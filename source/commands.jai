
// Movement commands
// ------------------------------------

move_one_char_left :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Move one char left",
		keybinding = .["h", "<left>"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	INSERT :: CommandConfig.{
		prettyName = "Move one char left",
		keybinding = .["<left>"],
		flags =  .PER_CURSOR
	};
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);

	lineStart, lineEnd := get_line_range(panel.document, cursorCoordinate.line);

	cursor.head -= 1;
	cursor.head = clamp(cursor.head, lineStart, lineEnd);
	cursor.anchor = cursor.head;
} @command

extend_one_char_left :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend one char left", keybinding = .["H"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_one_char_left(panel, cursor);
} @command

move_one_char_right :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Move one char right",
		keybinding = .["l", "<right>"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	INSERT :: CommandConfig.{
		prettyName = "Move one char right",
		keybinding = .["<right>"],
		flags = .PER_CURSOR
	};
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);

	lineStart, lineEnd := get_line_range(panel.document, cursorCoordinate.line);

	cursor.head += 1;
	cursor.head = clamp(cursor.head, lineStart, lineEnd);
	cursor.anchor = cursor.head;
} @command

extend_one_char_right :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend one char right", keybinding = .["L"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_one_char_right(panel, cursor);
} @command

chars_to_tabstop :: (column: s64) -> s64 {
	return tabSize - column % tabSize;
}

// Converts a virtual (visual) column into a byte offset into lineContent's text,
// accounting for tab stops. Clamped to the end of the line if the column is beyond it.
byte_offset_for_virtual_column :: (lineContent: Document.LineContent, virtualColumn: s64) -> s64 {
	columnCounter := 0;
	for lineContent.text {
		if it == #char "\t" {
			columnCounter += chars_to_tabstop(columnCounter);
		}
		else {
			columnCounter += 1;
		}

		if columnCounter > virtualColumn {
			return it_index;
		}
	}
	return lineContent.text.count;
}

// opposite of above
// Should really rename to visual column
virtual_column_for_byte_offset :: (lineContent: Document.LineContent, byteColumn: s64) -> s64 {
	column := 0;
	for lineContent.text {
		if it_index >= byteColumn then break;
		if it == #char "\t" then column += chars_to_tabstop(column);
		else column += 1;
	}
	return column;
}

move_one_line_down :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Move one line down",
		keybinding = .["j", "<down>"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	INSERT :: CommandConfig.{
		prettyName = "Move one line down",
		keybinding = .["<down>"],
		flags = .PER_CURSOR
	};
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);
	numLines := get_number_of_lines(document);
	newLine := min(cursorCoordinate.line + 1, numLines - 1);
	newLineContent := get_line_content(panel.document, newLine,,temp);

	targetColumn := get_virtual_column(panel, cursor);
	cursor.head = newLineContent.startByteOffset + byte_offset_for_virtual_column(newLineContent, targetColumn);
	cursor.anchor = cursor.head;

	cursor.virtualColumn = targetColumn;
	cursor.virtualColumnHead = cursor.head;
} @command

extend_one_line_down :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend one line down", keybinding = .["J"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_one_line_down(panel, cursor);
} @command

move_one_line_up :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Move one line up",
		keybinding = .["k", "<up>"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	INSERT :: CommandConfig.{
		prettyName = "Move one line up",
		keybinding = .["<up>"],
		flags = .PER_CURSOR
	};
	cursorCoordinate := get_coordinate_from_offset(document, cursor.head);
	newLine := max(cursorCoordinate.line - 1, 0);
	newLineContent := get_line_content(panel.document, newLine,,temp);

	targetColumn := get_virtual_column(panel, cursor);
	cursor.head = newLineContent.startByteOffset + byte_offset_for_virtual_column(newLineContent, targetColumn);
	cursor.anchor = cursor.head;

	cursor.virtualColumn = targetColumn;
	cursor.virtualColumnHead = cursor.head;
} @command

extend_one_line_up :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend one line up", keybinding = .["K"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_one_line_up(panel, cursor);
} @command

move_cursor_to_specific_line :: (using panel: *Panel, cursor: *Cursor, line: s64) {
	newLineContent := get_line_content(panel.document, line,,temp);

	targetColumn := get_virtual_column(panel, cursor);
	cursor.head = newLineContent.startByteOffset + byte_offset_for_virtual_column(newLineContent, targetColumn);

	cursor.virtualColumn = targetColumn;
	cursor.virtualColumnHead = cursor.head;
}

get_virtual_column :: (using panel: *Panel, cursor: *Cursor) -> s64 {
	// We used to have every single piece of code manually update the virtual column anytime it
	// changed the cursor in some relevant way, but this became very error prone and resulted in
	// boilerplate code being left everywhere. So now the virtual column is lazy updated when
	// it's required by storing the cursor head of where it was last recomputed.
	// This getter will check if it needs updating and update it accordingly
	if cursor.virtualColumnHead != cursor.head {
		cursorCoordinate := get_coordinate_from_offset(document, cursor.head);
		newLineContent := get_line_content(document, cursorCoordinate.line,,temp);
		cursor.virtualColumn = 0;
		for newLineContent.text {
			if it_index >= cursorCoordinate.col then break;
			if it == #char "\t" {
				cursor.virtualColumn += chars_to_tabstop(cursor.virtualColumn);
			}
		else {
				cursor.virtualColumn += 1;
			}
		}
		cursor.virtualColumnHead = cursor.head;
	}
	return cursor.virtualColumn;
}

goto_document_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Goto document start", keybinding = .["gk"], flags = .PER_CURSOR };
	cursor.head = 0;
	cursor.anchor = cursor.head;
	// scroll the window if the cursor will now become out of view
	panel_scroll_to_line(panel, 0);
} @command

extend_to_document_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to document start", keybinding = .["gK"], flags = .EXTEND | .PER_CURSOR };
	goto_document_start(panel, cursor);
} @command

goto_document_end :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Goto document end", keybinding = .["gj"], flags = .PER_CURSOR };
	cursor.head = get_size(document)-1;
	cursor.head = shift_offset_line_endings(document, cursor.head, .FORWARD);
	cursor.anchor = cursor.head;

	// scroll the window if the cursor will now become out of view
	pageSize := panel_get_page_size(panel);
	cursorLine := get_coordinate_from_offset(document, cursor.head).line;
	panel_scroll_to_line(panel, cursorLine - pageSize + 1);
} @command

extend_to_document_end :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to document end", keybinding = .["gJ"], flags = .EXTEND | .PER_CURSOR };
	goto_document_end(panel, cursor);
} @command

goto_line_end :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{ prettyName = "Goto line end", keybinding = .["gl"], flags = .PER_CURSOR };
	coordinate := get_coordinate_from_offset(document, cursor.head);
	_, cursor.head = get_line_range(document, coordinate.line);
	cursor.anchor = cursor.head;
} @command

extend_to_line_end :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to line end", keybinding = .["gL"], flags = .EXTEND | .PER_CURSOR };
	goto_line_end(panel, cursor);
} @command

goto_line :: (using panel: *Panel, cursor: *Cursor, lineNumber: s64) {
	NORMAL :: CommandConfig.{ prettyName = "Goto Line", keybinding = .["gg"] };
	cursor.head = get_line_start(document, lineNumber-1);
	cursor.anchor = cursor.head;
} @command

goto_line_start :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Goto line start",
		keybinding = .["gh"],
		flags = .PER_CURSOR
	};
	coordinate := get_coordinate_from_offset(document, cursor.head);
	cursor.head = get_line_start(document, coordinate.line);
	cursor.anchor = cursor.head;
} @command

extend_to_line_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to line start", keybinding = .["gH"], flags = .EXTEND | .PER_CURSOR };
	goto_line_start(panel, cursor);
} @command

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

move_word_forward :: (using panel: *Panel, cursor: *Cursor, checkPosition: (u8, u8, CharCategory, CharCategory) -> bool) {
	cursor.anchor = cursor.head;
	iter := make_iterator(document, cursor.head);
	for iter {
		cursor.head = iter.offset+1;
		next := get_char_at(document, iter.offset+1);
		next = ifx next == #char "\r" then get_char_at(document, iter.offset+2) else next;
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
}

move_word_reverse :: (using panel: *Panel, cursor: *Cursor, checkPosition: (u8, u8, CharCategory, CharCategory) -> bool) {
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
}

move_word_start :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to next word start",
		keybinding = .["w"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_forward(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isWordBoundary := nextCharCategory != prevCharCategory;
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		nextIsWhitespace := nextCharCategory == .WHITESPACE;
		return isWordBoundary && (nextIsLineEnding || !nextIsWhitespace);
	});
} @command

extend_word_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to next word start", keybinding = .["W"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_word_start(panel, cursor);
} @command

move_long_word_start :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to next long word start",
		keybinding = .["alt+w"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_forward(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isLongWordBoundary := prevCharCategory != nextCharCategory;
		if (nextCharCategory == .WORD && prevCharCategory == .PUNCTUATION) 
		|| (nextCharCategory == .PUNCTUATION && prevCharCategory == .WORD) {
			isLongWordBoundary = false;
		}

		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		nextIsWhitespace := nextCharCategory == .WHITESPACE;
		return isLongWordBoundary && (nextIsLineEnding || !nextIsWhitespace);
	});
} @command

extend_long_word_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to next long word start", keybinding = .["alt+shift+w"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_long_word_start(panel, cursor);
} @command

move_sub_word_start :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to next sub word start",
		keybinding = .["ctrl+w"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_forward(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
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
} @command

extend_sub_word_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to next sub word start", keybinding = .["ctrl+shift+w"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_sub_word_start(panel, cursor);
} @command

move_prev_word_start :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to previous word start",
		keybinding = .["b"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_reverse(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isWordBoundary := nextCharCategory != prevCharCategory;
		if nextCharCategory == .LINE_ENDING && prevCharCategory == .LINE_ENDING {
			isWordBoundary = true;
		}
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isWordBoundary && (!prevIsWhitespace || nextIsLineEnding);
	});
} @command

extend_prev_word_start :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to prev word start", keybinding = .["B"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_prev_word_start(panel, cursor);
} @command

move_word_end :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to next word end",
		keybinding = .["e"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_forward(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isWordBoundary := nextCharCategory != prevCharCategory;
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isWordBoundary && (!prevIsWhitespace || nextIsLineEnding);
	});
} @command

extend_word_end :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to next word end", keybinding = .["E"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_word_end(panel, cursor);
} @command

move_long_word_end :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to next long word end",
		keybinding = .["alt+e"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_forward(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
		isLongWordBoundary := prevCharCategory != nextCharCategory;
		if (nextCharCategory == .WORD && prevCharCategory == .PUNCTUATION) 
		|| (nextCharCategory == .PUNCTUATION && prevCharCategory == .WORD) {
			isLongWordBoundary = false;
		}
		nextIsLineEnding := nextCharCategory == .LINE_ENDING;
		prevIsWhitespace := prevCharCategory == .WHITESPACE;
		return isLongWordBoundary && (!prevIsWhitespace || nextIsLineEnding);
	});
} @command

extend_long_word_end :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to next long word end", keybinding = .["alt+shift+e"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_long_word_end(panel, cursor);
} @command

move_sub_word_end :: (using panel: *Panel, cursor: *Cursor) { 
	NORMAL :: CommandConfig.{
		prettyName = "Move to next sub word end",
		keybinding = .["ctrl+e"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	move_word_forward(panel, cursor, (prev: u8, next: u8, prevCharCategory: CharCategory, nextCharCategory: CharCategory) -> bool {
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
} @command

extend_sub_word_end :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to next sub word end", keybinding = .["ctrl+shift+e"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	move_sub_word_end(panel, cursor);
} @command

jump_to_char :: (using panel: *Panel, cursor: *Cursor, char: u8) { 
	NORMAL :: CommandConfig.{
		prettyName = "Jump to first occurence of {char}",
		keybinding = .["f{char}"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	iter := make_iterator(document, cursor.head+1);
	for iter {
		cursor.head = iter.offset;
		if char == it {
			break;
		}
	}
} @command

extend_to_char :: (using panel: *Panel, cursor: *Cursor, char: u8) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to first occurence of {char}", keybinding = .["F{char}"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	jump_to_char(panel, cursor, char);
} @command

jump_to_last_char :: (using panel: *Panel, cursor: *Cursor, char: u8) { 
	NORMAL :: CommandConfig.{
		prettyName = "Jump to last occurence of {char}",
		keybinding = .["alt+f{char}"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	iter := make_reverse_iterator(document, cursor.head);
	for iter {
		cursor.head = iter.offset;
		if char == it {
			break;
		}
	}
} @command

extend_to_last_char :: (using panel: *Panel, cursor: *Cursor, char: u8) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to last occurence of {char}", keybinding = .["alt+shift+f{char}"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	jump_to_last_char(panel, cursor, char);
} @command

jump_to_before_char :: (using panel: *Panel, cursor: *Cursor, char: u8) { 
	NORMAL :: CommandConfig.{
		prettyName = "Jump to just before first occurence of {char}",
		keybinding = .["t{char}"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	iter := make_iterator(document, cursor.head+1);
	for iter {
		cursor.head = iter.offset;
		next := get_char_at(document, iter.offset+1);
		if char == next {
			break;
		}
	}
} @command

extend_to_before_char :: (using panel: *Panel, cursor: *Cursor, char: u8) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to just before first occurence of {char}", keybinding = .["T{char}"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	jump_to_before_char(panel, cursor, char);
} @command

jump_to_before_last_char :: (using panel: *Panel, cursor: *Cursor, char: u8) { 
	NORMAL :: CommandConfig.{
		prettyName = "Jump to just before last occurence of {char}",
		keybinding = .["alt+t{char}"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	iter := make_reverse_iterator(document, cursor.head);
	for iter {
		cursor.head = iter.offset;
		if char == it {
			cursor.head += 1;
			break;
		}
	}
} @command

extend_to_before_last_char :: (using panel: *Panel, cursor: *Cursor, char: u8) {
	NORMAL :: CommandConfig.{ prettyName = "Extend to just before last occurence of {char}", keybinding = .["alt+shift+t{char}"], flags = .REPEATABLE | .EXTEND | .PER_CURSOR };
	jump_to_before_last_char(panel, cursor, char);
} @command

extend_selection_to_lines :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Extend selection to full lines",
		keybinding = .["x"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	// flip the cursors if required
	if cursor.head != cursor.anchor && min(cursor.head, cursor.anchor) == cursor.head {
		temp := cursor.head;
		cursor.head = cursor.anchor;
		cursor.anchor = temp;
	}

	anchorCoord := get_coordinate_from_offset(document, cursor.anchor);
	headCoord := get_coordinate_from_offset(document, cursor.head);
	_, headLineEnd := get_line_range(document, headCoord.line);
	if anchorCoord.col == 0 && cursor.head == headLineEnd {
		if headCoord.line == get_number_of_lines(document) return;
		start,end := get_line_range(document, headCoord.line+1);
		cursor.head = end;
	}
	else {
		coord := get_coordinate_from_offset(document, min(cursor.anchor, cursor.head));
		cursor.anchor, cursor.head = get_line_range(document, coord.line);
	}
} @command

extend_selection_to_lines_above :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Extend selection to lines above",
		keybinding = .["X"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	// flip the cursors if required
	if cursor.head != cursor.anchor && min(cursor.head, cursor.anchor) == cursor.anchor {
		temp := cursor.head;
		cursor.head = cursor.anchor;
		cursor.anchor = temp;
	}

	headCoord := get_coordinate_from_offset(document, cursor.head);
	anchorCoord := get_coordinate_from_offset(document, cursor.anchor);
	_, anchorLineEnd := get_line_range(document, anchorCoord.line);
	if headCoord.col == 0 && cursor.anchor == anchorLineEnd {
		if headCoord.line == 0 return;
		start,end := get_line_range(document, headCoord.line-1);
		cursor.head = start;
	}
	else {
		coord := get_coordinate_from_offset(document, min(cursor.anchor, cursor.head));
		cursor.head, cursor.anchor = get_line_range(document, coord.line);
	}
} @command

expand_selection_by_syntax :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Expand selection to parent syntax",
		keybinding = .["alt+o"],
		flags = .REPEATABLE
	};
	if !document_supports_treesitter(document) {
		push_notification("Not supported in this language");
		return;
	}

	before := panel_snapshot_selection(panel);
	changed := false;
	rootNode := ts_tree_root_node(document_get_ts_tree(document));

	for * c: cursors {
		range := cursor_to_range(c);
		node := ts_node_descendant_for_byte_range(rootNode, xx range.start, xx (range.end+1));

		startByte := ts_node_start_byte(node);
		endByte := ts_node_end_byte(node)-1;

		while startByte == range.start && endByte == range.end {
			parent := ts_node_parent(node);
			if !ts_node_is_null(parent) {
				node = parent;
				startByte = ts_node_start_byte(node);
				endByte = ts_node_end_byte(node)-1;
			}
			else {
				break;
			}
		}

		if range.start != startByte || range.end != endByte {
			changed = true;
		}
		c.* = range_to_cursor(c.*, .{startByte, endByte});
	}

	// if the selection has changed, store it in the history so it can be restored with shrink_selection_by_syntax below
	if changed {
		array_add(*syntaxSelectionsHistory, before);
	}
	else {
		free(before.cursors.data);
	}
} @command

// True if every cursor in the current selection contains at least one snapshot cursor, and every snapshot
// cursor is contained by a current cursor, i.e. the snapshot is what you'd get by shrinking the current selection.
// Relies on both sets of cursors being sorted and non overlapping
syntax_history_matches_selection :: (snapshot: SelectionSnapshot, cursors: []Cursor) -> bool {
	i := 0;
	for current: cursors {
		contained := 0;
		while i < snapshot.cursors.count && range_start(snapshot.cursors[i]) >= range_start(current) && range_end(snapshot.cursors[i]) <= range_end(current) {
			i += 1;
			contained += 1;
		}
		if contained == 0 return false;
	}
	return i == snapshot.cursors.count;
}

shrink_selection_by_syntax :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Shrink selection by syntax",
		keybinding = .["alt+i"],
		flags = .REPEATABLE
	};
	if !document_supports_treesitter(document) {
		push_notification("Not supported in this language");
		return;
	}

	// Restore the selection from before the last expand, but only if the whole selection still matches it
	if syntaxSelectionsHistory.count > 0 {
		top := pop(*syntaxSelectionsHistory);
		matches := syntax_history_matches_selection(top, cursors);
		if matches {
			panel_restore_selection(panel, top);
		}
		free(top.cursors.data);
		if matches return;

		// the history is stale, drop it and fall through to shrinking each cursor
		panel_clear_syntax_history(panel);
	}

	rootNode := ts_tree_root_node(document_get_ts_tree(document));
	for * c: cursors {
		range := cursor_to_range(c);
		node := ts_node_descendant_for_byte_range(rootNode, xx range.start, xx (range.end+1));
		node = ts_node_child(node, 0);
		if !ts_node_is_null(node) {
			c.* = range_to_cursor(c.*, .{ts_node_start_byte(node), ts_node_end_byte(node)-1});
		}
	}
} @command

select_next_sibling :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Select next sibling syntax node",
		keybinding = .["alt+p"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	if !document_supports_treesitter(document) {
		push_notification("Not supported in this language");
		return;
	}
	
	range := cursor_to_range(cursor);
	rootNode := ts_tree_root_node(document_get_ts_tree(document));
	node := ts_node_descendant_for_byte_range(rootNode, xx range.start, xx (range.end+1));
	node = ts_node_next_sibling(node);
	
	if !ts_node_is_null(node) {
		cursor.* = range_to_cursor(cursor.*, .{ts_node_start_byte(node), ts_node_end_byte(node)-1});
	}
} @command

select_prev_sibling :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{
		prettyName = "Select prev sibling syntax node",
		keybinding = .["alt+u"],
		flags = .REPEATABLE | .PER_CURSOR
	};
	if !document_supports_treesitter(document) {
		push_notification("Not supported in this language");
		return;
	}
	
	range := cursor_to_range(cursor);
	rootNode := ts_tree_root_node(document_get_ts_tree(document));
	node := ts_node_descendant_for_byte_range(rootNode, xx range.start, xx (range.end+1));
	node = ts_node_prev_sibling(node);
	
	if !ts_node_is_null(node) {
		cursor.* = range_to_cursor(cursor.*, .{ts_node_start_byte(node), ts_node_end_byte(node)-1});
	}
} @command

select_whole_document :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Select whole document", keybinding = .["%"] };
	cursor.anchor = 0;
	cursor.head = get_size(document)-1;
	cursor.head = shift_offset_line_endings(document, cursor.head, .REVERSE);
} @command

collapse_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Collapse selection", keybinding = .[";"], flags =  .PER_CURSOR };
	cursor.anchor = cursor.head;
} @command

flip_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Flip selection", keybinding = .["alt+;"], flags = .PER_CURSOR };
	temp := cursor.head;
	cursor.head = cursor.anchor;
	cursor.anchor = temp;
} @command

// Returns whether the line can hold a cursor at targetColumn, and the byte offset if so
offset_for_column_on_line :: (document: DocumentHandle, lineNumber: s64, targetColumn: s64, atLineEnd: bool) -> bool, s64 {
	line := get_line_content(document, lineNumber,,temp);
	lineWidth := virtual_column_for_byte_offset(line, line.text.count);
	
	suitable := ifx atLineEnd then targetColumn <= lineWidth else targetColumn < lineWidth;
	if !suitable return false, 0;
	
	return true, line.startByteOffset + byte_offset_for_virtual_column(line, targetColumn);
}

copy_selection_to_next_line :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Copy selection to next line", keybinding = .["C"], flags = .PER_CURSOR };
	
	SourcePosition :: struct {
		line: s64;
		visualColumn: s64;
		atLineEnd: bool;
	}
	get_source_position :: (document: DocumentHandle, offset: s64) -> SourcePosition {
		coord := get_coordinate_from_offset(document, offset);
		line := get_line_content(document, coord.line,,temp);
		return .{ coord.line, virtual_column_for_byte_offset(line, coord.col), coord.col >= line.text.count };
	}
	
	head := get_source_position(document, cursor.head);
	anchor := get_source_position(document, cursor.anchor);
	stepSize := abs(head.line - anchor.line) + 1;
	numLines := get_number_of_lines(document);
	
	lineOffset := stepSize;
	while max(head.line, anchor.line) + lineOffset < numLines {
		headOk, newHead := offset_for_column_on_line(document, head.line + lineOffset, head.visualColumn, head.atLineEnd);
		anchorOk, newAnchor := offset_for_column_on_line(document, anchor.line + lineOffset, anchor.visualColumn, anchor.atLineEnd);
		
		if headOk && anchorOk {
			newCursor := array_add(*panel.cursors);
			newCursor.head = newHead;
			newCursor.anchor = newAnchor;
			return;
		}
		lineOffset += stepSize;
	}
	// no suitable lines below, don't add a cursor
} @command

keep_primary_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Keep primary selection", keybinding = .[","] };
	panel.cursors[0] = panel_get_primary_cursor(panel).*;
	panel.primaryCursor = 0;
	array_resize(*panel.cursors, 1);
} @command

start_select_all_in_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Select All In Selection", keybinding = .["s"] };
	editorMode = .SELECT;
	array_reset(*panel.results);
	panel.hasMatches = false;
	panel.searchInput.onEditCallback = select_all_in_selection_on_edit;
	panel.searchInput.userData = cast(*void) panel;
} @command

confirm_select_all_in_selection :: (using panel: *Panel, cursor: *Cursor) {
	SELECT :: CommandConfig.{ prettyName = "Confirm select all in selection", keybinding = .["<enter>"] };
	if panel.hasMatches && panel.results.count > 0 {
		array_reset_keeping_memory(*panel.cursors);
		for panel.results {
			newCursor := array_add(*panel.cursors);
			newCursor.head = shift_offset_line_endings(document, it.end - 1, .REVERSE);
			newCursor.anchor = it.start;
		}
		panel.primaryCursor = 0;
	}

	panel_reset_dialogs(panel);
} @command

cancel_select_all_in_selection :: (using panel: *Panel) {
	input_field_reset_keeping_memory(*panel.searchInput);
	panel.searchInput.onEditCallback = null;
	panel.searchInput.userData = null;
	array_reset(*panel.results);
	panel.hasMatches = false;
}

select_all_in_selection_on_edit :: (userData: *void, input: string) {
	panel := cast(*Panel) userData;
	
	// Search fully in the current range of all selections
	array_reset_keeping_memory(*panel.results);
	panel.hasMatches = false;
	for cursor: panel.cursors {
		selectionEnd := shift_offset_line_endings(panel.document, max(cursor.head, cursor.anchor) + 1, .FORWARD);
		selectionRange := Document.Range.{min(cursor.head, cursor.anchor), selectionEnd};
		hasMatches, results := search(panel.document, panel_search_type(panel), selectionRange, input, stopAtFirstResult=false);
		panel.hasMatches |= hasMatches;
		for results array_add(*panel.results, it);
		array_free(results);
	}
}

start_split_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Split Selection", keybinding = .["S"] };
	editorMode = .SPLIT;
	array_reset(*panel.results);
	panel.hasMatches = false;
	panel.searchInput.onEditCallback = (userData: *void, input: string) {
		panel := cast(*Panel) userData;
		
		array_reset_keeping_memory(*panel.results);
		panel.hasMatches = false;
		for cursor: panel.cursors {
			selectionEnd := shift_offset_line_endings(panel.document, max(cursor.head, cursor.anchor) + 1, .FORWARD);
			selectionRange := Document.Range.{min(cursor.head, cursor.anchor), selectionEnd};
			hasMatches, results := search(panel.document, panel_search_type(panel), selectionRange, input, stopAtFirstResult=false);
			
			panel.hasMatches |= hasMatches;
			
			start := selectionRange.start;
			for result: results {
				end := shift_offset_line_endings(panel.document, result.start, .REVERSE);
				if end > start then array_add(*panel.results, {start, end});
				start = shift_offset_line_endings(panel.document, result.end, .FORWARD);
			}
			if selectionEnd > start then array_add(*panel.results, {start, selectionEnd});
			
			
			array_free(results);
		}
	} ;
	panel.searchInput.userData = cast(*void) panel;
} @command

confirm_split_selection :: (using panel: *Panel, cursor: *Cursor) {
	SPLIT :: CommandConfig.{ prettyName = "Confirm split selection", keybinding = .["<enter>"] };
	if panel.hasMatches && panel.results.count > 0 {
		array_reset_keeping_memory(*panel.cursors);
		for panel.results {
			newCursor := array_add(*panel.cursors);
			newCursor.head = shift_offset_line_endings(document, it.end - 1, .REVERSE);
			newCursor.anchor = it.start;
		}
		panel.primaryCursor = 0;
	}
	
	panel_reset_dialogs(panel);
} @command

cancel_split_selection :: (using panel: *Panel) {
	input_field_reset_keeping_memory(*panel.searchInput);
	panel.searchInput.onEditCallback = null;
	panel.searchInput.userData = null;
	array_reset(*panel.results);
	panel.hasMatches = false;
}

// Normal Mode Changes
// ------------------------------

enter_normal_mode :: (panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Enter normal mode", keybinding = .["<escape>"] };
	INSERT :: CommandConfig.{ prettyName = "Enter normal mode", keybinding = .["<escape>"] };
	COMMAND_PALETTE :: CommandConfig.{ prettyName = "Enter normal mode", keybinding = .["<escape>"] };
	SEARCH :: CommandConfig.{ prettyName = "Enter normal mode", keybinding = .["<escape>"] };
	SELECT :: CommandConfig.{ prettyName = "Enter normal mode", keybinding = .["<escape>"] };
	SPLIT :: CommandConfig.{ prettyName = "Enter normal mode", keybinding = .["<escape>"] };
	panel_reset_dialogs(panel);

	// if we were in insert mode we must now end the edit
	if editorMode == .INSERT {
		// after appending, the head sits just past the inserted text. Step it back onto the last
		// inserted char, otherwise the selection takes in the next char, which may belong to another cursor
		for * c: panel.cursors {
			if c.head > c.anchor then c.head = shift_offset_line_endings(panel.document, c.head - 1, .REVERSE);
		}
		end_edit(panel.document, panel);
	}

	editorMode = .NORMAL;
} @command

enter_insert_mode_start :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Enter insert mode start of selection", keybinding = .["i"] };
	
	for * cursor: cursors {
		if cursor.head > cursor.anchor {
			temp := cursor.head;
			cursor.head = cursor.anchor;
			cursor.anchor = temp;
		}
	}
	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	begin_edit(document, panel);
} @command

enter_insert_mode_end :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Enter insert mode end of selection", keybinding = .["a"] };
	
	for * cursor: cursors {
		if cursor.head < cursor.anchor {
			temp := cursor.head;
			cursor.head = cursor.anchor;
			cursor.anchor = temp;
		}
		cursor.head = min(cursor.head + 1, get_size(document)-1);
		cursor.head = shift_offset_line_endings(document, cursor.head, .REVERSE);
	}
	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	begin_edit(document, panel);
} @command

enter_insert_mode_line_start :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Enter insert mode start of line", keybinding = .["I"] };

	// put the cursor on the first non whitespace character
	for * cursor: cursors {
		goto_line_start(panel, cursor);
		cursorChar := get_char_at(document, cursor.head);
		if is_space(cursorChar) {
			iterator := make_iterator(document, cursor.head);
			for iterator {
				cursor.head = iterator.offset;
				if !is_space(it) break;
			}
		}
		cursor.anchor = cursor.head;
	}

	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	begin_edit(document, panel);
} @command

enter_insert_mode_line_end :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Enter insert mode end of line", keybinding = .["A"] };
	
	for * cursor: cursors {
		goto_line_end(panel, cursor);
	}

	panel_reset_dialogs(panel);
	editorMode = .INSERT;
	begin_edit(document, panel);
} @command

select_register :: (using panel: *Panel, cursor: *Cursor, char: u8) { 
	NORMAL :: CommandConfig.{ prettyName = "Select register {char}", keybinding = .["\"{char}"] };
	registers.selectedRegister = char;
} @command

delete_cursor_range :: (doc: DocumentHandle, locationA: s64, locationB:s64) -> s64, s64 {
	start := min(locationA, locationB);
	end := max(locationA, locationB);

	startOffset := shift_offset_line_endings(doc, start, .REVERSE);
	endOffset := shift_offset_line_endings(doc, end + 1, .FORWARD);
	delete(doc, startOffset, endOffset-startOffset);
	return start, endOffset-startOffset;
}

// yanks every cursor's selection into the selected register, one value per cursor
yank_cursors_to_register :: (using panel: *Panel) {
	reg := register_begin_write(registers.selectedRegister);
	for cursor: cursors {
		register_add_document_range(reg, document, cursor.head, cursor.anchor);
	}

	// separates the values when they're joined for the OS clipboard
	separator := "\r\n";
	if document_get_line_endings(document) == .LF || document_get_line_endings(document) == .MIXED_MAJORITY_LF {
		separator = "\n";
	}
	register_end_write(registers.selectedRegister, separator);
}

delete_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Delete selection", keybinding = .["d"] };

	// copy the selections into a register before deleting them
	yank_cursors_to_register(panel);

	begin_edit(document, panel);
	defer end_edit(document, panel);
	
	for * cursor: cursors {
		deletedCount: s64;
		cursor.head, deletedCount = delete_cursor_range(document, cursor.head, cursor.anchor);
		cursor.anchor = cursor.head;
		
		update_other_cursors_after_edit(panel, cursor, cursor.head, -deletedCount);
	}
} @command

change_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Change selection", keybinding = .["c"] };
	
	enter_insert_mode_start(panel, cursor);
	yank_cursors_to_register(panel);

	for * cursor: cursors {
		rangeEnd := max(cursor.head, cursor.anchor);
		endChar := get_char_at(document, rangeEnd);
		linewiseChange := endChar == #char "\n" || endChar == #char "\r";
		
		indentation: string;
		if linewiseChange {
			lineNumber := get_coordinate_from_offset(document, min(cursor.head, cursor.anchor)).line;
			indentation = calculate_indentation_for_line(document, lineNumber);
		}
		
		deletedRange: s64;
		cursor.head, deletedRange = delete_cursor_range(document, cursor.head, cursor.anchor);
		cursor.anchor = cursor.head;
		
		update_other_cursors_after_edit(panel, cursor, cursor.head, -deletedRange);
		
		if linewiseChange {
			insert_mode_insert_string(indentation, cursor);
			
			// reinsert a line ending
			textToInsert := "\r\n";
			if document_get_line_endings(panel.document) == .LF || document_get_line_endings(panel.document) == .MIXED_MAJORITY_LF {
				textToInsert = "\n";
			}
			insert_mode_insert_string(textToInsert, cursor);
			cursor.head -= textToInsert.count;
			cursor.anchor -= textToInsert.count;
		}
	}
} @command

yank_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Yank selection", keybinding = .["y"] };
	yank_cursors_to_register(panel);
	if cursors.count > 1 {
		push_notification(tprint("Yanked % selections into register %", cursors.count, string.{1,*registers.selectedRegister}));
	}
	else {
		push_notification(tprint("Yanked into register %", string.{1,*registers.selectedRegister}));
	}
} @command

paste_after_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Paste after selection", keybinding = .["p"] };
	valuesToPaste := read_register(registers.selectedRegister);
	paste(panel, valuesToPaste, false);
} @command

paste_before_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Paste before selection", keybinding = .["P"] };
	valuesToPaste := read_register(registers.selectedRegister);
	paste(panel, valuesToPaste, true);
} @command

replace_selection :: (using panel: *Panel, cursor: *Cursor, char: u8) {
	NORMAL :: CommandConfig.{ prettyName = "Replace selection with {char}", keybinding = .["r{char}"] };
	
	begin_edit(document, panel);
	defer end_edit(document, panel);
	
	for * cursor: cursors {
		head := cursor.head;
		anchor := cursor.anchor;
		rangeLength := abs(cursor.head - cursor.anchor);
		
		deletedCount: s64;
		cursor.head, deletedCount = delete_cursor_range(document, cursor.head, cursor.anchor);
		cursor.anchor = cursor.head;
		
		update_other_cursors_after_edit(panel, cursor, cursor.head, -deletedCount);
		
		builder : String_Builder;
		builder.allocator = temp;
		init_string_builder(*builder);
		
		for 0..rangeLength {
			append(*builder, char);
		}
		
		stringToInsert := builder_to_string(*builder,,temp);
		insert(document, min(cursor.head, cursor.anchor), stringToInsert);
		update_other_cursors_after_edit(panel, cursor, min(cursor.head, cursor.anchor), stringToInsert.count);
		cursor.head = head;
		cursor.anchor = anchor;
	}
} @command

replace_selection_with_yanked :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Replace selection with yanked", keybinding = .["R"] };
	begin_edit(document, panel);

	linewisePaste := NewArray(cursors.count, bool,,temp);
	valuesToPaste := read_register(registers.selectedRegister);

	for * cursor: cursors {
		head := cursor.head;
		anchor := cursor.anchor;
		rangeLength := abs(cursor.head - cursor.anchor);

		deletedCount: s64;
		cursor.head, deletedCount = delete_cursor_range(document, cursor.head, cursor.anchor);
		cursor.anchor = cursor.head;

		textToPaste := register_value_for_cursor(valuesToPaste, it_index);

		for char, i: textToPaste {
			if char == #char "\n" {
				linewisePaste[it_index] = true;
				break;
			}
		}
		
		// insert into document
		insertLocation := max(cursor.head, cursor.anchor);
		insert(document, insertLocation, textToPaste);
		
		// normalize line endings from pasted content
		change := normalize_line_endings_common(document, document_get_line_endings(document), .{insertLocation, insertLocation + textToPaste.count});
		cursor.anchor = insertLocation;
		cursor.head = cursor.anchor + textToPaste.count - 1 + change;
		
		update_other_cursors_after_edit(panel, cursor, insertLocation, textToPaste.count + change - deletedCount);
	}
	end_edit(document, panel);

	autoindent_selection_helper(panel, linewisePaste);
} @command

paste :: (using panel: *Panel, valuesToPaste: []string, pasteBefore: bool) {
	begin_edit(document, panel);

	linewisePaste := NewArray(cursors.count, bool,,temp);

	for * cursor: cursors {
		textToPaste := register_value_for_cursor(valuesToPaste, it_index);
		for char, i: textToPaste {
			if char == #char "\n" {
				linewisePaste[it_index] = true;
				break;
			}
		}
		
		insertLocation := 0;
		if linewisePaste[it_index] && !pasteBefore {
			coordinate := get_coordinate_from_offset(document, cursor.head);
			_, insertLocation = get_line_range(document, coordinate.line, true);
			
			insert(document, insertLocation, textToPaste);
		}
		else if linewisePaste[it_index] && pasteBefore {
			coordinate := get_coordinate_from_offset(document, cursor.head);
			// todo: paste on the first line
			_, insertLocation = get_line_range(document, coordinate.line-1, true);
			insert(document, insertLocation, textToPaste);
		}
		else if !linewisePaste[it_index] && !pasteBefore {
			insertLocation = max(cursor.head, cursor.anchor) + 1;
			insertLocation = shift_offset_line_endings(document, insertLocation, .REVERSE);
			insert(document, insertLocation, textToPaste);
		}
		else if !linewisePaste[it_index] && pasteBefore {
			insertLocation = min(cursor.head, cursor.anchor);
			insertLocation = shift_offset_line_endings(document, insertLocation, .REVERSE);
			insert(document, insertLocation, textToPaste);
		}
		
		change := normalize_line_endings_common(document, document_get_line_endings(document), .{insertLocation, insertLocation + textToPaste.count});
		cursor.anchor = shift_offset_line_endings(document, insertLocation, .FORWARD);
		cursor.head = shift_offset_line_endings(document, insertLocation + textToPaste.count - 1 + change, .REVERSE);
		
		update_other_cursors_after_edit(panel, cursor, insertLocation, textToPaste.count + change);
	}
	end_edit(document, panel);
	
	autoindent_selection_helper(panel, linewisePaste);
}

new_line_below :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "New line below selection", keybinding = .["o"] };
	
	for * cursor: cursors {
		if cursor.head < cursor.anchor then flip_selection(panel, cursor);
		goto_line_end(panel, cursor);
	}
	
	enter_insert_mode_start(panel, _cursor);
	
	for * cursor: cursors {
		textToInsert := "\r\n";
		if document_get_line_endings(panel.document) == .LF || document_get_line_endings(panel.document) == .MIXED_MAJORITY_LF {
			textToInsert = "\n";
		}
		insert_mode_insert_string(textToInsert, cursor);
		
		indentation := calculate_indentation_for_line(document, get_coordinate_from_offset(document, cursor.head).line);
		insert_mode_insert_string(indentation, cursor);
	}
} @command

new_line_above :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "New line above selection", keybinding = .["O"] };
	
	for * cursor: cursors {
		if cursor.head > cursor.anchor then flip_selection(panel, cursor);
		goto_line_start(panel, cursor);
		cursor.anchor = cursor.head;
	}
	
	enter_insert_mode_start(panel, _cursor);
	
	for * cursor: cursors {
		textToInsert := "\r\n";
		if document_get_line_endings(panel.document) == .LF || document_get_line_endings(panel.document) == .MIXED_MAJORITY_LF {
			textToInsert = "\n";
		}
		insert_mode_insert_string(textToInsert, cursor);
		
		if document_get_line_endings(panel.document) == .LF || document_get_line_endings(panel.document) == .MIXED_MAJORITY_LF {
			cursor.head -= 1;
		}
		else {
			cursor.head -= 2;
		}
		
		indentation := calculate_indentation_for_line(document, get_coordinate_from_offset(document, cursor.head).line);
		insert_mode_insert_string(indentation, cursor);
		
		cursor.anchor = cursor.head;
	}
} @command

join_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Join selection", keybinding = .["alt+j"] };
	begin_edit(document, panel);
	defer end_edit(document, panel);
	
	// Loop the cursors manually so the whole thing is treated as one edit
	for * cursor: cursors {
		// What should happen here? 
		headCoord := get_coordinate_from_offset(document, cursor.head);
		anchorCoord := get_coordinate_from_offset(document, cursor.anchor);
		
		startLine := min(headCoord.line, anchorCoord.line);
		endLine := max(headCoord.line, anchorCoord.line);
		
		delta := 0;
		for 1..max(1,endLine-startLine) {
			// we deal with the start line every time, cause each iteration removes one of the lines below
			nextLine := get_line_content(document, startLine+1, true,,temp);
			lineTrimmed := trim_left(nextLine.text);
			bytesToRemove := nextLine.text.count - lineTrimmed.count;
			deletionStart := nextLine.startByteOffset;
			
			
			while true {
				char := get_char_at(document, deletionStart-1);
				if char == #char "\n" || char == #char "\r" {
					bytesToRemove += 1;
					deletionStart -= 1;
					continue;
				}
				break;
			}
			delete(document, deletionStart, bytesToRemove);
			insert(document, deletionStart, " ");
			delta -= bytesToRemove - 1;
			
			update_other_cursors_after_edit(panel, cursor, deletionStart, -(bytesToRemove - 1));
		}
		
		if cursor.head < cursor.anchor {
			cursor.anchor = cursor.anchor+delta;
		}
		else if cursor.head > cursor.anchor {
			cursor.head = cursor.head+delta;
		}
	}
} @command

// TODO: should be defined alongside the language
commentString :: "// ";

toggle_comment :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Toggle comment", keybinding = .["<space>c"] };
	begin_edit(document, panel);
	defer end_edit(document, panel);
	
	coords:= NewArray(cursors.count, CursorCoordinates,,temp);
	
	for * cursor: cursors {
		coords[it_index].head = get_coordinate_from_offset(document, cursor.head);
		coords[it_index].anchor = get_coordinate_from_offset(document, cursor.anchor);
	}
	
	lineDeltas: Table(s64, s64);
	lineDeltas.allocator = temp;
	for c: coords {
		startLine := min(c.head.line, c.anchor.line);
		endLine := max(c.head.line, c.anchor.line);
		
		// first we need to work out if we want to comment this block of lines
		// or uncomment it
		// so we're gonna search every line to find out
		
		toggleComment := false;
		for startLine..endLine {
			line := get_line_content(document, it,,temp);
			
			lineTrimmed := trim_left(line.text);
			if !begins_with(lineTrimmed, commentString) {
				toggleComment = true;
				break;
			}
		}
		
		// add comment strings
		offset := 0;
		for lineNumber: startLine..endLine {
			line := get_line_content(document, lineNumber,,temp);
			firstNonBlankChar := 0;
			for character: line.text {
				if !is_space(character) {
					firstNonBlankChar = it_index;
					break;
				}
			}
			
			if table_contains(*lineDeltas, lineNumber) then continue;
			if toggleComment {
				insert(document, line.startByteOffset + firstNonBlankChar, commentString);
				table_set(*lineDeltas, lineNumber, 3);
			}
			else {
				delete(document, line.startByteOffset + firstNonBlankChar, commentString.count);
				table_set(*lineDeltas, lineNumber, -3);
			}
		}
	}
	
	// shift the cursors along
	for * cursor: cursors {
		c := coords[it_index];
		headDelta := table_find_pointer(*lineDeltas, c.head.line).*;
		anchorDelta := table_find_pointer(*lineDeltas, c.anchor.line).*;
		cursor.head = cursor_offset_after_line_indent_change(document, c.head, headDelta);
		cursor.anchor = cursor_offset_after_line_indent_change(document, c.anchor, anchorDelta);
	}
} @command
	
// returns the change in byte length of the line
replace_indentation_for_line :: (doc: DocumentHandle, lineNumber: s64) -> s64 {
	indentation := calculate_indentation_for_line(doc, lineNumber);
	lineContent := get_line_content(doc, lineNumber,,temp);

	// delete any existing indentation
	deleteUpTo := -1;
	for lineContent.text {
		if it != #char "\t" && it != #char " " {
			existingIndentation := slice(lineContent.text, 0, it_index);
			if existingIndentation == indentation {
				return 0;
			}
			deleteUpTo = it_index;
			delete(doc, lineContent.startByteOffset, it_index);
			break;
		}
	}

	// line is either blank or empty
	if deleteUpTo < 0 {
		if lineContent.text == indentation {
			return 0;
		}
		deleteUpTo = lineContent.text.count;
		delete(doc, lineContent.startByteOffset, lineContent.text.count);
	}

	insert(doc, lineContent.startByteOffset, indentation);

	return indentation.count - deleteUpTo;
}

cursor_offset_after_line_indent_change :: (doc: DocumentHandle, coord: Document.Coordinate, delta: s64) -> s64 {
	return get_offset_from_coordinate(doc, .{coord.line, max(0, coord.col + delta)});
}

autoindent_selection_helper :: (using panel: *Panel, cursorsToInclude: []bool) {
	if !document_supports_treesitter(document) return;
	
	// TODO: allow setting tabs or spaces, and tab width
	begin_edit(document, panel);
	defer end_edit(document, panel);
	
	coords:= NewArray(cursors.count, CursorCoordinates,,temp);
	
	for * cursor: cursors {
		coords[it_index].head = get_coordinate_from_offset(document, cursor.head);
		coords[it_index].anchor = get_coordinate_from_offset(document, cursor.anchor);
	}
	
	lineDeltas: Table(s64, s64);
	lineDeltas.allocator = temp;
	for c: coords {
		if cursorsToInclude[it_index] == false continue;
		
		startLine := min(c.head.line, c.anchor.line);
		endLine := max(c.head.line, c.anchor.line);
		for lineNumber: startLine..endLine {
			if table_contains(*lineDeltas, lineNumber) then continue;
			delta := replace_indentation_for_line(document, lineNumber);
			table_set(*lineDeltas, lineNumber, delta);
		}
	}
	
	for * cursor: cursors {
		c := coords[it_index];
		_, headDelta := table_find(*lineDeltas, c.head.line);
		_, anchorDelta := table_find(*lineDeltas, c.anchor.line);
		cursor.head = cursor_offset_after_line_indent_change(document, c.head, headDelta);
		cursor.anchor = cursor_offset_after_line_indent_change(document, c.anchor, anchorDelta);
	}
}

autoindent_selection :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Autoindent selection", keybinding = .["="] };
	// We need the ability to autoindent specific cursors out of the set of all of them
	// So we have this little helper here, apologies for the indirection
	include := NewArray(cursors.count, bool,,temp);
	for cursors { include[it_index] = true; }
	autoindent_selection_helper(panel, include);
} @command

indent_line :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Indent line", keybinding = .[">"] };
	begin_edit(document, panel);
	defer end_edit(document, panel);
	
	coords:= NewArray(cursors.count, CursorCoordinates,,temp);
	
	for * cursor: cursors {
		coords[it_index].head = get_coordinate_from_offset(document, cursor.head);
		coords[it_index].anchor = get_coordinate_from_offset(document, cursor.anchor);
	}
	
	lineDeltas: Table(s64, s64);
	lineDeltas.allocator = temp;
	for c: coords {
		startLine := min(c.head.line, c.anchor.line);
		endLine := max(c.head.line, c.anchor.line);
		for lineNumber: startLine..endLine {
			if table_contains(*lineDeltas, lineNumber) then continue;
			lineStartOffset := get_line_start(document, lineNumber);
			insert(document, lineStartOffset, "\t");
			table_set(*lineDeltas, lineNumber, 1);
		}
	}
	
	for * cursor: cursors {
		c := coords[it_index];
		headDelta := table_find_pointer(*lineDeltas, c.head.line).*;
		anchorDelta := table_find_pointer(*lineDeltas, c.anchor.line).*;
		cursor.head = cursor_offset_after_line_indent_change(document, c.head, headDelta);
		cursor.anchor = cursor_offset_after_line_indent_change(document, c.anchor, anchorDelta);
	}
} @command

unindent_line :: (using panel: *Panel, _cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Unindent line", keybinding = .["<"] };
	begin_edit(document, panel);
	defer end_edit(document, panel);

	// delete the start char for every line, assuming it is a tab of course
	
	coords:= NewArray(cursors.count, CursorCoordinates,,temp);
	
	for * cursor: cursors {
		coords[it_index].head = get_coordinate_from_offset(document, cursor.head);
		coords[it_index].anchor = get_coordinate_from_offset(document, cursor.anchor);
	}
	
	lineDeltas: Table(s64, s64);
	lineDeltas.allocator = temp;
	for c: coords {
		startLine := min(c.head.line, c.anchor.line);
		endLine := max(c.head.line, c.anchor.line);
		for lineNumber: startLine..endLine {
			if table_contains(*lineDeltas, lineNumber) then continue;
			lineStartOffset := get_line_start(document, lineNumber);
			delta := 0;
			if get_char_at(document, lineStartOffset) == #char "\t" {
				delete(document, lineStartOffset, 1);
				delta = -1;
			}
			table_set(*lineDeltas, lineNumber, delta);
		}
	}
	
	for * cursor: cursors {
		c := coords[it_index];
		headDelta := table_find_pointer(*lineDeltas, c.head.line).*;
		anchorDelta := table_find_pointer(*lineDeltas, c.anchor.line).*;
		cursor.head = cursor_offset_after_line_indent_change(document, c.head, headDelta);
		cursor.anchor = cursor_offset_after_line_indent_change(document, c.anchor, anchorDelta);
	}
} @command

undo :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Undo", keybinding = .["u"] };
	panel_restore_selection(panel, undo(document));
} @command

redo :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Redo", keybinding = .["U"] };
	panel_restore_selection(panel, redo(document));
} @command




// File Search Commands
// --------------------------------

start_document_search :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Search Document", keybinding = .["/"] };
	// show search bar
	editorMode = .SEARCH;
	// results may be left over from n/N, don't let them be confirmed or drawn
	array_reset(*panel.results);
	panel.hasMatches = false;
	write_register("/", "");
	panel.searchInput.onEditCallback = document_search_on_edit;
	panel.searchInput.userData = cast(*void) panel;
	panel.previousScrollLine = panel_get_current_scrolled_line(panel);
} @command

confirm_document_search :: (using panel: *Panel, cursor: *Cursor) {
	SEARCH :: CommandConfig.{ prettyName = "Confirm document search", keybinding = .["<enter>"] };
	// set real cursor to the match that was found, setup stepping
	if panel.hasMatches {
		cursor.anchor = panel.results[0].start;
		cursor.head = panel.results[0].end-1;
		keep_primary_selection(panel, cursor);
	}
	write_register("/", .{panel.searchInput.text.count, panel.searchInput.text.data});
	panel.previousScrollLine = panel_get_current_scrolled_line(panel);
	panel_reset_dialogs(panel);
} @command

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

next_search_result :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Next search result", keybinding = .["n"] };
	
	array_reset(*panel.results);
	panel.hasMatches = false;

	searchTerm := register_value_for_cursor(read_register("/"), 0);
	searchStart := shift_offset_line_endings(panel.document, max(cursor.head, cursor.anchor) + 1, .FORWARD);
	panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{searchStart, get_size(panel.document)}, searchTerm);

	// wrap around to the start if you didn't initially find anything
	if !panel.hasMatches {
		panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{0, get_size(panel.document)}, searchTerm);
	}

	if panel.hasMatches {
		cursor.anchor = panel.results[0].start;
		cursor.head = panel.results[0].end-1;
		
		keep_primary_selection(panel, cursor);

		matchLine := get_coordinate_from_offset(panel.document, panel.results[0].start).line;
		startVisibleLine, pageSize := panel_calculate_visible_lines(panel);
		if matchLine < startVisibleLine || matchLine >= (startVisibleLine+pageSize) {
			panel_scroll_to_line(panel, matchLine - pageSize/2);
		}
	}
} @command

add_selection_with_next_search_result :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Add selection with next search result", keybinding = .["N"] };
	
	array_reset(*panel.results);
	panel.hasMatches = false;
	
	searchTerm := register_value_for_cursor(read_register("/"), 0);
	searchStart := shift_offset_line_endings(panel.document, max(cursor.head, cursor.anchor) + 1, .FORWARD);
	panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{searchStart, get_size(panel.document)}, searchTerm);
	
	// wrap around to the start if you didn't initially find anything
	if !panel.hasMatches {
		panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{0, get_size(panel.document)}, searchTerm);
	}
	
	if panel.hasMatches {
		newCursor := array_add(*panel.cursors);
		newCursor.head = panel.results[0].end-1;
		newCursor.anchor = panel.results[0].start;
		primaryCursor = panel.cursors.count-1; // New cursor will be primary so we move along
	}
} @command

previous_search_result :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Previous search result", keybinding = .["alt+n"] };
	array_reset(*panel.results);
	panel.hasMatches = false;

	searchTerm := register_value_for_cursor(read_register("/"), 0);
	panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{0, get_size(panel.document)}, searchTerm, stopAtFirstResult=false);

	if panel.hasMatches {
		// you want to find the result whos range is just before the cursor's offset
		bestMatch := -1;
		cursorOffset := min(cursor.head, cursor.anchor);
		for result: panel.results {
			if result.start >= cursorOffset then break;
			bestMatch = it_index;
		}

		// wrap around if nothing found behind cursor
		if bestMatch < 0 {
			bestMatch = panel.results.count-1;
		}

		cursor.anchor = panel.results[bestMatch].start;
		cursor.head = panel.results[bestMatch].end-1;
		
		keep_primary_selection(panel, cursor);

		matchLine := get_coordinate_from_offset(panel.document, panel.results[bestMatch].start).line;
		startVisibleLine, pageSize := panel_calculate_visible_lines(panel);
		if matchLine < startVisibleLine || matchLine >= (startVisibleLine+pageSize) {
			panel_scroll_to_line(panel, matchLine - pageSize/2);
		}
	}
} @command

add_selection_with_previous_search_result :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Add selection with previous search result", keybinding = .["alt+shift+n"] };
	array_reset(*panel.results);
	panel.hasMatches = false;
	
	searchTerm := register_value_for_cursor(read_register("/"), 0);
	panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{0, get_size(panel.document)}, searchTerm, stopAtFirstResult=false);
	
	if panel.hasMatches {
		// you want to find the result whos range is just before the cursor's offset
		bestMatch := -1;
		cursorOffset := min(cursor.head, cursor.anchor);
		for result: panel.results {
			if result.start >= cursorOffset then break;
			bestMatch = it_index;
		}
		
		// wrap around if nothing found behind cursor
		if bestMatch < 0 {
			bestMatch = panel.results.count-1;
		}
		
		newCursor := array_add(*panel.cursors);
		newCursor.head = panel.results[bestMatch].end-1;
		newCursor.anchor = panel.results[bestMatch].start;
		primaryCursor = panel.cursors.count-1; // New cursor will be primary so we move along
	}
} @command

search_selection :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Search selection", keybinding = .["*"] };

	// the search register only holds one search term, so this uses the primary selection
	reg := register_begin_write("/");
	register_add_document_range(reg, document, cursor.head, cursor.anchor);
	register_end_write("/");
	push_notification("Selection copied to search register");
} @command

document_search_on_edit :: (userData: *void, input: string) {
	panel := cast(*Panel) userData;
	array_reset(*panel.results);
	panel.hasMatches = false;

	start := max(panel_get_primary_cursor(panel).head, panel_get_primary_cursor(panel).anchor);
	panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{start, get_size(panel.document)}, input);

	// we do another search if we found nothing to wrap from the start
	if panel.hasMatches == false && start > 0 {
		panel.hasMatches, panel.results = search(panel.document, panel_search_type(panel), .{0, get_size(panel.document)}, input);
	}

	// is the result off the edge of the screen? if so scroll so it's centered
	if panel.hasMatches {
		matchLine := get_coordinate_from_offset(panel.document, panel.results[0].start).line;
		startVisibleLine, pageSize := panel_calculate_visible_lines(panel);
		if matchLine < startVisibleLine || matchLine >= (startVisibleLine+pageSize) {
			panel_scroll_to_line(panel, matchLine - pageSize/2); 
		}
	}
}

jump_to_last_open_document :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Jump to last open document", keybinding = .["gp"] };
	panel_set_active_document(panel, panel.previousDocument);
} @command

// Insert Mode
// -----------------------------

insert_mode_insert_string :: (input: string, cursor: *Cursor) {
	// do the insert
	insertLocation := cursor.head;
	distanceToAnchor := cursor.anchor - cursor.head;
	insert(focusedPanel.document, cursor.head, input);

	// move the cursor along
	cursor.head += input.count;

	// update the anchor
	if distanceToAnchor > 0 {
		// anchor is ahead, we want to move it same as the head
		cursor.anchor += input.count;
	}
	else if distanceToAnchor == 0 {
		cursor.anchor = cursor.head;
	}

	update_other_cursors_after_edit(*focusedPanel, cursor, insertLocation, input.count);
	
	// If the last thing you typed likely closed an indentation region, reindent the line
	// We could do this by looking at the indent table of the document, but I don't want to have to regenerate that on every single
	// keypress, so for now we'll just guess
	delta := 0;
	if document_supports_treesitter(focusedPanel.document) && (input == "}" || input == ")" || input == "]") {
		headCoord := get_coordinate_from_offset(focusedPanel.document, cursor.head);
		anchorCoord := get_coordinate_from_offset(focusedPanel.document, cursor.anchor);
		
		delta = replace_indentation_for_line(focusedPanel.document, headCoord.line);

		cursor.head = cursor_offset_after_line_indent_change(focusedPanel.document, headCoord, delta);
		cursor.anchor = cursor_offset_after_line_indent_change(focusedPanel.document, anchorCoord, delta);
		
		if delta != 0 {
			lineStart := get_line_start(focusedPanel.document, headCoord.line);
			update_other_cursors_after_edit(*focusedPanel, cursor, lineStart, delta);
		}
	}
		
}

update_other_cursors_after_edit :: (using panel: *Panel, cursor: *Cursor, editLocation: s64, change: s64) {
	
	adjust :: (offset: s64, editLocation: s64, change: s64) -> s64 {
		// edit was an insert
		if change >= 0 {
			if offset >= editLocation {
				return offset + change;
			}
			return offset;
		}
		// edit was a deletion
		else {
			if offset >= (editLocation - change) {
				return offset + change;
			}
			else if offset > editLocation {
				return editLocation;
			}
			return offset;
		}
	}
	for * otherCursor: panel.cursors {
		if otherCursor == cursor continue;
		
		otherCursor.anchor = adjust(otherCursor.anchor, editLocation, change);
		otherCursor.head = adjust(otherCursor.head, editLocation, change);
	}
}

insert_mode_handle_text_input :: (char: Utf8_Char) {
	textToInsert := to_string(*char);
	for * cursor: focusedPanel.cursors {
		insert_mode_insert_string(textToInsert, cursor);
	}
}

insert_mode_line_break :: (using panel: *Panel, cursor: *Cursor) {
	INSERT :: CommandConfig.{ prettyName = "Insert line break", keybinding = .["<enter>"], flags = .PER_CURSOR };
	textToInsert := "\r\n";
	if document_get_line_endings(panel.document) == .LF || document_get_line_endings(panel.document) == .MIXED_MAJORITY_LF {
		textToInsert = "\n";
	}
	insert_mode_insert_string(textToInsert, cursor);
	
	cursorLine := get_coordinate_from_offset(document, cursor.head).line;
	indentation := calculate_indentation_for_line(document, cursorLine);
	
	// delete any existing whitespace on the newline before inserting the indentation
	line := get_line_content(document, cursorLine,,temp);
	trimmed := trim_left(line.text);
	delete(document, line.startByteOffset, line.text.count - trimmed.count);
	update_other_cursors_after_edit(panel, cursor, line.startByteOffset, -(line.text.count - trimmed.count));
	
	insert_mode_insert_string(indentation, cursor);
} @command

insert_tab_character :: (using panel: *Panel, cursor: *Cursor) {
	INSERT :: CommandConfig.{ prettyName = "Insert tab", keybinding = .["<tab>"], flags = .PER_CURSOR };
	textToInsert := "\t";
	insert_mode_insert_string(textToInsert, cursor);
} @command

insert_mode_backward_delete_char :: (using panel: *Panel, cursor: *Cursor) {
	INSERT :: CommandConfig.{ prettyName = "Backward delete char", keybinding = .["<backspace>"], flags = .PER_CURSOR };
	distanceToAnchor := cursor.anchor - cursor.head;

	startOffset := shift_offset_line_endings(document, cursor.head - 1, .REVERSE);
	endOffset := shift_offset_line_endings(document, cursor.head, .FORWARD);
	change := endOffset-startOffset;
	if startOffset < 0 return; 

	delete(document, startOffset, change);
	cursor.head -= change;

	// update the anchor
	if distanceToAnchor > 0 {
		// anchor is ahead, we want to move it same as the head
		cursor.anchor -= change;
	}
	else if distanceToAnchor == 0 {
		cursor.anchor = cursor.head;
	}
	
	update_other_cursors_after_edit(panel, cursor, startOffset, -change);
} @command

insert_mode_forward_delete_char :: (using panel: *Panel, cursor: *Cursor) {
	INSERT :: CommandConfig.{ prettyName = "Forward delete char", keybinding = .["<delete>"], flags = .PER_CURSOR };
	distanceToAnchor := cursor.anchor - cursor.head;

	startOffset := shift_offset_line_endings(document, cursor.head, .REVERSE);
	endOffset := shift_offset_line_endings(document, cursor.head + 1, .FORWARD);
	change := endOffset-startOffset;
	delete(document, startOffset, change);

	// update the anchor
	if distanceToAnchor > 0 {
		// anchor is ahead, we want to move it same as the head
		cursor.anchor -= change;
	}
	else if distanceToAnchor == 0 {
		cursor.anchor = cursor.head;
	}
	
	update_other_cursors_after_edit(panel, cursor, startOffset, -change);
} @command


// View Commands
// ------------------------------

// Moves every cursor by the same number of lines so they stay positioned relative to each other,
// then scrolls the view by the same amount to keep the primary cursor in the same place on screen
move_cursors_by_lines_and_scroll :: (using panel: *Panel, lineDelta: s64) {
	startVisibleLine := panel_calculate_visible_lines(panel, true);
	numLinesDocument := get_number_of_lines(panel.document);

	for * cursor: panel.cursors {
		cursorCoordinate := get_coordinate_from_offset(panel.document, cursor.head);
		move_cursor_to_specific_line(panel, cursor, clamp(cursorCoordinate.line + lineDelta, 0, numLinesDocument - 1));
		cursor.anchor = cursor.head;
	}

	panel_scroll_to_line(panel, startVisibleLine + lineDelta);
}

page_up :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Page up", keybinding = .["ctrl+b", "<pageup>"] };
	INSERT :: CommandConfig.{ prettyName = "Page up", keybinding = .["<pageup>"] };
	_, pageSize := panel_calculate_visible_lines(panel, true);
	move_cursors_by_lines_and_scroll(panel, -pageSize);
} @command

page_down :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Page down", keybinding = .["ctrl+f", "<pagedown>"] };
	INSERT :: CommandConfig.{ prettyName = "Page down", keybinding = .["<pagedown>"] };
	_, pageSize := panel_calculate_visible_lines(panel, true);
	move_cursors_by_lines_and_scroll(panel, pageSize);
} @command

half_page_up :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Half page up", keybinding = .["ctrl+u"] };
	_, pageSize := panel_calculate_visible_lines(panel, true);
	move_cursors_by_lines_and_scroll(panel, -pageSize/2);
} @command

half_page_down :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Half page down", keybinding = .["ctrl+d"] };
	_, pageSize := panel_calculate_visible_lines(panel, true);
	move_cursors_by_lines_and_scroll(panel, pageSize/2);
} @command


// Dialog Commands
// -----------------------------

search_input_backward_delete :: (using panel: *Panel, cursor: *Cursor) {
	SEARCH :: CommandConfig.{ prettyName = "Search backward delete", keybinding = .["<backspace>"] };
	SELECT :: CommandConfig.{ prettyName = "Search backward delete", keybinding = .["<backspace>"] };
	SPLIT :: CommandConfig.{ prettyName = "Search backward delete", keybinding = .["<backspace>"] };
	input_field_backward_delete(*searchInput);
} @command

// text input in any of the dialog modes goes to that dialog's input field
dialog_handle_text_input :: (panel: *Panel, char: Utf8_Char) {
	inputField := panel_get_dialog_input_field(panel);
	if inputField == null then return;

	// control characters (ctrl+backspace sends 0x7f for instance) are not text
	if char.count == 1 && (char.bytes[0] < 0x20 || char.bytes[0] == 0x7f) then return;

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

quit :: (panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Quit", keybinding = .["Q"] };
	pendingQuit = true;
} @command

open_file :: (panel: *Panel, cursor: *Cursor, file: SystemPath) {
	NORMAL :: CommandConfig.{ prettyName = "Open file", keybinding = .["<space>O"] };
	open_path(panel, file.base);
} @command

open_file_in_working_dir :: (panel: *Panel, cursor: *Cursor, file: WorkingDirPath) {
	NORMAL :: CommandConfig.{ prettyName = "Open file at working directory" };
	open_path(panel, file.base);
} @command

open_file_in_project :: (panel: *Panel, cursor: *Cursor, file: ProjectPath) {
	NORMAL :: CommandConfig.{ prettyName = "Open file in project", keybinding = .["<space>o"] };
	open_path(panel, file.base);
} @command

open_path :: (panel: *Panel, file: FilePath) {
	// a file that doesn't exist yet gets an empty document, it lands on disk when you save it
	doc := document_get_or_open(file.path, allowMissing = !file.exists);
	panel_set_active_document(panel, doc);
}

find_file :: (panel: *Panel, cursor: *Cursor, file: FinderFile) {
	NORMAL :: CommandConfig.{ prettyName = "Find file", keybinding = .["<space>f"] };
	if file.isDocument {
		panel_set_active_document(panel, file.documentHandle);
	}
	else {
		// the list was built when the dialog opened, so the file may have been deleted since
		projectFile := bucket_array_find_or_null(*project.projectFiles, file.projectHandle);
		if projectFile == null || projectFile.tombstoned {
			push_notification("File Does Not Exist");
			return;
		}
		doc := document_get_or_open(projectFile.fullName, noLoad = true);
		document_load_from_project(doc, projectFile);
		panel_set_active_document(panel, doc);
	}
} @command

find_in_files :: (panel: *Panel, cursor: *Cursor, result: FindInFiles) {
	NORMAL :: CommandConfig.{ prettyName = "Find in files", keybinding = .["<space>s"] };
	if result.isDocument {
		panel_set_active_document(panel, result.documentHandle);
	}
	else {
		// the list was built when the dialog opened, so the file may have been deleted since
		projectFile := bucket_array_find_or_null(*project.projectFiles, result.projectHandle);
		if projectFile == null || projectFile.tombstoned {
			push_notification("File Does Not Exist");
			return;
		}
		doc := document_get_or_open(projectFile.fullName, noLoad = true);
		document_load_from_project(doc, projectFile);
		panel_set_active_document(panel, doc);
	}
	
	keep_primary_selection(panel, panel_get_primary_cursor(panel));
	primary := panel_get_primary_cursor(panel);
	primary.head = result.lineOffset + result.matchRange.end;
	primary.anchor = result.lineOffset + result.matchRange.start;
	
	// force set the initial scroll such that the result is in the center of the view
	startVisibleLine, range := panel_calculate_visible_lines(panel);
	panel_scroll_to_line(panel, result.lineNum-range/2);
} @command

save_file :: (panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Save file", keybinding = .["ctrl+s"] };
	document_save(panel.document, document_get_path(panel.document));
} @command

save_file_as :: (panel: *Panel, cursor: *Cursor, file: DocumentDirPath) {
	NORMAL :: CommandConfig.{ prettyName = "Save file as", keybinding = .["ctrl+shift+s"] };
	document_save(panel.document, file.path);
} @command

p4_checkout_file :: (panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "P4 checkout file", keybinding = .[] };
	
	p4_checkout_task :: (data: *void) {
		doc := cast(*DocumentHandle, data);
		result, output, error := run_command("p4", "edit", document_get_path(doc), capture_and_return_output=true);
		log("%", output);
	}
	push_task(*asyncWorker, *panel.document, p4_checkout_task, null);
} @command

print_piece_chain_debug :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Print piece chain debug" };
	log("Tree Nodes: ");
	document_debug_print_tree(document);
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
} @command

print_highlight_debug :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Print highlight debug" };
	queuePrintHighlightDebug = true;
} @command

reparse_syntax :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Reparse syntax tree" };
	document_reparse_ts_tree(document, false);
} @command

visualize_undos :: (using panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Visualize Undos" };
	// document_debug_print_undos(document);
} @command

toggle_render_line_endings :: (panel: *Panel, cursor: *Cursor) {
	NORMAL :: CommandConfig.{ prettyName = "Toggle render line endings" };
	fontCode.drawLineEndings = !fontCode.drawLineEndings;
} @command

normalize_line_endings_common :: (document: DocumentHandle, targetEndings: Document.LineEndingMode, range: Document.Range) -> s64 {
	// this function needs to peak ahead, which requires it to binary query the tree for every single character checked
	// probably can make it faster, but it's fine for now
	// you could take the strategy of going line by line, rather than char by char
	
	iterator := make_iterator(document, range.start);
	end := range.end;
	if targetEndings == .LF {
		for :raw_bytes iterator {
			if it == #char "\r" && get_char_at(document, iterator.offset+1) == #char "\n" {
				delete(document, iterator.offset, 2);
				insert(document, iterator.offset, "\n");
				iterator.offset -= 1;
				end -= 1;
			}
			if iterator.offset == end then break;
		}
		document_set_line_endings(document, .LF);
	}
	else if targetEndings == .CRLF {
		for :raw_bytes iterator {
			if it != #char "\r" && get_char_at(document, iterator.offset+1) == #char "\n" {
				// this is done in two steps to ensure \r\n do not cross node boundaries in the piece tree
				delete(document, iterator.offset+1, 1);
				insert(document, iterator.offset+1, "\r\n");
				iterator.offset += 1;
				end += 1;
			}
			if iterator.offset == end then break;
		}
		document_set_line_endings(document, .CRLF);
	}

	return end - range.end;
}

NormalizedLineEndings :: enum {
	CRLF;
	LF;
}

normalize_line_endings :: (using panel: *Panel, cursor: *Cursor, endings: NormalizedLineEndings) {
	NORMAL :: CommandConfig.{ prettyName = "Normalize line endings" };
	begin_edit(document, panel);
	
	if endings == {
	case .CRLF;
		normalize_line_endings_common(document, .CRLF, .{0, S64_MAX});
	case .LF;
		normalize_line_endings_common(document, .LF, .{0, S64_MAX});
	}
	
	end_edit(document, panel);
} @command

