
// @todo: once this replaces the old document system it will be renamed to just "Document"
Document :: struct {

	Piece :: struct {
		start: BufferCursor;
		end: BufferCursor;
		length: s64;
		lineFeedCount: s64;
		bufferIndex: u8;
	}

	Buffer :: struct {
		text: []u8;
		lineStarts: [..]s64;
	}

	BufferCursor :: struct {
		line: s64;
		column: s64;
	}

	NodeData :: struct {
		piece: Piece;
		leftSubtreeLength : s64;
		leftSubtreeLfCount : s64;
	}

	Node :: struct {
		allocator: Allocator;
		color: Color;
		using data: NodeData;
		left: *Node;
		right: *Node;
		#place left;
		child :[2]*Node = ---;
	}

	Color :: enum {
		RED;
		BLACK;
	}

	LineEndingMode :: enum {
		CRLF;
		LF;
		MIXED_MAJORITY_LF;
		MIXED_MAJORITY_CRLF;
	}

	LineContent :: struct {
		text: string;
		startByteOffset: s64;
		endByteOffset: s64;
	}

	Coordinate :: struct {
		line: s64;
		col: s64;
	}

	LineIterator :: struct {
		doc: *Document;
		line: s64;
		endLine: s64;
		node: *Node;
		lineNumInNode: s64;
		nodeStartOffset: s64;
		stack: [..]*Node;
		direction: IterateDirection;
		lineBuffer: [..]u8;
		lineContent: LineContent;
	}

	Iterator :: struct {
		doc: *Document;
		offset: s64;
		node: *Node;
		stack: [..]*Node;
		firstChar: *u8;
		lastChar: *u8;
		direction: IterateDirection;
	}

	IterateDirection :: enum {
		REVERSE;
		FORWARD;
	}

	Range :: struct {
		start: s64;
		end: s64;
	}

	SearchType :: enum {
		STANDARD;
		NOCASE;
		REGEX;
	}

	tree: *Node;
	buffers: [2]Buffer;
	lastInsert: BufferCursor;
	lineEndings: LineEndingMode;
	path: string;
	diskLastModtime: Apollo_Time;
	locator: Bucket_Locator;
	language: string;
	longestLine: s32;
	longestLineLength: s32;
	isCopy: bool;
	tsTree: *TSTree;

	// managed by async thread, do not touch
	// unfortunately due to incremental parsing, we must retain the parser
	// and tree state between each successive reparse
	// so if there are many edits within a frame, we need to use the most up
	// to date parser and ts tree for every parse task on the async thread
	// at the end of each async job we'll copy asyncTsTree to the actual tsTree
	// for use on the main thread
	asyncParser: *TSParser;
	asyncTsTree: *TSTree;

	// Undo
	// need to store an array of tree pointers basically
	// which you can just replace the tree in the document with as you go back and forth in time

	UndoEntry :: struct {
		tree: *Node;
		offset: s64;
		longestLine: s32;
		longestLineLength: s32;
		saved: bool;
	}
	
	undoStack: [..]UndoEntry;
	redoStack: [..]UndoEntry;
	nextUndoOffset: s64 = -1;

	// [ ] - Make a new_undo_event function which will save the current tree to the stack
	//		 This will be called before anyone makes an edit
	// [ ] - Make an undo function which will push the current tree onto the redo stack,
	//       and then replace it with a tree from the undo stack
	// [ ] - Make a redo function which does the opposite
	// [ ] - Inject undo events everwhere that is appropriate

	// Note it will not be threadsafe to share these pools
	// Between copies of the tree and allow any allocation
	treeMemory: Flat_Pool;
	bufferMemory: Flat_Pool;
	otherMemory: Flat_Pool;
}

open_documents: Bucket_Array(Document, 128); // might want more when we load full projects in?
open_document_table: Table(string, Bucket_Locator);

tree_test :: () {
	doc := document_open("build_shorter.jai");

	pretty_print_tree(doc.tree);

	insert(doc, 100, "hello world");
	insert(doc, 105, " my");
	pretty_print_tree(doc.tree);

	// trivial copies
	copy := document_copy(doc);
	log("size from view before edit: %", get_size(copy));

	insert(doc, 110, "test ");
	insert(doc, 200, "again more");

	pretty_print_tree(doc.tree);

	// copies again, but without edit
	log("size of doc %, size of view %", get_size(doc), get_size(copy));
	document_copy_free(copy);

	// iterator
	
	iterator := make_iterator(doc, 0);
	for iterator {
		print("%", string.{1, *it});
	}

	// reverse iteration
	iterator = make_reverse_iterator(doc, 109);
	for iterator {
		if it_index == 10 break;
		print("%", string.{1, *it});
	}
	print("\n");

	// for comparison, the same region forward
	iterator = make_iterator(doc, 100);
	for iterator {
		if it_index == 10 break;
		print("%", string.{1, *it});
	}
	print("\n");

	count := 0;
	iterator = make_iterator(doc, 0);
	while iterator.node != null {
		log("Index: %, nodeLen %", count, iterator.node.piece.length);
		next_node(*iterator);
		count += 1;
	}

	char1 := get_char_at(doc, 101);
	char2 := get_char_at(doc, 113);
	char3 := get_char_at(doc, 3);
	log("char1 %", string.{1, *char1});
	log("char2 %", string.{1, *char2});
	log("char3 %", string.{1, *char3});

	log("num lines %", get_number_of_lines(doc));

	// line starts
	log("line start 0, %", get_line_start(doc, 0));
	log("line start 1, %", get_line_start(doc, 1));
	log("line start 2, %", get_line_start(doc, 2));
	log("line start 3, %", get_line_start(doc, 3));

	// line ranges
	start, end := get_line_range(doc, 2, false);
	log("line range for line 2 %, %", start, end);

	coord := get_coordinate_from_offset(doc, 100);
	log("from offset 100 we get (%,%)", coord.line, coord.col);

	// get content

	log("second line: %", get_line_content(doc, 1));
	log("at 100, 10 chars: %", get_content(doc, 100, 10));

	// deletions
	delete(doc, 130, 19);


	
	
	pretty_print_tree(doc.tree);

	iterator = make_iterator(doc, 0);
	for iterator {
		print("%", string.{1, *it});
	}
}

// Document API

document_open :: (path: string) -> *Document {
	// check if this file is already open
	success, existinglocator := table_find_new(*open_document_table, path);
	if success {
		bucket := open_documents.all_buckets[existinglocator.bucket_index];
		assert(bucket.occupied[existinglocator.slot_index] == true);
		return *bucket.data[existinglocator.slot_index];
	}

	// check if the file even exists
	if !file_exists(path) {
		push_notification("File Does Not Exist");
		return null;
	}

	doc, locator := find_and_occupy_empty_slot(*open_documents);

	if is_absolute_path(path) {
		doc.path = copy_string(path);
	}
	else {
		doc.path = copy_string(get_absolute_path(path));
	}
	path_overwrite_separators(doc.path, #char "/");

	// Setup document language and parsing
	doc.language = path_extension(doc.path);
	language: *Language;
	success, language = get_language(doc.language);
	if !success {
		log("No language support for file '%' with language '%'", doc.path, doc.language);
	}
	else {
		doc.asyncParser = ts_parser_new();
		if !ts_parser_set_language(doc.asyncParser , language.treesitterLang) {
			log("Language ABI mismatch: Language(%) is % and treesitter is %", doc.language, TREE_SITTER_LANGUAGE_VERSION, ts_language_abi_version(language.treesitterLang));
		}

		tsVerboseLogging := false;
		if tsVerboseLogging {
			treesitter_logger :: (payload: *void, log_type: TSLogType, buffer: *u8) #c_call {
			    push_context {
			        log("%", to_string(buffer));
			    }
			}
			ts_parser_set_logger(doc.asyncParser , .{null, treesitter_logger});
		}
	}

	doc.locator = locator;
	table_add(*open_document_table, doc.path, doc.locator); 

	document_load_from_disk(doc);

	// add to file watcher
	parentPath := path_strip_filename(doc.path);
	if parentPath.count > 1 && parentPath[parentPath.count-1] == #char "/" then parentPath.count -= 1;
	add_directories(*watcher, parentPath);
	array_add_if_unique(*watchedFiles, doc.path);

	return doc;
}

document_load_from_disk :: (doc: *Document) {
	TaskData :: struct {
		originalDocument: *Document;
		workingDocument: *Document;
		result: Result;
		Result :: enum {
			IN_PROGRESS;
			SUCCESS;
			FAILED_TO_READ_FILE_DATA;
			FAILED_TO_OPEN_FILE_FOR_WRITE;
		}
	}
	load_from_disk_task :: (data: *void) {
		// @todo: I'm mildly uncomfortable with the memory management happening here with file loading
		// particularly because we must keep the original file in memory briefly while loading the new one
		// Additionally the undo tree memory is not part of the pools so it can be hard to track
		// at some point I would like to try consolidate the memory for each document so it's much easier to control
		// and give me some confidence there are definitely no leaks
	
		taskData := cast(*TaskData, data);
		doc := taskData.workingDocument;

		doc.bufferMemory.alignment = 1; // important!! make this hard to miss

		// if this fails, we have not reset any memory yet, so the existing document will persist in memory
		f, success := file_open(doc.path);
		if !success {
			taskData.result = .FAILED_TO_OPEN_FILE_FOR_WRITE;
			return;
		}

		fileSize := file_length(f);
		if (fileSize > (256*1024*1024)) {
			// this is a large file, so reserve space for the file plus 30% for additions
			init(*doc.bufferMemory, cast(int)(fileSize * 1.3));
			// @todo: better heuristic for guessing how much space you need for line endings and other data
			init(*doc.otherMemory, 512 * 1024 * 1024);
		}

		// now actually read in the file data
		file: string;
	    file, success = read_entire_file(f,,buffer_allocator(doc));
		file_close(*f);

		if !success {
			taskData.result = .FAILED_TO_READ_FILE_DATA;
			return;
		}

		doc.buffers[0].text.data = file.data;
		doc.buffers[0].text.count = file.count;
		doc.buffers[1].text.data = doc.buffers[0].text.data + doc.buffers[0].text.count;
		doc.buffers[1].text.count = 0;

		// count line starts
		lineStarts := *doc.buffers[0].lineStarts;
		lineStarts.allocator = other_allocator(doc);

		// @todo: rewrite this with SIMD
		array_add(lineStarts, 0);
		lfCount := 0;
		crCount := 0;
		crlfCount := 0;
		i := 0;
		while i < doc.buffers[0].text.count {
			byte := doc.buffers[0].text[i];
			if byte == #char "\r" {
				if i < doc.buffers[0].text.count-1 && doc.buffers[0].text[i+1] == #char "\n" {
					crlfCount += 1;
					array_add(lineStarts, xx (i+2));
					i += 1; // skip \n
				}
				else {
					crCount += 1;
				}
			}
			else if byte == #char "\n" {
				lfCount += 1;
				array_add(lineStarts, xx (i+1));
			}
			i += 1;
		}
		if lfCount > 0 && crlfCount == 0 && crCount == 0 {
			doc.lineEndings = .LF;
		}
		else if lfCount == 0 && crlfCount > 0 && crCount == 0 {
			doc.lineEndings = .CRLF;
		}
		else if lfCount > 0 && crlfCount > 0 && crCount == 0 {
			if lfCount > crlfCount {
				doc.lineEndings = .MIXED_MAJORITY_LF;
			}
			else {
				doc.lineEndings = .MIXED_MAJORITY_CRLF;
			}
		}
		else if crCount > 0 {
			// @todo: bit dangerous calling this from other threads
			push_notification("File has CR line endings, undefined behaviour will occur, my apologies");
		}

		lineStarts2 := *doc.buffers[1].lineStarts;
		lineStarts2.allocator = other_allocator(doc);
		array_add(lineStarts2, 0);

		// make root rb node
		firstPiece: Document.Piece;
		firstPiece.length = doc.buffers[0].text.count;
		firstPiece.lineFeedCount = doc.buffers[0].lineStarts.count-1;
		firstPiece.start = .{0,0};
		firstPiece.end = .{firstPiece.lineFeedCount, doc.buffers[0].text.count - doc.buffers[0].lineStarts[firstPiece.lineFeedCount]};
		firstPiece.bufferIndex = 0;

		doc.tree = make_rb_tree(*tree_allocator(doc), firstPiece);

		taskData.result = .SUCCESS;
	}

	load_from_disk_complete :: (data: *void) {
		// Assuming we had a success you need to copy all the new data and memory pools into the original document
		using taskData := cast(*TaskData, data);

		if result == .SUCCESS {
			// the memory pools will be set to the ones from the workingDocument, so we're done with these
			fini(*originalDocument.treeMemory);
			fini(*originalDocument.bufferMemory);
			fini(*originalDocument.otherMemory);

			memcpy(originalDocument, workingDocument, size_of(Document));

			// initial undo node
			array_reset(*originalDocument.undoStack);
			array_reset(*originalDocument.redoStack);
			originalDocument.nextUndoOffset = 0;
			commit_history(originalDocument);
			originalDocument.undoStack[originalDocument.undoStack.count-1].saved = true;

			calculate_longest_line(originalDocument);
			document_reparse_ts_tree(originalDocument);

			push_notification("Document Opened");
		}
		else if result == .FAILED_TO_READ_FILE_DATA {
			push_notification("File read failed");			
		}
		else if result == .FAILED_TO_OPEN_FILE_FOR_WRITE {
			push_notification("File open failed");			
		}
		free(taskData.workingDocument);
		free(taskData);
	}

	data := New(TaskData);
	data.originalDocument = doc;
	data.workingDocument = New(Document);
	data.workingDocument.path = doc.path;
	data.workingDocument.asyncParser = doc.asyncParser;
	data.workingDocument.locator = doc.locator;
	data.workingDocument.language = doc.language;

	data.result = .IN_PROGRESS;
	push_task(*asyncWorker, data, load_from_disk_task, load_from_disk_complete);
}

document_save :: (doc: *Document, path: string, backup := false) {
	TaskData :: struct {
		document: *Document;
		result: Result;
		desiredPath: string;
		isBackup: bool;
		Result :: enum {
			IN_PROGRESS;
			SUCCESS;
			FAILED_TO_MAKE_DIRECTORY;
			FAILED_TO_OPEN_FILE_FOR_WRITE;
		}
	}
	save_task :: (data: *void) {
		using taskData := cast(*TaskData, data);
		doc := taskData.document;

		directory_make_success := make_directory_if_it_does_not_exist(path_strip_filename(desiredPath), recursive = true);
	    if !directory_make_success {
			result = .FAILED_TO_MAKE_DIRECTORY;
			return;
		}

		fileHandle, success := file_open(desiredPath, true, false);
		if success {
			iterator := make_iterator(doc, 0);
			while iterator.node != null {
				bufferIndex := iterator.node.piece.bufferIndex;
				startOffset := buffer_cursor_to_offset(*doc.buffers[bufferIndex], iterator.node.piece.start);
				success := file_write(*fileHandle, doc.buffers[bufferIndex].text.data + startOffset, iterator.node.piece.length);
				next_node(*iterator);
			}

			file_close(*fileHandle);
			result = .SUCCESS;
			return;
		}
		else {
			result = .FAILED_TO_OPEN_FILE_FOR_WRITE;
			return;
		}
	}
	save_task_complete :: (data: *void) {
		using taskData := cast(*TaskData, data);
		doc := taskData.document;
		defer free(desiredPath);
		defer document_copy_free(document);
		defer free(taskData);

		if result == .FAILED_TO_MAKE_DIRECTORY {
			push_notification("Failed to make directory for file save");
			return;
		}

		if result == .FAILED_TO_OPEN_FILE_FOR_WRITE {
			push_notification("Failed to save file (couldn't open file)");
			return;
		}

		if !isBackup {
			if doc.path != desiredPath {
				free(doc.path); // this is bad for some reason?
				doc.path = copy_string(desiredPath);
			}

			modtime, size, success := file_modtime_and_size(doc.path);
			if success {
				doc.diskLastModtime = modtime;
			}

			push_notification("Document Saved");

			// mark last undo as saved
			doc.undoStack[doc.undoStack.count-1].saved = true;
		}
		else {
			push_notification("Backup Saved");
		}
	}

	data := New(TaskData);
	data.document = document_copy(doc);
	data.isBackup = backup;
	data.result = .IN_PROGRESS;
	data.desiredPath = copy_string(path);
	push_task(*asyncWorker, data, save_task, save_task_complete);
}

document_is_unsaved :: (doc: *Document) -> bool {
	// there is pending edits that have not been committed yet, definitely unsaved
	if doc.nextUndoOffset != -1 {
		return true;
	}

	// TODO: unclean fallback for when files fail to load
	if doc.undoStack.count == 0 {
		return false;
	}

	// most recent edit has not been saved
	if doc.undoStack[doc.undoStack.count-1].saved == false {
		return true;
	}

	return false;
}

document_get_by_path :: (path: string) -> bool, *Document {
	success, locator := table_find_new(*open_document_table, path);
	if success {
		bucket := open_documents.all_buckets[locator.bucket_index];
		assert(bucket.occupied[locator.slot_index] == true);
		result := *bucket.data[locator.slot_index];
		return true, result;
	}
	return false, null;
}

insert :: (doc: *Document, atOffset: s64, text: string, suppressHistory: bool = false) {
	#if BUILD_TYPE == BuildType.DEBUG {
		// Check to make sure we won't split a crlf
		if atOffset > 0 {
			character := get_char_at(doc, atOffset-1);
			assert(character != #char "\r");
		}
	}
	assert(!doc.isCopy, "You must not edit copies!!!");

	// undo updates
	if doc.nextUndoOffset < 0 {
		doc.nextUndoOffset = atOffset;
	}
	if suppressHistory == false {
		defer commit_history(doc);
	}

	defer document_update_ts_tree(doc, atOffset, atOffset, atOffset+text.count);

	// insert text at offset in document

	node, remainder, nodeStartOffset, line := node_at_offset(doc, doc.tree, atOffset);
	insertCursor := buffer_offset_to_cursor(doc, node.piece, remainder);

	// need the line/column in the buffer?, lets see for later
	
	// first case, inserting at the start of a node
	if atOffset == nodeStartOffset {
		if atOffset != 0 {
			// special case, if we are inserting right at the end of the last insertion
			// and the last insertion was the added data buffer, just extend the existing node
			prevNode, _, prevNodeStartOffset := node_at_offset(doc, doc.tree, atOffset-1);
			if prevNode.piece.bufferIndex == 1 && prevNode.piece.end == doc.lastInsert {
				newPiece := make_piece(doc, text);
				doc.tree = combine_pieces(tree_allocator(doc), doc.tree, prevNode, prevNodeStartOffset, newPiece);
				return;
			}
		}
		newPiece := make_piece(doc, text);
		doc.tree = insert_node(tree_allocator(doc), doc.tree, newPiece, atOffset);
		return;
	}

	// second case, inserting at end of a node
	if atOffset == nodeStartOffset+node.piece.length {
		// special case, if we are inserting right at the end of the last insertion
		// and the last insertion was the added data buffer, just extend the existing node
		if node.piece.bufferIndex == 1 && node.piece.end == doc.lastInsert {
			newPiece := make_piece(doc, text);
			doc.tree = combine_pieces(tree_allocator(doc), doc.tree, node, nodeStartOffset, newPiece);
			return;
		}
		newPiece := make_piece(doc, text);
		doc.tree = insert_node(tree_allocator(doc), doc.tree, newPiece, atOffset);
		return;
	}

	// final case, inserting in the middle of a node
	newPieceLeft := node_trim_right(doc, node.piece, insertCursor);
	newPieceMiddle := make_piece(doc, text);
	newPieceRight := node_trim_left(doc, node.piece, insertCursor);

	tree := remove_node(doc.tree, nodeStartOffset);

	tree = insert_node(tree_allocator(doc), tree, newPieceLeft, nodeStartOffset);
	tree = insert_node(tree_allocator(doc), tree, newPieceMiddle, nodeStartOffset + newPieceLeft.length);
	tree = insert_node(tree_allocator(doc), tree, newPieceRight, nodeStartOffset + newPieceLeft.length + newPieceMiddle.length);

	doc.tree = tree;
}

delete :: (doc: *Document, atOffset: s64, length: s64, suppressHistory := false) {
	// delete length bytes in the document at offset
	assert(!doc.isCopy, "You must not edit copies!!!");

	// undo updates
	if doc.nextUndoOffset < 0 {
		doc.nextUndoOffset = atOffset;
	}
	if suppressHistory == false {
		defer commit_history(doc);
	}

	defer document_update_ts_tree(doc, atOffset, atOffset+length, atOffset);

	firstNode, firstRemainder, firstNodeOffset, beginLine := node_at_offset(doc, doc.tree, atOffset);
	lastNode, lastRemainder, lastNodeOffset, endLine := node_at_offset(doc, doc.tree, atOffset + length);

	defer if beginLine <= doc.longestLine && endLine >= doc.longestLine {
		calculate_longest_line(doc);
	}
	
	startBufferCursor := buffer_offset_to_cursor(doc, firstNode.piece, firstRemainder);
	endBufferCursor := buffer_offset_to_cursor(doc, lastNode.piece, lastRemainder);

	// fully contained in one node
	if firstNode == lastNode {

		// deletion starts at the beginning of the node
		if firstNodeOffset == atOffset {

			// it's the entire node
			if length == firstNode.piece.length {
				doc.tree = remove_node(doc.tree, firstNodeOffset);
				return;
			}

			// remove only the left side of the node
			newPiece := node_trim_left(doc, firstNode.piece, endBufferCursor);
			doc.tree = remove_node(doc.tree, firstNodeOffset);
			doc.tree = insert_node(tree_allocator(doc), doc.tree, newPiece, firstNodeOffset);
			return;
		}

		if firstNodeOffset + firstNode.piece.length == atOffset + length {
			// in this case we are removing the right part of the node

			newPiece := node_trim_right(doc, firstNode.piece, startBufferCursor);
			doc.tree = remove_node(doc.tree, firstNodeOffset);
			doc.tree = insert_node(tree_allocator(doc), doc.tree, newPiece, firstNodeOffset);
			return;
		}

		// lastly we have the case where the removed section is in the middle of the node
		// so we must trim both sides
		
		newPieceLeft := node_trim_right(doc, firstNode.piece, startBufferCursor);
		newPieceRight := node_trim_left(doc, firstNode.piece, endBufferCursor);

		doc.tree = remove_node(doc.tree, firstNodeOffset);
		doc.tree = insert_node(tree_allocator(doc), doc.tree, newPieceLeft, firstNodeOffset);
		doc.tree = insert_node(tree_allocator(doc), doc.tree, newPieceRight, firstNodeOffset + newPieceLeft.length);
		return;
	}

	// the latter half of this function deals with the case where the deletion covers multiples nodes

	remove_node_range :: (doc: *Document, tree: *Document.Node, firstOffset: s64, lengthToDelete: s64) -> *Document.Node {
		node, remainder, nodeStartOffset := node_at_offset(doc, tree, firstOffset);

		// adjust length to forcefully include the whole first node (it may not)
		firstNodeLength := node.piece.length;
		lengthToDelete = lengthToDelete - (firstNodeLength - remainder) + firstNodeLength;

		deleteAtOffset := nodeStartOffset;
		while lengthToDelete > 0 {
			lengthToDelete -= node.piece.length;
			tree = remove_node(tree, deleteAtOffset);
			node = node_at_offset(doc, tree, deleteAtOffset);
		}
		return tree;
	}
	
	newPieceLeft := node_trim_right(doc, firstNode.piece, startBufferCursor);
	if lastNode == null {
		doc.tree = remove_node_range(doc, doc.tree, atOffset, length);
	}
	else {
		newPieceRight := node_trim_left(doc, lastNode.piece, endBufferCursor);
		doc.tree = remove_node_range(doc, doc.tree, atOffset, length);

		if lastRemainder != 0 && newPieceRight.length != 0 {
			doc.tree = insert_node(tree_allocator(doc), doc.tree, newPieceRight, firstNodeOffset);
		}
	}

	if newPieceLeft.length != 0 {
		doc.tree = insert_node(tree_allocator(doc), doc.tree, newPieceLeft, firstNodeOffset);
	}
}

search :: (doc: *Document, type: Document.SearchType, fromOffset: s64, searchTerm: string, stopAtFirstResult := true) -> bool, [..]Document.Range {
	startCoordinate := get_coordinate_from_offset(doc, fromOffset);

	matched := false;
	results : [..]Document.Range;
	
	iter := make_line_iterator(doc, startCoordinate.line);
	currentNode := iter.node;
	for iter {
		// first lets get our string to search
		haystack: string;
		haystackStartOffset: s64;
		haystackEndOffset: s64;

		// current node has not changed, so there could be more lines for us to copy
		moreLinesInThisNode := ifx iter.node then iter.lineNumInNode < iter.node.piece.end.line else false;
		if currentNode == iter.node && moreLinesInThisNode {
			// okay there are more lines available in this file
			buffer := *iter.doc.buffers[iter.node.piece.bufferIndex];
			startOffset := buffer_cursor_to_offset(buffer, .{iter.lineNumInNode - 1, 0} );
			endOffset := buffer_cursor_to_offset(buffer, .{iter.node.piece.end.line, 0});

			haystack = string.{endOffset - startOffset, buffer.text.data + startOffset};
			haystackStartOffset = it.startByteOffset;
			haystackEndOffset = it.startByteOffset + haystack.count;

			// log("block:\n");
			// log("%", haystack);

			linesMoved := iter.node.piece.end.line - iter.lineNumInNode;
			iter.line = iter.line + linesMoved;
			iter.lineNumInNode = iter.node.piece.end.line;

		}
		else {
			haystack = it.text;
			haystackStartOffset = it.startByteOffset;
			haystackEndOffset = it.endByteOffset;
		
			// log("block:\n");
			// log("%", it.text);
		}
		currentNode = iter.node;

		i := -1;
		if it_index == startCoordinate.line+1 {
			haystack.data += startCoordinate.col;
			haystack.count -= startCoordinate.col;
			if type == {
				case .STANDARD; 
					i = find_index_from_left_fast(haystack, searchTerm);
				case .NOCASE;
					i = find_index_from_left_nocase_fast(haystack, searchTerm);
				case .REGEX;
					assert(false, "Not implemented");
			}
			if i >= 0 then i += startCoordinate.col;
		}
		else {
			if type == {
				case .STANDARD; 
					i = find_index_from_left_fast(haystack, searchTerm);
				case .NOCASE;
					i = find_index_from_left_nocase_fast(haystack, searchTerm);
				case .REGEX;
					assert(false, "Not implemented");
			}
		}

		if i >= 0 {
			// found a match, report it
			matched = true;
			array_add(*results, Document.Range.{haystackStartOffset+i, haystackStartOffset+i+searchTerm.count});
			if stopAtFirstResult then break;
		}
	}
	return matched, results;
}

get_char_at :: (doc: *Document, offset: s64) -> u8 {
	// get the literal char at the given offset

	node, remainder, _ := node_at_offset(doc, doc.tree, offset);
	bufferIndex := node.piece.bufferIndex;
	startOffset := buffer_cursor_to_offset(*doc.buffers[bufferIndex], node.piece.start);
	charPtr := doc.buffers[bufferIndex].text.data + startOffset + remainder;
	return charPtr.*;
}

get_line_start :: (doc: *Document, line: s64) -> s64 {
	// get the document offset of a specific line (0 indexed) via binary search
	node := doc.tree;
	lineInSubtree := line;
	nodeStartOffset: s64;
	lineFeedCount: s64;
	while node != null {
		if lineInSubtree <= node.leftSubtreeLfCount {
			// Target must be in the left side of the tree
			node = node.left;
		}
		else if lineInSubtree <= node.leftSubtreeLfCount + node.piece.lineFeedCount {
			// Target must be within this node
			nodeStartOffset += node.leftSubtreeLength;
			lineFeedCount += node.leftSubtreeLfCount;

			lineInThisNode := line - lineFeedCount;
			buffer := *doc.buffers[node.piece.bufferIndex];
			return nodeStartOffset + (buffer_cursor_to_offset(buffer, .{node.piece.start.line + lineInThisNode, 0}) - buffer_cursor_to_offset(buffer, node.piece.start));
		}
		else {
			if node.right == null {
				return length(doc.tree); // at end of document, just return the length
			}
			// Target must be in the right side of the tree
			lineInSubtree -= node.leftSubtreeLfCount + node.piece.lineFeedCount;
			nodeStartOffset += node.leftSubtreeLength + node.piece.length;
			lineFeedCount += node.leftSubtreeLfCount + node.piece.lineFeedCount;
			node = node.right;
		}
	}

	return 0;
}

get_line_range :: (doc: *Document, line: s64, includeLineEndings := false) -> s64, s64 {
	// find the start and end offsets of the given line, with or without line endings
	lineStart := get_line_start(doc, line);
	lineEnd := get_line_start(doc, line+1);

	if !includeLineEndings {
		rem := 0;
		if get_char_at(doc, lineEnd-1) == #char "\n" {
			rem += 1;
		}
		if get_char_at(doc, lineEnd-2) == #char "\r" {
			rem += 1;
		}
		return lineStart, lineEnd - rem;
	}
	return lineStart, lineEnd;
}

get_coordinate_from_offset :: (doc: *Document, offset: s64) -> Document.Coordinate {
	// get line, column from a given offset
	node, remainder, nodeStart, line := node_at_offset(doc, doc.tree, offset);
	lineStart := get_line_start(doc, line);
	return .{ line, offset-lineStart };
}

get_offset_from_coordinate :: (doc: *Document, coord: Document.Coordinate) -> s64 {
	// Note, if you provide a column that is off the length of the line, it will clamp
	// decide at some point if that's desirable
	lineStart, lineEnd := get_line_range(doc, coord.line);
	column := min(lineEnd-lineStart, coord.col);
	return lineStart + column;
}

get_line_content :: (doc: *Document, line: s64, includeLineEndings := false) -> Document.LineContent {
	// allocates memory for returned string!!

	offset := get_line_start(doc, line);
	iterator := make_iterator(doc, offset);
	builder: String_Builder;
	builder.allocator = temp;
	prev: u8;
	endOffset := 0;

	for iterator {
		if !includeLineEndings && (it == #char "\n" || it == #char "\r") {
			endOffset = offset + it_index;
			break;
		}
		else if includeLineEndings && (prev == #char "\n") {
			endOffset = offset + it_index;
			break;
		}
		append(*builder, it);
		prev = it;
	}

	return .{ builder_to_string(*builder), offset, endOffset };
}

get_content :: (doc: *Document, offset: s64, count: s64) -> string {
	// allocates memory for returned string!!

	iterator := make_iterator(doc, offset);
	builder: String_Builder;
	builder.allocator = temp;

	test : [200]u8;
	for iterator {
		if it_index == count {
			break;
		}
		test[it_index] = it;
		append(*builder, it);
	}
	return builder_to_string(*builder);
}

get_number_of_lines :: (doc: *Document) -> s64 {
	return lf_count(doc.tree)+1; // plus one due to fence post problem
}

get_size :: (doc: *Document) -> s64 {
	return length(doc.tree);
}

shift_offset_line_endings :: (doc: *Document, offset: s64, direction: Document.IterateDirection) -> s64 {
	// if offset is sat in between \r and \n, that is \r is the char behind it, then shift
	// in the desired direction
	if direction == .FORWARD {
		if get_char_at(doc, offset-1) == #char "\r" {
			return offset + 1;
		}
	}
	else {
		if get_char_at(doc, offset-1) == #char "\r" {
			return offset - 1;
		}
	}
	return offset;
}

commit_history :: (doc: *Document) {
	// TODO: free this memory somewhere
	assert(!doc.isCopy, "You must not edit copies!!!");
	array_add(*doc.undoStack);
	doc.undoStack[doc.undoStack.count-1].tree = doc.tree;
	doc.undoStack[doc.undoStack.count-1].offset = doc.nextUndoOffset;
	doc.undoStack[doc.undoStack.count-1].longestLine = doc.longestLine;
	doc.undoStack[doc.undoStack.count-1].longestLineLength = doc.longestLineLength;
	doc.nextUndoOffset = -1;
}

undo :: (doc: *Document) -> s64 {
	assert(!doc.isCopy, "You must not edit copies!!!");
	if doc.undoStack.count == 1 {
		push_notification("Undo history empty");
		return -1;
	}
	entry := pop(*doc.undoStack);
	array_add(*doc.redoStack, entry);
	doc.tree = doc.undoStack[doc.undoStack.count-1].tree;
	doc.longestLine = doc.undoStack[doc.undoStack.count-1].longestLine;
	doc.longestLineLength = doc.undoStack[doc.undoStack.count-1].longestLineLength;

	// @todo: track and coalesce edits such that we can reparse after an undo more precisely
	// You coalesce edits by doing something like this:
	// combinedStart = min(combinedStart, start)
	// combinedOldEnd = max(combinedOldEnd, oldEnd)
	// combinedNewEnd = combinedOldEnd + totalDeltaBytes
	document_reparse_ts_tree(doc);
	return entry.offset;
}

redo :: (doc: *Document) -> s64 {
	assert(!doc.isCopy, "You must not edit copies!!!");
	if doc.redoStack.count == 0 {
		push_notification("Redo history empty");
		return -1;
	}
	entry := pop(*doc.redoStack);
	doc.tree = entry.tree;
	doc.longestLine = entry.longestLine;
	doc.longestLineLength = entry.longestLineLength;
	array_add(*doc.undoStack, entry);

	// could be more efficient here, but don't know how to tell the diff of the undo?
	document_reparse_ts_tree(doc);
	return entry.offset;
}

document_copy :: (doc: *Document) -> *Document {
	assert(!doc.isCopy, "Don't make copies of copies");
	copy := New(Document);
	memcpy(copy, doc, size_of(Document));
	if doc.tsTree {
		copy.tsTree = ts_tree_copy(doc.tsTree);
	}
	copy.isCopy = true;
	return copy;
}
 
document_copy_free :: (doc: *Document) {
	assert(doc.isCopy, "Don't delete actual document");
	ts_tree_delete(doc.tsTree);
	free(doc);
}

// Tree iterators

make_iterator :: (doc: *Document, startOffset: s64 = 0) -> Document.Iterator {
	// starting at some non trivial offset will require doing a binary search in the tree for that offset
	// and saving the node, as we have done with node_at
	iter: Document.Iterator;
	iter.doc = doc;
	iter.stack.allocator = context.allocator; // is this leaking??
	iter.direction = .FORWARD;

	jump_to(*iter, startOffset);
	return iter;
}

make_reverse_iterator :: (document: *Document, startOffset: s64 = 0) -> Document.Iterator {
	// starting at some non trivial offset will require doing a binary search in the tree for that offset
	// and saving the node, as we have done with node_at
	iter: Document.Iterator;
	iter.doc = document;
	iter.stack.allocator = context.allocator; // is this leaking??
	iter.direction = .REVERSE;

	jump_to(*iter, startOffset);
	return iter;
}

make_line_iterator :: (document: *Document, startLine: s64 = 0, endLine: s64 = -1) -> Document.LineIterator {
	iter: Document.LineIterator;
	iter.doc = document;
	iter.stack.allocator = context.allocator; // is this leaking??
	iter.direction = .FORWARD;
	iter.lineBuffer.allocator = context.allocator;
	iter.endLine = ifx endLine > 0 then endLine else get_number_of_lines(document);

	jump_to_line(*iter, startLine);
	return iter;
}

next_node :: (iterator: *Document.Iterator) {
	// NOTE: This does not update iterator.offset
	// in a for expansion it will be done at each iteration step
	// in other situations you may require calculating it manually, or contextually
	// With no context it'll be another binary search of the tree to find the offset
	// you could store nodeStartOffset in the iterator, such that you can set the offset based on that
	// by adding the current node length or subtracting the previous depending on direction
	// no need at the moment though so I'll leave this as is

	node := iterator.node.child[iterator.direction];
	while iterator.stack.count > 0 || node != null {
		if node != null {
			// all parents are added to the stack
			array_add(*iterator.stack, node);
			node = node.child[1 - iterator.direction];
		}
		else {
			// the node we return is not left in the stack
			node = iterator.stack[iterator.stack.count-1];
			iterator.stack.count -= 1;
			break;
		}
	}

	// node was found, setup the range pointers
	if node != null {
		bufferIndex := node.piece.bufferIndex;
		startOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], node.piece.start);
		endOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], node.piece.end);

		iterator.firstChar = iterator.doc.buffers[bufferIndex].text.data + startOffset;
		iterator.lastChar = iterator.doc.buffers[bufferIndex].text.data + endOffset;

		iterator.node = node;
		return;
	}

	// if no node found
	iterator.node = null;
	iterator.firstChar = null;
	iterator.lastChar = null;
	array_reset(*iterator.stack);
}

jump_to :: (iterator: *Document.Iterator, offset: s64) {
	iterator.offset = offset;
	node := iterator.doc.tree;
	remainder := 0;

	nodeStartOffset := 0;
	while node != null {
		// you only want to store nodes that you would visit in a forward/reverse iteration here
		// rather than every parent
		if offset < node.leftSubtreeLength {
			// Target must be in the left side of the tree
			if iterator.direction == .FORWARD {
				array_add(*iterator.stack, node);
			}
			node = node.left;
		}
		else if offset <= node.leftSubtreeLength + node.piece.length {
			// Target must be within this node
			nodeStartOffset += node.leftSubtreeLength;
			remainder = iterator.offset - nodeStartOffset;
			break;
		}
		else {
			// Target must be in the right side of the tree
			if iterator.direction == .REVERSE {
				array_add(*iterator.stack, node);
			}
			leftSideOffset := node.leftSubtreeLength + node.piece.length;
			nodeStartOffset += leftSideOffset;
			offset -= leftSideOffset; // Our offset now must be relative to the right side of the tree
			node = node.right;
		}
	}

	// node was found
	if node != null {
		bufferIndex := node.piece.bufferIndex;
		startOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], node.piece.start);
		endOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], node.piece.end);

		iterator.firstChar = iterator.doc.buffers[bufferIndex].text.data + startOffset + remainder;
		iterator.lastChar = iterator.doc.buffers[bufferIndex].text.data + endOffset;
		iterator.node = node;
		return;
	}

	// if no node found
	iterator.node = null;
	iterator.firstChar = null;
	iterator.lastChar = null;
	array_reset(*iterator.stack);
}

jump_to_line :: (iterator: *Document.LineIterator, line: s64) {
	iterator.line = line;
	node := iterator.doc.tree;

	// first we scan to find the start of the desired line in which ever node it lives in
	lineInSubtree := line;
	lineInNode := -1;
	nodeStartOffset: s64;
	lineFeedCount: s64;
	while node != null {
		// you only want to store nodes that you would visit in a forward/reverse iteration here
		// rather than every parent
		if lineInSubtree <= node.leftSubtreeLfCount {
			// Target must be in the left side of the tree

			// special case for first line
			if node.left == null && lineInSubtree == 0 && node.leftSubtreeLfCount == 0 {
				lineInNode = 0;
				break;
			}

			if iterator.direction == .FORWARD {
				array_add(*iterator.stack, node);
			}
			node = node.left;
		}
		else if lineInSubtree <= node.leftSubtreeLfCount + node.piece.lineFeedCount {
			// Target must be within this node
			nodeStartOffset += node.leftSubtreeLength;
			lineFeedCount += node.leftSubtreeLfCount;

			lineInNode = line - lineFeedCount;
			break;
		}
		else {
			if iterator.direction == .REVERSE {
				array_add(*iterator.stack, node);
			}

			// Target must be in the right side of the tree
			lineInSubtree -= node.leftSubtreeLfCount + node.piece.lineFeedCount;
			nodeStartOffset += node.leftSubtreeLength + node.piece.length;
			lineFeedCount += node.leftSubtreeLfCount + node.piece.lineFeedCount;
			node = node.right;
		}
	}

	// either way the output of the above search is two things
	iterator.node = node;
	iterator.lineNumInNode = iterator.node.piece.start.line + lineInNode;
	iterator.nodeStartOffset = nodeStartOffset;
}

step_line :: (iter: *Document.LineIterator) {
	// so what's actually involved in this process??

	if iter.lineNumInNode < iter.node.piece.end.line {
		// line is fully contained in this node

		buffer := *iter.doc.buffers[iter.node.piece.bufferIndex];
		startOffset := buffer_cursor_to_offset(buffer, .{iter.lineNumInNode, 0} );
		endOffset := buffer_cursor_to_offset(buffer, .{iter.lineNumInNode + 1, 0});
		lineLength := endOffset - startOffset;

		iter.lineContent.text = .{ lineLength, buffer.text.data + startOffset };
		iter.lineContent.startByteOffset = iter.nodeStartOffset + (startOffset - buffer_cursor_to_offset(buffer, iter.node.piece.start));
		iter.lineContent.endByteOffset = iter.nodeStartOffset + (endOffset - buffer_cursor_to_offset(buffer, iter.node.piece.start));
	}
	else {
		// line is not fully contained in this node
		array_reset_keeping_memory(*iter.lineBuffer);

		// copy the remaining memory of the node
		buffer := *iter.doc.buffers[iter.node.piece.bufferIndex];
		startOffset := max(buffer_cursor_to_offset(buffer, .{iter.lineNumInNode, 0} ), buffer_cursor_to_offset(buffer, iter.node.piece.start ));
		endOffset := buffer_cursor_to_offset(buffer, iter.node.piece.end);
		sectionLength := endOffset - startOffset;
		array_reserve(*iter.lineBuffer, sectionLength);
		memcpy(iter.lineBuffer.data, buffer.text.data + startOffset, sectionLength);
		iter.lineBuffer.count = sectionLength;
		iter.lineContent.startByteOffset = iter.nodeStartOffset + (startOffset - buffer_cursor_to_offset(buffer, iter.node.piece.start));

		// we'll loop over nodes, copying text until we reach the end of the line
		// or the end of the tree
		while iter.node {
			// find the next node
			node := iter.node.child[iter.direction];
			while iter.stack.count > 0 || node != null {
				if node != null {
					// all parents are added to the stack
					array_add(*iter.stack, node);
					node = node.child[1 - iter.direction];
				}
				else {
					// the node we return is not left in the stack
					node = iter.stack[iter.stack.count-1];
					iter.stack.count -= 1;
					break;
				}
			}

			// next node found
			if node != null {
				iter.nodeStartOffset = iter.nodeStartOffset + iter.node.piece.length;
				iter.node = node;
				iter.lineNumInNode = node.piece.start.line;

				// See if the next node contains the rest of the line
				if iter.node.piece.lineFeedCount > 0 {
					// copy up to the first newline of this node
					buffer := *iter.doc.buffers[iter.node.piece.bufferIndex];
					startOffset := buffer_cursor_to_offset(buffer, iter.node.piece.start );
					endOffset := buffer_cursor_to_offset(buffer, .{iter.node.piece.start.line + 1, 0});
					sectionLength := endOffset - startOffset;
					array_reserve(*iter.lineBuffer, iter.lineBuffer.count + sectionLength);
					memcpy(iter.lineBuffer.data+iter.lineBuffer.count, buffer.text.data + startOffset, sectionLength);
					iter.lineBuffer.count = iter.lineBuffer.count + sectionLength;
					iter.lineContent.endByteOffset = iter.lineContent.startByteOffset + iter.lineBuffer.count;
					break; // we're finished
				}
				else {
					// copy the whole node, and then loop again
					buffer := *iter.doc.buffers[iter.node.piece.bufferIndex];
					startOffset := buffer_cursor_to_offset(buffer, iter.node.piece.start );
					endOffset := buffer_cursor_to_offset(buffer, iter.node.piece.end);
					sectionLength := endOffset - startOffset;
					array_reserve(*iter.lineBuffer, iter.lineBuffer.count + sectionLength);
					memcpy(iter.lineBuffer.data+iter.lineBuffer.count, buffer.text.data + startOffset, sectionLength);
					iter.lineBuffer.count = iter.lineBuffer.count + sectionLength;
				}
			}
			else {
				iter.node = node;
			}
		}

		iter.lineContent.text = .{ iter.lineBuffer.count, iter.lineBuffer.data };
	}

	// move on to next line
	iter.line = iter.line + 1;
	iter.lineNumInNode = iter.lineNumInNode + 1;
}

for_expansion :: (iterator: *Document.LineIterator, body: Code, flags: For_Flags) #expand {
	while iterator.node {
		step_line(iterator);

		`it := iterator.lineContent;
		`it_index := iterator.line;
		
		#insert body;

		if iterator.endLine+1 == iterator.line then break;
	}
}

for_expansion :: (iterator: *Document.Iterator, body: Code, flags: For_Flags) #expand {

	counter := 0;
	while outer := iterator.node != null {
		`it: u8;
		`it_index := 0;
		if iterator.direction == .REVERSE {
			// need to adjust the start and end pointers if we're going backward
			bufferIndex := iterator.node.piece.bufferIndex;
			startOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], iterator.node.piece.start);
			endOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], iterator.node.piece.end);
			startPtr := iterator.doc.buffers[bufferIndex].text.data + startOffset;
			endPtr := iterator.doc.buffers[bufferIndex].text.data + endOffset;
			if iterator.firstChar > startPtr || iterator.offset == iterator.node.leftSubtreeLength {
				iterator.lastChar = iterator.firstChar;
				iterator.firstChar = startPtr-1;
			}
			else {
				iterator.lastChar -= 1;
				iterator.firstChar -= 1;
			}


			while iterator.firstChar < iterator.lastChar {
				`it_index = counter;
				`it = iterator.lastChar.*;
				if `it != #char "\r" {
					#insert(break=break outer) body;  // If the user says break, break from the *outer* loop!
					counter += 1;
				}
				iterator.lastChar -= 1;
				iterator.offset -= 1;
			}
			next_node(iterator);
		}
		else {
			while iterator.firstChar < iterator.lastChar {
				`it_index = counter;
				`it = iterator.firstChar.*;
				if `it != #char "\r" {
					#insert(break=break outer) body;  // If the user says break, break from the *outer* loop!
					counter += 1;
				}
				iterator.firstChar += 1;
				iterator.offset += 1;
			}
			next_node(iterator);
		}
	}
}

raw_bytes :: (iterator: *Document.Iterator, body: Code, flags: For_Flags) #expand {

	counter := 0;
	while outer := iterator.node != null {
		`it: u8;
		`it_index := 0;
		if iterator.direction == .REVERSE {
			// need to adjust the start and end pointers if we're going backward
			bufferIndex := iterator.node.piece.bufferIndex;
			startOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], iterator.node.piece.start);
			endOffset := buffer_cursor_to_offset(*iterator.doc.buffers[bufferIndex], iterator.node.piece.end);
			startPtr := iterator.doc.buffers[bufferIndex].text.data + startOffset;
			endPtr := iterator.doc.buffers[bufferIndex].text.data + endOffset;
			if iterator.firstChar > startPtr || iterator.offset == iterator.node.leftSubtreeLength {
				iterator.lastChar = iterator.firstChar;
				iterator.firstChar = startPtr-1;
			}
			else {
				iterator.lastChar -= 1;
				iterator.firstChar -= 1;
			}


			while iterator.firstChar < iterator.lastChar {
				`it_index = counter;
				`it = iterator.lastChar.*;
				#insert(break=break outer) body;  // If the user says break, break from the *outer* loop!
				counter += 1;
				iterator.lastChar -= 1;
				iterator.offset -= 1;
			}
			next_node(iterator);
		}
		else {
			while iterator.firstChar < iterator.lastChar {
				`it_index = counter;
				`it = iterator.firstChar.*;
				#insert(break=break outer) body;  // If the user says break, break from the *outer* loop!
				counter += 1;
				iterator.firstChar += 1;
				iterator.offset += 1;
			}
			next_node(iterator);
		}
	}
}

// syntax highlight stuff

document_parse_read :: (payload: *void, byteOffset: u32, position: TSPoint, bytesRead: *u32) -> *u8 #c_call {
	push_context {
		doc := cast(*Document, payload);
		
		node, remainder, nodeStartOffset := node_at_offset(doc, doc.tree, byteOffset);
		bufferIndex := node.piece.bufferIndex;
		startOffset := buffer_cursor_to_offset(*doc.buffers[bufferIndex], node.piece.start);
		endOffset := buffer_cursor_to_offset(*doc.buffers[bufferIndex], node.piece.end);
		charPtr := doc.buffers[bufferIndex].text.data + startOffset + remainder;

		bytesRead.* = cast(u32, endOffset - (startOffset + remainder));

		return charPtr;
	}
}

document_reparse_ts_tree :: (doc: *Document) {
	if doc.asyncParser == null return;

	task := New(TSParseTaskData);
	task.doc = doc;
	task.docCopy = document_copy(doc);
	task.forceReparse = true;
	push_task(*asyncWorker, task, ts_parse_task, ts_parse_task_complete);
}

document_update_ts_tree :: (doc: *Document, startOffset: s64, oldEndOffset: s64, newEndOffset: s64) {
	if doc.asyncParser == null return;

	task := New(TSParseTaskData);
	task.doc = doc;
	task.docCopy = document_copy(doc);
	task.forceReparse = false;
	task.startOffset = startOffset;
	task.oldEndOffset = oldEndOffset;
	task.newEndOffset = newEndOffset;
	push_task(*asyncWorker, task, ts_parse_task, ts_parse_task_complete);
}

#scope_file
TSParseTaskData :: struct {
	doc: *Document;
	docCopy: *Document;
	forceReparse: bool;
	startOffset: s64;
	oldEndOffset: s64;
	newEndOffset: s64;
}
ts_parse_task :: (data: *void) {
	using taskData := cast(*TSParseTaskData, data);

	if doc.asyncParser && doc.language {
		if !forceReparse {
			inputEdit := TSInputEdit.{start_byte=xx startOffset, old_end_byte=xx oldEndOffset, new_end_byte=xx newEndOffset};
			ts_tree_edit(doc.asyncTsTree, *inputEdit);
			doc.asyncTsTree = ts_parser_parse(doc.asyncParser, doc.asyncTsTree, .{payload=docCopy, read=document_parse_read, encoding=.UTF8});
		}
		else {
			ts_parser_reset(docCopy.asyncParser);
			doc.asyncTsTree = ts_parser_parse(doc.asyncParser, null, .{payload=docCopy, read=document_parse_read, encoding=.UTF8});
		}
	}
}
ts_parse_task_complete :: (data: *void) {
	using taskData := cast(*TSParseTaskData, data);

	// swap the ts trees
	ts_tree_delete(doc.tsTree);
	doc.tsTree = ts_tree_copy(doc.asyncTsTree);

	document_copy_free(taskData.docCopy);
	free(taskData);
}

#scope_export

// helpers

pretty_print_tree :: (node: *Document.Node) {
	pretty_print_tree(node, "", false);
}

operator == :: (a: Document.BufferCursor, b: Document.BufferCursor) -> bool {
	return a.line == b.line && a.column == b.column;
}

node_at_offset :: (doc: *Document, node: *Document.Node, offset: s64) -> node: *Document.Node, remainder: s64, nodeStartOffset: s64, line: s64 {
	// This is basically a binary search

	offsetInSubtree := offset;
	nodeStartOffset: s64;
	lineFeedCount: s64;
	while node != null {
		if offsetInSubtree < node.leftSubtreeLength {
			// Target must be in the left side of the tree
			node = node.left;
		}
		else if offsetInSubtree < node.leftSubtreeLength + node.piece.length {
			// Target must be within this node
			nodeStartOffset += node.leftSubtreeLength;
			lineFeedCount += node.leftSubtreeLfCount;
			remainder := offset - nodeStartOffset;
			
			bufferCursor := buffer_offset_to_cursor(doc, node.piece, remainder);
			lineFeedCount += bufferCursor.line - node.piece.start.line;
			return node, remainder, nodeStartOffset, lineFeedCount;
		}
		else {
			if node.right == null {
				// end of the tree, we'll just go with the current node, at the very end
				leftSideOffset := node.leftSubtreeLength;
				nodeStartOffset += leftSideOffset;
				lineFeedCount += node.leftSubtreeLfCount + node.piece.lineFeedCount;
				remainder := node.piece.length;
				return node, remainder, nodeStartOffset, lineFeedCount;
			}

			// Target must be in the right side of the tree
			leftSideOffset := node.leftSubtreeLength + node.piece.length;
			
			offsetInSubtree -= leftSideOffset; // Our offset now must be relative to the right side of the tree

			nodeStartOffset += leftSideOffset;
			lineFeedCount += node.leftSubtreeLfCount + node.piece.lineFeedCount;
			node = node.right;
		}
	}

	return null, 0, 0, 0;
}

// Piece Tree helpers

// commented out because search is using internal stuff
// intention is that core search function gets moved to this file
// #scope_file

make_piece :: (pieceTree: *Document, t: string) -> Document.Piece {
	// firstly copy the text into the add buffer

	newPiece: Document.Piece;
	newPiece.length = t.count;
	newPiece.bufferIndex = 1; // add buffer

	text := copy_string(t,, buffer_allocator(pieceTree));
	currentBufferEnd := pieceTree.buffers[1].text.count;
	pieceTree.buffers[1].text.count = pieceTree.buffers[1].text.count + text.count;

	// count line endings
	// @todo: might be a good location to correct bad line endings
	// @todo: otherwise mark if the line endings have changed based on something new
	lineFeedCount := 0;
	for byte, i: text {
		if byte == #char "\n" {
			array_add(*pieceTree.buffers[1].lineStarts, xx (currentBufferEnd + i + 1));
			lineFeedCount += 1;
		}
	}
	newPiece.lineFeedCount = lineFeedCount;

	newPiece.start = pieceTree.lastInsert;
	endLine := pieceTree.buffers[1].lineStarts.count-1;
	newPiece.end = .{ endLine, pieceTree.buffers[1].text.count - pieceTree.buffers[1].lineStarts[endLine] };
	pieceTree.lastInsert = newPiece.end;

	return newPiece;
}

node_trim_left :: (pieceTree: *Document, piece: Document.Piece, pos: Document.BufferCursor) -> Document.Piece {
	buffer := *pieceTree.buffers[piece.bufferIndex];
	newPiece := piece;

	// remove the left side of piece up to pos
	bufferOffsetStart := buffer_cursor_to_offset(buffer, piece.start);
	bufferOffsetSplit := buffer_cursor_to_offset(buffer, pos);
	lenRight := (bufferOffsetStart + piece.length) - bufferOffsetSplit;

	newPiece.start = pos;
	newPiece.length = lenRight;
	newPiece.lineFeedCount = buffer_line_start_count(newPiece.start, newPiece.end);
	return newPiece;
}

node_trim_right :: (pieceTree: *Document, piece: Document.Piece, pos: Document.BufferCursor) -> Document.Piece {
	buffer := *pieceTree.buffers[piece.bufferIndex];
	newPiece := piece;

	// remove the right side of piece from pos
	bufferOffsetStart := buffer_cursor_to_offset(buffer, piece.start);
	bufferOffsetSplit := buffer_cursor_to_offset(buffer, pos);
	lenLeft := bufferOffsetSplit - bufferOffsetStart;

	newPiece.end = pos;
	newPiece.length = lenLeft;
	newPiece.lineFeedCount = buffer_line_start_count(newPiece.start, newPiece.end);
	return newPiece;
}

combine_pieces :: (allocator: Allocator, tree: *Document.Node, prevNode: *Document.Node, prevNodeStartOffset: s64, newPiece: Document.Piece) -> *Document.Node {
	newPieceCopy := newPiece;
	newPieceCopy.start = prevNode.piece.start;
	newPieceCopy.lineFeedCount = newPiece.lineFeedCount + prevNode.piece.lineFeedCount;
	newPieceCopy.length= newPiece.length + prevNode.piece.length;
	tree = remove_node(tree, prevNodeStartOffset);
	return insert_node(allocator, tree, newPieceCopy , prevNodeStartOffset);
}

buffer_offset_to_cursor :: (pieceTree: *Document, piece: Document.Piece, offsetInNode: s64) -> Document.BufferCursor {
	// Calculate a buffer cursor for a given offset _within_ the given node,
	// that is offset >= 0 && offset < node.length

	buffer := *pieceTree.buffers[piece.bufferIndex];
	offset := buffer_cursor_to_offset(buffer, piece.start) + offsetInNode;
	low := piece.start.line;
	high := piece.end.line;
	mid := 0;
	midStartOffset := 0;
	midEndOffset := 0;

	// we are trying to get low and high to be equal, which implies we've found the line
	while low <= high {
		mid = low + ((high - low) / 2);
		midStartOffset = buffer.lineStarts[mid];

		if mid == high
			break;

		midEndOffset = buffer.lineStarts[mid+1];

		// target is before the mid line
		if offset < midStartOffset {
			high = mid - 1;
		}
		// offset is at or above the end of mid line
		else if offset >= midEndOffset {
			low = mid + 1;
		}
		else {
			break;
		}
	}

	return .{mid, offset - midStartOffset};
}

buffer_cursor_to_offset :: (buffer: *Document.Buffer, pos: Document.BufferCursor) -> s64 {
	return buffer.lineStarts[pos.line] + pos.column;
}

buffer_line_start_count :: (start: Document.BufferCursor, end: Document.BufferCursor) -> s64 {
	return (end.line - start.line);
}

// Allocator helpers

tree_allocator :: (pieceTree: *Document) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *pieceTree.treeMemory };
}

buffer_allocator :: (pieceTree: *Document) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *pieceTree.bufferMemory };
}

other_allocator :: (pieceTree: *Document) -> Allocator {
	return Allocator.{ proc = flat_pool_allocator_proc, data = *pieceTree.otherMemory };
}

// Basic Red Black tree API

make_rb_tree :: (allocator: Allocator, piece: Document.Piece) -> *Document.Node {
	return new_node(allocator, .BLACK, .{ piece, 0, 0 }, null, null);
}

insert_node :: (allocator: Allocator, root: *Document.Node, piece: Document.Piece, at: s64) -> *Document.Node {
	if root == null then return make_rb_tree(allocator, piece);

	t :=  internal_insert(root.allocator, root, .{piece, 0, 0}, at, 0);
	return new_node(root.allocator, .BLACK, t.data, t.left, t.right);
}

remove_node :: (root: *Document.Node, at: s64) -> *Document.Node {
	t := internal_remove(root, at, 0);
	if t == null then return null;
	return new_node(root.allocator, .BLACK, t.data, t.left, t.right);
}

length :: (root: *Document.Node) -> s64 {
	if root == null {
		return 0;
	}
	return root.leftSubtreeLength + root.piece.length + length(root.right);
 }

lf_count :: (root: *Document.Node) -> s64 {
	if root == null {
		return 0;
	}
	return root.leftSubtreeLfCount + root.piece.lineFeedCount + lf_count(root.right);
}


// insertion helpers

new_node :: (allocator: Allocator, color: Document.Color, data: Document.NodeData, left: *Document.Node, right: *Document.Node) -> *Document.Node {
	newNode := New(Document.Node,,allocator);
	newNode.allocator = allocator;
	newNode.color = color;
	newNode.data = data;
	newNode.leftSubtreeLength = length(left);
	newNode.leftSubtreeLfCount = lf_count(left);
	newNode.left= left;
	newNode.right= right;
	return newNode;
}

internal_insert :: (allocator: Allocator, root: *Document.Node, nodeData: Document.NodeData, at: s64, totalOffset: s64) -> *Document.Node {
	// ending case of the recursion, just make a new leaf node
	if root == null {
		return new_node(allocator, .RED, nodeData, null, null);
	}

	// in this case we insert on the left side of the tree (modifying the left node)
	if at < (totalOffset + root.leftSubtreeLength + root.piece.length) {
		newLeft := internal_insert(allocator, root.left, nodeData, at, totalOffset);
		return balance(allocator, root.color, root.data, newLeft, root.right);
	}

	// in this case we insert on the right side of the tree (modifying the right node)
	else {
		newRight := internal_insert(allocator, root.right, nodeData, at, totalOffset + root.leftSubtreeLength + root.piece.length);
		return balance(allocator, root.color, root.data, root.left, newRight);
	}
}

balance :: (allocator: Allocator, c: Document.Color, data: Document.NodeData, left: *Document.Node, right: *Document.Node) -> *Document.Node {
	// We cannot have a parent and child both be red
	// so what we are doing here is checking for that case on either the left or right side
	// and if it is doubled, we rotate to fix it up
	// see  https://bartoszmilewski.com/2013/11/25/functional-data-structures-in-c-trees/

	// each case will find a possible double red, and rotate it such that the red violation percolates
	// up to the top of the tree. Repeatedly doing this will correct the tree
	if c == .BLACK && doubled_left(left) {
		newRight := new_node(allocator, .BLACK, data, left.right, right);
		return new_node(allocator, .RED, left.data, paint(left.left, .BLACK), newRight);
	}
	else if c == .BLACK && doubled_right(left) {
		newLeft := new_node(allocator, .BLACK, left.data, left.left, left.right.left);
		newRight := new_node(allocator, .BLACK, data, left.right.right, right);
		return new_node(allocator, .RED, left.right.data, newLeft, newRight);
	}
	else if c == .BLACK && doubled_left(right) {
		newLeft := new_node(allocator, .BLACK, data, left, right.left.left);
		newRight := new_node(allocator, .BLACK, right.data, right.left.right, right.right);
		return new_node(allocator, .RED, right.left.data, newLeft, newRight);
	}
	else if c == .BLACK && doubled_right(right) {
		newLeft := new_node(allocator, .BLACK, data, left, right.left);
		return new_node(allocator, .RED, right.data, newLeft, paint(right.right, .BLACK));
	}
	return new_node(allocator, c, data, left, right);
}

doubled_left :: (node: *Document.Node) -> bool {
	return node != null && node.color == .RED && node.left != null && node.left.color == .RED;
}

doubled_right :: (node: *Document.Node) -> bool {
	return node != null && node.color == .RED && node.right != null && node.right.color == .RED;
}

paint :: (node: *Document.Node, color: Document.Color) -> *Document.Node {
	assert(node != null);
	return new_node(node.allocator, color, node.data, node.left, node.right);
}

// Removal helpers

internal_remove :: (root: *Document.Node, at: s64, totalOffset: s64) -> *Document.Node {
	if root == null then return null;

	if at < totalOffset + root.leftSubtreeLength {
		return remove_left(root, at, totalOffset);
	}
	if at == totalOffset + root.leftSubtreeLength {
		return fuse(root.left, root.right);
	}
	return remove_right(root, at, totalOffset);
}

remove_left :: (root: *Document.Node, at: s64, totalOffset: s64) -> *Document.Node {
	newLeft := internal_remove(root.left, at, totalOffset);
	newNode := new_node(root.allocator, .RED, root.data, newLeft, root.right);

	if root.left && root.left.color == .BLACK {
		return balance_left(newNode);
	}
	return newNode;
}

remove_right :: (root: *Document.Node, at: s64, totalOffset: s64) -> *Document.Node {
	newRight := internal_remove(root.right, at, totalOffset + root.leftSubtreeLength + root.piece.length);
	newNode := new_node(root.allocator, .RED, root.data, root.left, newRight);

	if root.right && root.right.color == .BLACK {
		return balance_right(newNode);
	}
	return newNode;
}

balance_right :: (right: *Document.Node) -> *Document.Node {
	if right.right != null && right.right.color == .RED {
		return new_node(right.allocator, .RED, right.data, right.left, paint(right.right, .BLACK));
	}
	if right.left != null && right.left.color == .BLACK {
		newRight := new_node(right.allocator, .BLACK, right.data, paint(right.left, .RED), right.right);
		return balance(newRight);
	}
	if right.left != null && right.left.color == .RED && right.left.right != null && right.left.right.color == .BLACK {
		unbalancedNewLeft := new_node(right.allocator, .BLACK, right.left.data, paint(right.left.left, .RED), right.left.right.left);

		newLeft := balance(unbalancedNewLeft);
		newRight := new_node(right.allocator, .BLACK, right.data, right.left.right.right, right.right);

		return new_node(right.allocator, .RED, right.left.right.data, newLeft, newRight);
	}
	assert(false); // should be unreachable
	return right;
}

balance_left :: (left: *Document.Node) -> *Document.Node {
	if left.left != null && left.left.color == .RED {
		return new_node(left.allocator, .RED, left.data, paint(left.left, .BLACK), left.right);
	}
	if left.right != null && left.right.color == .BLACK {
		newLeft := new_node(left.allocator, .BLACK, left.data, left.left, paint(left.right, .RED));
		return balance(newLeft);
	}
	if left.right != null && left.right.color == .RED && left.right.left != null && left.right.left.color == .BLACK {
		unbalancedNewRight := new_node(left.allocator, .BLACK, left.right.data, left.right.left.right, paint(left.right.right, .RED));
		
		newRight := balance(unbalancedNewRight);
		newLeft := new_node(left.allocator, .BLACK, left.data, left.left, left.right.left.left);

		return new_node(left.allocator, .RED, left.right.left.data, newLeft, newRight);
	}
	assert(false); // should be unreachable
	return left;
}

balance :: (node: *Document.Node) -> *Document.Node {
	if node.left != null && node.left.color == .RED && node.right != null && node.right.color == .RED {
		left := paint(node.left, .BLACK);
		right := paint(node.right, .BLACK);
		return new_node(node.allocator, .RED, node.data, left, right);
	}
	assert(node.color == .BLACK);
	return balance(node.allocator, node.color, node.data, node.left, node.right);
}

fuse :: (left: *Document.Node, right: *Document.Node) -> *Document.Node {
	if left == null then return right;
	if right == null then return left;

	if left.color == .BLACK && right.color == .RED {
		return new_node(left.allocator, .RED, right.data, fuse(left, right.left), right.right);
	}

	if left.color == .RED && right.color == .BLACK {
		return new_node(left.allocator, .RED, left.data, left.left, fuse(left.right, right));
	}

	if left.color == .RED && right.color == .RED {
		fused := fuse(left.right, right.left);
		if fused != null && fused.color == .RED {
			newLeft := new_node(left.allocator, .RED, left.data, left.left, fused.left);
			newRight := new_node(left.allocator, .RED, right.data, fused.right, right.right);
			return new_node(left.allocator, .RED, fused.data, newLeft, newRight);
		}
		newRight := new_node(left.allocator, .RED, right.data, fused, right.right);
		return new_node(left.allocator, .RED, left.data, left.left, newRight);
	}

	assert(left.color == right.color && left.color == .BLACK);
	fused := fuse(left.right, right.left);
	if fused != null && fused.color == .RED {
		newLeft := new_node(left.allocator, .BLACK, left.data, left.left, fused.left);
		newRight := new_node(left.allocator, .BLACK, right.data, fused.right, right.right);
		return new_node(left.allocator, .RED, fused.data, newLeft, newRight);
	}
	newRight := new_node(left.allocator, .BLACK, right.data, fused, right.right);
	newNode := new_node(left.allocator, .RED, left.data, left.left, newRight);
	return balance_left(newNode);
}

// Line Length array management

calculate_longest_line :: (doc: *Document) {
	TaskData :: struct {
		document: *Document;
		documentCopy: *Document;
		longestLine: s32;
		longestLineLength: s32;
	}
	task:: (data: *void) {
		using taskData := cast(*TaskData , data);

		longestLine = 0;
		longestLineLength = 0;

		lineIterator := make_line_iterator(documentCopy);
		for lineIterator {
			if it.text.count > longestLineLength {
				longestLine = xx it_index;
				longestLineLength = xx it.text.count;
			}
		}
	}
	task_done :: (data: *void) {
		using taskData := cast(*TaskData , data);

		taskData.document.longestLine = taskData.longestLine;
		taskData.document.longestLineLength = taskData.longestLineLength;
		document_copy_free(taskData.documentCopy);
		free(taskData);
	}

	taskData := New(TaskData);
	taskData.document = doc;
	taskData.documentCopy = document_copy(doc);
	push_task(*asyncWorker, taskData, task, task_done);
}

// debug functions
 
check_black_node_invariant :: (node: *Document.Node) -> s32 {
	if node == null then return 1;

	if node.color == .RED && ((node.left && node.left.color == .RED) || (node.right && node.right.color == .RED)) {
		return 1;
	}

	l := check_black_node_invariant(node.left);
	r := check_black_node_invariant(node.right);

	if l != 0 && r != 0 && l != r
		return 0;

	if l != 0 && r != 0
		return ifx node.color == .RED then l else l + 1; 
	return 0;
}

satisfies_rb_invariants :: (node: *Document.Node) {
	if node == null || (node.left == null && node.right == null)
		return;
	assert(check_black_node_invariant(node) != 0);
}

pretty_print_tree :: (node: *Document.Node, prefix: string, isLeft: bool) {
	if node {
		print("%", prefix);

		if isLeft {
			print("|--");
		}
		else {
			print("L--");
		}

		print(" %(%,%)-(%,%)\n", ifx node.color == .RED then "R" else "B", node.piece.length, node.piece.lineFeedCount, node.leftSubtreeLength, node.leftSubtreeLfCount);
		// this version prints the node pointer value, helpful for tracking which node you're looking at in the debugger
		// print(" %-%(%,%)-(%,%)\n", node, ifx node.color == .RED then "R" else "B", node.piece.length, node.piece.lineFeedCount, node.leftSubtreeLength, node.leftSubtreeLfCount);

		pretty_print_tree(node.right, tprint("%1%2", prefix, ifx isLeft then "|   " else "    "), true);
		pretty_print_tree(node.left, tprint("%1%2", prefix, ifx isLeft then "|   " else "    "), false);
	}
}
