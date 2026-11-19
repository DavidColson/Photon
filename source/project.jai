
// Memory: everything the project owns is individually heap allocated and freed when it's replaced or removed
// (folders/ignores in project_set_settings, files in project_destroy_file). Anything that holds on to project
// strings beyond the current frame, such as palette results, must take its own copy.

Project :: struct {
	folders: [..]string;
	ignore: [..]string;
	
	File :: struct {
		fullName: string;
		content: string;
		lock: Mutex;
		locator: Bucket_Locator;
		diskLastModtime: Apollo_Time;
		lineEndingMode: Document.LineEndingMode;
		lineStarts: []s64;
		tsTree: *TSTree;

		// Load tasks on the thread group hold a raw pointer to this file and take its lock while
		// they write into it, so it cannot be freed while any of them are outstanding.
		queuedLoads: s32;
		// Removed from the project, but a queud load is still holding it.
		tombstoned: bool;
	}	
	
	projectFiles: Bucket_Array(File, 128);
	projectFileTable: Table(string, Bucket_Locator, given_compare_function=platform_path_equal, given_hash_function=platform_path_hash);

	ProjectLoadProgress :: enum {
		NONE;
		COMPLETE;
		WAITING_FOR_FILE_SCAN;
		FILE_SCAN_IN_PROGRESS;
		WAITING_FOR_FILE_LOADING;
		FILE_LOADING_IN_PROGRESS;
		RELOAD_RECONCILE_IN_PROGRESS; // projectAsyncWorker is reading projectFiles to find files no longer in the project
	}
	loadProgress: ProjectLoadProgress;
	pendingFileLoads: s32;
	threadGroup: Thread_Group; // @todo: rename
	threadGroupStarted: bool;
    lineStartTempArrays: [ ][..]s64;
	pendingReconciles: [..]string; // these are file change events that came in while we were building the project file list
}

projectAsyncWorker: Async;
projectAsyncWorkerStarted: bool;

// Absolute path to the .photon-project file currently loaded, '/' separated.
projectFilePath: string;

projectReloadRequested: bool;
projectReloadInProgress: bool;

project_set_file_path :: (path: string) {
	free(projectFilePath);
	projectFilePath = ifx is_absolute_path(path) then copy_string(path) else copy_string(get_absolute_path(path));
	path_overwrite_separators(projectFilePath, #char "/");
}

project_is_project_file :: (path: string) -> bool {
	return projectFilePath.count > 0 && platform_path_equal(path, projectFilePath);
}

project_reload :: () {
	if !projectReloadRequested  log("Project file % changed, reload requested", projectFilePath);
	projectReloadRequested = true;
}

project_do_reload :: () {
	// Parse into temp first so a broken file leaves the current project untouched
	folders, ignore: [..]string;
	neverLoaded := project.loadProgress == .NONE; // the project file was broken at startup
	if !project_parse_file(projectFilePath, *folders, *ignore) {
		if neverLoaded {
			log_error("Failed to parse project file %, still waiting for the errors to be fixed", projectFilePath);
			push_notification("Project file has errors, fix them to load the project");
		}
		else {
			log_error("Failed to reparse project file %, keeping the current project", projectFilePath);
			push_notification("Project file has errors, keeping current project");
		}
		return;
	}

	project_set_settings(folders, ignore);

	// Nothing to reconcile if it never loaded, so this is just a normal first load
	if neverLoaded {
		project_watch_folders();
		project.loadProgress = .WAITING_FOR_FILE_SCAN;
		project_begin_load();
		return;
	}

	watcher_reset_project_watcher();
	project_watch_folders();
	
	// Document paths are not watched if the project watcher is watching them
	// So we have to re-register them now 
	for doc: openDocuments  watch_directory_for_document(document_get_path(doc));

	log("Project reload: reparsed project file, % folder(s), % ignore(s)", project.folders.count, project.ignore.count);
	projectReloadInProgress = true;

	// Find files that are no longer in the project on the worker, then remove them back on the main thread.
	// The worker only reads projectFiles; while it runs the project counts as loading, so nothing else
	// on the main thread adds, removes or reaps project files (see project_is_worker_reading_files).
	ReloadTaskData :: struct {
		toRemove: [..]Bucket_Locator;
	}

	find_files_outside_project_task :: (data: *void) {
		taskData := cast(*ReloadTaskData, data);
		for * file: project.projectFiles {
			if file.tombstoned continue;
			if !path_is_within_project_folders(file.fullName) || should_ignore_file(file.fullName) {
				array_add(*taskData.toRemove, file.locator);
			}
		}
	}

	find_files_outside_project_complete :: (data: *void) {
		taskData := cast(*ReloadTaskData, data);
		defer { array_reset(*taskData.toRemove); free(taskData); }

		for taskData.toRemove  project_remove_file(it);
		log("Project reload: removed % file(s) no longer in the project", taskData.toRemove.count);

		// Documents opened while the worker was running couldn't remove their project entries, so do it now
		project_remove_open_documents();
		project_reap_tombstones();

		// Now scan the new folders for files we don't have yet, load like normal
		project_begin_load();
	}

	taskData := New(ReloadTaskData);
	taskData.toRemove.allocator = context.allocator;
	project.loadProgress = .RELOAD_RECONCILE_IN_PROGRESS;

	// Files are about to be removed and their slots reused, so drop any open palette results that refer to them
	command_palette_refresh_project_results();

	push_task(*projectAsyncWorker, taskData, find_files_outside_project_task, find_files_outside_project_complete);
}

// True while projectAsyncWorker is walking or building projectFiles without a lock.
// The main thread must not add, remove or reap project files during this time.
project_is_worker_reading_files :: inline () -> bool {
	return project.loadProgress == .FILE_SCAN_IN_PROGRESS || project.loadProgress == .RELOAD_RECONCILE_IN_PROGRESS;
}

// A path is either a document or a project file, never both
project_remove_open_documents :: () {
	for doc: openDocuments {
		found, locator := table_find(*project.projectFileTable, document_get_path(doc));
		if found  project_remove_file(locator);
	}
}

project_is_loaded :: inline () -> bool {
	return project.loadProgress == .COMPLETE;
}

project_is_loading :: inline () -> bool {
	return project.loadProgress != .NONE && project.loadProgress != .COMPLETE;
}

free_file :: (file: *Project.File) {
	free(file.content);
	array_reset(*file.lineStarts);
	if file.tsTree { ts_tree_delete(file.tsTree); file.tsTree = null; }
}

project_remove_file :: (locator: Bucket_Locator) {
	file := bucket_array_find_pointer(*project.projectFiles, locator);
	if file == null || file.tombstoned return;

	table_remove(*project.projectFileTable, file.fullName);

	if file.queuedLoads > 0 {
		file.tombstoned = true; // reaped by project_update once those loads come back
		log("Project file % tombstoned, % load(s) still in flight", file.fullName, file.queuedLoads);
		return;
	}

	project_destroy_file(file);
}

project_reap_tombstones :: () {
	for * file: project.projectFiles {
		if !file.tombstoned || file.queuedLoads > 0 continue;
		log("Reaped tombstoned project file %", file.fullName);
		project_destroy_file(file);
	}
}

project_destroy_file :: (file: *Project.File) {
	locator := file.locator;
	free_file(file);
	free(file.fullName);
	destroy(*file.lock);
	bucket_array_remove(*project.projectFiles, locator);
}

project_add_file :: (path: string) -> Bucket_Locator {
	file := Project.File.{ fullName = copy_string(path) };
	init(*file.lock);
	locator, entry := bucket_array_add(*project.projectFiles, file);
	entry.locator = locator;
	table_add(*project.projectFileTable, entry.fullName, locator);
	return locator;
}

project_queue_file_load :: (locator: Bucket_Locator) {
	file := bucket_array_find_pointer(*project.projectFiles, locator);
	if file == null || file.tombstoned return;

	file.queuedLoads += 1;
	project.pendingFileLoads += 1;
	add_work(*project.threadGroup, file, tprint("Load task %", file.fullName));
}

path_is_within_project_folders :: (path: string) -> bool {
	for project.folders {
		if path_is_within(path, it) return true;
	}
	return false;
}

ProjectFileSections :: enum {
	NONE;
	FOLDERS;
	IGNORE;
}

project_parse_file :: (projectFileName: string, folders: *[..]string, ignore: *[..]string) -> bool {
	handler: Text_File_Handler;
	defer deinit(*handler);

	folders.allocator = temp;
	ignore.allocator = temp;

	currentSection := ProjectFileSections.NONE;

	start_file(*handler, "project", projectFileName);
	if handler.failed return false;

	while true {
		line, found := consume_next_line(*handler);
		if !found break;

		if begins_with(line, "[") {
			if !ends_with(line, "]") {
				error(handler, "Sections must end with a ']' character");
				return false;
			}

			sectionName := slice(line, 1, line.count-2);
			if sectionName == {
				case "folders";
					currentSection = .FOLDERS;
				case "ignore";
					currentSection = .IGNORE;
				case;
					error(handler, "Unknown section");
					return false;
			}
			continue;
		}
		else if currentSection == .NONE {
			error(handler, "No open section at this point in the file");
			return false;
		}

		if currentSection == {
			case .FOLDERS;
				if !is_absolute_path(line) {
					error(handler, "Supplied folder is not an absolute path");
					return false;
				}
				if !is_directory(line) {
					error(handler, "Supplied folder is not a directory or cannot be found");
					return false;
				}
				line = trim_right(line, "/");
				line = trim_right(line, "\\");
				folder := copy_string(line,,temp);
				path_overwrite_separators(folder, #char "/");
				array_add(folders, folder);
			case .IGNORE;
				folder := copy_string(line,,temp);
				path_overwrite_separators(folder, #char "/");
				array_add(ignore, folder);
		}
	}

	return true;
}

project_set_settings :: (folders: []string, ignore: []string) {
	for project.folders  free(it);
	for project.ignore   free(it);
	array_reset(*project.folders);
	array_reset(*project.ignore);

	for folders  array_add(*project.folders, copy_string(it));
	for ignore   array_add(*project.ignore,  copy_string(it));
}

should_ignore_path :: (path: string) -> bool {
	// we assume paths are all allowed
	shouldBeIgnored := false;

	// check if it's been ignored
	for project.ignore {
		result := find_index_from_left_fast(path, it);
		if result > 0 then shouldBeIgnored = true;
	}

	return shouldBeIgnored;
}

should_ignore_file :: (path: string) -> bool {
	// naive substring match for now, we'll deal with wildcards and stuff another time

	shouldBeIgnored := should_ignore_path(path);
	if shouldBeIgnored then return true;

	extension, found := path_extension(path);
	if found {
		extension = to_lower_copy(extension,,temp);
		known, type := is_known_file_extension(extension);
		if known && type == .BINARY return true;
		if known && type == .TEXT return false;
	}

	return true; // unknown files are ignored
}

check_file_for_zeroes :: (path: string) -> bool {
	file, success := file_open(path);
	if !success return true;
	defer file_close(*file);
	
	buffer: [4*1024]u8;
	_, bytesRead := file_read(file, buffer.data, buffer.count);

	if find_index_from_left(.{bytesRead, buffer.data}, 0) >= 0 {
		return true;
	}
	return false;
}

project_watch_folders :: () {
	for project.folders {
		watch_project_directory(it);
	}

	// The project file itself usually lives outside the project folders, so watch its directory too.
	// This is a no-op if it's already covered by one of the folders above.
	if projectFilePath.count > 0  watch_directory_for_document(projectFilePath);
}

project_begin_load :: () {
	// note this task will read/edit the project without any protection
	// it is assumed no other project processes happen while this occurs

	collect_project_files_task :: (data: *void) {
		maybe_add_file_to_project_list :: (info: *File_Visit_Info, udata: *Project) {
			// should we ignore a directory?
			if info.is_directory {
				if should_ignore_path(info.full_name) {
					info.descend_into_directory = false;
				}
				return;
			}

			if should_ignore_file(info.full_name) then return;

			// see if it's already loaded
			success, _ := document_get_by_path(info.full_name);
			if success then return;

			// already in the project, e.g. we're rescanning after a project reload
			if table_contains(*project.projectFileTable, info.full_name) then return;

			// log("found file short: % full: %", info.short_name, info.full_name);

			project_add_file(info.full_name);
		}

		for project.folders {
			visit_files(it, recursive=true, *project, maybe_add_file_to_project_list, visit_directories=true);
		}
	}

	collect_project_files_complete :: (data: *void) {
		project.loadProgress = .WAITING_FOR_FILE_LOADING;
	}

	if !projectAsyncWorkerStarted {
		init_async(*projectAsyncWorker);
		projectAsyncWorkerStarted = true;
	}

	project.loadProgress = .FILE_SCAN_IN_PROGRESS;
	if projectReloadInProgress  log("Project reload: rescanning project folders");
	else                        log("Begin project loading");
	push_task(*projectAsyncWorker, null, collect_project_files_task, collect_project_files_complete);
}

project_update :: () {
	if projectAsyncWorkerStarted then process_completed_tasks(*projectAsyncWorker);

	if projectReloadRequested && !project_is_loading() {
		projectReloadRequested = false;
		project_do_reload();
	}

	if project.loadProgress == .WAITING_FOR_FILE_LOADING {
		// On a reload the thread group is already running, so only start it the first time
		if !project.threadGroupStarted {
			init_thread_groups();
			start(*project.threadGroup);
			project.threadGroupStarted = true;
		}

		// Delete any files that got opened properly while we did the file scan
		project_remove_open_documents();

		for * project.projectFiles {
			if it.content.count == 0 && it.queuedLoads == 0 {
				project_queue_file_load(it.locator);
			}
		}

		if projectReloadInProgress  log("Project reload: loading % new file(s) into the project", project.pendingFileLoads);
		else                        log("Loading % files into the project", project.pendingFileLoads);
		project.loadProgress = .FILE_LOADING_IN_PROGRESS;
	}

	if project.threadGroupStarted {
		results := get_completed_work(*project.threadGroup);
		for results {
			// for each loaded file you will need to copy it's data into the
			// real document in the open documents table
			file := cast(*Project.File, it);
			file.queuedLoads -= 1;
			project.pendingFileLoads -= 1;
		}
		// While the worker is reading projectFiles we can't remove entries; the reload completion reaps instead
		if results.count > 0 && !project_is_worker_reading_files() then project_reap_tombstones();
	}

	if project.loadProgress == .FILE_LOADING_IN_PROGRESS && project.pendingFileLoads == 0 {
		project.loadProgress = .COMPLETE;
		if projectReloadInProgress {
			log("Project reload complete");
			push_notification("Project Reloaded");
			projectReloadInProgress = false;

			// Bring the project files back into any open palette results now the reload is done
			command_palette_refresh_project_results();
		}
		else {
			log("Project loading complete");
			push_notification("Project Loaded");
		}
		project_replay_pending_reconciles();

		// @todo: track the progress of the project load
	}

	if project_is_loading() {
		requestRedraw = true;
	}
}

reconcile_project_entry :: (path: string) {
	if project.loadProgress == .NONE return;

	if project_is_loading() {
		if project.pendingReconciles.count < MAX_PENDING_RECONCILES {
			array_add(*project.pendingReconciles, copy_string(path));
		}
		return;
	}

	if !path_is_within_project_folders(path) return;
	if should_ignore_file(path) return;

	found, locator := table_find(*project.projectFileTable, path);
	exists, isDirectory := platform_path_stat(path);

	// TODO: we don't protect for the case where the file content is the same
	// so it reloads again here
	// Good for keeping us in sync, but maybe this could be improved?
	if exists && !isDirectory {
		if found {
			project_queue_file_load(locator);
		}
		else {
			log("Project file added: %", path);
			project_queue_file_load(project_add_file(path));
		}
	}
	else if found {
		log("Project file removed: %", path);
		project_remove_file(locator);
	}
}

MAX_PENDING_RECONCILES :: 8192;

project_replay_pending_reconciles :: () {
	for project.pendingReconciles {
		reconcile_project_entry(it);
		free(it);
	}
	array_reset(*project.pendingReconciles);
}

project_scan_directory :: (dir: string) {
	if !project_is_loaded() return;
	if !path_is_within_project_folders(dir) return;
	if should_ignore_path(dir) return;

	added := 0;

	visit :: (info: *File_Visit_Info, addedCount: *int) {
		if info.is_directory {
			if should_ignore_path(info.full_name) then info.descend_into_directory = false;
			return;
		}
		if should_ignore_file(info.full_name) return;
		if table_contains(*project.projectFileTable, info.full_name) return;

		alreadyOpen, _ := document_get_by_path(info.full_name);
		if alreadyOpen return;

		project_queue_file_load(project_add_file(info.full_name));
		addedCount.* += 1;
	}

	visit_files(dir, recursive=true, *added, visit, visit_directories=true);

	if added  log("Scanned new directory %: % project files added", dir, added);
}

init_thread_groups :: () {
    numCpus := get_number_of_processors();

    assert(numCpus >= 1);
    if numCpus > 200  numCpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.

    #if (OS == .WINDOWS) || (OS == .LINUX) {
        // This routine reports hyperthreads, so, divide by two, because of Intel marketing.
        numCpus /= 2;
    }

	// we want to leave a core for the main thread and one for the async thread
    numThreads := max(numCpus - 2, 1);
	// numThreads = 1;

    init(*project.threadGroup, numThreads, project_file_load_thread_proc);
    project.threadGroup.name    = "Project File Loading";
    project.threadGroup.logging = false;
	// todo: make sure you yeet these after project loading is done
	project.lineStartTempArrays = NewArray(numThreads, [..]s64);
	for * project.lineStartTempArrays {
		it.allocator = temp;
	}
}

project_file_load_thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
	file := cast(*Project.File, work);

	lock(*file.lock);
	defer unlock(*file.lock);
	
	free_file(file);

	tempArray := *project.lineStartTempArrays[thread.worker_info.worker_index];
	array_reset_keeping_memory(tempArray);
	
	// @todo: handle failed case
	f, result := file_open(file.fullName);
	content: string;
	if file_length(f) > 0 {
		content, result = read_entire_file(f);
	}
	else {
		result = true;
	}
	file_close(*f);

	modtime := file_modtime_and_size(file.fullName);

	file.diskLastModtime = modtime;
	file.content = content;

	// find line starts
	array_add(tempArray, 0);
	lfCount := 0;
	crlfCount := 0;
	i := 0;
	while i < file.content.count {
		j := find_index_from_left(file.content, #char "\n", i);
		if j >= 0 {
			if j > 0 && file.content[j-1] == #char "\r" {
				crlfCount += 1;
			}
			else {
				lfCount += 1;
			}
			array_add(tempArray, j+1);
			i = j+1;
		}
		else {
			i = file.content.count;
		}
	}

	file.lineStarts = NewArray(tempArray.count, s64);
	memcpy(file.lineStarts.data, tempArray.data, size_of(s64)*tempArray.count);
	
	// set line ending mode
	if lfCount > 0 && crlfCount == 0 {
		file.lineEndingMode = .LF;
	}
	else if lfCount == 0 && crlfCount > 0 {
		file.lineEndingMode = .CRLF;
	}
	else if lfCount > 0 && crlfCount > 0 {
		if lfCount > crlfCount {
			file.lineEndingMode = .MIXED_MAJORITY_LF;
		}
		else {
			file.lineEndingMode = .MIXED_MAJORITY_CRLF;
		}
	}
	
	return .CONTINUE;
}

is_known_file_extension :: inline (extension: string) -> bool, KnownExtensionFileType {
    ok, type := table_find(*knownExtensionsTable, extension);
    return ok, type;
}

KnownExtensionFileType :: enum {
	TEXT;
	BINARY;
}

knownExtensionsTable :: #run -> Table(string, KnownExtensionFileType) {
    table: Table(string, KnownExtensionFileType);

    textFiles :: string.[
        "jai", "c", "cpp", "h", "hpp", "cc", "cs", "d", "txt", "md", "ini", "csv", "go", "log",
        "bat", "sql", "py", "m", "html", "xml", "plist", "js", "jsx", "ts", "tsx", "json", "yml",
        "yaml", "toml", "zig", "odin", "photon-project", "lua", "luau", "inl", "cmake", "prl",
		"prl", "ps1", "qml", "vcxproj", "sln", "props", "cxx", "css", "decl", "groovy", "scm", 
    ];
    for textFiles  table_add(*table, it, .TEXT);

    binaryFiles :: string.[
        "exe", "pdb", "ttf", "otf", "eot", "woff", "dll", "lib", "dylib", "so", "a", "o", "pdf",
        "jpg", "png", "gif", "jpeg", "ico", "tif", "tiff", "tga", "bmp", "webp", "mp3", "wav", "ogg",
        "wma", "blend", "blend1", "obj", "fbx", "dae", "3ds", "dat", "msh2", "mpg", "mpeg", "psd", "codex",
        "webm", "zip", "rar", "7z", "bin", "sys", "iso", "nib", "exp", "pyc", "rpyc", "DS_Store", "dmg",
		"svg", "bnk", "woff2"
    ];
    for binaryFiles  table_add(*table, it, .BINARY);

    return table;
}
