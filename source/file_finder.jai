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

file_finder_open :: (using panel: *Panel, args: []string) {
	panel.activeDialog = .FILE_FINDER;
	editorMode = .DIALOG;

	// Collect open documents
	for doc: openDocuments {
		entry := array_add(*fileFinder.fileList);
		entry.filePath = document_get_path(doc);
		entry.loaded = true;
		entry.handle = doc;
		entry.sortKey = 10 + calculate_recency_bonus(document_get_disk_last_modtime(doc));
		fileFinder.numToDisplay += 1;
	}

	if project.loadProgress == .COMPLETE {
		for * file: project.projectFiles {
			entry := array_add(*fileFinder.fileList);
			entry.filePath = file.fullName;
			entry.loaded = false;
			entry.handle = .{locator = file.locator};
			entry.sortKey = 10 + calculate_recency_bonus(file.diskLastModtime);
			fileFinder.numToDisplay += 1;
		}
	}

	quick_sort(fileFinder.fileList, compare_entries);
	
	fileFinder.input.onEditCallback = file_finder_input_field_on_edit;
	fileFinder.input.userData = *fileFinder;
}

calculate_recency_bonus :: (modtime: Apollo_Time) -> s64 {
	fileAge := to_float64_seconds(current_time_consensus() - modtime);
	// this is an exponential decay that ensures all files get some kind of recency bonus
	// and the recency bonus decays out to zero for every file, so there is no "window"
	// The 0.9998 value is picked such that files you've touched over the last 4-5 hours have meaningful values
	// to sort, so you can expect a sensible ordering for your last day of work
	normalized := clamp(pow(0.9998, fileAge), 0.0, 1.0);
	return cast(s64, normalized * 4000);
}

compare_entries :: (e1: FileFinder.FileEntry, e2: FileFinder.FileEntry) -> s64 {
	diff := e2.sortKey - e1.sortKey;
	if diff != 0 return diff;
	return memcmp(e1.filePath.data, e2.filePath.data, min(e1.filePath.count, e2.filePath.count));
}

file_finder_input_field_on_edit :: (userData: *void, input: string) {
	finder: *FileFinder = cast(*FileFinder) userData;
	finder.numToDisplay = 0;
	array_reset_keeping_memory(*finder.fileList);

	for doc: openDocuments {
		// @todo: at some point you probably want to search the whole path for matches
		// need better UI to show the filepath
		filePath := document_get_path(doc);
		scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(filePath), input,,get_allocator(finder));
		scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(filePath), input,,get_allocator(finder));
		score := scoreFile + scorePath/5;
		
		if score > 0 {
			entry := array_add(*finder.fileList);
			entry.filePath = filePath;
			entry.loaded = true;
			entry.handle = doc;
			entry.sortKey = score + calculate_recency_bonus(document_get_disk_last_modtime(doc));
			entry.fuzzyMatchesFile = fuzzyMatchesFile;
			entry.fuzzyMatchesPath = fuzzyMatchesPath;
			finder.numToDisplay += 1;
		}
	}

	if project.loadProgress == .COMPLETE {
		for * file: project.projectFiles {
			filePath := file.fullName;
			scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(filePath), input,,get_allocator(finder));
			scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(filePath), input,,get_allocator(finder));
			score := scoreFile + scorePath/5;
			
			if score > 0 {
				entry := array_add(*finder.fileList);
				entry.filePath = file.fullName;
				entry.loaded = false;
				entry.handle = .{locator = file.locator};
				entry.sortKey = score + calculate_recency_bonus(file.diskLastModtime);
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

file_finder_select_file :: (panel: *Panel, args: []string) {
	finder := *panel.fileFinder;
	entry := finder.fileList[finder.selectedEntry];
	if entry.loaded {
		panel_set_active_document(panel, entry.handle);
	}
	else {
		doc := document_get_or_open(finder.fileList[finder.selectedEntry].filePath, noLoad = true);
		projectFile:= bucket_array_find_pointer(*project.projectFiles, entry.handle.locator);
		document_load_from_project(doc, projectFile);
		panel_set_active_document(panel, doc);
	}
	file_finder_reset(panel);
	editorMode = .NORMAL;
}

file_finder_select_next :: (using panel: *Panel) {
	finder := *panel.fileFinder;

	maxEntry := finder.fileList.count - 1;
	finder.selectedEntry = clamp(finder.selectedEntry+1, 0, xx maxEntry);
	finder.selectedEntryChanged = true;
}

file_finder_select_previous :: (using panel: *Panel) {
	finder := *panel.fileFinder;

	maxEntry := finder.fileList.count - 1;
	finder.selectedEntry = clamp(finder.selectedEntry-1, 0, xx maxEntry);
	finder.selectedEntryChanged = true;
}

#scope_file

get_allocator :: (state: *FileFinder) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.memory };
}
