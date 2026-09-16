
// @todo: currently we use one memory pool for the whole project
// but really, we need more
// we need one for long lasting project info such as the folder lists, etc
// and then we need another that lasts for the duration of the project loading
// process, to store work, the file scan results and other temporary things

Project :: struct {
	memory: Flat_Pool;

	folders: [..]string;
	ignore: [..]string;
	allow: [..]string;

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
	}
	loadProgress: ProjectLoadProgress;
	pendingFileLoads: s32;
	threadGroup: Thread_Group; // @todo: rename
	threadGroupStarted: bool;
    lineStartTempArrays: [ ][..]s64;
	pendingReconciles: [..]string; // these are file change events that came in while we were building the project file list

	SearchResult :: struct {
		matchLine: string;
		lineNum: s64;
		lineOffset: s64;
		filePath: string;
		fileLocator: Bucket_Locator;
		matchRange: Document.Range;
		loaded: bool;
	}

	SearchWork :: struct {
		loaded: bool;
		bucketIndex: s64;
		searchTerm: string;
		results: [..]SearchResult;
	}

	searchThreads: Thread_Group;
}

project_allocator :: inline () -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *project.memory };
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

	free_file(file);
	destroy(*file.lock);
	bucket_array_remove(*project.projectFiles, locator);
}

project_reap_tombstones :: () {
	for * file: project.projectFiles {
		if !file.tombstoned || file.queuedLoads > 0 continue;
		log("Reaped tombstoned project file %", file.fullName);
		locator := file.locator;
		free_file(file);
		destroy(*file.lock);
		bucket_array_remove(*project.projectFiles, locator);
	}
}

project_add_file :: (path: string) -> Bucket_Locator {
	file := Project.File.{ fullName = copy_string(path,, project_allocator()) };
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
	ALLOW;
}

project_parser :: (projectFileName: string) -> bool, Project {
	handler: Text_File_Handler;
	defer deinit(*handler);

	// currently we create the project itself and set it up in here
	// is this a good idea? Not sure lets see how it goes
	project: Project;
	project.loadProgress = .WAITING_FOR_FILE_SCAN;
	project.folders.allocator = project_allocator();
	project.ignore.allocator = project_allocator();
	project.allow.allocator = project_allocator();

	currentSection := ProjectFileSections.NONE;

	start_file(*handler, "project", projectFileName);
	if handler.failed return false, .{};

	while true {
		line, found := consume_next_line(*handler);
		if !found break;

		if begins_with(line, "[") {
			if !ends_with(line, "]") {
				error(handler, "Sections must end with a ']' character");
				return false, .{};
			}

			sectionName := slice(line, 1, line.count-2);
			if sectionName == {
				case "folders";
					currentSection = .FOLDERS;
				case "ignore";
					currentSection = .IGNORE;
				case "allow";
					currentSection = .ALLOW;
				case;
					error(handler, "Unknown section");
					return false, .{};
			}
			continue;
		}
		else if currentSection == .NONE {
			error(handler, "No open section at this point in the file");
			return false, .{};
		}

		if currentSection == {
			case .FOLDERS;
				if !is_absolute_path(line) {
					error(handler, "Supplied folder is not an absolute path");
					return false, .{};
				}
				if !is_directory(line) {
					error(handler, "Supplied folder is not a directory or cannot be found");
					return false, .{};
				}
				line = trim_right(line, "/");
				line = trim_right(line, "\\");
				folder := copy_string(line,,project_allocator()); 
				path_overwrite_separators(folder, #char "/");
				array_add(*project.folders, folder);
			case .IGNORE;
				folder := copy_string(line,,project_allocator()); 
				path_overwrite_separators(folder, #char "/");
				array_add(*project.ignore, folder);
			case .ALLOW;
				folder := copy_string(line,,project_allocator()); 
				path_overwrite_separators(folder, #char "/");
				array_add(*project.allow, folder);
		}
	}

	return true, project;
}


should_ignore_path :: (path: string) -> bool {
	// we assume paths are all allowed
	shouldBeIgnored := false;

	// first we check if it's allowed
	for project.allow {
		result := find_index_from_left_fast(path, it);
		if result > 0 then shouldBeIgnored = false;
	}
	
	// then check if it's additionally been ignored
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

	project.loadProgress = .FILE_SCAN_IN_PROGRESS;
	log("Begin project loading");
	push_task(*asyncWorker, null, collect_project_files_task, collect_project_files_complete);
}

project_update :: () {
	if project.loadProgress == .WAITING_FOR_FILE_LOADING {
		init_thread_groups();
		start(*project.threadGroup);
		start(*project.searchThreads);
		project.threadGroupStarted = true;

		for * project.projectFiles {
			if it.content.count == 0 {
				project_queue_file_load(it.locator);
			}
		}

		log("Loading % files into the project", project.pendingFileLoads);
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
		if results.count > 0 then project_reap_tombstones();
	}

	if project.loadProgress == .FILE_LOADING_IN_PROGRESS && project.pendingFileLoads == 0 {
		project.loadProgress = .COMPLETE;
		log("Project loading complete");
		push_notification("Project Loaded");
		project_replay_pending_reconciles();

		// @todo: track the progress of the project load
	}

	if project_is_loading() {
		requestRedraw = true;
	}

	// Update the searcher thread if active
	searchWork := get_completed_work(*project.searchThreads);
	currentSearchTerm := string.{ focusedPanel.projectSearcher.input.text.count, focusedPanel.projectSearcher.input.text.data };
	for work: searchWork  {
		searchWork := cast(*Project.SearchWork, work);

		// check to see if the search term is the current one, if not, it's from
		// an old query and we can just discard the results
		if searchWork.searchTerm == currentSearchTerm && focusedPanel.projectSearcher.results.count < 5000 {
			for searchWork.results {
				array_add(*focusedPanel.projectSearcher.results, it);
				if it.loaded {
					array_add(*focusedPanel.projectSearcher.resultsRequiringFree, it);
				}
			}
		}
		else {
			// these results are being discarded (stale search term, or we've already hit the display cap),
			// so free the matchLine strings that get_line_content heap-allocated for open-document matches
			// (unloaded-file matches just slice into file.content and don't own their matchLine)
			for searchWork.results {
				if it.loaded {
					free(it.matchLine);
				}
			}
		}
		array_reset(*searchWork.results);
		free(searchWork.searchTerm);
		free(searchWork);
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

    init(*project.searchThreads, numThreads, project_search_thread_proc);
    project.searchThreads.name    = "Project Searcher";
    project.searchThreads.logging = false;
}

project_search_thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
	searchWork:= cast(*Project.SearchWork, work);
	array_reset(*searchWork.results);
	
	if searchWork.loaded {
		// this is where we search currently open documents

		// @todo: This actually iterates the real documents, which is pretty naughty tbh
		// Ideally these would all be document copies made at the point of searching on the main thread
		// something to sort out later
		for openDocuments.documents.all_buckets[searchWork.bucketIndex].data {
			if !openDocuments.documents.all_buckets[searchWork.bucketIndex].occupied[it_index] then continue;

			doc: *Document;
			if it.state == {
				case .INVALID;
					continue;
				case .A_VALID;
					doc = *it.docA;
				case .B_VALID;
					doc = *it.docB;
				case;
					continue;
			}

			hasMatches, results := search(doc.handle, .NOCASE, 0, searchWork.searchTerm, false);
			defer array_reset(*results);

			for result: results {
				coordinate := get_coordinate_from_offset(doc.handle, result.start);
				line := get_line_content(doc.handle, coordinate.line);

				searchResult: Project.SearchResult;
				searchResult.matchLine = line.text;
				searchResult.lineNum = coordinate.line;
				searchResult.lineOffset = line.startByteOffset;
				searchResult.filePath = doc.path;
				searchResult.fileLocator = .{ xx searchWork.bucketIndex, xx it_index };
				searchResult.matchRange = .{result.start - line.startByteOffset, (result.start - line.startByteOffset) + searchWork.searchTerm.count};
				searchResult.loaded = true;
				array_add(*searchWork.results, searchResult);
			}
		}
	}
	else {
		// this is where we search unloaded project files

		for project.projectFiles.all_buckets[searchWork.bucketIndex].data {
			if !project.projectFiles.all_buckets[searchWork.bucketIndex].occupied[it_index] then continue;
			if it.tombstoned then continue; // deleted on disk, only its memory is still here
		    file := *it;

			// @todo: currently 500 results per file is the max?? is that sensible?
			searchCursor := 0;
			while searchCursor < file.content.count && searchWork.results.count < 500 {
				result := find_index_from_left_nocase_fast(file.content, searchWork.searchTerm, searchCursor);
				if result > 0 {
					// found match
					// for each result we need to binary search the list of line starts for the file
					low := 0; // line 0
					high := file.lineStarts.count-1; // max line
					mid := 0;
					midStartOffset := 0;
					midEndOffset := 0;
					while low <= high {
						mid = low + ((high - low) / 2);
						midStartOffset = file.lineStarts[mid];

						if mid == high {
							if mid+1 < file.lineStarts.count {
								midEndOffset = file.lineStarts[mid+1];
							}
							else {
								midEndOffset = file.content.count;
							}
							break;
						}

						midEndOffset = file.lineStarts[mid+1];

						// target is before the mid line
						if result < midStartOffset {
							high = mid - 1;
						}
						// result is at or above the end of mid line
						else if result >= midEndOffset {
							low = mid + 1;
						}
						else {
							break;
						}
					}

					// once complete, mid is now set to the line in which the match was found on
					searchResult: Project.SearchResult; 
					searchResult.matchLine = .{ midEndOffset - midStartOffset, file.content.data + midStartOffset };
					searchResult.lineNum = mid;
					searchResult.lineOffset = midStartOffset;
					searchResult.filePath = file.fullName;
					searchResult.fileLocator = .{ xx searchWork.bucketIndex, xx it_index };
					searchResult.matchRange = .{result - midStartOffset, (result - midStartOffset) + searchWork.searchTerm.count};
					searchResult.loaded = false;
					array_add(*searchWork.results, searchResult);

					searchCursor = result + searchWork.searchTerm.count;
				}
				else {
					searchCursor = file.content.count; // end the search
				}
			}
		}
	}
	return .CONTINUE;
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
