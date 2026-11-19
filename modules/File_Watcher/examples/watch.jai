Args :: struct {
    delay: float = 1.0; // Big default delay so you can clearly see events being coalesced.
    verbose: bool;
}

main :: () {
    success, args, is_set, dirs_to_watch := parse_arguments(Args);
    if !success exit(1);

    if !dirs_to_watch {
        log_error("You need to provide one or more directory paths to watch.");
        exit(2);
    }

    watcher: File_Watcher(string);
    if !init(*watcher, file_change_callback, *"Cowabunga", events_to_watch = .ALL_EVENTS, merge_window_seconds = args.delay, verbose = args.verbose) {
        log_error("Could not initialize watcher");
        exit(3);
    }
    defer deinit(watcher); // Won't trigger here since we never return, but you might want to do this in your program.

    log("Adding root folders: %", dirs_to_watch);
    if !add_directories(*watcher, ..dirs_to_watch) {
        log_error("Could not watch directories %", dirs_to_watch);
        exit(4);
    }

    log("Starting to check for changes...");

    while true {
        changed, needs_wait, wait_seconds := process_changes(*watcher);
        reset_temporary_storage();

        // Normally you'd either call this as part of your main loop
        // or on Linux use poll() + a timer (if needs_wait was set) to sleep until something changes.
        // See the dcoumentation of process_changes for details.
        //
        // But we’re just kinda busy-looping in this example.
        sleep_milliseconds(100);
    }
}

file_change_callback :: (watcher: *File_Watcher(string), change: *File_Change, user_data: *string) {
    log("Change for path %: % (user_data points to %)", change.full_path, change.events, user_data.*);
}

#import "Basic";
#import "File_Watcher";
#import "Command_Line";
