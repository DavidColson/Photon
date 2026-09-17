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
	currentHandler: *ArgHandler;

	Suggestion :: struct {
		name: string;
		sortKey: s64;
		fuzzyMatches: []Highlight;

		// the value this suggestion resolves to, used by the default resolve (i.e. *bool for bool arguments)
		payload: *void;

		// free for arg handlers to store any extra per suggestion data they need
		userData: *void;
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
		currentHandler = *commandArgHandler;
		command_populate(palette, null);
	}
	else {
		// show suggestions based on the current commands pending argument
		pendingArgument := pendingCommand.cmd.args[currentArgIndex];
		currentHandler = get_arg_handler(pendingArgument.type);
		if currentHandler.populate {
			currentHandler.populate(palette, pendingArgument.type);
		}
	}

	command_palette_count_and_sort(palette);
}

compare_entries :: (e1: CommandPalette.Suggestion, e2: CommandPalette.Suggestion) -> s64 {
	diff := e2.sortKey - e1.sortKey;
	if diff != 0 return diff;
	return memcmp(e1.name.data, e2.name.data, min(e1.name.count, e2.name.count));
}

command_palette_filter_and_sort_suggestions :: (using palette: *CommandPalette, filter: string) {
	// The handler goes through all the suggestions doing a fuzzy search (or whatever it likes)
	// and sets the sort keys, then we count how many are included in the results

	reset(*perSearchMem);

	if currentHandler && currentHandler.populate {
		if currentHandler.filter {
			currentHandler.filter(palette, filter);
		}
		else {
			default_filter(palette, filter);
		}
	}

	command_palette_count_and_sort(palette);

	maxItems := numToDisplay - 1;
	selection = clamp(selection-1, 0, xx maxItems);
}

command_palette_count_and_sort :: (using palette: *CommandPalette) {
	numToDisplay = 0;
	for suggestionList {
		if it.sortKey > 0 then numToDisplay += 1;
	}
	quick_sort(suggestionList, compare_entries);
}

command_palette_input_field_on_edit :: (userData: *void, input: string) {
	state: *CommandPalette = cast(*CommandPalette) userData;
	command_palette_filter_and_sort_suggestions(state, input);
}

command_palette_reset :: (panel: *Panel) {
	using panel.commandPalette;
	selection = 0;
	numToDisplay = 0;
	currentHandler = null;

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
		// the argument handler turns the palette state into an actual argument

		pendingArgument := state.pendingCommand.cmd.args[state.currentArgIndex];
		argHandler := get_arg_handler(pendingArgument.type);

		result: ResolveResult;
		arg: Any;
		if argHandler.resolve {
			result, arg = argHandler.resolve(state, pendingArgument.type);
		}
		else {
			result, arg = default_resolve(state, pendingArgument.type);
		}

		if result == {
		case .REJECT;
			return;
		case .STAY;
			command_palette_populate_suggestions(state);
			return;
		case .COMMIT;
			deferred_command_set_argument(*state.pendingCommand, state.currentArgIndex, arg);
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
		cmd := cast(*Command, state.suggestionList[state.selection].payload);

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

// Argument handlers define how the command palette gathers a single command argument of a given type
// Custom struct types used as command arguments name their handler in a note, i.e.
// MyArg :: struct @command_arg(myArgHandler) { ... }
// where myArgHandler is a global ArgHandler variable
ArgHandler :: struct {

	// This function should fill out the suggestions list of the command palette
	// setting the sortKey of the suggestions, anything with a positive sortKey will be shown
	// if not given, no suggestion list is shown, and you must provide resolve
	populate:		(palette: *CommandPalette, argType: *Type_Info);

	// This function should set the sortKeys of the suggestions using the given filter string
	// it can optionally also trigger another populate if desired
	// this is optional a default fuzzy search on the suggestion name will be used if not given
	filter:			(palette: *CommandPalette, filter: string);

	// This should resolve the current state of the command palette (i.e. selected suggestion, input text)
	// Into an actual argument to give to a command
	// the argument should live in per invocation memory
	// return reject if the input is not a valid argument
	// return stay if the argument was valid but you won't progress to the next argument
	// return commit to validate a correct argument
	// this is optional, if not given the payload of the selected suggestion is used
	resolve:		(palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any;

	// This will be called while the UI is being constructed, it will be expected to draw
	// the UI for a single entry in the suggestion list, inside the entry's box
	// this is optional, if not given the suggestion name is drawn with fuzzy highlights
	drawSuggestion:	(palette: *CommandPalette, suggestion: *CommandPalette.Suggestion, index: int, selected: bool);

	// how high is a suggestion in the UI
	rowHeightLines: s32 = 2;
}

ResolveResult :: enum { REJECT; STAY; COMMIT; }

// Filled out by the metaprogram for all @command_arg struct types used by commands
argHandlerTable: Table(*Type_Info, *ArgHandler);

get_arg_handler :: (t: *Type_Info) -> *ArgHandler {
	// if the argument is a u8, I've aribrarily decided it should be treated as a char
	// this may come back to bite me, but there we go
	if t == type_info(u8) return *charArgHandler;

	if t.type == {
	case .BOOL;    return *boolArgHandler;
	case .INTEGER; return *integerArgHandler;
	case .FLOAT;   return *floatArgHandler;
	case .STRING;  return *stringArgHandler;
	case .ENUM;    return *enumArgHandler;
	case .STRUCT;
		found, handler := table_find(*argHandlerTable, t);
		if found return handler;
	}

	assert(false, "No argument handler found for type %", t.type);
	return null;
}

// Defaults used when an arg handler doesn't provide a function

default_filter :: (using palette: *CommandPalette, filter: string) {
	for * suggestion: suggestionList {
		score, fuzzyMatches := fuzzy_search(suggestion.name, filter,,get_per_search_allocator(palette));
		suggestion.fuzzyMatches = fuzzyMatches;
		suggestion.sortKey = score;
	}
}

default_resolve :: (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any {
	if !command_palette_has_valid_selection(palette) return .REJECT, Any.{};
	return .COMMIT, Any.{argType, palette.suggestionList[palette.selection].payload};
}

default_draw_suggestion :: (palette: *CommandPalette, suggestion: *CommandPalette.Suggestion, index: int, selected: bool) {
	suggestionLabel := box(ui_key("%##%", suggestion.name, index), .{
		flags=.DRAW_TEXT_HIGHLIGHTS,
		layout=.{ width=text_content(), height=text_content() },
	});
	suggestionLabel.textHighlights = suggestion.fuzzyMatches;

	box(ui_key_nil, .{ layout=.{width=grow()}});
}

// commands (the list of commands shown before a command has been picked)

commandArgHandler := ArgHandler.{
	populate = command_populate,
	drawSuggestion = command_draw_suggestion,
};

command_populate :: (using palette: *CommandPalette, argType: *Type_Info) {
	for * command: allCommands[editorModeFilter] {
		if !(command.flags & .HIDDEN) {
			suggestion := array_add(*suggestionList);
			suggestion.sortKey = 10;
			suggestion.name = command.prettyName;
			suggestion.payload = command;
		}
	}
}

command_draw_suggestion :: (palette: *CommandPalette, suggestion: *CommandPalette.Suggestion, index: int, selected: bool) {
	// find the normal mode mapping
	// @todo: should we show bindings for all modes?
	command := cast(*Command, suggestion.payload);
	mappingStr := "";
	for command.keybinding {
		// TODO
		// if it.mode == .NORMAL then mappingStr = it;
		mappingStr = it;
	}

	commandLabel := box(ui_key("%##%", suggestion.name, index), .{
		flags=.DRAW_TEXT_HIGHLIGHTS,
		layout=.{ width=text_content(), height=text_content() },
	});
	commandLabel.textHighlights = suggestion.fuzzyMatches;

	box(ui_key_nil, .{ layout=.{width=grow()}});

	if mappingStr {
		box(ui_key("%##%", mappingStr, index), .{
			flags=.DRAW_TEXT | .DRAW_BACKGROUND,
			layout=.{ width=text_content(), height=text_content() },
			palette=.{ background=style.backgroundMid },
			textPadding=em(0.3)
		});
	}
}

// booleans

boolArgHandler := ArgHandler.{
	populate = bool_populate,
};

bool_populate :: (using palette: *CommandPalette, argType: *Type_Info) {
	suggestionTrue := array_add(*suggestionList);
	suggestionTrue.sortKey = 10;
	suggestionTrue.name = "true";
	valueTrue := New(bool,,get_per_invocation_allocator(palette));
	valueTrue.* = true;
	suggestionTrue.payload = valueTrue;

	suggestionFalse := array_add(*suggestionList);
	suggestionFalse.sortKey = 10;
	suggestionFalse.name = "false";
	valueFalse := New(bool,,get_per_invocation_allocator(palette));
	valueFalse.* = false;
	suggestionFalse.payload = valueFalse;
}

// enums

enumArgHandler := ArgHandler.{
	populate = enum_populate,
};

enum_populate :: (using palette: *CommandPalette, argType: *Type_Info) {
	enumType := cast(*Type_Info_Enum)argType;
	for get_enum_pretty_names(enumType) {
		suggestion := array_add(*suggestionList);
		suggestion.sortKey = 10;
		suggestion.name = it;
		suggestion.payload = *enumType.values[it_index];
	}
}

// strings

stringArgHandler := ArgHandler.{
	resolve = string_resolve,
};

string_resolve :: (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any {
	// string doesn't need validation
	// TODO: it probably does tbh
	value := New(string,,get_per_invocation_allocator(palette));
	value.* = string.{palette.input.text.count, palette.input.text.data};
	return .COMMIT, Any.{argType, value};
}

// floats

floatArgHandler := ArgHandler.{
	resolve = float_resolve,
};

float_resolve :: (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any {
	argStr := string.{palette.input.text.count, palette.input.text.data};
	if argType.runtime_size == 4 {
		val, success := string_to_float(argStr);
		if !success return .REJECT, Any.{};
		value := New(float32,,get_per_invocation_allocator(palette));
		value.* = val;
		return .COMMIT, Any.{argType, value};
	}
	else if argType.runtime_size == 8 {
		val, success := string_to_float64(argStr);
		if !success return .REJECT, Any.{};
		value := New(float64,,get_per_invocation_allocator(palette));
		value.* = val;
		return .COMMIT, Any.{argType, value};
	}

	assert(false, "Unsupported float argument type");
	return .REJECT, Any.{};
}

// integers

integerArgHandler := ArgHandler.{
	resolve = integer_resolve,
};

integer_resolve :: (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any {
	parse :: (palette: *CommandPalette, argStr: string, $T: Type) -> ResolveResult, Any {
		val, success := string_to_int(argStr, 10, T);
		if !success return .REJECT, Any.{};
		value := New(T,,get_per_invocation_allocator(palette));
		value.* = val;
		return .COMMIT, Any.{type_info(T), value};
	}

	argStr := string.{palette.input.text.count, palette.input.text.data};
	if argType == {
	case type_info(s8);  result, value := parse(palette, argStr, s8); return result, value;
	case type_info(u16); result, value := parse(palette, argStr, u16); return result, value;
	case type_info(s16); result, value := parse(palette, argStr, s16); return result, value;
	case type_info(u32); result, value := parse(palette, argStr, u32); return result, value;
	case type_info(s32); result, value := parse(palette, argStr, s32); return result, value;
	case type_info(u64); result, value := parse(palette, argStr, u64); return result, value;
	case type_info(s64); result, value := parse(palette, argStr, s64); return result, value;
	}

	assert(false, "Unsupported integer argument type");
	return .REJECT, Any.{};
}

// chars (u8)

charArgHandler := ArgHandler.{
	resolve = char_resolve,
};

char_resolve :: (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any {
	if palette.input.text.count != 1 return .REJECT, Any.{};
	value := New(u8,,get_per_invocation_allocator(palette));
	value.* = palette.input.text.data.*;
	return .COMMIT, Any.{argType, value};
}

// special data type representing a file
// either loaded or in the project, for the find file command

FinderFile :: struct @command_arg(finderFileArgHandler) {
	isDocument: bool;
	documentHandle: DocumentHandle;
	projectHandle: Bucket_Locator;
}

finderFileArgHandler := ArgHandler.{
	populate = finder_file_populate,
	filter = finder_file_filter,
	drawSuggestion = finder_file_draw_suggestion,
	rowHeightLines = 3,
};

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

finder_file_populate :: (using palette: *CommandPalette, argType: *Type_Info) {
	for * file: project.projectFiles {
		if file.tombstoned then continue;
		suggestion := array_add(*suggestionList);
		suggestion.name = file.fullName;
		suggestion.sortKey = 10 + calculate_edit_recency_bonus(file.diskLastModtime);
		finderFile := New(FinderFile,,get_per_invocation_allocator(palette));
		finderFile.isDocument = false;
		finderFile.projectHandle = file.locator;
		suggestion.payload = finderFile;
	}
	for doc: openDocuments {
		suggestion := array_add(*suggestionList);
		suggestion.name = document_get_path(doc);
		suggestion.sortKey = 10 + calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
		finderFile := New(FinderFile,,get_per_invocation_allocator(palette));
		finderFile.isDocument = true;
		finderFile.documentHandle = doc;
		suggestion.payload = finderFile;
	}
}

finder_file_filter :: (using palette: *CommandPalette, filter: string) {
	for * suggestion: suggestionList {
		scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(suggestion.name), filter,,get_per_search_allocator(palette));
		scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(suggestion.name), filter,,get_per_search_allocator(palette));
		score := scoreFile + scorePath/5;

		recencyBonus := 0;
		finderFile := cast(*FinderFile, suggestion.payload);
		if finderFile.isDocument {
			recencyBonus = calculate_edit_recency_bonus(document_get_disk_last_modtime(finderFile.documentHandle)) + calculate_open_recency_bonus(finderFile.documentHandle);
		}
		else {
			file := bucket_array_find_pointer(*project.projectFiles, finderFile.projectHandle);
			if file then recencyBonus = calculate_edit_recency_bonus(file.diskLastModtime);
		}

		// filename matches are stored separately so we can highlight the filename and path labels independently
		filenameMatches := New([]Highlight,,get_per_search_allocator(palette));
		filenameMatches.* = fuzzyMatchesFile;
		suggestion.userData = filenameMatches;

		suggestion.fuzzyMatches = fuzzyMatchesPath;
		suggestion.sortKey = ifx score > 0 then score + recencyBonus else 0;
	}
}

finder_file_draw_suggestion :: (palette: *CommandPalette, suggestion: *CommandPalette.Suggestion, index: int, selected: bool) {
	verticalBox := box(ui_key_nil, .{ layout=.{ width=grow(), height=grow(), childLayoutAxis=.Y }, });
	push_parent(verticalBox); defer pop_parent();

	key := ui_key("%##fileListEntryLabel%", path_filename(suggestion.name), index);
	fileLabel := box(key, .{
		flags=.DRAW_TEXT_HIGHLIGHTS,
		layout=.{ width=text_content(), height=text_content() },
	});
	if suggestion.userData then fileLabel.textHighlights = cast(*[]Highlight, suggestion.userData).*;

	key2 := ui_key("%##fileListPathLabel%", suggestion.name, index);
	pathLabel := box(key2, .{
		flags=.DRAW_TEXT_HIGHLIGHTS,
		fontSize=em(0.7),
		layout=.{ width=text_content(), height=text_content() },
	});
	pathLabel.textHighlights = suggestion.fuzzyMatches;
}

#scope_file

get_per_search_allocator :: (state: *CommandPalette) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perSearchMem };
}

get_per_invocation_allocator :: (state: *CommandPalette) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perInvocationMem };
}
