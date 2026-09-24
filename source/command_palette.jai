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

	// free for the current arg handler to keep state that lives across populates/filters
	// lives in per invocation memory, and is cleared whenever we move to another argument
	handlerData: *void;

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
		input.isPath = currentHandler.pathInput;
		command_populate(palette, null);
	}
	else {
		// show suggestions based on the current commands pending argument
		pendingArgument := pendingCommand.cmd.args[currentArgIndex];
		currentHandler = get_arg_handler(pendingArgument.type);
		input.isPath = currentHandler.pathInput;
		if currentHandler.populate {
			currentHandler.populate(palette, pendingArgument.type);
		}
	}

	command_palette_count_and_sort(palette);
}

compare_entries :: (e1: CommandPalette.Suggestion, e2: CommandPalette.Suggestion) -> s64 {
	if e1.sortKey == 0 && e2.sortKey == 0 return 0;
	
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

	if currentHandler && currentHandler.asyncFilter == false {
		command_palette_count_and_sort(palette);
		
		maxItems := numToDisplay - 1;
		selection = clamp(selection-1, 0, xx maxItems);
	}
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
	handlerData = null;
	input.isPath = false;

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
		// the next argument gets a fresh handler state
		state.handlerData = null;

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

} @command

// replaces the contents of the palette input field, putting the cursor at the end
// note this does not run the edit callback, callers are expected to repopulate themselves
command_palette_set_input_text :: (palette: *CommandPalette, text: string) {
	input := *palette.input;
	input.text.count = 0;
	for 0..text.count-1 {
		array_add(*input.text, text[it]);
	}
	input.cursor = xx input.text.count;
}

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

	// if set, the input field is treated as a path, dimming everything but the segment being edited
	// and enabling ctrl+backspace to delete a whole path segment
	pathInput: bool;
	
	// If true, sorting suggestions will be deferred until after async jobs are done
	// note you must do this manually
	asyncFilter: bool;
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

// Special argument used to create the file finder command

FinderFile :: struct @command_arg(finderFileArgHandler) {
	isDocument: bool;
	documentHandle: DocumentHandle;
	projectHandle: Bucket_Locator;
	recencyBonus: s64;
}

finderFileArgHandler := ArgHandler.{
	populate = finder_file_populate,
	filter = finder_file_filter,
	drawSuggestion = finder_file_draw_suggestion,
	rowHeightLines = 3,
};

FileFinderState :: struct {
	threadMemory: []Flat_Pool;
	initialized := false;
	
	WorkItem :: struct {
		filter: string;
		suggestionList: []CommandPalette.Suggestion;
	}
}

fileFinderState: FileFinderState;

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
	if !fileFinderState.initialized {
		fileFinderState.threadMemory = NewArray(parallel_for_pool_thread_count(*parallelPool), Flat_Pool);

		fileFinderState.initialized = true;
	}
	
	for * file: project.projectFiles {
		if file.tombstoned then continue;
		suggestion := array_add(*suggestionList);
		suggestion.name = file.fullName;
		suggestion.sortKey = 10 + calculate_edit_recency_bonus(file.diskLastModtime);
		finderFile := New(FinderFile,,get_per_invocation_allocator(palette));
		finderFile.isDocument = false;
		finderFile.projectHandle = file.locator;
		finderFile.recencyBonus = calculate_edit_recency_bonus(file.diskLastModtime);
		suggestion.payload = finderFile;
	}
	for doc: openDocuments {
		suggestion := array_add(*suggestionList);
		suggestion.name = document_get_path(doc);
		suggestion.sortKey = 10 + calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
		finderFile := New(FinderFile,,get_per_invocation_allocator(palette));
		finderFile.isDocument = true;
		finderFile.documentHandle = doc;
		finderFile.recencyBonus = calculate_edit_recency_bonus(document_get_disk_last_modtime(doc)) + calculate_open_recency_bonus(doc);
		suggestion.payload = finderFile;
	}
}

finder_file_filter :: (using palette: *CommandPalette, filter: string) {
	for fileFinderState.threadMemory {
		reset(*it);
	}
	
	// Ideal interface
	filter_suggestion :: (suggestion: *CommandPalette.Suggestion, threadIndex: s64, filter: *string) {
		push_allocator(flat_pool_allocator_proc, *fileFinderState.threadMemory[threadIndex]);
		
		// Do fuzzy searching
		scoreFile, fuzzyMatchesFile := fuzzy_search(path_filename(suggestion.name), filter.*);
		scorePath, fuzzyMatchesPath := fuzzy_search(path_strip_filename(suggestion.name), filter.*);
		score := scoreFile + scorePath/5;
		
		// Write output directly to suggestion
		// Note that we know our range of suggestions will not be touched during this work
		// as the main thread is waiting for us
		filenameMatches := New([]Highlight);
		filenameMatches.* = fuzzyMatchesFile;
		suggestion.userData = filenameMatches;
		
		fileData := cast(*FinderFile, suggestion.payload);
		suggestion.fuzzyMatches = fuzzyMatchesPath;
		suggestion.sortKey = ifx score > 0 then score + fileData.recencyBonus else 0;
	}
	parallel_for(*parallelPool, suggestionList, *filter, filter_suggestion);
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

// Filepath argument used for all the commands that require file browsing
// of some kind, very customizable

FilePath :: struct {
	path: string;
	// false when the path doesn't exist yet, i.e. the user asked us to create it
	exists: bool;
}

// the variations only differ in where they start the path off, so they all name the same handler
// and the behaviour that does differ is looked up from the argument type in path_arg_config
SystemPath      :: struct @command_arg(pathArgHandler) { using base: FilePath; }
WorkingDirPath  :: struct @command_arg(pathArgHandler) { using base: FilePath; }
ProjectPath     :: struct @command_arg(pathArgHandler) { using base: FilePath; }
DocumentDirPath :: struct @command_arg(pathArgHandler) { using base: FilePath; }

// path_commit writes the value through a *FilePath, so the variations must all be laid out like one
#assert size_of(SystemPath) == size_of(FilePath);
#assert size_of(WorkingDirPath) == size_of(FilePath);
#assert size_of(ProjectPath) == size_of(FilePath);
#assert size_of(DocumentDirPath) == size_of(FilePath);

pathArgHandler := ArgHandler.{ populate = path_populate, filter = path_filter, resolve = path_resolve, drawSuggestion = path_draw_suggestion, pathInput = true };

PathArgConfig :: struct {
	start: enum { SYSTEM; WORKING_DIR; PROJECT; DOCUMENT_DIR; };
	createLabel := "Create";
	createAtTop := false;
}

path_arg_config :: (argType: *Type_Info) -> PathArgConfig {
	if argType == type_info(WorkingDirPath)  return .{ start = .WORKING_DIR };
	if argType == type_info(ProjectPath)     return .{ start = .PROJECT };
	if argType == type_info(DocumentDirPath) return .{ start = .DOCUMENT_DIR, createLabel = "Save as", createAtTop = true };
	return .{ start = .SYSTEM };
}

PathArgEntry :: struct {
	Kind :: enum { FILE; DIRECTORY; DRIVE; PROJECT_FOLDER; CREATE; }
	kind: Kind;
	// what the input field becomes when this entry is picked
	fullPath: string;
}

// comfortably above any fuzzy search score, but nowhere near overflowing a subtraction of two keys
CREATE_ENTRY_TOP_SORT_KEY :: 1_000_000_000;

PathArgState :: struct {
	argType: *Type_Info;
	config: PathArgConfig;
	// the directory the current suggestion list was built from, so we know when to rebuild it
	listedDir: string;
}

path_populate :: (using palette: *CommandPalette, argType: *Type_Info) {
	
	path_seed_input :: (palette: *CommandPalette, config: PathArgConfig) {
		if palette.input.text.count > 0 then return;
		
		start: string;
		if config.start == {
		case .WORKING_DIR;
			start = path_normalized(get_working_directory(),,temp);
		case .PROJECT;
			// with several folders we show them as a list instead, so there's nothing to seed
			if project.folders.count == 1 then start = path_normalized(project.folders[0],,temp);
		case .DOCUMENT_DIR;
			if palette.pendingCommand.panel {
				documentPath := document_get_path(palette.pendingCommand.panel.document);
				if documentPath then start = path_normalized(path_strip_filename(documentPath),,temp);
			}
		}
		
		if start then command_palette_set_input_text(palette, tprint("%/", start));
	}
	
	state := cast(*PathArgState, handlerData);
	if !state {
		state = New(PathArgState,,get_per_invocation_allocator(palette));
		state.argType = argType;
		state.config = path_arg_config(argType);
		handlerData = state;
		path_seed_input(palette, state.config);
	}

	text := input_field_get_text(*input);
	dir := path_strip_filename(text);
	
	path_add_suggestion :: (using palette: *CommandPalette, name: string, kind: PathArgEntry.Kind, fullPath: string) {
		suggestion := array_add(*suggestionList);
		suggestion.name = name;
		suggestion.sortKey = 10;
		
		entry := New(PathArgEntry,,get_per_invocation_allocator(palette));
		entry.kind = kind;
		entry.fullPath = copy_string(fullPath,,get_per_invocation_allocator(palette));
		suggestion.userData = entry;
	}

	if !dir {
		// at the very top of the path there is no real directory to list, so we show
		// the project folders if there's a choice to make, and the drives otherwise
		if state.config.start == .PROJECT && project.folders.count > 1 {
			for project.folders {
				folder := path_normalized(it,,get_per_invocation_allocator(palette));
				path_add_suggestion(palette, folder, .PROJECT_FOLDER, tprint("%/", folder));
			}
		}
		else {
			for platform_enumerate_logical_drives() {
				drive := copy_string(it,,get_per_invocation_allocator(palette));
				path_add_suggestion(palette, drive, .DRIVE, tprint("%/", drive));
			}
		}
	}
	else {
		visitor :: (info: *File_Visit_Info, palette: *CommandPalette) {
			name := copy_string(info.short_name,,get_per_invocation_allocator(palette));
			directory := path_strip_filename(input_field_get_text(*palette.input));
			if info.is_directory {
				path_add_suggestion(palette, name, .DIRECTORY, tprint("%1%2/", directory, name));
			}
			else {
				path_add_suggestion(palette, name, .FILE, tprint("%1%2", directory, name));
			}
		}
		if platform_is_path_directory(dir) {
			visit_files(dir, false, palette, visitor, visit_directories=true);
		}

		// the create entry is always in the list, the filter decides whether it's actually shown
		path_add_suggestion(palette, "", .CREATE, "");
	}

	state.listedDir = copy_string(dir,,get_per_invocation_allocator(palette));
	selection = 0;

	path_filter(palette, text);
}

path_filter :: (using palette: *CommandPalette, filter: string) {
	state := cast(*PathArgState, handlerData);
	if !state return;

	dir := path_strip_filename(filter);
	leaf := path_filename(filter);

	if !platform_path_equal(dir, state.listedDir) {
		// the user moved to another directory, by typing a separator, pasting a path
		// or deleting a segment, so the whole list needs rebuilding
		array_reset(*suggestionList);
		path_populate(palette, state.argType);
		return;
	}

	leafAlreadyExists := false;
	for * suggestion: suggestionList {
		entry := cast(*PathArgEntry, suggestion.userData);
		if entry.kind == .CREATE then continue;

		if platform_path_equal(suggestion.name, leaf) then leafAlreadyExists = true;

		score, fuzzyMatches := fuzzy_search(suggestion.name, leaf,,get_per_search_allocator(palette));
		suggestion.fuzzyMatches = fuzzyMatches;
		// with nothing typed everything scores the same, so nudge directories above files
		suggestion.sortKey = max(score, 0) + ifx leaf.count == 0 && entry.kind != .FILE then 1 else 0;
	}

	for * suggestion: suggestionList {
		entry := cast(*PathArgEntry, suggestion.userData);
		if entry.kind != .CREATE then continue;

		if leaf.count > 0 && dir.count > 0 && !leafAlreadyExists {
			// deliberately not S64_MAX, the sort compares entries by subtracting their keys
			// and that would overflow
			suggestion.sortKey = ifx state.config.createAtTop then CREATE_ENTRY_TOP_SORT_KEY else 1;
		}
		else {
			suggestion.sortKey = 0;
		}
	}
}

path_resolve :: (palette: *CommandPalette, argType: *Type_Info) -> ResolveResult, Any {
	text := input_field_get_text(*palette.input);

	path_commit :: (palette: *CommandPalette, argType: *Type_Info, path: string, exists: bool) -> ResolveResult, Any {
		value := alloc(argType.runtime_size,,get_per_invocation_allocator(palette));
		filePath := cast(*FilePath, value);
		filePath.path = copy_string(path,,get_per_invocation_allocator(palette));
		path_overwrite_separators(filePath.path, #char "/");
		filePath.exists = exists;
		return .COMMIT, Any.{argType, value};
	}
	
	if command_palette_has_valid_selection(palette) {
		suggestion := palette.suggestionList[palette.selection];
		entry := cast(*PathArgEntry, suggestion.userData);
		if entry.kind == {
		case .CREATE;
			result, value := path_commit(palette, argType, text, false); return result, value;
		case .FILE;
			result, value := path_commit(palette, argType, entry.fullPath, true); return result, value;
		case;
			// directories, drives and project folders take us one level deeper instead of committing
			command_palette_set_input_text(palette, entry.fullPath);
			return .STAY, Any.{};
		}
	}

	// nothing in the list is selected, so all we have to go on is the typed path
	exists, isDirectory := platform_path_stat(text);
	if exists && !isDirectory {
		result, value := path_commit(palette, argType, text, true); return result, value;
	}
	if exists {
		command_palette_set_input_text(palette, tprint("%/", trim_right(text, "/\\")));
		return .STAY, Any.{};
	}
	return .REJECT, Any.{};
}

path_draw_suggestion :: (palette: *CommandPalette, suggestion: *CommandPalette.Suggestion, index: int, selected: bool) {
	entry := cast(*PathArgEntry, suggestion.userData);

	if entry.kind == .CREATE {
		state := cast(*PathArgState, palette.handlerData);
		label := tprint("% %", state.config.createLabel, input_field_get_text(*palette.input));
		box(ui_key("%##pathCreateEntry%", label, index), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});
		return;
	}

	isDirectory := entry.kind != .FILE;
	box(ui_key("%##pathEntryIcon%", ifx isDirectory then style.iconFolder else style.iconFile, index), .{
		flags=.DRAW_TEXT,
		layout=.{ width=text_content(), height=text_content() },
		font=fontIcons
	});

	itemLabel := box(ui_key("%##pathEntryLabel%", suggestion.name, index), .{
		flags=.DRAW_TEXT_HIGHLIGHTS,
		layout=.{ width=text_content(), height=text_content() },
	});
	itemLabel.textHighlights = suggestion.fuzzyMatches;
}

#scope_file

get_per_search_allocator :: (state: *CommandPalette) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perSearchMem };
}

get_per_invocation_allocator :: (state: *CommandPalette) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *state.perInvocationMem };
}
