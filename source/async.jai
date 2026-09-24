
// This is intended to be a single long running worker thread which we can
// Give work that we don't want to block the main thread, such as scanning, loading files
// parsing and that sort of thing. Not recommended for very low latency, fast work (better to use a Thread_Group for that)

#import "Atomics";

Async :: struct {
	Task :: struct {
		data: *void;
		workFunc: #type (data: *void);
		completeFunc: #type (data: *void);
		next: *Task;
		id: s32;
	}

	TaskList :: struct {
		semaphore: Semaphore;
		mutex: Mutex;
		first: *Task;
		last: *Task;
		count: s32;
	}

	thread: Thread;
	available: TaskList;
	completed: TaskList;
	shutdown: bool;
	pendingTasks: s32;
	waitStartTime: Apollo_Time;
	taskCounter: s32;
}

init_async :: (using async: *Async) {
	// Spin up the thread for doing out work
	async.thread.data = cast(*void, async);
	thread_init(*async.thread, async_thread_entry);

	// Setup the work queue
	init(*available.semaphore);
	init(*available.mutex);
	init(*completed.semaphore);
	init(*completed.mutex);

	thread_start(*async.thread);
	async.waitStartTime = APOLLO_TIME_INVALID;
}

shutdown :: (async: *Async) {
	async.shutdown = true;
}

push_task :: (using async: *Async, data: *void, func: #type (data: *void), completeFunc: #type (data: *void)) {
	task := New(Async.Task);
	task.workFunc = func;
	task.completeFunc = completeFunc;
	task.data = data;
	task.id = taskCounter;
	taskCounter += 1;
	pendingTasks += 1;
	push_task(*async.available, task);
	if async.waitStartTime == APOLLO_TIME_INVALID then async.waitStartTime = current_time_monotonic();
}

process_completed_tasks :: (using async: *Async) -> s32 {
	completedTasks: *Async.Task;
	completedCount: s32;

	// copy out the completed items and reset the completed list
	lock(*completed.mutex);
	completedCount = completed.count;
	completedTasks = completed.first;

	if completed.first {
		completed.first = null;
		completed.last = null;
		completed.count = 0;
	}
	unlock(*completed.mutex);

	while completedTasks {
		task := completedTasks;
		completedTasks = task.next;

		if task.completeFunc {
			task.completeFunc(task.data);
		}
		free(task);
		pendingTasks -= 1;
	}

	if pendingTasks == 0 then async.waitStartTime = APOLLO_TIME_INVALID;
	return pendingTasks;
}

push_task :: (list: *Async.TaskList, task: *Async.Task) {
	lock(*list.mutex);

	if list.last {
    	list.last.next = task;
    	list.last      = task;
    } else {
    	list.first     = task;
    	list.last      = task;
    }

    list.count += 1;

	unlock(*list.mutex);

	signal(*list.semaphore);
}

pop_task :: (list: *Async.TaskList) -> *Async.Task {
	lock(*list.mutex);
	defer unlock(*list.mutex);

	// no work to do
	if !list.first return null;

	result := list.first;
	list.first = result.next;

	// list is empty now
	if !list.first then list.last = null;
	
	list.count -= 1;
	return result;
}

async_thread_entry :: (thread: *Thread) -> s64 {
	async := cast(*Async, thread.data);

	while !async.shutdown {
		task: *Async.Task;
		wait_for(*async.available.semaphore);
		if async.shutdown break;

		task = pop_task(*async.available);

		if task {
			task.next = null;
			if task.workFunc then task.workFunc(task.data);
			push_task(*async.completed, task);
		}
	}
	return 0;
}

ParallelForPool :: struct {
	// This represents a whole batch of work
	// that the pool will execute across all it's threads
	Batch :: struct {
		proc: #type (batch: *Batch, start: s64, end: s64, threadIndex: s64);
		items: *void;
		userData: *void;
		pending: s64; // atomic
	}
	
	// This represents the task of a specific thread
	// It is some subsection of the batch
	Task :: struct {
		next: *Task;
		start: s64;
		end: s64;
	}

	// Per thread data, index is local to this pool (0 is the main thread, workers are 1..threads.count)
	// unlike Thread.index which is global across all threads in the program
	Worker :: struct {
		pool: *ParallelForPool;
		index: s64;
	}

	threads: []Thread;
	workers: []Worker;
	workAvailable: Semaphore;
	done: Semaphore;
	taskListMutex: Mutex;
	first: *Task;
	last: *Task;
	currentBatch: *Batch;
	shutdown: bool;
}

pop_task :: (pool: *ParallelForPool) -> *ParallelForPool.Task {
	lock(*pool.taskListMutex);
	defer unlock(*pool.taskListMutex);
	
	// no work to do
	if !pool.first return null;
	
	result := pool.first;
	pool.first = result.next;
	
	// list is empty now
	if !pool.first then pool.last = null;
	
	return result;
}

parallel_pool_thread_entry :: (thread: *Thread) -> s64 {
	worker := cast(*ParallelForPool.Worker, thread.data);
	pool := worker.pool;

	while !pool.shutdown {
		task: *ParallelForPool.Task;
		wait_for(*pool.workAvailable);
		if pool.shutdown break;

		task = pop_task(pool);
		if task then run_task(pool, task, worker.index);
	}
	return 0;
}

run_task :: (pool: *ParallelForPool, task: *ParallelForPool.Task, threadIndex: s64) {
	pool.currentBatch.proc(pool.currentBatch, task.start, task.end, threadIndex);
	if atomic_add(*pool.currentBatch.pending, -1) == 1 then signal(*pool.done);
}

init_parallel_for_pool :: (using pool: *ParallelForPool) {
	// Calculate number of threads
	numCpus := get_number_of_processors();
	assert(numCpus >= 1);
	if numCpus > 200  numCpus = 200;
	#if (OS == .WINDOWS) || (OS == .LINUX) {
		numCpus /= 2;
	}
	
	// We'll make one less to leave room for the main thread
	// which will be executing as well
	numThreads := max(numCpus - 1, 1); 
	
	init(*pool.done);
	init(*pool.workAvailable);
	init(*pool.taskListMutex);
	
	threads = NewArray(numThreads, Thread);
	workers = NewArray(numThreads, ParallelForPool.Worker);
	for * threads {
		worker := *workers[it_index];
		worker.pool = pool;
		worker.index = it_index + 1; // 0 is reserved for the main thread
		it.data = cast(*void, worker);
		thread_init(it, parallel_pool_thread_entry);
		thread_start(it);
	}
}

parallel_for_pool_thread_count :: (pool: *ParallelForPool) -> s64 {
	return pool.threads.count + 1;
}

parallel_for :: (pool: *ParallelForPool, items: []$T, userData: *$G, $proc: (*T, int, *G) -> ()) {
	if items.count == 0 return;
	
	execute_range :: (batch: *ParallelForPool.Batch, start: s64, end: s64, threadIndex: s64) {
		data := cast(*T, batch.items);
		for i: start..end-1  proc(*data[i], threadIndex, cast(*G, batch.userData));
	}	
	// Firstly we need to split up the items into sections reliably to give to each thread
	
	batch: ParallelForPool.Batch;
	batch.proc = execute_range;
	batch.items = items.data;
	batch.userData = userData;
	
	pool.currentBatch = *batch;
	
	// Distribute work
	// We do a few per thread to try balance out the work a bit more, probably worth experimenting with it
	numTasks := min(items.count, (pool.threads.count + 1) * 4);
	itemsPerTask := (items.count + numTasks - 1) / numTasks; // integer division with round up
	numTasks = (items.count + itemsPerTask - 1) / itemsPerTask;
	// After the above two operaitons itemsPerTask * numTasks should equal items.count
	
	tasks := NewArray(numTasks, ParallelForPool.Task,,temp);
	batch.pending = numTasks;
	
	for * task: tasks {
		task.start = it_index * itemsPerTask;
		task.end = min(task.start + itemsPerTask, items.count);
		
		// Push task to list
		lock(*pool.taskListMutex);
		if pool.last {
			pool.last.next = task;
			pool.last      = task;
		} else {
			pool.first     = task;
			pool.last      = task;
		}
		unlock(*pool.taskListMutex);
		
		signal(*pool.workAvailable);
	}
	
	
	while task := pop_task(pool) {
		run_task(pool, task, 0);
	}
	
	wait_for(*pool.done);
}
