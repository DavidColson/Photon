CommandPalette :: struct {
	
	// two memory lifetimes in use in this tool
	// one for the duration of a full use of the tool (i.e., opening the palette window, through to calling a command or closing the tool)
	// one for every single run of a search (more or less each keypress)
	perInvocationMem : Flat_Pool;
	perSearchMem : Flat_Pool;
	input: InputField;
	
	// stuff for pending command mode
	pendingCommandMode := false;
	pendingCommand: DeferredCommand;
	currentArgIndex := 0;
	currentArgSuggestionKind: SuggestionKind;
	
	SuggestionKind :: enum {
		NONE;
		NORMAL;
		COMMAND;
		FINDER_FILE;
	}
	Suggestion :: struct {
		name: string;
		sortKey: s64;
		fuzzyMatches: []Highlight;
		userData: *void;
		
		// Specialized members used by the FINDER_FILE kind
		isDocument: bool;
		filenameFuzzyMatches: []Highlight;
	}
	
	numToDisplay:s64; // number of items with positive sortkeys
	suggestionList: [..]Suggestion;
	selection: s32;
	selectionChange: bool;
	editorModeFilter: EditorMode;
}

command_palette_open :: (using panel: *Panel) {
	NORMAL :: CommandConfig.{ prettyName = "Open Command Palette", keybinding = .[":"] };
	panel.activeDialog = .COMMAND_PALETTE;
	commandPalette.editorModeFilter = editorMode;
	editorMode = .DIALOG;
	
	commandPalette.suggestionList.allocator = get_per_invocation_allocator(*commandPalette);

	command_palette_populate_suggestions(*commandPalette);
	
	commandPalette.input.onEditCallback = command_palette_input_field_on_edit;
	commandPalette.input.userData = *commandPalette;
} @command

command_palette_populate_suggestions :: (using palette: *CommandPalette) {
	array_reset(*suggestionList);
	numToDisplay = 0;
	
	if pendingCommandMode == false {
		// default mode, suggestions will be a list of commands
		currentArgSuggestionKind = .COMMAND;
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
		pendingArgument := pendingCommand.cmd.args[currentArgIndex];
		if pendingArgument.type.type == {
			
		case .BOOL;
			currentArgSuggestionKind = .NORMAL;
			suggestionTrue := array_add(*suggestionList);
			suggestionTrue.sortKey = 10;
			suggestionTrue.name = "true";
			numToDisplay += 1;
			
			suggestionFalse := array_add(*suggestionList);
			suggestionFalse.sortKey = 10;
			suggestionFalse.name = "false";
			numToDisplay += 1;
			
		case .ENUM;
			currentArgSuggestionKind = .NORMAL;
			enumType := cast(*Type_Info_Enum)pendingArgument.type;
			for get_enum_pretty_names(enumType) {
				suggestion := array_add(*suggestionList);
				suggestion.sortKey = 10;
				suggestion.name = enumType.names[it_index];
				suggestion.userData = *enumType.values[it_index];
				numToDisplay += 1;
			}
			
		case .STRUCT;
			structTypeInfo := cast(*Type_Info_Struct, pendingArgument.type);
			if structTypeInfo.name == "FinderFile" {
				// file finder suggestions
				currentArgSuggestionKind = .FINDER_FILE;
				
				for * file: project.projectFiles {
					if file.tombstoned then continue;
					suggestion := array_add(*suggestionList);
					suggestion.name = file.fullName;
					suggestion.sortKey = 10 + calculate_edit_recency_bonus(file.diskLastModtime);
					suggestion.userData = New(Bucket_Locator,,get_per_invocation_allocator(palette));
					memcpy(suggestion.userData, *file.locator, size_of(Bucket_Locator));
					suggestion.isDocument = false;
					numToDisplay += 1;
				}
				for doc: openDocuments {
					suggestion := array_add(*suggestionList);
					suggestion.name = document_get_path(doc);
					suggestion.sortKey = 10 + calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
					docHandleCopy := New(DocumentHandle,,get_per_invocation_allocator(palette));
					docHandleCopy.* = doc;
					suggestion.userData = docHandleCopy;
					suggestion.isDocument = true;
					numToDisplay += 1;
				}
			}
			
		case;
			// all other types don't have suggestions
			currentArgSuggestionKind = .NONE;
		}
	}
	
	quick_sort(suggestionList, compare_entries);
}

calculate_open_recency_bonus :: (document: DocumentHandle) -> s64 {
	found, lastOpenTime := table_find(*fileOpenRecency, document);
	if found {
		timeSinceLastOpen := to_float64_seconds(current_time_consensus() - lastOpenTime);
		normalized := clamp(pow(0.9995, timeSinceLastOpen), 0.0, 1.0);
		return cast(s64, normalized * 16000);
	}
	return 0;
}

calculate_edit_recency_bonus :: (modtime: Apollo_Time) -> s64 {
	fileAge := to_float64_seconds(current_time_consensus() - modtime);
	// this is an exponential decay that ensures all files get some kind of recency bonus
	// and the recency bonus decays out to zero for every file, so there is no "window"
	// The 0.9998 value is picked such that files you've touched over the last 4-5 hours have meaningful values
	// to sort, so you can expect a sensible ordering for your last day of work
	normalized := clamp(pow(0.9998, fileAge), 0.0, 1.0);
	return cast(s64, normalized * 12000);
}

compare_entries :: (e1: CommandPalette.Suggestion, e2: CommandPalette.Suggestion) -> s64 {
	diff := e2.sortKey - e1.sortKey;
	if diff != 0 return diff;
	return memcmp(e1.name.data, e2.name.data, min(e1.name.count, e2.name.count));
}

command_palette_filter_and_sort_suggestions :: (using palette: *CommandPalette, filter: string) {
	// Go through all the suggestions doing a fuzzy search on it
	// and applying any score modifiers that are relevant, count how many are included in the results 
	
	reset(*perSearchMem);
	
	if currentArgSuggestionKind == {
	case .NORMAL; #through;
	case .COMMAND;
		numToDisplay = 0;
		for * suggestion: suggestionList {
			score,fuzzyMatches := fuzzy_search(suggestion.name, filter,,get_per_search_allocator(palette));
			
			suggestion.fuzzyMatches = fuzzyMatches;
			suggestion.sortKey = score;
			if suggestion.sortKey > 0 {
				numToDisplay += 1;
			}
		}
	case .FINDER_FILE;
		numToDisplay = 0;
		for * suggestion: suggestionList {
			scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(suggestion.name), filter,,get_per_search_allocator(palette));
			scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(suggestion.name), filter,,get_per_search_allocator(palette));
			score := scoreFile + scorePath/5;
			recencyBonus := 0;
			if suggestion.isDocument {
				doc := cast(*DocumentHandle, suggestion.userData);
				recencyBonus = calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
			}
			else {
				file := cast(*Project.File, suggestion.userData);
				recencyBonus = calculate_edit_recency_bonus(file.diskLastModtime);
			}
			
			suggestion.fuzzyMatches = fuzzyMatchesPath;
			suggestion.filenameFuzzyMatches = fuzzyMatchesFile;
			suggestion.sortKey = score + recencyBonus;
			if suggestion.sortKey > 0 {
				numToDisplay += 1;
			}
		}
		
	}
	
	quick_sort(suggestionList, compare_entries);
	
	maxItems := numToDisplay - 1;
	selection = clamp(selection-1, 0, xx maxItems);
}

command_palette_input_field_on_edit :: (userData: *void, input: string) {
	state: *CommandPalette = cast(*CommandPalette) userData;
	command_palette_filter_and_sort_suggestions(state, input);
}

command_palette_reset :: (panel: *Panel) {
	using panel.commandPalette;
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

command_palette_has_valid_selection :: (state: *CommandPalette) -> bool {
	return state.selection >= 0 && state.selection < state.numToDisplay && state.selection < state.suggestionList.count;
}

// Used when the dialog is dismissed without a command having run to completion
command_palette_cancel :: (panel: *Panel) {
	using panel.commandPalette;
	cancel_deferred_command(*pendingCommand);
	pendingCommandMode = false;
	currentArgIndex = 0;
	command_palette_reset(panel);
}

command_palette_execute_command :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPalette;
	
	if state.pendingCommandMode {
		// In this branch we are waiting for arguments
		// we switch on the expected argument type
		
		pendingArgument := state.pendingCommand.cmd.args[state.currentArgIndex];
		if pendingArgument.type.type == {
		case .BOOL;
			if !command_palette_has_valid_selection(state) then return;
			if state.suggestionList[state.selection].name == "true" {
				deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, true);
			}
			else {
				deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, false);
			}
			
		case .STRING;
			// string doesn't need validation
			// TODO: it probably does tbh
			deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, string.{state.input.text.count, state.input.text.data});
			
		case .FLOAT;
			argStr := string.{state.input.text.count, state.input.text.data};
			if pendingArgument.type.runtime_size == 4 {
				val, success := string_to_float(argStr);
				if !success then return;
				deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
			}
			else if pendingArgument.type.runtime_size == 8 {
				val, success := string_to_float64(argStr);
				if !success then return;
				deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
			}
			else {
				assert(false, "Unsupported float argument type");
				return;
			}

		case .INTEGER;
			if pendingArgument.type == type_info(u8) {
				// if the integer is a u8, I've aribrarily decided it should be treated as a char
				// this may come back to bite me, but there we go
				if state.input.text.count != 1 return;
				deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, state.input.text.data.*);
			}
			else {

				argStr := string.{state.input.text.count, state.input.text.data};
				if pendingArgument.type == {
				case type_info(s8);
					val, success := string_to_int(argStr, 10, s8);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case type_info(u16);
					val, success := string_to_int(argStr, 10, u16);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case type_info(s16);
					val, success := string_to_int(argStr, 10, s16);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case type_info(u32);
					val, success := string_to_int(argStr, 10, u32);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case type_info(s32);
					val, success := string_to_int(argStr, 10, s32);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case type_info(u64);
					val, success := string_to_int(argStr, 10, u64);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case type_info(s64);
					val, success := string_to_int(argStr, 10, s64);
					if !success then return;
					deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, val);
				case;
					assert(false, "Unsupported integer argument type");
					return;
				}
			}

		case .ENUM;
			if !command_palette_has_valid_selection(state) then return;
			deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, Any.{pendingArgument.type, state.suggestionList[state.selection].userData});

		case .STRUCT;
			structTypeInfo := cast(*Type_Info_Struct, pendingArgument.type);
			if structTypeInfo.name == "FinderFile" {
				if !command_palette_has_valid_selection(state) then return;
				chosenFile := state.suggestionList[state.selection];
				
				arg: FinderFile;
				arg.isDocument = chosenFile.isDocument;
				if chosenFile.isDocument {
					arg.documentHandle = cast(*DocumentHandle, chosenFile.userData).*;
				}
				else {
					arg.projectHandle = cast(*Bucket_Locator, chosenFile.userData);
				}
				deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, arg);
			}
			else {
				assert(false, "Unsupported struct argument type");
				return;
			}
		case;
			assert(false, "Invalid argument type given");
			return;
		}

		state.currentArgIndex += 1;

		// we now have enough arguments to actually invoke the command
		if state.currentArgIndex == state.pendingCommand.cmd.args.count {
			command := state.pendingCommand;
			state.pendingCommand = .{};
			state.pendingCommandMode = false;
			state.currentArgIndex = 0;

			// reset before executing the command, incase the command opens a dialog
			command_palette_reset(panel);
			editorMode = .NORMAL;
			deferred_command_invoke(*command);
		}
		else {
			input_field_reset_keeping_memory(*state.input);
			command_palette_populate_suggestions(*commandPalette);
		}
	}
	else {
		// In this branch we haven't picked what command we want to execute yet, so 
		// here we do just that

		if !command_palette_has_valid_selection(state) then return;
		cmd := cast(*Command, state.suggestionList[state.selection].userData); 
		
		// if it requires no args, just execute it now
		if cmd.args.count == 0 {
			// reset before executing the command, incase the command opens a dialog
			command_palette_reset(panel);
			editorMode = .NORMAL;
			
			cmd.wrapper(panel, .[]);
		}
		else {
			// We need commands, so enter pending command mode
			state.pendingCommandMode = true;
			cancel_deferred_command(*state.pendingCommand);
			state.pendingCommand = create_deferred_command(cmd, panel);
			state.currentArgIndex = 0;
			input_field_reset_keeping_memory(*state.input);
			command_palette_populate_suggestions(*commandPalette);
		}
	}

	// TODO: if the command has arguments
	// then you want to enter a new mode where we are pending arguments
	// you will store the current pending command
	// and you will have an array of strings for the arguments as they get filled out
	// the whole command palette goes into a new mode
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

command_palette_select_next :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPalette;

	maxItems := state.numToDisplay - 1;
	state.selection = clamp(state.selection+1, 0, xx maxItems);
	state.selectionChange = true;
} @command

command_palette_select_previous :: (using panel: *Panel) {
	DIALOG :: CommandConfig.{ };
	state := *commandPalette;

	maxItems := state.numToDisplay - 1;
	state.selection = clamp(state.selection-1, 0, xx maxItems);
	state.selectionChange = true;
} @command

get_enum_pretty_names :: (enumType: *Type_Info_Enum) -> []string {
	// Put in here overrides for enums that you want to have pretty visual names
	return enumType.names;
}

// proposed interface for argument handlers (such as FinderFile or Path)
/*
ArgHandler :: struct {
	populate:   (palette: *CommandPalette, argType: *Type_Info);
	filter:     (palette: *CommandPalette, filter: string);           // may repopulate (Path)
	resolve:    (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any; // this should return the resolved argument in palette invocation memory, it will be copied to the pending command afterward
	backspace:  (palette: *CommandPalette) -> handled: bool;          // optional (Path segment delete)
	rowHeightLines: s32 = 2;                                          // drawing hint
	kind: SuggestionKind;                                             // drawing hint for main.jai
}
ResolveResult :: enum { REJECT; STAY; COMMIT; }
get_arg_handler :: (t: *Type_Info) -> *ArgHandler
*/
	
#scope_file

get_per_search_allocator :: (state: *CommandPalette) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perSearchMem };
}

get_per_invocation_allocator :: (state: *CommandPalette) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perInvocationMem };
}
