
Cursor :: struct {
	head: s64;
	anchor: s64;

	// when users move up and down lines, this stores the 
	// column that we should try stick to as we move up and down
	// gets reset when the user actually moves left or right
	virtualColumn: s64; 
}

Panel :: struct {
	document: *Document;
	layoutRect: Rect;
	optionsMenuOpen: bool;

	// cursors
	cursor: Cursor;

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

panel_set_active_document :: (panel: *Panel, doc: *Document) {
	panel.document = doc;
	panel.cursor = .{};
	panel.cursor.head = 0;
	panel.cursor.anchor = 0;
	panel.cursor.virtualColumn = 0;
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
}

panel_calculate_visible_lines :: (panel: *Panel, useAnimTarget:bool=false) -> s64, s64 {
	success, box := find_box(ui_key("code"));
	if success {
		if box.rect.h == 0.0 return 0,0;
		documentLines := get_number_of_lines(panel.document);
		metrics := get_font_metrics(box.font, xx box.fontSize);

		viewOffset := ifx useAnimTarget then box.viewOffsetTarget.y else box.viewOffset.y;
		startVisibleLines := clamp(cast(s64) (-viewOffset / metrics.lineSpacing), 0, documentLines - 1);
		return startVisibleLines, cast(s64, box.rect.h / metrics.lineSpacing)-1;
	}
	return 0,0;
}

panel_get_page_size :: (panel: *Panel) -> s64 {
	success, box := find_box(ui_key("code"));
	if success {
		metrics := get_font_metrics(box.font, xx box.fontSize);
		return cast(s64) (box.rect.h / metrics.lineSpacing);
	}
	return 0;
}
