CommandPicker :: struct {
	
	// two memory lifetimes in use in this tool
	// one for the duration of a full use of the tool (i.e., opening the picker window, through to calling a command or closing the tool)
	// one for every single run of a search (more or less each keypress)
	perInvocationMem : Flat_Pool;
	perSearchMem : Flat_Pool;
	input: InputField;
	pendingCommand: *Command;
	// TODO: argList memory is handled differently because it must exist during command invocation
	// I don't particularly like this, we should refactor this to be nicer and clean up
	// the memory properly
	argList: [..]string;
	
	fuzzySearchResultMemory : Flat_Pool;
	Suggestion :: struct {
		name: string;
		sortKey: s64;
		fuzzyMatches: []Highlight;
		userData: *void;
		DisplayMode :: enum {
			NORMAL;
			COMMAND;
		}
		displayMode: DisplayMode;
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
	array_reset(*suggestionList);
	numToDisplay = 0;
	
	if pendingCommand == null {
		// default mode, suggestions will be a list of commands
		for * command: allCommands[editorModeFilter] {
			if !(command.flags & .HIDDEN) {
				suggestion := array_add(*suggestionList);
				suggestion.sortKey = 10;
				suggestion.name = command.prettyName;
				suggestion.userData = command;
				suggestion.displayMode = .COMMAND;
				numToDisplay += 1;
			}
		}
	}
	else {
		// show suggestions based on the current commands pending argument
		pendingArgument := argList.count;
		
		if pendingCommand.args[pendingArgument].type.type == {
		case .BOOL;
			suggestionTrue := array_add(*suggestionList);
			suggestionTrue.sortKey = 10;
			suggestionTrue.name = "true";
			numToDisplay += 1;
			
			suggestionFalse := array_add(*suggestionList);
			suggestionFalse.sortKey = 10;
			suggestionFalse.name = "false";
			numToDisplay += 1;
		case .ENUM;
			enumType := cast(*Type_Info_Enum)pendingCommand.args[pendingArgument].type;
			for get_enum_pretty_names(enumType) {
				suggestion := array_add(*suggestionList);
				suggestion.sortKey = 10;
				suggestion.name = enumType.names[it_index];
				suggestion.userData = *enumType.values[it_index];
				numToDisplay += 1;
			}
		case;
			// all other types don't have suggestions
		}
	}
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
	// note we don't reset the arg list, this must be done after a command is executed
	// so the arguments are usable by the command
	array_reset(*suggestionList);
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
		// In this branch we are waiting for arguments
		// we switch on the expected argument type
		
		pendingArgument := state.argList.count;
		if state.pendingCommand.args[pendingArgument].type.type == {
		case .BOOL;
			if state.selection < 0 then return; // Invalid selection
			arg := copy_string(state.suggestionList[state.selection].name);
			array_add(*state.argList, arg);
			
		case .STRING;
			// string doesn't need validation
			// TODO: it probably does tbh
			arg := copy_string(string.{state.input.text.count, state.input.text.data});
			array_add(*state.argList, arg);
			
		case .FLOAT;
			// Theoretically wasteful as we convert to float again later
			// but it's probably fine tbh, validation is useful
			argStr := string.{state.input.text.count, state.input.text.data};
			_, success := string_to_float64(argStr);
			if !success then return;
			arg := copy_string(string.{state.input.text.count, state.input.text.data});
			array_add(*state.argList, arg);
			
		case .INTEGER;
			if state.pendingCommand.args[pendingArgument].type.runtime_size == 1 {
				// if the integer is a u8, I've aribrarily decided it should be treated as a char
				// this may come back to bite me, but there we go
				// we convert the char to a string of that number, which is a bit ick tbh
				if state.input.text.count > 1 return;
				array_add(*state.argList, sprint("%", state.input.text.data.*));
			}
			else {
				argStr := string.{state.input.text.count, state.input.text.data};
				_, success := string_to_int(argStr);
				if !success then return;
				arg := copy_string(string.{state.input.text.count, state.input.text.data});
				array_add(*state.argList, arg);
			}
			
		case .ENUM;
			if state.selection < 0 then return; // Invalid selection
			arg := copy_string(state.suggestionList[state.selection].name);
			array_add(*state.argList, arg);
			
		case;
			assert(false, "Invalid argument type given");
		}
		
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
			state.pendingCommand = null;
		}
		else {
			input_field_reset_keeping_memory(*state.input);
			command_picker_populate_suggestions(*commandPicker);
		}
	}
	else {
		// In this branch we haven't picked what command we want to execute yet, so 
		// here we do just that
		
		cmd := cast(*Command, state.suggestionList[state.selection].userData); 
		
		// if it requires no args, just execute it now
		if cmd.args.count == 0 {
			// reset before executing the command, incase the command opens a dialog
			command_picker_reset(panel);
			editorMode = .NORMAL;
			
			execute_command(panel, cmd, .[]);
			
			for state.argList {
				free(it);
			}
			array_reset(*state.argList);
		}
		else {
			// We need commands, so enter pending command mode
			state.pendingCommand = cmd;
			input_field_reset_keeping_memory(*state.input);
			command_picker_populate_suggestions(*commandPicker);
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
