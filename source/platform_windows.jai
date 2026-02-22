
platform_enumerate_logical_drives :: () -> [] string {
	drives: [..] string;

	drives_buf: [500] u16;
	GetLogicalDriveStringsW(500, drives_buf.data);

	drive_wstr := drives_buf.data;
	for drives_buf {
		if it == 0 { // split on null terminator
			drive, success := wide_to_utf8(drive_wstr,, allocator = temp);
			if !drive || !success break;
			drive.count -= 1;  // cut off separator
			array_add(*drives, drive);
			drive_wstr = *drives_buf[it_index + 1];
		}
	}

	return drives;
}

platform_is_path_directory :: (path: string) -> bool {
	push_allocator(temp);
	attrib := GetFileAttributesW(utf8_to_wide(path));
	if attrib & FILE_ATTRIBUTE_DIRECTORY {
		return true;
	}
	return false;
}

platform_get_dpi_scale :: (window: Window_Type) -> float {
	dpi := cast(float) GetDpiForWindow(window);
	return dpi / 96.0;
}

platform_wait_message :: inline () {
	WaitMessage();
}

BackupTimerCallback :: #type ();
platform_set_backup_timer :: (window: Window_Type, callback: BackupTimerCallback) {
	backupTimerCallback = callback;
	SetTimer(window, 0, 1000*60*5, cast(*void)_windows_timer_callback);
}

platform_swap_buffers :: (window: Window_Type) {
	dc := GetDC(window);
	SwapBuffers(dc);
}

platform_set_border_color :: () {
	using DwmAttribute;
	col : u32 = 0xFFFFFFFF;
	r : u32 = cast(u32)(style.backgroundMid.x * 255.0);
	g : u32 = cast(u32)(style.backgroundMid.y * 255.0);
	b : u32 = cast(u32)(style.backgroundMid.z * 255.0);
	// COLORREF format is 0x00bbggrr
	col = 0x00000000;
	col |= b << 16;
	col |= g << 8;
	col |= r;
	DwmSetWindowAttribute(window, CAPTION_COLOR, *col, size_of(u32));
}

platform_init_crash_handler :: () {
	SetUnhandledExceptionFilter :: (lpTopLevelExceptionFilter: *void) -> *void #foreign kernel32;
	SetUnhandledExceptionFilter(xx handle_exception);

	// Maybe we don't want to call a bunch of functions after
	// a crash occurs, because maybe things are messed up.
	// So we call these things upfront.
	SymInitialize :: (hProcess: *void, UserSearchPath: *u8, fInvadeProcess: s32) -> s32 #foreign DbgHelp;
	SymSetOptions :: (SymOptions: u32) -> u32 #foreign DbgHelp;

	// SYMOPT_DEFERRED_LOADS make us not take a ton of time unless we actually log traces.
	SymSetOptions(0x216); // SYMOPT.DEFERRED_LOADS|.FAIL_CRITICAL_ERRORS|.LOAD_LINES|.UNDNAME;

	if !SymInitialize(CurrentProcess, null, xx true) {
		// Don't log anything; don't want to weigh this code down. We just silently won't handle exceptions.
		return;
	}

	symbols_initialized = true;
}

#run {
    #if BUILD_TYPE == .RELEASE {
        WR :: #import "Windows_Resources";
        WR.disable_runtime_console();
    }
}

#scope_file 

backupTimerCallback: BackupTimerCallback;
_windows_timer_callback :: (hwnd: HWND, message: u32, timerId: u32, dwTime: DWORD) #c_call {
	push_context {
		backupTimerCallback();
	}
}

kernel32 :: #system_library "kernel32";
user32   :: #system_library "user32";
Dwmapi :: #system_library "Dwmapi";
#import "Windows";
#import "Windows_Utf8";
GetLogicalDriveStringsW :: (nBufferLength: DWORD, lpBuffer: *u16) -> DWORD #foreign kernel32;
GetDpiForWindow :: (hWnd: HWND) -> u32 #foreign user32;
WaitMessage :: () -> s32 #foreign user32;
SetTimer  :: (hWnd: HWND, nIDEvent: u64, uElapse: u32, lpTimerFunc: *void) -> s32 #foreign user32;
DwmSetWindowAttribute :: (handle: HANDLE, dwAttribute: DwmAttribute, pvAttributde :*void, cbAttribute :DWORD) -> HRESULT #foreign Dwmapi;

DwmAttribute :: enum u32 {
	NCRENDERING_ENABLED;
	NCRENDERING_POLICY;
	TRANSITIONS_FORCEDISABLED;
	ALLOW_NCPAINT;
	CAPTION_BUTTON_BOUNDS;
	NONCLIENT_RTL_LAYOUT;
	FORCE_ICONIC_REPRESENTATION;
	FLIP3D_POLICY;
	EXTENDED_FRAME_BOUNDS;
	HAS_ICONIC_BITMAP;
	DISALLOW_PEEK;
	EXCLUDED_FROM_PEEK;
	CLOAK;
	CLOAKED;
	FREEZE_REPRESENTATION;
	PASSIVE_UPDATE_MODE;
	USE_HOSTBACKDROPBRUSH;
	USE_IMMERSIVE_DARK_MODE :: 20;
	WINDOW_CORNER_PREFERENCE :: 33;
	BORDER_COLOR;
	CAPTION_COLOR;
	TEXT_COLOR;
	VISIBLE_FRAME_BORDER_THICKNESS;
	SYSTEMBACKDROP_TYPE;
	LAST;
}
windows_context: CONTEXT  #align 32;  // @Incomplete: should be on the stack for threadsafety.
symbols_initialized := false;
CurrentProcess := cast(*void) -1;  // GetCurrentProcess on Windows just returns -1.

DbgHelp  :: #system_library "DbgHelp";

CONTEXT :: struct {
    using members: struct {
        before_rax: [152] u8 = ---;
        Rsp: u64;
        Rbp: u64;
        other: [10] u64;

        Rip: u64;
    }
    
    padding: [1232 - size_of(type_of(members))] u8 = ---;
}

#assert(size_of(CONTEXT) == 1232);

ADDRESS64 :: struct {
    Offset: u64;
    Segment: u16;
    Mode: s32;
}

STACKFRAME64 :: struct {
    using members: struct {
        AddrPC:     ADDRESS64;
        AddrReturn: ADDRESS64;
        AddrFrame:  ADDRESS64;
        AddrStack:  ADDRESS64;
    }
    
    padding: [264 - size_of(type_of(members))] u8;
}

#assert(size_of(STACKFRAME64) == 264);

EXCEPTION_RECORD :: struct {
	ExceptionCode: u32;
	ExceptionFlags: u32;
	ExceptionRecord: *EXCEPTION_RECORD;
	ExceptionAddress: *void;
	NumberParameters: u32;
	ExceptionInformation: [15]u64;
}

EXCEPTION_POINTERS :: struct {
	ExceptionRecord: *EXCEPTION_RECORD;
	ContextRecord:   *CONTEXT;
}

backtrace :: (ctx: *CONTEXT, skips: s32) {
	// Init the stack frame for this function
	stackFrame: STACKFRAME64;

	IMAGE_FILE_MACHINE :: enum u32 {
		I386  :: 0x014c;
		IA64  :: 0x0200;
		AMD64 :: 0x8664;
	}

	// @@ Assuming x64
	dwMachineType := IMAGE_FILE_MACHINE.AMD64;
	stackFrame.AddrPC   .Offset = ctx.Rip;
	stackFrame.AddrFrame.Offset = ctx.Rbp;
	stackFrame.AddrStack.Offset = ctx.Rsp;

	AddrModeFlat :: 3;

	stackFrame.AddrPC   .Mode = AddrModeFlat;
	stackFrame.AddrFrame.Mode = AddrModeFlat;
	stackFrame.AddrStack.Mode = AddrModeFlat;
	//stackFrame.AddrReturn.Offset = ctx.Rip;

	ReadProcessMemoryProc64 :: #type (hProcess: *void, lpBaseAddress: u64, lpBuffer: *void, nSize: u32, lpNumberOfBytesRead: *u32) -> s32 #c_call;
	FunctionTableAccessProc64 :: #type (hProcess: *void, AddrBase:u64) -> *void #c_call;
	GetModuleBaseProc64 :: #type (hProcess: *void, dwAddr:u64) -> u64 #c_call;
	TranslateAddressProc64 :: #type (hProcess: *void, hThread: *void, lpaddr: *ADDRESS64) -> u64 #c_call;

	// Annoying dbghelp stuff:
	StackWalk64 :: (MachineType: IMAGE_FILE_MACHINE, hProcess: *void, hThread: *void, StackFrame:*STACKFRAME64, ContextRecord: *void,
					ReadMemoryRoutine: ReadProcessMemoryProc64, FunctionTableAccessRoutine: FunctionTableAccessProc64,
					GetModuleBaseRoutine: GetModuleBaseProc64, TranslateAddress: TranslateAddressProc64) -> s32 #foreign DbgHelp;

	SymGetSymFromAddr64 :: (hProcess: *void, Address: u64, Displacement: *u64, Symbol: *void) -> s32 #foreign DbgHelp;
	SymFunctionTableAccess64 :: (hProcess: *void, AddrBase:u64) -> *void #foreign DbgHelp;
	SymGetModuleBase64 :: (hProcess: *void, dwAddr:u64) -> u64 #foreign DbgHelp;

	// Walk up the stack.
	GetCurrentThread :: () -> *void #foreign kernel32;
	hThread := GetCurrentThread();

	LIMIT :: 2047;  // If you exceed this many calls, you ain't going to get more trace.
	i := 0;
	while i < LIMIT {
		// walking once first makes us skip self
		if !StackWalk64(dwMachineType, CurrentProcess, hThread, *stackFrame, ctx, null, SymFunctionTableAccess64, SymGetModuleBase64, null) {
			break;
		}

		// For robustness, we should ensure that rsp continually increases?

		/*if (stackFrame.AddrPC.Offset == stackFrame.AddrReturn.Offset || stackFrame.AddrPC.Offset == 0) {
			break;
		}*/

		if (i > 0) && (i <= skips) {
			// Skip a bunch of stuff internal to the OS that is annoying.
			if i == 1  log("... (skipping OS-internal procedures)");
			i += 1;
			continue;
		}

		MAX_NAME_LEN :: 512;
		MY_IMAGEHLP_SYMBOL64 :: struct {  // An extension of Windows' IMAGEHLP_SYMBOL64 to have MAX_NAME_LEN on the end.
			SizeOfStruct: u32;
			Address: u64;
			Size: u32;
			Flags: u32;
			MaxNameLength: u32;
			Name: [MAX_NAME_LEN] u8;
		}

		IMAGEHLP_LINE64 :: struct {
			SizeOfStruct: u32;
			Key: *void;
			LineNumber: u32;
			FileName: *u8;
			Address: u64;
		}

		// Get the function name.
		symbol: MY_IMAGEHLP_SYMBOL64;
		symbol.SizeOfStruct = 32;  // This is size_of(IMAGEHLP_SYMBOL64).
		symbol.MaxNameLength = MAX_NAME_LEN;

		func := "unknown";
		ip := stackFrame.AddrPC.Offset;
		symbol_displacement: u64;  // What are these for exactly? Can we just pass null instead?
		if SymGetSymFromAddr64(CurrentProcess, ip, *symbol_displacement, *symbol) {     // @@ Use SymFromAddr instead?
			func = to_string(symbol.Name.data);
		}


		// Get file and line number.
		theLine: IMAGEHLP_LINE64;
		theLine.SizeOfStruct = size_of(IMAGEHLP_LINE64);

		file := "unknown";
		line: int;
		SymGetLineFromAddr64 :: (hProcess: *void, dwAddr: u64, pdwDisplacement: *u32, Line: *IMAGEHLP_LINE64) -> s32 #foreign DbgHelp;
		line_displacement: u32;
		if SymGetLineFromAddr64(CurrentProcess, ip, *line_displacement, *theLine) {
			file = to_string(theLine.FileName);
			line = theLine.LineNumber;
		}

        builder : String_Builder;
        builder.allocator = temp;
		append(*builder, func);

		NAME_WIDTH :: 32;

		padding := NAME_WIDTH - func.count;
		for 1..padding append(*builder, " ");

		// @Speed: Can optimize the outputting of spaces.
		append(*builder, "  ");
		append(*builder, file);
		append(*builder, ":");
		print_to_builder(*builder, "%", cast,no_check(u64) line);
		log(builder_to_string(*builder,,temp));

		if func == "main" {  // @Incomplete: We really want to compare against the entry point, which may not be "main".
			break;
		}

		i += 1;
	}
}

is_ptr_in_program_section :: (ptr: *void) -> in_program_section: bool, read_only: bool, section_name: string #no_context {
	IMAGE_FILE_HEADER :: struct {
		Machine: u16;
		NumberOfSections: u16;
		TimeDateStamp: u32;
		PointerToSymbolTable: u32;
		NumberOfSymbols: u32;
		SizeOfOptionalHeader: u16;
		Characteristics: u16;
	}

	IMAGE_SECTION_HEADER :: struct {
		Name: [8]u8;
		Misc: union {
			PhysicalAddress: u32;
			VirtualSize: u32;
		};
		VirtualAddress: u32;
		SizeOfRawData: u32;
		PointerToRawData: u32;
		PointerToRelocations: u32;
		PointerToLinenumbers: u32;
		NumberOfRelocations: u16;
		NumberOfLinenumbers: u16;
		Characteristics: u32;
	}

	IMAGE_NT_HEADERS :: struct {
		Signature: u32;
		FileHeader: IMAGE_FILE_HEADER;
		// We only use this struct as a pointer, so we
		// can omit this member we don't use
		OptionalHeader: void;
	}

	IMAGE_FIRST_SECTION :: (header: *IMAGE_NT_HEADERS) -> *IMAGE_SECTION_HEADER #no_context { 
		result := cast (*void) *header.OptionalHeader + header.FileHeader.SizeOfOptionalHeader;

		return cast (*IMAGE_SECTION_HEADER) result;
	}

	GetModuleHandleW :: (lpModuleName: *u16) -> *void #foreign kernel32;
	ImageNtHeader :: (Base: *void) -> *IMAGE_NT_HEADERS #foreign DbgHelp;

	module := GetModuleHandleW (null);
	header := ImageNtHeader (module);

	sections: []IMAGE_SECTION_HEADER = ---;
	sections.count = header.FileHeader.NumberOfSections;
	sections.data  = IMAGE_FIRST_SECTION (header);

	for sections {
		// GetModuleHandle returns the base address of where the module is loaded
		loaded_addr := module + it.VirtualAddress;
		if ptr > loaded_addr && ptr < loaded_addr + it.SizeOfRawData {
			return in_program_section = true,
				read_only = (it.Characteristics & 0x40000000) && !(it.Characteristics & 0x80000000),
				section_name = to_string (it.Name.data);
		}
	}

	return false, false, "";
}

handle_exception :: (using pExceptionInfo: *EXCEPTION_POINTERS) -> s32 #c_call {
	push_context {
	    context.logger = loggerFunc;
	    context.logger_data = *logger;

		EXCEPTION_ACCESS_VIOLATION :: 3221225477;
		EXCEPTION_ARRAY_BOUNDS_EXCEEDED :: 3221225612;
		EXCEPTION_BREAKPOINT :: 2147483651;
		EXCEPTION_DATATYPE_MISALIGNMENT :: 2147483650;
		EXCEPTION_FLT_INVALID_OPERATION :: 3221225616;
		EXCEPTION_ILLEGAL_INSTRUCTION :: 3221225501;
		EXCEPTION_IN_PAGE_ERROR :: 3221225478;
		EXCEPTION_INT_DIVIDE_BY_ZERO :: 3221225620;
		EXCEPTION_PRIV_INSTRUCTION :: 3221225622;
		EXCEPTION_STACK_OVERFLOW :: 3221225725;

 		if ExceptionRecord.ExceptionCode == {
		// I'm trying to limit the amount of code we have here, so let's combine page fault and access violation
		case EXCEPTION_ACCESS_VIOLATION; #through;
		case EXCEPTION_IN_PAGE_ERROR;
			exception := ifx ExceptionRecord.ExceptionCode == EXCEPTION_ACCESS_VIOLATION then "an access violation" else "a page fault";
			action := ExceptionRecord.ExceptionInformation[0];
			ptr := ExceptionRecord.ExceptionInformation[1];

			if (!ptr) {
				log("The program crashed because it tried to % %", ifx action "write to" else "read from", "a null pointer.");
			} else {
				if (action == 0) || (action == 1) {
					log("The program crashed because of % %", exception, ifx action == 0 "reading location 0x" else "writing location 0x");
				} else {
					log("The program crashed because of % %", exception, ifx action == 8 "(user-mode data execution prevention)", "at location 0x");
				}

				write_nonnegative_number(ptr, base=16, to_standard_error = true);

				in_program_section, read_only, section_name := is_ptr_in_program_section (cast (*void) ptr);

				if in_program_section {
					log("This address is in the %section % of the program", ifx read_only "read only " else "", section_name);

					if read_only {
						log("A common mistake is to write to a constant string or array, which is put by the compiler in a read only section of the program.");
					}
				}
			}

		case EXCEPTION_ARRAY_BOUNDS_EXCEEDED;
			log("The program crashed because of a non user level array bounds check failure.");
		case EXCEPTION_BREAKPOINT;
			log("A breakpoint was hit, but no debugger is attached.");
		case EXCEPTION_DATATYPE_MISALIGNMENT;
			// I don't think this can really happen on modern hardware, but let's handle it anyway
			log("The program crashed because of a datatype misalignment.");
		case EXCEPTION_FLT_INVALID_OPERATION;
			log("The program crashed because of a floating point exception.");
		case EXCEPTION_ILLEGAL_INSTRUCTION;
			log("The program crashed because the thread tried to execute an invalid instruction.");
		case EXCEPTION_INT_DIVIDE_BY_ZERO;
			log("The program crashed because of an integer division by zero error.");
		case EXCEPTION_PRIV_INSTRUCTION;
			log("The program crashed because it tried to execute an unauthorized instruction.");
		case EXCEPTION_STACK_OVERFLOW;
			log("The program crashed because of a stack overflow.");
		case;
			log("The program crashed.");
		}

		// This condition is here to avoid printing both the user-level stack trace and OS provided stack trace
		// (i.e. assertion failures will print the stack trace, and trigger a breakpoint which we handle here)
		if !__runtime_support_disable_stack_trace {
			RtlCaptureContext :: (ContextRecord: *CONTEXT) #foreign kernel32;
			RtlCaptureContext(*windows_context);

			// In some cases of stack overflow (i.e. infinite recursion), printing the stack trace crashes the program
			if ExceptionRecord.ExceptionCode == EXCEPTION_STACK_OVERFLOW
				log("Printing the stack trace (this may fail when a stack overflow occurred):");
			else
				log("Printing the stack trace:");
			backtrace(*windows_context, 6);
		}

		// Before we terminate we want to make a folder Crashes/<timestamp>/ and then copy the log file to it.
		make_time_string :: (ct: Calendar_Time) -> string /* Temporary_Storage */ {
			using ct;

			date_part :: #bake_arguments formatInt(minimum_digits = 2);

			timezone_name := ifx ct.time_zone == .UTC then "Z" else ""; // @Incomplete: Maybe determine local time zone name or offset

			time_string := tprint("%_%_%T%-%-%-%0%", year, date_part(month_starting_at_0 + 1), date_part(day_of_month_starting_at_0 + 1), date_part(hour), date_part(minute), date_part(second), formatInt(millisecond, minimum_digits = 3), timezone_name);
			return time_string;
		}
		crashDirectory := tprint("%/crashes/%", path_strip_filename(get_path_of_running_executable()), make_time_string(to_calendar(current_time_consensus())));
		make_directory_if_it_does_not_exist(crashDirectory, recursive=true);
		copy_file(tprint("%/photon.log", path_strip_filename(get_path_of_running_executable())), tprint("%/photon.log", crashDirectory));

		// This should terminate the process and set the error exit code.
		TerminateProcess :: (hProcess: *void, uExitCode: u32) -> s32 #foreign kernel32;
		TerminateProcess(CurrentProcess, 1);  // We are not being picky about exit codes currently.

		EXCEPTION_EXECUTE_HANDLER :: 1;
		return EXCEPTION_EXECUTE_HANDLER;   // Terminate the program, in case TerminateProcess did not succeed.
	}
} @NoProfile

