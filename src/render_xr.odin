// The XRender renderer: the fallback when GLX is unavailable. It repaints
// only the damaged region into a back buffer and copies that region to the
// overlay window. Shadows are nine-patches cut from one pre-computed
// template, corners use small anti-aliased masks. No blur, and the zoom
// animation shows as a fade.
package lactase

import "core:log"
import "core:math"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

XR_Win :: struct {
	pic:        Picture,
	shadow:     Picture, // this window's own shadow (windows smaller than the template)
	shadow_key: [5]i32,
}

@(private="file")
Shadow_Template :: struct {
	key:     [4]i32, // radius, sigma×100, opacity×255, 1
	full:    Picture,
	top, bottom, left, right: Picture, // one-pixel strips, repeated along the edges
	e:       i32, // extent beyond the box
	c:       i32, // corner tile size
	size:    i32, // template side (2c + 1)
}

XR :: struct {
	w, h:      i32,
	back:      Picture,
	target:    Picture,
	root_fmt:  ^XRenderPictFormat,
	a8:        ^XRenderPictFormat,
	wall:      Picture,
	wall_prev: Picture,
	template:  Shadow_Template,
	corners:   map[[2]i32]Picture, // (radius, alpha) → 2r×2r mask of a disc
	warned_blur: bool,
}

xr_init :: proc(comp: ^Comp) -> bool {
	xr := new(XR)
	xr.root_fmt = XRenderFindVisualFormat(comp.dpy, comp.c.visual)
	xr.a8 = XRenderFindStandardFormat(comp.dpy, PICT_STANDARD_A8)
	if xr.root_fmt == nil || xr.a8 == nil {
		log.error("XRender: no picture format for the root visual")
		free(xr)
		return false
	}
	attrs: xlib.XWindowAttributes
	xlib.GetWindowAttributes(comp.dpy, comp.overlay, &attrs)
	target_fmt := XRenderFindVisualFormat(comp.dpy, attrs.visual)
	pa: XRenderPictureAttributes
	pa.subwindow_mode = INCLUDE_INFERIORS
	xr.target = XRenderCreatePicture(comp.dpy, comp.overlay, target_fmt, CP_SUBWINDOW_MODE, &pa)
	xr.corners = make(map[[2]i32]Picture)
	comp.xr = xr
	xr_resize(comp)
	comp.root_changed = true
	log.info("XRender renderer (no vsync, no blur)")
	return true
}

xr_shutdown :: proc(comp: ^Comp) {
	xr := comp.xr
	if xr == nil { return }
	for w in comp.wins { xr_release_window(comp, w) }
	free_template(comp)
	for _, pic in xr.corners { XRenderFreePicture(comp.dpy, pic) }
	delete(xr.corners)
	for pic in ([]Picture{xr.back, xr.target, xr.wall, xr.wall_prev}) {
		if pic != 0 { XRenderFreePicture(comp.dpy, pic) }
	}
	free(xr)
	comp.xr = nil
}

xr_resize :: proc(comp: ^Comp) {
	xr := comp.xr
	if xr == nil { return }
	if xr.back != 0 { XRenderFreePicture(comp.dpy, xr.back) }
	xr.w, xr.h = comp.screen.w, comp.screen.h
	pm := xlib.CreatePixmap(comp.dpy, comp.root, u32(xr.w), u32(xr.h), u32(comp.c.depth))
	xr.back = XRenderCreatePicture(comp.dpy, pm, xr.root_fmt, 0, nil)
	xlib.FreePixmap(comp.dpy, pm)
	comp.root_changed = true
}

xr_config_changed :: proc(comp: ^Comp) {
	free_template(comp)
	for w in comp.wins {
		if w.xr.shadow != 0 {
			XRenderFreePicture(comp.dpy, w.xr.shadow)
			w.xr.shadow = 0
		}
	}
}

xr_release_window :: proc(comp: ^Comp, w: ^Win) {
	if w.xr.pic != 0 { XRenderFreePicture(comp.dpy, w.xr.pic) }
	if w.xr.shadow != 0 { XRenderFreePicture(comp.dpy, w.xr.shadow) }
	w.xr = {}
}

// ---------------------------------------------------------------------------
// Masks
// ---------------------------------------------------------------------------
// An A8 picture from bytes (the pixmap is released at once; the picture keeps it).
@(private="file")
a8_picture :: proc(comp: ^Comp, data: []u8, w, h: i32, repeat := false) -> Picture {
	pm := xlib.CreatePixmap(comp.dpy, comp.root, u32(w), u32(h), 8)
	img := xlib.CreateImage(comp.dpy, comp.c.visual, 8, .ZPixmap, 0, raw_data(data), u32(w), u32(h), 8, w)
	if img != nil {
		gc := xlib.CreateGC(comp.dpy, pm, {}, nil)
		xlib.PutImage(comp.dpy, pm, gc, img, 0, 0, 0, 0, u32(w), u32(h))
		xlib.FreeGC(comp.dpy, gc)
		img.data = nil
		xlib.DestroyImage(img)
	}
	attrs: XRenderPictureAttributes
	mask: uint
	if repeat {
		attrs.repeat = REPEAT_NORMAL
		mask |= CP_REPEAT
	}
	pic := XRenderCreatePicture(comp.dpy, pm, comp.xr.a8, mask, &attrs)
	xlib.FreePixmap(comp.dpy, pm)
	return pic
}

// A 2r×2r disc (the four corners) scaled by alpha; same edge as the GL shader.
@(private="file")
corner_mask :: proc(comp: ^Comp, r: i32, alpha: u8) -> Picture {
	xr := comp.xr
	key := [2]i32{r, i32(alpha)}
	if pic, ok := xr.corners[key]; ok { return pic }
	if len(xr.corners) > 96 {
		for _, pic in xr.corners { XRenderFreePicture(comp.dpy, pic) }
		clear(&xr.corners)
	}
	size := 2 * r
	data := make([]u8, int(size * size), context.temp_allocator)
	fr := f32(r)
	for y in 0 ..< size {
		for x in 0 ..< size {
			px := f32(x) + 0.5
			py := f32(y) + 0.5
			qx := min(px, f32(size) - px)
			qy := min(py, f32(size) - py)
			cov: f32 = 1
			if qx < fr && qy < fr { cov = clamp(fr - math.sqrt((fr - qx) * (fr - qx) + (fr - qy) * (fr - qy)), 0, 1) }
			data[y * size + x] = u8(cov * f32(alpha) + 0.5)
		}
	}
	pic := a8_picture(comp, data, size, size)
	xr.corners[key] = pic
	return pic
}

@(private="file")
free_template :: proc(comp: ^Comp) {
	xr := comp.xr
	if xr == nil { return }
	t := &xr.template
	for pic in ([]Picture{t.full, t.top, t.bottom, t.left, t.right}) {
		if pic != 0 { XRenderFreePicture(comp.dpy, pic) }
	}
	t^ = {}
}

@(private="file")
shadow_template :: proc(comp: ^Comp, radius: i32) -> ^Shadow_Template {
	xr := comp.xr
	sigma := shadow_sigma(comp)
	key := [4]i32{radius, i32(sigma * 100), i32(comp.cfg.shadows.opacity * 255), 1}
	t := &xr.template
	if t.key == key && t.full != 0 { return t }
	free_template(comp)
	t.key = key
	t.e = i32(math.ceil(3 * sigma)) + 1
	t.c = 2 * t.e + radius
	t.size = 2 * t.c + 1
	box := t.size - 2 * t.e
	data := shadow_image(box, box, t.e, f32(radius), sigma, f32(comp.cfg.shadows.opacity))
	t.full = a8_picture(comp, data, t.size, t.size)
	s, c := t.size, t.c
	top := make([]u8, int(c), context.temp_allocator)
	bottom := make([]u8, int(c), context.temp_allocator)
	left := make([]u8, int(c), context.temp_allocator)
	right := make([]u8, int(c), context.temp_allocator)
	for i in 0 ..< c {
		top[i] = data[i * s + c]
		bottom[i] = data[(s - c + i) * s + c]
		left[i] = data[c * s + i]
		right[i] = data[c * s + s - c + i]
	}
	t.top = a8_picture(comp, top, 1, c, true)
	t.bottom = a8_picture(comp, bottom, 1, c, true)
	t.left = a8_picture(comp, left, c, 1, true)
	t.right = a8_picture(comp, right, c, 1, true)
	return t
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------
@(private="file")
set_clip :: proc(comp: ^Comp, region: XserverRegion) {
	XFixesSetPictureClipRegion(comp.dpy, comp.xr.back, 0, 0, region)
}

// Clip to damage ∩ extra (a region in screen coordinates); returns the
// region to destroy afterwards.
@(private="file")
clip_with :: proc(comp: ^Comp, extra: XserverRegion) -> XserverRegion {
	XFixesIntersectRegion(comp.dpy, extra, extra, comp.damage)
	set_clip(comp, extra)
	return extra
}

@(private="file")
solid :: proc(comp: ^Comp, c: tx.Color, alpha: f32) -> Picture {
	a := clamp(alpha, 0, 1)
	col := XRenderColor{
		red = u16(f32(c.r) * 257 * a), green = u16(f32(c.g) * 257 * a), blue = u16(f32(c.b) * 257 * a), alpha = u16(a * 65535),
	}
	return XRenderCreateSolidFill(comp.dpy, &col)
}

@(private="file")
draw_shadow :: proc(comp: ^Comp, d: ^Draw, dx, dy: i32, color: tx.Color) {
	xr := comp.xr
	s := comp.cfg.shadows
	radius := i32(d.radius)
	r := d.rect
	r.x += dx + i32(s.offset_x)
	r.y += dy + i32(s.offset_y)
	src := solid(comp, color, d.alpha)
	defer XRenderFreePicture(comp.dpy, src)

	// Never under the window itself (except its rounded-off corners).
	win := Rect{d.rect.x + dx, d.rect.y + dy, d.rect.w, d.rect.h}
	inner := []Rect{
		{win.x + radius, win.y, win.w - 2 * radius, radius},
		{win.x, win.y + radius, win.w, win.h - 2 * radius},
		{win.x + radius, win.y + win.h - radius, win.w - 2 * radius, radius},
	}
	t := shadow_template(comp, radius)
	e := t.e
	area := region_rect(comp.dpy, {r.x - e, r.y - e, r.w + 2 * e, r.h + 2 * e})
	cut := region_from_rects(comp.dpy, inner)
	XFixesSubtractRegion(comp.dpy, area, area, cut)
	XFixesDestroyRegion(comp.dpy, cut)
	clip := clip_with(comp, area)
	defer {
		XFixesDestroyRegion(comp.dpy, clip)
		set_clip(comp, comp.damage)
	}

	box := t.size - 2 * e
	if r.w < box || r.h < box {
		// Smaller than the template: this window gets its own shadow image.
		key := [5]i32{r.w, r.h, t.key[0], t.key[1], t.key[2]}
		if d.w.xr.shadow == 0 || d.w.xr.shadow_key != key {
			if d.w.xr.shadow != 0 { XRenderFreePicture(comp.dpy, d.w.xr.shadow) }
			data := shadow_image(r.w, r.h, e, f32(radius), shadow_sigma(comp), f32(s.opacity))
			d.w.xr.shadow = a8_picture(comp, data, r.w + 2 * e, r.h + 2 * e)
			d.w.xr.shadow_key = key
		}
		XRenderComposite(comp.dpy, PICT_OP_OVER, src, d.w.xr.shadow, xr.back, 0, 0, 0, 0, r.x - e, r.y - e, u32(r.w + 2 * e), u32(r.h + 2 * e))
		return
	}
	c := t.c
	x0, y0 := r.x - e, r.y - e
	x1, y1 := r.x + r.w + e, r.y + r.h + e
	mid_w := u32(max(x1 - x0 - 2 * c, 0))
	mid_h := u32(max(y1 - y0 - 2 * c, 0))
	comp_ :: proc(comp: ^Comp, src, mask: Picture, mx, my, x, y: i32, w, h: u32) {
		if w == 0 || h == 0 { return }
		XRenderComposite(comp.dpy, PICT_OP_OVER, src, mask, comp.xr.back, 0, 0, mx, my, x, y, w, h)
	}
	comp_(comp, src, t.full, 0, 0, x0, y0, u32(c), u32(c))
	comp_(comp, src, t.full, t.size - c, 0, x1 - c, y0, u32(c), u32(c))
	comp_(comp, src, t.full, 0, t.size - c, x0, y1 - c, u32(c), u32(c))
	comp_(comp, src, t.full, t.size - c, t.size - c, x1 - c, y1 - c, u32(c), u32(c))
	comp_(comp, src, t.top, 0, 0, x0 + c, y0, mid_w, u32(c))
	comp_(comp, src, t.bottom, 0, 0, x0 + c, y1 - c, mid_w, u32(c))
	comp_(comp, src, t.left, 0, 0, x0, y0 + c, u32(c), mid_h)
	comp_(comp, src, t.right, 0, 0, x1 - c, y0 + c, u32(c), mid_h)
}

// The window's pieces: four corner squares through the disc mask, three
// bands through a plain alpha. `src` = nil draws the window picture.
@(private="file")
draw_pieces :: proc(comp: ^Comp, d: ^Draw, dx, dy: i32, src: Picture, alpha: f32) {
	x, y, w, h := d.rect.x + dx, d.rect.y + dy, d.rect.w, d.rect.h
	pic := src != 0 ? src : d.w.xr.pic
	r := i32(d.radius)
	if r * 2 > w || r * 2 > h { r = min(w, h) / 2 }
	a8 := u8(clamp(alpha, 0, 1) * 255 + 0.5)
	mask: Picture
	if a8 < 255 {
		mask = solid(comp, {0, 0, 0, 255}, alpha)
	}
	defer if mask != 0 { XRenderFreePicture(comp.dpy, mask) }
	op := i32(PICT_OP_OVER)
	if src == 0 && !d.w.argb && a8 == 255 { op = PICT_OP_SRC }
	band :: proc(comp: ^Comp, op: i32, pic, mask: Picture, sx, sy, x, y, w, h: i32) {
		if w <= 0 || h <= 0 { return }
		XRenderComposite(comp.dpy, op, pic, mask, comp.xr.back, sx, sy, 0, 0, x, y, u32(w), u32(h))
	}
	if r <= 0 {
		band(comp, op, pic, mask, 0, 0, x, y, w, h)
		return
	}
	// Coordinates in the source: window-local for the window picture, screen for a solid.
	lx := src != 0 ? x : 0
	ly := src != 0 ? y : 0
	band(comp, op, pic, mask, lx + r, ly, x + r, y, w - 2 * r, r)
	band(comp, op, pic, mask, lx, ly + r, x, y + r, w, h - 2 * r)
	band(comp, op, pic, mask, lx + r, ly + h - r, x + r, y + h - r, w - 2 * r, r)
	cm := corner_mask(comp, r, a8)
	corner :: proc(comp: ^Comp, pic, cm: Picture, sx, sy, mx, my, x, y, r: i32) {
		XRenderComposite(comp.dpy, PICT_OP_OVER, pic, cm, comp.xr.back, sx, sy, mx, my, x, y, u32(r), u32(r))
	}
	corner(comp, pic, cm, lx, ly, 0, 0, x, y, r)
	corner(comp, pic, cm, lx + w - r, ly, r, 0, x + w - r, y, r)
	corner(comp, pic, cm, lx, ly + h - r, 0, r, x, y + h - r, r)
	corner(comp, pic, cm, lx + w - r, ly + h - r, r, r, x + w - r, y + h - r, r)
}

@(private="file")
update_wallpaper :: proc(comp: ^Comp) {
	xr := comp.xr
	comp.root_changed = false
	if xr.wall_prev != 0 { XRenderFreePicture(comp.dpy, xr.wall_prev) }
	xr.wall_prev = xr.wall
	xr.wall = 0
	comp.wall_fade = xr.wall_prev != 0 && wallpaper_fade_seconds(comp) > 0 ? 1 : 0
	pm, pw, ph, depth, ok := root_background(comp)
	if !ok || depth != comp.c.depth { return }
	own := xlib.CreatePixmap(comp.dpy, comp.root, u32(xr.w), u32(xr.h), u32(comp.c.depth))
	xr.wall = XRenderCreatePicture(comp.dpy, own, xr.root_fmt, 0, nil)
	xlib.FreePixmap(comp.dpy, own)
	black := XRenderColor{alpha = 0xFFFF}
	XRenderFillRectangle(comp.dpy, PICT_OP_SRC, xr.wall, &black, 0, 0, u32(xr.w), u32(xr.h))
	src := XRenderCreatePicture(comp.dpy, pm, xr.root_fmt, 0, nil)
	XRenderComposite(comp.dpy, PICT_OP_SRC, src, 0, xr.wall, 0, 0, 0, 0, 0, 0, u32(min(pw, xr.w)), u32(min(ph, xr.h)))
	XRenderFreePicture(comp.dpy, src)
}

xr_paint :: proc(comp: ^Comp, now: f64) {
	xr := comp.xr
	dpy := comp.dpy
	if comp.root_changed {
		update_wallpaper(comp)
		comp.damage_all = true
	}
	if comp.damage_all {
		full := Rect{0, 0, xr.w, xr.h}
		reg := region_rect(dpy, full)
		XFixesCopyRegion(dpy, comp.damage, reg)
		XFixesDestroyRegion(dpy, reg)
	}
	draws, first := build_draws(comp)
	set_clip(comp, comp.damage)

	black := XRenderColor{alpha = 0xFFFF}
	XRenderFillRectangle(dpy, PICT_OP_SRC, xr.back, &black, 0, 0, u32(xr.w), u32(xr.h))
	if first == 0 {
		if xr.wall != 0 { XRenderComposite(dpy, PICT_OP_SRC, xr.wall, 0, xr.back, 0, 0, 0, 0, 0, 0, u32(xr.w), u32(xr.h)) }
		if comp.wall_fade > 0 && xr.wall_prev != 0 {
			mask := solid(comp, {0, 0, 0, 255}, f32(ease(comp.wall_fade)))
			XRenderComposite(dpy, PICT_OP_OVER, xr.wall_prev, mask, xr.back, 0, 0, 0, 0, 0, 0, u32(xr.w), u32(xr.h))
			XRenderFreePicture(dpy, mask)
		}
	}
	color := tx.color_from_hex(comp.cfg.shadows.color)
	for i in first ..< len(draws) {
		d := &draws[i]
		w := d.w
		if d.blur && !xr.warned_blur {
			log.info("XRender: blur needs the GLX renderer; windows are drawn without it")
			xr.warned_blur = true
		}
		if w.xr.pic == 0 {
			fmt := XRenderFindVisualFormat(dpy, w.visual)
			if fmt == nil { continue }
			pa: XRenderPictureAttributes
			pa.subwindow_mode = INCLUDE_INFERIORS
			w.xr.pic = XRenderCreatePicture(dpy, w.pixmap, fmt, CP_SUBWINDOW_MODE, &pa)
		}
		dx, dy := i32(math.round(d.dx)), i32(math.round(d.dy))
		if d.shadow && comp.cfg.shadows.radius > 0 { draw_shadow(comp, d, dx, dy, color) }
		shape_clip: XserverRegion
		if w.shaped && len(w.shape_rects) > 0 {
			rects := make([]Rect, len(w.shape_rects), context.temp_allocator)
			for r, j in w.shape_rects { rects[j] = {r.x + d.rect.x + dx, r.y + d.rect.y + dy, r.w, r.h} }
			shape_clip = clip_with(comp, region_from_rects(dpy, rects))
		}
		draw_pieces(comp, d, dx, dy, 0, d.alpha)
		if d.dim > 0 {
			shade := solid(comp, {0, 0, 0, 255}, 1)
			draw_pieces(comp, d, dx, dy, shade, d.alpha * d.dim)
			XRenderFreePicture(dpy, shade)
		}
		if shape_clip != 0 {
			XFixesDestroyRegion(dpy, shape_clip)
			set_clip(comp, comp.damage)
		}
	}

	XFixesSetPictureClipRegion(dpy, xr.target, 0, 0, comp.damage)
	XRenderComposite(dpy, PICT_OP_SRC, xr.back, 0, xr.target, 0, 0, 0, 0, 0, 0, u32(xr.w), u32(xr.h))
	XFixesSetPictureClipRegion(dpy, xr.target, 0, 0, 0)
	xlib.Flush(dpy)
}
