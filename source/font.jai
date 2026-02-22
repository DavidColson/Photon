
FontCache :: struct {
	freetype : FT_Library;
	atlasList: [..]Atlas;
	pool: Flat_Pool;
	allocator: Allocator;
}

Font :: struct {
	fileData: []u8;
	face: FT_Face;

	drawTabs: bool;
	drawLineEndings: bool;

	tabSize: s32;

	hasKerning: bool;
	// keyed by size currently
	styleTable: Table(int, FontStyle);
}

FontStyle :: struct {
	// keyed by glyphIndex in the font face
	glyphTable: Table(u32, GlyphData);
	metrics: FontMetrics;
}

FontMetrics :: struct {
	characterHeight: int;
	typicalAscender: int;
	typicalDescender: int;
	maxDescender: int;
	maxAscender: int;
	lineSpacing: int;
}

GlyphData :: struct {
	index: u32;
	atlas: s32;
	subRect: Rect;
	offsetX: float;
	offsetY: float;
	advance: float;
}

TextRun :: struct {
	instances: []Instance;
	byteOffsets: []s32;
	 
	// in pixels
	height: float;
	width: float; 
}

init_font_cache :: () {
	// initialize freetype
	error := FT_Init_FreeType(*fontCache.freetype);
	assert(!error);

	fontCache.allocator = Allocator.{ proc = flat_pool_allocator_proc, data = *fontCache.pool };
	fontCache.atlasList.allocator = fontCache.allocator;

	// setup our first atlas
	atlas := array_add(*fontCache.atlasList);
	atlas.nodes.allocator = fontCache.allocator;
	alloc_bitmap(*atlas.texture, 1024, 1024, .R8,,fontCache.allocator);

	initialNode := array_add(*atlas.nodes);
	initialNode.x = 0;
	initialNode.y = 0;
	initialNode.width = atlas.texture.width;
}

load_font :: (filename: string, drawTabs:= false, tabSize := 4, drawLineEndings := false) -> *Font, bool {
	// we support loading fonts from windows font folders. If the path is absolute, then we'll just do that
	path: string;
	if !is_absolute_path(filename) {
		// search in windows
		windowsSystem := tprint("C:\\Windows\\Fonts\\%", filename);
		if file_exists(windowsSystem) {
			path = windowsSystem;
		}
		windowsUser := tprint("%\\AppData\\Local\\Microsoft\\Windows\\Fonts\\%", get_home_directory(), filename);
		if file_exists(windowsUser) {
			path = windowsUser;
		}
	}
	else {
		if file_exists(filename) {
			path = filename;
		}
	}

	if path.count == 0 {
		return null, false;
	}

	font := New(Font);

	// load the file
	file, success := read_entire_file(path,,fontCache.allocator);
	assert(success);
	font.fileData.data = file.data;
	font.fileData.count = file.count;

	error := FT_New_Memory_Face(fontCache.freetype, file.data, xx file.count, 0, *font.face);
	assert(!error);
	font.styleTable.allocator = fontCache.allocator;

	font.drawTabs = drawTabs;
	font.drawLineEndings = drawLineEndings;
	font.tabSize = xx tabSize;

	return font, true;
}

load_font_from_memory :: (data: string) -> *Font {
	font := New(Font);

	font.fileData.data = data.data;
	font.fileData.count = data.count;

	error := FT_New_Memory_Face(fontCache.freetype, data.data, xx data.count, 0, *font.face);
	assert(!error);
	font.styleTable.allocator = fontCache.allocator;

	return font;
}

get_font_metrics :: (font: *Font, size: int) -> FontMetrics {
	fontStyle,newStyle := find_or_add(*font.styleTable, size);

	// cache miss
	// @todo: duplicated from find_or_make_glyph
	if newStyle {
		fontStyle.glyphTable.allocator = fontCache.allocator;
		FT_Set_Pixel_Sizes(font.face, 0, xx size);

		// calculate basic metrics
		fontStyle.metrics.characterHeight = size;
		glyphIndexTemp := FT_Get_Char_Index(font.face, #char "T");
		if glyphIndexTemp {
			FT_Load_Glyph(font.face, glyphIndexTemp, FT_LOAD_DEFAULT);
			fontStyle.metrics.typicalAscender = FT_ROUND(font.face.glyph.metrics.horiBearingY);
		}

		glyphIndexTemp = FT_Get_Char_Index(font.face, #char "g");
		if glyphIndexTemp {
			FT_Load_Glyph(font.face, glyphIndexTemp, FT_LOAD_DEFAULT);
			fontStyle.metrics.typicalDescender = FT_ROUND(font.face.glyph.metrics.horiBearingY - font.face.glyph.metrics.height);
		}

		scale := font.face.size.metrics.y_scale/(64.0*65536.0);
		fontStyle.metrics.lineSpacing = cast(int) floor(scale * font.face.height + 0.5);
		fontStyle.metrics.maxAscender  = cast(int) floor(scale * font.face.bbox.yMax + 0.5);
		fontStyle.metrics.maxDescender = cast(int) floor(scale * font.face.bbox.yMin + 0.5);
	}
	return fontStyle.metrics;
}

generate_text_run :: (text: string, size: int, font: *Font, startCol := 0, stopAtWidth := FLOAT32_MAX) -> TextRun {
	textCopy := text;
	nCodepoints := 0;
	while textCopy.count > 0 {
		nBytes := 1 + trailingBytesForUTF8[textCopy[0]];
		textCopy.data += nBytes; 
		textCopy.count -= nBytes; 
		nCodepoints += 1;
	}
	
	result: TextRun;
	result.width = 0;
	result.height = 0;
	result.instances = NewArray(nCodepoints,Instance);
	result.byteOffsets = NewArray(nCodepoints,s32);

	textCopy = text;
	prevGlyphIndex: u32 = 0;
	i := 0;
	x := 0.0;
	byteOffsetCounter := 0;
	col := startCol;
	while textCopy.count > 0 {
		countStart := textCopy.count;
		utf32,success := utf8_next_character(*textCopy);
		bytes := countStart - textCopy.count;

		if success == .CONVERSION_OK {
			glyphData := find_or_make_glyph(font, size, utf32);
			glyphIndex := get_glyph_index(font, utf32);

			if FT_HAS_KERNING(font.face) {
				delta:FT_Vector = ---;
				FT_Get_Kerning(font.face, prevGlyphIndex, glyphIndex, xx FT_Kerning_Mode.DEFAULT, *delta);
				result.width += (delta.x >> 6);
				x += (delta.x >> 6);
			}

			result.instances[i] = .{
				dstRect = .{x + glyphData.offsetX, -glyphData.offsetY, glyphData.subRect.w / 3.0, glyphData.subRect.h},
				srcRect = glyphData.subRect,
				color = .{1.0, 1.0, 1.0, 1.0},
				cornerRadii = .{0.0, 0.0, 0.0, 0.0},
				edgeSoftness = 0.0,
				borderThickness = 0.0,
				texture = *fontCache.atlasList[glyphData.atlas].texture,
				shader = .TEXT
			};

			result.byteOffsets[i] = xx byteOffsetCounter;

			// tab handling
			width: float;
			if utf32 != #char "\t" {
				width = glyphData.advance;
				x += glyphData.advance;
				col += 1;
			} else {
				charsToTabstop := font.tabSize - col % font.tabSize;
				width = charsToTabstop * glyphData.advance;
				x += charsToTabstop * glyphData.advance;
				col += charsToTabstop;
			}

			result.width += width;
			result.height = max(glyphData.subRect.h, result.height);

			prevGlyphIndex = glyphIndex;

		}
		byteOffsetCounter += bytes;
		i += 1;

		if result.width >= stopAtWidth {
			result.instances.count = i;
			result.byteOffsets.count = i;
			break;
		}
	}
	return result;
}

draw_text_run :: (textRun: TextRun, x: float, y: float, color: Vector4) {

	// drawing fuzzy matches?

	// We essentially want a list of ranges with a color
	// this may not cover everything
	// so when you render the text, if there is a gap between the current character
	// and the start of the next node, render it with default color
	// otherwise use the color of the node and render up to the end of the node
	// then go to the next node
	// once again, if it is further away render without a color, repeat
	for textRun.instances {
		instance := it;
		instance.dstRect.x = round(x + instance.dstRect.x);
		instance.dstRect.y = round(y + instance.dstRect.y);
		instance.color = color;
		submit_instance(instance);
	}
}

draw_text_run_highlights :: (textRun: TextRun, x: float, y: float, highlights: []Highlight, color: Vector4, highlightColor: Vector4) {

	currHighlightIndex := 0;
	currHighlight := Highlight.{};
	if currHighlightIndex < highlights.count {
		currHighlight = highlights[currHighlightIndex];
	}

	for textRun.instances {
		instance := it;
		instance.dstRect.x = round(x + instance.dstRect.x);
		instance.dstRect.y = round(y + instance.dstRect.y);

		if it_index >= currHighlight.end {
			currHighlightIndex += 1;
			if currHighlightIndex < highlights.count {
				currHighlight = highlights[currHighlightIndex];
			}
			else {
				currHighlight = Highlight.{};
			}
		}

		if it_index >= currHighlight.start && it_index < currHighlight.end {
			instance.color = highlightColor;
		}
		else {
			instance.color = color;
		}

		submit_instance(instance);
	}
}

draw_text :: (text: string, size: int, font: *Font, x: float, y: float) {
	run := generate_text_run(text, size, font,,temp);
	draw_text_run(run, x, y, .{1.0, 1.0, 1.0, 1.0});
}



#scope_file

Atlas :: struct {
	texture: Bitmap;
	nodes: [..]AtlasNode;
}

AtlasNode :: struct {
	x: s32;
	y: s32;
	width: s32;
}

get_glyph_index :: (font: *Font, utf32: u32) -> u32 {
	if font.drawTabs {
		if utf32 == #char "\t" then utf32 = #char "→";
	}
	else {
		if utf32 == #char "\t" then utf32 = #char " ";
	}

	// if utf32 == #char "\n" then utf32 = #char " ";
	// if utf32 == #char "\r" then utf32 = #char " ";

	index := FT_Get_Char_Index(font.face, utf32);

	if font.drawLineEndings {
		if utf32 == #char "\n" then index = FT_Get_Char_Index(font.face, 0x240A);
		if utf32 == #char "\r" then index = FT_Get_Char_Index(font.face, 0x240D);
	}
	else {
		if utf32 == #char "\n" then index = FT_Get_Char_Index(font.face, #char " ");
		if utf32 == #char "\r" then index = FT_Get_Char_Index(font.face, #char " ");
	}
	return index;
}

find_or_make_glyph :: (font: *Font, size: int, utf32: u32) -> GlyphData {
	glyphIndex := get_glyph_index(font, utf32);
	fontStyle,newStyle := find_or_add(*font.styleTable, size);

	// cache miss on the font style
	if newStyle {
		fontStyle.glyphTable.allocator = fontCache.allocator;
		FT_Set_Pixel_Sizes(font.face, 0, xx size);

		// calculate basic metrics
		fontStyle.metrics.characterHeight = size;
		glyphIndexTemp := FT_Get_Char_Index(font.face, #char "T");
		if glyphIndexTemp {
			FT_Load_Glyph(font.face, glyphIndexTemp, FT_LOAD_DEFAULT);
			fontStyle.metrics.typicalAscender = FT_ROUND(font.face.glyph.metrics.horiBearingY);
		}

		glyphIndexTemp = FT_Get_Char_Index(font.face, #char "g");
		if glyphIndexTemp {
			FT_Load_Glyph(font.face, glyphIndexTemp, FT_LOAD_DEFAULT);
			fontStyle.metrics.typicalDescender = FT_ROUND(font.face.glyph.metrics.horiBearingY - font.face.glyph.metrics.height);
		}

		scale := font.face.size.metrics.y_scale/(64.0*65536.0);
		fontStyle.metrics.lineSpacing = cast(int) floor(scale * font.face.height + 0.5);
		fontStyle.metrics.maxAscender  = cast(int) floor(scale * font.face.bbox.yMax + 0.5);
		fontStyle.metrics.maxDescender = cast(int) floor(scale * font.face.bbox.yMin + 0.5);
	}

	glyphData,newGlyph := find_or_add(*fontStyle.glyphTable, glyphIndex);
	
	// cache miss on the glyph
	if newGlyph {
		FT_Set_Pixel_Sizes(font.face, 0, xx size);

		// Jai bindings doesn't expose this, but it's critical 
		// to get correct looking hinting when using subpixel rendering
		FT_LOAD_TARGET_LCD :: cast(s32, 3 & 15) << 16;

		error := FT_Load_Glyph(font.face, glyphIndex, FT_LOAD_DEFAULT | FT_LOAD_TARGET_LCD);
		assert(!error);

		FT_Render_Glyph(font.face.glyph, .FT_RENDER_MODE_LCD);

		glyphData.index = glyphIndex;
		glyphData.offsetX = cast(float)font.face.glyph.bitmap_left;
		glyphData.offsetY = cast(float)font.face.glyph.bitmap_top;
		glyphData.advance = cast(float)(font.face.glyph.advance.x >> 6);

		if !try_add_glyph_to_atlas(*fontCache.atlasList[fontCache.atlasList.count-1], font.face, glyphData) {
			// @todo: failed to find space in atlas, make a new one
			assert(false);
		}
	}
	return glyphData.*;
}

can_rect_fit_in_atlas :: (atlas: *Atlas, atNode: s32, w: s32, h: s32) -> s32 {
	x := atlas.nodes[atNode].x;
	y := atlas.nodes[atNode].y;

	// check we're not going off the edge of the bitmap
	if x + w > atlas.texture.width {
		return -1;
	}

	// We're going to loop over all the nodes from atNode to however many this new rect "covers"
    // We want to find the highest rect underneath this rect to place it at.
	remainingSpace := w;
	index := atNode;
	while remainingSpace > 0 {
		if index == atlas.nodes.count {
			return -1;
		}

		node := *atlas.nodes[index];

		if node.y > y
			y = node.y;

		if y + h > atlas.texture.height
			return -1; // off the edge of the bitmap

		remainingSpace -= node.width;
		index += 1;
	}

	return y;
}

try_add_glyph_to_atlas :: (atlas: *Atlas, face: FT_Face, glyphData: *GlyphData) -> bool {
	bestHeight: s32 = atlas.texture.height;
	bestWidth: s32 = atlas.texture.width;
	bestNode: s32 = -1;
	bestX, bestY: s32;

	padding:s32 = 1;
	glyphWidth:s32 = xx face.glyph.bitmap.width + padding*2;
	glyphHeight:s32 = xx face.glyph.bitmap.rows + padding*2;

	// find the best location for the glyph
	for * atlas.nodes {
		highestY := can_rect_fit_in_atlas(atlas, xx it_index, glyphWidth, glyphHeight); 

		if highestY != -1 {
			// Settling a tie here on best height by checking lowest width we can use up
			if highestY + glyphHeight < bestHeight || (highestY + glyphHeight == bestHeight && it.width < bestWidth) {
				bestNode = xx it_index;
				bestWidth = it.width;
				bestHeight = highestY + glyphHeight;
				bestX = it.x;
				bestY = highestY;
			}
		}
	}

	if bestNode == -1
		return false; // glyph cannot fit in this atlas

	newNode: AtlasNode;
	newNode.width = glyphWidth;
	newNode.x = bestX;
	newNode.y = bestY + glyphHeight;
	array_insert_at(*atlas.nodes, newNode, bestNode);

	// now find all the nodes underneath this one and remove them
	i := bestNode+1;
	while i < atlas.nodes.count {
		node := *atlas.nodes[i];
		prevNode := *atlas.nodes[i-1];
		// check to see if the current node is underneath the previous node
		// remember that "it" starts as the first node after we inserted, so the previous node is the one we inserted
		if node.x < prevNode.x + prevNode.width {
			amountToShrink := (prevNode.x + prevNode.width) - node.x;
			node.x += amountToShrink;
			node.width -= amountToShrink;

			if node.width <= 0 {
				// we've reduced this node so much it can be removed
				array_ordered_remove_by_index(*atlas.nodes, i);
				i -= 1; // move back since we've removed a node
			}
			else {
				break; // if we don't need to remove this node, we've reached the extents of our new covering node
			}
		}
		else {
			break; // nothing being covered
		}
		i += 1;
	}

	// Find any skyline nodes that are the same height and merge them
	i = 0;
	while i < atlas.nodes.count-1 {
		if atlas.nodes[i].y == atlas.nodes[i+1].y {
			atlas.nodes[i].width += atlas.nodes[i+1].width;
			array_ordered_remove_by_index(*atlas.nodes, i+1);
			i -= 1;
		}
		i += 1;
	}

	bestX += padding;
	bestY += padding;

	// actually copy the bitmap data into the atlas
	rows  := cast(s32) face.glyph.bitmap.rows;
	width := cast(s32) face.glyph.bitmap.width;
	pitch := cast(s32) face.glyph.bitmap.pitch;
	for j : 0..rows-1 {
		for i : 0..width-1 {
            dst_pixel := atlas.texture.data.data + ((bestY + j) * atlas.texture.width + (bestX + i));
            dst_pixel.* = face.glyph.bitmap.buffer[(rows - 1 - j) * pitch + i];
		}
	}
	atlas.texture.dirty = true;

	// set the uv rect for rendering
	glyphData.subRect.x = cast(float)  bestX;
	glyphData.subRect.y = cast(float) (atlas.texture.height - bestY - rows);
	glyphData.subRect.w = cast(float)  width;
	glyphData.subRect.h = cast(float)  rows;

	return true;
}

fontCache: FontCache;

FT_ROUND :: inline (x: int) -> int {
    if x >= 0 return (x + 0x1f) >> 6;
    return -(((-x) + 0x1f) >> 6);
}

#import "freetype";
