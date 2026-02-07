Rect :: struct {
	x: float;
	y: float;
#place x;
    pos: Vector2;

	w: float;
	h: float;
#place w;
    size: Vector2;
}

contains_point :: (rect: Rect, x: float, y: float) -> bool {
	if (rect.x < x && x < rect.x+rect.w) && (rect.y < y && y < rect.y+rect.h) {
		return true;
	}
	return false;
}

// @todo: probably can delete a lot of this soon?

make_rect :: (x: int, y: int, w: int, h: int) -> Rect {
    r: Rect = ---;

    r.x = xx x;
    r.y = xx y;
    r.w = xx w;
    r.h = xx h;

    return r;
}

make_rect :: (x: float, y: float, w: float, h: float) -> Rect {
    r: Rect = ---;

    r.x = x;
    r.y = y;
    r.w = w;
    r.h = h;

    return r;
}

expand :: (rect: Rect, amount: float) -> Rect {
    r := rect;

    r.x -= amount;
    r.y -= amount;
    r.w += 2 * amount;
    r.h += 2 * amount;

    return r;
}

expand_x :: (rect: Rect, amount: float) -> Rect {
    r := rect;

    r.x -= amount;
    r.w += 2 * amount;

    return r;
}

expand_y :: (rect: Rect, amount: float) -> Rect {
    r := rect;

    r.y -= amount;
    r.h += 2 * amount;

    return r;
}

shrink :: (rect: Rect, amount: float) -> Rect {
    return expand(rect, -amount);
}

shrink_x :: (rect: Rect, amount: float) -> Rect {
    return expand_x(rect, -amount);
}

shrink_y :: (rect: Rect, amount: float) -> Rect {
    return expand_y(rect, -amount);
}

cut_left :: (rect: Rect, amount: float, $margin := 0) -> (left: Rect,  remainder: Rect) {
    amount = floor(amount);

    remainder := rect;

    remainder.w -= amount;
    remainder.x += amount;

    left := rect;
    left.w = amount;

    #if margin > 0 {
        #assert margin % 2 == 0;
        half_margin := margin / 2;
        remainder.x += margin;
        remainder.w -= half_margin;
        left.w      -= half_margin;
    }

    return left, remainder;
}

cut_right :: (rect: Rect, amount: float, $margin := 0) -> (right: Rect, remainder: Rect) {
    amount = floor(amount);

    remainder := rect;

    remainder.w -= amount;

    right := rect;
    right.x = remainder.x + remainder.w;
    right.w = amount;

    #if margin > 0 {
        #assert margin % 2 == 0;
        half_margin := margin / 2;
        remainder.x -= margin;
        remainder.w += half_margin;
        right.w     -= half_margin;
    }

    return right, remainder;
}

cut_bottom :: (rect: Rect, amount: float) -> (bottom: Rect, remainder: Rect) {
    amount = floor(amount);

    remainder := rect;

    remainder.h -= amount;
    remainder.y += amount;

    bottom := rect;
    bottom.h = amount;

    return bottom, remainder;
}

cut_top :: (rect: Rect, amount: float) -> (top: Rect, remainder: Rect) {
    amount = floor(amount);

    remainder := rect;

    remainder.h -= amount;

    top := rect;
    top.h = amount;
    top.y = remainder.y + remainder.h;

    return top, remainder;
}
