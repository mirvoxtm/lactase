// What a frame shows: the windows that are visible (or still animating out),
// bottom first, with their animated geometry, opacity, corners, shadow and
// blur decided. Both renderers draw from this list.
package lactase

import "core:log"
import "core:math"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

ZOOM_FROM :: 0.88

Draw :: struct {
	w:         ^Win,
	rect:      Rect, // outer rectangle on screen, before the animation transform
	scale:     f32,  // around the rectangle's centre
	dx, dy:    f32,
	alpha:     f32,  // opacity × visibility
	vis:       f32,  // visibility alone (the blur behind fades with it)
	dim:       f32,
	radius:    f32,
	shadow:    bool,
	blur:      bool,
	fullscreen: bool,
}

// Screen position of a point given in window-local pixels.
draw_point :: proc(d: ^Draw, lx, ly: f32) -> [2]f32 {
	cx := f32(d.rect.x) + f32(d.rect.w) / 2
	cy := f32(d.rect.y) + f32(d.rect.h) / 2
	return {cx + (f32(d.rect.x) + lx - cx) * d.scale + d.dx, cy + (f32(d.rect.y) + ly - cy) * d.scale + d.dy}
}

// The transformed rectangle as x0, y0, x1, y1.
draw_box :: proc(d: ^Draw) -> [4]f32 {
	a := draw_point(d, 0, 0)
	b := draw_point(d, f32(d.rect.w), f32(d.rect.h))
	return {a.x, a.y, b.x, b.y}
}

draw_bounds :: proc(d: ^Draw) -> Rect {
	b := draw_box(d)
	x0 := i32(math.floor(b[0]))
	y0 := i32(math.floor(b[1]))
	return {x0, y0, i32(math.ceil(b[2])) - x0, i32(math.ceil(b[3])) - y0}
}

shadow_sigma :: proc(comp: ^Comp) -> f32 { return max(f32(comp.cfg.shadows.radius) / 2, 0.5) }

// Build the list; `first` is the lowest entry worth drawing (an opaque window
// covering the whole screen hides everything under it, wallpaper included).
build_draws :: proc(comp: ^Comp) -> (draws: []Draw, first: int) {
	list := make([dynamic]Draw, context.temp_allocator)
	for w in comp.wins {
		if w.input_only || w.vis <= 0 { continue }
		if !w.mapped && w.pixmap == 0 { continue }
		if w.mapped && w.offscreen && !w.ghosting { continue }
		if !ensure_pixmap(comp, w) { continue }
		r := draw_rect(w)
		if !rect_intersects(r, comp.screen) { continue }
		d := Draw{w = w, rect = r, scale = 1}
		t := ease(w.vis)
		switch w.vis_style {
		case .Zoom:  d.scale = f32(ZOOM_FROM + (1 - ZOOM_FROM) * t)
		case .Slide: d.dy = f32((1 - t) * SLIDE_DISTANCE)
		case .Fade, .None:
		}
		if w.vis >= 1 { d.scale, d.dy = 1, 0 }
		d.vis = f32(w.vis)
		d.alpha = f32(w.opacity) * d.vis
		d.dim = f32(w.dim)
		d.fullscreen = is_fullscreen(comp, w)
		// Corners: the rule's radius, or the radius of a rounded shape (milk
		// rounds its windows with SHAPE), whichever is larger.
		radius := w.eff.corners
		if w.shaped { radius = w.shape_radius > 0 ? max(radius, w.shape_radius) : 0 }
		if d.fullscreen && !w.shaped { radius = 0 }
		d.radius = f32(radius)
		d.shadow = w.eff.shadow && !d.fullscreen && !(w.shaped && w.shape_radius == 0)
		d.blur = w.eff.blur && (w.argb || d.alpha < 0.999) && w.type != .Desktop
		if d.alpha <= 0.002 { continue }
		append(&list, d)
	}
	draws = list[:]
	for i := len(draws) - 1; i >= 0; i -= 1 {
		d := &draws[i]
		if d.alpha >= 1 && !d.w.argb && !d.w.shaped && d.radius == 0 && d.scale == 1 && d.dy == 0 &&
		   rect_covers(d.rect, comp.screen) {
			first = i
			break
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Renderer dispatch
// ---------------------------------------------------------------------------
backend_init :: proc(comp: ^Comp, preferred: Backend_Kind) -> bool {
	comp.backend = .None
	if preferred == .GLX {
		if gl_init(comp) {
			comp.backend = .GLX
			return true
		}
		log.warn("The GLX renderer could not start; using XRender")
	}
	if xr_init(comp) {
		comp.backend = .XRender
		return true
	}
	return false
}

backend_shutdown :: proc(comp: ^Comp) {
	switch comp.backend {
	case .GLX:     gl_shutdown(comp)
	case .XRender: xr_shutdown(comp)
	case .None:
	}
	comp.backend = .None
}

// Let go of every window's renderer resources (their pixmaps stay).
backend_shutdown_windows :: proc(comp: ^Comp) {
	for w in comp.wins { backend_release_window(comp, w) }
}

backend_release_window :: proc(comp: ^Comp, w: ^Win) {
	switch comp.backend {
	case .GLX:     gl_release_window(comp, w)
	case .XRender: xr_release_window(comp, w)
	case .None:
	}
}

backend_resize :: proc(comp: ^Comp) {
	switch comp.backend {
	case .GLX:     gl_resize(comp)
	case .XRender: xr_resize(comp)
	case .None:
	}
}

backend_config_changed :: proc(comp: ^Comp) {
	switch comp.backend {
	case .GLX:
	case .XRender: xr_config_changed(comp)
	case .None:
	}
}

backend_paint :: proc(comp: ^Comp, now: f64) {
	switch comp.backend {
	case .GLX:     gl_paint(comp, now)
	case .XRender: xr_paint(comp, now)
	case .None:
	}
}

// The wallpaper published by feh (or any other setter): _XROOTPMAP_ID.
root_background :: proc(comp: ^Comp) -> (pm: xlib.Pixmap, w, h, depth: i32, ok: bool) {
	for name in ([]string{"_XROOTPMAP_ID", "ESETROOT_PMAP_ID"}) {
		longs, found := tx.get_pixmap_id(comp.c, comp.root, name)
		if !found { continue }
		root: xlib.Window
		x, y: i32
		pw, ph, border, d: u32
		if xlib.GetGeometry(comp.dpy, xlib.Drawable(longs), &root, &x, &y, &pw, &ph, &border, &d) == xlib.Status(0) { continue }
		if pw == 0 || ph == 0 { continue }
		return longs, i32(pw), i32(ph), i32(d), true
	}
	return 0, 0, 0, 0, false
}

// Seconds the previous wallpaper takes to fade out after an area switch.
wallpaper_fade_seconds :: proc(comp: ^Comp) -> f64 {
	if !comp.cfg.animations.enabled || !comp.cfg.animations.workspaces { return 0 }
	return 0.28 * comp.anim_scale
}
