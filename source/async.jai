
// This is intended to be a single long running worker thread which we can
// Give work that we don't want to block the main thread, such as scanning, loading files
// parsing and that sort of thing. Not recommended for very low latency, fast work (better to use a Thread_Group for that)

Async :: struct {
	Task :: struct {
		data: *void;
		workFunc: #type (data: *void);
		completeFunc: #type (data: *void);
		next: *Task;
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
}

init_async :: (using async: *Async) {
	// Spin up the thread for doing out work
	async.thread.data = cast(*void, async);
	thread_init(*async.thread, async_thread_entry);

	// for parallel by default, we'd have to spin up several threads here instead of just one
	// have them in some array

	// Setup the work queue
	init(*available.semaphore);
	init(*available.mutex);
	init(*completed.semaphore);
	init(*completed.mutex);

	thread_start(*async.thread);
}

shutdown :: (async: *Async) {
	async.shutdown = true;
}

push_task :: (using async: *Async, data: *void, func: #type (data: *void), completeFunc: #type (data: *void)) {
	task := New(Async.Task);
	task.workFunc = func;
	task.completeFunc = completeFunc;
	task.data = data;
	pendingTasks += 1;
	push_task(*async.available, task);

	// when pushing a task, we want the task to be given to all the threads at once
	// we could just create async tasks in a loop here, one for each thread requested
	// of course the push_task function would want to know how many wide do you want your task to go

	// I think we would also need a task list for every thread
}

process_completed_tasks :: (using async: *Async) -> s32 {

	// in here you would have to loop through every thread and collect up it's completed work
	// calling the complete function

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
	return pendingTasks;
}

#scope_file

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
			if task.workFunc then task.workFunc(task.data);
			push_task(*async.completed, task);
		}
	}
	return 0;
}

#import "Thread";
