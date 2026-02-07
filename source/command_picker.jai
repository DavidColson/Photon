CommandPicker :: struct {
	memory : Flat_Pool;

	CommandEntry :: struct {
		command: *Command;
		// right now this is just the search score, but i'd like to add
		// the last use time of the command, or how often it's used
		sortKey: s64;
		fuzzyMatches: []Highlight;
	}
	filteredCommandList: [..]CommandEntry;
	selectedCommand:s32;
	selectedCommandChange:bool;
	numToDisplay:s64; // number of items with positive sortkeys
	input: InputField;
}

command_picker_open :: (using panel: *Panel, args: []string) {
	panel.activeDialog = .COMMAND_PICKER;
	editorMode = .DIALOG;

    push_allocator(flat_pool_allocator_proc, *commandPicker.memory);

	for command: normalModeCommands {
		if !(command.flags & .HIDDEN) {
			entry := array_add(*commandPicker.filteredCommandList);
			entry.command = *command;
			entry.sortKey = 10;
			commandPicker.numToDisplay += 1;
		}
	}

	commandPicker.input.onEditCallback = command_picker_input_field_on_edit;
	commandPicker.input.userData = *commandPicker;
}

command_picker_input_field_on_edit :: (userData: *void, input: string) {
	state: *CommandPicker = cast(*CommandPicker) userData;

	state.numToDisplay = 0;
    push_allocator(flat_pool_allocator_proc, *state.memory);

	array_reset_keeping_memory(*state.filteredCommandList);

	for command: normalModeCommands {
		if !(command.flags & .HIDDEN) {
			score,fuzzyMatches := fuzzy_search(command.name, input);
			entry := array_add(*state.filteredCommandList);
			entry.fuzzyMatches = fuzzyMatches;
			entry.command = *command;
			entry.sortKey = score;
			if entry.sortKey > 0 {
				state.numToDisplay += 1;
			}
		}
	}

	compare_entries :: (e1: CommandPicker.CommandEntry, e2: CommandPicker.CommandEntry) -> s64 {
		diff := e2.sortKey - e1.sortKey;
		if diff != 0 return diff;
		return memcmp(e1.command.name.data, e2.command.name.data, min(e1.command.name.count, e2.command.name.count));
	}
	quick_sort(state.filteredCommandList, compare_entries);

	maxCommand := state.filteredCommandList.count - 1;
	state.selectedCommand = clamp(state.selectedCommand-1, 0, xx maxCommand);
}

command_picker_reset :: (panel: *Panel) {
	using panel.commandPicker;
	selectedCommand = 0;
	numToDisplay = 0;
	array_reset(*filteredCommandList);
	#if BUILD_TYPE == BuildType.DEBUG {
		reset(*memory, overwrite_memory=true);
	} else {
		reset(*memory, overwrite_memory=false);
	}
	// input field manages it's own memory
	input_field_reset_keeping_memory(*input);
	panel.activeDialog = .NONE;
}

command_picker_execute_command :: (using panel: *Panel, args: []string) {
	state := *commandPicker;

	cmd := state.filteredCommandList[state.selectedCommand].command; 

	// reset before executing the command, incase the command opens a dialog
	command_picker_reset(panel);
	editorMode = .NORMAL;

	cmd.execute(panel, string.[]); // @todo: command picker can't give arguments yet? Needs this ability
}

command_picker_select_next :: (using panel: *Panel, args: []string) {
	state := *commandPicker;

	maxItems := state.numToDisplay - 1;
	state.selectedCommand = clamp(state.selectedCommand+1, 0, xx maxItems);
	state.selectedCommandChange = true;
}

command_picker_select_previous :: (using panel: *Panel, args: []string) {
	state := *commandPicker;

	maxItems := state.numToDisplay - 1;
	state.selectedCommand = clamp(state.selectedCommand-1, 0, xx maxItems);
	state.selectedCommandChange = true;
}
