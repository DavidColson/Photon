CommandPicker :: struct {
	
	// two memory lifetimes in use in this tool
	// one for the duration of a full use of the tool (i.e., opening the picker window, through to calling a command or closing the tool)
	// one for every single run of a search (more or less each keypress)
	perInvocationMem : Flat_Pool;
	perSearchMem : Flat_Pool;

	// CommandEntry :: struct {
		// command: *Command;
		// // right now this is just the search score, but i'd like to add
		// // the last use time of the command, or how often it's used
		// sortKey: s64;
		// fuzzyMatches: []Highlight;
	// }
	// filteredCommandList: [..]CommandEntry;
	// selectedCommand:s32;
	// selectedCommandChange:bool;
	input: InputField;
	
	
	
	
	// New stuff
	pendingCommand: *Command;
	argList: [..]string;
	
	fuzzySearchResultMemory : Flat_Pool;
	Suggestion :: struct {
		name: string;
		sortKey: s64;
		fuzzyMatches: []Highlight;
		userData: *void;
	}
	numToDisplay:s64; // number of items with positive sortkeys
	suggestionList: [..]Suggestion;
	selection: s32;
	selectionChange: bool;
	editorModeFilter: EditorMode;
}

TestEnum :: enum {
	FIRST_VALUE;
	SECOND_VALUE;
}

get_enum_pretty_names :: (enumType: *Type_Info_Enum) -> []string {
	if enumType == type_info(TestEnum) {
		return .[ "First Value", "Second Value" ];
	}
	else {
		return enumType.names;
	}
}

command_picker_open :: (using panel: *Panel) {
	NORMAL :: CommandConfig.{ prettyName = "Open Command Picker", keybinding = .[":"] };
	panel.activeDialog = .COMMAND_PICKER;
	commandPicker.editorModeFilter = editorMode;
	editorMode = .DIALOG;
	
	commandPicker.argList.allocator = get_per_invocation_allocator(*commandPicker);
	commandPicker.suggestionList.allocator = get_per_invocation_allocator(*commandPicker);

	command_picker_populate_suggestions(*commandPicker);
	
	commandPicker.input.onEditCallback = command_picker_input_field_on_edit;
	commandPicker.input.userData = *commandPicker;
} @command

command_picker_populate_suggestions :: (using picker: *CommandPicker) {
	// fill out a list of items for the suggestions based on what mode we're in
	// by default we fill it out from the command list
	// If we're in pending command mode, figure out which argument is current
	// and then provide suggestions based on the type
	
	if pendingCommand == null {
		// default mode, suggestions will be a list of commands
		for * command: allCommands[editorModeFilter] {
			if !(command.flags & .HIDDEN) {
				suggestion := array_add(*suggestionList);
				suggestion.sortKey = 10;
				suggestion.name = command.prettyName;
				suggestion.userData = command;
				numToDisplay += 1;
			}
		}
	}
	else {
		// show suggestions based on the current commands pending argument
		pendingArgument := argList.count;
		
		// if pendingCommand.args[pendingArgument].type == {
		// case type_info(bool);
		// }
	}
	
	// how do we populate suggestions for enums? We need a pretty name getter for enums
	// and we need a generic way to get them
	// Ultimately it's just a little array of strings, but need to register them somehow
}

command_picker_filter_and_sort_suggestions :: (using picker: *CommandPicker, filter: string) {
	// Go through all the suggestions doing a fuzzy search on it
	// and applying any score modifiers that are relevant, count how many are included in the results 
	
	reset(*perSearchMem);
	
	numToDisplay = 0;
	for * suggestion: suggestionList {
		score,fuzzyMatches := fuzzy_search(suggestion.name, filter,,get_per_search_allocator(picker));
		
		suggestion.fuzzyMatches = fuzzyMatches;
		suggestion.sortKey = score;
		if suggestion.sortKey > 0 {
			numToDisplay += 1;
		}
	}
	
	// TODO: somehow add extra sorting information for items depending on their type??
	
	compare_entries :: (e1: CommandPicker.Suggestion, e2: CommandPicker.Suggestion) -> s64 {
		diff := e2.sortKey - e1.sortKey;
		if diff != 0 return diff;
		return memcmp(e1.name.data, e2.name.data, min(e1.name.count, e2.name.count));
	}
	quick_sort(suggestionList, compare_entries);
	
	maxItems := numToDisplay - 1;
	selection = clamp(selection-1, 0, xx maxItems);
}

command_picker_input_field_on_edit :: (userData: *void, input: string) {
	state: *CommandPicker = cast(*CommandPicker) userData;
	command_picker_filter_and_sort_suggestions(state, input);
}

command_picker_reset :: (panel: *Panel) {
	using panel.commandPicker;
	selection = 0;
	numToDisplay = 0;
	
	// reset memory
	array_reset(*suggestionList);
	array_reset(*argList);
	reset(*perInvocationMem);
	reset(*perSearchMem);
	
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
		cmd := cast(*Command, state.suggestionList[state.selection].userData); 
		
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
	state.selection = clamp(state.selection+1, 0, xx maxItems);
	state.selectionChange = true;
} @command

command_picker_select_previous :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPicker;

	maxItems := state.numToDisplay - 1;
	state.selection = clamp(state.selection-1, 0, xx maxItems);
	state.selectionChange = true;
} @command

#scope_file

get_per_search_allocator :: (state: *CommandPicker) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perSearchMem };
}

get_per_invocation_allocator :: (state: *CommandPicker) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perInvocationMem };
}
