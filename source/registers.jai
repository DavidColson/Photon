// Registers
// --------------------------------
// Each register holds one value per cursor, so yanking with multiple cursors and pasting
// gives each cursor back its own text. All the values of a register are stored back to back
// in one buffer, so a register costs two allocations no matter how many cursors wrote to it.
//
// The default register is mirrored to the OS clipboard, joined with a separator. When reading
// it back, if the clipboard still holds exactly what we wrote, we use our per cursor values,
// otherwise something outside of photon changed the clipboard and it's treated as one value.

DEFAULT_REGISTER :: #char "+";

REGISTER_SHRINK_THRESHOLD :: 64 * 1024;

Register :: struct {
	data: [..]u8;   // every value stored back to back
	ends: [..]s64;  // ends[i] is the end offset of value i in data
}

Registers :: struct {
	slots: [256]Register;
	allocator: Allocator;
	selectedRegister: u8 = DEFAULT_REGISTER;

	// separator used to join the values the last time we set the OS clipboard
	clipboardSeparator: string;
}
registers: Registers;

register_begin_write :: (name: u8) -> *Register {
	reg := *registers.slots[name];
	array_reset_keeping_memory(*reg.data);
	array_reset_keeping_memory(*reg.ends);
	return reg;
}

register_add_value :: (reg: *Register, value: string) {
	register_reserve_extra(*reg.data, value.count);
	memcpy(reg.data.data + reg.data.count, value.data, value.count);
	reg.data.count += value.count;
	array_add(*reg.ends, reg.data.count,,registers.allocator);
}

// copies the (inclusive) range between the two locations as one value, straight from the document
register_add_document_range :: (reg: *Register, doc: DocumentHandle, locationA: s64, locationB: s64) {
	start := min(locationA, locationB);
	end := max(locationA, locationB);

	register_reserve_extra(*reg.data, end - start + 1);
	iterator := make_iterator(doc, start);
	for :raw_bytes iterator {
		array_add(*reg.data, it,,registers.allocator);
		if it != #char "\r" && iterator.offset >= end then break;
	}
	array_add(*reg.ends, reg.data.count,,registers.allocator);
}

// separator is used to join the values when this is the default register and they go to the OS clipboard
register_end_write :: (name: u8, separator := "\n") {
	reg := *registers.slots[name];
	if name == DEFAULT_REGISTER {
		os_clipboard_set_text(register_join(reg, separator));
		registers.clipboardSeparator = separator;
	}

	register_shrink_to_fit(*reg.data);
	register_shrink_to_fit(*reg.ends);
}

// convenience for registers that only ever hold one value, like the search register
write_register :: (name: u8, value: string) {
	reg := register_begin_write(name);
	register_add_value(reg, value);
	register_end_write(name);
}

// The returned values are views into the register, and are valid until the register is next written to
// you shouldn't store them, just call read_register again to retrieve them
read_register :: (name: u8) -> []string {
	reg := *registers.slots[name];
	if name == DEFAULT_REGISTER {
		// os_clipboard_get_text() heap-allocates its result
		clipboardText := os_clipboard_get_text();
		defer free(clipboardText);

		if clipboard_matches_register(clipboardText, reg, registers.clipboardSeparator) {
			return register_values(reg);
		}

		// the clipboard was changed outside of photon, so it's one value for every cursor
		values := NewArray(1, string,,temp);
		values[0] = copy_string(clipboardText,,temp);
		return values;
	}
	return register_values(reg);
}

// If there are more cursors than values, the last value is repeated for the remaining cursors
register_value_for_cursor :: (values: []string, cursorIndex: s64) -> string {
	if values.count == 0 return "";
	return values[min(cursorIndex, values.count - 1)];
}

#scope_file

register_values :: (reg: *Register) -> []string {
	values := NewArray(reg.ends.count, string,,temp);
	start := 0;
	for end, i: reg.ends {
		values[i] = .{end - start, reg.data.data + start};
		start = end;
	}
	return values;
}

register_join :: (reg: *Register, separator: string) -> string {
	builder : String_Builder;
	builder.allocator = temp;
	init_string_builder(*builder);

	for value, i: register_values(reg) {
		if i > 0 then append(*builder, separator);
		append(*builder, value);
	}
	return builder_to_string(*builder,,temp);
}

// checks if the clipboard holds exactly the register's values joined with separator,
// without building the joined string
clipboard_matches_register :: (clipboard: string, reg: *Register, separator: string) -> bool {
	if reg.ends.count == 0 return false;
	if clipboard.count != reg.data.count + separator.count * (reg.ends.count - 1) return false;

	offset := 0;
	for value, i: register_values(reg) {
		if i > 0 {
			if string.{separator.count, clipboard.data + offset} != separator return false;
			offset += separator.count;
		}
		if string.{value.count, clipboard.data + offset} != value return false;
		offset += value.count;
	}
	return true;
}

// grows geometrically, as array_reserve on its own reserves exactly what's asked for
register_reserve_extra :: (array: *[..]u8, extra: s64) {
	needed := array.count + extra;
	if needed > array.allocated {
		array_reserve(array, max(needed, array.allocated * 2),,registers.allocator);
	}
}

register_shrink_to_fit :: (array: *[..]$T) {
	if array.allocated * size_of(T) <= REGISTER_SHRINK_THRESHOLD return;
	if array.allocated <= array.count * 4 return;

	shrunk: [..]T;
	array_reserve(*shrunk, array.count,,registers.allocator);
	memcpy(shrunk.data, array.data, array.count * size_of(T));
	shrunk.count = array.count;
	array_free(array.*);
	array.* = shrunk;
}
