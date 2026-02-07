
UIBoxDeclaration :: struct {
	flags: UIBoxFlags;
	layout: UILayoutData;
	fixedX: float;
	fixedY: float;
	palette: UIPalette;
	cornerRadius: Vector4;
	borderThickness: float;
	fontSize: float;
	font: *Font;
	textPadding: float;
	textAlignment: UIAlignment;
}

UIBox :: struct {
	key: UIKey;

	// tree
	next: *UIBox; // siblings
	prev: *UIBox;
	head: *UIBox; // chilren
	tail: *UIBox;
	parent: *UIBox;

	// per frame information (must be cleared in box())
	using declaration: UIBoxDeclaration;
	text: string;
	textRun: TextRun;
	textHighlights: []Highlight;
	childCount: s32;
	fixedPosition: [UIAxis.COUNT]float; // parent relative
	fixedSize: [UIAxis.COUNT]float;
	rect: Rect; // final rect for rendering
	customDrawFunction: (*UIBox, *void);
	customDrawUdata: *void;

	// persistent data
	firstTouchedFrame: u64;
	lastTouchedFrame: u64;
	viewOffset: Vector2;
	viewOffsetTarget: Vector2;
	viewBounds: Vector2;
	hotTimer: float;
	activeTimer: float;
	dragPrevPos: Vector2;
	// @todo: actually maintain the whole signal state from the previous frame for this
	leftClickStateLastFrame: bool;
}

UILayoutData :: struct {
	childLayoutAxis: UIAxis;
	padding: Vector4; // left, right, top, bottom
	childGap: float;
	childAlignment: UIAlignment;
	width: UISize;
	height: UISize;
#place width;
    size: [2]UISize = ---;
}

// @todo: this needs to be much better
// Needs different mouse buttons, needs
// transient states like "onpressed" to be implemented better than now
// also needs "double click" events
UISignal :: struct {
	hovering: bool;
	pressed: bool;
	released: bool;
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
	DRAW_HOT_EFFECTS;
	DRAW_ACTIVE_EFFECTS;
	MOUSE_CLICKABLE;
	FLOATING_X;
	FLOATING_Y;
	FIXED_WIDTH;
	FIXED_HEIGHT;
	CLIP_CONTENTS;
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

UIPalette :: struct {
	background: Vector4;
	hot: Vector4;
	active: Vector4;
	text: Vector4;
	textHighlight: Vector4;
	border: Vector4;
#place background;
	colors: [6]Vector4 = ---;
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
	rootbox: *UIBox;
	tooltip: *UIBox;
	parentStack: [32]*UIBox;
	parentStackTop: s32 = 1;

	defaultPalette: UIPalette;
	defaultFont: *Font;
	defaultFontSize := 15.0;
	defaultTextPadding := 0.0;
	defaultTextAlignment:UIAlignment = .LEFT;

	// Persistent UI data
	boxTable: Table(UIKey, *UIBox, given_compare_function=compare_key, given_hash_function=x=>get_hash(x.keyVal));
	freeListHead: *UIBox;
	freeListTail: *UIBox;
	contextMenu: *UIBox; // at some point it may be desirable to have a "popup" stack like imgui?
	activeContextMenu: UIKey;
	nextActiveContextMenu: UIKey;
	hotBoxKey: UIKey;
	activeBoxKey: UIKey;

	frameIndex: u64;

	events: [..]Input.Event;
}
uiState: UIState;

init_ui :: () {
	uiState.alloc = Allocator.{ proc = flat_pool_allocator_proc, data = *uiState.arena };
	uiState.frameAlloc = Allocator.{ proc = flat_pool_allocator_proc, data = *uiState.frameArena };

	uiState.boxTable.allocator = uiState.alloc;
	init(*uiState.boxTable, 4096);

	uiState.frameIndex = 0;
}

find_box :: (key: UIKey) -> bool, *UIBox {
	success, box:= table_find_new(*uiState.boxTable, key);
	return success, box;
}

box :: (key: UIKey = ui_key_nil, data: UIBoxDeclaration) -> *UIBox {
	// attempt to get the box from persistent data using it's key
	success, box := table_find_new(*uiState.boxTable, key);

	// if it can't be found it's new
	if !success {
		// transient box, we'll allocate in the frame allocator (cleared at the end of the frame)
			childAlignment: UIAlignment;
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
	box.next = null;
	box.prev = null;
	box.head = null;
	box.tail = null;
	box.parent = top_parent();
	box.childCount = 0;
	box.fixedPosition = .[0,0];
	box.fixedSize = .[0,0];
	box.key = key;
	box.declaration = data;
	box.customDrawFunction = null;
	box.lastTouchedFrame = uiState.frameIndex;

	if data.fixedX != 0.0 {
		box.fixedPosition[UIAxis.X] = data.fixedX;
		box.flags |= .FLOATING_X;
		assert(box.layout.size[UIAxis.X].type != .GROW || box.layout.size[UIAxis.X].type != .PERCENT, "Grow and percent sized boxes cannot be floating, they need some defined size"); 
	}
	if data.fixedY != 0.0 {
		box.fixedPosition[UIAxis.Y] = data.fixedY;
		box.flags |= .FLOATING_Y;
		assert(box.layout.size[UIAxis.Y].type != .GROW || box.layout.size[UIAxis.Y].type != .PERCENT, "Grow and percent sized boxes cannot be floating, they need some defined size"); 
	}

	if box.flags & .DRAW_TEXT || box.flags & .DRAW_TEXT_HIGHLIGHTS {
		box.text = display_string_from_key(box.key.keyStr);
	}

	// override palette defaults if specified
	box.palette = uiState.defaultPalette;
	for 0..size_of(UIPalette)/size_of(Vector4)-1 {
		if  data.palette.colors[it].x != 0 || 
			data.palette.colors[it].y != 0 ||
			data.palette.colors[it].z != 0 ||
			data.palette.colors[it].w != 0
		{
			box.palette.colors[it] = data.palette.colors[it];
		}
	}

	// override text/font defaults
	box.font = uiState.defaultFont;
	if data.font != null {
		box.font = data.font;
	}
	box.fontSize = uiState.defaultFontSize;
	if data.fontSize != 0.0 {
		box.fontSize = data.fontSize;
	}
	box.textPadding = uiState.defaultTextPadding;
	if data.textPadding != 0.0 {
		box.textPadding = data.textPadding;
	}
	box.textAlignment = uiState.defaultTextAlignment;
	if data.textAlignment != uiState.defaultTextAlignment {
		box.textAlignment = data.textAlignment;
	}

	// insert into parent's list of children
	if box.parent {
		linked_list_insert(*box.parent.head, *box.parent.tail, box.parent.tail, box);
		box.parent.childCount += 1;
	}

	return box;
}

signal_from_box :: (box: *UIBox) -> UISignal {
	signal: UISignal;
    x, y, success := get_mouse_pointer_position(window, false);
	box_contains_cursor := contains_point(box.rect, xx x, xx y);

	if  box_contains_cursor {
		signal.hovering = true;
		if box.flags & .MOUSE_CLICKABLE {
			uiState.hotBoxKey = box.key;
		}
	}

	for uiState.events {
		if it.type == {
			case .KEYBOARD;
				// left click press
				if box.flags & .MOUSE_CLICKABLE && it.key_pressed && it.key_code == .MOUSE_BUTTON_LEFT && box_contains_cursor { 
					uiState.activeBoxKey = box.key;
					if box.leftClickStateLastFrame == false {
						signal.pressed = true;
					}
					box.leftClickStateLastFrame = true;
					box.dragPrevPos = .{xx x,xx y};
					remove it;
				}
				// left click release inside box
				if box.flags & .MOUSE_CLICKABLE
					&& !it.key_pressed
					&& it.key_code == .MOUSE_BUTTON_LEFT
					&& uiState.activeBoxKey == box.key
					&& box_contains_cursor { 

					signal.released = true;
					box.leftClickStateLastFrame = false;
					uiState.activeBoxKey = ui_key_nil;
					remove it;
				}

				// left click release outside box
				if box.flags & .MOUSE_CLICKABLE
					&& !it.key_pressed
					&& it.key_code == .MOUSE_BUTTON_LEFT
					&& uiState.activeBoxKey == box.key
					&& !box_contains_cursor { 

					box.leftClickStateLastFrame = false;
					uiState.hotBoxKey = ui_key_nil;
					uiState.activeBoxKey = ui_key_nil;
					remove it;
				}

				// clicking somewhere outside of context menu
				if uiState.contextMenu && uiState.activeContextMenu != ui_key_nil && !contains_point(uiState.contextMenu.rect, xx x, xx y) && it.key_pressed {
					context_menu_close();
				}

			case .MOUSE_WHEEL;
                if it.wheel_delta && box_contains_cursor {
					metrics := get_font_metrics(box.font, xx box.fontSize);
					box.viewOffsetTarget.y += (it.wheel_delta/it.typical_wheel_delta)*metrics.lineSpacing*3;
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

begin_ui :: () {
	uiState.rootbox = box(ui_key_nil, .{
		layout=.{childLayoutAxis=.Y, width=fixed(xx windowWidth), height=fixed(xx windowHeight)},
	}); 
	uiState.hotBoxKey = ui_key_nil;
	uiState.tooltip = null;
	push_parent(uiState.rootbox);
}

end_ui :: () {
	// yeet any unused boxes
	for uiState.boxTable {
		if it.lastTouchedFrame < uiState.frameIndex || it.key == ui_key_nil {
			table_remove(*uiState.boxTable, it.key);
			linked_list_insert(*uiState.freeListHead, *uiState.freeListTail, uiState.freeListTail, it);
		}
	}

	// layout all the boxes
	compute_layout(uiState.rootbox, .X);
	compute_layout(uiState.rootbox, .Y);

	// set the root box rect 
	uiState.rootbox.rect.x = uiState.rootbox.fixedPosition[0];
	uiState.rootbox.rect.y = uiState.rootbox.fixedPosition[1];
	uiState.rootbox.rect.w = uiState.rootbox.fixedSize[0];
	uiState.rootbox.rect.h = uiState.rootbox.fixedSize[1];

	// adjust position of floating popups to be within bounds (i.e. context menu/tooltips)
	floatingRoots := *UIBox.[uiState.tooltip, uiState.contextMenu];
	for floatingRoots {
		if it != null {
			xBounds := uiState.rootbox.rect.w - em(0.3, it.fontSize); // padding
			yBounds := uiState.rootbox.rect.h - em(0.3, it.fontSize); // padding
			xShiftDown := max(it.rect.x, 0) - it.rect.x;
			xShiftUp := min(it.rect.x+it.rect.w, xBounds) - (it.rect.x+it.rect.w);
			it.rect.x += xShiftDown + xShiftUp;
			yShiftDown := max(it.rect.x, 0) - it.rect.x;
			yShiftUp := min(it.rect.y+it.rect.h, yBounds) - (it.rect.y+it.rect.h);
			it.rect.y += yShiftDown + yShiftUp;

			compute_layout(it, .X);
			compute_layout(it, .Y);
		}
	}

	// do animations
	for :depth_first uiState.rootbox {
		box := it;

		// scroll animations
		box.viewOffset.x += cast(float) deltaTime * style.scrollAnimRate * (box.viewOffsetTarget.x - box.viewOffset.x);
		box.viewOffset.y += cast(float) deltaTime * style.scrollAnimRate * (box.viewOffsetTarget.y - box.viewOffset.y);
		if abs(box.viewOffset.x - box.viewOffsetTarget.x) < 0.001 then box.viewOffset.x = box.viewOffsetTarget.x;
		if abs(box.viewOffset.y - box.viewOffsetTarget.y) < 0.001 then box.viewOffset.y = box.viewOffsetTarget.y;

		// figure out if we need redraws because there are animations playing
		if abs(box.viewOffset.x - box.viewOffsetTarget.x) > 0.0 then requestRedraw = true;
		if abs(box.viewOffset.y - box.viewOffsetTarget.y) > 0.0 then requestRedraw = true;
	}

	render_ui_recursive(uiState.rootbox);
	for floatingRoots {
		if it != null then render_ui_recursive(it);
	}

	if uiState.activeContextMenu != ui_key_nil && uiState.nextActiveContextMenu == ui_key_nil {
		uiState.contextMenu = null;
		uiState.activeContextMenu = ui_key_nil;
	}
	else if uiState.activeContextMenu == ui_key_nil && uiState.nextActiveContextMenu != ui_key_nil {
		uiState.activeContextMenu = uiState.nextActiveContextMenu;
	}

	reset(*uiState.frameArena, overwrite_memory=true);
	uiState.frameIndex += 1;
	uiState.parentStackTop = 1;
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

// parent stack

push_parent :: (box: *UIBox) {
	uiState.parentStack[uiState.parentStackTop] = box;
	uiState.parentStackTop += 1;
}

pop_parent :: () -> *UIBox {
	if uiState.parentStackTop != 1 {
		uiState.parentStackTop -= 1;
		return uiState.parentStack[uiState.parentStackTop]; 
	}
	return uiState.parentStack[0];
}

top_parent :: () -> *UIBox {
	return uiState.parentStack[uiState.parentStackTop-1]; 
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

display_string_from_key :: (str: string) -> string {
    index := find_index_from_left(str, "##");
	if index < 0
		return str;
	return slice(str, 0, index);
}

// Basic widgets

// @todo: actually use these
label :: (text: string) -> UISignal, *UIBox {
	label := box(ui_key(text), .{flags=.DRAW_TEXT});
	return signal_from_box(label), label;
}

label :: (textFormat: string, args: ..Any) -> UISignal, *UIBox {
	label := box(ui_key(textFormat, ..args), .{flags=.DRAW_TEXT});
	return signal_from_box(label), label;
}

button :: (text: string) -> UISignal {
	button := box(ui_key(text), .{flags=.DRAW_BACKGROUND | .DRAW_TEXT | .DRAW_HOT_EFFECTS | .DRAW_ACTIVE_EFFECTS | .MOUSE_CLICKABLE});
	return signal_from_box(button);
}

tooltip_begin :: (anchorBoxKey:UIKey = ui_key_nil, anchorOffset: Vector2 = .{0.0,0.0}) {
	success, anchor := find_box(anchorBoxKey);
	fixedX, fixedY := 0.0;
	if success {
		fixedX = anchor.rect.x + anchorOffset.x;
		fixedY = anchor.rect.y + anchorOffset.y;
	}
	else {
		x, y, success := get_mouse_pointer_position(window, false);
		fixedX = cast(float, x + 20);
		fixedY = cast(float, y + 20);
	}

	uiState.tooltip = box(ui_key("tooltip"), .{
		flags=.DRAW_BACKGROUND | .DRAW_BORDER,
		layout=.{ 
			childLayoutAxis = .X,
			width=fit(),
			height=fit(),
			padding=padding_all(em(0.5))
		},
		palette=.{ background=style.backgroundLight },
		borderThickness=1.0,
		cornerRadius=corner_rad_all(em(0.4)),
		fixedX = fixedX,
		fixedY = fixedY,
	});

	push_parent(uiState.tooltip);
}

tooltip_end :: () {
	pop_parent();
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

context_menu_begin :: (key: UIKey, width: UISize, anchorBoxKey:UIKey = .{0,""}, anchorOffset: Vector2 = .{0.0,0.0}) -> bool {
	if uiState.activeContextMenu == key {

		success, anchor := find_box(anchorBoxKey);
		fixedX, fixedY := 0.0;
		if success {
			fixedX = anchor.rect.x + anchorOffset.x;
			fixedY = anchor.rect.y + anchorOffset.y;
		}
		else {
			x, y, success := get_mouse_pointer_position(window, false);
			fixedX = cast(float, x + 20);
			fixedY = cast(float, y + 20);
		}

		uiState.contextMenu = box(ui_key("context"), .{
			flags=.DRAW_BACKGROUND | .DRAW_BORDER,
			layout=.{ 
				childLayoutAxis = .Y,
				width=width,
				height=fit(),
				padding=padding_all(em(0.5)),
				childGap=em(0.2),
			},
			palette=.{ background=style.backgroundLight },
			borderThickness=1.0,
			cornerRadius=corner_rad_all(em(0.4)),
			fixedX = fixedX,
			fixedY = fixedY,
		});

		push_parent(uiState.contextMenu);
		return true;
	}
	return false;
}

context_menu_item :: (text: string, icon: string) -> UISignal {
	id := top_parent().childCount;
	row := box(ui_key("menuitem%", id), .{
		flags=.DRAW_BACKGROUND | .DRAW_HOT_EFFECTS | .MOUSE_CLICKABLE,
		layout=.{ 
			childLayoutAxis = .X,
			width=grow(),
			height=fit(),
		},
		palette=.{background = style.backgroundLight}
	});
	{
		push_parent(row); defer pop_parent();

		// icon
		if icon.count {
			box(ui_key(icon), .{
				flags=.DRAW_TEXT,
				layout=.{ width=fixed(em(2.0)), height=text_content() },
				font=fontIcons
			});
		}
		else {
			box(ui_key_nil, .{ layout=.{ width=fixed(em(2.0)) }, });
		}

		// text
		box(ui_key("%##%", text, id), .{
			flags=.DRAW_TEXT,
			layout=.{ width=text_content(), height=text_content() },
		});
	}
	return signal_from_box(row);
}


context_menu_end :: () {
	pop_parent();
}

spacer :: (axis: UIAxis, size: UISize) {
	if axis == .X {
		box(ui_key_nil, .{ layout=.{ width=size } });
	}
	else {
		box(ui_key_nil, .{ layout=.{ height=size } });
	}
}

scroll_bar :: (key: UIKey, axis: UIAxis, scrollOffsetPct: float, scrollableRange:float, visibleRange: float, boxToScroll: UIKey) {
	scrollAxis := axis;
	otherAxis := axis ^ 1;

	if abs(scrollableRange) < abs(visibleRange) return;
	
	layout := UILayoutData.{ padding=padding_all(em(0.3))};
	layout.size[axis^1] = fixed(em(1.2));
	layout.size[axis] = grow();
	container := box(ui_key_nil, .{layout = layout});
	{
		push_parent(container); defer pop_parent();

		scrollBarOuter := box(ui_key_nil, .{
			flags=.DRAW_BACKGROUND,
			layout=.{childLayoutAxis = axis, width=grow(), height=grow()},
			cornerRadius=corner_rad_all(em(0.3)),
			palette=.{background=style.backgroundLight}
		});
		{
			push_parent(scrollBarOuter); defer pop_parent();

			handleSizePct := max(abs(visibleRange/scrollableRange), 0.05);
			spaceBeforePct := (1.0-handleSizePct) * scrollOffsetPct;

			// space before
			layout = UILayoutData.{};
			layout.size[axis^1] = grow();
			layout.size[axis] = percent(spaceBeforePct);
			box(ui_key_nil, .{layout = layout});

			// handle
			layout = UILayoutData.{};
			layout.size[axis^1] = grow();
			layout.size[axis] = percent(handleSizePct);
			scrollHandle := box(key, .{
				flags=.DRAW_BACKGROUND | .MOUSE_CLICKABLE | .DRAW_HOT_EFFECTS | .DRAW_ACTIVE_EFFECTS,
				layout=layout,
				palette=.{background=style.backgroundLighter},
				cornerRadius=corner_rad_all(em(0.3))
			});

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

scroll_list_begin :: (listKey: UIKey, maxContainerHeight: float, elementHeight: float, maxElements: int, selectedElement: int, selectedElementChanged: bool) -> rangeStart: int, rangeEnd: int {
	outerContainer := box(ui_key_nil, .{ flags=0, layout=.{width=grow(), height=fit(), }});
	push_parent(outerContainer);

	maxContainerHeightInner := maxContainerHeight - em(0.4)*2; // without the padding

	container := box(listKey, .{
		flags=.CLIP_CONTENTS, 
		layout=.{ childLayoutAxis = .Y, width=grow(), height=fit(0.0, maxContainerHeight), padding=.{0,0, em(0.4), em(0.4)} },
	});

	elementsBefore := cast(int, floor(abs(container.viewOffset.y) / elementHeight));
	elementsOnScreen := min(cast(int, round(maxContainerHeightInner / elementHeight) + 1), maxElements);

	container.viewBounds.y = min(cast(float, -(maxElements * elementHeight - maxContainerHeightInner)), 0.0);
	signal_from_box(container);

	// keyboard scrolling behaviour 
	// @todo: don't really like the fact that we need to do this, need a better way to deal with it
	// I guess the best solution is that the signal above is what actually changes the element and we manage it inside UI
	if selectedElementChanged {
		elementsBeforeTarget := cast(int, floor(abs(container.viewOffsetTarget.y) / elementHeight));
		if selectedElement < elementsBeforeTarget+1 { 
			distance := elementsBeforeTarget - selectedElement;
			container.viewOffsetTarget.y = -selectedElement*elementHeight;
		}
		if selectedElement > (elementsBeforeTarget+elementsOnScreen-2) {
			container.viewOffsetTarget.y = -(selectedElement+1)*elementHeight+(maxContainerHeight-em(0.4));
		}
	}

	push_parent(container);

	// spacer to fill gap of elements that are offscreen
	spacer(.Y, fixed(elementsBefore*elementHeight));

	rangeEnd := min(elementsBefore+elementsOnScreen-1, maxElements-1);
	rangeStart := elementsBefore; 
	return rangeStart, rangeEnd;
}

scroll_list_end :: (scrollBarKey: UIKey) {
	container := pop_parent(); // list element container

	container.viewOffset.y = clamp(container.viewOffset.y, container.viewBounds.y, 0);
	container.viewOffset.x = clamp(container.viewOffset.x, container.viewBounds.x, 0);
	container.viewOffsetTarget.y = clamp(container.viewOffsetTarget.y, container.viewBounds.y, 0);
	container.viewOffsetTarget.x = clamp(container.viewOffsetTarget.x, container.viewBounds.x, 0);

	// scroll bar if there are too many elements to display
	if container.viewBounds.y != 0.0 {
		scrollData:= scroll_bar(scrollBarKey,
								.Y,
								container.viewOffset.y/container.viewBounds.y,
								container.viewBounds.y,
								container.layout.height.max - em(0.4)*2,
								container.key);
	}

	pop_parent(); // outer container (inc scroll bar)
}

// @todo: widgets:
// [ ] - context menu item
// [ ] - Table stuff
// [ ] - Text input box
// [ ] - Checkbox
// [ ] - 

// helpers

fixed :: (pixels: float) -> UISize { return .{type=.FIXED, min=pixels, max=pixels};}
fit :: (min: float = 0.0, max: float=0.0) -> UISize { return .{type=.FIT, min=min, max=max};}
grow :: (min: float = 0.0, max: float=0.0) -> UISize { return .{type=.GROW, min=min, max=max};}
percent :: (percent: float) -> UISize { return .{type=.PERCENT, percent=percent};}
text_content :: () -> UISize { return .{type=.TEXT};}

em :: (size: float, fontSize: float = 0.0) -> float { return ifx fontSize == 0.0 then size*uiState.defaultFontSize else size*fontSize; }

corner_rad_all :: (v: float) -> Vector4 {return .{v,v,v,v};}
padding_all :: (v: float) -> Vector4 {return .{v,v,v,v};}



#scope_file

// rendering the tree

render_ui_recursive :: (box: *UIBox) {
	if box.flags & .DRAW_BACKGROUND {
		color := box.palette.background;

		if box.flags & .DRAW_HOT_EFFECTS && uiState.hotBoxKey != ui_key_nil && box.key == uiState.hotBoxKey {
			color = box.palette.hot;
		}
		if box.flags & .DRAW_ACTIVE_EFFECTS && uiState.activeBoxKey != ui_key_nil && box.key == uiState.activeBoxKey {
			color = box.palette.active;
		}

		submit_instance(.{
			dstRect = box.rect,
			color = color,
			cornerRadii = box.cornerRadius,
		});
	}

	if box.flags & .CLIP_CONTENTS {
		set_scissor(box.rect);
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
		draw_text_run(box.textRun, xPos, yPos, box.palette.text);
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
		draw_text_run_highlights(box.textRun, xPos, yPos, box.textHighlights, box.palette.text, box.palette.textHighlight);
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
		clear_scissor();
	}

	if box.flags & .DRAW_BORDER {
		submit_instance(.{
			dstRect = box.rect,
			color = box.palette.border,
			cornerRadii = box.cornerRadius,
			borderThickness = box.borderThickness
		});
	}

	if box.flags & .DRAW_SIDE_TOP {
		submit_instance(.{
			dstRect = .{box.rect.x, box.rect.y - floor(box.borderThickness/2), box.rect.w, box.borderThickness},
			color = box.palette.border,
		});
	}
	if box.flags & .DRAW_SIDE_BOTTOM {
		submit_instance(.{
			dstRect = .{box.rect.x, box.rect.y + box.rect.h - floor(box.borderThickness/2), box.rect.w, box.borderThickness},
			color = box.palette.border,
		});
	}
	if box.flags & .DRAW_SIDE_LEFT {
		submit_instance(.{
			dstRect = .{box.rect.x - floor(box.borderThickness/2), box.rect.y, box.borderThickness, box.rect.h},
			color = box.palette.border,
		});
	}
	if box.flags & .DRAW_SIDE_RIGHT {
		submit_instance(.{
			dstRect = .{box.rect.x + box.rect.w - floor(box.borderThickness/2), box.rect.y, box.borderThickness, box.rect.h},
			color = box.palette.border,
		});
	}
}

// Layout algorithm

compute_layout :: (root: *UIBox, axis: UIAxis) {	
	compute_standalone_sizes(root, axis); // text, fixed 
	compute_downward_dependant_sizes(root, axis); // fit sizing
	compute_upward_dependant_sizes(root, axis); // growable/percent
	compute_positions(root, axis);
}

compute_standalone_sizes :: (root: *UIBox, axis: UIAxis) {
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

// Linked list functions

linked_list_insert :: (head: **$T, tail: **T, insertAfter: *T, toInsert: *T) {
	if <<head == null {
		// empty linked list
		<<head = toInsert;
		<<tail = toInsert;
		toInsert.next = null;
		toInsert.prev = null;
	}
	else if insertAfter == null {
		// insert at front
		toInsert.next = <<head;
		(<<head).prev = toInsert;
		<<head = toInsert;
		toInsert.prev = null;
	}
	else if insertAfter == <<tail {
		// insert at end
		(<<tail).next = toInsert;
		toInsert.prev = <<tail;
		toInsert.next = null;
		(<<tail) = toInsert;
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
		<<head = toRemove.next; // toRemove was first
	}

	if toRemove.next != null {
		toRemove.next.prev = toRemove.prev;
	}
	else {
		<<tail = toRemove.prev; // toRemove was last
	}
}
