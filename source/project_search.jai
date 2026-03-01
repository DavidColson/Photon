ProjectSearch :: struct {
	memory : Flat_Pool;

	results: [..]SearchResult;

	selectedEntry:s32;
	selectedEntryChanged:bool;
	numToDisplay:s32;
	input: InputField;
}

project_search_open :: (using panel: *Panel, args: []string) {
	panel.activeDialog = .PROJECT_SEARCH;
	editorMode = .DIALOG;

	projectSearcher.numToDisplay = 0;
	projectSearcher.selectedEntry = 0;
	projectSearcher.selectedEntryChanged = false;

	projectSearcher.results.allocator = get_allocator(*projectSearcher);

	projectSearcher.input.onEditCallback = project_search_input_field_on_edit;
	projectSearcher.input.userData = *projectSearcher;
}

SearchResult :: struct {
	matchLine: string;
	lineNum: s64;
	filePath: string;
	matchRange: Document.Range;
}

project_search_input_field_on_edit :: (userData: *void, input: string) {
	searcher: *ProjectSearch = cast(*ProjectSearch) userData;

	array_reset_keeping_memory(*searcher.results);

	for * project.projectFiles {
		searchCursor := 0;
		while searchCursor < it.content.count && searcher.results.count < 2000 {
			result := find_index_from_left_nocase_fast(it.content, input, searchCursor);
			if result > 0 {
				// found match
				// for each result we need to binary search the list of line starts for the file
				low := 0; // line 0
				high := it.lineStarts.count-1; // max line
				mid := 0;
				midStartOffset := 0;
				midEndOffset := 0;
				while low <= high {
					mid = low + ((high - low) / 2);
					midStartOffset = it.lineStarts[mid];

					if mid == high
						break;

					midEndOffset = it.lineStarts[mid+1];

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
				searchResult: SearchResult; 
				searchResult.matchLine = .{ midEndOffset - midStartOffset, it.content.data + midStartOffset };
				searchResult.lineNum = mid;
				searchResult.filePath = it.fullName;
				searchResult.matchRange = .{result - midStartOffset, (result - midStartOffset) + input.count};
				array_add(*searcher.results, searchResult);

				searchCursor = result + input.count;
			}
			else {
				searchCursor = it.content.count; // end the search
			}
		}
	}

	searcher.numToDisplay = xx searcher.results.count;
	searcher.selectedEntry = 0;
	searcher.selectedEntryChanged = false;

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
