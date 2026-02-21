BuildType :: enum u8
{
	DEBUG;
	OPTIMIZED;
	RELEASE;
}

DialogType :: enum u8 {
	NONE;
	COMMAND_PICKER;
	FILESYSTEM_NAVIGATOR;
	FILE_FINDER;
	SEARCH;
}

EditorMode :: enum u8 {
	NORMAL;
	INSERT;
	DIALOG;
}

Notification :: struct {
	content: string;
	timer: float64;
}

style : struct {
	// colors
	backgroundDark := #run hex_to_color_vec4("1C1F25");
	backgroundMid := #run hex_to_color_vec4("282C34");
	backgroundLight := #run hex_to_color_vec4("3B414C");
	backgroundLighter := #run hex_to_color_vec4("4e5665");

	hotHighlight := #run hex_to_color_vec4("636f85");
	activeHighlight := #run hex_to_color_vec4("7e90bd");

	textPrimary := #run hex_to_color_vec4("C3C7D0");
	textSecondary := #run hex_to_color_vec4("5C6370");
	textHighlight := #run hex_to_color_vec4("7e90bd");
	textSelection := #run hex_to_color_vec4("434d60");

	borders := #run hex_to_color_vec4("5C6476");

	// fonts
	fontSize := 15;
	codeFont := string.["CaskaydiaMonoNerdFont-Regular.ttf", "consola.ttf"];
	uiFont := string.["segoeui.ttf"];

	// Icons
	iconVerticalEllipsis :: #run to_string(*convert_utf32_to_utf8(0xf142));
	iconCircle :: #run to_string(*convert_utf32_to_utf8(0xf111));
	iconLock :: #run to_string(*convert_utf32_to_utf8(0xf023));
	iconNumList :: #run to_string(*convert_utf32_to_utf8(0xf0cb));
	iconAlignLeft :: #run to_string(*convert_utf32_to_utf8(0xf036));
	iconFolder :: #run to_string(*convert_utf32_to_utf8(0xf07c));
	iconFile :: #run to_string(*convert_utf32_to_utf8(0xf15b));
	iconSpinner :: #run to_string(*convert_utf32_to_utf8(0xf110));

	// animations
	scrollAnimRate := 14;

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
#place codeDefault;
	codeColors: [HighlightType.COUNT]Vector4 = ---;
};

EDITOR_MODE_NUM :: #run enum_highest_value(EditorMode) + 1;

// globals
editorMode := EditorMode.NORMAL;
focusedPanel : Panel;
watcher: File_Watcher(void);
watchedFiles: [..]string;
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

// current project (only one active at a time)
project: Project;

notifications : [10]Notification;
numActiveNotifications := 0;
notificationTime: float64 = 10;

// registers
DEFAULT_REGISTER :: #char "+";
Registers :: struct {
	registerPool: Flat_Pool;
	registerAllocator: Allocator;
	table: Table(u8, [..]u8);
	selectedRegister:u8 = DEFAULT_REGISTER;
}
registers: Registers;

// fonts
fontUI: *Font;
fontCode: *Font;
fontIcons: *Font;

// options
textSize :: 15;
tabSize :: 4;
lineNumbers := true;

Arguments :: struct {
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
	file :=  file_open(tprint("%/photon.log", path_strip_filename(get_path_of_running_executable())), for_writing=true, keep_existing_content=false);
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
	init_renderer(window);
	init_font_cache();
	load_fonts();
	init_ui();
	rebuild_key_map();
	init_async(*asyncWorker);
	init(*openDocumentLock);
	init(*languagesMutex);

	registers.registerAllocator = Allocator.{ proc = flat_pool_allocator_proc, data = *registers.registerPool };

	if !init(*watcher, file_change_callback, watch_recursively = false) {
		push_notification("Could not initialize the file watcher. Files won't be reloaded. This is likely a bug.");
	}

	focusedPanel.layoutRect.x = 0;
	focusedPanel.layoutRect.y = 0;
	focusedPanel.layoutRect.w = xx windowWidth;
	focusedPanel.layoutRect.h = xx windowHeight;
	focusedPanel.activeDialog = .NONE;

	if filesToOpen.count > 0 {
		doc := document_get_or_open(filesToOpen[0]);

		if doc {
			panel_set_active_document(*focusedPanel, doc);
		}
	}

	// test projects
	// Note, this should be done _after the document is loaded so that it doesn't block the
	// parsing job of the opening document
	// does the beg the question of what happens if you open a big file? Does project loading _wait_ until it's done?
	// The other option is that project loading stays on it's own thread similar to focus?
	// means we either need a second async worker, or a thread group?
	// I guess you could literally have a second async worker dedicated to project stuff?
	// Have to be careful though to keep them separate and touching different things
	// potentially we have a "file operations async worker" for opening, saving, parsing, calculating line length etc
	// and a "project async worker" which handles filesystem scanning and such things
	success, project = project_parser("photon.photon-project");
	// project_begin_load();

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

			resize_backbuffer();

			focusedPanel.layoutRect.x = 0;
			focusedPanel.layoutRect.y = 0;
			focusedPanel.layoutRect.w = xx windowWidth;
			focusedPanel.layoutRect.h = xx windowHeight;
		}
	}

	for Input.events_this_frame {
		if it.type == .QUIT then pendingQuit = true;
		array_add(*uiState.events, it);
	}

	project_update();
	process_changes(*watcher);

	newDpiScale := platform_get_dpi_scale(window);
	if newDpiScale != dpiScale && newDpiScale != 0.0 {
		dpiScale = newDpiScale;
	}

	build_ui();

	// after ui has taken any inputs it wants, we'll give the rest to the default input handler
	for uiState.events {
		input_handler(it);
	}
	array_reset_keeping_memory(*uiState.events);

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
		memcpy(notifications.data, notifications.data + nNotificationsToRemove, (numActiveNotifications - nNotificationsToRemove)*size_of(Notification));
		numActiveNotifications -= nNotificationsToRemove;
	}
	if numActiveNotifications > 0 {
		requestRedraw = true;
	}

	// @todo: may want to support 120hz or higher? 
	reset_temporary_storage();
}

build_ui :: () {
	begin_ui();

	uiState.defaultPalette = .{
		text = style.textPrimary,
		textHighlight = style.textHighlight,
		background=style.backgroundMid,
		hot=style.hotHighlight,
		active=style.activeHighlight,
		border=style.borders
	};
	uiState.defaultFont = fontUI;
	uiState.defaultFontSize = style.fontSize * dpiScale;
	uiState.defaultTextPadding = em(0.2);

	// Draw notifications
	
	fontMetrics := get_font_metrics(uiState.defaultFont, xx uiState.defaultFontSize);

	maxWidth := 0.0;
	for * notifications {
		textRun := generate_text_run(it.content, xx uiState.defaultFontSize, uiState.defaultFont,,temp);
		maxWidth = max(maxWidth, textRun.width);
	}

	it := numActiveNotifications;
	notificationBox := box(ui_key("notifBox"), .{
		flags=0,
		layout=.{
			childLayoutAxis = .Y,
			width=fit(),
			height=fit(),
			childAlignment=.RIGHT,
			childGap=em(0.5)
		},
		fixedX= windowWidth - maxWidth - em(2.5),
		fixedY= em(3.0),
	});
	{
		push_parent(notificationBox); defer pop_parent();
		while it > 0 {
			notif := notifications[it-1];
			fadeOutTime := cast(float) notificationTime*0.3;
			timeFactor := cast(float) clamp(notif.timer, 0.0, fadeOutTime) / fadeOutTime;
			alpha := lerp(0.0, 1.0, timeFactor);

			backgroundCol := style.activeHighlight;
			backgroundCol.w = alpha;
			textCol := style.backgroundMid;
			textCol.w = alpha;
			box(ui_key("%##%", notif.content, it), .{
				flags=.DRAW_TEXT | .DRAW_BACKGROUND,
				layout=.{ width=text_content(), height=text_content() },
				palette=.{background=backgroundCol, text=textCol},
				textPadding=em(0.4),
				cornerRadius=corner_rad_all(em(0.3))
			});
			it -= 1;
		}
	}
	
	// Draw the panel
	if focusedPanel.document {
		if focusedPanel.document.tree {
			build_ui_panel(*focusedPanel);
		}
		else {
			build_ui_loading_panel(*focusedPanel);
		}
	}
	else {
		build_ui_empty_panel(*focusedPanel);
	}

	end_ui();

	render_frame();
}

build_ui_empty_panel :: (panel: *Panel) {
	panelBox := box(ui_key("panel1"), .{
		flags=.DRAW_BACKGROUND,
		layout=.{
			childLayoutAxis = .Y,
			width=fixed(panel.layoutRect.w),
			height=fixed(panel.layoutRect.h),
			childAlignment=.CENTER
		},
	});
	push_parent(panelBox); defer pop_parent();

	header := box(ui_key_nil, .{
		flags=.DRAW_BACKGROUND | .DRAW_SIDE_BOTTOM,
		layout=.{ 
			childLayoutAxis = .X,
			width=grow(),
			height=fit(),
			padding= padding_all(em(0.3))
		},
		palette=.{ background=style.backgroundLight },
		borderThickness=1.0
	});
	{
		push_parent(header); defer pop_parent();
		box(ui_key("DUMMY"), .{
			flags=0,
			layout=.{ width=text_content(), height=text_content() },
		});
	}
	

	build_ui_panel_dialogs(panel);

	spacer(.Y, fixed(em(5.0)));

	box(ui_key("No Document Loaded"), .{
		flags=.DRAW_TEXT,
		layout=.{ width=text_content(), height=text_content() },
	});

	spacer(.Y, fixed(em(3.0)));

	box(ui_key("Open file with '<space>O'"), .{
		flags=.DRAW_TEXT,
		layout=.{ width=text_content(), height=text_content() },
	});
	box(ui_key("Open command palette with ':'"), .{
		flags=.DRAW_TEXT,
		layout=.{ width=text_content(), height=text_content() },
	});
}

build_ui_loading_panel :: (panel: *Panel) {
	panelBox := box(ui_key("panel1"), .{
		flags=.DRAW_BACKGROUND,
		layout=.{
			childLayoutAxis = .Y,
			width=fixed(panel.layoutRect.w),
			height=fixed(panel.layoutRect.h),
			childAlignment=.CENTER
		},
	});
	push_parent(panelBox); defer pop_parent();

	header := box(ui_key_nil, .{
		flags=.DRAW_BACKGROUND | .DRAW_SIDE_BOTTOM,
		layout=.{ 
			childLayoutAxis = .X,
			width=grow(),
			height=fit(),
			padding= padding_all(em(0.3))
		},
		palette=.{ background=style.backgroundLight },
		borderThickness=1.0
	});
	{
		push_parent(header); defer pop_parent();
		box(ui_key("DUMMY"), .{
			flags=0,
			layout=.{ width=text_content(), height=text_content() },
		});
	}

	spacer(.Y, fixed(em(5.0)));
	
	shouldShowSpinner :=  asyncWorker.pendingTasks != 0 && to_milliseconds(current_time_monotonic() - asyncWorker.waitStartTime) > 33;
	if shouldShowSpinner {
		loadingBox := box(ui_key_nil, .{
			layout=.{ 
				childLayoutAxis = .X,
				width=fit(),
				height=fit(),
				padding= padding_all(em(0.3))
			},
		});
		{
			push_parent(loadingBox); defer pop_parent();
			box(ui_key("Loading % ...", panel.document.path), .{
				flags=.DRAW_TEXT,
				layout=.{ width=text_content(), height=text_content() },
			});

			spinner := box(ui_key_nil, .{
				layout=.{ width=text_content(), height=text_content() },
				fontSize=em(1.0),
				font=fontIcons
			});
			spinner.customDrawFunction = custom_draw_spinner;
			spinner.customDrawUdata = cast(*void) panel;
		}
	}
}

build_ui_panel :: (panel: *Panel) {
	panelBox := box(ui_key("panel1"), .{
		flags=.DRAW_BACKGROUND,
		layout=.{childLayoutAxis = .Y, width=fixed(panel.layoutRect.w), height=fixed(panel.layoutRect.h)},
	});
	push_parent(panelBox); defer pop_parent();

	header := box(ui_key_nil, .{
		flags=.DRAW_BACKGROUND | .DRAW_SIDE_BOTTOM,
		layout=.{ 
			childLayoutAxis = .X,
			width=grow(),
			height=fit(),
			padding= padding_all(em(0.3)),
			childAlignment=.CENTER
		},
		palette=.{ background=style.backgroundLight },
		borderThickness=1.0
	});
	{
		push_parent(header); defer pop_parent();

		// mode
		modeText := "NORMAL";
		if editorMode == .INSERT {
			modeText = "INSERT";
		}
		box(ui_key(modeText), .{
			flags=.DRAW_BACKGROUND | .DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
			palette=.{ background=style.backgroundDark },
		});

		spacer(.X, fixed(em(0.5)));

		// filename
		fileLabel := box(ui_key(path_filename(panel.document.path)), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});
		if signal_from_box(fileLabel).hovering {
			tooltip_begin(fileLabel.key, .{0.0, em(1.9)});
			box(ui_key(panel.document.path), .{
				flags=.DRAW_TEXT,
				layout=.{ width=text_content(), height=text_content() },
			});
			tooltip_end();
		}

		// lock icon @todo: implement for real
		if false {
			box(ui_key(style.iconLock), .{
				flags=.DRAW_TEXT,
				layout=.{ width=text_content(), height=text_content() },
				fontSize=em(0.7),
				font=fontIcons
			});
		}

		// icon for file save status
		if document_is_unsaved(panel.document) {
			box(ui_key(style.iconCircle), .{
				flags=.DRAW_TEXT,
				layout=.{ width=text_content(), height=text_content() },
				fontSize=em(0.7),
				font=fontIcons
			});
		}

		spacer(.X, grow());

		// pending keys
		pendingKeys := string.{keyMap.pendingKeyString.count, keyMap.pendingKeyString.data};
		box(ui_key(pendingKeys), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});

		if project.loadProgress != .COMPLETE || (asyncWorker.pendingTasks != 0 && to_milliseconds(current_time_monotonic() - asyncWorker.waitStartTime) > 33) {
			spacer(.X, fixed(em(2.0)));

			spinner := box(ui_key_nil, .{
				layout=.{ width=text_content(), height=text_content() },
				fontSize=em(1.0),
				font=fontIcons
			});
			spinner.customDrawFunction = custom_draw_spinner;
			spinner.customDrawUdata = cast(*void) panel;
		}

		spacer(.X, fixed(em(2.0)));

		// location
		cursorCoordinate := get_coordinate_from_offset(panel.document, panel.cursor.head);
		box(ui_key("Ln: % Col: % Byte: %", cursorCoordinate.line+1, cursorCoordinate.col, panel.cursor.head), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});

		spacer(.X, fixed(em(2.0)));

		// line endings
		lineEndingText := "[Mixed]";
		if panel.document.lineEndings == .LF {
			lineEndingText = "LF";
		}
		else if panel.document.lineEndings == .CRLF {
			lineEndingText = "CRLF";
		}
		else if panel.document.lineEndings == .MIXED_MAJORITY_LF {
			lineEndingText = "[Mixed]";
		}
		box(ui_key(lineEndingText), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});

		spacer(.X, fixed(em(2.0)));

		// file type
		// @todo
		box(ui_key("jai"), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});

		spacer(.X, fixed(em(2.0)));

		// panel options button
		panelOptsKey := ui_key("panelopts");
		if is_context_menu_open(panelOptsKey) { 
			button := box(ui_key(style.iconVerticalEllipsis), .{
				flags=.DRAW_BACKGROUND | .DRAW_TEXT | .MOUSE_CLICKABLE,
				layout=.{ width=fixed(em(1.5)), height=text_content() },
				palette=.{background=style.activeHighlight},
				font=fontIcons,
				textAlignment=.CENTER,
				cornerRadius=corner_rad_all(em(0.3))
			});
			if signal_from_box(button).pressed {
				context_menu_close();
			}
		}
		else {
			button := box(ui_key(style.iconVerticalEllipsis), .{
				flags=.DRAW_BACKGROUND | .DRAW_TEXT | .DRAW_HOT_EFFECTS | .MOUSE_CLICKABLE,
				layout=.{ width=fixed(em(1.5)), height=text_content() },
				font=fontIcons,
				textAlignment=.CENTER,
				cornerRadius=corner_rad_all(em(0.3))
			});
			if signal_from_box(button).pressed {
				context_menu_open(panelOptsKey);
			}
		}

		if context_menu_begin(key=panelOptsKey,
								width=fixed(em(12.0)),
								anchorBoxKey=ui_key(style.iconVerticalEllipsis),
								anchorOffset=.{0.0, em(1.9)}) {

			if context_menu_item("Line Numbers", style.iconNumList).pressed {
				lineNumbers = !lineNumbers;
			}
			context_menu_item("View Line Endings", "");
			context_menu_item("Line Wrapping", style.iconAlignLeft);
			context_menu_end();
		}
	}

	build_ui_panel_dialogs(panel);

	// Draw the main code screen
	codeContainerOuter := box(ui_key_nil, .{
		flags=.DRAW_BACKGROUND,
		layout=.{childLayoutAxis = .Y, width=grow(), height=grow()},
	});
	{
		push_parent(codeContainerOuter); defer pop_parent();

		
		longestLinePixelWidth:= 0.0;

		codeContainerInner := box(ui_key_nil, .{
			flags=.DRAW_BACKGROUND,
			layout=.{childLayoutAxis = .X, width=grow(), height=grow()},
		});
		{
			push_parent(codeContainerInner); defer pop_parent();

			codeBox := box(ui_key("code"), .{
				flags=.CLIP_CONTENTS | .MOUSE_CLICKABLE,
				layout=.{width=grow(), height=grow()},
				font=fontCode
			});
			codeBox.customDrawFunction = custom_draw_code;
			codeBox.customDrawUdata = cast(*void) panel;

			numDocumentLines := get_number_of_lines(panel.document);
			metrics := get_font_metrics(codeBox.font, xx codeBox.fontSize);
			codeBox.viewBounds.y = cast(float, -(metrics.lineSpacing * numDocumentLines) + metrics.lineSpacing * 5);

			// TODO: cache this calculation, it won't change much and it can be slow
			longestLinePixelWidth = cast(float, generate_text_run(get_line_content(panel.document, panel.document.longestLine-1,,temp).text, xx codeBox.fontSize, codeBox.font,,temp).width);

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
			set_cursor_to_mouse_location :: (doc: *Document, cursor: *Cursor, numDocumentLines: s64, box: *UIBox) {
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
				cursor.head = lineContent.startByteOffset + column;
				cursor.anchor = cursor.head;

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
				set_cursor_to_mouse_location (panel.document, *panel.cursor, numDocumentLines, codeBox);
				panel.cursor.head = panel.cursor.anchor;
			}

			if signal.holding {
				set_cursor_to_mouse_location (panel.document, *panel.cursor, numDocumentLines, codeBox);
				x, y, success := get_mouse_pointer_position(window, false);
				if y > cast(int, codeBox.rect.y + codeBox.rect.h) {
					_, range := panel_calculate_visible_lines(panel);
					currentLine := get_coordinate_from_offset(panel.document, panel.cursor.head).line;
					panel_scroll_to_line(panel, currentLine - range);
				}
				else if y < cast(int, codeBox.rect.y) {
					currentLine := get_coordinate_from_offset(panel.document, panel.cursor.head).line;
					panel_scroll_to_line(panel, currentLine);
				}
			}

			scrollData:= scroll_bar(ui_key("codeScrollVertical"),
									.Y,
									codeBox.viewOffset.y/codeBox.viewBounds.y,
									cast(float, numDocumentLines),
									codeBox.rect.h/metrics.lineSpacing,
									ui_key("code"));
		}

		success, codeBox:= find_box(ui_key("code"));
		scrollData:= scroll_bar(ui_key("codeScrollHorizontal"),
								.X,
								codeBox.viewOffset.x/codeBox.viewBounds.x,
								longestLinePixelWidth,
								codeBox.rect.w,
								ui_key("code"));
	}

	// Draw the search dialog
	if panel.activeDialog == .SEARCH {
		searchContainer := box(ui_key_nil, .{
			flags=.DRAW_BACKGROUND | .DRAW_SIDE_TOP,
			layout=.{ 
				childLayoutAxis = .X,
				width=grow(),
				height=fit(),
				padding= padding_all(em(0.4))
			},
			palette=.{ background=style.backgroundLight },
			borderThickness=1.0
		});
		{
			push_parent(searchContainer); defer pop_parent();

			fontMetrics := get_font_metrics(uiState.defaultFont, xx uiState.defaultFontSize);
			inputBox := box(ui_key("search_input"), .{
				flags=.DRAW_BACKGROUND,
				layout=.{
					width=grow(),
					height=fixed(fontMetrics.lineSpacing+em(0.8)),
				},
				cornerRadius=corner_rad_all(em(0.2)),
				palette=.{ background=style.backgroundLighter },
				font=fontCode,
				textPadding=em(0.5)
			});
			inputBox.customDrawFunction = custom_draw_input_field;
			inputBox.customDrawUdata = cast(*void, *panel.searchInput);

			// @todo: buttons for regex mode, caps, whole word search etc
		}
	}
}

build_ui_panel_dialogs :: (panel: *Panel) {
	if panel.activeDialog == .COMMAND_PICKER {
		commandPickerContainer := box(ui_key_nil, .{
			flags=.DRAW_BACKGROUND,
			layout=.{ 
				childLayoutAxis = .Y,
				width=fixed(panel.layoutRect.w / 2),
				height=fit(),
				padding= padding_all(em(0.4)),
			},
			palette=.{ background=style.backgroundLight },
			cornerRadius=corner_rad_all(em(0.5)),
			fixedX=panel.layoutRect.x+(panel.layoutRect.w-(panel.layoutRect.w/2))/2,
			fixedY=em(3.0)
		});
		{
			push_parent(commandPickerContainer); defer pop_parent();

			fontMetrics := get_font_metrics(uiState.defaultFont, xx uiState.defaultFontSize);
			inputBox := box(ui_key("commandPickerInput"), .{
				flags=.DRAW_BACKGROUND,
				layout=.{
					width=grow(),
					height=fixed(fontMetrics.lineSpacing+em(0.8)),
				},
				cornerRadius=corner_rad_all(em(0.2)),
				palette=.{ background=style.backgroundLighter },
				textPadding=em(0.5)
			});

			inputBox.customDrawFunction = custom_draw_input_field;
			inputBox.customDrawUdata = cast(*void, *panel.commandPicker.input);

			elementHeight := cast(float, fontMetrics.characterHeight*2);
			rangeStart, rangeEnd := scroll_list_begin(ui_key("commandList"),
								panel.layoutRect.h/2,
								elementHeight,
								panel.commandPicker.numToDisplay,
								panel.commandPicker.selectedCommand,
								panel.commandPicker.selectedCommandChange);

			if panel.commandPicker.selectedCommandChange then panel.commandPicker.selectedCommandChange = false;

			for rangeStart..rangeEnd {
				commandEntry := panel.commandPicker.filteredCommandList[it];

				if commandEntry.sortKey == 0 continue;

				// @todo: may be desirable to use the UI focus (hot/active) system for this?
				entryFlags:UIBoxFlags = 0;
				if it == panel.commandPicker.selectedCommand {
					entryFlags |= .DRAW_BACKGROUND;
				}

				entryBox := box(ui_key("commandEntry##%", it), .{
					flags=entryFlags, layout=.{ width=grow(), height=fixed(elementHeight), padding=padding_all(em(0.2)), childAlignment=.CENTER },
					palette=.{ background=style.backgroundLighter },
				});
				{
					push_parent(entryBox); defer pop_parent();

					// find the normal mode mapping
					// @todo: should we show bindings for all modes?
					mappingStr := "";
					for commandEntry.command.mappings {
						// TODO
						// if it.mode == .NORMAL then mappingStr = it;
						mappingStr = it;
					}

					commandLabel := box(ui_key("%", commandEntry.command.name), .{
						flags=.DRAW_TEXT_HIGHLIGHTS,
						layout=.{ width=text_content(), height=text_content() },
					});
					commandLabel.textHighlights = commandEntry.fuzzyMatches;

					box(ui_key_nil, .{ layout=.{width=grow()}});

					if mappingStr {
						box(ui_key("%##%", mappingStr, it), .{
							flags=.DRAW_TEXT | .DRAW_BACKGROUND,
							layout=.{ width=text_content(), height=text_content() },
							palette=.{ background=style.backgroundMid },
							textPadding=em(0.3)
						});
					}
				}
			}

			scroll_list_end(ui_key("commandListScroller")); 

			hintsBox := box(ui_key("hintsBox"), .{
				flags=.DRAW_SIDE_TOP,
				layout=.{ 
					childLayoutAxis = .X,
					width=grow(),
					height=fit(),
				},
				borderThickness=1.0
			});
			{
				push_parent(hintsBox); defer pop_parent();

				spacer(.X, grow());

				textCol := uiState.defaultPalette.text;
				textCol.w = 0.6;
				box(ui_key("<up><down> to navigate <enter> to use <escape> to dismiss"), .{
					flags=.DRAW_TEXT,
					layout=.{ width=text_content(), height=text_content() },
					textAlignment=.CENTER,
					textPadding=em(0.5),
					palette=.{text = textCol}
				});

				spacer(.X, grow());
			}
		}
	}

	if panel.activeDialog == .FILESYSTEM_NAVIGATOR {
		fileNavContainer := box(ui_key_nil, .{
			flags=.DRAW_BACKGROUND,
			layout=.{ 
				childLayoutAxis = .Y,
				width=fixed(panel.layoutRect.w / 2),
				height=fit(),
				padding= padding_all(em(0.4)),
			},
			palette=.{ background=style.backgroundLight },
			cornerRadius=corner_rad_all(em(0.5)),
			fixedX=panel.layoutRect.x+(panel.layoutRect.w-(panel.layoutRect.w/2))/2,
			fixedY=em(3.0)
		});
		{
			push_parent(fileNavContainer); defer pop_parent();

			fontMetrics := get_font_metrics(uiState.defaultFont, xx uiState.defaultFontSize);
			inputBox := box(ui_key_nil, .{
				flags=.DRAW_BACKGROUND,
				layout=.{
					width=grow(),
					height=fixed(fontMetrics.lineSpacing+em(0.8)),
					childLayoutAxis=.X,
					padding=padding_all(em(0.4)),
					childGap=em(0.2)
				},
				cornerRadius=corner_rad_all(em(0.2)),
				palette=.{ background=style.backgroundLighter },
				textPadding=em(0.5)
			});

			// draw existing path sections
			{
				push_parent(inputBox); defer pop_parent();

				for panel.filesystemNav.currentPath {
					pathSectionLabel := box(ui_key("%##path_section%", it, it_index), .{
						flags=.DRAW_TEXT | .DRAW_BACKGROUND,
						layout=.{ width=text_content(), height=text_content() },
					});
				}

				inputArea := box(ui_key("fileNavInput"), .{
					flags=0,
					layout=.{
						width=grow(),
						height=fixed(xx fontMetrics.lineSpacing),
						childLayoutAxis=.X
					},
				});

				inputArea.customDrawFunction = custom_draw_input_field;
				inputArea.customDrawUdata = cast(*void, *panel.filesystemNav.input);
			}

			elementHeight := cast(float, fontMetrics.characterHeight*2);
			rangeStart, rangeEnd := scroll_list_begin(ui_key("fileNav_fileList"),
								panel.layoutRect.h/2,
								elementHeight,
								panel.filesystemNav.numToDisplay,
								panel.filesystemNav.selectedItem,
								panel.filesystemNav.selectedItemChanged);

			if panel.filesystemNav.selectedItemChanged then panel.filesystemNav.selectedItemChanged = false;

			for rangeStart..rangeEnd {
				directoryItem := panel.filesystemNav.itemList[it];
				if directoryItem.sortKey == 0 continue;

				if directoryItem.saveItem == true {
					builder: String_Builder;
					builder.allocator = temp;
					init_string_builder(*builder);

					append(*builder, "Save As - ");
					for panel.filesystemNav.currentPath {
						append(*builder, it);
						if (it_index != panel.filesystemNav.currentPath.count-1)  append(*builder, "/");
					}
					append(*builder, "/");
					append(*builder, input_field_get_text(*panel.filesystemNav.input));

					entryBox := box(ui_key("savefileItem"), .{
						flags=.DRAW_BACKGROUND,
						layout=.{
							width=grow(),
							height=fixed(elementHeight),
							padding=padding_all(em(0.2)),
							childAlignment=.CENTER
						},
						palette=.{ background=style.backgroundLighter },
					});
					{
						push_parent(entryBox); defer pop_parent();
						itemLabel := box(ui_key("%", builder_to_string(*builder,,temp)), .{
							flags=.DRAW_TEXT_HIGHLIGHTS,
							layout=.{ width=text_content(), height=text_content() },
						});
					}
				}
				else {

					// @todo: may be desirable to use the UI focus (hot/active) system for this?
					entryFlags:UIBoxFlags = 0;
					if it == panel.filesystemNav.selectedItem {
						entryFlags |= .DRAW_BACKGROUND;
					}

					entryBox := box(ui_key("directoryItem##%", it), .{
						flags=entryFlags, layout=.{ width=grow(), height=fixed(elementHeight), padding=padding_all(em(0.2)) },
						palette=.{ background=style.backgroundLighter },
					});
					{
						push_parent(entryBox); defer pop_parent();

						box(ui_key("%##%", ifx directoryItem.isDirectory then style.iconFolder else style.iconFile, it), .{
							flags=.DRAW_TEXT,
							layout=.{ width=text_content(), height=text_content() },
							font=fontIcons
						});

						itemLabel := box(ui_key("%##commandEntry%", directoryItem.name, it), .{
							flags=.DRAW_TEXT_HIGHLIGHTS,
							layout=.{ width=text_content(), height=text_content() },
						});
						itemLabel.textHighlights = directoryItem.fuzzyMatches;
					}
				}
			}

			scroll_list_end(ui_key("filesystemNavScroller")); 

			hintsBox := box(ui_key("hintsBox"), .{
				flags=.DRAW_SIDE_TOP,
				layout=.{ 
					childLayoutAxis = .X,
					width=grow(),
					height=fit(),
				},
				borderThickness=1.0
			});
			{
				push_parent(hintsBox); defer pop_parent();

				spacer(.X, grow());

				textCol := uiState.defaultPalette.text;
				textCol.w = 0.6;
				box(ui_key("<up><down> to navigate <enter> to open file/directory <escape> to dismiss"), .{
					flags=.DRAW_TEXT,
					layout=.{ width=text_content(), height=text_content() },
					textAlignment=.CENTER,
					textPadding=em(0.5),
					palette=.{text = textCol}
				});

				spacer(.X, grow());
			}
		}
	}


	
	if panel.activeDialog == .FILE_FINDER {
		fileFinderContainer := box(ui_key_nil, .{
			flags=.DRAW_BACKGROUND,
			layout=.{ 
				childLayoutAxis = .Y,
				width=fixed(panel.layoutRect.w / 2),
				height=fit(),
				padding= padding_all(em(0.4)),
			},
			palette=.{ background=style.backgroundLight },
			cornerRadius=corner_rad_all(em(0.5)),
			fixedX=panel.layoutRect.x+(panel.layoutRect.w-(panel.layoutRect.w/2))/2,
			fixedY=em(3.0)
		});
		{
			push_parent(fileFinderContainer); defer pop_parent();

			fontMetrics := get_font_metrics(uiState.defaultFont, xx uiState.defaultFontSize);
			inputBox := box(ui_key("fileFinderInput"), .{
				flags=.DRAW_BACKGROUND,
				layout=.{
					width=grow(),
					height=fixed(fontMetrics.lineSpacing+em(0.8)),
				},
				cornerRadius=corner_rad_all(em(0.2)),
				palette=.{ background=style.backgroundLighter },
				textPadding=em(0.5)
			});

			inputBox.customDrawFunction = custom_draw_input_field;
			inputBox.customDrawUdata = cast(*void, *panel.fileFinder.input);

			elementHeight := cast(float, fontMetrics.characterHeight*3);
			rangeStart, rangeEnd := scroll_list_begin(ui_key("fileList"),
								panel.layoutRect.h/2,
								elementHeight,
								panel.fileFinder.numToDisplay,
								panel.fileFinder.selectedEntry,
								panel.fileFinder.selectedEntryChanged);

			if panel.fileFinder.selectedEntryChanged then panel.fileFinder.selectedEntryChanged = false;

			for rangeStart..rangeEnd {
				entry := panel.fileFinder.fileList[it];

				if entry.sortKey == 0 continue;

				// @todo: may be desirable to use the UI focus (hot/active) system for this?
				entryFlags:UIBoxFlags = 0;
				if it == panel.fileFinder.selectedEntry {
					entryFlags |= .DRAW_BACKGROUND;
				}

				entryBox := box(ui_key("entry##%", it), .{
					flags=entryFlags, layout=.{
						width=grow(),
						height=fixed(elementHeight),
						padding=padding_all(em(0.2)),
						childLayoutAxis=.Y
					},
					palette=.{ background=style.backgroundLighter },
				});
				{
					push_parent(entryBox); defer pop_parent();


					key := ui_key("%##fileListEntryLabel%-%", path_filename(entry.filePath), entry.locator.bucket_index, entry.locator.slot_index);
					fileLabel := box(key, .{
						flags=.DRAW_TEXT_HIGHLIGHTS,
						layout=.{ width=text_content(), height=text_content() },
					});
					fileLabel.textHighlights = entry.fuzzyMatches;

					key2 := ui_key("%##fileListPathLabel%-%", entry.filePath, entry.locator.bucket_index, entry.locator.slot_index);
					pathLabel := box(key2, .{
						flags=.DRAW_TEXT,
						fontSize=em(0.7),
						layout=.{ width=text_content(), height=text_content() },
					});
				}
			}

			scroll_list_end(ui_key("fileFinderScroller")); 

			hintsBox := box(ui_key("hintsBox"), .{
				flags=.DRAW_SIDE_TOP,
				layout=.{ 
					childLayoutAxis = .X,
					width=grow(),
					height=fit(),
				},
				borderThickness=1.0
			});
			{
				push_parent(hintsBox); defer pop_parent();

				spacer(.X, grow());

				textCol := uiState.defaultPalette.text;
				textCol.w = 0.6;
				box(ui_key("<up><down> to navigate <enter> to open file <escape> to dismiss"), .{
					flags=.DRAW_TEXT,
					layout=.{ width=text_content(), height=text_content() },
					textAlignment=.CENTER,
					textPadding=em(0.5),
					palette=.{text = textCol}
				});

				spacer(.X, grow());
			}
		}
	}
}

custom_draw_spinner :: (box: *UIBox, udata: *void) {
	// there's no simple way to make a box rotate so for now spinners have custom drawing code
	// that let us rotate them in the shader
	
	box.textRun = generate_text_run(style.iconSpinner, xx box.fontSize, box.font,,temp);
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
	instance.color = box.palette.text;
	instance.angle = cast(float, time) / 1000.0 * 10;
	submit_instance(instance);

}

custom_draw_input_field :: (box: *UIBox, udata: *void) {
	inputField:*InputField = cast(*InputField)udata;

	// draw the input field text
	box.textRun = generate_text_run(string.{inputField.text.count, inputField.text.data}, xx box.fontSize, box.font,,temp);
	metrics := get_font_metrics(box.font, xx box.fontSize);
	yPos := floor(box.rect.y + box.rect.h/2.0) + floor(box.fontSize/2.0) - 1.0;
	xPos := box.rect.x;

	xPos += box.textPadding;
	xPos = floor(xPos);
	draw_text_run(box.textRun, xPos, yPos, box.palette.text);

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
		color = ifx editorMode == .INSERT then .{1.0, 1.0, 1.0, 1.0} else style.textPrimary,
		shader = .RECTS
	});
}

// @todo: probably want to move this somewhere else? Potentially the panel file?
custom_draw_code :: (box: *UIBox, udata: *void) {
	panel:*Panel = cast(*Panel)udata;

	if panel.document && get_size(panel.document) > 0 {
		metrics := get_font_metrics(box.font, xx box.fontSize);
		documentLines := get_number_of_lines(panel.document);

		cursorLine := get_coordinate_from_offset(panel.document, panel.cursor.head).line;

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
		if panel.activeDialog != .SEARCH {
			if panel.cursor.head != panel.cursor.anchor {
				start := min(panel.cursor.head, panel.cursor.anchor);
				end := max(panel.cursor.head, panel.cursor.anchor);
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

		// draw search results
		if panel.activeDialog == .SEARCH {
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
		success, language := get_language(panel.document.language);
		if success && panel.document.tsTree && language.highlightsQuery {
			queryCursor := ts_query_cursor_new();
			rangeStartByte := linesOnScreen[0].startByteOffset;
			rangeEndByte := linesOnScreen[linesOnScreen.count-1].endByteOffset;

			ts_query_cursor_set_byte_range(queryCursor, xx rangeStartByte, xx rangeEndByte);

			treeNode := ts_tree_root_node(panel.document.tsTree);
			treeNode = ts_node_descendant_for_byte_range(treeNode, xx rangeStartByte, xx rangeEndByte);

			ts_query_cursor_exec(queryCursor, language.highlightsQuery, treeNode);

			highlights: [..]Highlight;
			highlights.allocator = temp;

			// collect all the highlights for the region of code we must render
			while true {
				tsMatch: TSQueryMatch;
				captureId: u32;
				result := ts_query_cursor_next_capture(queryCursor, *tsMatch, *captureId);
				if result == false then break;
				capture := tsMatch.captures[captureId];

				startByte := ts_node_start_byte(capture.node);
				endByte := ts_node_end_byte(capture.node);
				type := to_string(ts_node_grammar_type(capture.node));

				success, highlightType := table_find_new(*language.captureToHighlight, capture.index);
				if evaluate_query_predicates(language, tsMatch, panel.document) {
					if highlights.count > 0 {
						if highlights[highlights.count-1].start == startByte {
							// override the previous range if there's a newer (better) one
							highlights[highlights.count-1] = .{startByte, endByte, highlightType};
							continue;
						}
					}
					array_add(*highlights, .{startByte, endByte, highlightType});
				}
			}

			x :float = textAreaX;
			y :float = textAreaY;
			currentHighlightIndex := 0;
			for line: linesOnScreen {
				run := generate_text_run(line.text, xx box.fontSize, box.font,,temp);
				for run.instances {
					byteOffset := line.startByteOffset + run.byteOffsets[it_index];

					if currentHighlightIndex < highlights.count && byteOffset >= highlights[currentHighlightIndex].end {
						currentHighlightIndex += 1;
					}

					color := style.codeDefault;
					if currentHighlightIndex < highlights.count && byteOffset >= highlights[currentHighlightIndex].start && byteOffset < highlights[currentHighlightIndex].end {
						color = style.codeColors[highlights[currentHighlightIndex].type];
					}

					instance := it;
					instance.dstRect.x = round(x + instance.dstRect.x);
					instance.dstRect.y = round(y + instance.dstRect.y);
					instance.color = color;
					submit_instance(instance);

				}
				y += metrics.lineSpacing;
			}

			// potentially cheaper to reuse the same cursor?
			ts_query_cursor_delete(queryCursor);
		}
		else {
			// draw text with no highlighting
			x :float = textAreaX;
			y :float = textAreaY;
			for line: linesOnScreen {
				run := generate_text_run(line.text, xx box.fontSize, box.font,,temp);
				draw_text_run(run, x, y, style.textPrimary);
				y += metrics.lineSpacing;
			}
		}

		// Draw cursor
		if panel.activeDialog != .SEARCH && cursorLine >= startVisibleLine && cursorLine <= endVisibleLine {
			lineCopy := linesOnScreen[cursorLine - startVisibleLine];
			lineCopy.text.count = panel.cursor.head - get_line_start(panel.document, cursorLine);

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
			cursorChar := get_char_at(panel.document, panel.cursor.head);
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
				color = ifx editorMode == .INSERT then .{1.0, 1.0, 1.0, 1.0} else style.textPrimary,
				shader = .RECTS
			});

			if cursorChar != 0 {
				draw_text_run(cursorRun, cursorX, textAreaY + metrics.lineSpacing * (cursorLine-startVisibleLine), style.backgroundMid);
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
				color = style.backgroundMid,
				shader = .RECTS
			});

			// Draw line numbers
			y :float = box.rect.y + startOffset + box.viewOffset.y;
			for startVisibleLine..endVisibleLine {
				lineNoRun := generate_text_run(tprint("% ", it+1), xx box.fontSize, box.font,,temp);
				draw_text_run(lineNoRun, box.rect.x + (gutterWidth - lineNoRun.width), y, style.textSecondary);
				y += metrics.lineSpacing;
			}
		}
	}
}

evaluate_query_predicates :: (lang: *Language, tsMatch: TSQueryMatch, document: *Document) -> bool {
	predicateList := table_find_pointer(*lang.predicates, tsMatch.pattern_index);
	if predicateList == null then return true;

	get_capture_content :: (tsMatch: TSQueryMatch, document: *Document, captureIndex: u32) -> string {
		capture: TSQueryCapture;
		for 0..tsMatch.capture_count-1 {
			if tsMatch.captures[it].index == captureIndex {
				capture = tsMatch.captures[it];
				break;
			}
		}
		
		startByte := ts_node_start_byte(capture.node);
		endByte := ts_node_end_byte(capture.node);

		// need to find the text corresponding to this node
		captureText := alloc_string(endByte-startByte,,temp);
		iter := make_iterator(document, startByte);
		for iter {
			if it_index >= captureText.count break;
			captureText[it_index] = it;
		}
		return captureText;
	}

	for predicate: predicateList.* {
		if predicate.type == {
			case .MATCH;
				captureText := get_capture_content(tsMatch, document, predicate.captureIndex1);
				matched, captures := match(captureText, predicate.regex,,temp);
				if !matched return false ^ predicate.not;
			case .ANY_OF;
				captureText := get_capture_content(tsMatch, document, predicate.captureIndex1);
				matched := false;
				for predicate.strings {
					if captureText == it then matched = true;
				}
				if !matched return false ^ predicate.not;
			case .EQ_TEXT;
				captureText := get_capture_content(tsMatch, document, predicate.captureIndex1);
				if captureText != predicate.basicStr then return false ^ predicate.not;
			case .EQ_CAPTURE;
				captureText1 := get_capture_content(tsMatch, document, predicate.captureIndex1);
				captureText2 := get_capture_content(tsMatch, document, predicate.captureIndex2);
				if captureText1 != captureText2 then return false ^ predicate.not;
			case;
				return true;
		}
	}

	// all predicates passed
	return true;
}

draw_document_range :: (doc: *Document, start: s64, end: s64, font: *Font, fontSize: int, textAreaX: float, textAreaY: float, linesOnScreen: []Document.LineContent, startVisibleLine: s64) {
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
		lineWidth := generate_text_run(line.text, fontSize, font,,temp).width;

		isFirstLine:= it == rangeStart.line;
		isLastLine:= it == rangeEnd.line;

		selectionX := 0;
		selectionW := lineWidth;
		if isFirstLine {
			selectionX = xx generate_text_run(string.{rangeStart.col,line.text.data}, fontSize, font,,temp).width;
			selectionW = lineWidth - selectionX;
		}
		if isLastLine {
			selectionW = generate_text_run(string.{rangeEnd.col,line.text.data}, fontSize, font,,temp).width - selectionX;
		}

		submit_instance(.{
			dstRect = .{
				cast(float)(textAreaX + selectionX),
				cast(float)(textAreaY - metrics.typicalDescender + metrics.lineSpacing * (it-startVisibleLine-1)),
				cast(float)selectionW,
				cast(float)metrics.lineSpacing
			},
			color = style.textSelection,
			shader = .RECTS
		});
	}
}

do_backup_callback :: () {
	for * openDocuments {
		if document_is_unsaved(it) {
			builder : String_Builder;
			builder.allocator = temp;
			init_string_builder(*builder);

			append(*builder, path_strip_filename(get_path_of_running_executable()));
			append(*builder, "\\backups\\");
			append(*builder, path_filename(it.path));

			document_save(it, builder_to_string(*builder,,temp), true);
		}
	}
}

file_change_callback :: (watcher: *File_Watcher(void), change: *File_Change, userdata: *void) {
	found := array_find(watchedFiles, change.full_path);
	if found {
		success, doc := document_get_by_path(change.full_path);
		if change.events & .MODIFIED {
			modtime, size, success := file_modtime_and_size(doc.path);
			if modtime > doc.diskLastModtime {
				// reload file
				if !document_is_unsaved(doc) {
					document_load_from_disk(doc);
				}
				else {
					// @todo: when we have nicer UI this should give a popup or something more explicit
					doc.undoStack[doc.undoStack.count-1].saved = false;
					push_notification("File on disk changed, but you have unsaved edits");
				}
			}
		}
		if change.events & .REMOVED {
			doc.undoStack[doc.undoStack.count-1].saved = false;
		}
	}
}

write_register :: (name: u8, value: string) {
	if name == DEFAULT_REGISTER {
		os_clipboard_set_text(value);
	}

	// we write to the default yank
	registerData := find_or_add(*registers.table, name,,registers.registerAllocator); 
	array_reset_keeping_memory(registerData);

	array_reserve(registerData, value.count,,registers.registerAllocator);
	memcpy(registerData.data, value.data, value.count * size_of(u8));
	registerData.count = value.count;
}

read_register :: (name: u8) -> string {
	if name == DEFAULT_REGISTER {
		return os_clipboard_get_text();
	}
	else {
		registerData := table_find_pointer(*registers.table, name); 
		if registerData {
			return string.{registerData.count, registerData.data};
		}
	}
	return string.{};
}

load_fonts :: () {
	fontUI,_ = load_font("segoeui.ttf");

	// attempt to load my personal font, then fallback to consolas
	// @todo: ideally my font would be in a config file somewhere not in here
	success: bool;
	fontCode,success = load_font("CaskaydiaMonoNerdFont-Regular.ttf");
	if !success { 
		fontCode,_ = load_font("consola.ttf");
	}

	fontIcons = load_font_from_memory(#run read_entire_file("fonts/Font Awesome 6 Free-Solid-900.otf"));
}

// color stuff
hex_to_color_vec4 :: (src_hex: string) -> Vector4 {
	hex := src_hex;
	if hex.count == 6 then hex = tprint("%FF", hex);
	if hex.count != 8 return Vector4.{};

	r := slice(hex, 0, 2);
	g := slice(hex, 2, 2);
	b := slice(hex, 4, 2);
	a := slice(hex, 6, 2);

	to_float :: (byte_str: string) -> float {
		hex_digit_to_int :: (char: u8) -> int {
			char = to_upper(char);
			if #char "0" <= char && char <= #char "9" return char - #char "0";
			if #char "A" <= char && char <= #char "F" return 10 + char - #char "A";
			return -1;
		}

		d1, d0 := cast(float)hex_digit_to_int(byte_str[0]), cast(float) hex_digit_to_int(byte_str[1]);
		if d1 < 0 || d0 < 0 return -1;

		return (16 * d1 + d0) / 255;
	}

	c := Vector4.{ to_float(r), to_float(g), to_float(b), to_float(a) };

	return c;
}

round :: (f: float) -> float {
	diff := f - floor(f);
	if diff >= 0.5{
		return ceil(f);
	}
	else {
		return floor(f);
	}
}

// fuzzy searching
Highlight :: struct {
	start: u32;
	end: u32;
	type: HighlightType;
}

fuzzy_search :: (stringToSearch: string, filter: string) -> score: s32, highlights: [..]Highlight {
	MAX_CHARS :: 200;

	highlights: [..]Highlight;

	if filter.count == 0 return 1, highlights;

	// search for the full string first
	{
		i := find_index_from_left_nocase_fast(stringToSearch, filter);
		if i >= 0 {
			// match!
			score := (200 + cast(s32, filter.count)) * (MAX_CHARS - i);
			array_add(*highlights, Highlight.{xx i, cast(u32, i + filter.count), .NONE});
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
		array_add(*highlights, Highlight.{xx i, cast(u32, i + substr.count), .NONE});

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

// this function will not copy the string
push_notification :: (message: string) {
	if numActiveNotifications < 10 {
		notifications[numActiveNotifications] = Notification.{message, notificationTime}; 
		numActiveNotifications += 1;
	}
	else {
		// we'll delete the oldest element to make space for this one, so no notifications get missed
		memcpy(notifications.data, notifications.data+1, size_of(Notification));
		notifications[9] = Notification.{message, 20}; 
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

Utf8_Char :: struct {
	bytes: [4] u8;
	count: s32;
}

// Languages

Language :: struct {
	// note we allocate memory for this (arrays/tables)
	// But it's intended this lives the whole duration of the program
	// So we do not free it
	name: string;
	url: string;
	revision: string;
	treesitterLang: *TSLanguage;

	Predicate :: struct {
		Type :: enum {
			MATCH;
			EQ_TEXT;
			EQ_CAPTURE;
			ANY_OF;
		}
		type: Type;
		not: bool;
		captureIndex1: u32;
		captureIndex2: u32;
		regex: Regexp;
		basicStr: string;
		strings: [..]string;
	}

	// information for a query (will probably refactor into query object)
	highlightsQuery: *TSQuery;
	predicates: Table(u32, [..]Predicate);
	captureToHighlight: Table(u32, HighlightType);
}

HighlightType :: enum {
	NONE;
	FUNCTION;
	KEYWORD;
	VARIABLE;
	CONSTANT;
	STRING;
	TYPE;
	NAMESPACE;
	COMMENT;
	COUNT;
}

// should probably be in a config file or something?
staticLanguageData :: Language.[
	.{name="jai", url="https://github.com/constantitus/tree-sitter-jai.git", revision="e15938a94c931662aa3e38cc07dfb98cf7436a90"},
	.{name="cpp", url="https://github.com/tree-sitter/tree-sitter-cpp.git", revision="56455f4245baf4ea4e0881c5169de69d7edd5ae7"},
	.{name="c", url="https://github.com/tree-sitter/tree-sitter-c.git", revision="7fa1be1b694b6e763686793d97da01f36a0e5c12"},
];

LanguageFunc :: #type () -> *TSLanguage #c_call;
languages: Table(string, Language);
languagesMutex: Mutex;

get_language :: (languageName: string) -> bool, *Language {
	if languageName.count == 0 return false, null;

	staticLangData: Language;
	supportsLang := false;
	for staticLanguageData {
		if it.name==languageName {
			staticLangData = it;
			supportsLang = true;
			break;
		}
	}

	if supportsLang == false {
		return false, null;
	}

	lock(*languagesMutex);
	lang, added := find_or_add(*languages, languageName);
	if !added {
		return true, lang;
	}
	unlock(*languagesMutex);

	// @todo: In packaged builds this should be the base directory of the exe
	exePath := path_strip_filename(get_path_of_running_executable());
	libPath := tprint("%../../grammars/%.dll", exePath, languageName);
	if !file_exists(libPath) {
		return false, null;
	}

	// copy data from static lang stuff
	lang.* = staticLangData;

	// @todo: windows specific code here, need to move to platform_windows
	grammarLib := LoadLibraryA(temp_c_string(libPath));

	// Load the treesitter language structure
	functionName := tprint("tree_sitter_%", languageName);
	loadFunc := cast(LanguageFunc, GetProcAddress(grammarLib, temp_c_string(functionName)));
	lang.treesitterLang = loadFunc();
	
	// Load queries
	highlightsQueryPath := tprint("%../../queries/%/highlights.scm", exePath, languageName);
	file, success := read_entire_file(highlightsQueryPath,,temp);
	if success {
		errorLocation: u32;
		errorType: TSQueryError;
		lang.highlightsQuery = ts_query_new(lang.treesitterLang, file.data, xx file.count, *errorLocation, *errorType);
		if lang.highlightsQuery == null {
			errorTypeStr := "None";
			if errorType == {
				case .None; errorTypeStr = "None";
				case .Syntax; errorTypeStr = "Syntax";
				case .NodeType; errorTypeStr = "NodeType";
				case .Field; errorTypeStr = "Field";
				case .Capture; errorTypeStr = "Capture";
				case .Structure; errorTypeStr = "Structure";
				case .Language; errorTypeStr = "Language";
			}
			// @todo: can probably make this nicer, figure out the line/column etc
			log("Query Error in file %: %Error at %", highlightsQueryPath, errorTypeStr, errorLocation);
		}
		else {
			// Prepare information to speed up query use, such as predicate information
			
			patternCount := ts_query_pattern_count(lang.highlightsQuery);
			captureCount := ts_query_capture_count(lang.highlightsQuery);
			stringCount := ts_query_string_count(lang.highlightsQuery);

			// loop over all the patterns looking for predicates
			// We will save them all in a table to use later
			for patternIndex: 0..patternCount-1 {
				steps: *TSQueryPredicateStep;
				stepCount: u32;
				steps = ts_query_predicates_for_pattern(lang.highlightsQuery, patternIndex, *stepCount);

				i: u32 = 0;
				while i<stepCount {
					if steps[i].type == .String {
						predicateName:string;
						len: u32;
						predicateName.data = ts_query_string_value_for_id(lang.highlightsQuery, steps[i].value_id, *len);
						predicateName.count = len;

						if predicateName == "match?" || predicateName == "not-match?" {
							matchPredicate: Language.Predicate;
							matchPredicate.type = .MATCH;

							if contains(predicateName, "not") {
								matchPredicate.not = true;
							}

							// expect capture, then string
							i += 1;
							if steps[i].type != .Capture {
								log("Expected capture as first argument of match predicate");
								continue patternIndex;
							}

							matchPredicate.captureIndex1 = steps[i].value_id;

							// now grab the regex string
							i += 1;
							if steps[i].type != .String {
								log("Expected string as second argument of match predicate");
								continue patternIndex;
							}

							regex:string;
							len: u32;
							regex.data = ts_query_string_value_for_id(lang.highlightsQuery, steps[i].value_id, *len);
							regex.count = len;

							success, captures := match("HELLO", regex);
							matchPredicate.regex = compile(regex);

							predicateList, _ := find_or_add(*lang.predicates, patternIndex);
							array_add(predicateList, matchPredicate);
							i += 1;
						}
						else if predicateName == "any-of?" || predicateName == "not-any-of?" {
							anyOfPredicate: Language.Predicate;
							anyOfPredicate.type = .ANY_OF;

							if contains(predicateName, "not") {
								anyOfPredicate.not = true;
							}

							i += 1;
							if steps[i].type != .Capture {
								log("Expected capture as first argument of any-of predicate");
								continue patternIndex;
							}

							anyOfPredicate.captureIndex1 = steps[i].value_id;

							i += 1;
							while steps[i].type != .Done {
								if steps[i].type != .String {
									log("Expected string as argument of any-of predicate");
									continue patternIndex;
								}

								candidate:string;
								len: u32;
								candidate.data = ts_query_string_value_for_id(lang.highlightsQuery, steps[i].value_id, *len);
								candidate.count = len;

								i += 1;
								array_add(*anyOfPredicate.strings, candidate);
							}

							predicateList, _ := find_or_add(*lang.predicates, patternIndex);
							array_add(predicateList, anyOfPredicate);
						}
						else if predicateName == "eq?" || predicateName == "not-eq?" {
							eqPredicate: Language.Predicate;
							eqPredicate.type = .EQ_TEXT;

							if contains(predicateName, "not") {
								eqPredicate.not = true;
							}

							i += 1;
							if steps[i].type != .Capture {
								log("Expected capture as first argument of eq predicate");
								continue patternIndex;
							}

							eqPredicate.captureIndex1 = steps[i].value_id;

							i += 1;
							if steps[i].type == .String {
								eqPredicate.type = .EQ_TEXT;

								otherStr:string;
								len: u32;
								otherStr.data = ts_query_string_value_for_id(lang.highlightsQuery, steps[i].value_id, *len);
								otherStr.count = len;
								eqPredicate.basicStr = otherStr;
							}
							else if steps[i].type == .Capture {
								eqPredicate.captureIndex2 = steps[i].value_id;
								eqPredicate.type = .EQ_CAPTURE;
							}
							else {
								log("Unexpected second predicate argument in eq predicate, must be string or capture");
								continue patternIndex;
							}

							predicateList, _ := find_or_add(*lang.predicates, patternIndex);
							array_add(predicateList, eqPredicate);
							i += 1;
						}
					}
					else if steps[i].type == .Done {
						break;
					}
					else {
						log("Unexpected element in predicate");
					}
				}
			}

			// Loop over all the captures looking at their names, and matching them
			// to highlight types
			
			for captureIndex: 0..captureCount-1 {
				captureName: string;
				len:u32;
				captureName.data = ts_query_capture_name_for_id(lang.highlightsQuery, captureIndex, *len);
				captureName.count = xx len;

				highlightType := HighlightType.NONE;
				if contains(captureName, "function") {
					highlightType = .FUNCTION;
				}
				if contains(captureName, "keyword") {
					highlightType = .KEYWORD;
				}
				if contains(captureName, "variable") {
					highlightType = .VARIABLE;
				}
				if contains(captureName, "constant") {
					highlightType = .CONSTANT;
				}
				if contains(captureName, "string") {
					highlightType = .STRING;
				}
				if contains(captureName, "type") {
					highlightType = .TYPE;
				}
				if contains(captureName, "namespace") {
					highlightType = .NAMESPACE;
				}
				if contains(captureName, "comment") {
					highlightType = .COMMENT;
				}
				table_add(*lang.captureToHighlight, captureIndex, highlightType);
			}
		}
	}
	
	return true, lang;
}

fetch_grammars :: () {
	// Have a list of grammar repositories
	// Clone them at a certain revision

	verboseOutput := false;

	// @todo: check that git actually exists on this machine
	// @todo: error if not on windows

	for staticLanguageData {
		directory := tprint("grammars/sources/%", it.name);

		// @todo: check if directory exists and if so check what revision before doing a clone
		if file_exists(directory) {
			delete_directory(directory);
		}
		
		log("Fetching %..", it.name);
		make_directory_if_it_does_not_exist(directory);
		result, output, error := run_command("git", "clone", "--no-checkout", it.url, directory, capture_and_return_output=true);
		if verboseOutput {
			log("%", output);
		}
		if result.exit_code != 0 {
			log_error("Error!");
			log_error("Output:\n%", output);
			log_error("Errors:\n%", error);
		}

		result, output, error = run_command("git", "-C", directory, "checkout", it.revision, capture_and_return_output=true);
		if verboseOutput {
			log("%", output);
		}
		if result.exit_code != 0 {
			log_error("Error!");
			log_error("Output:\n%", output);
			log_error("Errors:\n%", error);
		}
	}
}

build_grammars :: () {
	// set up compile environment
	vcPath, linkerPath := find_visual_studio_in_a_ridiculous_garbage_way();
	compiler := join(linkerPath, "\\", "cl.exe");
	windowsKit := find_windows_kit_root();
	vcIncludePath := join(vcPath, "\\..\\..\\include");
	windowsKitInclude := replace(windowsKit, "Lib", "Include");

	// @todo: error if you can't find visual studio

	verboseOutput := false;
	for staticLanguageData {
		log("Compiling %..", it.name);
		directory := tprint("grammars/sources/%", it.name);

		args: [..] string;
		array_add(*args, compiler);
		defer array_free(args);

		array_add(*args, "src\\parser.c");
		if file_exists(tprint("%\\src\\scanner.c", directory)) {
			array_add(*args, "src\\scanner.c");
		}
		array_add(*args,
			"/O2",                      // Maximize speed.
			"/Oi",                      // Enable intrinsics.
			// "/Zi",
		);

		array_add(*args,
			tprint("/I%", vcIncludePath),
			tprint("/I%\\um", windowsKitInclude),
			tprint("/I%\\ucrt", windowsKitInclude),
			tprint("/I%\\shared", windowsKitInclude),
		);
		
		array_add(*args, "/link");
		array_add(*args, "/DLL");
		array_add(*args, "/MACHINE:AMD64");
		array_add(*args, tprint("/OUT:%.dll", it.name));
		array_add(*args,
			tprint("/libpath:%", vcPath),
			tprint("/libpath:%\\um\\x64", windowsKit),
			tprint("/libpath:%\\ucrt\\x64", windowsKit),
		);
		
		result, output, error := run_command(..args, capture_and_return_output=true, working_directory=directory);
		if verboseOutput {
			log("%", output);
		}
		if result.exit_code != 0 {
			log_error("Error!");
			log_error("Output:\n%", output);
			log_error("Errors:\n%", error);
			return;
		}
		copy_file(tprint("%/%.dll", directory, it.name), tprint("grammars/%.dll", it.name));
	}
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



Input :: #import "Input";
#import "Window_Creation";
#import "Process";
#import "Basic"()(MEMORY_DEBUGGER = false);
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
#import "Bit_Operations";
#import "Text_File_Handler";
#import "Thread";

#load "rect.jai";
#load "command_picker.jai";
#load "filesystem_navigator.jai";
#load "file_finder.jai";
#load "keymap.jai";
#load "commands.jai";
#load "panel.jai";
#load "ui.jai";
#load "renderer.jai";
#load "font.jai";
#load "async.jai";
#load "document.jai";
#load "project.jai";

#if OS == .WINDOWS {
	#load "platform_windows.jai";
	#import "Windows_Resources";
}
