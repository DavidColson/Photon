
KeyMappingDesc :: struct {
	keys: string = "";
}

CommandFlags :: enum_flags u8 {
	HIDDEN;
	REPEATABLE;
	EXTEND;
}

Command :: struct {
	name: string;
	mappings: []string;
	flags: CommandFlags;
	execute: (*Panel, []string);
}

KeyMap :: struct {
	memory : Flat_Pool;
	allocator: Allocator;
	root: [EDITOR_MODE_NUM]KeyMapNode;
	pendingKeyNode: *KeyMapNode;
	pendingKeyString: [..]u8;
	pendingArgs: [..]string;
	pendingCount: s32;
	textInputCount: u16;
}

KeyMapNode :: struct {
	children: *Table(string, *KeyMapNode); // null if leaf node
	cmd: *Command;
	nArgs: s32;
}

// global keymap
keyMap: KeyMap;

// keymapping syntax
// special keys will be <backspace>, <esc> etc
// modifiers will be ctrl+b, W, alt+g, ctrl+<tab>a
// for shift you can do shift+b or B, but if you use ctrl or alt, then you can't use a capital
// because of how text input works :(
// @todo: consider making certain commands only available in certain modes
// such as command picker and filesystem nav commands. They won't show up in the command picker
// if they can't be selected, filter them out when doing fuzzy filtering

normalModeCommands :: Command.[
	.{ "Quit", .["Q"], 0, quit },
	.{ "Save File", .["ctrl+s"], 0, save_file },
	.{ "Save File As", .["ctrl+shift+s"], 0, save_file_as },

	// movements
	.{ "Move one char left", .["h", "<left>"], .REPEATABLE, move_one_char_left },
	.{ "Move one char right", .["l", "<right>"], .REPEATABLE, move_one_char_right },
	.{ "Move one line down", .["j", "<down>"], .REPEATABLE, move_one_line_down },
	.{ "Move one line up", .["k", "<up>"], .REPEATABLE, move_one_line_up },
	.{ "Extend one char left", .["H"], .REPEATABLE | .EXTEND, move_one_char_left },
	.{ "Extend one char right", .["L"], .REPEATABLE | .EXTEND, move_one_char_right },
	.{ "Extend one line down", .["J"], .REPEATABLE | .EXTEND, move_one_line_down },
	.{ "Extend one line up", .["K"], .REPEATABLE | .EXTEND, move_one_line_up },

	.{ "Goto document start", .["gk"], 0, goto_document_start },
	.{ "Goto document end", .["gj"], 0, goto_document_end },
	.{ "Goto line start", .["gh"], 0, goto_line_start },
	.{ "Goto line end", .["gl"], 0, goto_line_end },
	.{ "Extend to document start", .["Gk"], .EXTEND, goto_document_start },
	.{ "Extend to document end", .["Gj"], .EXTEND, goto_document_end },
	.{ "Extend to line start", .["Gh", "alt+h"], .EXTEND, goto_line_start },
	.{ "Extend to line end", .["Gl", "alt+l"], .EXTEND, goto_line_end },

	.{ "Move to next word start", .["w"], .REPEATABLE, move_word_start },
	.{ "Move to next word end", .["e"], .REPEATABLE, move_word_end },
	.{ "Move to prev word start", .["b"], .REPEATABLE, move_prev_word_start },
	.{ "Extend to next word start", .["W"], .REPEATABLE | .EXTEND, move_word_start },
	.{ "Extend to next word end", .["E"], .REPEATABLE | .EXTEND, move_word_end },
	.{ "Extend to prev word start", .["B"], .REPEATABLE | .EXTEND, move_prev_word_start },

	.{ "Move to next long word start", .["alt+w"], .REPEATABLE, move_long_word_start },
	.{ "Move to next long word end", .["alt+e"], .REPEATABLE, move_long_word_end },
	.{ "Move to next sub word start", .["ctrl+w"], .REPEATABLE, move_sub_word_start },
	.{ "Move to next sub word end", .["ctrl+e"], .REPEATABLE, move_sub_word_end },
	.{ "Extend to next long word start", .["alt+shift+w"], .REPEATABLE | .EXTEND, move_long_word_start },
	.{ "Extend to next long word end", .["alt+shift+e"], .REPEATABLE | .EXTEND, move_long_word_end },
	.{ "Extend to next sub word start", .["ctrl+shift+w"], .REPEATABLE | .EXTEND, move_sub_word_start },
	.{ "Extend to next sub word end", .["ctrl+shift+e"], .REPEATABLE | .EXTEND, move_sub_word_end },

	.{ "Jump to first occurence of {char}", .["f{char}"], .REPEATABLE, jump_to_char },
	.{ "Jump to just before first occurence of {char}", .["t{char}"], .REPEATABLE, jump_to_before_char },
	.{ "Jump to last occurence of {char}", .["alt+f{char}"], .REPEATABLE, jump_to_last_char },
	.{ "Jump to just before last occurence of {char}", .["alt+t{char}"], .REPEATABLE, jump_to_before_last_char },
	.{ "Extend to first occurence of {char}", .["F{char}"], .REPEATABLE | .EXTEND, jump_to_char },
	.{ "Extend to just before first occurence of {char}", .["T{char}"], .REPEATABLE | .EXTEND, jump_to_before_char },
	.{ "Extend to last occurence of {char}", .["alt+shift+f{char}"], .REPEATABLE | .EXTEND, jump_to_last_char },
	.{ "Extend to just before last occurence of {char}", .["alt+shift+t{char}"], .REPEATABLE | .EXTEND, jump_to_before_last_char },

	.{ "Extend selection to full lines", .["x"], .REPEATABLE, extend_selection_to_lines },
	.{ "Extend selection to lines above", .["X"], .REPEATABLE, extend_selection_to_lines_above },

	.{ "Select whole document", .["%"], 0, select_whole_document },

	.{ "Page Up", .["ctrl+b", "<pageup>"], 0, page_up },
	.{ "Page Down", .["ctrl+f", "<pagedown>"], 0, page_down },
	.{ "Half Page Up", .["ctrl+u"], 0, half_page_up },
	.{ "Half Page Down", .["ctrl+d"], 0, half_page_down },

	// misc normal mode
	.{ "Select register {char}", .["\"{char}"], 0, select_register },
	.{ "Next search result", .["n"], 0, next_search_result },
	.{ "Previous search result", .["N"], 0, previous_search_result },

	// search
	.{ "Search Document", .["/"], 0, start_document_search },

	// changes
	.{ "Delete selection", .["d"], 0, delete_selection },
	.{ "Change selection", .["c"], 0, change_selection },
	.{ "Yank selection", .["y"], 0, yank_selection },
	.{ "Paste after selection", .["p"], 0, paste_after_selection },
	.{ "Paste before selection", .["P"], 0, paste_before_selection },
	.{ "Replace selection with {char}", .["r{char}"], 0, replace_selection },
	.{ "Replace selection with yanked", .["R"], 0, replace_selection_with_yanked },
	.{ "New line below selection", .["o"], 0, new_line_below },
	.{ "New line above selection", .["O"], 0, new_line_above },
	.{ "Indent line", .[">"], 0, indent_line },
	.{ "Unindent line", .["<"], 0, unindent_line },
	.{ "Undo", .["u"], 0, undo },
	.{ "Redo", .["U"], 0, redo },
	.{ "Visualize Undos", .[], 0, visualize_undos },

	.{ "Open Filesystem Navigator", .["<space>o"], 0, open_file },
	.{ "Open Filesystem Navigator At Working Directory", .["<space>O"], 0, open_file_in_working_dir },
	.{ "Open Command Picker", .[":"], .HIDDEN, command_picker_open },
	.{ "Open File Finder", .["<space>f"], 0, file_finder_open },	

	.{ "Enter Insert Mode Start Of Selection", .["i"], 0, enter_insert_mode_start },
	.{ "Enter Insert Mode End Of Selection", .["a"], 0, enter_insert_mode_end },
	.{ "Enter Insert Mode Start Of Line", .["I"], 0, enter_insert_mode_line_start },
	.{ "Enter Insert Mode End Of Line", .["A"], 0, enter_insert_mode_line_end },
	.{ "Enter Normal Mode", .["<escape>"], 0, enter_normal_mode },

	// misc commands
	.{ "Print piece chain debug", .[], 0, print_piece_chain_debug },
	.{ "Toggle draw line endings", .[], 0, toggle_render_line_endings },

	// @todo: need command arguments to clean this up, second option box pops up to select from a dropdown
	.{ "Normalize Line Endings To LF", .[], 0, normalize_line_endings_lf },
	.{ "Normalize Line Endings To CRLF", .[], 0, normalize_line_endings_crlf },];

insertModeCommands :: Command.[
	.{ "Enter Normal Mode", .["<escape>"], 0, enter_normal_mode },
	.{ "Move one char left", .["<left>"], 0, move_one_char_left },
	.{ "Move one char right", .["<right>"], 0, move_one_char_right },
	.{ "Move one line down", .["<down>"], 0, move_one_line_down },
	.{ "Move one line up", .["<up>"], 0, move_one_line_up },

	.{ "Page Up", .["<pageup>"], 0, page_up },
	.{ "Page Down", .["<pagedown>"], 0, page_down },

	.{ "Backward Delete Char", .["<backspace>"], .HIDDEN, insert_mode_backward_delete_char },
	.{ "Forward Delete Char", .["<delete>"], .HIDDEN, insert_mode_forward_delete_char },
	.{ "Insert line break", .["<enter>"], .HIDDEN, insert_mode_line_break },
	.{ "Insert tab", .["<tab>"], .HIDDEN, insert_tab_character },
];

dialogModeCommands :: Command.[
	.{ "Dialog Select Next", .["<down>"], .HIDDEN, dialog_select_next },
	.{ "Dialog Select Previous", .["<up>"], .HIDDEN, dialog_select_previous },
	.{ "Dialog Action Item", .["<enter>"], .HIDDEN, dialog_action_item },
	.{ "Dialog Backward Delete", .["<backspace>"], .HIDDEN, dialog_backward_delete },
	.{ "Enter Normal Mode", .["<escape>"], 0, enter_normal_mode },
];

allCommands :: []Command.[
	normalModeCommands,
	insertModeCommands,
	dialogModeCommands
];

rebuild_key_map :: ()  {
	keyMap.allocator = Allocator.{proc = flat_pool_allocator_proc, data = *keyMap.memory};
	keyMap.pendingKeyString.allocator = keyMap.allocator;

	build_key_map_for_mode :: (list: []Command, mode: EditorMode) {
		for * cmd : list {
			for mapping : cmd.mappings {
				if mapping == "" continue;

				// Grab the mapping for each command
				// for each key in the mapping (single char, or modified key, or special key)
				keys := mapping;
				curNode := *keyMap.root[mode]; 
				while keys.count > 0 {
					hashKey:= keys;
					if begins_with(keys, "ctrl+") {
						advance(*keys, 5); 
					}
					if begins_with(keys, "alt+") {
						advance(*keys, 4); 
					}
					if begins_with(keys, "shift+") {
						advance(*keys, 6); 
					}

					if begins_with(keys, "<backspace>") {
						advance(*keys, 11); 
					}
					else if begins_with(keys, "<enter>") {
						advance(*keys, 7); 
					}
					else if begins_with(keys, "<escape>") {
						advance(*keys, 8); 
					}
					else if begins_with(keys, "<left>") {
						advance(*keys, 6); 
					}
					else if begins_with(keys, "<right>") {
						advance(*keys, 7); 
					}
					else if begins_with(keys, "<up>") {
						advance(*keys, 4); 
					}
					else if begins_with(keys, "<down>") {
						advance(*keys, 6); 
					}
					else if begins_with(keys, "<tab>") {
						advance(*keys, 5); 
					}
					else if begins_with(keys, "<delete>") {
						advance(*keys, 8); 
					}
					else if begins_with(keys, "<space>") {
						advance(*keys, 7); 
					}
					else if begins_with(keys, "<pageup>") {
						advance(*keys, 7); 
					}
					else if begins_with(keys, "<pagedown>") {
						advance(*keys, 7); 
					}
					else {
						advance(*keys, 1); // take just the one letter key
					}

					nArgs := 0;
					while begins_with(keys, "{char}") {
						advance(*keys, 6); 
						nArgs += 1;
					}

					// hashkey should be just what we grabbed from this loop iteration
					hashKey.count = hashKey.count - (keys.count + nArgs * 6);

					// a few possibilities
					// if keys.count == 0, this is a leaf
						// If there's already an entry in the current table, assert
						// No existing entry, add the entry now
					// if keys.count > 0 this is not a leaf
						// If there's no entry, add a new non-leaf entry set this as current table
						// if there's already a non-leaf entry, set as current and loop
						// if there's already a leaf entry, assert

					if keys.count == 0 { // leaf node
						assert(!table_contains(curNode.children, hashKey), "Mapping for % already exists", mapping);
						newNode := New(KeyMapNode,,keyMap.allocator);
						newNode.cmd = cmd;
						newNode.nArgs = xx nArgs;
						table_add(curNode.children, hashKey, newNode);
					}
					else if keys.count > 0 { // non-leaf node
						assert(nArgs == 0, "Arguments in a key mapping must be at the end of the sequence (for binding %)", mapping);
						exists, entry := table_find_new(curNode.children, hashKey);
						if !exists { 
							newNode := New(KeyMapNode,,keyMap.allocator);
							newNode.children = New(Table(string, *KeyMapNode),,keyMap.allocator);
							curNode = <<table_add(curNode.children, hashKey, newNode); 
						}
						else {
							assert(entry.cmd == null, "Start of this (%) key sequence already exists as a direct mapping", mapping);
							curNode = entry;
						}
					}
				}
			}
		}
	}
	
	keyMap.root[EditorMode.NORMAL].children = New(Table(string, *KeyMapNode),,keyMap.allocator);
	build_key_map_for_mode(normalModeCommands, .NORMAL);

	keyMap.root[EditorMode.INSERT].children = New(Table(string, *KeyMapNode),,keyMap.allocator);
	build_key_map_for_mode(insertModeCommands, .INSERT);

	keyMap.root[EditorMode.DIALOG].children = New(Table(string, *KeyMapNode),,keyMap.allocator);
	build_key_map_for_mode(dialogModeCommands, .DIALOG);

	keyMap.pendingKeyNode = *keyMap.root[editorMode];
}

input_handler :: (event: Input.Event) {
	keyString: string;
	keyStringIsText := false;

	if event.type == .TEXT_INPUT {
		char: Utf8_Char = convert_utf32_to_utf8(event.utf32);

		// if there are no pending key sequences give the text input to a currently focused dialog
		// otherwise normal insert mode can have it
		if keyMap.pendingKeyNode == *keyMap.root[editorMode] {
			if focusedPanel.activeDialog != .NONE {
				dialog_handle_text_input(*focusedPanel, char);
				return;
			}
			else if editorMode == .INSERT {
				insert_mode_handle_text_input(char);
				return;
			}
		}

		keyString= to_string(*char);
		keyStringIsText = true;
	}
	else if event.type == .KEYBOARD {
		keyMap.textInputCount = event.text_input_count;
		builder : String_Builder;
		builder.allocator = temp;
		init_string_builder(*builder);

		// modifiers first
		if event.ctrl_pressed {
			append(*builder, "ctrl+");
		}
		if event.alt_pressed {
			append(*builder, "alt+");
		}
		if event.shift_pressed {
			append(*builder, "shift+");
		}

		gotInput := true;
		if event.key_pressed && event.key_code == .BACKSPACE {
			append(*builder, "<backspace>");
		}
		else if event.key_pressed && event.key_code == .ESCAPE {
			append(*builder, "<escape>");
		}
		else if event.key_pressed && event.key_code == .ARROW_UP {
			append(*builder, "<up>");
		}
		else if event.key_pressed && event.key_code == .ARROW_DOWN {
			append(*builder, "<down>");
		}
		else if event.key_pressed && event.key_code == .ARROW_LEFT {
			append(*builder, "<left>");
		}
		else if event.key_pressed && event.key_code == .ARROW_RIGHT {
			append(*builder, "<right>");
		}
		else if event.key_pressed && event.key_code == .ENTER {
			append(*builder, "<enter>");
		}
		else if event.key_pressed && event.key_code == .TAB {
			append(*builder, "<tab>");
		}
		else if event.key_pressed && event.key_code == .PAGE_UP {
			append(*builder, "<pageup>");
		}
		else if event.key_pressed && event.key_code == .PAGE_DOWN {
			append(*builder, "<pagedown>");
		}
		else if event.key_pressed && event.key_code == .DELETE {
			append(*builder, "<delete>");
		}
		else if event.key_pressed && event.key_code == #char " " {
			append(*builder, "<space>");
		}
		else if event.key_pressed && event.key_code >= 33 && event.key_code <= 96 && event.modifier_flags.packed {
			// Note we only take characters as events here if there are modifiers on, otherwise we let the text
			// input case handle it
			// this is to disambiguate for example ctrl+shift+s vs ctrl+S
			lowered:u8 = to_lower(cast(u8)event.key_code); 
			append(*builder, lowered);
		}
		else {
			gotInput = false;
		}

		if gotInput keyString = builder_to_string(*builder,,temp);
	}

	if keyString.count == 0 return;

	// if a digit is given we take it as a count to repeat a motion
	if keyMap.pendingKeyNode == *keyMap.root[editorMode] && is_digit(keyString[0]) {
		digit, _, _ := string_to_int(keyString);
		keyMap.pendingCount = keyMap.pendingCount * 10 + cast(s32) digit;
	}

	nodePtr: **KeyMapNode;
	// if we're waiting for args, then potentially add it to pending and don't change the pending keynode
	if keyMap.pendingKeyNode.nArgs > keyMap.pendingArgs.count {
		if keyStringIsText {
			nodePtr = *keyMap.pendingKeyNode;
			array_add(*keyMap.pendingArgs, keyString);
		}
	}
	else {
		nodePtr = table_find_pointer(keyMap.pendingKeyNode.children, keyString);
	}

	if editorMode != .INSERT && nodePtr != null {
		for keyString {
			array_add(*keyMap.pendingKeyString, it);
		}
	}

	if nodePtr {
		node := <<nodePtr;
		if node.cmd && keyMap.pendingArgs.count == node.nArgs {
			// this is where we execute the actual command, subject to various
			// flag modifiers

			if keyMap.pendingCount == 0 then keyMap.pendingCount = 1;
			if !(node.cmd.flags & .REPEATABLE) then keyMap.pendingCount = 1; 

			while keyMap.pendingCount > 0 {
				if node.cmd.flags & .EXTEND {
					anchor := focusedPanel.cursor.anchor;
					node.cmd.execute(*focusedPanel, keyMap.pendingArgs);
					focusedPanel.cursor.anchor = anchor;
				}
				else {
					node.cmd.execute(*focusedPanel, keyMap.pendingArgs);
				}

				// register selection has some special behaviour as it's intended to be paired with 
				// one other action
				if node.cmd.execute != select_register {
					registers.selectedRegister = DEFAULT_REGISTER;
				}
				keyMap.pendingCount -= 1;
			}

			keyMap.pendingKeyNode = *keyMap.root[editorMode];
			array_reset_keeping_memory(*keyMap.pendingKeyString);
			array_reset_keeping_memory(*keyMap.pendingArgs);
		}
		else {
			keyMap.pendingKeyNode = node;
		}
	}
	// special handling for canceling a key sequence, not the neatest, but whatever
	else if keyString == "<escape>" {
		keyMap.pendingKeyNode = *keyMap.root[editorMode];
		array_reset_keeping_memory(*keyMap.pendingKeyString);
	}
}
