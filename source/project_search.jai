ProjectSearch :: struct {
	memory : Flat_Pool;

	selectedEntry:s32;
	selectedEntryChanged:bool;
	numToDisplay:s32;
	input: InputField;
}

project_search_open :: (using panel: *Panel, args: []string) {
	panel.activeDialog = .PROJECT_SEARCH;
	editorMode = .DIALOG;

	// dummy data
	projectSearcher.numToDisplay = 4;
	projectSearcher.selectedEntry = 0;
	projectSearcher.selectedEntryChanged = false;

	projectSearcher.input.onEditCallback = project_search_input_field_on_edit;
	projectSearcher.input.userData = *projectSearcher;
}

project_search_input_field_on_edit :: (userData: *void, input: string) {
	searcher: *ProjectSearch = cast(*ProjectSearch) userData;
	// dummy data
	searcher.numToDisplay = 4;
	searcher.selectedEntry = 0;
	searcher.selectedEntryChanged = false;

	// what do we even need to do here then?
	// Essentially loop through the whole project file list
	// doing find_index_of using the search term from input
	// for each result we need to binary search the list of line starts for the file
	// to find the start and end byte
	// and then create a string view that represents the matching line
	// and an offset into that line
	// store that string view, filename and offset into an array
	// sorting??
	// the array will then be used to draw the UI

	// the thread group will be given a file, or list of files per work item
	// and it will produce an array of results, already with line strings and offsets
}

project_search_reset :: (panel: *Panel) {
	searcher := *panel.projectSearcher;
	searcher.selectedEntry = 0;
	searcher.numToDisplay = 0;

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
