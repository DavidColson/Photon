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
	editorModeFilter: EditorMode;
	
	// New stuff
	pendingCommand: *Command;
	argList: [..]string;
}

command_picker_open :: (using panel: *Panel) {
	NORMAL :: CommandConfig.{ prettyName = "Open Command Picker", keybinding = .[":"] };
	panel.activeDialog = .COMMAND_PICKER;
	commandPicker.editorModeFilter = editorMode;
	editorMode = .DIALOG;

    push_allocator(flat_pool_allocator_proc, *commandPicker.memory);

	for command: allCommands[commandPicker.editorModeFilter] {
		if !(command.flags & .HIDDEN) {
			entry := array_add(*commandPicker.filteredCommandList);
			entry.command = *command;
			entry.sortKey = 10;
			commandPicker.numToDisplay += 1;
		}
	}

	commandPicker.input.onEditCallback = command_picker_input_field_on_edit;
	commandPicker.input.userData = *commandPicker;
} @command

command_picker_input_field_on_edit :: (userData: *void, input: string) {
	state: *CommandPicker = cast(*CommandPicker) userData;

	state.numToDisplay = 0;
    push_allocator(flat_pool_allocator_proc, *state.memory);

	array_reset_keeping_memory(*state.filteredCommandList);

	for command: allCommands[state.editorModeFilter] {
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

command_picker_execute_command :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPicker;
	
	if state.pendingCommand {
		// we require an argument, so take whatever the current text is in the input field
		// and place that in as an argument
		
		arg := copy_string(string.{state.input.text.count, state.input.text.data});
		array_add(*state.argList, arg);
		
		// we now have enough arguments to actually invoke the command
		if state.argList.count == state.pendingCommand.args.count {
			// reset before executing the command, incase the command opens a dialog
			command_picker_reset(panel);
			editorMode = .NORMAL;
			
			execute_command(panel, state.pendingCommand, state.argList);
			
			for state.argList {
				free(it);
			}
			array_reset(*state.argList);
		}
		else {
			input_field_reset_keeping_memory(*state.input);
		}
	}
	else {
		cmd := state.filteredCommandList[state.selectedCommand].command; 
		
		// if it requires no args, just execute it now
		if cmd.args.count == 0 {
			// reset before executing the command, incase the command opens a dialog
			command_picker_reset(panel);
			editorMode = .NORMAL;
			
			execute_command(panel, cmd, .[]);
		}
		else {
			// We need commands, so enter pending command mode
			state.pendingCommand = cmd;
			input_field_reset_keeping_memory(*state.input);
		}
	}

	// TODO: if the command has arguments
	// then you want to enter a new mode where we are pending arguments
	// you will store the current pending command
	// and you will have an array of strings for the arguments as they get filled out
	// the whole command picker goes into a new mode
	// which changes how it renders
	
	// when in pending command mode, the UI will draw the command's prettyname in a box
	// and then the fuzzy find will be populated with options based on the type of the argument
	
	// I feel like we need to make the whole fuzzy find functionality much more generic here
	
	// so maybe we should start there
	// what do we actually need for a fuzzy search
	// we need an array of strings of items to show
	// we need the score value for the item
	// and I guess we might need some userdata for the item so it can be retrieved
	
	// when we're in pending command mode, the relevant places will populated the suggestions list based on the type of the argument
	
	// we need really a function like "populate_suggestions" and "filter_and_sort_suggestions", we can branch on the type
	
	// how to handle path arguments?
	// Paths will be strings like anything else, but they'll have some special editing features
	// They're simply rendered as text, but with a highlight for the final segments, similar to file pilot
	// The populate_suggestions box will read the _current_ path string, and populate based on that path string 
	// (minus the final text after the last separator which will be used for sorting)
	// When we're editing a path ctrl backspace will delete the whole last path segment
	// enter, or tab, when the path is not a valid file, will populate the next path segment with what is selected, rather than actuall commit the argument
	

} @command

command_picker_select_next :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPicker;

	maxItems := state.numToDisplay - 1;
	state.selectedCommand = clamp(state.selectedCommand+1, 0, xx maxItems);
	state.selectedCommandChange = true;
} @command

command_picker_select_previous :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPicker;

	maxItems := state.numToDisplay - 1;
	state.selectedCommand = clamp(state.selectedCommand-1, 0, xx maxItems);
	state.selectedCommandChange = true;
} @command
