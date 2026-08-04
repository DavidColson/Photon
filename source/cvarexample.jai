/*
    // CVars (quake-style config vars or console vars, but much more flexible):
    Player :: struct { position: Vector3; }
    player: Player; @CVar

    // Set fields of a struct, multiple at once. Can skip or arguments.
    > player.position ,10,      // This only sets y. x and z are left untouched
    > player.position.y 10      // y can also be set manually

    // When no arguments are passed, it'll print the cvar struct
    > player.position           // Prints the Vector3 struct `position`
    > player.position.x         // Prints the float `x`

    // Commands:
    echo :: (msg: string) { ... } @Command
    > echo "Hello world\n"      // Escapes in quoted strings are parsed
    > echo text                 // Strings can be unquoted if they don't contain spaces or escapes
    
    // Multiple arguments, default arguments
    my_command :: (a: int, b: int, c: int = 10) { .. } @Command
    > my_command 10, 69          // c is optional and default to 10

    // Varargs are possible with the condition that the variable argument is the last one
    my_command :: (vararg: .. int) { .. } @Command
    > my_command, 10, 20, 30     // Can be as many as you want
*/

#import "Compiler";

Command2 :: struct {
    Argument_Input :: struct {
        name: string;
        type: *Type_Info;
    }
    args: []Argument_Input;
    proc: (panel: *Panel, args: []*void);
    flags: enum {
        LAST_ARG_IS_VARARGS :: 0x1;
    };
}

Option :: struct {
    data: *void;
    type: *Type_Info;
}

commandTable: Table(string, Command2);
optionsTable:    Table(string, Option);


commands_init :: () {
    register_commands_and_options(); // Inserted by the metaprogram
}

run_console_command :: (panel: *Panel, input: string) {
    in := input;

    // Eat leading spaces
    while in.count && is_space(in[0]) {
        advance(*in, 1);
    }

    // Everything before the first space is a command or cvar.
    cursor := find_index_from_left(in, #char " ");
    if cursor < 0  cursor = in.count;
    left := split(string.{cursor, in.data}, cast(u8) #char ".",, temp);
    if !left {
        log_error("Unable to parse command");
        return;
    }

    // The rest are arguments.
    args := parse_args(string.{in.count - cursor, in.data + cursor});

    // We only check for commands if left doesn't contain dots.
    if left.count == 1 {
        command := table_find_pointer(*commandTable, left[0]);
        if command {
            args_out := NewArray(command.args.count, *void,, temp);
            for command.args {
                if it_index < args.count && args[it_index] {
                    if it_index == command.args.count - 1 && command.flags & .LAST_ARG_IS_VARARGS {
                        assert(it.type.type == .ARRAY);
                        element_type := (cast(*Type_Info_Array) it.type).element_type;

                        // Process varargs
                        args_left := args.count - it_index;
                        out_data := cast(*u8) talloc(args_left * element_type.runtime_size);

                        for i: 0..args_left - 1 {
                            the_element := out_data + i * element_type.runtime_size;
                            the_arg := args[it_index + i];
                            success := set_value_from_string2(Any.{element_type, the_element}, the_arg);
                            if !success {
                                log_error("In command %, failed to convert argument % \"%\" to type %",
                                          left[0], it_index, it.name, element_type.type);
                                return;
                            }
                        }

                        out_arg := cast(*[]void) talloc(size_of([]void));
                        out_arg.count = args_left;
                        out_arg.data  = out_data;
                        args_out[it_index] = out_arg;

                        break; // We are done
                    }

                    size := it.type.runtime_size;
                    args_out[it_index] = talloc(size);
                    success := set_value_from_string2(Any.{it.type, args_out[it_index]}, args[it_index]);
                    if !success {
                        log_error("In command %, failed to convert argument % \"%\" to type %",
                                  left[0], it_index, it.name, it.type.type);
                        return;
                    }
                } else {
					log_error("In command %, no value provided for argument % \"%\"",
						left[0], it_index, it.name);
					return;
                }
            }
            command.proc(panel, args_out);
            return;
        }
    }

    // No command found - try cvars
    found, cvar := table_find(*optionsTable, left[0]);
    if !found {
        log_error("Unknown command or cvar \"%\"", left[0]);
        return;
    }

    // Find the member's type and address
    cursor = 1;
    type := cvar.type;
    data := cvar.data;
    while cursor < left.count {
        defer cursor += 1;
        name := left[cursor];
        if type.type != .STRUCT {
            log_error("Cannot access members of type %", type.type);
            return;
        }
        info := cast(*Type_Info_Struct) type;

        found: bool;
        for info.members {
            if it.flags & .CONSTANT  continue;
            if it.flags & .IMPORTED  continue;
            if it.name == name {
                data += it.offset_in_bytes;
                type = it.type;
                found = true;
                break;
            }
        }

        if !found {
            log_error("No member named % in struct %", name, info.name);
            return;
        }
    }

    // If no args are passed, just print it
    if args.count == 0 {
        if type.type == .STRUCT {
            log("%", formatStruct(Any.{type, data}, 0, true)); // Pretty formatting because why not
        } else {
            log("%", Any.{type, data});
        }
        return;
    }

    // Set non-struct type
    if type.type != .STRUCT {
        if args.count != 1 {
            log_error("Too many arguments for non-struct type %.", type.type);
        } else {
            success := set_value_from_string2(Any.{type, data}, args[0]);
            if !success  log_error("failed to set value \"%\" to variable of type %", args[0], type.type);
        }
        return;
    }

    // Set members in case of struct type
    info := cast(*Type_Info_Struct) type;
    cursor = 0;
    highest_offset := -1;
    for * info.members {
        defer cursor += 1;
        if cursor >= args.count  break;

        if it.flags & .CONSTANT  continue;
        if it.flags & .IMPORTED  continue;

        if it.offset_in_bytes < highest_offset  continue;
        if it.type.runtime_size == 0            continue;

        highest_offset = it.offset_in_bytes + it.type.runtime_size;

        // We set the members in order. If we fail on one of the members but we've already set the
        // previous ones, we can't go back and unset them. I would prefer to either succeed or fail
        // the entire command instead of this half-success half-failure thing.
        // Perhaps we can do something smarter.
        arg := args[cursor];
        if arg.count {
            success := set_value_from_string2(Any.{it.type, data + it.offset_in_bytes}, arg);
            if !success  log_error("failed to set value \"%\" to variable of type %", arg, it.type.type);
            break;
        }
    }

    if args.count > cursor {
        log_error("Too many arguments for struct %, last % ignored.", info.name, args.count - cursor);
    }
}


COMMANDS_FILE_SCOPE :: #code {};

#import "Program_Print";

command_cat :: (path: string) {
    #import "Process";
    result, out, err := run_command("cat", path, capture_and_return_output=true);
    if result.exit_code == 0 {
        log("%", out);
    } else {
        log("%", err);
    }
} @Command

command_exit :: (exit_code: s32 = 0) {
    exit(exit_code);
} @Command

command_clear :: () {
    // console.current_line = 0;
    // console.lines_used   = 0;
	log("Clear");
} @Command

command_echo :: (msg: .. string) {
    log("%", join(.. msg, separator = " ",, temp));
} @Command

parse_args ::  (input: string) -> []string {
    cursor: s64;
    args: [..]string;

    while outer := cursor < input.count {
        c := input[cursor];

        // eat spaces
        while is_space(c) {
            cursor += 1;
            if cursor >= input.count  break outer;
            c = input[cursor];
        }

        if c == #char "\"" {
            builder: String_Builder;
            cursor += 1;
            while 1 {
                if cursor >= input.count {
                    log_error("Unterminated quoted argument");
                    return .[];
                }

                c := input[cursor];

                if c == #char "\"" {
                    cursor += 1;
                    break;
                }

                if c == #char "\n" {
                    log_error("Newline in quoted argument");
                    return .[];
                }

                if c == #char "\\" {
                    cursor += 1;
                    if cursor >= input.count {
                        log_error("Unterminated escape sequence in quoted argument");
                        return .[];
                    }

                    c = parse_escape(input[cursor]);
                }

                append(*builder, c);
                cursor += 1;
            }
            array_add(*args, builder_to_string(*builder));
        } else {
            start_cursor := cursor;
            while 1 {
                if is_space(c) || c == #char ","  break;
                cursor += 1;
                if cursor >= input.count  break;
                c = input[cursor];
            }
            arg := string.{cursor - start_cursor, input.data + start_cursor};
            array_add(*args, arg);
        }

        if cursor >= input.count  break;
        c = input[cursor];

        // Eat trailing spaces (before comma or at the end)
        while is_space(c) {
            cursor += 1;
            if cursor >= input.count  break outer;
            c = input[cursor];
        }

        if c != #char "," {
            log_error("Unable to parse input, expected list of comma-separated arguments");
            return .[];
        };
        cursor += 1;
    }
    return args;
}

parse_escape :: inline (c: u8) -> u8 {
    if c == {
    case #char "r";  c = #char "\r";
    case #char "n";  c = #char "\n";
    case #char "t";  c = #char "\t";
    case #char "0";  c = 0;
    case #char "e";  c = 0x1b;
    case #char " ";  // c = #char " ";
    case #char "\""; // c = #char "\"";
    case #char "\\"; // c = #char "\\";
    case; log_error("Unknown escape sequence \"\\%\"", string.{1, *c});
    }
    return c;
}

// From modules/Reflection, but modified. Changle the name if you have imported Reflection outside of it.
set_value_from_string2 :: (any: Any, text: string) -> bool {
    #import "Reflection";

    read_bool :: inline (text: string) -> bool, bool {
        if compare_nocase(text, "true") == 0 {
            return true, true;
        }
        if compare_nocase(text, "false") == 0 {
            return true, false;
        }

        result, success, remainder := string_to_int(text);
        return success && !remainder, xx result;
    }

    if any.type.type == {
        case .INTEGER;
            i, success, remainder := string_to_int(text);
            if !success || remainder  return false;

            ti_integer := cast(*Type_Info_Integer)any.type;
            if ti_integer.signed {
                valid, low, high := range_check_and_store(i, ti_integer, any.value_pointer);
                // @ToDo: We could log an error with the ranges here, similar to Command_Line.parse_and_write_integer
                if !valid return false;
            } else {
                valid, low, high := range_check_and_store(cast(u64) i, ti_integer, any.value_pointer);
                // @ToDo: We could log an error with the ranges here, similar to Command_Line.parse_and_write_integer
                if !valid return false;
            }

            return true;
        case .FLOAT;
            if any.type.runtime_size == 4 {
                f, success, remaining := string_to_float(text);
                if !success || remaining  return false;
                (.*) cast(*float32) any.value_pointer = f;
            } else if any.type.runtime_size == 8 {
                f, success, remaining := string_to_float64(text);
                if !success || remaining  return false;
                (.*) cast(*float64) any.value_pointer = f;
            } else {
                return false;
            }
        case .BOOL;
            success, b := read_bool(text);
            if !success return false;
            if any.type.runtime_size == 1 {
                (.*) cast(*bool)any.value_pointer = b;
            } else {
                return false;
            }
        case .STRING;
            if !text  return false;
            (.*) cast(*string) any.value_pointer = text;
        case .ENUM;
            enum_type := cast(*Type_Info_Enum)any.type;
            // First, try to parse it as an integer.
            _any := any;
            _any.type = enum_type.internal_type;
            success := set_value_from_string2(_any, text);

            // If that doesn't work, try to parse the enum names.
            if !success {
                for enum_type.names {
                    if it == text {
					if enum_type.runtime_size == 1      { (.*)cast(*s8)any.value_pointer = xx enum_type.values[it_index]; }
                        else if enum_type.runtime_size == 2 { (.*)cast(*s16)any.value_pointer = xx enum_type.values[it_index]; }
                        else if enum_type.runtime_size == 4 { (.*)cast(*s32)any.value_pointer = xx enum_type.values[it_index]; }
                        else if enum_type.runtime_size == 8 { (.*)cast(*s64)any.value_pointer = enum_type.values[it_index]; }
                        return true;
                    }
                }
            }

            if !success return false;
        case;
            return false;
    }

    return true;
}


