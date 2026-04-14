
Cursor :: struct {
	head: s64;
	anchor: s64;

	// when users move up and down lines, this stores the 
	// column that we should try stick to as we move up and down
	// gets reset when the user actually moves left or right
	virtualColumn: s64; 
}

Panel :: struct {
	docHandle: DocumentHandle;
	// this will be updated every frame using the handle
	// Never copy and store this pointer, it can change underneath you
	document: *Document;
	previousDocument: DocumentHandle;

	layoutRect: Rect;
	optionsMenuOpen: bool;

	// cursors
	cursor: Cursor;

	// we key by the document path because documentHandle is not actually hashable
	// TODO: make documentHandle be hashable and improve this
	DocumentPanelLocation :: struct {
		scrollOffset: Vector2;
		cursor: Cursor;
	}
	documentLocations: Table(string, DocumentPanelLocation);

	// Dialogs
	activeDialog: DialogType;
	commandPicker: CommandPicker;
	filesystemNav: FilesystemNavigator;
	fileFinder: FileFinder;
	projectSearcher: ProjectSearch;

	// search state (this is too a dialog, may want to group it up)
	searchInput: InputField;
	currentRegex: Regexp;
	currentSearchTerm: string;
	hasMatches := false;
	previousScrollLine := 0;
	results: [..]Document.Range;
}

panel_set_active_document :: (panel: *Panel, doc: DocumentHandle) {
	newDoc := document_get(doc);

	// Save the scroll offset of the old document so we can come back to it
	success, codeBox := find_box(ui_key("code"));
	if success {
		location := table_find_pointer(*panel.documentLocations, panel.document.path);
		if location {
			location.scrollOffset = .{codeBox.viewOffset.x, codeBox.viewOffset.y};
			location.cursor = panel.cursor;
		}
		else {
			table_add(*panel.documentLocations, panel.document.path, .{.{codeBox.viewOffset.x, codeBox.viewOffset.y}, panel.cursor});
		}
	}

	panel.previousDocument = panel.docHandle;
	panel.docHandle = newDoc.handle;
	panel.document = newDoc;
	panel.cursor = .{};
	panel.cursor.head = 0;
	panel.cursor.anchor = 0;
	panel.cursor.virtualColumn = 0;

	// Restore a saved scroll offset if one exists
	location := table_find_pointer(*panel.documentLocations, panel.document.path);
	if success {
		if location {
			codeBox.viewOffset = location.scrollOffset;
			codeBox.viewOffsetTarget = location.scrollOffset;
			panel.cursor = location.cursor;
		}
		else {
			codeBox.viewOffset = .{};
			codeBox.viewOffsetTarget = .{};
		}
	}
	else {
		if location {
			// @todo: initial offsets should support x
			codeScrollInitialOffset = location.scrollOffset.y;
			panel.cursor = location.cursor;
		}
		else {
			codeScrollInitialOffset = 0;
		}
	}
}

panel_reset_dialogs :: (panel: *Panel) {
	if panel.activeDialog == {
		case .FILE_FINDER; file_finder_reset(panel);
		case .PROJECT_SEARCH; project_search_reset(panel);
		case .FILESYSTEM_NAVIGATOR; filesystem_nav_reset(panel);
		case .COMMAND_PICKER; command_picker_reset(panel);
		case .SEARCH; end_document_search(panel);
	}
	panel.activeDialog = .NONE;
}

panel_get_current_scrolled_line :: (panel: *Panel) -> s64 {
	success, box := find_box(ui_key("code"));
	if success {
		metrics := get_font_metrics(box.font, xx box.fontSize);
		return cast(s64, floor(-box.viewOffset.y / metrics.lineSpacing));
	}
	return 0;
}

panel_scroll_to_cursor :: (panel: *Panel) {
	currentLine := get_coordinate_from_offset(panel.document, panel.cursor.head).line;

	startVisibleLine, range := panel_calculate_visible_lines(panel);
	if currentLine < startVisibleLine {
		panel_scroll_to_line(panel, currentLine);
	}
	else if currentLine-range >= startVisibleLine {
		panel_scroll_to_line(panel, currentLine-range);
	}
}

// targetLine will be the top edge of the panel, such that target line = 0 will leave you scrolled
// up as high as you can go. Will allow you to scroll off the end as far as a couple lines are still visible
panel_scroll_to_line :: (panel: *Panel, targetLine: s64) {
	// @todo: when we have more than one panel, you will need to 
	// specify which code box you want, in which panel
	success, box := find_box(ui_key("code"));
	if success {
		metrics := get_font_metrics(box.font, xx box.fontSize);
		box.viewOffsetTarget.y = cast(float, -targetLine * metrics.lineSpacing);
		box.viewOffsetTarget.y = clamp(box.viewOffsetTarget.y, box.viewBounds.y, 0);
	}
	else {
		// when the box doesn't exist, we may want to set it's initial scroll setup for when it gets created
		metrics := get_font_metrics(fontCode, xx style.fontSize);
		codeScrollInitialOffset = cast(float, -targetLine * metrics.lineSpacing);
	}
}

panel_calculate_visible_lines :: (panel: *Panel, useAnimTarget:bool=false) -> s64, s64 {
	success, box := find_box(ui_key("code"));
	if success {
		metrics := get_font_metrics(box.font, xx box.fontSize);
		if box.rect.h == 0.0 {
			return 0, cast(s64, panel.layoutRect.h / metrics.lineSpacing)-1;
		}

		documentLines := get_number_of_lines(panel.document);
		viewOffset := ifx useAnimTarget then box.viewOffsetTarget.y else box.viewOffset.y;
		startVisibleLines := clamp(cast(s64) (-viewOffset / metrics.lineSpacing), 0, documentLines - 1);
		return startVisibleLines, cast(s64, box.rect.h / metrics.lineSpacing)-1;
	}
	
	// fallback for when there is no codebox to use
	metrics := get_font_metrics(fontCode, xx style.fontSize);
	return 0, cast(s64, panel.layoutRect.h / metrics.lineSpacing)-1;
}

panel_get_page_size :: (panel: *Panel) -> s64 {
	success, box := find_box(ui_key("code"));
	if success {
		metrics := get_font_metrics(box.font, xx box.fontSize);
		return cast(s64) (box.rect.h / metrics.lineSpacing);
	}
	return 0;
}
