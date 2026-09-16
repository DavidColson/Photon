FileFinder :: struct {
	memory : Flat_Pool;

	FileEntry :: struct {
		filePath: string;
		loaded : bool;
		handle: DocumentHandle;
		sortKey: s64;
		fuzzyMatchesFile: []Highlight;
		fuzzyMatchesPath: []Highlight;
	}
	fileList: [..]FileEntry;
	selectedEntry:s32;
	selectedEntryChanged:bool;
	numToDisplay:s32;
	input: InputField;
}

file_finder_open :: (using panel: *Panel) {
	NORMAL :: CommandConfig.{ prettyName = "Open file finder" };
	panel.activeDialog = .FILE_FINDER;
	editorMode = .DIALOG;

	// Collect open documents
	for doc: openDocuments {
		recencyBonus := calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
		entry := array_add(*fileFinder.fileList);
		entry.filePath = document_get_path(doc);
		entry.loaded = true;
		entry.handle = doc;
		entry.sortKey = 10 + recencyBonus;
		fileFinder.numToDisplay += 1;
	}

	if project_is_loaded() {
		for * file: project.projectFiles {
			if file.tombstoned then continue; // gone from disk, only its memory is still here
			entry := array_add(*fileFinder.fileList);
			entry.filePath = file.fullName;
			entry.loaded = false;
			entry.handle = .{locator = file.locator};
			entry.sortKey = 10 + calculate_edit_recency_bonus(file.diskLastModtime);
			fileFinder.numToDisplay += 1;
		}
	}

	quick_sort(fileFinder.fileList, compare_entries);
	
	fileFinder.input.onEditCallback = file_finder_input_field_on_edit;
	fileFinder.input.userData = *fileFinder;
} @command

compare_entries :: (e1: FileFinder.FileEntry, e2: FileFinder.FileEntry) -> s64 {
	diff := e2.sortKey - e1.sortKey;
	if diff != 0 return diff;
	return memcmp(e1.filePath.data, e2.filePath.data, min(e1.filePath.count, e2.filePath.count));
}

file_finder_input_field_on_edit :: (userData: *void, input: string) {
	finder: *FileFinder = cast(*FileFinder) userData;
	finder.numToDisplay = 0;
	array_reset_keeping_memory(*finder.fileList);
	
	#if BUILD_TYPE == BuildType.DEBUG {
		reset(*finder.memory, overwrite_memory=true);
	} else {
		reset(*finder.memory, overwrite_memory=false);
	}

	for doc: openDocuments {
		// @todo: at some point you probably want to search the whole path for matches
		// need better UI to show the filepath
		filePath := document_get_path(doc);
		scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(filePath), input,,get_allocator(finder));
		scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(filePath), input,,get_allocator(finder));
		score := scoreFile + scorePath/5;
		recencyBonus := calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
		
		if score > 0 {
			entry := array_add(*finder.fileList);
			entry.filePath = filePath;
			entry.loaded = true;
			entry.handle = doc;
			entry.sortKey = score + recencyBonus;
			entry.fuzzyMatchesFile = fuzzyMatchesFile;
			entry.fuzzyMatchesPath = fuzzyMatchesPath;
			finder.numToDisplay += 1;
		}
	}

	if project_is_loaded() {
		for * file: project.projectFiles {
			if file.tombstoned then continue; // gone from disk, only its memory is still here
			filePath := file.fullName;
			scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(filePath), input,,get_allocator(finder));
			scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(filePath), input,,get_allocator(finder));
			score := scoreFile + scorePath/5;
			
			if score > 0 {
				entry := array_add(*finder.fileList);
				recencyBonus := calculate_edit_recency_bonus(file.diskLastModtime);
				entry.filePath = file.fullName;
				entry.loaded = false;
				entry.handle = .{locator = file.locator};
				entry.sortKey = score + calculate_edit_recency_bonus(file.diskLastModtime);
				entry.fuzzyMatchesFile = fuzzyMatchesFile;
				entry.fuzzyMatchesPath = fuzzyMatchesPath;
				finder.numToDisplay += 1;
			}
		}
	}

	quick_sort(finder.fileList, compare_entries);

	maxItems := finder.fileList.count - 1;
	finder.selectedEntry = clamp(finder.selectedEntry-1, 0, xx maxItems);
}

file_finder_reset :: (panel: *Panel) {
	finder := *panel.fileFinder;
	finder.selectedEntry = 0;
	finder.numToDisplay = 0;
	array_reset(*finder.fileList);
	#if BUILD_TYPE == BuildType.DEBUG {
		reset(*finder.memory, overwrite_memory=true);
	} else {
		reset(*finder.memory, overwrite_memory=false);
	}
	input_field_reset_keeping_memory(*finder.input);
	panel.activeDialog = .NONE;
}

file_finder_select_file :: (panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	finder := *panel.fileFinder;
	entry := finder.fileList[finder.selectedEntry];
	if entry.loaded {
		panel_set_active_document(panel, entry.handle);
	}
	else {
		// the list was built when the dialog opened, so the file may have been deleted since
		projectFile := bucket_array_find_pointer(*project.projectFiles, entry.handle.locator);
		if projectFile == null || projectFile.tombstoned {
			push_notification("File Does Not Exist");
			file_finder_reset(panel);
			editorMode = .NORMAL;
			return;
		}
		doc := document_get_or_open(finder.fileList[finder.selectedEntry].filePath, noLoad = true);
		document_load_from_project(doc, projectFile);
		panel_set_active_document(panel, doc);
	}
	file_finder_reset(panel);
	editorMode = .NORMAL;
} @command

file_finder_select_next :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	finder := *panel.fileFinder;

	maxEntry := finder.fileList.count - 1;
	finder.selectedEntry = clamp(finder.selectedEntry+1, 0, xx maxEntry);
	finder.selectedEntryChanged = true;
} @command

file_finder_select_previous :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	finder := *panel.fileFinder;

	maxEntry := finder.fileList.count - 1;
	finder.selectedEntry = clamp(finder.selectedEntry-1, 0, xx maxEntry);
	finder.selectedEntryChanged = true;
} @command

#scope_file

get_allocator :: (state: *FileFinder) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.memory };
}
