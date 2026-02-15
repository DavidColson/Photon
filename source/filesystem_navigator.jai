
FilesystemNavigator :: struct {
	memory : Flat_Pool;

	saveMode: bool;
	currentPath: [..]string;
	itemList: [..]Item;
	selectedItem:s64;
	selectedItemChanged:bool;
	numToDisplay:s64; // number of items with positive sortkeys
	input: InputField;

	Item :: struct {
		name: string;
		sortKey: s64;
		saveItem: bool;
		isDirectory: bool;
		fuzzyMatches: []Highlight;
	}
}

filesystem_nav_open :: (state: *FilesystemNavigator, saveMode := false, initialLocation := "") {
	state.input.onEditCallback = filesystem_nav_input_field_on_edit;
	state.input.userData = state;
	state.saveMode = saveMode;

	path := split(initialLocation, "\\",,temp);
	if initialLocation.count > 0 {
		for path {
			pathSection := copy_string(it,,get_allocator(state));
			array_add(*state.currentPath, pathSection,, get_allocator(state));
		}
	}
	filesystem_nav_refresh_directory_list(state);
	editorMode = .DIALOG;
}

filesystem_nav_reset :: (using panel: *Panel) {
	using panel.filesystemNav;
	saveMode = false;
	numToDisplay = 0;
	array_reset(*currentPath);
	array_reset(*itemList);
	#if BUILD_TYPE == BuildType.DEBUG {
		reset(*memory, overwrite_memory=true);
	} else {
		reset(*memory, overwrite_memory=false);
	}
	// input field manages it's own memory
	input_field_reset_keeping_memory(*input);
	panel.activeDialog = .NONE;
}

filesystem_nav_input_field_on_edit :: (userData: *void, input: string) {
	state := cast(*FilesystemNavigator) userData;
	if state.saveMode && input.count > 0 && (input[input.count-1] == #char "/" || input[input.count-1] == #char "\\") {
		dirName := copy_string(string.{input.count-1, input.data},,get_allocator(state));
		array_add(*state.currentPath, dirName,, get_allocator(state));
		filesystem_nav_refresh_directory_list(state);
		input_field_reset_keeping_memory(*state.input);
	}
	filesystem_nav_filter_directory_list(state);
}

filesystem_nav_select_next :: (using panel: *Panel, args: []string) {
	state := *filesystemNav;
	maxItems := state.numToDisplay - 1;
	state.selectedItem = clamp(state.selectedItem+1, 0, xx maxItems);
	state.selectedItemChanged = true;
}

filesystem_nav_select_previous :: (using panel: *Panel, args: []string) {
	state := *filesystemNav;
	maxItems := state.numToDisplay - 1;
	state.selectedItem = clamp(state.selectedItem-1, 0, xx maxItems);
	state.selectedItemChanged = true;
}

filesystem_nav_action_item :: (using panel: *Panel, args: []string) {
	state := *filesystemNav;

	item := state.itemList[state.selectedItem];
	if item.saveItem {
		// save item, we need to save this file
		fileName := copy_string(input_field_get_text(*state.input),,get_allocator(state));
		array_add(*state.currentPath, fileName,, get_allocator(state));
		document_save(panel.document, make_path_from_strings(state.currentPath,,temp));
		editorMode = .NORMAL;
		filesystem_nav_reset(panel);
	}
	else {
		array_add(*state.currentPath, item.name,, get_allocator(state));

		// normal case, add path element to list and refresh
		if platform_is_path_directory(make_path_from_strings(state.currentPath,,temp)) {
			filesystem_nav_refresh_directory_list(state);
			input_field_reset_keeping_memory(*state.input);
		}
		// item is a file, open it
		else {
			doc := document_get_or_open(make_path_from_strings(state.currentPath,,temp));
			panel_set_active_document(panel, doc);
			editorMode = .NORMAL;
			filesystem_nav_reset(panel);
		}
	}
}

filesystem_nav_delete_item :: (using panel: *Panel, args: []string) {
	state := *filesystemNav;
	// This actually won't work because a letter is consumed by the text input for this widget
	// unless you made a submode, something to think about when we get here
	print("Not implemented, delete item");
}

filesystem_nav_rename_move_item :: (using panel: *Panel, args: []string) {
	state := *filesystemNav;
	print("Not implemented, rename/move item");
}

filesystem_nav_refresh_directory_list :: (state: *FilesystemNavigator) {
	state.numToDisplay = 0;
	array_reset_keeping_memory(*state.itemList);
	path := make_path_from_strings(state.currentPath,,temp);

	// start with drives
	if state.currentPath.count == 0 {
		// @todo, at some point it should use the project directory maybe, or the current file
		for platform_enumerate_logical_drives() {
			item := array_add(*state.itemList,,get_allocator(state));
			item.name = copy_string(it,,get_allocator(state));
			item.sortKey = 1;
			item.isDirectory=true;
			state.numToDisplay += 1;
		}
	} else if file_exists(path) {
		visitor :: (info: *File_Visit_Info, state: *FilesystemNavigator) {
			newItem: FilesystemNavigator.Item;
			newItem.name = copy_string(info.short_name,,get_allocator(state));
			newItem.sortKey = 1;
			newItem.isDirectory = info.is_directory;
			array_add(*state.itemList, newItem,,get_allocator(state));
		}
		visit_files(path, false, state, visitor, visit_directories=true);
		state.numToDisplay = state.itemList.count;
	}

	if state.saveMode {
		item := array_add(*state.itemList,,get_allocator(state));
		item.sortKey = 1;
		item.saveItem = true;
	}

	maxItems := state.itemList.count - 1;
	state.selectedItem = clamp(state.selectedItem, 0, xx maxItems);
}

filesystem_nav_filter_directory_list :: (state: *FilesystemNavigator) {
	state.numToDisplay = 0;
	search_query:= input_field_get_text(*state.input);
	for * item: state.itemList {
		if !item.saveItem {
			item.sortKey, item.fuzzyMatches = fuzzy_search(item.name, search_query,,get_allocator(state));
		}
		else {
			// save item special case
			if state.currentPath.count > 0 && state.input.text.count > 0 {
				item.sortKey = 1;
			}
			else {
				item.sortKey = 0;
			}
		}

		if item.sortKey > 0 {
			state.numToDisplay += 1;
		}
	}

	compare_entries :: (e1: FilesystemNavigator.Item, e2: FilesystemNavigator.Item) -> s64 {
		diff := e2.sortKey - e1.sortKey;
		if diff != 0 return diff;
		// todo: should also sort on other things like folder or file etc
		return memcmp(e1.name.data, e2.name.data, min(e1.name.count, e2.name.count));
	}
	quick_sort(state.itemList, compare_entries);

	maxItem := state.itemList.count - 1;
	state.selectedItem = clamp(state.selectedItem-1, 0, xx maxItem);
}

#scope_file

get_allocator :: (state: *FilesystemNavigator) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.memory };
}

make_path_from_strings :: (strings: []string) -> string {
    builder: String_Builder;
    init_string_builder(*builder);

    for strings {
        append(*builder, it);
		if (it_index != strings.count-1)  append(*builder, "/");
    }
    
    return builder_to_string(*builder);
}

