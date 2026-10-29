// The editor mode is our current input state, each mode has it's own keymap
// Commands bind to a mode by declaring a CommandConfig constant named after the mode
EditorMode :: enum u8 {
	NORMAL;
	INSERT;
	COMMAND_PALETTE;
	SEARCH;
	SELECT;
	SPLIT;
}

Notification :: struct {
	content: string;
	timer: float64;
}

// Editor specific styling, extending the UI's base style
editorStyle : struct {
	using #as base: UIStyle;

	codeFont := string.["CaskaydiaMonoNerdFont-Regular.ttf", "consola.ttf"]; // first one that loads is used
	
	commandPaletteCornerRadius := 0.5;
	commandPalettePadding := 0.4;
}

// Editor specific colours, extending the UI's base palette
editorColours : struct {
	using #as base: UIColours;

	windowBackground := #run hex_to_color_vec4("1C1F25");
	headerBackground := #run hex_to_color_vec4("3B414C");
	searchBarBackground := #run hex_to_color_vec4("3B414C");
	notificationBackground := #run hex_to_color_vec4("7e90bd");
	notificationText := #run hex_to_color_vec4("282C34");
	gutterText := #run hex_to_color_vec4("5C6370");
	textSelection := #run hex_to_color_vec4("434d60");
	searchMatch := #run hex_to_color_vec4("8c262e");

	// Code colors
	// Must match the order of HighlightType
	codeDefault := #run hex_to_color_vec4("C3C7D0");
	codeFunction := #run hex_to_color_vec4("61AFEF");
	codeKeyword := #run hex_to_color_vec4("E06C75");
	codeVariable := #run hex_to_color_vec4("C3C7D0");
	codeConstant := #run hex_to_color_vec4("56B6C2");
	codeString := #run hex_to_color_vec4("98C379");
	codeType := #run hex_to_color_vec4("E5C07B");
	codeNamespace := #run hex_to_color_vec4("E5C07B");
	codeComment := #run hex_to_color_vec4("5C6370");
	#overlay (codeDefault) codeColors: [HighlightType.COUNT]Vector4 = ---;
}

// Glyphs in the icon font
Icons :: struct {
	verticalEllipsis :: #run to_string(*convert_utf32_to_utf8(0xf142));
	circle :: #run to_string(*convert_utf32_to_utf8(0xf111));
	lock :: #run to_string(*convert_utf32_to_utf8(0xf023));
	numList :: #run to_string(*convert_utf32_to_utf8(0xf0cb));
	alignLeft :: #run to_string(*convert_utf32_to_utf8(0xf036));
	folder :: #run to_string(*convert_utf32_to_utf8(0xf07c));
	file :: #run to_string(*convert_utf32_to_utf8(0xf15b));
	spinner :: #run to_string(*convert_utf32_to_utf8(0xf110));
}

EDITOR_MODE_NUM :: #run enum_highest_value(EditorMode) + 1;

// globals
editorMode := EditorMode.NORMAL;
focusedPanel : Panel;
window: Window_Type;
windowWidth  : s32 = 1920;
windowHeight : s32 = 1080;
dpiScale := 1.0;
pendingQuit := false;
backupSaveTimer:float64 = 300;
requestRedraw := true;
deltaTime:float64 = 0.016;
lastTime:float64 = 0.0;
asyncWorker: Async;
logger: LoggerData;
startTime: Apollo_Time;
parallelPool: ParallelForPool;

// this is used to set the codebox's initial scroll offset before it's been created
// potentially a nicer way to do this??
codeScrollInitialOffset := 0.0;
codeScrollInitialBounds := 0.0;

queuePrintHighlightDebug := false;

// current project (only one active at a time)
project: Project;

notifications : [10]Notification;
numActiveNotifications := 0;
notificationTime: float64 = 10;

// fonts
fontCode: *Font; // the ui and icon fonts are owned by the UI, see uiState.font and uiState.iconFont

// options
textSize :: 15;
tabSize :: 4;
lineNumbers := true;

Arguments :: struct {
	project: string;
	fetch_grammars: bool;
	build_grammars: bool;
}

LoggerData :: struct {
	logFile: File;
}

loggerFunc :: (message: string, data: *void, info: Log_Info) {
	logger: *LoggerData;
	logger = cast(*LoggerData)data;
	
	write_string(message);
	write_string("\n");
	file_write(*logger.logFile, message);
	file_write(*logger.logFile, "\n");
}

main :: () {
	file :=  file_open(tprint("%/photon.log", get_app_base_path()), for_writing=true, keep_existing_content=false);
	logger.logFile = file;

	context.logger = loggerFunc;
	context.logger_data = *logger;
	context.assertion_failed = assertion_failed;

	#if OS == .WINDOWS {
		Windows :: #import "Windows";
		// Windows is very bad at thread-switching by default unless you do this. Sad.
		Windows.timeBeginPeriod(1);
		platform_init_crash_handler();
	}

	success, args, isSet, filesToOpen := parse_arguments(Arguments);
	if !success {
		return;
	}

	if isSet.fetch_grammars then fetch_grammars();
	if isSet.build_grammars then build_grammars();
	if isSet.fetch_grammars || isSet.build_grammars then return;

	// create window
	window = create_window(windowWidth, windowHeight, "Photon");
	Input.window_move_callback = update;
	platform_set_border_color();
	init_renderer(window, windowWidth, windowHeight);
	init_font_cache();
	load_fonts();
	editorStyle.iconFontData = #run read_entire_file("fonts/Font Awesome 6 Free-Solid-900.otf");
	init_ui(*editorStyle, *editorColours);
	initialize_commands_and_keymap();
	init_async(*asyncWorker);
	init_parallel_for_pool(*parallelPool);
	init(*openDocuments.lock);
	init(*languagesMutex);
	
	watcher_init();

	// Initialize a panel
	focusedPanel.layoutRect.x = 0;
	focusedPanel.layoutRect.y = 0;
	focusedPanel.layoutRect.w = xx windowWidth;
	focusedPanel.layoutRect.h = xx windowHeight;
	array_add(*focusedPanel.cursors);

	projectParsed := false;
	if isSet.project {
		projectParsed, project = project_parser(args.project);
		if projectParsed then project_watch_folders();
	}

	if filesToOpen.count > 0 {
		doc := document_get_or_open(filesToOpen[0]);
		panel_set_active_document(*focusedPanel, doc);
	}

	if projectParsed then project_begin_load();

	platform_set_backup_timer(window, do_backup_callback);

	deltaTime: float64 = 0.0;
	want_screenshot := false;
	while !pendingQuit {
		frameStart := seconds_since_init();
		update(deltaTime);
		#if BUILD_TYPE == BuildType.DEBUG {
			memory_visualizer_per_frame_update();
		}
		updateTime := seconds_since_init() - frameStart;

		// not ideal, should vsync to something else if above 16ms
		timeToSleep := max(16 - updateTime * 1000, 0);
		sleep_milliseconds(cast(s32) timeToSleep);

		deltaTime = seconds_since_init() - frameStart;
		// log("delta %", deltaTime);
	}
	file_close(*logger.logFile);
	// report_memory_leaks();
}

update :: (deltaTime: float64) {
	if !requestRedraw platform_wait_message();
	requestRedraw = false;

	// collect results from async thread, and if we're still waiting, don't go to sleep
	if process_completed_tasks(*asyncWorker) > 0 then requestRedraw = true;

	Input.update_window_events();

	for Input.get_window_resizes() {
		if it.window == window {
			should_reinit := (it.width != windowWidth) || (it.height != windowHeight);

			windowWidth  = it.width;
			windowHeight = it.height;

			resize_backbuffer(windowWidth, windowHeight);

			focusedPanel.layoutRect.x = 0;
			focusedPanel.layoutRect.y = 0;
			focusedPanel.layoutRect.w = xx windowWidth;
			focusedPanel.layoutRect.h = xx windowHeight;
		}
	}

	watcher_update();
	project_update();
	
	newDpiScale := platform_get_dpi_scale(window);
	if newDpiScale != dpiScale && newDpiScale != 0.0 {
		dpiScale = newDpiScale;
	}
	
	for Input.events_this_frame {
		if it.type == .QUIT then pendingQuit = true;
		input_handler(it);
	}

	build_ui();

	flush_pending_commands();
	
	if Input.events_this_frame.count > 0 then requestRedraw = true;
	
	array_reset_keeping_memory(*uiState.events);

	// edits this frame (possibly from many cursors) only marked the syntax tree dirty, queue one reparse for all of them
	document_flush_ts_tree(focusedPanel.document);

	// the view follows the primary cursor: scroll to it whenever it moved since we last did.
	if panel_get_primary_cursor(*focusedPanel).head != focusedPanel.lastScrolledCursorHead {
		panel_scroll_to_cursor(*focusedPanel);
	}

	// update notifications
	nNotificationsToRemove := 0;
	it := 0;
	while it < numActiveNotifications {
		notif := *notifications[it];
		notif.timer -= deltaTime;
		if notif.timer < 0 {
			nNotificationsToRemove += 1;
		}
		it += 1;
	}

	if nNotificationsToRemove > 0 {
		for i: 0..nNotificationsToRemove-1 {
			free(notifications[i].content);
		}
		memcpy(notifications.data, notifications.data + nNotificationsToRemove, (numActiveNotifications - nNotificationsToRemove)*size_of(Notification));
		numActiveNotifications -= nNotificationsToRemove;
	}
	if numActiveNotifications > 0 {
		requestRedraw = true;
	}

	reset_temporary_storage();
}

build_ui :: () {
	ui_set_dpi_scale(dpiScale);
	root := begin_ui();

	// Draw notifications

	fontMetrics := get_font_metrics(uiState.font, xx uiState.fontSize);

	maxWidth := 0.0;
	for * notifications {
		textRun := generate_text_run(it.content, xx uiState.fontSize, uiState.font,,temp);
		maxWidth = max(maxWidth, textRun.width);
	}

	it := numActiveNotifications;
	notificationBox := box(root, ui_key("notifBox"));
	{
		set_child_layout_axis(notificationBox, .Y);
		set_size(notificationBox, fit(), fit());
		set_child_alignment(notificationBox, .RIGHT);
		set_child_gap(notificationBox, em(0.5));
		set_fixed_x(notificationBox, windowWidth - maxWidth - em(2.5));
		set_fixed_y(notificationBox, em(3.0));
		
		while it > 0 {
			notif := notifications[it-1];
			fadeOutTime := cast(float) notificationTime*0.3;
			timeFactor := cast(float) clamp(notif.timer, 0.0, fadeOutTime) / fadeOutTime;
			alpha := lerp(0.0, 1.0, timeFactor);

			backgroundCol := editorColours.notificationBackground;
			backgroundCol.w = alpha;
			textCol := editorColours.notificationText;
			textCol.w = alpha;
			notifLabel := text(notificationBox, notif.content);
			add_flags(notifLabel, .DRAW_BACKGROUND);
			set_background_color(notifLabel, backgroundCol);
			set_text_color(notifLabel, textCol);
			set_text_padding(notifLabel, em(0.4));
			set_corner_radius(notifLabel, em(0.3));
			it -= 1;
		}
	}

	// Draw the panel
	// @todo: wrap this up somehow so zero handles resolve to null
	// this is ugly as heck
	if openDocuments.documents.count != 0 {
		slot := bucket_array_find_pointer(*openDocuments.documents, focusedPanel.document.locator);
		if slot {
			if slot.state == .INVALID {
				build_ui_loading_panel(root, *focusedPanel);
			}
			else {
				build_ui_panel(root, *focusedPanel);
			}
		}
		else {
			build_ui_empty_panel(root, *focusedPanel);
		}
	}
	else {
		build_ui_empty_panel(root, *focusedPanel);
	}

	if end_ui(deltaTime) then requestRedraw = true;

	render_frame(editorColours.windowBackground);
}

build_ui_empty_panel :: (parent: *UIBox, panel: *Panel) {
	panelBox := box(parent, ui_key("panel1"));
	{
		add_flags(panelBox, .DRAW_BACKGROUND);
		set_child_layout_axis(panelBox, .Y);
		set_size(panelBox, fixed(panel.layoutRect.w), fixed(panel.layoutRect.h));
		set_child_alignment(panelBox, .CENTER);
		
		header := box(panelBox);
		{
			add_flags(header, .DRAW_BACKGROUND | .DRAW_SIDE_BOTTOM);
			set_size(header, grow(), fit());
			set_padding(header, em(0.3));
			set_background_color(header, editorColours.headerBackground);
			set_border_thickness(header, 1.0);
			
			// empty box to give the header the height of a line of text
			dummy := box(header);
			set_size(dummy, text_content(), text_content());
		}
		
		build_ui_panel_dialogs(panelBox, panel);
		
		spacer(panelBox, .Y, fixed(em(5.0)));
		
		text(panelBox, "No Document Loaded");
		
		spacer(panelBox, .Y, fixed(em(3.0)));
		
		text(panelBox, "Open file with '<space>O'");
		
		text(panelBox, "Open command palette with ':'");
	}
}

build_ui_loading_panel :: (parent: *UIBox, panel: *Panel) {
	panelBox := box(parent, ui_key("panel1"));
	{
		add_flags(panelBox, .DRAW_BACKGROUND);
		set_child_layout_axis(panelBox, .Y);
		set_size(panelBox, fixed(panel.layoutRect.w), fixed(panel.layoutRect.h));
		set_child_alignment(panelBox, .CENTER);
		
		header := box(panelBox);
		{
			add_flags(header, .DRAW_BACKGROUND | .DRAW_SIDE_BOTTOM);
			set_size(header, grow(), fit());
			set_padding(header, em(0.3));
			set_background_color(header, editorColours.headerBackground);
			set_border_thickness(header, 1.0);
			
			// empty box to give the header the height of a line of text
			dummy := box(header);
			set_size(dummy, text_content(), text_content());
		}
		
		spacer(panelBox, .Y, fixed(em(5.0)));
		
		shouldShowSpinner :=  asyncWorker.pendingTasks != 0 && to_milliseconds(current_time_monotonic() - asyncWorker.waitStartTime) > 33;
		if shouldShowSpinner {
			loadingBox := box(panelBox);
			{
				set_size(loadingBox, fit(), fit());
				set_padding(loadingBox, em(0.3));
				
				text(loadingBox, "Loading % ...", document_get_path(panel.document));
				
				spinner := box(loadingBox);
				set_size(spinner, text_content(), text_content());
				set_font_size(spinner, em(1.0));
				set_font(spinner, uiState.iconFont);
				set_custom_draw(spinner, custom_draw_spinner, cast(*void) panel);
			}
		}
	}
}

build_ui_panel :: (parent: *UIBox, panel: *Panel) {
	panelBox := box(parent, ui_key("panel1"));
	{
		add_flags(panelBox, .DRAW_BACKGROUND);
		set_child_layout_axis(panelBox, .Y);
		set_size(panelBox, fixed(panel.layoutRect.w), fixed(panel.layoutRect.h));
		
		header := box(panelBox);
		{
			add_flags(header, .DRAW_BACKGROUND | .DRAW_SIDE_BOTTOM);
			set_size(header, grow(), fit());
			set_padding(header, em(0.3));
			set_child_alignment(header, .CENTER);
			set_background_color(header, editorColours.headerBackground);
			set_border_thickness(header, 1.0);
			
			// mode
			modeText := "NORMAL";
			if editorMode == .INSERT {
				modeText = "INSERT";
			}
			modeLabel := text(header, modeText);
			add_flags(modeLabel, .DRAW_BACKGROUND);
			set_background_color(modeLabel, editorColours.windowBackground);
			
			spacer(header, .X, fixed(em(0.5)));
			
			// filename (keyed as it's the anchor for the tooltip)
			fileLabel := box(header, ui_key("header_filename"));
			add_flags(fileLabel, .DRAW_TEXT);
			set_text(fileLabel, path_filename(document_get_path(panel.document)));
			set_size(fileLabel, text_content(), text_content());
			if signal_from_box(fileLabel).hovering {
				pathTooltip := tooltip(fileLabel.key, .{0.0, em(1.9)});
				text(pathTooltip, document_get_path(panel.document));
			}
			
			// lock icon @todo: implement for real
			if document_is_read_only(panel.document) {
				lockIcon := text(header, Icons.lock);
				set_font_size(lockIcon, em(0.7));
				set_font(lockIcon, uiState.iconFont);
			}
			
			// icon for file save status
			if document_is_unsaved(panel.document) {
				unsavedIcon := text(header, Icons.circle);
				set_font_size(unsavedIcon, em(0.7));
				set_font(unsavedIcon, uiState.iconFont);
			}
			
			spacer(header, .X, grow());
			
			// pending keys
			pendingKeys := string.{keyMap.pendingKeyString.count, keyMap.pendingKeyString.data};
			text(header, pendingKeys);
			
			if project_is_loading() || (asyncWorker.pendingTasks != 0 && to_milliseconds(current_time_monotonic() - asyncWorker.waitStartTime) > 33) {
				spacer(header, .X, fixed(em(2.0)));
				
				spinner := box(header);
				set_size(spinner, text_content(), text_content());
				set_font_size(spinner, em(1.0));
				set_font(spinner, uiState.iconFont);
				set_custom_draw(spinner, custom_draw_spinner, cast(*void) panel);
			}
			
			spacer(header, .X, fixed(em(2.0)));
			
			// location
			cursorCoordinate := get_coordinate_from_offset(panel.document, panel_get_primary_cursor(panel).head);
			text(header, "Ln: % Col: % Byte: %", cursorCoordinate.line+1, cursorCoordinate.col, panel_get_primary_cursor(panel).head);
			
			spacer(header, .X, fixed(em(2.0)));
			
			// line endings
			lineEndingText := "[Mixed]";
			lineEndings := document_get_line_endings(panel.document);
			if lineEndings == .LF {
				lineEndingText = "LF";
			}
			else if lineEndings == .CRLF {
				lineEndingText = "CRLF";
			}
			else if lineEndings == .MIXED_MAJORITY_LF {
				lineEndingText = "[Mixed]";
			}
			text(header, lineEndingText);
			
			spacer(header, .X, fixed(em(2.0)));
			
			// file type
			language := document_get_language(panel.document);
			text(header, ifx language then language.name else path_extension(document_get_path(panel.document)));
			
			spacer(header, .X, fixed(em(2.0)));
			
			// panel options button
			panelOptsKey := ui_key("panelopts");
			menuOpen := is_context_menu_open(panelOptsKey);
			clicked, panelOptsToggle := toggle(header, fixed(em(1.5)), text_content(), *menuOpen, Icons.verticalEllipsis);
			set_font(panelOptsToggle, uiState.iconFont);
			if clicked {
				if menuOpen {
					context_menu_open(panelOptsKey);
				}
				else {
					context_menu_close();
				}
			}
			
			menu := context_menu(key=panelOptsKey,
								 width=fixed(em(12.0)),
								 anchorBoxKey=panelOptsToggle.key,
								 anchorOffset=.{0.0, em(1.9)});
			if menu {
				if context_menu_item(menu, "Line Numbers", Icons.numList).pressed {
					lineNumbers = !lineNumbers;
				}
				context_menu_item(menu, "View Line Endings", "");
				context_menu_item(menu, "Line Wrapping", Icons.alignLeft);
			}
		}
		
		build_ui_panel_dialogs(panelBox, panel);
		
		// Draw the main code screen
		codeContainerOuter := box(panelBox);
		{
			add_flags(codeContainerOuter, .DRAW_BACKGROUND);
			set_child_layout_axis(codeContainerOuter, .Y);
			set_size(codeContainerOuter, grow(), grow());
			
			longestLinePixelWidth:= 0.0;
			
			codeContainerInner := box(codeContainerOuter);
			add_flags(codeContainerInner, .DRAW_BACKGROUND);
			set_size(codeContainerInner, grow(), grow());
			
			codeBox := box(codeContainerInner, ui_key("code"));
			{
				add_flags(codeBox, .CLIP_CONTENTS | .MOUSE_CLICKABLE);
				set_size(codeBox, grow(), grow());
				set_font(codeBox, fontCode);
				set_custom_draw(codeBox, custom_draw_code, cast(*void) panel);
				
				numDocumentLines := get_number_of_lines(panel.document);
				metrics := get_font_metrics(codeBox.font, xx codeBox.fontSize);
				codeBox.viewBounds.y = cast(float, -(metrics.lineSpacing * numDocumentLines) + metrics.lineSpacing * 5);
				
				if codeBox.firstTouchedFrame == uiState.frameIndex {
					codeBox.viewOffsetTarget.y = codeScrollInitialOffset;
					codeBox.viewOffsetTarget.y = clamp(codeBox.viewOffsetTarget.y, codeBox.viewBounds.y, 0);
				}
				
				// TODO: cache this calculation, it won't change much and it can be slow
				longestLinePixelWidth = cast(float, generate_text_run(get_line_content(panel.document, document_get_longest_line(panel.document)-1,,temp).text, xx codeBox.fontSize, codeBox.font,,temp).width);
				longestLinePixelWidth += metrics.emWidth; // add extra monospace width for cursor to sit on end of line
				
				if longestLinePixelWidth > codeBox.rect.w {
					gutterWidth := 0;
					if lineNumbers {
						maxLinesRun := generate_text_run(tprint(" % ", numDocumentLines), xx codeBox.fontSize, codeBox.font,,temp);
						gutterWidth = xx maxLinesRun.width;
					}
					
					// We only want to scroll horizontally such that the longest line is still mostly visible
					// i.e. not the whole length of the line, just how much is going off screen
					codeBox.viewBounds.x = abs(longestLinePixelWidth - codeBox.rect.w + gutterWidth);
				}
				else {
					codeBox.viewBounds.x = 0;
				}
				
				signal := signal_from_box(codeBox);
				
				// mouse cursor control
				set_cursor_to_mouse_location :: (doc: DocumentHandle, cursor: *Cursor, numDocumentLines: s64, box: *UIBox) {
					gutterWidth := generate_text_run(tprint(" % ", numDocumentLines), xx box.fontSize, box.font,,temp).width;
					
					x, y, success := get_mouse_pointer_position(window, false);
					mouseX := abs(box.viewOffset.x) + (cast(float, x) - box.rect.x - gutterWidth);
					mouseY := abs(box.viewOffset.y) + (cast(float, y) - box.rect.y);
					
					metrics := get_font_metrics(box.font, xx box.fontSize);
					clickedLine := clamp(cast(s64) (mouseY / metrics.lineSpacing), 0, numDocumentLines - 1);
					
					// collect the line content of this line (so we can figure out how wide it is in pixels)
					lineContent := get_line_content(doc, clickedLine,,temp);
					run := generate_text_run(lineContent.text, xx box.fontSize, box.font, stopAtWidth=mouseX,,temp);
					column := ifx run.byteOffsets.count > 0 then run.byteOffsets[run.byteOffsets.count-1] else 0;
					cursor.head = min(get_size(doc)-1, lineContent.startByteOffset + column);
					
					// update the virtual column
					cursor.virtualColumn = 0;
					for lineContent.text {
						if it_index == column then break;
						if it == #char "\t" {
							cursor.virtualColumn += chars_to_tabstop(cursor.virtualColumn);
						}
						else {
							cursor.virtualColumn += 1;
						}
					}
				}
				
				if signal.pressed {
					keep_primary_selection(panel, panel_get_primary_cursor(panel));
					set_cursor_to_mouse_location (panel.document, panel_get_primary_cursor(panel), numDocumentLines, codeBox);
					panel_get_primary_cursor(panel).anchor = panel_get_primary_cursor(panel).head;
				}
				
				if signal.doubleClicked {
					keep_primary_selection(panel, panel_get_primary_cursor(panel));
					set_cursor_to_mouse_location (panel.document, panel_get_primary_cursor(panel), numDocumentLines, codeBox);
					move_prev_word_start(panel, panel_get_primary_cursor(panel));
					move_word_end(panel, panel_get_primary_cursor(panel));
				}
				
				if signal.holding {
					set_cursor_to_mouse_location (panel.document, panel_get_primary_cursor(panel), numDocumentLines, codeBox);
					x, y, success := get_mouse_pointer_position(window, false);
					if y > cast(int, codeBox.rect.y + codeBox.rect.h) {
						_, range := panel_calculate_visible_lines(panel);
						currentLine := get_coordinate_from_offset(panel.document, panel_get_primary_cursor(panel).head).line;
						panel_scroll_to_line(panel, currentLine - range);
					}
					else if y < cast(int, codeBox.rect.y) {
						currentLine := get_coordinate_from_offset(panel.document, panel_get_primary_cursor(panel).head).line;
						panel_scroll_to_line(panel, currentLine);
					}
				}
				
				scroll_bar(codeContainerInner,
						   ui_key("codeScrollVertical"),
						   .Y,
						   codeBox.viewOffset.y/codeBox.viewBounds.y,
						   cast(float, numDocumentLines),
						   codeBox.rect.h/metrics.lineSpacing,
						   codeBox.key);
			}
			
			scroll_bar(codeContainerOuter,
					   ui_key("codeScrollHorizontal"),
					   .X,
					   codeBox.viewOffset.x/codeBox.viewBounds.x,
					   longestLinePixelWidth,
					   codeBox.rect.w,
					   codeBox.key);
		}
		
		// Draw the search/select dialog
		if editorMode == .SEARCH || editorMode == .SELECT || editorMode == .SPLIT {
			searchContainer := box(panelBox);
			{
				add_flags(searchContainer, .DRAW_BACKGROUND | .DRAW_SIDE_TOP);
				set_size(searchContainer, grow(), fit());
				set_padding(searchContainer, em(0.4));
				set_background_color(searchContainer, editorColours.searchBarBackground);
				set_border_thickness(searchContainer, 1.0);
				set_child_gap(searchContainer, em(0.4));
				
				// regex toggle, highlighted while enabled
				clicked, regexToggle := toggle(searchContainer, fixed(em(2.0)), grow(), *panel.searchRegexEnabled, ".*");
				set_font(regexToggle, fontCode);
				if clicked {
					// rerun the search so the results reflect the new mode
					if panel.searchInput.onEditCallback {
						panel.searchInput.onEditCallback(panel.searchInput.userData, input_field_get_text(*panel.searchInput));
					}
				}
				
				// case sensitive toggle, highlighted while enabled
				caseClicked, caseToggle := toggle(searchContainer, fixed(em(2.0)), grow(), *panel.searchCaseSensitive, "Aa");
				set_font(caseToggle, fontCode);
				if caseClicked {
					if panel.searchInput.onEditCallback {
						panel.searchInput.onEditCallback(panel.searchInput.userData, input_field_get_text(*panel.searchInput));
					}
				}
				
				// TODO(ui): input field widget here
				fontMetrics := get_font_metrics(uiState.font, xx uiState.fontSize);
				inputBox := box(searchContainer, ui_key("search_input"));
				add_flags(inputBox, .DRAW_BACKGROUND);
				set_size(inputBox, grow(), fixed(fontMetrics.lineSpacing+em(0.8)));
				set_corner_radius(inputBox, em(0.2));
				set_background_color(inputBox, editorColours.textInputBackground);
				set_font(inputBox, fontCode);
				set_text_padding(inputBox, em(0.5));
				set_custom_draw(inputBox, custom_draw_input_field, cast(*void, *panel.searchInput));
			}
		}
	}
}

build_ui_panel_dialogs :: (parent: *UIBox, panel: *Panel) {
	if editorMode == .COMMAND_PALETTE {
		paletteWidth := panel.layoutRect.w * 0.5;
		if panel.commandPalette.currentHandler {
			paletteWidth = panel.layoutRect.w * panel.commandPalette.currentHandler.rowWidthPercent;
		}

		commandPaletteContainer := box(parent);
		{
			add_flags(commandPaletteContainer, .DRAW_BACKGROUND);
			set_child_layout_axis(commandPaletteContainer, .Y);
			set_size(commandPaletteContainer, fixed(paletteWidth), fit());
			set_padding(commandPaletteContainer, em(editorStyle.commandPalettePadding));
			set_background_color(commandPaletteContainer, editorColours.popupBackground);
			set_corner_radius(commandPaletteContainer, em(editorStyle.commandPaletteCornerRadius));
			set_fixed_x(commandPaletteContainer, panel.layoutRect.x+(panel.layoutRect.w-paletteWidth)/2);
			set_fixed_y(commandPaletteContainer, em(3.0));
			
			fontMetrics := get_font_metrics(uiState.font, xx uiState.fontSize);
			inputBox := box(commandPaletteContainer);
			{
				add_flags(inputBox, .DRAW_BACKGROUND);
				set_size(inputBox, grow(), fixed(fontMetrics.lineSpacing+em(0.8)));
				set_padding(inputBox, em(0.4));
				set_child_gap(inputBox, em(0.2));
				set_corner_radius(inputBox, em(0.2));
				set_background_color(inputBox, editorColours.textInputBackground);
				set_text_padding(inputBox, em(0.5));
				
				if panel.commandPalette.pendingCommandMode {
					pendingCommandLabel := text(inputBox, panel.commandPalette.pendingCommand.cmd.prettyName);
					add_flags(pendingCommandLabel, .DRAW_BACKGROUND);

					// only arguments before currentArgIndex are filled in, later slots are null or stale
					pendingCommand := *panel.commandPalette.pendingCommand;
					for 0..panel.commandPalette.currentArgIndex-1 {
						argType := pendingCommand.cmd.args[it].type;
						argValue := pendingCommand.args[it];
						if !argValue then continue;

						valueText: string;
						if argType == type_info(u8) {
							// u8 arguments are chars
							valueText = string.{1, cast(*u8, argValue)};
						}
						else {
							valueText = tprint("%", Any.{argType, argValue});
						}
						argLabel := text(inputBox, valueText);
						add_flags(argLabel, .DRAW_BACKGROUND);
					}
				}

				if panel.commandPalette.input.text.count == 0 && panel.commandPalette.pendingCommandMode {
					currentArg := panel.commandPalette.currentArgIndex;
					// TODO: capitalize and undo camelcase on this name
					text(inputBox, panel.commandPalette.pendingCommand.cmd.args[currentArg].name);
				}
				else {
					// TODO(ui): refactor into input field widget
					inputArea := box(inputBox, ui_key("commandPaletteInput"));
					set_size(inputArea, grow(), fixed(xx fontMetrics.lineSpacing));
					set_custom_draw(inputArea, custom_draw_input_field, cast(*void, *panel.commandPalette.input));
				}
			}

			// Draw the list of suggestions, that are currently relevant
			argHandler := panel.commandPalette.currentHandler;
			if argHandler && argHandler.populate {
				elementHeight := fontMetrics.characterHeight*argHandler.rowHeightLines;
				listBox, rangeStart, rangeEnd := scroll_list_begin(commandPaletteContainer,
															ui_key("suggestionList"), ui_key("suggestionListScroller"),
															panel.layoutRect.h/2,
															elementHeight,
															panel.commandPalette.numToDisplay,
															panel.commandPalette.selection,
															panel.commandPalette.selectionChange);

				if panel.commandPalette.selectionChange then panel.commandPalette.selectionChange = false;

				for rangeStart..rangeEnd {
					suggestion := panel.commandPalette.suggestionList[it];
					selected := it == panel.commandPalette.selection;

					if suggestion.sortKey == 0 continue;

					entryBox := box(listBox, ui_key("suggestion##%", it));
					{
						add_flags(entryBox, .DRAW_HOT_EFFECTS | .DRAW_ACTIVE_EFFECTS | .MOUSE_CLICKABLE | .DRAW_BACKGROUND);
						set_size(entryBox, grow(), fixed(elementHeight));
						set_padding(entryBox, em(argHandler.suggestionPadding));
						set_background_color(entryBox, ifx selected editorColours.selectedBackground else editorColours.popupBackground);
						signal := signal_from_box(entryBox);
						if signal.pressed {
							panel.commandPalette.selection = xx it;
							queue_command(find_command_by_name("command_palette_execute_command"), panel);
						}
						if argHandler.drawSuggestion {
							argHandler.drawSuggestion(entryBox, *panel.commandPalette, *suggestion, it, selected, signal);
						}
						else {
							default_draw_suggestion(entryBox, *panel.commandPalette, *suggestion, it, selected, signal);
						}
					}
				}

				scroll_list_end(listBox);
			}

			// Draw the control hints box at the bottom
			hintsBox := box(commandPaletteContainer, ui_key("hintsBox"));
			{
				add_flags(hintsBox, .DRAW_SIDE_TOP);
				set_size(hintsBox, grow(), fit());
				set_border_thickness(hintsBox, 1.0);
				
				spacer(hintsBox, .X, grow());

				hintsLabel := text(hintsBox, "<up><down> to navigate <enter> to use <escape> to dismiss");
				set_text_alignment(hintsLabel, .CENTER);
				set_text_padding(hintsLabel, em(0.5));
				set_text_color(hintsLabel, editorColours.textDim);

				spacer(hintsBox, .X, grow());
			}
		}
	}
}

custom_draw_spinner :: (box: *UIBox, udata: *void) {
	// there's no simple way to make a box rotate so for now spinners have custom drawing code
	// that let us rotate them in the shader
	
	box.textRun = generate_text_run(Icons.spinner, xx box.fontSize, box.font,,temp);
	metrics := get_font_metrics(box.font, xx box.fontSize);
	yPos := floor(box.rect.y + box.rect.h/2.0) + floor(box.fontSize/2.0) - 1.0;
	xPos := box.rect.x;

	xPos += box.textPadding;
	xPos = floor(xPos);

	time := to_milliseconds (current_time_monotonic() - startTime);

	instance := box.textRun.instances[0];
	instance.dstRect.x = round(xPos + instance.dstRect.x);
	instance.dstRect.y = round(yPos + instance.dstRect.y);

	// this is a bit of a hack, for some reason if you don't shift the uv's slighly
	// then the spinner wobbles. Probably due to some issue we have with rendering fonts that are not
	// perfectly aligned. Something to look into one day
	instance.srcRect.x = instance.srcRect.x+0.5;
	instance.srcRect.y = instance.srcRect.y+0.5;
	instance.color = box.colours.text;
	instance.angle = cast(float, time) / 1000.0 * 10;
	submit_instance(instance);

}

custom_draw_input_field :: (box: *UIBox, udata: *void) {
	inputField:*InputField = cast(*InputField)udata;
	text := string.{inputField.text.count, inputField.text.data};

	// draw the input field text
	box.textRun = generate_text_run(text, xx box.fontSize, box.font,,temp);
	metrics := get_font_metrics(box.font, xx box.fontSize);
	yPos := floor(box.rect.y + box.rect.h/2.0) + floor(box.fontSize/2.0) - 1.0;
	xPos := box.rect.x;

	xPos += box.textPadding;
	xPos = floor(xPos);

	if inputField.isPath {
		// the path is drawn as plain text, but the segment being edited is brighter than the rest
		// so it's clear where the suggestions are coming from
		directory := path_strip_filename(text);
		leaf := path_filename(text);

		dimmed := box.colours.text;
		dimmed.w *= 0.6;

		directoryRun := generate_text_run(directory, xx box.fontSize, box.font,,temp);
		draw_text_run(directoryRun, xPos, yPos, dimmed);

		leafRun := generate_text_run(leaf, xx box.fontSize, box.font,,temp);
		draw_text_run(leafRun, xPos + directoryRun.width, yPos, box.colours.text);
	}
	else {
		draw_text_run(box.textRun, xPos, yPos, box.colours.text);
	}

	// calculate cursor position
	cursorOffsetX := generate_text_run(string.{inputField.cursor, inputField.text.data}, xx box.fontSize, box.font,,temp).width;

	// draw cursor
	cursorHeight:float = metrics.typicalAscender-metrics.typicalDescender + metrics.characterHeight*0.2;
	submit_instance(.{
		dstRect = .{
			xPos + cursorOffsetX,
			yPos-metrics.typicalDescender-cursorHeight,
			2,
			cursorHeight
		},
		color = ifx editorMode == .INSERT then .{1.0, 1.0, 1.0, 1.0} else editorColours.text,
		shader = .RECTS
	});
}

highlight_color_at :: (highlights: [] Highlight, byteOffset: s64, currentIndex: *s64) -> Vector4 {
	while currentIndex.* < highlights.count && byteOffset >= highlights[currentIndex.*].end {
		currentIndex.* += 1;
	}
	if currentIndex.* < highlights.count
	&& byteOffset >= highlights[currentIndex.*].start
	&& byteOffset <  highlights[currentIndex.*].end {
		return editorColours.codeColors[highlights[currentIndex.*].type];
	}
	return editorColours.codeDefault;
}

// @todo: probably want to move this somewhere else? Potentially the panel file?
custom_draw_code :: (box: *UIBox, udata: *void) {
	panel:*Panel = cast(*Panel)udata;

	metrics := get_font_metrics(box.font, xx box.fontSize);
	documentLines := get_number_of_lines(panel.document);

	startVisibleLine : s64;
	endVisibleLine : s64;
	visibleLines: [..]string;
	visibleLines.allocator = temp;

	startVisibleLine = clamp(cast(s64) (-box.viewOffset.y / metrics.lineSpacing) - 1, 0, documentLines - 1);
	endVisibleLine = clamp(startVisibleLine + cast(s64)box.rect.h / metrics.lineSpacing + 2, 0, documentLines - 1);

	startOffset := (startVisibleLine+2) * metrics.lineSpacing - metrics.lineSpacing;

	gutterWidth := 0;
	if lineNumbers {
		maxLinesRun := generate_text_run(tprint(" % ", documentLines), xx box.fontSize, box.font,,temp);
		gutterWidth = xx maxLinesRun.width;
	}

	textAreaX := box.rect.x + gutterWidth - box.viewOffset.x;
	textAreaY := box.rect.y + startOffset + box.viewOffset.y;

	linesOnScreen: [..]Document.LineContent;
	linesOnScreen.allocator = temp;
	{
		lineIterator := make_line_iterator(panel.document, startVisibleLine, endVisibleLine);
		for lineIterator {
			lineContent := it;
			lineContent.text = copy_temporary_string(it.text);
			array_add(*linesOnScreen, lineContent);
		}
	}

	// Draw cursor selection
	if editorMode != .SEARCH && editorMode != .SELECT && editorMode != .SPLIT {
		for cursor: panel.cursors {
			if cursor.head != cursor.anchor {
				start := min(cursor.head, cursor.anchor);
				end := max(cursor.head, cursor.anchor);
				end = shift_offset_line_endings(panel.document, end + 1, .FORWARD);
				draw_document_range(panel.document, start, end,
									box.font,
									xx box.fontSize,
									textAreaX,
									textAreaY,
									linesOnScreen,
									startVisibleLine);
			}
		}
	}

	// draw search results
	if editorMode == .SEARCH || editorMode == .SELECT || editorMode == .SPLIT {
		for panel.results {
			draw_document_range(panel.document,
								it.start,
								it.end,
								box.font,
								xx box.fontSize,
								textAreaX,
								textAreaY,
								linesOnScreen,
								startVisibleLine);
		}
	}

	// Draw code
	language := document_get_language(panel.document);
	tsTree := document_get_ts_tree(panel.document);
	if language && tsTree && language.highlightsQuery.query {
		rangeStartByte := linesOnScreen[0].startByteOffset;
		rangeEndByte := linesOnScreen[linesOnScreen.count-1].endByteOffset;

		treeNode := ts_tree_root_node(tsTree);

		highlights := compute_highlights(language, treeNode, rangeStartByte, rangeEndByte, panel.document);

		if queuePrintHighlightDebug {
			get_text_range :: (doc: DocumentHandle, start: s64, end: s64) -> string {
				captureText := alloc_string(end-start,,temp);
				iter := make_iterator(doc, start,,temp);
				for iter {
					if it_index >= captureText.count break;
					captureText[it_index] = it;
				}
				return captureText;
			}
			for highlight: highlights {
				log("Highlight: % %", highlight, get_text_range(panel.document, highlight.start, highlight.end));
			}
			queuePrintHighlightDebug = false;
		}

		x :float = textAreaX;
		y :float = textAreaY;
		currentHighlightIndex : s64 = 0;
		for line: linesOnScreen {
			run := generate_text_run(line.text, xx box.fontSize, box.font,,temp);
			for run.instances {
				byteOffset := line.startByteOffset + run.byteOffsets[it_index];
				color := highlight_color_at(highlights, byteOffset, *currentHighlightIndex);

				instance := it;
				instance.dstRect.x = round(x + instance.dstRect.x);
				instance.dstRect.y = round(y + instance.dstRect.y);
				instance.color = color;
				submit_instance(instance);

			}
			y += metrics.lineSpacing;
		}
	}
	else {
		// draw text with no highlighting
		x :float = textAreaX;
		y :float = textAreaY;
		for line: linesOnScreen {
			run := generate_text_run(line.text, xx box.fontSize, box.font,,temp);
			draw_text_run(run, x, y, editorColours.text);
			y += metrics.lineSpacing;
		}
	}

	// Draw cursor
	for cursor: panel.cursors {
		cursorLine := get_coordinate_from_offset(panel.document, cursor.head).line;
		
		if (editorMode != .SEARCH && editorMode != .SELECT && editorMode != .SPLIT) && cursorLine >= startVisibleLine && cursorLine <= endVisibleLine {
			lineCopy := linesOnScreen[cursorLine - startVisibleLine];
			lineCopy.text.count = min(lineCopy.text.count, cursor.head - get_line_start(panel.document, cursorLine));
			
			// figuring out the width of the cursor requires knowing which vertical column of text
			// we're in, including previous tabs
			col:=0;
			for lineCopy.text {
				if it != #char "\t" {
					col += 1;
				} else {
					charsToTabstop := box.font.tabSize - col % box.font.tabSize;
					col += charsToTabstop;
				}
			}
			cursorChar := get_char_at(panel.document, cursor.head);
			cursorRun := generate_text_run(cast(string) u8.[cursorChar], xx box.fontSize, box.font, col,,temp);
			
			cursorX := textAreaX + generate_text_run(lineCopy.text, xx box.fontSize, box.font,,temp).width;
			cursorY := textAreaY - metrics.typicalDescender + metrics.lineSpacing * (cursorLine-startVisibleLine-1);
			
			submit_instance(.{
				dstRect = .{
					cursorX,
					cursorY,
					cursorRun.width,
					xx metrics.lineSpacing
				},
				color = (ifx editorMode == .INSERT then .{1.0, 1.0, 1.0, 1.0} else editorColours.text) * (ifx it_index != panel.primaryCursor then 0.9 else 1.0),
				shader = .RECTS
			});
			
			if cursorChar != 0 {
				draw_text_run(cursorRun, cursorX, textAreaY + metrics.lineSpacing * (cursorLine-startVisibleLine), editorColours.boxBackground);
			}
		}
	}
	
	// Draw gutter
	if lineNumbers {
		submit_instance(.{
			dstRect = .{
				cast(float)(box.rect.x),
				cast(float)(box.rect.y),
				cast(float)gutterWidth,
				cast(float)box.rect.h
			},
			color = editorColours.boxBackground,
			shader = .RECTS
		});

		// Draw line numbers
		y :float = box.rect.y + startOffset + box.viewOffset.y;
		for startVisibleLine..endVisibleLine {
			lineNoRun := generate_text_run(tprint("% ", it+1), xx box.fontSize, box.font,,temp);
			draw_text_run(lineNoRun, box.rect.x + (gutterWidth - lineNoRun.width), y, editorColours.gutterText);
			y += metrics.lineSpacing;
		}
	}
}

draw_document_range :: (doc: DocumentHandle, start: s64, end: s64, font: *Font, fontSize: int, textAreaX: float, textAreaY: float, linesOnScreen: []Document.LineContent, startVisibleLine: s64) {
	metrics := get_font_metrics(font, fontSize);
	rangeStart := get_coordinate_from_offset(doc, start);
	rangeEnd := get_coordinate_from_offset(doc, end);
	lineWidths: [..] s32;
	lineWidths.allocator = temp;
	endVisibleLine := startVisibleLine + linesOnScreen.count;
	 
	if !(rangeEnd.line > startVisibleLine || rangeStart.line < endVisibleLine) {
		return;
	}

	// clamp us to only render inside the visible range
	rangeStart.line = max(startVisibleLine, rangeStart.line);
	rangeEnd.line = min(endVisibleLine, rangeEnd.line);
	
	for rangeStart.line..rangeEnd.line {
		lineIndex := it - startVisibleLine; 
		if 0 > lineIndex || lineIndex >= linesOnScreen.count then continue;

		line := linesOnScreen[it - startVisibleLine];

		// hide CRLF endings
		if line.text.count >= 2 && line.text[line.text.count-2] == #char "\r" {
			line.text.count -= 1;
			line.endByteOffset -= 1;
		}
		
		lineWidth := generate_text_run(line.text, fontSize, font,,temp).width;

		isFirstLine:= it == rangeStart.line;
		isLastLine:= it == rangeEnd.line;

		selectionX := 0;
		selectionW := lineWidth;
		if isFirstLine {
			selectionX = xx generate_text_run(string.{min(rangeStart.col, line.text.count), line.text.data}, fontSize, font,,temp).width;
			selectionW = lineWidth - selectionX;
		}
		if isLastLine {
			selectionW = generate_text_run(string.{min(rangeEnd.col, line.text.count), line.text.data}, fontSize, font,,temp).width - selectionX;
		}

		submit_instance(.{
			dstRect = .{
				cast(float)(textAreaX + selectionX),
				cast(float)(textAreaY - metrics.typicalDescender + metrics.lineSpacing * (it-startVisibleLine-1)),
				cast(float)selectionW,
				cast(float)metrics.lineSpacing
			},
			color = editorColours.textSelection,
			shader = .RECTS
		});
	}
}

do_backup_callback :: () {
	for doc: openDocuments {
		if document_is_unsaved(doc) {
			builder : String_Builder;
			builder.allocator = temp;
			init_string_builder(*builder);

			append(*builder, path_strip_filename(get_path_of_running_executable()));
			append(*builder, "\\backups\\");
			append(*builder, path_filename(document_get_path(doc)));

			document_save(doc, builder_to_string(*builder,,temp), true);
		}
	}
}

load_fonts :: () {
	// @todo: ideally the code font would be in a config file somewhere not in here
	fontCode = load_first_font(editorStyle.codeFont);
}

// fuzzy searching
Highlight :: struct {
	start: u32;
	end: u32;
	type: HighlightType;
}

fuzzy_search :: (stringToSearch: string, filter: string) -> score: s32, highlights: [..]TextHighlight {
	MAX_CHARS :: 200;

	highlights: [..]TextHighlight;

	if filter.count == 0 return 1, highlights;

	// search for the full string first
	{
		i := find_index_from_left_nocase_fast(stringToSearch, filter);
		if i >= 0 {
			// match!
			score := (200 + cast(s32, filter.count)) * (MAX_CHARS - i);
			array_add(*highlights, TextHighlight.{xx i, cast(u32, i + filter.count)});
			return xx score, highlights; 
		}
	}

	// search for individual (utf8) characters
	score := 0;
	pos := 0;
	str := filter.data;
	while str < filter.data+filter.count {
		// iterate per unicode character, rather than literal scan of bytes
		substr: string = ---;
		substr.data = str;
		str = unicode_next_character(str);
		substr.count = str - substr.data;

		// search 
		i := find_index_from_left_nocase_fast(stringToSearch, substr, pos);
		if i < 0 { score = -1; break; }; 

		// found a match!
		score += 5 * (MAX_CHARS - i); 
		array_add(*highlights, TextHighlight.{xx i, cast(u32, i + substr.count)});

		// start the next search after this one, so we find ordered highlights of chars
		pos = i + substr.count;
	}
	return xx score, highlights;
}

find_index_from_left_nocase_fast :: (s: string, substring: string, start_index := 0) -> s64 {
	cursor := start_index;

	if substring.count == 0 then return -1;

	SIMD_WIDTH :: 16; // 16 bytes, 128 bits

	furthestValid := s.count - substring.count;
	byte1 := to_lower(substring[0]);
	byte2 := to_lower(substring[substring.count-1]);
	_caseBit := 0x20202020;
	_aMinus1:= 0x40404040;
	_z:= 0x5a5a5a5a;
	

	#if CPU == .X64 {
		#asm {
			// makes a register of all zeroes
			pxor.x      zeroes:, zeroes;

			// puts our needle into the lowest 32 bit slot of the "first" register
			movd        first:, byte1;
			// puts our needle into every slot
			pshufb.x    first, zeroes;

			// same again but for the last needle
			movd        last:, byte2;
			pshufb.x    last, zeroes;

			movd        caseBit:, _caseBit;
			pshufb.x    caseBit, zeroes;
			movd        aMinus1:, _aMinus1;
			pshufb.x    aMinus1, zeroes;
			movd        z:, _z;
			pshufb.x    z, zeroes;
		}

		while cursor + SIMD_WIDTH < furthestValid {
			point0 := s.data + cursor;
			point1 := s.data + cursor + substring.count - 1;

			mask:    u32 = ---;
			advance: u32;
			#asm {
				// loads the next 16 bytes into test registers
				movdqu.x    test0:, [point0];
				// make test0 lowercase
				movdqu.x    tmp:, test0;
				pcmpgtb.x   tmp, aMinus1; // should be a mask of test > a-1
				movdqu.x    tmp2:,z;
				pcmpgtb.x   tmp2, test0; // should be a mask of test <= z 
				pand.x      tmp, tmp2; // mask of a <= test <= z
				pand.x      tmp, caseBit; // masking the case to the write bytes
				por.x       test0,tmp; // apply the lowercase

				movdqu.x    test1:, [point1];
				// make test1 lowercase
				movdqu.x    tmp, test1;
				pcmpgtb.x   tmp, aMinus1;
				movdqu.x    tmp2, z;
				pcmpgtb.x   tmp2, test1;
				pand.x      tmp, tmp2;
				pand.x      tmp, caseBit;
				por.x       test1,tmp;

				// actually does the test
				pcmpeqb.x   test0, first;
				pcmpeqb.x   test1, last;

				// and the results together
				pand.x test0, test1;

				// takes the most significant bit of each byte and packs them into 16 bit mask
				pmovmskb.x  mask, test0;

				// bit scan forward to find the index of the first nonzero bit
				bsf.d       advance, mask;
			}

			while mask != 0 {
				candidate := cursor + advance;
				if compare_nocase(.{substring.count, s.data + candidate}, substring) == 0 {
					return candidate;
				}
				mask &= mask - 1; // clear lowest set bit
			}

			cursor += 16;
			continue;
		}
	}

	while cursor + substring.count <= s.count {
		t := slice(s, cursor, substring.count);
		if equal_nocase(t, substring) return cursor;
		cursor += 1;
	}

	return -1;
}

find_index_from_left_fast :: (s: string, substring: string, start_index := 0) -> s64 {
	cursor := start_index;

	if substring.count == 0 then return -1;

	SIMD_WIDTH :: 16; // 16 bytes, 128 bits

	furthestValid := s.count - substring.count;
	byte1 := substring[0];
	byte2 := substring[substring.count-1];

	#if CPU == .X64 {

		#asm {
			// makes a register of all zeroes
			pxor.x      zeroes:, zeroes;

			// puts our needle into the lowest 32 bit slot of the "first" register
			movd        first:, byte1;
			// puts our needle into every slot
			pshufb.x    first, zeroes;

			// same again but for the last needle
			movd        last:, byte2;
			pshufb.x    last, zeroes;
		}

		while cursor + SIMD_WIDTH < furthestValid {
			point0 := s.data + cursor;
			point1 := s.data + cursor + substring.count - 1;

			mask:    u32 = ---;
			advance: u32;
			#asm {
				// loads the next 16 bytes into test registers
				movdqu.x    test0:, [point0];
				movdqu.x    test1:, [point1];

				// actually does the test
				pcmpeqb.x   test0, first;
				pcmpeqb.x   test1, last;

				// and the results together
				pand.x test0, test1;

				// takes the most significant bit of each byte and packs them into 16 bit mask
				pmovmskb.x  mask, test0;

				// bit scan forward to find the index of the first nonzero bit
				bsf.d       advance, mask;
			}

			while mask != 0 {
				candidate := cursor + advance;
				if memcmp(s.data + candidate, substring.data, substring.count) == 0 {
					return candidate;
				}
				mask &= mask - 1; // clear lowest set bit
			}

			cursor += 16;
			continue;
		}
	}

	while cursor + substring.count <= s.count {
		t := slice(s, cursor, substring.count);
		if equal(t, substring) return cursor;
		cursor += 1;
	}

	return -1;
}

// notifications

// this function copies the message string; the notification system owns the copy and frees it once the notification expires or is evicted
push_notification :: (message: string) {
	owned := copy_string(message);
	if numActiveNotifications < 10 {
		notifications[numActiveNotifications] = Notification.{owned, notificationTime};
		numActiveNotifications += 1;
	}
	else {
		// we'll delete the oldest element to make space for this one, so no notifications get missed
		free(notifications[0].content);
		memcpy(notifications.data, notifications.data+1, size_of(Notification));
		notifications[9] = Notification.{owned, 20};
	}
	requestRedraw = true;
}


// unicode stuff
convert_utf32_to_utf8 :: (ch: u32) -> Utf8_Char {
	UNI_MAX_LEGAL_UTF32 :: 0x0010FFFF;
	UNI_REPLACEMENT_CHAR :: 0x0000FFFD;

	count := 0;
	if ch < 0x80                        count = 1;
	else if ch < 0x800                  count = 2;
	else if ch < 0x10000                count = 3;
	else if ch <= UNI_MAX_LEGAL_UTF32   count = 4;
	else {
		count = 3;
		ch = UNI_REPLACEMENT_CHAR;
	}

	byteMask :: 0xBF;
	byteMark :: 0x80;

	bytes: [4] u8 = ---;

	if count == {
		case 4; bytes[3] = xx (ch | byteMark) & byteMask; ch = ch >> 6; #through;
		case 3; bytes[2] = xx (ch | byteMark) & byteMask; ch = ch >> 6; #through;
		case 2; bytes[1] = xx (ch | byteMark) & byteMask; ch = ch >> 6; #through;
		case 1; bytes[0] = xx (ch | firstByteMark[count]);
	}

	result: Utf8_Char = ---;
	result.bytes = bytes;
	result.count = xx count;
	return result;
}

to_string :: (utf8_char: *Utf8_Char) -> string {
	str: string = ---;
	str.data  = *utf8_char.bytes[0];
	str.count = utf8_char.count;
	return str;
}

// simple input field

InputField :: struct {
	text: [..]u8;
	cursor: s32;
	onEditCallback: (*void, string);
	userData: *void;

	// when set the text is a path, so everything but the segment being edited is dimmed
	// and ctrl+backspace deletes a whole segment
	isPath: bool;
}

input_field_reset :: (inputField: *InputField) {
	array_reset(*inputField.text);
	inputField.cursor = 0;
}

input_field_reset_keeping_memory :: (inputField: *InputField) {
	inputField.text.count = 0;
	inputField.cursor = 0;
}

input_field_get_text :: (inputField: *InputField) -> string {
	return string.{inputField.text.count, inputField.text.data};
}

input_field_backward_delete :: (inputField: *InputField) {
	before := inputField.text.count;
	inputField.text.count = max(inputField.text.count - 1, 0);
	inputField.cursor = max(inputField.cursor - 1, 0);
	if inputField.onEditCallback && before != inputField.text.count {
		inputField.onEditCallback(inputField.userData, input_field_get_text(inputField));
	}
}

Utf8_Char :: struct {
	bytes: [4] u8;
	count: s32;
}

get_app_base_path :: () -> string {
	#if BUILD_TYPE == .SHIPPING {
		return path_strip_filename(get_path_of_running_executable());
	}
	else {
		exePath := path_strip_filename(get_path_of_running_executable());
		return tprint("%../../", exePath);
	}
}

// normalizes separators and ensures there's no trailing slash
path_normalized :: (path: string) -> string {
	result := copy_string(path);
	path_overwrite_separators(result, #char "/");
	while result.count > 1 && result[result.count-1] == #char "/" {
		result.count -= 1;
	}
	return result;
}

bucket_array_find_or_null :: ( using array: *Bucket_Array, locator: Bucket_Locator) -> *array.type {
	bucket := all_buckets[locator.bucket_index];
	if bucket.occupied[locator.slot_index] == false return null;
	result := *bucket.data[locator.slot_index];
	return result;
}

assertion_failed :: (loc: Source_Code_Location, message: string) -> bool {
	if message {
		log("%:%,%: Assertion failed: %\n", loc.fully_pathed_filename, loc.line_number, loc.character_number, message);
	}
	else {
		log("%:%,%: Assertion failed!\n", loc.fully_pathed_filename, loc.line_number, loc.character_number);
	}

	log_stack_trace :: (node: *Stack_Trace_Node, log_flags := Log_Flags.ERROR) {
		while node {
			if node.info {
				if node.info.name {
					log("%:%: %", node.info.location.fully_pathed_filename, node.line_number, node.info.name);
				}
				else {
					log("%:%: (anonymous procedure)", node.info.location.fully_pathed_filename, node.line_number);
				}
			}
			node = node.next;
		}
	}
	if context.stack_trace {
		log("Stack trace:");
		log_stack_trace(context.stack_trace);
	} else {
		log("Exiting.");
	}

	__runtime_support_disable_stack_trace = true;

	return true;
}



#if BUILD_TYPE == .SHIPPING {
	#import "Basic"()(MEMORY_DEBUGGER = false);
}
else {
	#import "Basic"()(MEMORY_DEBUGGER = true);
}
Input :: #import "Input";
#import "Window_Creation";
#import "Process";
#import "Math";
#import "System";
#import "String";
#import "File";
#import "Hash";
#import "File_Utilities";
#import "Unicode";
#import "Sort";
#import "Flat_Pool";
#import "Hash_Table";
#import "Clipboard";
#import "Command_Line";
#import "File_Watcher";
#import "Bucket_Array";
#import "treesitter";
#import "uniform";
#import "Text_File_Handler";
#import "Thread";
#import "UI";

#load "command_palette.jai";
#load "command_system.jai";
#load "commands.jai";
#load "panel.jai";
#load "async.jai";
#load "document.jai";
#load "project.jai";
#load "watcher.jai";
#load "language.jai";
#load "registers.jai";

#if OS == .WINDOWS {
	#load "platform_windows.jai";
	#import "Windows_Resources";
}
