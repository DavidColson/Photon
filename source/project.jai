
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

	// loading flow
	ProjectLoadProgress :: enum {
		WAITING_FOR_FILE_SCAN;
		FILE_SCAN_IN_PROGRESS;
		WAITING_FOR_FILE_LOADING;
		FILE_LOADING_IN_PROGRESS;
		COMPLETE;
	}
	loadProgress: ProjectLoadProgress;
	fileScanResults: [..]string;
	pendingFileLoads: s32;
	threadGroup: Thread_Group;
}

project_allocator :: inline () -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *project.memory };
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
	project.fileScanResults.allocator = project_allocator();

	currentSection := ProjectFileSections.NONE;

	start_file(*handler, "project", projectFileName);
	if handler.failed return false, .{};

	while true {
		line, found := consume_next_line(*handler);
		if !found break;

		if begins_with(line, "[") {
			if !ends_with(line, "]") {
				error(*handler, "Sections must end with a ']' character");
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
					error(*handler, "Unknown section");
					return false, .{};
			}
			continue;
		}
		else if currentSection == .NONE {
			error(*handler, "No open section at this point in the file");
			return false, .{};
		}

		if currentSection == {
			case .FOLDERS;
				if !is_absolute_path(line) {
					error(*handler, "Supplied folder is not an absolute path");
					return false, .{};
				}
				if !is_directory(line) {
					error(*handler, "Supplied folder is not a directory or cannot be found");
					return false, .{};
				}
				array_add(*project.folders, copy_string(line,,project_allocator()));
			case .IGNORE;
				array_add(*project.ignore, copy_string(line,,project_allocator()));
			case .ALLOW;
				array_add(*project.allow, copy_string(line,,project_allocator()));
		}
	}

	return true, project;
}


should_ignore_path :: (path: string) -> bool {
	shouldBeIgnored := false;
	for project.ignore {
		result := find_index_from_left_fast(path, it);
		if result > 0 then shouldBeIgnored = true;
	}
	// @todo: respect the allow list
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
	
	if check_file_for_zeroes(path) return true;

	return false;
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
	
			// log("found file short: % full: %", info.short_name, info.full_name);

			// If we're keeping a file, copy it's full_name with our allocator and store
			copyString := copy_string(info.full_name,, project_allocator());
			array_add(*project.fileScanResults, copyString);
		}

		for project.folders {
			visit_files(it, recursive=true, *project, maybe_add_file_to_project_list, visit_directories=true);
		}
	}

	collect_project_files_complete :: (data: *void) {
		project.loadProgress = .WAITING_FOR_FILE_LOADING;
	}

	project.loadProgress = .FILE_SCAN_IN_PROGRESS;
	push_task(*asyncWorker, null, collect_project_files_task, collect_project_files_complete);
}

project_update :: () {
	if project.loadProgress == .WAITING_FOR_FILE_LOADING {
		init_project_thread_group();
		start(*project.threadGroup);

		for project.fileScanResults {
			task := New(LoadProjectFileTask,,project_allocator());
			task.filePath = it;

			project.pendingFileLoads += 1;
			add_work(*project.threadGroup, task, tprint("Load task %", it));
		}
		project.loadProgress = .FILE_LOADING_IN_PROGRESS;
	}

	if project.loadProgress == .FILE_LOADING_IN_PROGRESS {

		results := get_completed_work(*project.threadGroup);

		for results {
			// for each loaded file you will need to copy it's data into the
			// real document in the open documents table
			project.pendingFileLoads -= 1;
		}

		if project.pendingFileLoads == 0 {
			project.loadProgress = .COMPLETE;
			log("Project loading complete");
		}

		// track the progress of the project load
	}
}

#scope_file

LoadProjectFileTask :: struct {
	filePath: string;
}

init_project_thread_group :: () {
    numCpus := get_number_of_processors();

    assert(numCpus >= 1);
    if numCpus > 200  numCpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.

    #if (OS == .WINDOWS) || (OS == .LINUX) {
        // This routine reports hyperthreads, so, divide by two, because of Intel marketing.
        numCpus /= 2;
    }

	// we want to leave a core for the main thread and one for the async thread
    numThreads := max(numCpus - 2, 1);

    init(*project.threadGroup, numThreads, project_file_load_thread_proc);
    project.threadGroup.name    = "Project File Loading";
    project.threadGroup.logging = false;
}

project_file_load_thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
	task := cast(*LoadProjectFileTask, work);

	// you have a filename, you can just load the file now

	// there is a question about whether you defer the copy into place part of the load
	// and do it on the main thread, thus ensuring there are no edits to the file while someone
	// could be doing somethign with it, such as quickly opening it into a panel

	// it would be vastly simpler to just do it all in the thread group procedure
	// but then you somehow need to block the file being accessed or touched by anyone other than this procedure

	// which would imply locking inside each file again, which we've been trying to avoid

	// okay we already have a mechanism where we can do it in a different document pointer that can't be touched by anyone else
	// and then we copy it over to the real document location on the main thread
	// but this begs the question of then we need special functionality to handle the reparse on the thread group
	// cause it has to operate on the non-real document now, and then be copied over later, which is not usually how it works


	// so put simply, we need a straightforward way to prevent anyone accessing the document in the openDocument array slot
	// before it's finished loading

	// we could change panel_set_active_document to take a path or locator, and then block the document being set on any
	// panel until the loading is complete?
	// that's 

	document_get_or_open(task.filePath, false);
	
	return .CONTINUE;
}

is_known_file_extension :: inline (extension: string) -> bool, KnownExtensionFileType {
    ok, type := table_find_new(*knownExtensionsTable, extension);
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
		"prl", "ps1", "qml", "vcxproj", "sln", "props", "cxx", "css", "decl"
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
