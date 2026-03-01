
ProjectSearch :: struct {
	memory : Flat_Pool;

	results: [..]Project.SearchResult;
	selectedEntry:s32;
	selectedEntryChanged:bool;
	numToDisplay:s32;
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

	#if BUILD_TYPE == BuildType.DEBUG {
		reset(*searcher.memory, overwrite_memory=true);
	} else {
		reset(*searcher.memory, overwrite_memory=false);
	}
	input_field_reset_keeping_memory(*searcher.input);
	panel.activeDialog = .NONE;
}

project_search_select_next :: (using panel: *Panel) {
	searcher := *panel.projectSearcher;
}

project_search_select_previous :: (using panel: *Panel) {
	searcher := *panel.projectSearcher;
}

#scope_file

get_allocator :: (state: *ProjectSearch) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.memory };
}
