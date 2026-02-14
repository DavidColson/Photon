
#run build();

SOURCE_PATH :: "src";
LIB_BASE_NAME :: "treesitter";

build :: () {
	set_build_options_dc(.{do_output=false});

    #if OS == {
        case .WINDOWS;
            libDirectory := "windows";
        case .LINUX;
            libDirectory := "linux";
        case .MACOS;
            libDirectory := "macos";
        case;
            #assert false;
    }

	options := get_build_options();
	
    includePaths := string.[
        "src",
        "src/wasm",
        "include"
    ];

    extraArgs: [..] string;
    array_add(*extraArgs,
        "-D_POSIX_C_SOURCE=200112L",
        "-D_DEFAULT_SOURCE"
    );
    #if OS == .WINDOWS {
	    array_add(*extraArgs,
             "/wd4018", // disable 'signed/unsigned mismatch'
             "/wd4232", // disable 'nonstandard extension used'
             "/wd4244", // disable 'possible loss of data'
             "/wd4267", // disable 'possible loss of data (size_t)'
             "/wd4701", // disable 'potentially uninitialized local variable'
             "/we4022", // treat 'incompatible types' as an error
             "/MD",
             "/Zi",
             "/W3");
        for includePaths {
            array_add(*extraArgs, tprint("/I%/%", SOURCE_PATH, it));
        }
    } else {
        array_add(*extraArgs, "-std=c11", "-Wall", "-Wextra", "-Wshadow", "-Wpedantic", "-Werror=incompatible-pointer-types");
        for include_paths {
            array_add(*extraArgs, tprint("-I%/%", SOURCE_PATH, it));
        }
    }
	
    make_directory_if_it_does_not_exist(libDirectory, recursive = true);
    libPath := tprint("%/%", libDirectory, LIB_BASE_NAME);
	success := build_cpp_dynamic_lib(libPath, tprint("%/src/lib.c", SOURCE_PATH), debug=false, extra=extraArgs);

	if !success {
		compiler_set_workspace_status(.FAILED);
		return;
	}

	if !generate_bindings() {
		compiler_set_workspace_status(.FAILED);
		return;
	}
}

generate_bindings :: () -> bool {
	outputFilename: string;
	libDirectory: string;
    opts: Generate_Bindings_Options;
    {
        using opts;

        #if OS == .WINDOWS {
            outputFilename = "windows.jai";
            libDirectory = "windows";
            strip_flags = 0;
        } else #if OS == .LINUX {
            outputFilename = "linux.jai";
            libDirectory = "linux";
            strip_flags = 0;
        } else #if OS == .MACOS {
            outputFilename = "macos.jai";
            libDirectory = "macos";
            strip_flags = 0;
        } else {
            assert(false);
        }

		log_stripped_declarations = true;
		generate_library_declarations = true;
        array_add(*library_search_paths,  libDirectory);
        array_add(*libraries,      .{filename="treesitter"});
        array_add(*source_files,  tprint("%/include/tree_sitter/api.h", SOURCE_PATH));
        array_add(*extra_clang_arguments, "-x", "c++", "");
	}
    return generate_bindings(opts, outputFilename);
}

#scope_file

#import "Basic";
#import "Compiler";
#import "BuildCpp";
#import "Check";
#import "Bindings_Generator";
#import "File";
