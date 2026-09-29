// Windows: every child of the root window, in stacking order, with what the
// renderer needs (named pixmap, damage, shape) and what the rules need
// (class, title, type, EWMH state, opacity property).
//
// A window that disappears (unmap, destroy, or moved off-screen by milk's
// window manager when switching areas) keeps its last contents while its
// close animation plays; `vis` runs from 0 (hidden) to 1 (shown).
package lactase

import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

Win_Type :: enum {
	Unknown, Normal, Dialog, Utility, Toolbar, Splash, Menu, Dropdown_Menu, Popup_Menu,
	Tooltip, Notification, Combo, Dnd, Dock, Desktop,
}

@(rodata) WIN_TYPE_NAMES := [Win_Type]string{
	.Unknown = "unknown", .Normal = "normal", .Dialog = "dialog", .Utility = "utility", .Toolbar = "toolbar",
	.Splash = "splash", .Menu = "menu", .Dropdown_Menu = "dropdown_menu", .Popup_Menu = "popup_menu",
	.Tooltip = "tooltip", .Notification = "notification", .Combo = "combo", .Dnd = "dnd", .Dock = "dock",
	.Desktop = "desktop",
}

Anim_Style :: enum { None, Fade, Zoom, Slide }

// What the configuration and the rules decided for one window.
Effects :: struct {
	shadow:   bool,
	blur:     bool,
	corners:  i32,
	animate:  bool,
	dim:      bool,
	opacity:  Maybe(f64), // a rule or _NET_WM_WINDOW_OPACITY; nil = active/inactive opacity
}

Win :: struct {
	id:          xlib.Window,
	client:      xlib.Window, // the window carrying WM_STATE (== id without a reparenting WM)
	// Geometry as the server has it: x, y is the outer corner (border included).
	x, y, w, h:  i32,
	bw:          i32,
	depth:       i32,
	visual:      ^xlib.Visual,
	input_only:  bool,
	override:    bool,
	mapped:      bool,
	destroyed:   bool, // gone from the server; kept while it fades out
	argb:        bool, // the visual has an alpha channel
	damage:      Damage,
	damaged:     bool, // contents changed since the last frame

	pixmap:      xlib.Pixmap, // named with Composite; 0 = name it before painting
	pix_w, pix_h: i32,

	// Shape (SHAPE extension): shaped windows are drawn inside their rectangles only.
	shaped:      bool,
	shape_rects: [dynamic]Rect, // outer coordinates (0,0 = the border's corner)
	shape_radius: i32,          // the shape is a rounded rectangle of this radius (milk's windows)
	shape_dirty: bool,

	// Properties.
	props_dirty: bool,
	type:        Win_Type,
	class:       string,
	instance:    string,
	title:       string,
	net_opacity: Maybe(f64),
	fullscreen_state: bool,
	gtk_frame:   bool,
	eff:         Effects,

	// Animation.
	vis:          f64,        // 0 hidden .. 1 shown
	vis_target:   f64,
	vis_style:    Anim_Style, // how vis shows while it moves
	offscreen:    bool,       // moved off the screen (a hidden area)
	ghost:        Rect,       // where it is drawn while it disappears off-screen
	ghosting:     bool,
	opacity:      f64,        // animated towards the target opacity
	dim:          f64,

	// Renderer data.
	gl:          GL_Win,
	xr:          XR_Win,
}

outer_rect :: proc(w: ^Win) -> Rect { return {w.x, w.y, w.w + 2 * w.bw, w.h + 2 * w.bw} }

// Where the window is drawn: its real place, or the place it had when it
// started to disappear off-screen.
draw_rect :: proc(w: ^Win) -> Rect {
	if w.ghosting { return w.ghost }
	return outer_rect(w)
}

find_win :: proc(comp: ^Comp, id: xlib.Window) -> ^Win {
	if w, ok := comp.by_id[id]; ok { return w }
	return nil
}

// The window whose client (or itself) is `id`.
find_client :: proc(comp: ^Comp, id: xlib.Window) -> ^Win {
	if id == 0 { return nil }
	if w := find_win(comp, id); w != nil { return w }
	for w in comp.wins {
		if !w.destroyed && w.client == id { return w }
	}
	return nil
}

win_index :: proc(comp: ^Comp, w: ^Win) -> int {
	for it, i in comp.wins { if it == w { return i } }
	return -1
}

// ---------------------------------------------------------------------------
// Adding and removing
// ---------------------------------------------------------------------------
add_win :: proc(comp: ^Comp, id: xlib.Window, above: xlib.Window) -> ^Win {
	if id == comp.overlay || id == comp.owner { return nil }
	if existing := find_win(comp, id); existing != nil { return existing }
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(comp.dpy, id, &attrs) == 0 { return nil }
	w := new(Win)
	w.id = id
	w.x, w.y, w.w, w.h, w.bw = attrs.x, attrs.y, attrs.width, attrs.height, attrs.border_width
	w.depth = attrs.depth
	w.visual = attrs.visual
	w.input_only = attrs.class == .InputOnly
	w.override = bool(attrs.override_redirect)
	w.mapped = attrs.map_state == .IsViewable
	w.opacity = 1
	w.props_dirty = true
	w.shape_dirty = true
	if !w.input_only {
		if fmt := XRenderFindVisualFormat(comp.dpy, w.visual); fmt != nil {
			w.argb = fmt.type == 1 && fmt.direct.alpha_mask != 0 // PictTypeDirect
		}
		w.damage = XDamageCreate(comp.dpy, id, DAMAGE_REPORT_NON_EMPTY)
		xlib.SelectInput(comp.dpy, id, {.PropertyChange})
		if comp.has_shape { XShapeSelectInput(comp.dpy, id, SHAPE_NOTIFY_MASK) }
	}
	w.offscreen = !rect_intersects(outer_rect(w), comp.screen)
	if w.mapped && !w.offscreen {
		// Already on screen when lactase started: no animation.
		w.vis, w.vis_target = 1, 1
	}
	comp.by_id[id] = w
	insert_above(comp, w, above)
	return w
}

// Put w right above `above` (0 = at the bottom).
insert_above :: proc(comp: ^Comp, w: ^Win, above: xlib.Window) {
	if i := win_index(comp, w); i >= 0 { ordered_remove(&comp.wins, i) }
	if above == 0 {
		inject_at(&comp.wins, 0, w)
		return
	}
	for it, i in comp.wins {
		if it.id == above && !it.destroyed {
			inject_at(&comp.wins, i + 1, w)
			return
		}
	}
	append(&comp.wins, w)
}

// Stop tracking w now (it is freed; the renderer lets go of its resources).
free_win :: proc(comp: ^Comp, w: ^Win) {
	if i := win_index(comp, w); i >= 0 { ordered_remove(&comp.wins, i) }
	if !w.destroyed {
		if comp.by_id[w.id] == w { delete_key(&comp.by_id, w.id) }
		if w.damage != 0 { XDamageDestroy(comp.dpy, w.damage) }
		if comp.has_shape { XShapeSelectInput(comp.dpy, w.id, 0) }
	}
	release_pixmap(comp, w)
	delete(w.shape_rects)
	delete(w.class)
	delete(w.instance)
	delete(w.title)
	free(w)
}

// The window left the server (destroyed, or reparented into a frame).
forget_win :: proc(comp: ^Comp, w: ^Win, animate: bool) {
	if comp.by_id[w.id] == w { delete_key(&comp.by_id, w.id) }
	w.destroyed = true
	w.damage = 0 // destroyed with the window
	if animate && w.vis > 0 && w.pixmap != 0 {
		start_hide(comp, w, false)
		return
	}
	free_win(comp, w)
}

release_pixmap :: proc(comp: ^Comp, w: ^Win) {
	backend_release_window(comp, w)
	if w.pixmap != 0 {
		xlib.FreePixmap(comp.dpy, w.pixmap)
		w.pixmap = 0
	}
}

// Name the window's pixmap if it has none (only while it is viewable).
ensure_pixmap :: proc(comp: ^Comp, w: ^Win) -> bool {
	if w.pixmap != 0 { return true }
	if !w.mapped || w.destroyed || w.input_only { return false }
	w.pixmap = XCompositeNameWindowPixmap(comp.dpy, w.id)
	r := outer_rect(w)
	w.pix_w, w.pix_h = r.w, r.h
	w.damaged = true
	return w.pixmap != 0
}

// ---------------------------------------------------------------------------
// Properties and rules
// ---------------------------------------------------------------------------
@(private="file")
has_wm_state :: proc(comp: ^Comp, win: xlib.Window) -> bool {
	p, ok := tx.get_property(comp.c, win, "WM_STATE", xlib.Atom(0), 2)
	if ok { tx.property_free(p) }
	return ok
}

// The client window of a frame: the first descendant with WM_STATE.
@(private="file")
find_client_window :: proc(comp: ^Comp, win: xlib.Window, depth: int) -> xlib.Window {
	if has_wm_state(comp, win) { return win }
	if depth <= 0 { return 0 }
	root, parent: xlib.Window
	children: [^]xlib.Window
	n: u32
	if xlib.QueryTree(comp.dpy, win, &root, &parent, &children, &n) == xlib.Status(0) || children == nil { return 0 }
	defer xlib.Free(children)
	for i := int(n) - 1; i >= 0; i -= 1 {
		if found := find_client_window(comp, children[i], depth - 1); found != 0 { return found }
	}
	return 0
}

@(private="file")
read_opacity :: proc(comp: ^Comp, win: xlib.Window) -> Maybe(f64) {
	if v, ok := tx.get_cardinal(comp.c, win, "_NET_WM_WINDOW_OPACITY"); ok {
		return f64(v & 0xFFFFFFFF) / f64(0xFFFFFFFF)
	}
	return nil
}

@(private="file")
type_from_atoms :: proc(comp: ^Comp, atoms: []xlib.Atom) -> (Win_Type, bool) {
	for a in atoms {
		name := tx.atom_name(comp.c, a)
		if !strings.has_prefix(name, "_NET_WM_WINDOW_TYPE_") { continue }
		switch name[len("_NET_WM_WINDOW_TYPE_"):] {
		case "DESKTOP":       return .Desktop, true
		case "DOCK":          return .Dock, true
		case "TOOLBAR":       return .Toolbar, true
		case "MENU":          return .Menu, true
		case "UTILITY":       return .Utility, true
		case "SPLASH":        return .Splash, true
		case "DIALOG":        return .Dialog, true
		case "DROPDOWN_MENU": return .Dropdown_Menu, true
		case "POPUP_MENU":    return .Popup_Menu, true
		case "TOOLTIP":       return .Tooltip, true
		case "NOTIFICATION":  return .Notification, true
		case "COMBO":         return .Combo, true
		case "DND":           return .Dnd, true
		case "NORMAL":        return .Normal, true
		}
	}
	return .Unknown, false
}

// Re-read the properties the rules look at.
read_props :: proc(comp: ^Comp, w: ^Win) {
	w.props_dirty = false
	if w.destroyed { return }
	c := comp.c
	if w.override {
		w.client = w.id
	} else {
		client := find_client_window(comp, w.id, 3)
		if client != w.client && client != 0 && client != w.id {
			xlib.SelectInput(comp.dpy, client, {.PropertyChange})
		}
		w.client = client != 0 ? client : w.id
	}
	src := w.client

	delete(w.class)
	delete(w.instance)
	delete(w.title)
	instance, class := tx.window_class(c, src)
	w.instance = strings.clone(instance)
	w.class = strings.clone(class)
	w.title = strings.clone(tx.window_title(c, src))

	t, typed := type_from_atoms(comp, tx.get_atoms(c, src, "_NET_WM_WINDOW_TYPE"))
	if !typed && src != w.id { t, typed = type_from_atoms(comp, tx.get_atoms(c, w.id, "_NET_WM_WINDOW_TYPE")) }
	if !typed {
		t = .Unknown
		if !w.override {
			_, transient := tx.get_window(c, src, "WM_TRANSIENT_FOR")
			t = transient ? .Dialog : .Normal
		}
	}
	w.type = t

	states := tx.get_atoms(c, src, "_NET_WM_STATE")
	w.fullscreen_state = slice.contains(states, tx.atom(c, "_NET_WM_STATE_FULLSCREEN"))
	w.gtk_frame = len(tx.get_cardinals(c, src, "_GTK_FRAME_EXTENTS")) >= 4

	w.net_opacity = read_opacity(comp, w.id)
	if w.net_opacity == nil && src != w.id { w.net_opacity = read_opacity(comp, src) }
	eval_effects(comp, w)
}

// Shape: the rectangles of the bounding region, and whether they form a
// rounded rectangle (how milk rounds its windows without a compositor).
read_shape :: proc(comp: ^Comp, w: ^Win) {
	w.shape_dirty = false
	clear(&w.shape_rects)
	w.shaped = false
	w.shape_radius = 0
	if !comp.has_shape || w.destroyed { return }
	bshaped, cshaped: b32
	xb, yb, xc, yc: i32
	wb, hb, wc, hc: u32
	if XShapeQueryExtents(comp.dpy, w.id, &bshaped, &xb, &yb, &wb, &hb, &cshaped, &xc, &yc, &wc, &hc) == 0 || !bshaped { return }
	n, ordering: i32
	rects := XShapeGetRectangles(comp.dpy, w.id, SHAPE_BOUNDING, &n, &ordering)
	if rects == nil { return }
	defer xlib.Free(rects)
	outer := outer_rect(w)
	outer.x, outer.y = 0, 0
	for i in 0 ..< int(n) {
		// Shape rectangles are relative to the window's origin, inside the border.
		r := Rect{i32(rects[i].x) + w.bw, i32(rects[i].y) + w.bw, i32(rects[i].width), i32(rects[i].height)}
		if clipped, ok := tx.rect_intersect(r, outer); ok { append(&w.shape_rects, clipped) }
	}
	if len(w.shape_rects) == 1 && w.shape_rects[0] == outer { return } // a plain rectangle
	w.shaped = true
	w.shape_radius = rounded_radius(w.shape_rects[:], outer.w, outer.h)
	log.debugf("Window 0x%x: shaped, %d rectangles, rounded radius %d", w.id, len(w.shape_rects), w.shape_radius)
}

// The radius of the rounded rectangle these rectangles draw, or 0 when they
// are some other shape. Each row must hold one span, inset equally on both
// sides and symmetric top/bottom, following a circle of that radius.
@(private="file")
rounded_radius :: proc(rects: []Rect, w, h: i32) -> i32 {
	if w <= 0 || h <= 0 || h > 8192 { return 0 }
	left := make([]i32, h, context.temp_allocator)
	right := make([]i32, h, context.temp_allocator)
	for i in 0 ..< h { left[i] = -1 }
	for r in rects {
		for y in max(r.y, 0) ..< min(r.y + r.h, h) {
			if left[y] >= 0 { return 0 } // two spans on one row
			left[y] = r.x
			right[y] = w - (r.x + r.w)
		}
	}
	top := i32(0) // rows of the upper rounded band
	for y in 0 ..< h {
		if left[y] < 0 || abs(left[y] - right[y]) > 1 { return 0 }
		if abs(left[y] - left[h - 1 - y]) > 1 { return 0 }
		if y < h / 2 && left[y] > 0 { top = y + 1 }
	}
	if top == 0 || top * 2 > h { return 0 }
	// Best radius around the height of the rounded band.
	best, best_err := i32(0), i32(1 << 30)
	for r in max(top - 1, 1) ..= min(top + 3, min(w, h) / 2) {
		err := i32(0)
		for y in 0 ..< top {
			dy := f64(r) - (f64(y) + 0.5)
			inset := i32(0)
			if dy > 0 { inset = i32(math.ceil(f64(r) - math.sqrt(max(f64(r * r) - dy * dy, 0)) - 0.5)) }
			err = max(err, abs(inset - left[y]))
		}
		if err < best_err { best, best_err = r, err }
	}
	if best_err > 1 { return 0 }
	return best
}

@(private="file")
lower_eq :: proc(a, b: string) -> bool { return strings.equal_fold(a, b) }

@(private="file")
rule_matches :: proc(r: Rule, w: ^Win) -> bool {
	if r.type != "" && r.type != WIN_TYPE_NAMES[w.type] { return false }
	if r.class != "" && !lower_eq(r.class, w.class) { return false }
	if r.instance != "" && !lower_eq(r.instance, w.instance) { return false }
	if r.title != "" {
		lt := strings.to_lower(w.title, context.temp_allocator)
		lr := strings.to_lower(r.title, context.temp_allocator)
		if !strings.contains(lt, lr) { return false }
	}
	return true
}

// Apply the configuration, the built-in exceptions and the rules.
eval_effects :: proc(comp: ^Comp, w: ^Win) {
	cfg := comp.cfg
	e := Effects{
		shadow  = cfg.shadows.enabled && cfg.shadows.opacity > 0,
		blur    = cfg.blur.enabled,
		corners = comp.corner_radius,
		animate = cfg.animations.enabled,
		dim     = true,
	}
	// Client-side decorations draw their own shadow and corners.
	if w.gtk_frame {
		e.shadow = false
		e.corners = 0
		e.blur = false
	}
	for r in cfg.rules {
		if !rule_matches(r, w) { continue }
		if v, ok := r.opacity.?; ok { e.opacity = v }
		if v, ok := r.shadow.?; ok  { e.shadow = v && cfg.shadows.opacity > 0 }
		if v, ok := r.blur.?; ok    { e.blur = v }
		if v, ok := r.corners.?; ok { e.corners = i32(v) }
		if v, ok := r.animate.?; ok { e.animate = v }
		if v, ok := r.dim.?; ok     { e.dim = v }
	}
	if e.opacity == nil { e.opacity = w.net_opacity }
	w.eff = e
}

// Application windows fade with focus; panels, menus and popups do not.
focus_sensitive :: proc(w: ^Win) -> bool {
	if w.override { return false }
	#partial switch w.type {
	case .Normal, .Dialog, .Utility, .Toolbar, .Unknown: return true
	}
	return false
}

is_fullscreen :: proc(comp: ^Comp, w: ^Win) -> bool {
	if w.fullscreen_state { return true }
	r := outer_rect(w)
	for m in comp.monitors { if r == m { return true } }
	return r == comp.screen
}

target_opacity :: proc(comp: ^Comp, w: ^Win) -> f64 {
	if v, ok := w.eff.opacity.?; ok { return v }
	if !focus_sensitive(w) { return 1 }
	return is_focused(comp, w) ? comp.cfg.opacity.active : comp.cfg.opacity.inactive
}

target_dim :: proc(comp: ^Comp, w: ^Win) -> f64 {
	if !w.eff.dim || !focus_sensitive(w) || is_focused(comp, w) { return 0 }
	return comp.cfg.opacity.dim_inactive
}

is_focused :: proc(comp: ^Comp, w: ^Win) -> bool {
	return comp.active != 0 && (w.client == comp.active || w.id == comp.active)
}

// ---------------------------------------------------------------------------
// Showing and hiding
// ---------------------------------------------------------------------------
anim_style :: proc(name: string) -> Anim_Style {
	switch name {
	case "fade":  return .Fade
	case "zoom":  return .Zoom
	case "slide": return .Slide
	}
	return .None
}

// Map, or back on screen: grow vis towards 1.
start_show :: proc(comp: ^Comp, w: ^Win, from_area: bool) {
	w.vis_target = 1
	w.ghosting = false
	style := from_area ? Anim_Style.Fade : anim_style(comp.cfg.animations.open)
	if !w.eff.animate || !comp.cfg.animations.enabled || anim_seconds(comp, true) <= 0 || style == .None ||
	   (from_area && !comp.cfg.animations.workspaces) {
		w.vis = 1
	} else if w.vis >= 1 {
		w.vis = 0
	}
	if w.vis < 1 { w.vis_style = style }
	damage_win(comp, w)
}

// Unmap, destroy, or off-screen: shrink vis towards 0 with the last contents.
start_hide :: proc(comp: ^Comp, w: ^Win, from_area: bool) {
	w.vis_target = 0
	style := from_area ? Anim_Style.Fade : anim_style(comp.cfg.animations.close)
	if w.pixmap == 0 || !w.eff.animate || !comp.cfg.animations.enabled || anim_seconds(comp, false) <= 0 ||
	   style == .None || (from_area && !comp.cfg.animations.workspaces) {
		w.vis = 0
	} else {
		w.vis_style = style
	}
	damage_win(comp, w)
}

anim_seconds :: proc(comp: ^Comp, opening: bool) -> f64 {
	ms := opening ? comp.cfg.animations.open_duration : comp.cfg.animations.close_duration
	return f64(ms) / 1000 * comp.anim_scale
}

// Advance every animation to `now`. Returns true while something moves.
step_animations :: proc(comp: ^Comp, dt: f64) -> bool {
	moving := false
	fade_rate := 1.0 / max(0.12 * comp.anim_scale, 0.001)
	animate_focus := comp.cfg.animations.enabled && comp.anim_scale > 0
	i := 0
	for i < len(comp.wins) {
		w := comp.wins[i]
		i += 1
		if w.input_only { continue }
		if w.vis != w.vis_target {
			opening := w.vis_target > w.vis
			secs := anim_seconds(comp, opening)
			step := secs > 0 ? dt / secs : 1
			if opening { w.vis = min(w.vis + step, w.vis_target) } else { w.vis = max(w.vis - step, w.vis_target) }
			damage_win(comp, w)
			if w.vis == w.vis_target {
				if w.vis == 0 { hidden(comp, w); if w.destroyed { i -= 1; free_win(comp, w); continue } }
			} else {
				moving = true
			}
		}
		if !w.mapped && w.vis == 0 { continue }
		// Opacity and dimming follow focus changes smoothly.
		to := target_opacity(comp, w)
		dim_to := target_dim(comp, w)
		if w.opacity != to || w.dim != dim_to {
			if animate_focus {
				w.opacity = approach(w.opacity, to, dt * fade_rate)
				w.dim = approach(w.dim, dim_to, dt * fade_rate)
			} else {
				w.opacity, w.dim = to, dim_to
			}
			damage_win(comp, w)
			if w.opacity != to || w.dim != dim_to { moving = true }
		}
	}
	return moving
}

@(private="file")
approach :: proc(v, to, step: f64) -> f64 {
	if v < to { return min(v + step, to) }
	return max(v - step, to)
}

// The disappearing animation finished.
@(private="file")
hidden :: proc(comp: ^Comp, w: ^Win) {
	w.ghosting = false
	if !w.mapped && !w.destroyed { release_pixmap(comp, w) }
}

// Ease-out cubic.
ease :: proc(t: f64) -> f64 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}
