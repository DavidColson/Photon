
Project :: struct {
	memory: Flat_Pool;

	folders: [..]string;
	ignore: [..]string;
	allow: [..]string;

	filesToOpen: [..]string;
}

project_allocator :: (project: *Project) -> Allocator {
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

	project: Project;
	project.folders.allocator = project_allocator(*project);
	project.ignore.allocator = project_allocator(*project);
	project.allow.allocator = project_allocator(*project);
	project.filesToOpen.allocator = project_allocator(*project);

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
				array_add(*project.folders, line);
			case .IGNORE;
				array_add(*project.ignore, line);
			case .ALLOW;
				array_add(*project.allow, line);
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
	
	// @todo: check if the file has zeroes in it
	return false;
}

project_begin_load :: () {
	// kick off async task to produce a list of files to open
	// this will use visit_files and give us back a list of files to open
	// this should scan the desired folders, and apply ignore patterns as required

	maybe_add_file_to_project_list :: (info: *File_Visit_Info, project: *Project) {
		// should we ignore a directory?
		if info.is_directory {
			if should_ignore_path(info.full_name) {
				info.descend_into_directory = false;
			}
			return;
		}

		if should_ignore_file(info.full_name) then return;
	
		log("found file short: % full: % is_dir %", info.short_name, info.full_name, info.is_directory);

		// If we're keeping a file, copy it's full_name with our allocator and store
		array_add(*project.filesToOpen, copy_string(info.full_name,,project_allocator(project)));
	}

	for project.folders {
		visit_files(it, recursive=true, *project, maybe_add_file_to_project_list, visit_directories=true);
	}
}

project_update :: (project: Project) {
	// once we have results from scanning directories on the async thread,
	// we should have an array of file paths we want to load

	// at this point we spin up the thread group on N threads
	// iterate the list of filepaths
	// add work for each file

	// get completed work from the thread group
	// for each loaded file you will need to copy it's data into the
	// real document in the open documents table
	// track the progress of the project load
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
        "yaml", "toml", "zig", "odin", "photon-project",
    ];
    for textFiles  table_add(*table, it, .TEXT);

    binaryFiles :: string.[
        "exe", "pdb", "ttf", "otf", "eot", "woff", "dll", "lib", "dylib", "so", "a", "o", "pdf",
        "jpg", "png", "gif", "jpeg", "ico", "tif", "tiff", "tga", "bmp", "webp", "mp3", "wav", "ogg",
        "wma", "blend", "blend1", "obj", "fbx", "dae", "3ds", "dat", "msh2", "mpg", "mpeg", "psd", "codex",
        "webm", "zip", "rar", "7z", "bin", "sys", "iso", "nib", "exp", "pyc", "rpyc", "DS_Store", "dmg",
    ];
    for binaryFiles  table_add(*table, it, .BINARY);

    return table;
}
