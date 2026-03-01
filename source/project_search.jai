
ProjectSearch :: struct {
	memory : Flat_Pool;

	results: [..]Project.SearchResult;
	selectedEntry:s32;
	selectedEntryChanged:bool;
	input: InputField;

}

project_search_open :: (using panel: *Panel, args: []string) {
	panel.activeDialog = .PROJECT_SEARCH;
	editorMode = .DIALOG;

	projectSearcher.selectedEntry = 0;
	projectSearcher.selectedEntryChanged = false;

	projectSearcher.results.allocator = get_allocator(*projectSearcher);

	projectSearcher.input.onEditCallback = project_search_input_field_on_edit;
	projectSearcher.input.userData = *projectSearcher;
}

project_search_input_field_on_edit :: (userData: *void, input: string) {
	searcher: *ProjectSearch = cast(*ProjectSearch) userData;

	array_reset_keeping_memory(*searcher.results);

	// each job will get one bucket

	for project.projectFiles.all_buckets {
		workItem := New(Project.SearchWork);
		workItem.bucketIndex  = it_index;
		workItem.searchTerm = copy_string(input);
		add_work(*project.searchThreads, workItem, tprint("Search task %", workItem.bucketIndex));
	}

	searcher.selectedEntry = 0;
	searcher.selectedEntryChanged = false;
}

project_search_reset :: (panel: *Panel) {
	searcher := *panel.projectSearcher;
	searcher.selectedEntry = 0;

	array_reset(*searcher.results);
	#if BUILD_TYPE == BuildType.DEBUG {
		reset(*searcher.memory, overwrite_memory=true);
	} else {
		reset(*searcher.memory, overwrite_memory=false);
	}
	input_field_reset_keeping_memory(*searcher.input);
	panel.activeDialog = .NONE;
}

project_search_open_result :: (using panel: *Panel) {
	searcher := *panel.projectSearcher;
	
	result := searcher.results[searcher.selectedEntry];
	
	// open project file
	doc := document_get_or_open(result.filePath, noLoad = true);
	projectFile := bucket_array_find_pointer(*project.projectFiles, result.fileLocator);
	document_load_from_project(doc, projectFile);
	panel_set_active_document(panel, doc);

	panel.cursor.head = result.lineOffset + result.matchRange.end;
	panel.cursor.anchor = result.lineOffset + result.matchRange.start;

	// force set the initial scroll such that the result is in the center of the view
	startVisibleLine, range := panel_calculate_visible_lines(panel);
	panel_scroll_to_line(panel, result.lineNum-range/2);

	project_search_reset(panel);
	editorMode = .NORMAL;
}

project_search_select_next :: (using panel: *Panel) {
	searcher := *panel.projectSearcher;

	maxEntry := searcher.results.count - 1;
	searcher.selectedEntry = clamp(searcher.selectedEntry+1, 0, xx maxEntry);
	searcher.selectedEntryChanged = true;
}

project_search_select_previous :: (using panel: *Panel) {
	searcher := *panel.projectSearcher;

	maxEntry := searcher.results.count - 1;
	searcher.selectedEntry = clamp(searcher.selectedEntry-1, 0, xx maxEntry);
	searcher.selectedEntryChanged = true;
}

#scope_file

get_allocator :: (state: *ProjectSearch) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.memory };
}
