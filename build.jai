#import "Basic";
#import "Compiler";
#import "File";
#import "String";
#import "File_Utilities";
Compiler :: #import "Compiler";
#import "Windows_Resources";
#import "Metaprogram_Plugins";

#if OS == .WINDOWS {
    Windows_Resources :: #import "Windows_Resources";
    Ico_File :: #import "Ico_File";
}


BuildType :: enum u8
{
	DEBUG;
	OPTIMIZED_DEBUG;
	SHIPPING;
}

BUILD_DEBUG_DIR :: "build/debug";
BUILD_OPTIMIZED_DEBUG_DIR :: "build/optimized";
BUILD_SHIPPING_DIR :: "build/shipping";

Build :: ()
{
    w := compiler_create_workspace();

	// @todo, create build output when it does not exist
    target_options := get_build_options(w);
    args := target_options.compile_time_command_line;
    
    set_working_directory(#filepath);
	target_options.output_executable_name = "Photon";
	set_build_options(target_options, w);
	set_build_options_dc(.{do_output=false});
    
	buildType: BuildType = .DEBUG;
    for arg: args
    {
    	if arg ==
    	{
    		case "-optimized_debug";
    			buildType = .OPTIMIZED_DEBUG;
    		case "shipping"; // use like jai build.jai - shipping
    			buildType = .SHIPPING;
    	}
    }


    intercept_flags: Intercept_Flags;
	res, pluginsToCreate, remaining := parse_plugin_arguments(args);
	plugins : [..]*Metaprogram_Plugin;
	init_plugins(pluginsToCreate, *plugins , w);
    for plugins if it.before_intercept it.before_intercept(it, *intercept_flags);
    
	Compiler.compiler_begin_intercept(w, intercept_flags);

	if buildType == {
		case .DEBUG;
			make_directory_if_it_does_not_exist(BUILD_DEBUG_DIR, recursive=true);
		    target_options := get_build_options(w);
		    target_options.backend =.X64; 
		    target_options.output_path = BUILD_DEBUG_DIR;
		    set_optimization(*target_options, Optimization_Type.DEBUG, true);
		    set_build_options(target_options, w);
		    add_build_string("BUILD_TYPE :: BuildType.DEBUG;", w);
		case .OPTIMIZED_DEBUG;
			make_directory_if_it_does_not_exist(BUILD_OPTIMIZED_DEBUG_DIR, recursive=true);
		    target_options := get_build_options(w);
		    target_options.backend = .LLVM;
		    target_options.output_path = BUILD_OPTIMIZED_DEBUG_DIR;
		    set_optimization(*target_options, Optimization_Type.VERY_OPTIMIZED);   
		    set_build_options(target_options, w);
		    add_build_string("BUILD_TYPE :: BuildType.OPTIMIZED_DEBUG;", w);
		case .SHIPPING;
			make_directory_if_it_does_not_exist(BUILD_SHIPPING_DIR, recursive=true);
		    target_options := get_build_options(w);
		    target_options.backend = .LLVM;
		    target_options.output_path = BUILD_SHIPPING_DIR;
		    // target_options.emit_debug_info=.NONE; // @todo: we output debug info in shipping builds for crash reports, any way around that?
		    target_options.enable_bytecode_inliner = true;
		    set_optimization(*target_options, Optimization_Type.VERY_OPTIMIZED);   
		    set_build_options(target_options, w);
		    add_build_string("BUILD_TYPE :: BuildType.SHIPPING;", w);
	}
	add_build_string("BuildType :: enum u8 { DEBUG; OPTIMIZED_DEBUG; SHIPPING; }", w);
    
    for plugins      if it.add_source it.add_source(it);
    add_build_file("source/main.jai", w);
    
	// wait for compilation to finish so we can edit the exe
	while true {
		message := Compiler.compiler_wait_for_message();
        for plugins if it.message it.message(it, message);
		if message.kind == .COMPLETE break;
	}
	Compiler.compiler_end_intercept(w);

    for plugins if it.finish   it.finish  (it);
    for plugins if it.shutdown it.shutdown(it);

	// Edit the exe and do any other bits we need
	build_opts := get_build_options(w);
	exe_name := sprint("%/%.exe", build_opts.output_path, target_options.output_executable_name);
	defer free(exe_name);

	ico_data := Ico_File.create_ico_file_from_bitmap_filename("photon.png");
	defer free(ico_data);
	Windows_Resources.set_icon_by_data(exe_name, ico_data);

	manifest_options: Windows_Resources.Manifest_Options;
	success := Windows_Resources.add_manifest_to_executable(exe_name, manifest_options);
	if !success {
        log_error("ERROR: Couldn't add manifest to executable '%'\n", exe_name);
    }

	// copy stuff to output
	copy_file("modules/treesitter/windows/treesitter.dll", tprint("%/treesitter.dll", build_opts.output_path));
	copy_file("modules/treesitter/windows/treesitter.pdb", tprint("%/treesitter.pdb", build_opts.output_path));

	if buildType == .SHIPPING {
		copy_directory("fonts", tprint("%/fonts", BUILD_SHIPPING_DIR));
	    visitor :: (info: *File_Visit_Info, args: *void) {
	        if info.is_directory {
                info.descend_into_directory = false;
				return;
            }
			if path_extension(info.full_name) == "dll" {
		        copy_file(info.full_name, tprint("%/grammars/%", BUILD_SHIPPING_DIR, info.short_name));
			}
	    }

	    make_directory_if_it_does_not_exist(tprint("%/grammars", BUILD_SHIPPING_DIR));
	    visit_files("grammars", true, null, visitor, visit_directories = true);

		copy_directory("queries", tprint("%/queries", BUILD_SHIPPING_DIR));
	}
}

#run,stallable Build();
