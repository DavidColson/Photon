

UIBox :: struct {
	key: UIKey;

	using tree: struct {
		next: *UIBox; // siblings
		prev: *UIBox;
		head: *UIBox; // chilren
		tail: *UIBox;
		parent: *UIBox;
	}

	// per frame information, reset in box() and configured with the set_* functions
	using properties: struct {
		flags: UIBoxFlags;
		text: string;
		textHighlights: []TextHighlight;
		textPadding: float;
		textAlignment: UIAlignment;
		layout: struct {
			childLayoutAxis: UIAxis;
			padding: Vector4; // left, right, top, bottom
			childGap: float;
			childAlignment: UIAlignment;
			width: UISize;
			height: UISize;
			#overlay (width) size: [2]UISize = ---;
		};
		colours: struct {
			background: Vector4;
			hover: Vector4; // mouse hovered
			hot: Vector4; // keyboard focused, i.e. the selected row in a list
			active: Vector4;
			text: Vector4;
			textHighlight: Vector4;
			border: Vector4;
			#overlay (background) colors: [7]Vector4 = ---;
		};
		cornerRadius: Vector4;
		borderThickness: float;
		fontSize: float;
		font: *Font;
		customDrawFunction: (*UIBox, *void);
		customDrawUdata: *void;
	}
	
	// per frame working data (must be cleared in box())
	textRun: TextRun;
	fixedPosition: [UIAxis.COUNT]float; // parent relative
	fixedSize: [UIAxis.COUNT]float;
	childCount: s32;
	rect: Rect; // final rect for rendering

	// persistent data
	firstTouchedFrame: u64;
	lastTouchedFrame: u64;
	viewOffset: Vector2;
	viewOffsetTarget: Vector2;
	viewBounds: Vector2;
	hoverTimer: float;
	activeTimer: float;
	dragPrevPos: Vector2;
	// @todo: actually maintain the whole signal state from the previous frame for this
	leftClickStateLastFrame: bool;
	lastClickTime: float64;
}

UIColours :: struct {
	// Base box colours, applied to every box in box()
	text := #run hex_to_color_vec4("C3C7D0");
	textDim := #run hex_to_color_vec4("C3C7D099"); // hints and secondary labels
	textHighlight := #run hex_to_color_vec4("7e90bd");
	boxBackground := #run hex_to_color_vec4("282C34");
	boxHover := #run hex_to_color_vec4("636f85"); // mouse hover
	boxHot := #run hex_to_color_vec4("4e5665"); // keyboard focus/selection
	boxActive := #run hex_to_color_vec4("7e90bd");
	boxBorder := #run hex_to_color_vec4("5C6476");

	// Widget colours
	popupBackground := #run hex_to_color_vec4("3B414C"); // tooltips, context menus and dialogs
	textInputBackground := #run hex_to_color_vec4("4e5665");
	
	buttonBackground := #run hex_to_color_vec4("282C34");
	buttonHover := #run hex_to_color_vec4("636f85");
	buttonHot := #run hex_to_color_vec4("4e5665");
	buttonActive := #run hex_to_color_vec4("7e90bd");
	buttonBorder := #run hex_to_color_vec4("5C6476");
	
	scrollBarBackground := #run hex_to_color_vec4("3B414C");
	scrollBarHandle := #run hex_to_color_vec4("4e5665");
	scrollBarHandleHover := #run hex_to_color_vec4("636f85");
	scrollBarHandleActive := #run hex_to_color_vec4("7e90bd");
}

UIStyle :: struct {
	// Fonts
	fontSize := 15.0;
	font := string.["segoeui.ttf"];
	iconFontData: string; // embedded font file, no icon font if empty

	// Base box styling (sizes in em units)
	boxTextPadding := 0.2;
	boxPadding := Vector4.{0, 0, 0, 0};
	boxChildGap := 0.0;
	
	// Widget styling
	buttonCornerRadius := 0.2;
	buttonTextAlign := UIAlignment.CENTER;
	
	// TODO: once we refactor popups
	// it may be desirable to more specific about these
	// so we have styling for context menus and tooltips specifically
	// or what have you
	popupPadding := 0.5;
	popupChildGap := 0.2;
	popupCornerRadius := 0.4;
	popupBorderThickness := 1.0; // pixels
	
	scrollBarThickness := 1.2;
	scrollBarPadding := 0.3;
	scrollBarCornerRadius := 0.3;

	// Animation
	scrollAnimRate := 14.0;
}

UIEvent :: struct {
	// What kind of event is this?
	Type :: enum {
		NAVIGATE;
		EDIT;
		TEXT;
		PRESS;
		RELEASE;
		SCROLL;
	}
	// This is an abstract idea of "what binding does the event relate to"
	Action :: enum {
		NONE;
		ACCEPT;
		CANCEL;
		LEFT_MOUSE;
		MIDDLE_MOUSE;
		RIGHT_MOUSE;
	}
	// For navigate and edit, what is the unit of delta
	Unit :: enum {
		NONE;
		CHAR;
		WORD;
		LINE;
	}
	type: Type;
	action: Action;
	unit: Unit;
	text: string;
	delta: [2]s32;
}

// @todo: this needs to be much better
// Needs different mouse buttons, needs
// transient states like "onpressed" to be implemented better than now
UISignal :: struct {
	hoverEnter: bool;
	hoverExit: bool;
	hovering: bool;
	pressed: bool;
	released: bool;
	doubleClicked: bool;
	holding: bool;
	dragDelta: Vector2;
}

UIBoxFlags :: enum_flags {
	DRAW_BACKGROUND;
	DRAW_TEXT;
	DRAW_TEXT_HIGHLIGHTS;
	DRAW_BORDER;
	DRAW_SIDE_BOTTOM;
	DRAW_SIDE_TOP;
	DRAW_SIDE_LEFT;
	DRAW_SIDE_RIGHT;
	DRAW_HOVER_EFFECTS;
	DRAW_ACTIVE_EFFECTS;
	CLICKABLE;
	FLOATING_X;
	FLOATING_Y;
	FIXED_WIDTH;
	FIXED_HEIGHT;
	CLIP_CONTENTS;
	FOCUS_HOT;
	FOCUS_ACTIVE;
}

UIAxis :: enum {
	X;
	Y;
	COUNT;
}

UISize :: struct {
	type: UISizeType;
	percent: float;
	min: float;
	max: float;
}

UISizeType :: enum {
	NULL;
	FIXED;
	TEXT;
	PERCENT;
	FIT;
	GROW;
}

UIAlignment :: enum {
	LEFT;
	CENTER;
	RIGHT;
}

UIKey :: struct {
	keyVal:u64;
	keyStr: string; // debug, @todo remove in release?
}

UIState :: struct {
	arena: Flat_Pool;
	alloc: Allocator;
	frameArena: Flat_Pool;
	frameAlloc: Allocator;

	// Per frame UI data
	root: *UIBox;
	popupRoot: *UIBox;

	// Styling information, pointers so the user can extend the style data
	style: *UIStyle;
	colours: *UIColours;

	// Loaded from the style in init_ui
	font: *Font;
	iconFont: *Font;
	fontSize: float; // style font size with dpi scaling applied, updated in begin_ui
	dpiScale := 1.0;

	doubleClickTimeSeconds := 0.4;

	// Persistent UI data
	boxTable: Table(UIKey, *UIBox, given_compare_function=compare_key, given_hash_function=x=>get_hash(x.keyVal));
	freeListHead: *UIBox;
	freeListTail: *UIBox;
	activeContextMenu: UIKey;
	nextActiveContextMenu: UIKey;
	hoverBoxKey: UIKey;
	hoverBoxKeyLastFrame: UIKey;
	activeBoxKey: UIKey;

	frameIndex: u64;

	events: [..]UIEvent;
}
uiState: UIState;

// style and colours may point to structs extending UIStyle/UIColours, they must outlive the UI
init_ui :: (style: *UIStyle, colours: *UIColours) {
	uiState.alloc = Allocator.{ proc = flat_pool_allocator_proc, data = *uiState.arena };
	uiState.frameAlloc = Allocator.{ proc = flat_pool_allocator_proc, data = *uiState.frameArena };

	uiState.boxTable.allocator = uiState.alloc;
	init(*uiState.boxTable, 4096);

	uiState.frameIndex = 0;

	uiState.style = style;
	uiState.colours = colours;
	uiState.fontSize = style.fontSize * uiState.dpiScale;
	uiState.font = load_first_font(style.font);
	if style.iconFontData.count > 0 {
		uiState.iconFont = load_font_from_memory(style.iconFontData);
	}
}

ui_set_dpi_scale :: (scale: float) {
	uiState.dpiScale = scale;
	uiState.fontSize = uiState.style.fontSize * scale;
}

// Loads the first font in the list that succeeds, i.e. a preferred font with fallbacks
load_first_font :: (filenames: []string) -> *Font, bool {
	for filenames {
		font, success := load_font(it);
		if success return font, true;
	}
	return null, false;
}

find_box :: (key: UIKey) -> bool, *UIBox {
	success, box:= table_find(*uiState.boxTable, key);
	return success, box;
}

box :: (parent: *UIBox, key: UIKey = ui_key_nil) -> *UIBox {
	// attempt to get the box from persistent data using it's key
	success, box := table_find(*uiState.boxTable, key);

	// if it can't be found it's new
	if !success {
		// transient box, we'll allocate in the frame allocator (cleared at the end of the frame)
		if key == ui_key_nil {
			box = New(UIBox,, uiState.frameAlloc);
		}
		else {
			if uiState.freeListTail != null {
				// there is an existing box we can reuse
				box = uiState.freeListTail;
				linked_list_remove(*uiState.freeListHead, *uiState.freeListTail, box);
			}
			else {
				box = New(UIBox,, uiState.alloc);
			}
			table_add(*uiState.boxTable, key, box);
		}
		memset(box, 0, size_of(UIBox));
		box.firstTouchedFrame = uiState.frameIndex;
	}

	// this will save your sanity
 	if success {
		assert(box.lastTouchedFrame != uiState.frameIndex, "Encountered a duplicate key this frame, probably a mistake");
	}

	// setup box
	box.tree = .{};
	box.parent = parent;
	box.childCount = 0;
	box.fixedPosition = .[0,0];
	box.fixedSize = .[0,0];
	box.key = key;
	box.lastTouchedFrame = uiState.frameIndex;

	// reset properties to defaults, these are then overridden by the setters below
	box.properties = .{};
	box.colours.background = uiState.colours.boxBackground;
	box.colours.hover = uiState.colours.boxHover;
	box.colours.hot = uiState.colours.boxHot;
	box.colours.active = uiState.colours.boxActive;
	box.colours.text = uiState.colours.text;
	box.colours.textHighlight = uiState.colours.textHighlight;
	box.colours.border = uiState.colours.boxBorder;
	box.font = uiState.font;
	box.fontSize = uiState.fontSize;
	box.textPadding = em(uiState.style.boxTextPadding);
	box.layout.childGap = em(uiState.style.boxChildGap);
	box.layout.padding = .{em(uiState.style.boxPadding.x), em(uiState.style.boxPadding.y), em(uiState.style.boxPadding.z), em(uiState.style.boxPadding.z) };

	// insert into parent's list of children
	if box.parent {
		linked_list_insert(*box.parent.head, *box.parent.tail, box.parent.tail, box);
		box.parent.childCount += 1;
	}

	return box;
}

popup :: (key: UIKey = ui_key_nil) -> *UIBox {
	return box(uiState.popupRoot, key);
}

// box property setters

add_flags :: (box: *UIBox, flags: UIBoxFlags) { box.flags |= flags; }
remove_flags :: (box: *UIBox, flags: UIBoxFlags) { box.flags &= ~flags; }

// floating boxes are positioned relative to their parent and take no space in its layout
set_fixed_x :: (box: *UIBox, fixedX: float) {
	box.fixedPosition[UIAxis.X] = fixedX;
	box.flags |= .FLOATING_X;
}

set_fixed_y :: (box: *UIBox, fixedY: float) {
	box.fixedPosition[UIAxis.Y] = fixedY;
	box.flags |= .FLOATING_Y;
}

// text
set_text :: (box: *UIBox, text: string) { box.text = text; }
set_text_highlights :: (box: *UIBox, highlights: []TextHighlight) { box.textHighlights = highlights; }
set_text_padding :: (box: *UIBox, padding: float) { box.textPadding = padding; }
set_text_alignment :: (box: *UIBox, alignment: UIAlignment) { box.textAlignment = alignment; }
set_font :: (box: *UIBox, font: *Font) { box.font = font; }
set_font_size :: (box: *UIBox, fontSize: float) { box.fontSize = fontSize; }

// layout
set_child_layout_axis :: (box: *UIBox, axis: UIAxis) { box.layout.childLayoutAxis = axis; }
set_padding :: (box: *UIBox, padding: float) { box.layout.padding = .{padding, padding, padding, padding}; }
set_padding :: (box: *UIBox, padding: Vector4) { box.layout.padding = padding; } // left, right, top, bottom
set_child_gap :: (box: *UIBox, gap: float) { box.layout.childGap = gap; }
set_child_alignment :: (box: *UIBox, alignment: UIAlignment) { box.layout.childAlignment = alignment; }
set_width :: (box: *UIBox, size: UISize) { box.layout.width = size; }
set_height :: (box: *UIBox, size: UISize) { box.layout.height = size; }
set_size :: (box: *UIBox, axis: UIAxis, size: UISize) { box.layout.size[axis] = size; }
set_size :: (box: *UIBox, width: UISize, height: UISize) { box.layout.width = width; box.layout.height = height; }

// palette
set_background_color :: (box: *UIBox, color: Vector4) { box.colours.background = color; }
set_hover_color :: (box: *UIBox, color: Vector4) { box.colours.hover = color; }
set_hot_color :: (box: *UIBox, color: Vector4) { box.colours.hot = color; }
set_active_color :: (box: *UIBox, color: Vector4) { box.colours.active = color; }
set_text_color :: (box: *UIBox, color: Vector4) { box.colours.text = color; }
set_text_highlight_color :: (box: *UIBox, color: Vector4) { box.colours.textHighlight = color; }
set_border_color :: (box: *UIBox, color: Vector4) { box.colours.border = color; }

// decoration
set_corner_radius :: (box: *UIBox, radius: float) { box.cornerRadius = .{radius, radius, radius, radius}; }
set_corner_radius :: (box: *UIBox, radii: Vector4) { box.cornerRadius = radii; }
set_border_thickness :: (box: *UIBox, thickness: float) { box.borderThickness = thickness; }

set_custom_draw :: (box: *UIBox, function: (*UIBox, *void), udata: *void) {
	box.customDrawFunction = function;
	box.customDrawUdata = udata;
}

// Events and input handling
// ---------------------------

push_event :: (uiState: *UIState, type: UIEvent.Type, delta: [2]s32 = .[0,0], action: UIEvent.Action = .NONE, unit: UIEvent.Unit = .NONE, text: string = "") {
	array_add(*uiState.events, .{ type, action, unit, text, delta });
}

signal_from_box :: (box: *UIBox) -> UISignal {
	signal: UISignal;

	// figure out if this box's parent is a floating root parent
	isPopup: bool = false;
	parent: *UIBox = box.parent;
	while parent {
		if parent == uiState.popupRoot {
			isPopup = true;
			break;
		}
		parent = parent.parent;
	}

	// if it isn't, then get the context menu's rectangle
	blacklistRect: Rect;
	if !isPopup && uiState.activeContextMenu != ui_key_nil {
		found, contextMenu := find_box(uiState.activeContextMenu);
		if found then blacklistRect = contextMenu.rect;
	}

    x, y, success := get_mouse_pointer_position(renderState.window, false);
	box_contains_cursor := !contains_point(blacklistRect, xx x, xx y) && contains_point(box.rect, xx x, xx y);
	
	if box_contains_cursor && uiState.hoverBoxKey == ui_key_nil {
		signal.hovering = true;
		if box.flags & .CLICKABLE {
			uiState.hoverBoxKey = box.key;
		}

		if uiState.hoverBoxKeyLastFrame != box.key {
			signal.hoverEnter = true;
		}
	}
	else if uiState.hoverBoxKeyLastFrame == box.key {
		signal.hoverExit = true;
	}

	for uiState.events {
		if it.type == {
			case .PRESS;
				// left click press
				if box.flags & .CLICKABLE && it.action == .LEFT_MOUSE && box_contains_cursor { 
					uiState.activeBoxKey = box.key;
					if box.leftClickStateLastFrame == false {
						signal.pressed = true;
					}
					box.leftClickStateLastFrame = true;
					box.dragPrevPos = .{xx x,xx y};
					remove it;
				}
			
				// Keyboard accept on this box if it's focused
				if box.flags & .CLICKABLE && box.flags & .FOCUS_HOT && it.action == .ACCEPT {
					uiState.activeBoxKey = box.key;
					signal.pressed = true;
					remove it;
				}
				
				// clicking somewhere outside of context menu
				if uiState.activeContextMenu != ui_key_nil {
					found, contextMenu := find_box(uiState.activeContextMenu);
					if found && !contains_point(contextMenu.rect, xx x, xx y) {
						context_menu_close();
					}
				}
			case .RELEASE;
				// left click release inside box
				if box.flags & .CLICKABLE
					&& it.action == .LEFT_MOUSE
					&& uiState.activeBoxKey == box.key
					&& box_contains_cursor { 

					signal.released = true;
					box.leftClickStateLastFrame = false;
					uiState.activeBoxKey = ui_key_nil;

					now := seconds_since_init();
					if now - box.lastClickTime <= uiState.doubleClickTimeSeconds {
						signal.doubleClicked = true;
						box.lastClickTime = 0; // consume the pair so a third rapid click starts fresh rather than chaining
					}
					else {
						box.lastClickTime = now;
					}
					remove it;
				}

				// left click release outside box
				if box.flags & .CLICKABLE
					&& it.action == .LEFT_MOUSE
					&& uiState.activeBoxKey == box.key
					&& !box_contains_cursor { 

					box.leftClickStateLastFrame = false;
					uiState.hoverBoxKey = ui_key_nil;
					uiState.activeBoxKey = ui_key_nil;
					remove it;
				}

			case .SCROLL;
                if box_contains_cursor {
					metrics := get_font_metrics(box.font, xx box.fontSize);
					box.viewOffsetTarget.x += it.delta[0]*metrics.lineSpacing*3;
					box.viewOffsetTarget.y += it.delta[1]*metrics.lineSpacing*3;
					box.viewOffsetTarget.y = clamp(box.viewOffsetTarget.y, box.viewBounds.y, 0);
					box.viewOffsetTarget.x = clamp(box.viewOffsetTarget.x, 0, box.viewBounds.x);
					remove it;
				}
		}
	}

	// calculate dragging delta if we are the active box
	if box.key == uiState.activeBoxKey {
		xDist := x - box.dragPrevPos.x;
		yDist := y - box.dragPrevPos.y;
		signal.dragDelta = .{xDist, yDist};
		box.dragPrevPos = .{xx x,xx y};
	}

	if box.leftClickStateLastFrame == true {
		signal.holding = true;
	}

	return signal;
}

// Returns the root box which all other boxes should descend from
begin_ui :: () -> *UIBox {
	// recomputed each frame so changes to the style apply immediately
	uiState.fontSize = uiState.style.fontSize * uiState.dpiScale;

	uiState.root = box(null);
	set_child_layout_axis(uiState.root, .Y);
	set_size(uiState.root, fixed(xx renderState.windowWidth), fixed(xx renderState.windowHeight));
	
	uiState.popupRoot = box(null);
	set_child_layout_axis(uiState.popupRoot, .Y);
	set_size(uiState.popupRoot, fixed(xx renderState.windowWidth), fixed(xx renderState.windowHeight));

	uiState.hoverBoxKeyLastFrame = uiState.hoverBoxKey;
	uiState.hoverBoxKey = ui_key_nil;
	return uiState.root;
}

// Returns true if animations are still playing and the app should redraw next frame
end_ui :: (deltaTime: float64) -> needsRedraw: bool {
	needsRedraw := false;

	// yeet any unused boxes
	for uiState.boxTable {
		if it.lastTouchedFrame < uiState.frameIndex || it.key == ui_key_nil {
			if it.key == uiState.activeBoxKey then uiState.activeBoxKey = ui_key_nil;
			table_remove(*uiState.boxTable, it.key);
			linked_list_insert(*uiState.freeListHead, *uiState.freeListTail, uiState.freeListTail, it);
		}
	}

	// layout all the boxes
	compute_layout(uiState.root, .X);
	compute_layout(uiState.root, .Y);
	set_rect_from_fixed(uiState.root);

	// floating popups (i.e. context menu/tooltips) are all children of popupRoot, so we do their layout separately
	// Currently we have to do it twice, once to lay them out to figure out their size, then we reposition them
	// if they're off screen or such, then redo the layout to update all the children. Maybe we can do better I dunno?
	popup := uiState.popupRoot.head;
	while popup {
		compute_layout(popup, .X);
		compute_layout(popup, .Y);
		set_rect_from_fixed(popup);
		
		xBounds := uiState.root.rect.w - em(0.3, popup.fontSize); // padding
		yBounds := uiState.root.rect.h - em(0.3, popup.fontSize); // padding
		xShiftDown := max(popup.rect.x, 0) - popup.rect.x;
		xShiftUp := min(popup.rect.x+popup.rect.w, xBounds) - (popup.rect.x+popup.rect.w);
		popup.rect.x += xShiftDown + xShiftUp;
		yShiftDown := max(popup.rect.y, 0) - popup.rect.y;
		yShiftUp := min(popup.rect.y+popup.rect.h, yBounds) - (popup.rect.y+popup.rect.h);
		popup.rect.y += yShiftDown + yShiftUp;
		
		// repospopupion children now the popup has moved
		compute_layout(popup, .X);
		compute_layout(popup, .Y);
		
		popup = popup.next;
	}

	// do animations
	needsRedraw |= update_animations_recursive(uiState.root, deltaTime);
	needsRedraw |= update_animations_recursive(uiState.popupRoot, deltaTime);
	
	// render
	render_ui_recursive(uiState.root);
	render_ui_recursive(uiState.popupRoot);

	if uiState.activeContextMenu != ui_key_nil && uiState.nextActiveContextMenu == ui_key_nil {
		uiState.activeContextMenu = ui_key_nil;
	}
	else if uiState.activeContextMenu == ui_key_nil && uiState.nextActiveContextMenu != ui_key_nil {
		uiState.activeContextMenu = uiState.nextActiveContextMenu;
	}

	// Clear any unused input events
	array_reset_keeping_memory(*uiState.events);
	
	reset(*uiState.frameArena, overwrite_memory=true);
	uiState.frameIndex += 1;
	return needsRedraw;
}

// depth first UI tree iterator

depth_first :: (box: *UIBox, body: Code, flags: For_Flags) #expand {
	recursionStack: [32]*UIBox;
	recursionLevel := 0;
	push_parent :: (box: *UIBox) #expand { `recursionStack[`recursionLevel] = box; `recursionLevel += 1; }
	pop_parent :: () -> *UIBox #expand { `recursionLevel -= 1; return `recursionStack[`recursionLevel]; }

	counter := 0;
	push_parent(box.next);
	while box {
		`it_index := counter; defer counter += 1;
		`it := box;

		#insert body;

		// get next box
		if box.head {
			// this box has children, so traverse them
			if box.next then push_parent(box.next);
			box = box.head;
		}
		else {
			box = box.next;
			if box == null && recursionLevel > 0 {
				// go up a recursion level
				box = pop_parent();
			}
		}
	}
}

// keying

ui_key_nil :: UIKey.{0,""};

ui_key :: (str: string) -> UIKey {
	if str.count == 0 then return ui_key_nil; 
	return .{fnv1a_hash(str.data, str.count), str};
}

ui_key :: (formatStr: string, args: ..Any) -> UIKey {
	keyString := tprint(formatStr, ..args);
	return ui_key(keyString);
}

operator== :: (key1: UIKey, key2: UIKey) -> bool {
	return key1.keyVal == key2.keyVal;
}
compare_key :: (key1: UIKey, key2: UIKey) -> bool {
	return key1.keyVal == key2.keyVal;
}

// Colours
// -----------------

hex_to_color_vec4 :: (src_hex: string) -> Vector4 {
	hex := src_hex;
	if hex.count == 6 then hex = tprint("%FF", hex);
	if hex.count != 8 return Vector4.{};

	r := slice(hex, 0, 2);
	g := slice(hex, 2, 2);
	b := slice(hex, 4, 2);
	a := slice(hex, 6, 2);

	to_float :: (byte_str: string) -> float {
		hex_digit_to_int :: (char: u8) -> int {
			char = to_upper(char);
			if #char "0" <= char && char <= #char "9" return char - #char "0";
			if #char "A" <= char && char <= #char "F" return 10 + char - #char "A";
			return -1;
		}

		d1, d0 := cast(float)hex_digit_to_int(byte_str[0]), cast(float) hex_digit_to_int(byte_str[1]);
		if d1 < 0 || d0 < 0 return -1;

		return (16 * d1 + d0) / 255;
	}

	c := Vector4.{ to_float(r), to_float(g), to_float(b), to_float(a) };

	return c;
}

// Widgets
// ------------------

text :: (parent: *UIBox, text: string) -> *UIBox {
	label := box(parent);
	add_flags(label, .DRAW_TEXT);
	set_text(label, text);
	set_size(label, text_content(), text_content());
	return label;
}

text :: (parent: *UIBox, textFormat: string, args: ..Any) -> *UIBox {
	return text(parent, tprint(textFormat, ..args));
}

// Text where the highlighted ranges are drawn in the textHighlight colour, i.e. fuzzy search matches
highlighted_text :: (parent: *UIBox, text: string, highlights: []TextHighlight) -> *UIBox {
	label := box(parent);
	add_flags(label, .DRAW_TEXT_HIGHLIGHTS);
	set_text(label, text);
	set_text_highlights(label, highlights);
	set_size(label, text_content(), text_content());
	return label;
}

button :: (parent: *UIBox, width: UISize, height: UISize, text: string) -> bool, *UIBox {
	button := box(parent, ui_key(text));
	add_flags(button, .DRAW_BACKGROUND | .DRAW_TEXT | .CLICKABLE | .DRAW_HOVER_EFFECTS | .DRAW_ACTIVE_EFFECTS);
	set_text(button, text);
	set_size(button, width, height);
	set_text_alignment(button, uiState.style.buttonTextAlign);
	set_background_color(button, uiState.colours.buttonBackground);
	set_hover_color(button, uiState.colours.buttonHover);
	set_hot_color(button, uiState.colours.buttonHot);
	set_active_color(button, uiState.colours.buttonActive);
	set_border_color(button, uiState.colours.buttonBorder);
	set_corner_radius(button, em(uiState.style.buttonCornerRadius));
	signal := signal_from_box(button);
	return signal.pressed, button;
}

button :: (parent: *UIBox, text: string) -> bool, *UIBox {
	clicked, toggle := button(parent, text_content(), text_content(), text);
	return clicked, toggle;
}

toggle :: (parent: *UIBox, width: UISize, height: UISize, value: *bool, text: string) -> bool, *UIBox {
	toggle := box(parent, ui_key(text));
	add_flags(toggle, .DRAW_BACKGROUND | .DRAW_TEXT | .CLICKABLE);
	set_text(toggle, text);
	set_size(toggle, width, height);
	set_text_alignment(toggle, uiState.style.buttonTextAlign);
	set_background_color(toggle, uiState.colours.buttonBackground);
	set_hover_color(toggle, uiState.colours.buttonHover);
	set_hot_color(toggle, uiState.colours.buttonHot);
	set_active_color(toggle, uiState.colours.buttonActive);
	set_border_color(toggle, uiState.colours.buttonBorder);
	set_corner_radius(toggle, em(uiState.style.buttonCornerRadius));
	if value.* {
		set_background_color(toggle, uiState.colours.buttonActive);
	}
	else {
		add_flags(toggle, .DRAW_HOVER_EFFECTS);
	}
	signal := signal_from_box(toggle);
	if signal.pressed {
		value.* = !(value.*);
	}
	return signal.pressed, toggle;
}

toggle :: (parent: *UIBox, value: *bool, text: string) -> bool, *UIBox {
	clicked, toggle := toggle(parent, text_content(), text_content(), value, text);
	return clicked, toggle;
}

tooltip :: (anchorBoxKey:UIKey = ui_key_nil, anchorOffset: Vector2 = .{0.0,0.0}) -> *UIBox {
	success, anchor := find_box(anchorBoxKey);
	fixedX, fixedY := 0.0;
	if success {
		fixedX = anchor.rect.x + anchorOffset.x;
		fixedY = anchor.rect.y + anchorOffset.y;
	}
	else {
		x, y, success := get_mouse_pointer_position(renderState.window, false);
		fixedX = cast(float, x + 20);
		fixedY = cast(float, y + 20);
	}

	tooltip := popup(ui_key("tooltip"));
	add_flags(tooltip, .DRAW_BACKGROUND | .DRAW_BORDER);
	set_child_layout_axis(tooltip, .X);
	set_size(tooltip, fit(), fit());
	set_padding(tooltip, em(uiState.style.popupPadding));
	set_background_color(tooltip, uiState.colours.popupBackground);
	set_border_thickness(tooltip, uiState.style.popupBorderThickness);
	set_corner_radius(tooltip, em(uiState.style.popupCornerRadius));
	set_fixed_x(tooltip, fixedX);
	set_fixed_y(tooltip, fixedY);

	return tooltip;
}

is_context_menu_open :: (key: UIKey) -> bool {
	return uiState.activeContextMenu == key;
}

context_menu_open :: (key: UIKey) {
	uiState.nextActiveContextMenu = key;
}

context_menu_close :: () {
	uiState.nextActiveContextMenu = ui_key_nil;
}

// Returns null if the context menu is not open, otherwise the menu box to add context_menu_items to
context_menu :: (key: UIKey, width: UISize, anchorBoxKey:UIKey = .{0,""}, anchorOffset: Vector2 = .{0.0,0.0}) -> *UIBox {
	if uiState.activeContextMenu != key return null;

	success, anchor := find_box(anchorBoxKey);
	fixedX, fixedY := 0.0;
	if success {
		fixedX = anchor.rect.x + anchorOffset.x;
		fixedY = anchor.rect.y + anchorOffset.y;
	}
	else {
		x, y, success := get_mouse_pointer_position(renderState.window, false);
		fixedX = cast(float, x + 20);
		fixedY = cast(float, y + 20);
	}

	menu := popup(key);
	add_flags(menu, .DRAW_BACKGROUND | .DRAW_BORDER);
	set_child_layout_axis(menu, .Y);
	set_size(menu, width, fit());
	set_padding(menu, em(uiState.style.popupPadding));
	set_child_gap(menu, em(uiState.style.popupChildGap));
	set_background_color(menu, uiState.colours.popupBackground);
	set_border_thickness(menu, uiState.style.popupBorderThickness);
	set_corner_radius(menu, em(uiState.style.popupCornerRadius));
	set_fixed_x(menu, fixedX);
	set_fixed_y(menu, fixedY);

	return menu;
}

context_menu_item :: (menu: *UIBox, label: string, icon: string) -> UISignal {
	id := menu.childCount;
	row := box(menu, ui_key("menuitem%", id));
	add_flags(row, .DRAW_BACKGROUND | .DRAW_HOVER_EFFECTS | .CLICKABLE);
	set_child_layout_axis(row, .X);
	set_size(row, grow(), fit());
	set_background_color(row, uiState.colours.popupBackground);
	{
		// icon
		if icon.count {
			iconBox := text(row, icon);
			set_width(iconBox, fixed(em(2.0)));
			set_font(iconBox, uiState.iconFont);
		}
		else {
			spacer(row, .X, fixed(em(2.0)));
		}

		// text
		text(row, label);
	}
	return signal_from_box(row);
}

spacer :: (parent: *UIBox, axis: UIAxis, size: UISize) {
	spacer := box(parent);
	set_size(spacer, axis, size);
}

scroll_bar :: (parent: *UIBox, key: UIKey, axis: UIAxis, scrollOffsetPct: float, scrollableRange:float, visibleRange: float, boxToScroll: UIKey) {
	scrollAxis := axis;
	otherAxis := axis ^ 1;

	if abs(scrollableRange) < abs(visibleRange) return;

	container := box(parent);
	set_padding(container, em(uiState.style.scrollBarPadding));
	set_size(container, otherAxis, fixed(em(uiState.style.scrollBarThickness)));
	set_size(container, scrollAxis, grow());
	{
		scrollBarOuter := box(container);
		add_flags(scrollBarOuter, .DRAW_BACKGROUND);
		set_child_layout_axis(scrollBarOuter, axis);
		set_size(scrollBarOuter, grow(), grow());
		set_corner_radius(scrollBarOuter, em(uiState.style.scrollBarCornerRadius));
		set_background_color(scrollBarOuter, uiState.colours.scrollBarBackground);
		{
			handleSizePct := max(abs(visibleRange/scrollableRange), 0.05);
			spaceBeforePct := (1.0-handleSizePct) * scrollOffsetPct;

			// space before
			spaceBefore := box(scrollBarOuter);
			set_size(spaceBefore, otherAxis, grow());
			set_size(spaceBefore, scrollAxis, percent(spaceBeforePct));

			// handle
			scrollHandle := box(scrollBarOuter, key);
			add_flags(scrollHandle, .DRAW_BACKGROUND | .CLICKABLE | .DRAW_HOVER_EFFECTS | .DRAW_ACTIVE_EFFECTS);
			set_size(scrollHandle, otherAxis, grow());
			set_size(scrollHandle, scrollAxis, percent(handleSizePct));
			set_background_color(scrollHandle, uiState.colours.scrollBarHandle);
			set_hover_color(scrollHandle, uiState.colours.scrollBarHandleHover);
			set_active_color(scrollHandle, uiState.colours.scrollBarHandleActive);
			set_corner_radius(scrollHandle, em(uiState.style.scrollBarCornerRadius));

			// dragging handling
			if boxToScroll != ui_key_nil {
				success, box:= find_box(boxToScroll);
				if success {
					drag := signal_from_box(scrollHandle).dragDelta;
					scaleRatio := 1.0;
					if box.rect.size.component[axis] != 0 {
						scaleRatio = box.viewBounds.component[axis]/((1.0-handleSizePct)*box.rect.size.component[axis]);
					}
					box.viewOffset.component[axis] += drag.component[axis] * scaleRatio;
					box.viewOffsetTarget.component[axis] += drag.component[axis] * scaleRatio;

					if axis == .X {
						box.viewOffset.x = clamp(box.viewOffset.x, 0, box.viewBounds.x);
						box.viewOffsetTarget.x = clamp(box.viewOffsetTarget.x, 0, box.viewBounds.x);
					}
					else {
						box.viewOffset.y = clamp(box.viewOffset.y, box.viewBounds.y, 0);
						box.viewOffsetTarget.y = clamp(box.viewOffsetTarget.y, box.viewBounds.y, 0);
					}
				}
			}
		}
	}
}

// Returns the list container, add list elements in the given range as children of it, then call scroll_list_end
scroll_list_begin :: (parent: *UIBox, listKey: UIKey, scrollBarKey: UIKey,  maxContainerHeight: float, elementHeight: float, maxElements: int, selectedElement: *s32) -> container: *UIBox, rangeStart: int, rangeEnd: int {
	outerContainer := box(parent);
	set_size(outerContainer, grow(), fit());

	maxContainerHeightInner := maxContainerHeight - em(0.4)*2; // without the padding

	container := box(outerContainer, listKey);
	add_flags(container, .CLIP_CONTENTS);
	set_child_layout_axis(container, .Y);
	set_size(container, grow(), fit(0.0, maxContainerHeight));
	set_padding(container, .{0,0, em(0.4), em(0.4)});

	// scroll bar if there are too many elements to display
	if container.viewBounds.y != 0.0 {
		scroll_bar(outerContainer,
					scrollBarKey,
					.Y,
					container.viewOffset.y/container.viewBounds.y,
					container.viewBounds.y,
					container.layout.height.max - em(0.4)*2,
					container.key);
	}

	elementsBefore := cast(int, floor(abs(container.viewOffset.y) / elementHeight));
	elementsOnScreen := min(cast(int, round(maxContainerHeightInner / elementHeight) + 1), maxElements);

	container.viewBounds.y = min(cast(float, -(maxElements * elementHeight - maxContainerHeightInner)), 0.0);
	signal_from_box(container);

	// Do keyboard list navigation
	for uiState.events {
		if it.type == {
		case .NAVIGATE;
			selectedElement.* += it.delta[1];
			selectedElement.* = clamp(selectedElement.*, 0, xx (maxElements - 1));
			elementsBeforeTarget := cast(s32, floor(abs(container.viewOffsetTarget.y) / elementHeight));
			if selectedElement.* < elementsBeforeTarget+1 {
				distance := elementsBeforeTarget - selectedElement.*;
				container.viewOffsetTarget.y = -selectedElement.**elementHeight;
			}
			if selectedElement.* > (elementsBeforeTarget+elementsOnScreen-2) {
				container.viewOffsetTarget.y = -(selectedElement.*+1)*elementHeight+(maxContainerHeight-em(0.4));
			}
		}
	}

	// spacer to fill gap of elements that are offscreen
	spacer(container, .Y, fixed(elementsBefore*elementHeight));

	rangeEnd := min(elementsBefore+elementsOnScreen-1, maxElements-1);
	rangeStart := elementsBefore;
	return container, rangeStart, rangeEnd;
}

scroll_list_end :: (container: *UIBox) {
	container.viewOffset.y = clamp(container.viewOffset.y, container.viewBounds.y, 0);
	container.viewOffset.x = clamp(container.viewOffset.x, container.viewBounds.x, 0);
	container.viewOffsetTarget.y = clamp(container.viewOffsetTarget.y, container.viewBounds.y, 0);
	container.viewOffsetTarget.x = clamp(container.viewOffsetTarget.x, container.viewBounds.x, 0);
}

// helpers

fixed :: (pixels: float) -> UISize { return .{type=.FIXED, min=pixels, max=pixels};}
fit :: (min: float = 0.0, max: float=0.0) -> UISize { return .{type=.FIT, min=min, max=max};}
grow :: (min: float = 0.0, max: float=0.0) -> UISize { return .{type=.GROW, min=min, max=max};}
percent :: (percent: float) -> UISize { return .{type=.PERCENT, percent=percent};}
text_content :: () -> UISize { return .{type=.TEXT};}

em :: (size: float, fontSize: float = 0.0) -> float { return ifx fontSize == 0.0 then size*uiState.fontSize else size*fontSize; }

corner_rad_all :: (v: float) -> Vector4 {return .{v,v,v,v};}
padding_all :: (v: float) -> Vector4 {return .{v,v,v,v};}



#scope_file

// rendering the tree

render_ui_recursive :: (box: *UIBox) {
	if box.flags & .DRAW_BACKGROUND {
		color := box.colours.background;

		// keyboard focus first so mouse hover and active draw over it
		if box.flags & .FOCUS_HOT {
			color = box.colours.hot;
		}
		if box.flags & .DRAW_HOVER_EFFECTS &&
			(uiState.hoverBoxKey != ui_key_nil && box.key == uiState.hoverBoxKey) {
			color = box.colours.hover;
		}
		if (box.flags & .DRAW_ACTIVE_EFFECTS &&
			(uiState.activeBoxKey != ui_key_nil && box.key == uiState.activeBoxKey))
			|| box.flags & .FOCUS_ACTIVE {
			color = box.colours.active;
		}

		submit_instance(.{
			dstRect = box.rect,
			color = color,
			cornerRadii = box.cornerRadius,
		});
	}

	if box.flags & .CLIP_CONTENTS {
		push_scissors(box.rect);
	}

	if box.flags & .DRAW_TEXT {
		// find position of text?
		box.textRun = generate_text_run(box.text, xx box.fontSize, box.font,,temp);
		metrics := get_font_metrics(box.font, xx box.fontSize);
		yPos := floor(box.rect.y + box.rect.h/2.0) + floor(box.fontSize/2.0) - 1.0;
		xPos := box.rect.x;

		if box.textAlignment == {
			case .LEFT;
				xPos += box.textPadding;
			case .CENTER;
				xPos = box.rect.x + Min((box.rect.w/2.0) - box.textRun.width/2.0, box.rect.w);
			case .RIGHT;
				xPos = box.rect.x + Min(box.rect.w - box.textRun.width - box.textPadding, box.rect.w);
		}
		xPos = floor(xPos);
		draw_text_run(box.textRun, xPos, yPos, box.colours.text);
	}

	if box.flags & .DRAW_TEXT_HIGHLIGHTS {
		// find position of text?
		box.textRun = generate_text_run(box.text, xx box.fontSize, box.font,,temp);
		metrics := get_font_metrics(box.font, xx box.fontSize);
		yPos := floor(box.rect.y + box.rect.h/2.0) + floor(box.fontSize/2.0) - 1.0;
		xPos := box.rect.x;

		if box.textAlignment == {
			case .LEFT;
				xPos += box.textPadding;
			case .CENTER;
				xPos = box.rect.x + Min((box.rect.w/2.0) - box.textRun.width/2.0, box.rect.w);
			case .RIGHT;
				xPos = box.rect.x + Min(box.rect.w - box.textRun.width - box.textPadding, box.rect.w);
		}
		xPos = floor(xPos);
		draw_text_run_highlights(box.textRun, xPos, yPos, box.textHighlights, box.colours.text, box.colours.textHighlight);
	}

	if box.customDrawFunction {
		box.customDrawFunction(box, box.customDrawUdata);
	}

	// draw children
	// note this is a reverse breadth first search
	// because we want to draw the UI in order of input priority (bottom to top)
	child := box.tail;
	while child {
		render_ui_recursive(child);
		child = child.prev;
	}

	if box.flags & .CLIP_CONTENTS {
		pop_scissors();
	}

	if box.flags & .DRAW_BORDER {
		submit_instance(.{
			dstRect = box.rect,
			color = box.colours.border,
			cornerRadii = box.cornerRadius,
			borderThickness = box.borderThickness
		});
	}

	if box.flags & .DRAW_SIDE_TOP {
		submit_instance(.{
			dstRect = .{box.rect.x, box.rect.y - floor(box.borderThickness/2), box.rect.w, box.borderThickness},
			color = box.colours.border,
		});
	}
	if box.flags & .DRAW_SIDE_BOTTOM {
		submit_instance(.{
			dstRect = .{box.rect.x, box.rect.y + box.rect.h - floor(box.borderThickness/2), box.rect.w, box.borderThickness},
			color = box.colours.border,
		});
	}
	if box.flags & .DRAW_SIDE_LEFT {
		submit_instance(.{
			dstRect = .{box.rect.x - floor(box.borderThickness/2), box.rect.y, box.borderThickness, box.rect.h},
			color = box.colours.border,
		});
	}
	if box.flags & .DRAW_SIDE_RIGHT {
		submit_instance(.{
			dstRect = .{box.rect.x + box.rect.w - floor(box.borderThickness/2), box.rect.y, box.borderThickness, box.rect.h},
			color = box.colours.border,
		});
	}
}

// Layout algorithm

set_rect_from_fixed :: (box: *UIBox) {
	box.rect.x = box.fixedPosition[0];
	box.rect.y = box.fixedPosition[1];
	box.rect.w = box.fixedSize[0];
	box.rect.h = box.fixedSize[1];
}

compute_layout :: (root: *UIBox, axis: UIAxis) {
	compute_standalone_sizes(root, axis); // text, fixed
	compute_downward_dependant_sizes(root, axis); // fit sizing
	compute_upward_dependant_sizes(root, axis); // growable/percent
	compute_positions(root, axis);
}

compute_standalone_sizes :: (root: *UIBox, axis: UIAxis) {
	floating := ifx axis == .X then UIBoxFlags.FLOATING_X else .FLOATING_Y;
	if root.flags & floating {
		sizeType := root.layout.size[axis].type;
		assert(sizeType != .GROW && sizeType != .PERCENT, "Grow and percent sized boxes cannot be floating, they need some defined size");
	}

	if root.layout.size[axis].type == {
		case .FIXED;
			root.fixedSize[axis] = root.layout.size[axis].min;
		case .TEXT;
			root.textRun = generate_text_run(root.text, xx root.fontSize, root.font,,temp);
			textSize := 0.0;
			if axis == .X {
				textSize = root.textRun.width;
			}
			else {
				textSize = root.fontSize;
			}
			root.fixedSize[axis] = textSize + root.textPadding * 2;
		case;
	}

	// recurse children
	first := root.head;
	while first {
		compute_standalone_sizes(first, axis);
		first = first.next;
	}
}

compute_upward_dependant_sizes :: (root: *UIBox, axis: UIAxis) {
	// first pass, collect growable boxes, setting them to their min sizes
	// while also expanding percent boxes into their parent
	growableBoxes: [..]*UIBox;
	growableBoxes.allocator = temp;
	child := root.head;
	while child {
		if child.layout.size[axis].type == {
			case .GROW; 
				array_add(*growableBoxes, child);
				if child.layout.size[axis].min != 0.0 {
					child.fixedSize[axis] = child.layout.size[axis].min;
				}
			case .PERCENT;
				padding := root.layout.padding.component[axis*2] + root.layout.padding.component[axis*2+1];
				childGaps := ifx root.layout.childLayoutAxis == axis then root.layout.childGap * (root.childCount-1) else 0.0;
				child.fixedSize[axis] = (root.fixedSize[axis]-padding-childGaps) * child.layout.size[axis].percent;
		}
		child = child.next;
	}

	// Calculate the remaining space in this box for things to grow into
	// note all sizing polices are done for this box at this point
	remainingSpace := root.fixedSize[axis];
	remainingSpace -= root.layout.padding.component[axis*2] + root.layout.padding.component[axis*2+1];
	if root.layout.childLayoutAxis == axis {
		remainingSpace -= root.layout.childGap * (root.childCount-1);
		child := root.head;
		while child {
			floating := UIBoxFlags.FLOATING_X;
			if axis == .Y then floating = .FLOATING_Y; 
			if !(child.flags & floating) {
				remainingSpace -= child.fixedSize[axis];
			}
			child = child.next;
		}
	}

	if root.layout.childLayoutAxis == axis {
		// iterate through the children increasing their sizes from smallest to largest
		// to use the remaining space in the layout axis
		while remainingSpace > 0.0 && growableBoxes.count > 0 {
			smallestSize:float = growableBoxes[0].fixedSize[axis];
			secondSmallest:float = FLOAT32_INFINITY;
			spaceToAdd := remainingSpace;

			for child:growableBoxes {
				if child.fixedSize[axis] < smallestSize {
					secondSmallest = smallestSize;
					smallestSize = child.fixedSize[axis];
				}

				if child.fixedSize[axis] > smallestSize {
					secondSmallest = min(secondSmallest, child.fixedSize[axis]);
					spaceToAdd = secondSmallest - smallestSize;
				}
			}

			spaceToAdd = min(spaceToAdd, remainingSpace / growableBoxes.count);

			for child:growableBoxes {
				prevSize := child.fixedSize[axis];
				if child.fixedSize[axis] == smallestSize {
					child.fixedSize[axis] += spaceToAdd;
					if child.layout.size[axis].max != 0.0 && child.fixedSize[axis] >= child.layout.size[axis].max {
						child.fixedSize[axis] = child.layout.size[axis].max;
						remove child;
					}
					remainingSpace -= child.fixedSize[axis] - prevSize;
				}
			}
		}
	}
	else {
		// this is the case for off axis growing, it's much simpler
		for child:growableBoxes {
			child.fixedSize[axis] += (remainingSpace - child.fixedSize[axis]);
			if child.layout.size[axis].max != 0.0 && child.fixedSize[axis] >= child.layout.size[axis].max {
				child.fixedSize[axis] = child.layout.size[axis].max;
			}
		}
	}

	// Finally continue the chain of computation to the dependant children
	child = root.head;
	while child {
		compute_upward_dependant_sizes(child, axis);
		child = child.next;
	}
}

compute_downward_dependant_sizes :: (root: *UIBox, axis: UIAxis) { 
	// recurse children first as we depend on them
	first := root.head;
	while first {
		compute_downward_dependant_sizes(first, axis);
		first = first.next;
	}

	size := root.layout.size[axis];
	if size.type == {
		case .FIT;
			sum := 0.0;
			child := root.head;
			while child {
				floating := UIBoxFlags.FLOATING_X;
				if axis == .Y then floating = .FLOATING_Y; 

				if !(child.flags & floating) {
					if root.layout.childLayoutAxis == axis {
						sum += child.fixedSize[axis];
					}
					else {
						sum = max(sum, child.fixedSize[axis]);
					}
				}
				child = child.next;
			}
			padding := root.layout.padding.component[axis*2] + root.layout.padding.component[axis*2+1];
			root.fixedSize[axis] = sum + padding;
			if root.layout.childLayoutAxis == axis {
				root.fixedSize[axis] += root.layout.childGap * (root.childCount-1);
			}

			// apply limits
			if size.min != 0.0 && size.max != 0.0 {
				root.fixedSize[axis] = clamp(root.fixedSize[axis], root.layout.size[axis].min, root.layout.size[axis].max);
			}
			else if size.min == 0.0 && size.max != 0.0 {
				root.fixedSize[axis] = min(root.fixedSize[axis], root.layout.size[axis].max);
			}
			else if size.min != 0.0 && size.max == 0.0 {
				root.fixedSize[axis] = max(root.fixedSize[axis], root.layout.size[axis].min);
			}
		case;
	}
}

compute_positions :: (root: *UIBox, axis: UIAxis) {
	// depth first iterate through all boxes
	for :depth_first root {
		box := it;
		viewOffset := box.viewOffset;
		layoutPosition := box.layout.padding.component[axis*2];

		// loop through the children of this box
		child := box.head;
		while child {
			floating := UIBoxFlags.FLOATING_X;
			if axis == .Y then floating = .FLOATING_Y; 

			if !(child.flags & floating) {
				if box.layout.childLayoutAxis == axis {
					child.fixedPosition[axis] = box.viewOffset.component[axis] + layoutPosition;
					layoutPosition += child.fixedSize[axis] + box.layout.childGap;
				}
				else {
					if box.layout.childAlignment == {
						case .LEFT;
							child.fixedPosition[axis] = box.viewOffset.component[axis] + layoutPosition;
						case .RIGHT;
							child.fixedPosition[axis] = box.viewOffset.component[axis] + (box.fixedSize[axis]-child.fixedSize[axis]-box.layout.padding.component[axis*2]);
						case .CENTER; #through;
						case;
							child.fixedPosition[axis] = box.viewOffset.component[axis] + (box.fixedSize[axis]-child.fixedSize[axis])/2;
					}
				}
			}

			// actually set the final rect
			if axis == .X {
				child.rect.x = round(box.rect.x + child.fixedPosition[axis]);
				child.rect.w = round(child.fixedSize[axis]);
			}
			else {
				child.rect.y = round(box.rect.y + child.fixedPosition[axis]);
				child.rect.h = round(child.fixedSize[axis]);
			}
			child = child.next;
		}
	}
}

// Animations

update_animations_recursive :: (root: *UIBox, deltaTime: float64) -> bool {
	needsRedraw := false;
	for :depth_first root {
		box := it;
		
		// scroll animations
		box.viewOffset.x += cast(float) deltaTime * uiState.style.scrollAnimRate * (box.viewOffsetTarget.x - box.viewOffset.x);
		box.viewOffset.y += cast(float) deltaTime * uiState.style.scrollAnimRate * (box.viewOffsetTarget.y - box.viewOffset.y);
		if abs(box.viewOffset.x - box.viewOffsetTarget.x) < 0.001 then box.viewOffset.x = box.viewOffsetTarget.x;
		if abs(box.viewOffset.y - box.viewOffsetTarget.y) < 0.001 then box.viewOffset.y = box.viewOffsetTarget.y;
		
		// figure out if we need redraws because there are animations playing
		if abs(box.viewOffset.x - box.viewOffsetTarget.x) > 0.0 then needsRedraw = true;
		if abs(box.viewOffset.y - box.viewOffsetTarget.y) > 0.0 then needsRedraw = true;
	}
	return needsRedraw;
}

// Linked list functions

linked_list_insert :: (head: **$T, tail: **T, insertAfter: *T, toInsert: *T) {
	if head.* == null {
		// empty linked list
		head.* = toInsert;
		tail.* = toInsert;
		toInsert.next = null;
		toInsert.prev = null;
	}
	else if insertAfter == null {
		// insert at front
		toInsert.next = head.*;
		(head.*).prev = toInsert;
		head.* = toInsert;
		toInsert.prev = null;
	}
	else if insertAfter == tail.* {
		// insert at end
		(tail.*).next = toInsert;
		toInsert.prev = tail.*;
		toInsert.next = null;
		(tail.*) = toInsert;
	}
	else {
		// insert in middle
		toInsert.next = insertAfter.next;
		toInsert.prev = insertAfter;
		if insertAfter.next != null {
			insertAfter.next.prev = toInsert;
		}
		insertAfter.next = toInsert;
	}
}

linked_list_remove :: (head: **$T, tail: **T, toRemove: *T) {
	if toRemove.prev != null {
		toRemove.prev.next = toRemove.next;
	}
	else {
		head.* = toRemove.next; // toRemove was first
	}

	if toRemove.next != null {
		toRemove.next.prev = toRemove.prev;
	}
	else {
		tail.* = toRemove.prev; // toRemove was last
	}
}
