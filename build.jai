#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
Compiler :: #import "Compiler";

#if OS == .WINDOWS {
    Windows_Resources :: #import "Windows_Resources";
    Ico_File :: #import "Ico_File";
}

BUILD_DEBUG_DIR :: "run/debug";
BUILD_OPTIMIZED_DIR :: "run/optimized";
BUILD_RELEASE_DIR :: "run/release";

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
    
	// @todo: config which produces a shipping packaged build
	build_optimized := false;
	build_release := false;
    for arg: args
    {
    	if arg ==
    	{
    		case "optimized";
    			build_optimized = true;
    		case "release";
    			build_release = true;
    	}
    }
    
    // There are 3 target types in this program :
    // 	- Debug : Not optimized and has debug info
    // 	- Optimized : Optimized and has debug info
    // 	- Release : Very optimized and doesn't have debug info
	Compiler.compiler_begin_intercept(w);
    if build_release then BuildRelease(w);
    else if build_optimized then BuildOptimized(w);
    else BuildDebug(w);
    
    add_build_file("source/main.jai", w);
    
	// wait for compilation to finish so we can edit the exe
	while true {
		message := Compiler.compiler_wait_for_message();
		if message.kind == .COMPLETE break;
	}
	Compiler.compiler_end_intercept(w);

	// Edit the exe and do any other bits we need
	#if OS == .WINDOWS {
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

		// copy dlls
		copy_file("modules/treesitter/windows/treesitter.dll", tprint("%/treesitter.dll", build_opts.output_path));
	}
}

BuildDebug :: (w: Workspace)
{
    target_options := get_build_options(w);
    target_options.backend =.X64; 
    target_options.output_path = BUILD_DEBUG_DIR;
    set_optimization(*target_options, Optimization_Type.DEBUG, true);
    set_build_options(target_options, w);
    add_build_string("BUILD_TYPE :: BuildType.DEBUG;", w);
}

BuildOptimized :: (w: Workspace)
{
    target_options := get_build_options(w);
    target_options.backend = .X64;
    target_options.output_path = BUILD_OPTIMIZED_DIR;
    set_optimization(*target_options, Optimization_Type.OPTIMIZED);   
    set_build_options(target_options, w);
    add_build_string("BUILD_TYPE :: BuildType.OPTIMIZED;", w);
}

BuildRelease :: (w: Workspace)
{
    target_options := get_build_options(w);
    target_options.backend = .LLVM;
    target_options.output_path = BUILD_RELEASE_DIR;
    target_options.emit_debug_info=.NONE;
    target_options.enable_bytecode_inliner = true;
    set_optimization(*target_options, Optimization_Type.VERY_OPTIMIZED);   
    set_build_options(target_options, w);
    add_build_string("BUILD_TYPE :: BuildType.RELEASE;", w);
}

#run Build();
