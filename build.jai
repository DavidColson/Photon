#import "Basic";
#import "Compiler";
#import "File";
#import "String";
#import "File_Utilities";
Compiler :: #import "Compiler";
#import "Windows_Resources";
#import "Metaprogram_Plugins";
#import "Hash_Table";
#import "Program_Print";

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
	w := compiler_create_workspace("Photon");

	// @todo, create build output when it does not exist
	target_options := get_build_options(w);
	args := target_options.compile_time_command_line;
    
	set_working_directory(#filepath);
	target_options.output_executable_name = "Photon";
	set_build_options(target_options, w);
	set_build_options_dc(.{do_output=false});
    
	buildType: BuildType = .DEBUG;
	for arg: args {
		if arg == {
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
	
	compiler_message_handler(w, *plugins);
    
	Compiler.compiler_end_intercept(w);

	for plugins if it.finish   it.finish  (it);
	for plugins if it.shutdown it.shutdown(it);

	// Compilation is finished now
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

compiler_message_handler :: (w: Workspace, plugins: *[..]*Metaprogram_Plugin) {
	normalModeCommands : [..]*Code_Procedure_Header;
	insertModeCommands : [..]*Code_Procedure_Header;
	dialogModeCommands : [..]*Code_Procedure_Header;
	options: [..]*Code_Declaration;
	commandsGenerated := false;
	
	while true {
		message := Compiler.compiler_wait_for_message();
		
		for (.*)plugins if it.message it.message(it, message);
		
		if message.kind == {
		case .TYPECHECKED;
			typechecked := cast(*Message_Typechecked)message;
			for typechecked.procedure_headers {
				expr := it.expression;
				for expr.notes {
					if it.text == "command_normal" {
						array_add(*normalModeCommands, expr);
					}
					if it.text == "command_insert" {
						array_add(*insertModeCommands, expr);
					}
					if it.text == "command_dialog" {
						array_add(*dialogModeCommands, expr);
					}
				}
			}
			for typechecked.declarations {
				expr := it.expression;
				for expr.notes {
					if it.text == "option" {
						array_add(*options, expr);
					}
				}
			}
			
		case .PHASE;
			phase := cast(*Message_Phase) message;
			if phase.phase == .TYPECHECKED_ALL_WE_CAN {
				if !commandsGenerated {
					
					builder: String_Builder;
					init_string_builder(*builder);
					
					append(*builder, "register_options :: () {\n");
					
					// generation options
					// TODO: check the type of the argument and error if invalid
					for options {
						if it.flags & .IS_CONSTANT {
							log_error("A constant declaration cannot be an option.");
							continue;
						}
						append(*builder, tprint("	table_add(*optionsTable, \"%1\", .{*%1, type_info(", it.name));
						print_expression(*builder, it.type_inst);
						append(*builder, ")});\n");
					}
					
					append(*builder, "};\n");
					
					
					// this will be static data
					append(*builder, "normalModeCommands2 :: Command2.[\n");
					generate_command_data(*builder, *normalModeCommands);
					append(*builder, "];\n");
					append(*builder, "insertModeCommands2 :: Command2.[\n");
					generate_command_data(*builder, *insertModeCommands);
					append(*builder, "];\n");
					append(*builder, "dialogModeCommands2 :: Command2.[\n");
					generate_command_data(*builder, *dialogModeCommands);
					append(*builder, "];\n");
					
					// make all commands list
					append(*builder, "allCommands2 :: []Command2.[\n");
					append(*builder, "    normalModeCommands2,\n");
					append(*builder, "    insertModeCommands2,\n");
					append(*builder, "    dialogModeCommands2,\n");
					append(*builder, "];\n");
					
					
					
					code := builder_to_string(*builder);
					add_build_string(code, w);
					commandsGenerated = true;
				}
			}
		case .COMPLETE;
			break;
		}
	}
}

generate_command_data :: (builder: *String_Builder, commands: *[..]*Code_Procedure_Header)  {
	// TODO: this breaks the syntax tree somehow
	// append(*builder, "    // Cvars\n");
	
	node_to_string :: (type: *Code_Node) -> string {
		push_allocator(temp);
		builder: String_Builder;
		init_string_builder(*builder);
		print_expression(*builder, type);
		return builder_to_string(*builder);
	}
	
	for header: (.*)commands {
		append(builder, "    .{\n");
		append(builder, tprint("       \"%\",\n", header.name));
		
		// generate the list of args
		append(builder, "        .[\n");
		for arg, argIndex: header.arguments {
			if argIndex == 0 then continue;
			append(builder, "            ");
			append(builder, tprint(".{\"%\", type_info(", arg.name));
			arg_type := arg.type_inst;
			print_expression(builder, arg_type);
			append(builder, ")},\n");
		}
		append(builder, "        ],\n");
		
		// generate the wrapper function
		append(builder, "        (panel: *Panel, args: []*void) {\n");
		append(builder, tprint("            assert(args.count == %);\n", header.arguments.count - 1));
		
		append(builder, tprint("            %(\n", header.name));
		for arg, argIndex: header.arguments {
			append(builder, "                ");
			
			argTypeInfo := arg.type_inst.result;
			
			if argIndex == 0 {
				// We want to verify the first argument of all commands is actually a panel
				firstArgIsPanel := false;
				if argTypeInfo.type == .POINTER {
					pointer := cast(*Type_Info_Pointer)argTypeInfo;
					if pointer.pointer_to.type == .STRUCT {
						structInfo := cast(*Type_Info_Struct) pointer.pointer_to;
						if structInfo.name == "Panel" {
							firstArgIsPanel = true;
						}
					}
				}
				if !firstArgIsPanel then compiler_report(arg.enclosing_load.fully_pathed_filename, arg.l0, arg.c0, "The first argument of a command must be of type \"*Panel\"");
				append(builder, "panel,\n");
			}
			else {
				append(builder,    "cast(*");
				
				if argTypeInfo.type != .INTEGER &&
				argTypeInfo.type != .FLOAT &&
				argTypeInfo.type != .BOOL &&
				argTypeInfo.type != .ENUM &&
				argTypeInfo.type != .STRING {
					compiler_report(arg.enclosing_load.fully_pathed_filename, arg.l0, arg.c0, "Unsupported argument type in command");
				}
				
				print_expression(builder, arg.type_inst);
				append(builder, tprint(", args[%]).*,\n", argIndex-1));
			}
		}
		append(builder, "            );\n");
		append(builder, "        },\n");
		
		// Pull out and place the config structure
		body := header.body_or_null;
		block := body.block;
		for statement: block.statements {
			// we expect some of these to be declarations
			if statement.kind == .DECLARATION {
				declaration := cast(*Code_Declaration, statement);
				if declaration.flags & .IS_CONSTANT && declaration.name == "CONFIG" {
					log("Found CONFIG with name %\n%", declaration.name, node_to_string(declaration));
					append(builder,        "        ");
					print_expression(builder, declaration.expression);
				}
			}
		}
		
		append(builder, "\n");
		append(builder, "    },\n");
	}
	
}

#run,stallable Build();
