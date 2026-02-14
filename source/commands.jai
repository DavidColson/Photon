
// Movement commands
// ------------------------------------

move_one_char_left :: (using panel: *Panel, args: []string) {
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);

	lineStart, lineEnd := get_line_range(panel.document, cursorCoordinate.line);

	cursor.head -= 1;
	cursor.head = clamp(cursor.head, lineStart, lineEnd);
	
	// recalculate virtual column
	newLineContent := get_line_content(panel.document, cursorCoordinate.line);
	cursor.virtualColumn = 0;
	for newLineContent.text {
		if it_index >= cursorCoordinate.col-1 then break;
		if it == #char "\t" {
			cursor.virtualColumn += chars_to_tabstop(cursor.virtualColumn);
		}
		else {
			cursor.virtualColumn += 1;
		}
	}

	cursor.anchor = cursor.head;
	panel_scroll_to_cursor(panel);
}

move_one_char_right :: (using panel: *Panel, args: []string) {
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);

	lineStart, lineEnd := get_line_range(panel.document, cursorCoordinate.line);

	panel.cursor.head += 1;
	panel.cursor.head = clamp(panel.cursor.head, lineStart, lineEnd);

	// recalculate virtual column
	newLineContent := get_line_content(panel.document, cursorCoordinate.line);
	cursor.virtualColumn = 0;
	for newLineContent.text {
		if it_index >= cursorCoordinate.col+1 then break;
		if it == #char "\t" {
			cursor.virtualColumn += chars_to_tabstop(cursor.virtualColumn);
		}
		else {
			cursor.virtualColumn += 1;
		}
	}

	cursor.anchor = cursor.head;
	panel_scroll_to_cursor(panel);
}

chars_to_tabstop :: (column: s64) -> s64 {
	return tabSize - column % tabSize;
}

move_one_line_down :: (using panel: *Panel, args: []string) {
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);
	numLines := get_number_of_lines(document);
	newLine := min(cursorCoordinate.line + 1, numLines - 1);
	newLineContent := get_line_content(panel.document, newLine);

	// recalculate the cursor column to match the virtual column
	columnCounter := 0;
	targetByteOffset := newLineContent.text.count;
	for newLineContent.text {
		if it == #char "\t" {
			columnCounter += chars_to_tabstop(columnCounter);
		}
		else {
			columnCounter += 1;
		}

		if columnCounter > cursor.virtualColumn {
			targetByteOffset = it_index;
			break;
		}
	}

	cursor.head = newLineContent.startByteOffset + targetByteOffset;

	cursor.anchor = cursor.head;
	panel_scroll_to_cursor(panel);
}

move_one_line_up :: (using panel: *Panel, args: []string) {
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);
	newLine := max(cursorCoordinate.line - 1, 0);
	newLineContent := get_line_content(panel.document, newLine);
	
	// recalculate the cursor column to match the virtual column
	columnCounter := 0;
	targetByteOffset := newLineContent.text.count;
	for newLineContent.text {
		if it == #char "\t" {
			columnCounter += chars_to_tabstop(columnCounter);
		}
		else {
			columnCounter += 1;
		}

		if columnCounter > cursor.virtualColumn {
			targetByteOffset = it_index;
			break;
		}
	}

	cursor.head = newLineContent.startByteOffset + targetByteOffset;

	cursor.anchor = cursor.head;
	panel_scroll_to_cursor(panel);
}

move_cursor_to_specific_line :: (using panel: *Panel, line: s64) {
	newLineContent := get_line_content(panel.document, line);
	
	// recalculate the cursor column to match the virtual column
	columnCounter := 0;
	targetByteOffset := newLineContent.text.count;
	for newLineContent.text {
		if it == #char "\t" {
			columnCounter += chars_to_tabstop(columnCounter);
		}
		else {
			columnCounter += 1;
		}

		if columnCounter > cursor.virtualColumn {
			targetByteOffset = it_index;
			break;
		}
	}

	cursor.head = newLineContent.startByteOffset + targetByteOffset;
}

goto_document_start :: (using panel: *Panel, args: []string) {
	cursor.head = 0;
	cursor.anchor = cursor.head;
	// scroll the window if the cursor will now become out of view
	panel_scroll_to_line(panel, 0);
}

goto_document_end :: (using panel: *Panel, args: []string) {
	cursor.head = get_size(document)-1;

	if get_char_at(document, cursor.head-1) == #char "\n" {
		cursor.head -= 1;
	}
	if get_char_at(document, cursor.head-1) == #char "\r" {
		cursor.head -= 1;
	}

	cursor.anchor = cursor.head;

	// scroll the window if the cursor will now become out of view
	pageSize := panel_get_page_size(panel);
	cursorLine := get_coordinate_from_offset(document, cursor.head).line;
	panel_scroll_to_line(panel, cursorLine - pageSize + 1);
}

goto_line_end :: (using panel: *Panel, args: []string) { 
	coordinate := get_coordinate_from_offset(document, cursor.head);
	cursor.head = get_line_start(document, coordinate.line + 1);

	if get_char_at(document, cursor.head-1) == #char "\n" {
		cursor.head -= 1;
	}
	if get_char_at(document, cursor.head-1) == #char "\r" {
		cursor.head -= 1;
	}
	cursor.anchor = cursor.head;

	// recalculate virtual column
	newCoordinate := get_coordinate_from_offset(document, cursor.head);
	newLineContent := get_line_content(panel.document, newCoordinate.line);
	cursor.virtualColumn = 0;
	for newLineContent.text {
		if it_index >= newCoordinate.col+1 then break;
		if it == #char "\t" {
			cursor.virtualColumn += chars_to_tabstop(cursor.virtualColumn);
		}
		else {
			cursor.virtualColumn += 1;
		}
	}

	panel_scroll_to_cursor(panel);
}

goto_line_start :: (using panel: *Panel, args: []string) { 
	coordinate := get_coordinate_from_offset(document, cursor.head);
	cursor.head = get_line_start(document, coordinate.line);
	cursor.anchor = cursor.head;
	cursor.virtualColumn = 0;
	panel_scroll_to_cursor(panel);
}

CharCategory :: enum {
	LINE_ENDING;
	WHITESPACE;
	WORD;
	PUNCTUATION;
	UNKNOWN;
}

categorize_char :: (ch: u8) -> CharCategory {
	// @todo note that there are more punctuation marks in full unicode
	// something to support later. Generally unicode may break the assumptions in here
	punctuation :: "\"!#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
	isPunctuation := false;
	for punctuation {
		if ch == it then isPunctuation = true;
	}

	if ch == #char "\n" {
		return .LINE_ENDING;
	}
	else if ch == #char " " || ch == #char "\t" || ch == #char "\r" {
		return .WHITESPACE;
	}
	else if is_alnum(ch) {
		return .WORD;
	}
	else if isPunctuation {
		return .PUNCTUATION;
	}
	else {
		return .UNKNOWN;
	}
}

is_lower :: inline (char: u8) -> bool {
    return char >= #char "a" && char <= #char "z";
}

is_upper :: inline (char: u8) -> bool {
    return char >= #char "A" && char <= #char "Z";
}

move_word_forward :: (using panel: *Panel, checkPosition: (u8, u8, CharCategory, CharCategory) -> bool) {
	cursor.anchor = cursor.head;
	iter := make_iterator(document, cursor.head);
	for iter {
		cursor.head = iter.offset+1;
		next := (iter.firstChar+1).*;
		next = ifx next == #char "\r" then (iter.firstChar+2).* else next;
		prevCharCategory := categorize_char(it);
		nextCharCategory := categorize_char(next);
		if checkPosition(it, next, prevCharCategory, nextCharCategory) {
			if it_index == 0 {
				cursor.anchor = cursor.head;
			}
			else {
				if nextCharCategory != .LINE_ENDING {
					cursor.head -= 1;
				}
				if prevCharCategory == .LINE_ENDING then cursor.anchor = cursor.head;
				break;
			}
		}
	}
	cursor.head = shift_offset_line_endings(document, cursor.head, .REVERSE);
	cursor.anchor = shift_offset_line_endings(document, cursor.anchor, .REVERSE);
	panel_scroll_to_cursor(panel);
}

move_word_reverse :: (using panel: *Panel, checkPosition: (u8, u8, CharCategory, CharCategory) -> bool) {
	cursor.anchor = cursor.head;
	iter := make_reverse_iterator(document, cursor.head-1);
	prev := get_char_at(document, cursor.head);
	for iter {
		cursor.head = iter.offset-1;
		nextCharCategory := categorize_char(it);
		prevCharCategory := categorize_char(prev);
		if checkPosition(prev, it, prevCharCategory, nextCharCategory) {
			if it_index == 0 {
				cursor.anchor = cursor.head+1;
			}
			else {
				cursor.head += 2;
				break;
			}
		}
		prev = it;
	}
	cursor.head = shift_offset_line_endings(document, cursor.head, .FORWARD);
	cursor.anchor = shift_offset_line_endings(document, cursor.anchor, .FORWARD);
	panel_scroll_to_cursor(panel);
}

move_word_start :: (using panel: *Panel, args: []string) { 
	move_word_forward(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isWordBoundary := nextCharCategory != prevCharCategory;
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		nextIsWhitespace := nextCharCategory == .WHITESPACE;
		return isWordBoundary && (nextIsLineEnding || !nextIsWhitespace);
	});
	panel_scroll_to_cursor(panel);
}

move_long_word_start :: (using panel: *Panel, args: []string) { 
	move_word_forward(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isLongWordBoundary := prevCharCategory != nextCharCategory;
		if (nextCharCategory == .WORD && prevCharCategory == .PUNCTUATION) 
		|| (nextCharCategory == .PUNCTUATION && prevCharCategory == .WORD) {
			isLongWordBoundary = false;
		}

		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		nextIsWhitespace := nextCharCategory == .WHITESPACE;
		return isLongWordBoundary && (nextIsLineEnding || !nextIsWhitespace);
	});
	panel_scroll_to_cursor(panel);
}

move_sub_word_start :: (using panel: *Panel, args: []string) { 
	move_word_forward(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isSubWordBoundary := prev != next;
		if nextCharCategory == .WORD && prevCharCategory == .WORD {
			if (prev == #char "_") != (next == #char "_") {
				isSubWordBoundary = true;
			}
			else {
				isSubWordBoundary = is_lower(prev) && is_upper(next);
			}
		}

		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		nextIsWhitespace := nextCharCategory == .WHITESPACE;
		return isSubWordBoundary && (nextIsLineEnding || !(nextIsWhitespace || next == #char "_"));
	});
	panel_scroll_to_cursor(panel);
}

move_prev_word_start :: (using panel: *Panel, args: []string) { 
	move_word_reverse(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isWordBoundary := nextCharCategory != prevCharCategory;
		if nextCharCategory == .LINE_ENDING && prevCharCategory == .LINE_ENDING {
			isWordBoundary = true;
		}
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isWordBoundary && (!prevIsWhitespace || nextIsLineEnding);
	});
	panel_scroll_to_cursor(panel);
}

move_word_end :: (using panel: *Panel, args: []string) { 
	move_word_forward(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isWordBoundary := nextCharCategory != prevCharCategory;
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isWordBoundary && (!prevIsWhitespace || nextIsLineEnding);
	});
	panel_scroll_to_cursor(panel);
}

move_long_word_end :: (using panel: *Panel, args: []string) { 
	move_word_forward(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isLongWordBoundary := prevCharCategory != nextCharCategory;
		if (nextCharCategory == .WORD && prevCharCategory == .PUNCTUATION) 
		|| (nextCharCategory == .PUNCTUATION && prevCharCategory == .WORD) {
			isLongWordBoundary = false;
		}
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isLongWordBoundary && (!prevIsWhitespace || nextIsLineEnding);
	});
	panel_scroll_to_cursor(panel);
}

move_sub_word_end :: (using panel: *Panel, args: []string) { 
	move_word_forward(panel, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isSubWordBoundary := ifx prev != next then true else false;
		if nextCharCategory == .WORD && prevCharCategory == .WORD {
			if (prev == #char "_") != (next == #char "_") {
				isSubWordBoundary = true;
			}
			else {
				isSubWordBoundary = is_lower(prev) && is_upper(next);
			}
		}

		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isSubWordBoundary && (!(prevIsWhitespace || prev == #char "_") || nextIsLineEnding);
	});
	panel_scroll_to_cursor(panel);
}

jump_to_char :: (using panel: *Panel, args: []string) { 
	iter := make_iterator(document, cursor.head+1);
	for iter {
		cursor.head = iter.offset;
		// @todo: assumes the args are single char, this may not always be true
		if args[0][0] == it {
			break;
		}
	}
	panel_scroll_to_cursor(panel);
}

jump_to_last_char :: (using panel: *Panel, args: []string) { 
	iter := make_reverse_iterator(document, cursor.head);
	for iter {
		cursor.head = iter.offset;
		// @todo: assumes the args are single char, this may not always be true
		if args[0][0] == it {
			break;
		}
	}
	panel_scroll_to_cursor(panel);
}

jump_to_before_char :: (using panel: *Panel, args: []string) { 
	iter := make_iterator(document, cursor.head+1);
	for iter {
		cursor.head = iter.offset;
		next := (iter.firstChar+1).*;
		// @todo: assumes the args are single char, this may not always be true
		if args[0][0] == next {
			break;
		}
	}
	panel_scroll_to_cursor(panel);
}

jump_to_before_last_char :: (using panel: *Panel, args: []string) { 
	iter := make_reverse_iterator(document, cursor.head);
	for iter {
		cursor.head = iter.offset;
		// @todo: assumes the args are single char, this may not always be true
		if args[0][0] == it {
			cursor.head += 1;
			break;
		}
	}
	panel_scroll_to_cursor(panel);
}

extend_selection_to_lines :: (using panel: *Panel, args: []string) { 
	// flip the cursors if required
	if cursor.head != cursor.anchor && min(cursor.head, cursor.anchor) == cursor.head {
		temp := cursor.head;
		cursor.head = cursor.anchor;
		cursor.anchor = temp;
		cursor.virtualColumn = S64_MAX;
	}

	// check if we already have whole lines selected, in which case we must select the next one
	anchorCoord := get_coordinate_from_offset(document, cursor.anchor);
	if cursor.virtualColumn == S64_MAX && anchorCoord.col == 0 {
		coord := get_coordinate_from_offset(document, cursor.head);
		if coord.line == get_number_of_lines(document) return;
		start,end := get_line_range(document, coord.line+1);
		cursor.head = end;
	}
	else {
		coord := get_coordinate_from_offset(document, min(cursor.anchor, cursor.head));
		cursor.anchor, cursor.head = get_line_range(document, coord.line);
	}

	cursor.virtualColumn = S64_MAX;
	panel_scroll_to_cursor(panel);
}

extend_selection_to_lines_above :: (using panel: *Panel, args: []string) { 
	// flip the cursors if required
	if cursor.head != cursor.anchor && min(cursor.head, cursor.anchor) == cursor.anchor {
		temp := cursor.head;
		cursor.head = cursor.anchor;
		cursor.anchor = temp;
		cursor.virtualColumn = 0;
	}

	headCoord := get_coordinate_from_offset(document, cursor.head);
	if cursor.virtualColumn == 0 && headCoord.col == 0 {
		coord := get_coordinate_from_offset(document, cursor.head);
		if coord.line == 0 return;
		start,end := get_line_range(document, coord.line-1);
		cursor.head = start;
	}
	else {
		coord := get_coordinate_from_offset(document, min(cursor.anchor, cursor.head));
		cursor.head, cursor.anchor = get_line_range(document, coord.line);
	}

	cursor.virtualColumn = 0;
	panel_scroll_to_cursor(panel);
}

select_whole_document :: (using panel: *Panel, args: []string) {
	cursor.anchor = 0;
	cursor.head = get_size(document)-1;
	panel_scroll_to_cursor(panel);
}

collapse_selection :: (using panel: *Panel, args: []string) {
	cursor.anchor = cursor.head;
	panel_scroll_to_cursor(panel);
}

// Normal Mode Changes
// ------------------------------

enter_normal_mode :: (panel: *Panel, args: []string) {
	panel_reset_dialogs(panel);

	// confirm undo action if we left insert mode with edits
	if editorMode == .INSERT && panel.document.nextUndoOffset > 0 {
		commit_history(panel.document);
	}
	
	editorMode = .NORMAL;
}

enter_insert_mode_start :: (using panel: *Panel, args: []string) {
	if cursor.head > cursor.anchor {
		temp := cursor.head;
		cursor.head = cursor.anchor;
		cursor.anchor = temp;
	}
	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	panel_scroll_to_cursor(panel);
}

enter_insert_mode_end :: (using panel: *Panel, args: []string) {
	if cursor.head < cursor.anchor {
		temp := cursor.head;
		cursor.head = cursor.anchor;
		cursor.anchor = temp;
	}
	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	panel_scroll_to_cursor(panel);
}

enter_insert_mode_line_start :: (using panel: *Panel, args: []string) {
	goto_line_start(panel, args);

	// put the cursor on the first non whitespace character
	cursorChar := get_char_at(document, cursor.head);
	if is_space(cursorChar) {
		iterator := make_iterator(document, cursor.head);
		for iterator {
			cursor.head = iterator.offset;
			if !is_space(it) break;
		}
	}
	cursor.anchor = cursor.head;

	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	panel_scroll_to_cursor(panel);
}

enter_insert_mode_line_end :: (using panel: *Panel, args: []string) {
	goto_line_end(panel, args);

	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	panel_scroll_to_cursor(panel);
}

select_register :: (using panel: *Panel, args: []string) { 
	registers.selectedRegister = args[0][0];
}

delete_selection :: (using panel: *Panel, args: []string) {
	if cursor.head < cursor.anchor {
		delete(document, cursor.head, cursor.anchor-cursor.head + 1);
		cursor.anchor = cursor.head;
	}
	else {
		delete(document, cursor.anchor, cursor.head-cursor.anchor + 1);
		cursor.head = cursor.anchor;
	}

	// @todo: put the deletion into a register
	panel_scroll_to_cursor(panel);
}

change_selection :: (using panel: *Panel, args: []string) {
	delete_selection(panel, args);
	enter_insert_mode_start(panel, args);
}

yank_selection :: (using panel: *Panel, args: []string) {
	// read the selection from the document
	// @todo: it may be useful to pull out this snippet as a generic "read range from document"
	rangeStart := min(cursor.head, cursor.anchor);
	rangeEnd := max(cursor.head, cursor.anchor);

	text: [..]u8;
	iterator := make_iterator(document, rangeStart);
	for :raw_bytes iterator {
		array_add(*text, it,,temp);
		if iterator.offset >= rangeEnd then break;
	}
	textStr := string.{text.count, text.data};
	push_notification(sprint("Yanked into register %", string.{1,*registers.selectedRegister}));

	write_register(registers.selectedRegister, textStr);
	panel_scroll_to_cursor(panel);
}

paste_after_selection :: (using panel: *Panel, args: []string) {
	// read from register (either default or selected)
	textToPaste := read_register(registers.selectedRegister);

	// insert into document
	insertLocation := max(cursor.head, cursor.anchor);
	if get_char_at(document, insertLocation) == #char "\r" {
		insertLocation += 2;
	}
	else {
		insertLocation += 1;
	}
	
	insert(document, insertLocation, textToPaste, true);
	change := normalize_line_endings_common(document, document.lineEndings, .{insertLocation, insertLocation + textToPaste.count}, true);
	commit_history(document);

	cursor.anchor = insertLocation;
	cursor.head = cursor.anchor + textToPaste.count - 1 + change;

	panel_scroll_to_cursor(panel);
}

paste_before_selection :: (using panel: *Panel, args: []string) {
	// read from register (either default or selected)
	textToPaste := read_register(registers.selectedRegister);

	// insert into document
	insertLocation := max(cursor.head, cursor.anchor);
	insert(document, insertLocation, textToPaste, true);
	change := normalize_line_endings_common(document, document.lineEndings, .{insertLocation, insertLocation + textToPaste.count}, true);
	commit_history(document);

	cursor.anchor = insertLocation;
	cursor.head = cursor.anchor + textToPaste.count - 1 + change;

	panel_scroll_to_cursor(panel);
}

replace_selection :: (using panel: *Panel, args: []string) {
	head := cursor.head;
	anchor := cursor.anchor;
	rangeLength := abs(cursor.head - cursor.anchor);

	delete_selection(panel, args);

	builder : String_Builder;
	builder.allocator = temp;
	init_string_builder(*builder);

	for 0..rangeLength {
		append(*builder, args[0]);
	}

	insert(document, min(cursor.head, cursor.anchor), builder_to_string(*builder,,temp));
	cursor.head = head;
	cursor.anchor = anchor;

	panel_scroll_to_cursor(panel);
}

replace_selection_with_yanked :: (using panel: *Panel, args: []string) {
	head := cursor.head;
	anchor := cursor.anchor;
	rangeLength := abs(cursor.head - cursor.anchor);

	delete_selection(panel, args);

	textToPaste := read_register(registers.selectedRegister);

	// insert into document
	insertLocation := max(cursor.head, cursor.anchor);
	insert(document, insertLocation, textToPaste, true);
	change := normalize_line_endings_common(document, document.lineEndings, .{insertLocation, textToPaste.count}, true);
	commit_history(document);

	cursor.anchor = insertLocation;
	cursor.head = cursor.anchor + textToPaste.count - 1 + change;

	panel_scroll_to_cursor(panel);
}

new_line_below :: (using panel: *Panel, args: []string) {
	goto_line_end(panel, args);
	insert_mode_line_break(panel, args);
	enter_insert_mode_start(panel, args);
}

new_line_above :: (using panel: *Panel, args: []string) {
	goto_line_start(panel, args);
	insert_mode_line_break(panel, args);

	if panel.document.lineEndings == .LF || panel.document.lineEndings == .MIXED_MAJORITY_LF {
		panel.cursor.head -= 1;
	}
	else {
		panel.cursor.head -= 2;
	}

	panel.cursor.anchor = panel.cursor.head;
	enter_insert_mode_start(panel, args);
}

// TODO: should be defined alongside the language
commentString :: "// ";

toggle_comment :: (using panel: *Panel, args: []string) {
	headCoord := get_coordinate_from_offset(document, cursor.head);
	anchorCoord := get_coordinate_from_offset(document, cursor.anchor);

	startLine := min(headCoord.line, anchorCoord.line);
	endLine := max(headCoord.line, anchorCoord.line);

	// first we need to work out if we want to comment this block of lines
	// or uncomment it
	// so we're gonna search every line to find out

	toggleComment := false;
	for startLine..endLine {
		line := get_line_content(document, it);
		lineTrimmed := trim_left(line.text);
		if !begins_with(lineTrimmed, commentString) {
			toggleComment = true;
			break;
		}
	}

	// add comment strings
	offset := 0;
	for startLine..endLine {
		line := get_line_content(document, it);
		firstNonBlankChar := 0;
		for character: line.text {
			if !is_space(character) {
				firstNonBlankChar = it_index;
				break;
			}
		}

		if toggleComment {
			insert(document, line.startByteOffset + firstNonBlankChar, commentString, true);
			offset = 3;
		}
		else {
			delete(document, line.startByteOffset + firstNonBlankChar, commentString.count, true);
			offset = -3;
		}
	}

	// shift the cursors along
	if cursor.head < cursor.anchor {
		cursor.head += offset;
		cursor.anchor += (endLine - startLine + 1)*offset;
	}
	else {
		cursor.anchor += offset;
		cursor.head += (endLine - startLine + 1)*offset;
	}

	commit_history(document);

	panel_scroll_to_cursor(panel);
}

indent_line :: (using panel: *Panel, args: []string) {
	headCoord := get_coordinate_from_offset(document, cursor.head);
	anchorCoord := get_coordinate_from_offset(document, cursor.anchor);

	startLine := min(headCoord.line, anchorCoord.line);
	endLine := max(headCoord.line, anchorCoord.line);

	for startLine..endLine {
		lineStartOffset := get_line_start(document, it);
		insert(document, lineStartOffset, "\t", true);
	}

	if cursor.head < cursor.anchor {
		cursor.head += 1;
		cursor.anchor += endLine - startLine + 1;
	}
	else {
		cursor.anchor += 1;
		cursor.head += endLine - startLine + 1;
	}
	commit_history(document);

	panel_scroll_to_cursor(panel);
}

unindent_line :: (using panel: *Panel, args: []string) {

	// delete the start char for every line, assuming it is a tab of course


	headCoord := get_coordinate_from_offset(document, cursor.head);
	anchorCoord := get_coordinate_from_offset(document, cursor.anchor);

	startLine := min(headCoord.line, anchorCoord.line);
	endLine := max(headCoord.line, anchorCoord.line);

	bytesDeleted := 0;
	for startLine..endLine {
		lineStartOffset := get_line_start(document, it);
		if get_char_at(document, lineStartOffset) == #char "\t" {
			delete(document, lineStartOffset, 1, true);

			if it == headCoord.line {
				cursor.head -= 1;
			}
			else if it == anchorCoord.line {
				cursor.anchor -= 1;
			}
			else {
				bytesDeleted += 1;
			}
		}
	}

	if cursor.head < cursor.anchor {
		cursor.anchor -= bytesDeleted + 1;
	}
	else {
		cursor.head -= bytesDeleted + 1;
	}
	commit_history(document);

	panel_scroll_to_cursor(panel);
}

undo :: (using panel: *Panel, args: []string) {
	result := undo(document);
	if result > 0 {
		panel.cursor.head = result;
		panel.cursor.anchor = panel.cursor.head;
	}

	// lets say we suppress history
	// how would that work with a timing based undo
	// When in insert mode:
	// You would suppress history by default when insert mode edits begin, and set a callback on a timer
	// If more edits come, you would reset the timer
	// If the timer runs out, you would commit the current tree to the undo stack

	// how do we do timers in a sleeping application though?

	// maybe timers is too complex of an idea
	// What if instead we just do it based on insert mode
	// Suppress history from the moment insert mode is entered
	// and then commit the tree when leaving insert mode

	// we need to know the offset to put the cursor to then

	// The undo stack really needs to know the lowest offset touched and the maximum offset touched
	// to accurately update the TS tree
	// And then we need the offset to put the cursor back to
	// which will be where you entered insert mode originallyo

	// We should be able to just store a min/max offset, which we update on every edit
	// when you commit the history you store that range
	// which may or may not be the same as the initial edit offset
	
	panel_scroll_to_cursor(panel);
}

redo :: (using panel: *Panel, args: []string) {
	result := redo(document);
	if result > 0 {
		panel.cursor.head = result;
		panel.cursor.anchor = panel.cursor.head;
	}
	panel_scroll_to_cursor(panel);
}


// File Search Commands
// --------------------------------

start_document_search :: (using panel: *Panel, args: []string) {
	// show search bar
	editorMode = .DIALOG;
	panel.activeDialog = .SEARCH;
	panel.currentSearchTerm = string.{};
	panel.searchInput.onEditCallback = document_search_on_edit;
	panel.searchInput.userData = cast(*void) panel;
	panel.previousScrollLine = panel_get_current_scrolled_line(panel);
}

confirm_document_search :: (using panel: *Panel, args: []string) {
	// set real cursor to the match that was found, setup stepping
	if panel.hasMatches {
		panel.cursor.anchor = panel.results[0].start;
		panel.cursor.head = panel.results[0].end-1;
	}
	editorMode = .NORMAL;
	panel.currentSearchTerm = string.{panel.searchInput.text.count, panel.searchInput.text.data};
	panel.previousScrollLine = panel_get_current_scrolled_line(panel);
	panel_reset_dialogs(panel);
}

end_document_search :: (using panel: *Panel) { 
	panel_scroll_to_line(panel, panel.previousScrollLine);
	input_field_reset_keeping_memory(*panel.searchInput);
	panel.searchInput.onEditCallback = null;
	panel.searchInput.userData = null;
	if panel.results.count {
		array_reset(*panel.results);
		panel.hasMatches = false;
	}
}

next_search_result :: (using panel: *Panel, args: []string) {
	array_reset(*panel.results);
	panel.hasMatches = false;

	panel.hasMatches, panel.results = search(panel.document, .NOCASE, max(panel.cursor.head, panel.cursor.anchor), panel.currentSearchTerm);

	// wrap around to the start if you didn't initially find anything
	if !panel.hasMatches {
		panel.hasMatches, panel.results = search(panel.document, .NOCASE, 0, panel.currentSearchTerm);
	}

	if panel.hasMatches {
		panel.cursor.anchor = panel.results[0].start;
		panel.cursor.head = panel.results[0].end-1;

		matchLine := get_coordinate_from_offset(panel.document, panel.results[0].start).line;
		startVisibleLine, pageSize := panel_calculate_visible_lines(panel);
		if matchLine < startVisibleLine || matchLine >= (startVisibleLine+pageSize) {
			panel_scroll_to_line(panel, matchLine - pageSize/2); 
		}
	}
}

previous_search_result :: (using panel: *Panel, args: []string) {
	array_reset(*panel.results);
	panel.hasMatches = false;

	panel.hasMatches, panel.results = search(panel.document, .NOCASE, 0, panel.currentSearchTerm, stopAtFirstResult=false);

	if panel.hasMatches {
		// you want to find the result whos range is just before the cursor's offset
		bestMatch := -1;
		cursorOffset := min(panel.cursor.head, panel.cursor.anchor);
		for result: panel.results {
			if result.start >= cursorOffset then break;
			bestMatch = it_index;
		}

		// wrap around if nothing found behind cursor
		if bestMatch < 0 {
			bestMatch = panel.results.count-1;
		}

		panel.cursor.anchor = panel.results[bestMatch].start;
		panel.cursor.head = panel.results[bestMatch].end-1;

		matchLine := get_coordinate_from_offset(panel.document, panel.results[bestMatch].start).line;
		startVisibleLine, pageSize := panel_calculate_visible_lines(panel);
		if matchLine < startVisibleLine || matchLine >= (startVisibleLine+pageSize) {
			panel_scroll_to_line(panel, matchLine - pageSize/2); 
		}
	}
}

document_search_on_edit :: (userData: *void, input: string) {
	panel := cast(*Panel) userData;
	array_reset(*panel.results);
	panel.hasMatches = false;

	panel.hasMatches, panel.results = search(panel.document, .NOCASE, max(panel.cursor.head, panel.cursor.anchor), input);

	// is the result off the edge of the screen? if so scroll so it's centered
	if panel.hasMatches {
		matchLine := get_coordinate_from_offset(panel.document, panel.results[0].start).line;
		startVisibleLine, pageSize := panel_calculate_visible_lines(panel);
		if matchLine < startVisibleLine || matchLine >= (startVisibleLine+pageSize) {
			panel_scroll_to_line(panel, matchLine - pageSize/2); 
		}
	}
}

// Insert Mode
// -----------------------------

insert_mode_insert_string :: (input: string) {
	// do the insert
	distanceToAnchor := focusedPanel.cursor.anchor - focusedPanel.cursor.head;
	insert(focusedPanel.document, focusedPanel.cursor.head, input, editorMode == .INSERT);

	// move the cursor along
	focusedPanel.cursor.head += input.count;

	// @todo: update virtual column correctly
	focusedPanel.cursor.virtualColumn = 0;

	// update the anchor
	if distanceToAnchor > 0 {
		// anchor is ahead, we want to move it same as the head
		focusedPanel.cursor.anchor += input.count;
	}
	else if distanceToAnchor == 0 {
		focusedPanel.cursor.anchor = focusedPanel.cursor.head;
	}

	panel_scroll_to_cursor(*focusedPanel);
}

insert_mode_handle_text_input :: (char: Utf8_Char) {
	textToInsert := to_string(*char);
	insert_mode_insert_string(textToInsert);
}

insert_mode_line_break :: (using panel: *Panel, args: []string) {
	textToInsert := "\r\n";
	if panel.document.lineEndings == .LF || panel.document.lineEndings == .MIXED_MAJORITY_LF {
		textToInsert = "\n";
	}
	insert_mode_insert_string(textToInsert);
}

insert_tab_character :: (using panel: *Panel, args: []string) {
	textToInsert := "\t";
	insert_mode_insert_string(textToInsert);
}

insert_mode_backward_delete_char :: (using panel: *Panel, args: []string) {
	distanceToAnchor := cursor.anchor - cursor.head;

	delete(document, cursor.head-1, 1);
	cursor.head -= 1;
	// @todo: update virtual column correctly

	// update the anchor
	if distanceToAnchor > 0 {
		// anchor is ahead, we want to move it same as the head
		cursor.anchor -= 1;
	}
	else if distanceToAnchor == 0 {
		cursor.anchor = cursor.head;
	}

	panel_scroll_to_cursor(panel);
}

insert_mode_forward_delete_char :: (using panel: *Panel, args: []string) {
	distanceToAnchor := cursor.anchor - cursor.head;

	delete(document, cursor.head, 1);
	// @todo: update virtual column correctly

	// update the anchor
	if distanceToAnchor > 0 {
		// anchor is ahead, we want to move it same as the head
		cursor.anchor -= 1;
	}
	else if distanceToAnchor == 0 {
		cursor.anchor = cursor.head;
	}
	panel_scroll_to_cursor(panel);
}


// View Commands
// ------------------------------

page_up :: (using panel: *Panel, args: []string) {
	startVisibleLine, pageSize := panel_calculate_visible_lines(panel, true);

	// move the cursor up half a page
	cursorCoordinate := get_coordinate_from_offset(panel.document, cursor.head);
	move_cursor_to_specific_line(panel, max(cursorCoordinate.line - pageSize, 0));
	focusedPanel.cursor.anchor = panel.cursor.head;

	// scroll to keep the cursor in the same relative place on screen
	panel_scroll_to_line(panel, startVisibleLine - pageSize);
}

page_down :: (using panel: *Panel, args: []string) {
	startVisibleLine, pageSize := panel_calculate_visible_lines(panel, true);
	numLinesDocument := get_number_of_lines(panel.document);

	// move the cursor down half a page
	cursorCoordinate := get_coordinate_from_offset(panel.document, cursor.head);
	move_cursor_to_specific_line(panel, min(cursorCoordinate.line + pageSize, numLinesDocument));
	focusedPanel.cursor.anchor = focusedPanel.cursor.head;

	// scroll to keep the cursor in the same relative place on screen
	panel_scroll_to_line(panel, startVisibleLine + pageSize);
}

half_page_up :: (using panel: *Panel, args: []string) {
	startVisibleLine, pageSize := panel_calculate_visible_lines(panel, true);

	// move the cursor up half a page
	cursorCoordinate := get_coordinate_from_offset(panel.document, cursor.head);
	move_cursor_to_specific_line(panel, max(cursorCoordinate.line - pageSize/2, 0));
	focusedPanel.cursor.anchor = focusedPanel.cursor.head;

	// scroll to keep the cursor in the same relative place on screen
	panel_scroll_to_line(panel, startVisibleLine - pageSize/2);
}

half_page_down :: (using panel: *Panel, args: []string) {
	startVisibleLine, pageSize := panel_calculate_visible_lines(panel, true);
	numLinesDocument := get_number_of_lines(panel.document);

	// move the cursor down half a page
	cursorCoordinate := get_coordinate_from_offset(panel.document, cursor.head);
	move_cursor_to_specific_line(panel, min(cursorCoordinate.line + pageSize/2, numLinesDocument));
	focusedPanel.cursor.anchor = focusedPanel.cursor.head;

	// scroll to keep the cursor in the same relative place on screen
	panel_scroll_to_line(panel, startVisibleLine + pageSize/2);
}


// Dialog Commands
// -----------------------------

dialog_select_next :: (using panel: *Panel, args: []string) {
	if activeDialog == {
		case .NONE; return;
		case .COMMAND_PICKER;
			command_picker_select_next(panel, args);
		case .FILESYSTEM_NAVIGATOR;
			filesystem_nav_select_next(panel, args);
		case .FILE_FINDER;
			file_finder_select_next(panel);
		case .SEARCH; return;
	}
}

dialog_select_previous :: (using panel: *Panel, args: []string) {
	if activeDialog == {
		case .NONE; return;
		case .COMMAND_PICKER;
			command_picker_select_previous(panel, args);
		case .FILESYSTEM_NAVIGATOR;
			filesystem_nav_select_previous(panel, args);
		case .FILE_FINDER;
			file_finder_select_previous(panel);
		case .SEARCH; return;
	}
}

dialog_action_item :: (using panel: *Panel, args: []string) {
	if activeDialog == {
		case .NONE; return;
		case .COMMAND_PICKER;
			command_picker_execute_command(panel, args);
		case .FILESYSTEM_NAVIGATOR;
			filesystem_nav_action_item(panel, args);
		case .FILE_FINDER;
			file_finder_select_file(panel);
		case .SEARCH;
			confirm_document_search(panel, args);
	}
}


dialog_backward_delete :: (using panel: *Panel, args: []string) {
	inputField := *commandPicker.input;
	if activeDialog == {
		case .FILE_FINDER; inputField = *fileFinder.input;
		case .FILESYSTEM_NAVIGATOR; inputField = *filesystemNav.input;
		case .COMMAND_PICKER; inputField = *commandPicker.input;
		case .SEARCH; inputField = *searchInput;
	}

	if activeDialog == {
		case .FILESYSTEM_NAVIGATOR; 
			state := *filesystemNav;
			if state.currentPath.count > 0 && state.input.text.count == 0 {
				state.currentPath.count -= 1;
				filesystem_nav_refresh_directory_list(state);
				return;
			}
			#through;
		case .COMMAND_PICKER; #through;
		case .SEARCH; #through;
		case .FILE_FINDER;
			inputField.text.count -= 1;
			inputField.cursor -= 1;
			inputField.text.count = max(inputField.text.count, 0);
			inputField.cursor = max(inputField.cursor, 0);
			if inputField.onEditCallback {
				inputField.onEditCallback(inputField.userData, string.{inputField.text.count, inputField.text.data});
			}
		case .NONE; return;
	}
}

dialog_handle_text_input :: (using panel: *Panel, char: Utf8_Char) {
	inputField := *commandPicker.input;
	if activeDialog == {
		case .FILE_FINDER; inputField = *fileFinder.input;
		case .FILESYSTEM_NAVIGATOR; inputField = *filesystemNav.input;
		case .COMMAND_PICKER; inputField = *commandPicker.input;
		case .SEARCH; inputField = *searchInput;
	}

	for 0..char.count-1 {
		array_add(*inputField.text, char.bytes[it]);
		inputField.cursor += 1;
	}
	if inputField.onEditCallback {
		inputField.onEditCallback(inputField.userData, string.{inputField.text.count, inputField.text.data});
	}
}


// Misc Commands
// ------------------------------

quit :: (panel: *Panel, args: []string) {
	pendingQuit = true;
}

open_file :: (panel: *Panel, args: []string) {
	panel.activeDialog = .FILESYSTEM_NAVIGATOR;
	filesystem_nav_open(*panel.filesystemNav);
}

open_file_in_working_dir :: (panel: *Panel, args: []string) {
	panel.activeDialog = .FILESYSTEM_NAVIGATOR;
	filesystem_nav_open(*panel.filesystemNav, false, get_working_directory());
}

save_file :: (panel: *Panel, args: []string) {
	document_save(panel.document, panel.document.path);
}

save_file_as :: (panel: *Panel, args: []string) {
	panel.activeDialog = .FILESYSTEM_NAVIGATOR;
	filesystem_nav_open(*panel.filesystemNav, true);
}

print_piece_chain_debug :: (using panel: *Panel, args: []string) {
	log("Tree Nodes: ");
	pretty_print_tree(document.tree);
	log("\nDocument: ");
	iterator := make_iterator(document, 0);

	while outer := iterator.node != null {
		print("[%,", iterator.offset);
		while iterator.firstChar < iterator.lastChar {
			if string.{2, iterator.firstChar} == "\r\n" {
				print("\\r\\n\r\n");
				iterator.firstChar += 1;
				iterator.offset += 1;
			}
			else if iterator.firstChar.* == #char "\n" {
				print("\\n\n");
			}
			else {
				print("%", string.{ 1, iterator.firstChar });
			}
			iterator.firstChar += 1;
			iterator.offset += 1;
		}
		print("]");
		next_node(*iterator);
	}
}

visualize_undos :: (using panel: *Panel, args: []string) {
	// document_debug_print_undos(document);
}

toggle_render_line_endings :: (panel: *Panel, args: []string) {
	fontCode.drawLineEndings = !fontCode.drawLineEndings;
}

normalize_line_endings_common :: (document: *Document, targetEndings: Document.LineEndingMode, range: Document.Range, suppressHistory := false) -> s64 {
	// this function needs to peak ahead, which requires it to binary query the tree for every single character checked
	// probably can make it faster, but it's fine for now
	// you could take the strategy of going line by line, rather than char by char
	
	iterator := make_iterator(document, range.start);
	end := range.end;
	if targetEndings == .LF {
		for :raw_bytes iterator {
			if it == #char "\r" && get_char_at(document, iterator.offset+1) == #char "\n" {
				delete(document, iterator.offset, 1, true);
				iterator.offset -= 1;
				end -= 1;
			}
			if iterator.offset == end then break;
		}
		document.lineEndings = .LF;
	}
	else if targetEndings == .CRLF {
		for :raw_bytes iterator {
			if it != #char "\r" && get_char_at(document, iterator.offset+1) == #char "\n" {
				// this is done in two steps to ensure \r\n do not cross node boundaries in the piece tree
				delete(document, iterator.offset+1, 1, true);
				insert(document, iterator.offset+1, "\r\n", true);
				iterator.offset += 1;
				end += 1;
			}
			if iterator.offset == end then break;
		}
		document.lineEndings = .CRLF;
	}
	if suppressHistory == false then commit_history(document);
	return end - range.end;
}

normalize_line_endings_lf :: (using panel: *Panel, args: []string) {
	normalize_line_endings_common(document, .LF, .{0, S64_MAX});
}

normalize_line_endings_crlf :: (using panel: *Panel, args: []string) {
	normalize_line_endings_common(document, .CRLF, .{0, S64_MAX});
}
	
