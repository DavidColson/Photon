
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
		locator: Bucket_Locator;
		diskLastModtime: Apollo_Time;
		lineEndingMode: Document.LineEndingMode;
		lineStarts: [..]s64;
	}
	projectFiles: Bucket_Array(File, 128);

	ProjectLoadProgress :: enum {
		WAITING_FOR_FILE_SCAN;
		FILE_SCAN_IN_PROGRESS;
		WAITING_FOR_FILE_LOADING;
		FILE_LOADING_IN_PROGRESS;
		COMPLETE;
	}
	loadProgress: ProjectLoadProgress;
	pendingFileLoads: s32;
	threadGroup: Thread_Group;
}

testMutex: Mutex;

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

	init(*testMutex);

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
				line = trim_right(line, "/");
				line = trim_right(line, "\\");
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

			// If we're keeping a file, copy it's full_name with our allocator and store
			file := Project.File.{ fullName = copy_string(info.full_name,, project_allocator()) };
			locator, entry := bucket_array_add(*project.projectFiles, file);
			entry.locator = locator;
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
		init_project_thread_group();
		start(*project.threadGroup);

		for * project.projectFiles {
			if it.content.count == 0 {
				project.pendingFileLoads += 1;
				add_work(*project.threadGroup, it, tprint("Load task %", it.fullName));
			}
		}

		log("Loading % files into the project", project.pendingFileLoads);
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
			push_notification("Project Loaded");
		}

		// @todo: track the progress of the project load
	}

	if project.loadProgress != .COMPLETE {
		requestRedraw = true;
	}

}

#scope_file

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
	// numThreads = 1;

    init(*project.threadGroup, numThreads, project_file_load_thread_proc);
    project.threadGroup.name    = "Project File Loading";
    project.threadGroup.logging = false;
}

project_file_load_thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
	file := cast(*Project.File, work);
	
	// @todo: handle failed case
	f, result := file_open(file.fullName);
	content, success := read_entire_file(f);
	file_close(*f);

	modtime := file_modtime_and_size(file.fullName);

	file.diskLastModtime = modtime;
	file.content = content;

	// find line starts
	array_add(*file.lineStarts, 0);
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
			array_add(*file.lineStarts, j+1);
			i = j+1;
		}
		else {
			i = file.content.count;
		}
	}
	
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
