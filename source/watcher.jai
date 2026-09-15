
// File watching has been one of the most difficult aspects of photon to get right
// Various other applications edit files in very strange ways, for example by renaming a file
// writing the new content to a new file, renaming the new file, and then deleting the original file
// Or changing a git branch for example will delete whole directories, and then immediately add them back again
// To resolve these various issues this file watching system will listen for all events for a given path
// and then merge them into one singular event and dispatch to either the document handlers, or to the project system
// which will usually inspect the file on disk to decide what to do with it. This happens only once after all changes have come in 
// for a frame so that we can ignore the various internal changes that happen
// We also have various extra handling for directories within projects to make sure they are handled correctly

// It's worth remembering that projects are intended to be in-memory caches of what is on disk, they are supposed to match
// exactly, whereas documents are not like this, they are open documents that exist separate to what is on disk, so we may treat them 
// quite differently

projectWatcher: File_Watcher(void);
documentWatcher: File_Watcher(void);

WatcherChange :: struct {
	path: string; // copied out of the watcher's pool, into temp; valid for this frame only
	events: File_Change_Event;
}
watcherBatch: [..]WatcherChange;
watchedProjectDirs: [..]string;
watchedDocumentDirs: [..]string;

watcher_init :: () {
	if !init(*projectWatcher, file_watcher_callback, watch_recursively = true, event_buffer_size = 64 * 1024) {
		push_notification("Could not initialize the file watcher. Files won't be reloaded. This is likely a bug.");
	}
	if !init(*documentWatcher, file_watcher_callback, watch_recursively = false) {
		push_notification("Could not initialize the file watcher. Files won't be reloaded. This is likely a bug.");
	}
}

watcher_update :: () {
	projectChanged, projectWaiting := process_changes(*projectWatcher);
	documentChanged, documentWaiting := process_changes(*documentWatcher);

	if projectChanged || projectWaiting || documentChanged || documentWaiting {
		requestRedraw = true;
	}

	reconcile_watcher_batch();
}

file_watcher_callback :: (watcher: *File_Watcher(void), change: *File_Change, userdata: *void) {
	entry := array_add(*watcherBatch);
	entry.path = copy_string(change.full_path,,temp);
	entry.events = change.events;
}

reconcile_watcher_batch :: () {
	if watcherBatch.count == 0 return;
	defer array_reset_keeping_memory(*watcherBatch);

	merged: Table(string, WatcherChange, given_compare_function=platform_path_equal, given_hash_function=platform_path_hash);
	merged.allocator = temp;

	for watcherBatch {
		found, existing := table_find(*merged, it.path);
		if found  table_set(*merged, existing.path, .{ existing.path, existing.events | it.events });
		else      table_add(*merged, it.path, it);
	}

	for change: merged {
		exists, isDirectory := platform_path_stat(change.path);

		if exists && isDirectory {
			reconcile_directory(change.path, change.events);
			continue;
		}

		reconcile_file(change.path);

		// If a folder disappeared below us, we won't get events for all the files
		// inside that directory, so we have to scan the whole path again
		if !exists  reconcile_paths_under(change.path);
	}
}

reconcile_file :: (path: string) {
	found, handle := document_get_by_path(path);
	if found  reconcile_document(handle);
	else      reconcile_project_entry(path);
}

reconcile_directory :: (path: string, events: File_Change_Event) {
	// SCAN_CHILDREN is the only event we actually listen to because 
	// it's generally a warning that some information was lost and you umst rescan the path
	// to get all the new information you may have missed
	if events & .SCAN_CHILDREN {
		if is_watched_root(path) {
			reconcile_paths_under(path);
		}
		else {
			// Windows reports a change it could not attribute, typically a child being renamed, as
			// a modification of the parent directory.
			for file_list(path, recursive = false,,temp) {
				reconcile_file(it);
			}
		}
	}

	// This case is for a directory that just appeared in one of our tracked paths
	// We'll first reconcile, and then scan to add any new files we weren't already tracking to the project
	// We reconcile because for example a git branch switch could report as a whole directory being deleted
	// and then suddenly being added again
	if events & (.ADDED | .MOVED_TO) {
		reconcile_paths_under(path);
		project_scan_directory(path);
	}
}

reconcile_paths_under :: (dir: string) {
	// This is intended to reconcile files we already track under the given directory
	for doc: openDocuments {
		if path_is_within(document_get_path(doc), dir)  reconcile_document(doc);
	}

	if !project_is_loaded() return;

	paths: [..]string;
	paths.allocator = temp;
	for locator, filePath: project.projectFileTable {
		if path_is_within(filePath, dir)  array_add(*paths, filePath);
	}
	for paths  reconcile_project_entry(it);
}

normalize_watch_directory :: (dir: string) -> string {
	result := ifx is_absolute_path(dir) then copy_string(dir,,temp) else copy_string(get_absolute_path(dir),,temp);
	path_overwrite_separators(result, #char "/");

	isDriveRoot := result.count == 3 && result[1] == #char ":";
	while !isDriveRoot && result.count > 1 && result[result.count-1] == #char "/" {
		result.count -= 1;
	}
	return result;
}

watch_project_directory :: (dir: string) {
	normalized := normalize_watch_directory(dir);
	for watchedProjectDirs  if path_is_within(normalized, it) return;

	stored := copy_string(normalized);
	array_add(*watchedProjectDirs, stored);
	log("Watching project folder % (recursively)", stored);
	if !add_directories(*projectWatcher, stored) {
		log_error("Could not watch project folder %. Changes in it will not be picked up.", stored);
	}
}

watch_document_directory :: (dir: string) {
	normalized := normalize_watch_directory(dir);
	// anything under a project folder is already covered by the recursive project watcher
	for watchedProjectDirs  if path_is_within(normalized, it) return;
	for watchedDocumentDirs  if platform_path_equal(normalized, it) return;

	stored := copy_string(normalized);
	array_add(*watchedDocumentDirs, stored);
	log("Watching folder % for open documents", stored);
	if !add_directories(*documentWatcher, stored) {
		log_error("Could not watch folder %. Changes to files in it will not be picked up.", stored);
	}
}

watch_directory_for_document :: (documentPath: string) {
	watch_document_directory(path_strip_filename(documentPath));
}

is_watched_root :: (path: string) -> bool {
	for watchedProjectDirs   if platform_path_equal(path, it) return true;
	for watchedDocumentDirs  if platform_path_equal(path, it) return true;
	return false;
}

path_is_within :: (path: string, dir: string) -> bool {
	if dir.count == 0 return false;
	if path.count < dir.count return false;

	for 0..dir.count-1 {
		if path_compare_char(path[it]) != path_compare_char(dir[it]) return false;
	}

	if path.count == dir.count return true;
	// a drive root keeps its trailing slash, so it already ends on a component boundary
	if dir[dir.count-1] == #char "/" || dir[dir.count-1] == #char "\\" return true;
	return path[dir.count] == #char "/" || path[dir.count] == #char "\\";
}

path_compare_char :: inline (c: u8) -> u8 {
	if c == #char "\\" return #char "/";
	if c >= #char "A" && c <= #char "Z" return c + 32;
	return c;
}
