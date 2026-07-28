Language :: struct {
	// note we allocate memory for this (arrays/tables)
	// But it's intended this lives the whole duration of the program
	// So we do not free it
	name: string;
	url: string;
	revision: string;
	treesitterLang: *TSLanguage;

	Predicate :: struct {
		Type :: enum {
			MATCH;
			EQ_TEXT;
			EQ_CAPTURE;
			ANY_OF;
			EQ_KIND;
			SET;
		}
		type: Type;
		not: bool;
		captureIndex1: u32;
		captureIndex2: u32;
		regex: Regexp;
		basicStr: string;
		strings: [..]string;
	}

	Query :: struct {
		query: *TSQuery;
		cursor: *TSQueryCursor;
		// this is indexed by the pattern index
		// so for each pattern there is some number of predicates
		predicates: Table(u32, [..]Predicate);
	}
	highlightsQuery: Query;
	captureToHighlight: Table(u32, HighlightType);
	indentQuery: Query;
}

IndentationMetadata :: struct {
	immediate: bool;
	startAtSameLine: bool;
	avoidLastMatchingNext: bool;
	openDelimiter: string;
	closeDelimiter: string;
}
Indents :: struct {
	treeHash: s64;
	auto: Table(*void, IndentationMetadata);
	begin: Table(*void, IndentationMetadata);
	end: Table(*void, IndentationMetadata);
	dedent: Table(*void, IndentationMetadata);
	branch: Table(*void, IndentationMetadata);
	ignore: Table(*void, IndentationMetadata);
	align: Table(*void, IndentationMetadata);
	zero: Table(*void, IndentationMetadata);
}

HighlightType :: enum {
	NONE;
	FUNCTION;
	KEYWORD;
	VARIABLE;
	CONSTANT;
	STRING;
	TYPE;
	NAMESPACE;
	COMMENT;
	COUNT;
}

// should probably be in a config file or something?
staticLanguageData :: Language.[
	.{name="jai", url="https://github.com/constantitus/tree-sitter-jai.git", revision="e15938a94c931662aa3e38cc07dfb98cf7436a90"},
	.{name="cpp", url="https://github.com/tree-sitter/tree-sitter-cpp.git", revision="56455f4245baf4ea4e0881c5169de69d7edd5ae7"},
	.{name="c", url="https://github.com/tree-sitter/tree-sitter-c.git", revision="7fa1be1b694b6e763686793d97da01f36a0e5c12"},
	.{name="python", url="https://github.com/tree-sitter/tree-sitter-python.git", revision="26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64"},
];

LanguageFunc :: #type () -> *TSLanguage #c_call;
languages: Table(string, Language);
languagesMutex: Mutex;

get_language :: (_languageName: string) -> bool, *Language {
	languageName := _languageName;
	// TODO: proper remap table!!!
	if equal(languageName, "h") {
		languageName = "cpp";
	} 
	if equal(languageName, "py") {
		languageName = "python";
	} 

	if languageName.count == 0 return false, null;

	staticLangData: Language;
	supportsLang := false;
	for staticLanguageData {
		if it.name==languageName {
			staticLangData = it;
			supportsLang = true;
			break;
		}
	}

	if supportsLang == false {
		return false, null;
	}

	lock(*languagesMutex);
	lang, added := find_or_add(*languages, languageName);
	unlock(*languagesMutex);
	if !added {
		return true, lang;
	}

	basePath := get_app_base_path();
	libPath := tprint("%grammars/%.dll", basePath, languageName);
	if !file_exists(libPath) {
		return false, null;
	}

	// copy data from static lang stuff
	lang.* = staticLangData;

	// @todo: windows specific code here, need to move to platform_windows
	grammarLib := LoadLibraryA(temp_c_string(libPath));

	// Load the treesitter language structure
	functionName := tprint("tree_sitter_%", languageName);
	loadFunc := cast(LanguageFunc, GetProcAddress(grammarLib, temp_c_string(functionName)));
	lang.treesitterLang = loadFunc();
	
	lang.highlightsQuery = load_query(lang, "highlights");
	lang.indentQuery = load_query(lang, "indents");

	// build mapping table for highlight captures
	captureCount := ts_query_capture_count(lang.highlightsQuery.query);
	for captureIndex: 0..captureCount-1 {
		captureName: string;
		len:u32;
		captureName.data = ts_query_capture_name_for_id(lang.highlightsQuery.query, captureIndex, *len);
		captureName.count = xx len;

		highlightType := HighlightType.NONE;
		if contains(captureName, "function") {
			highlightType = .FUNCTION;
		}
		if contains(captureName, "keyword") {
			highlightType = .KEYWORD;
		}
		if contains(captureName, "variable") {
			highlightType = .VARIABLE;
		}
		if contains(captureName, "constant") {
			highlightType = .CONSTANT;
		}
		if contains(captureName, "string") {
			highlightType = .STRING;
		}
		if contains(captureName, "type") {
			highlightType = .TYPE;
		}
		if contains(captureName, "namespace") {
			highlightType = .NAMESPACE;
		}
		if contains(captureName, "comment") {
			highlightType = .COMMENT;
		}
		table_add(*lang.captureToHighlight, captureIndex, highlightType);
	}
	
	return true, lang;
}

load_query :: (language: *Language, queryName: string) -> Language.Query {
	query: Language.Query;

	basePath := get_app_base_path();
	queryPath := tprint("%queries/%/%.scm", basePath, language.name, queryName);
	file, success := read_entire_file(queryPath,,temp);
	if success == false {
		log("Failed to load query \"%\" for language \"%\"", queryName, language.name);
		return query;
	}
		
	// parse the file initially looking for inherits comments, and then paste the corresponding query text in 
	// doesn't support multiple includes for now
	foundInherits := find_index_from_left_fast(file, "; inherits:");
	if foundInherits >= 0 {
		rangeToRemove := 11;
		targetLang := file;
		targetLang.data += foundInherits + 11;
		for targetLang {
			if it == #char "\n" {
				targetLang.count = it_index;
				rangeToRemove += it_index;
			}
		}
		targetLang = trim(targetLang); 
		
		// we don't currently support recursive includes, not sure that we need it, but maybe something to keep an eye on?
		inheritsPath := tprint("%queries/%/%.scm", basePath, targetLang, queryName);
		inheritsFile, inheritsSuccess := read_entire_file(inheritsPath,,temp);
		if inheritsSuccess == false {
			log("Failed to load query \"%\" from inherits \"%\"", queryName, targetLang);
			return query;
		}
				
		builder : String_Builder;
		builder.allocator = temp;
	    init_string_builder(*builder);
	
        append(*builder, file.data, foundInherits);
        append(*builder, inheritsFile);
        append(*builder, file.data+rangeToRemove, file.count - foundInherits - rangeToRemove);
		
		file = builder_to_string(*builder);
	}

	errorLocation: u32;
	errorType: TSQueryError;
	query.query = ts_query_new(language.treesitterLang, file.data, xx file.count, *errorLocation, *errorType);
	if query.query == null {
		errorTypeStr := "None";
		if errorType == {
			case .None; errorTypeStr = "None";
			case .Syntax; errorTypeStr = "Syntax";
			case .NodeType; errorTypeStr = "NodeType";
			case .Field; errorTypeStr = "Field";
			case .Capture; errorTypeStr = "Capture";
			case .Structure; errorTypeStr = "Structure";
			case .Language; errorTypeStr = "Language";
		}
		// @todo: can probably make this nicer, figure out the line/column etc
		log("Query Error in file %: %Error at %", queryPath, errorTypeStr, errorLocation);
	}
	else {
		// Prepare information to speed up query use, such as predicate information
		
		query.cursor = ts_query_cursor_new();
		patternCount := ts_query_pattern_count(query.query);
		captureCount := ts_query_capture_count(query.query);
		stringCount := ts_query_string_count(query.query);

		// loop over all the patterns looking for predicates
		// We will save them all in a table to use later
		for patternIndex: 0..patternCount-1 {
			steps: *TSQueryPredicateStep;
			stepCount: u32;
			steps = ts_query_predicates_for_pattern(query.query, patternIndex, *stepCount);

			i: u32 = 0;
			while i<stepCount {
				if steps[i].type == .String {
					predicateName:string;
					len: u32;
					predicateName.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
					predicateName.count = len;

					if predicateName == "match?" || predicateName == "not-match?" {
						matchPredicate: Language.Predicate;
						matchPredicate.type = .MATCH;

						if contains(predicateName, "not") {
							matchPredicate.not = true;
						}

						// expect capture, then string
						i += 1;
						if steps[i].type != .Capture {
							log("Expected capture as first argument of match predicate");
							continue patternIndex;
						}

						matchPredicate.captureIndex1 = steps[i].value_id;

						// now grab the regex string
						i += 1;
						if steps[i].type != .String {
							log("Expected string as second argument of match predicate");
							continue patternIndex;
						}

						regex:string;
						len: u32;
						regex.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
						regex.count = len;

						matchPredicate.regex = compile(regex);

						predicateList, _ := find_or_add(*query.predicates, patternIndex);
						array_add(predicateList, matchPredicate);
						i += 1;
					}
					else if predicateName == "not-kind-eq?" || predicateName == "kind-eq?" {
						kindEqPredicate: Language.Predicate;
						kindEqPredicate.type = .EQ_KIND;

						if contains(predicateName, "not") {
							kindEqPredicate.not = true;
						}

						// expect capture, then string
						i += 1;
						if steps[i].type != .Capture {
							log("Expected capture as first argument of kind eq predicate");
							continue patternIndex;
						}

						kindEqPredicate.captureIndex1 = steps[i].value_id;

						// now grab the kind string
						i += 1;
						if steps[i].type != .String {
							log("Expected string as second argument of kind eq predicate");
							continue patternIndex;
						}

						kind:string;
						len: u32;
						kind.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
						kind.count = len;
						kindEqPredicate.basicStr = kind;

						predicateList, _ := find_or_add(*query.predicates, patternIndex);
						array_add(predicateList, kindEqPredicate);
						i += 1;
					}
					else if predicateName == "any-of?" || predicateName == "not-any-of?" {
						anyOfPredicate: Language.Predicate;
						anyOfPredicate.type = .ANY_OF;

						if contains(predicateName, "not") {
							anyOfPredicate.not = true;
						}

						i += 1;
						if steps[i].type != .Capture {
							log("Expected capture as first argument of any-of predicate");
							continue patternIndex;
						}

						anyOfPredicate.captureIndex1 = steps[i].value_id;

						i += 1;
						while steps[i].type != .Done {
							if steps[i].type != .String {
								log("Expected string as argument of any-of predicate");
								continue patternIndex;
							}

							candidate:string;
							len: u32;
							candidate.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
							candidate.count = len;

							i += 1;
							array_add(*anyOfPredicate.strings, candidate);
						}

						predicateList, _ := find_or_add(*query.predicates, patternIndex);
						array_add(predicateList, anyOfPredicate);
					}
					else if predicateName == "eq?" || predicateName == "not-eq?" {
						eqPredicate: Language.Predicate;
						eqPredicate.type = .EQ_TEXT;

						if contains(predicateName, "not") {
							eqPredicate.not = true;
						}

						i += 1;
						if steps[i].type != .Capture {
							log("Expected capture as first argument of eq predicate");
							continue patternIndex;
						}

						eqPredicate.captureIndex1 = steps[i].value_id;

						i += 1;
						if steps[i].type == .String {
							eqPredicate.type = .EQ_TEXT;

							otherStr:string;
							len: u32;
							otherStr.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
							otherStr.count = len;
							eqPredicate.basicStr = otherStr;
						}
						else if steps[i].type == .Capture {
							eqPredicate.captureIndex2 = steps[i].value_id;
							eqPredicate.type = .EQ_CAPTURE;
						}
						else {
							log("Unexpected second predicate argument in eq predicate, must be string or capture");
							continue patternIndex;
						}

						predicateList, _ := find_or_add(*query.predicates, patternIndex);
						array_add(predicateList, eqPredicate);
						i += 1;
					}
					else if predicateName == "set!" {
						// You're given two parameters
						// a name, and then a string argument
						// You want to store this as metadata in the predicate
						// such that if someone matches this pattern, then the metadata will have this information
						// the metadata is basically a map of string to string
						setPredicate: Language.Predicate;
						setPredicate.type = .SET;

						// expect string, then string
						i += 1;
						if steps[i].type != .String {
							log("Expected string as first argument of set predicate");
							continue patternIndex;
						}

						metaDataKey:string;
						len: u32;
						metaDataKey.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
						metaDataKey.count = len;
						setPredicate.basicStr = metaDataKey;

						// now grab the value
						i += 1;
						if steps[i].type != .String {
							log("Expected string as second argument of set predicate");
							continue patternIndex;
						}

						metaDataValue:string;
						metaDataValue.data = ts_query_string_value_for_id(query.query, steps[i].value_id, *len);
						metaDataValue.count = len;
						array_add(*setPredicate.strings, metaDataValue);

						predicateList, _ := find_or_add(*query.predicates, patternIndex);
						array_add(predicateList, setPredicate);
						i += 1;
					}
					else {
						log("Unknown predicate type %", predicateName);
						break;
					}
				}
				else if steps[i].type == .Done {
					i += 1;
					continue;
				}
				else {
					log("Unexpected element in predicate");
				}
			}
		}
	}
	return query;
}

calculate_indentation_for_line :: (document: *Document, lineNumber:s64) -> string {
	tabsOverSpaces :: true;
	verboseLogging :: true;
	
	supportsAutoIndentation := document.language && document.tsTree && document.language.indentQuery.query;
	if !supportsAutoIndentation
		return "";
		
	lock(*document.reparseMutex);
	defer unlock(*document.reparseMutex);

	// figure out if we need to requery the indentation of a file, if we do then we do it here
	treeHash := get_hash(document.tree);
	if treeHash != document.indents.treeHash {
		if verboseLogging log("rehash of indents triggered");
		
		table_reset(*document.indents.auto); 
		table_reset(*document.indents.begin); 
		table_reset(*document.indents.end); 
		table_reset(*document.indents.dedent); 
		table_reset(*document.indents.branch); 
		table_reset(*document.indents.ignore); 
		table_reset(*document.indents.align); 
		table_reset(*document.indents.zero); 
	
		rootNode := ts_tree_root_node(document.tsTree);
		query_start(*document.language.indentQuery, ts_tree_root_node(document.tsTree), ts_node_start_byte(rootNode), ts_node_end_byte(rootNode));
		while true {
			result, capture, patternIndex, metadataTable := query_next(*document.language.indentQuery, document,,temp);
			if result == false then break;
			
			captureName := get_capture_name(capture, *document.language.indentQuery,,temp);
			
			#if verboseLogging {
				nodeStartLine := ts_node_start_point(capture.node).row;
				nodeEndLine := ts_node_end_point(capture.node).row;
				log("Node: %::% (%,%) (%:%,%:%)--> % patternIndex:%", capture.node.id, to_string(ts_node_type(capture.node)), ts_node_start_byte(capture.node), ts_node_end_byte(capture.node), nodeStartLine, ts_node_start_point(capture.node).column, nodeEndLine, ts_node_end_point(capture.node).column, captureName, patternIndex);
			}
			
			metadata: IndentationMetadata;
			if metadataTable.count > 0 {
				for metadataTable {
					if it_index == {
						case "indent.immediate"; metadata.immediate = true;
						case "indent.start_at_same_line"; metadata.startAtSameLine = true;
						case "indent.avoid_last_matching_next"; metadata.avoidLastMatchingNext = true;
						case "indent.open_delimiter"; metadata.openDelimiter = it;
						case "indent.close_delimiter"; metadata.closeDelimiter = it;
						case; continue;
					}
				}
			}
			
			if captureName == {
				case "indent.auto"; table_set(*document.indents.auto, capture.node.id, metadata);
				case "indent.begin"; table_set(*document.indents.begin, capture.node.id, metadata);
				case "indent.end"; table_set(*document.indents.end, capture.node.id, metadata);
				case "indent.dedent"; table_set(*document.indents.dedent, capture.node.id, metadata);
				case "indent.branch"; table_set(*document.indents.branch, capture.node.id, metadata);
				case "indent.ignore"; table_set(*document.indents.ignore, capture.node.id, metadata);
				case "indent.align"; table_set(*document.indents.align, capture.node.id, metadata);
				case "indent.zero"; table_set(*document.indents.zero, capture.node.id, metadata);
				case; continue;
			}
		}	
		document.indents.treeHash = treeHash;
	}
	
	push_allocator(temp);
	
	// calculate the node that we want to start with for the indentation calculation
	first_non_whitespace :: (text: string) -> s64 {
		for text {
			if !is_space(it) {
				return it_index; 
			}
		}
		return -1;
	}

	last_non_whitespace :: (text: string) -> s64 {
		for < text {
			if !is_space(it) {
				return it_index; 
			}
		}
		return -1;
	}
	
	line := get_line_content(document, lineNumber);
	firstNonWhitespace := first_non_whitespace(line.text);
	startNode := ts_tree_root_node(document.tsTree);

	if lineNumber > 0 && firstNonWhitespace < 0 {
		// line is blank, so we look at the end of the previous line
		prevLine := get_line_content(document, lineNumber - 1); 	// TODO: handle start of file
		lastNonWhitespace := prevLine.startByteOffset + last_non_whitespace(prevLine.text);
		
		if lastNonWhitespace < 0 then return "";

		startNode = ts_node_descendant_for_byte_range(startNode, xx lastNonWhitespace, xx (lastNonWhitespace+1));

		if get_node_type(startNode) == "comment" {
			nodeAtStartOfPrevLine := startNode;
			for prevLine.text {
				if !is_space(it) {
					nodeAtStartOfPrevLine = ts_tree_root_node(document.tsTree);
					nodeAtStartOfPrevLine = ts_node_descendant_for_byte_range(nodeAtStartOfPrevLine, xx (prevLine.startByteOffset + it_index), xx (prevLine.startByteOffset + it_index+1));
					break;
				}
			}

			// If startNode is a full line comment, we'll just use that, but if it's a trailing comment we want the node just before it
			if nodeAtStartOfPrevLine.id != startNode.id {
				prevLine.text.count -= prevLine.endByteOffset - ts_node_start_byte(startNode);
				nonCommentOffset := prevLine.startByteOffset + last_non_whitespace(prevLine.text);
				startNode = ts_tree_root_node(document.tsTree);
				startNode = ts_node_descendant_for_byte_range(startNode, xx nonCommentOffset, xx (nonCommentOffset+1));
			}
		}

		end := table_find(*document.indents.end, startNode.id);
		if !ts_node_is_null(startNode) && end {
			offset := line.startByteOffset;
			startNode = ts_tree_root_node(document.tsTree);
			startNode = ts_node_descendant_for_byte_range(startNode, xx offset, xx (offset+1));
		}
	}
	else if firstNonWhitespace >= 0 {
		// line is NOT blank, so get first node on the line
		offset := line.startByteOffset + firstNonWhitespace;
		startNode = ts_node_descendant_for_byte_range(startNode, xx offset, xx (offset+1));
	}
	else {
		startNode = ts_node_descendant_for_byte_range(startNode, 0, 0);
	}


	#if verboseLogging {
		log("Start node: %  %\ncontent: %", startNode.id, to_string(ts_node_string(startNode)), get_node_content(startNode, document,,temp));
	}



	zeroFound := table_find(*document.indents.zero, startNode.id);
	if !ts_node_is_null(startNode) && zeroFound {
		return "";
	}

	#if verboseLogging {
		log("Walk line:%", lineNumber);
	}
	
	find_delimiter_node :: (doc: *Document, node: TSNode, delimiter: string) -> TSNode, bool {
		if ts_node_child_count(node) == 0 {
			return TSNode.{}, false;
		}
			
		for 0..ts_node_child_count(node)-1 {
			child := ts_node_child(node, it);
			if !ts_node_is_null(child) && get_node_type(child) == delimiter {
				childStartOffset := ts_node_start_byte(child);
				childStart := get_coordinate_from_offset(doc, childStartOffset);
				line := get_line_content(doc, childStart.line);
				lineFromDelimiterOnward := slice(line.text, childStart.col+1, line.text.count - childStart.col);
				
				delimiterIsLastOnLine := true;
				for lineFromDelimiterOnward {
					if compare(slice(lineFromDelimiterOnward, it_index, delimiter.count), delimiter) || !is_space(it) {
						delimiterIsLastOnLine = false;
						break;
					}
				}
				return child, delimiterIsLastOnLine;
			}
		}
		return TSNode.{}, false;
	}
	
	// walk up the tree from our start node through the parent
	node := startNode;
	indentLevel := 0;
	processedLines : Table(s64, bool);
	while !ts_node_is_null(node) {
		nodeStartOffset := ts_node_start_byte(node);
		nodeEndOffset := ts_node_end_byte(node);
		
		nodeStart := get_coordinate_from_offset(document, nodeStartOffset);
		nodeEnd := get_coordinate_from_offset(document, nodeEndOffset);

		if verboseLogging {
			log("Node: %::% (%,%) (%:%,%:%)", node.id, to_string(ts_node_type(node)), nodeStartOffset, nodeEndOffset, nodeStart.line, nodeStart.col, nodeEnd.line, nodeEnd.col);
		}

		found, alreadyProcessed := false;
		found, alreadyProcessed = table_find(*processedLines, nodeStart.line);
		isProcessed := false;

		branchFound, branch := table_find(*document.indents.branch, node.id); if verboseLogging && branchFound then log("indent.branch");
		autoFound, auto := table_find(*document.indents.auto, node.id); if verboseLogging && autoFound then log("indent.auto");
		dedentFound, dedent := table_find(*document.indents.dedent, node.id); if verboseLogging && dedentFound then log("indent.dedent");
		beginFound,  begin := table_find(*document.indents.begin, node.id); if verboseLogging && beginFound then log("indent.begin");
		ignoreFound, ignore := table_find(*document.indents.ignore, node.id); if verboseLogging && ignoreFound then log("indent.ignore");
		alignFound, align := table_find(*document.indents.align, node.id); if verboseLogging && alignFound then log("indent.align");
		
		// if we encounter an indent.auto, then we fallback to copying the indentation from the previous line
		if !beginFound && !alignFound && autoFound && nodeStart.line < lineNumber && lineNumber <= nodeEnd.line {
			prevLine := get_line_content(document, lineNumber-1);
			for prevLine.text {
				if it == #char "\t" then indentLevel += tabSize;
				if it == #char " " then indentLevel += 1;
				if !is_space(it) then break;
			}
			log("indent.auto triggered");
			break;
		}
		
		// indent.ignore just gives back no indentation
		if !beginFound && ignoreFound && nodeStart.line <= lineNumber && lineNumber <= nodeEnd.line {
			indentLevel = 0;
			break;
		}
		
		// indent.branch and indent.dedent reduce the indentation level by one
		if !alreadyProcessed &&
			( (branchFound && nodeStart.line == lineNumber) 
			|| (dedentFound && nodeStart.line != lineNumber)) {
			indentLevel -= tabSize;
			isProcessed = true;
		}

		shouldProcess := !alreadyProcessed && !isProcessed;

		// indent.begin is the primary contributor to indentation
		if shouldProcess && beginFound {
	        validRange := (nodeStart.line != nodeEnd.line) || begin.immediate;
	        validStart := (nodeStart.line != lineNumber) || begin.startAtSameLine;
	
	        if validRange && validStart {
	            indentLevel += tabSize;
	            isProcessed = true;
	        }
		}
		
		
		// indent.align is the most complex case, we align by some opening delimiter
		// usually you see this in parameter blocks of functions
		isAbsoluteIndentation := false;
		if shouldProcess && alignFound {
	        validStart := (nodeStart.line != lineNumber);
			if validStart {
				
				// we need to find the open and close delimiter nodes now
				openDelimiter, openIsLastOnLine := find_delimiter_node(document, node, align.openDelimiter);
				closeDelimiter, closeIsLastOnLine := find_delimiter_node(document, node, align.closeDelimiter);
				
				openStartOffset := ts_node_start_byte(openDelimiter);
				open := get_coordinate_from_offset(document, openStartOffset);
				closeStartOffset := ts_node_start_byte(closeDelimiter);
				close := get_coordinate_from_offset(document, closeStartOffset);
				
				// this is a hanging indent, we treat this as though it's a normal indent.begin
				if openIsLastOnLine {
					if !(closeIsLastOnLine && close.line < lineNumber) {
						indentLevel += tabSize;
					}
				}
				// in this case it's an aligned indent, and we will indent to align with the open delimiter
				else {
					if closeIsLastOnLine && close.line != open.line && close.line < lineNumber {
						indentLevel = max(indentLevel - tabSize, 0);
					}
					else {
						// this is an absolute position, so set it and bail
						indentLevel = open.col + 1;
						isAbsoluteIndentation = true;
					}
				}
				
				avoidLastMatchingNext := false;
				if close.line != open.line && close.line == lineNumber {
					avoidLastMatchingNext = align.avoidLastMatchingNext;
				}
				if avoidLastMatchingNext {
					// we need the indentation of the line containing the open delimiter
					openLine := get_line_content(document, open.line);
					openLineIndentation := 0;
					for openLine.text {
						if it == #char "\t" then openLineIndentation += tabSize;
						if it == #char " " then openLineIndentation += 1;
						if !is_space(it) then break;
					}
					
					if indentLevel <= openLineIndentation + tabSize {
						indentLevel += tabSize;
					}
				}
				
	            isProcessed = true;
			}
		}

		#if verboseLogging {
			log("level %", indentLevel);
		}
		node = ts_node_parent(node);

		table_set(*processedLines, nodeStart.line, alreadyProcessed || isProcessed);
		
		if isAbsoluteIndentation then break;
	}
	
	// build the final indentation string
	builder : String_Builder;
	builder.allocator = temp;
	init_string_builder(*builder);

	// if we're using tabs over spaces
	if tabsOverSpaces {
		tabsToInsert := cast(s64, floor(cast(float,indentLevel)/cast(float,tabSize)));
		for 1..tabsToInsert {
			append(*builder, "\t");
		}
		remainder := indentLevel % tabSize;
		for 1..remainder {
			append(*builder, " ");
		}
	}
	else {
		for 0..indentLevel {
			append(*builder, " ");
		}
	}
	

	return builder_to_string(*builder,,temp);
}

fetch_grammars :: () {
	// Have a list of grammar repositories
	// Clone them at a certain revision

	verboseOutput := false;

	// @todo: check that git actually exists on this machine
	// @todo: error if not on windows

	for staticLanguageData {
		directory := tprint("grammars/sources/%", it.name);

		// @todo: check if directory exists and if so check what revision before doing a clone
		if file_exists(directory) {
			delete_directory(directory);
		}
		
		log("Fetching %..", it.name);
		make_directory_if_it_does_not_exist(directory);
		result, output, error := run_command("git", "clone", "--no-checkout", it.url, directory, capture_and_return_output=true);
		if verboseOutput {
			log("%", output);
		}
		if result.exit_code != 0 {
			log_error("Error!");
			log_error("Output:\n%", output);
			log_error("Errors:\n%", error);
		}

		result, output, error = run_command("git", "-C", directory, "checkout", it.revision, capture_and_return_output=true);
		if verboseOutput {
			log("%", output);
		}
		if result.exit_code != 0 {
			log_error("Error!");
			log_error("Output:\n%", output);
			log_error("Errors:\n%", error);
		}
	}
}

build_grammars :: () {
	// set up compile environment
	vcPath, linkerPath := find_visual_studio_in_a_ridiculous_garbage_way();
	compiler := join(linkerPath, "\\", "cl.exe");
	windowsKit := find_windows_kit_root();
	vcIncludePath := join(vcPath, "\\..\\..\\include");
	windowsKitInclude := replace(windowsKit, "Lib", "Include");

	// @todo: error if you can't find visual studio

	verboseOutput := false;
	for staticLanguageData {
		log("Compiling %..", it.name);
		directory := tprint("grammars/sources/%", it.name);

		args: [..] string;
		array_add(*args, compiler);
		defer array_free(args);

		array_add(*args, "src\\parser.c");
		if file_exists(tprint("%\\src\\scanner.c", directory)) {
			array_add(*args, "src\\scanner.c");
		}
		array_add(*args,
			"/O2",                      // Maximize speed.
			"/Oi",                      // Enable intrinsics.
			// "/Zi",
		);

		array_add(*args,
			tprint("/I%", vcIncludePath),
			tprint("/I%\\um", windowsKitInclude),
			tprint("/I%\\ucrt", windowsKitInclude),
			tprint("/I%\\shared", windowsKitInclude),
		);
		
		array_add(*args, "/link");
		array_add(*args, "/DLL");
		array_add(*args, "/MACHINE:AMD64");
		array_add(*args, tprint("/OUT:%.dll", it.name));
		array_add(*args,
			tprint("/libpath:%", vcPath),
			tprint("/libpath:%\\um\\x64", windowsKit),
			tprint("/libpath:%\\ucrt\\x64", windowsKit),
		);
		
		result, output, error := run_command(..args, capture_and_return_output=true, working_directory=directory);
		if verboseOutput {
			log("%", output);
		}
		if result.exit_code != 0 {
			log_error("Error!");
			log_error("Output:\n%", output);
			log_error("Errors:\n%", error);
			return;
		}
		copy_file(tprint("%/%.dll", directory, it.name), tprint("grammars/%.dll", it.name));
	}
}

query_start :: (query: *Language.Query, startNode: TSNode, startByte: s64, endByte: s64) {
	ts_query_cursor_set_byte_range(query.cursor, xx startByte, xx endByte);
	ts_query_cursor_exec(query.cursor, query.query, startNode);
}

// allocates memory for the metadata table, put in temp or free on your own
// note the strings in the table are not allocated, they will point to the query predicate data
query_next :: (query: *Language.Query, text: $T) -> bool, capture: TSQueryCapture, patternIndex: s64, metadata: Table(string, string)
#modify {
	if T == *Document || T == string then return true;
	return false;
} {

	evaluate_query_predicates :: (query: *Language.Query, tsMatch: TSQueryMatch, text: $T) -> bool, Table(string, string) {
		predicateList := table_find_pointer(*query.predicates, tsMatch.pattern_index);
		if predicateList == null then return true, .{};
	
		// I want to make it clear cause I keep fucking this up, but captureIndex, as in capture.index is the
		// index of the capture in the query source
		// get_next_capture on a query returns an index which is an index into the list of captures of the match
		// these indices are NOT the same
		// here we use capture.index because this is what the predicate source specifies. DO NOT MIX IT UP
	
		metadata: Table(string, string) = .{};
		result := true;
		for predicate: predicateList.* {
			if predicate.type == {
				case .MATCH;
					captureText := get_capture_content(find_capture(tsMatch, predicate.captureIndex1), text,,temp);
					matched, captures := match(captureText, predicate.regex,,temp);
					test := ifx predicate.not then !matched else matched;
					result = result && test;
				case .EQ_KIND;
					captureKind := get_node_type(find_capture(tsMatch, predicate.captureIndex1).node);
					test := ifx predicate.not then captureKind != predicate.basicStr else captureKind == predicate.basicStr;
					result = result && test;
				case .ANY_OF;
					captureText := get_capture_content(find_capture(tsMatch, predicate.captureIndex1), text,,temp);
					matched := false;
					for predicate.strings {
						if captureText == it then matched = true;
					}
					test := ifx predicate.not then !matched else matched;
					result = result && test;
				case .EQ_TEXT;
					captureText := get_capture_content(find_capture(tsMatch, predicate.captureIndex1), text,,temp);
					test := ifx predicate.not then captureText != predicate.basicStr else captureText == predicate.basicStr;
					result = result && test;
				case .EQ_CAPTURE;
					captureText1 := get_capture_content(find_capture(tsMatch, predicate.captureIndex1), text,,temp);
					captureText2 := get_capture_content(find_capture(tsMatch, predicate.captureIndex2), text,,temp);
					test := ifx predicate.not then captureText1 != captureText2 else captureText1 == captureText2;
					result = result && test;
				case .SET;
					assert(predicate.strings.count == 1, "This is a set predicate, but no value is available to set in the predicate source");
					table_set(*metadata, predicate.basicStr, predicate.strings[0]);
					continue;
				case;
					continue;
			}
		}
	
		// all predicates passed
		return result, metadata;
	}
	
	while true {
		tsMatch: TSQueryMatch;
		captureId: u32;
		result := ts_query_cursor_next_capture(query.cursor, *tsMatch, *captureId);
		if result == false then return false, .{}, 0, .{};
	
		capture := tsMatch.captures[captureId];
		passed, metadata := evaluate_query_predicates(query, tsMatch, text);
		if passed {
			return true, capture, tsMatch.pattern_index, metadata;
		}
	}
	return false, .{}, 0, .{};
}

// allocates memory for the returned string
get_node_content :: (node: TSNode, doc: *Document) -> string {
	startByte := ts_node_start_byte(node);
	endByte := ts_node_end_byte(node);

	// need to find the text corresponding to this node
	text := alloc_string(endByte-startByte);
	iter := make_iterator(doc, startByte);
	for iter {
		if it_index >= text.count break;
		text[it_index] = it;
	}
	return text;
}

// allocates memory for the returned string
get_capture_content :: (capture: TSQueryCapture, doc: *Document) -> string {
	return get_node_content(capture.node, doc);
}

// allocates memory for the returned string, doesn't strictly need to but it ensures we have the same
// api as the document version of this function
get_capture_content :: (capture: TSQueryCapture, text: string) -> string {
	startByte := ts_node_start_byte(capture.node);
	endByte := ts_node_end_byte(capture.node);
	return copy_string(slice(text, startByte, endByte-startByte));
}

get_capture_name :: (capture: TSQueryCapture, query: *Language.Query) -> string {
	captureName: string;
	len:u32;
	captureName.data = ts_query_capture_name_for_id(query.query, capture.index, *len);
	captureName.count = xx len;
	return captureName;
}

get_node_type :: (node: TSNode) -> string {
	return to_string(ts_node_type(node));
}

find_capture :: (tsMatch: TSQueryMatch, captureIndex: u32) -> TSQueryCapture {
	capture: TSQueryCapture;
	for 0..tsMatch.capture_count-1 {
		if tsMatch.captures[it].index == captureIndex {
			capture = tsMatch.captures[it];
			break;
		}
	}
	return capture;
}
