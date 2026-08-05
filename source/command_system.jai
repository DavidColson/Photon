

KeyMappingDesc :: struct {
	keys: string = "";
}

CommandFlags :: enum_flags u8 {
	HIDDEN;
	REPEATABLE;
	EXTEND;
}

CommandConfig :: struct {
	prettyName: string;
	keybinding: []string;
	category: string;
	flags: CommandFlags;
}

Command :: struct {
	name: string;
	Argument_Input :: struct {
		name: string;
		type: *Type_Info;
	}
	args: []Argument_Input;
	wrapper: (panel: *Panel, args: []*void);
	using config: CommandConfig;
}

Option :: struct {
	data: *void;
	type: *Type_Info;
}

KeyMap :: struct {
	memory : Flat_Pool;
	allocator: Allocator;
	root: [EDITOR_MODE_NUM]KeyMapNode;
	pendingKeyNode: *KeyMapNode;
	pendingKeyString: [..]u8;
	pendingArgs: [..]u8;
	pendingCount: s32;
	textInputCount: u16;
}

KeyMapNode :: struct {
	children: *Table(string, *KeyMapNode); // null if leaf node
	cmd: *Command;
	nArgs: s32;
}

optionsTable:    Table(string, Option);
normalModeCommands: [..]Command;
insertModeCommands: [..]Command;
dialogModeCommands: [..]Command;
allCommands: [3][..]Command;

// global keymap
keyMap: KeyMap;

initialize_commands_and_keymap :: ()  {
	register_options(); // created by the metaprogram to fill out all our command metadata
	
	// execute_command(*focusedPanel, normalModeCommands[1], .["321"]);
	// execute_command(*focusedPanel, dialogModeCommands[0], .["MIXED_MAJORITY_LF"]);
	
	// found, command = table_find(*commandTable, "sample_goto_line");
	// execute_command(*focusedPanel, , .["321"]);
	
	keyMap.allocator = Allocator.{proc = flat_pool_allocator_proc, data = *keyMap.memory};
	keyMap.pendingKeyString.allocator = keyMap.allocator;

	build_key_map_for_mode :: (list: []Command, mode: EditorMode) {
		for * cmd : list {
			for mapping : cmd.keybinding {
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
						// TODO: check that the command being bound to this mapping can actually accept the arguments
						// if nArgs > 0 {
							// assert(cmd.args == nArgs, "You can't bind a key with args to a command that doesn't have the corresponding amount of arguments");
							// for cmd.args {
								// assert(it.type == type_info(u8), "Argument type mismatch when binding a keybind with char arguments to a command that doesn't take chars"); 
							// }
						// }
						exists, entry := table_find(curNode.children, hashKey);
						if !exists { 
							newNode := New(KeyMapNode,,keyMap.allocator);
							newNode.children = New(Table(string, *KeyMapNode),,keyMap.allocator);
							curNode = (.*)table_add(curNode.children, hashKey, newNode); 
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

execute_command :: (panel: *Panel, command: Command, args: []string) {
	// Our input here is the command that was invoked either via a keybinding or via 
	// an entry in the command palette
	// and then a list of string arguments that the user typed into the command palette
	
	// our goal is to parse the arguments into the actual type required
	// and then invoke the command's wrapper
	
	// parse the given arguments into actual data values
	argsOut := NewArray(command.args.count, *void,, temp);
	for command.args {
		if it_index < args.count && args[it_index] {
			size := it.type.runtime_size;
			argsOut[it_index] = talloc(size);
			success := set_value_from_string(Any.{it.type, argsOut[it_index]}, args[it_index]);
			if !success {
				log_error("In command %, failed to convert argument % \"%\" to type %",
					command.name, it_index, it.name, it.type.type);
				return;
			}
		} else {
			log_error("In command %, no value provided for argument % \"%\"",
				command.name, it_index, it.name);
			return;
		}
	}
	
	command.wrapper(panel, argsOut);
}

set_option :: () {
	// TODO: this should take a string name of the option plus a string expression to set it to
	// It can lookup the option in the options table, and then parse and set the value
	// Likely the primary use case for this will be config files
	// so it would just amount to pulling the strings out of the config file and calling this function 
	
	// maybe we will make a set/get command as well which can do a similar thing with autocomplete
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
			array_add(*keyMap.pendingArgs, keyString[0]);
		}
	}
	else {
		nodePtr = table_find_pointer(keyMap.pendingKeyNode.children, keyString);
	}

	if editorMode != .INSERT && (nodePtr != null || is_digit(keyString[0])) {
		for keyString {
			array_add(*keyMap.pendingKeyString, it);
		}
	}

	if nodePtr {
		node := nodePtr.*;
		if node.cmd && keyMap.pendingArgs.count == node.nArgs {
			// this is where we execute the actual command, subject to various
			// flag modifiers

			if keyMap.pendingCount == 0 then keyMap.pendingCount = 1;
			if !(node.cmd.flags & .REPEATABLE) then keyMap.pendingCount = 1; 
			
			// Turn the list of pending keyargs to an array of void*
			// so we can give it to the command wrapper
			keyArgs: []*void;
			if keyMap.pendingArgs.count {
				keyArgs = NewArray(keyMap.pendingArgs.count, *void,, temp);
				for keyMap.pendingArgs {
					keyArgs[it_index] = cast(*void, *it);
				}
			}
			
			while keyMap.pendingCount > 0 {
				if node.cmd.flags & .EXTEND {
					anchor := focusedPanel.cursor.anchor;
					node.cmd.wrapper(*focusedPanel, keyArgs);
					focusedPanel.cursor.anchor = anchor;
				}
				else {
					node.cmd.wrapper(*focusedPanel, keyArgs);
				}

				// register selection has some special behaviour as it's intended to be paired with 
				// one other action
				if node.cmd.name != "select_register" {
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
