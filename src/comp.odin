// The compositor: takes the _NET_WM_CM_Sn selection, redirects every
// top-level window off-screen (Composite, manual mode), follows the windows
// through the X events and repaints the screen into the overlay window with
// the backend (GLX, or XRender as a fallback) when something changed.
package lactase

import "core:fmt"
import "core:log"
import "core:os"
import "core:time"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

Backend_Kind :: enum { None, GLX, XRender }

Comp :: struct {
	c:            ^tx.Connection,
	dpy:          ^xlib.Display,
	root:         xlib.Window,
	screen:       Rect,
	monitors:     [dynamic]Rect,
	refresh:      f64, // Hz
	overlay:      xlib.Window,
	owner:        xlib.Window, // owns _NET_WM_CM_Sn; receives lactase's control messages
	cm_atom:      xlib.Atom,
	control_atom: xlib.Atom,
	damage_event: i32,
	shape_event:  i32,
	has_shape:    bool,

	wins:         [dynamic]^Win, // stacking order, bottom first
	by_id:        map[xlib.Window]^Win,
	active:       xlib.Window, // _NET_ACTIVE_WINDOW

	cfg:          ^Config,
	cfg_path:     string,
	cfg_mtime:    time.Time,
	milk_path:    string,
	milk_mtime:   time.Time,
	milk:         Milk_Values,
	corner_radius: i32, // corners.radius, or milk's wm.cornerRadius
	anim_scale:   f64,  // 1, or milk's appearance.animationScale

	backend:      Backend_Kind,
	gl:           ^GL,
	xr:           ^XR,

	redirected:   bool,
	dirty:        bool,          // something must be repainted
	paint_again:  bool,          // the renderer wants one more frame
	damage:       XserverRegion, // what (for the xrender backend)
	damage_all:   bool,

	root_pixmap:  xlib.Pixmap, // _XROOTPMAP_ID
	root_changed: bool,
	wall_fade:    f64, // 1 → 0 while the previous wallpaper fades out

	unredir_since: f64, // a full-screen opaque window has been on top since then (0 = not)
	last_frame:   f64,
	quit:         bool,
	reload:       bool,
}

CONTROL_QUIT   :: 1
CONTROL_RELOAD :: 2

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
check_extensions :: proc(comp: ^Comp) -> bool {
	ev, er, major, minor: i32
	if !XCompositeQueryExtension(comp.dpy, &ev, &er) {
		log.error("The X server has no Composite extension")
		return false
	}
	XCompositeQueryVersion(comp.dpy, &major, &minor)
	if major == 0 && minor < 3 {
		log.errorf("Composite %d.%d is too old (0.3 needed for the overlay window)", major, minor)
		return false
	}
	if !XDamageQueryExtension(comp.dpy, &comp.damage_event, &er) {
		log.error("The X server has no Damage extension")
		return false
	}
	if !XFixesQueryExtension(comp.dpy, &ev, &er) {
		log.error("The X server has no XFixes extension")
		return false
	}
	XFixesQueryVersion(comp.dpy, &major, &minor)
	if !XRenderQueryExtension(comp.dpy, &ev, &er) {
		log.error("The X server has no Render extension")
		return false
	}
	comp.has_shape = bool(XShapeQueryExtension(comp.dpy, &comp.shape_event, &er))
	return true
}

// The window that owns the compositor selection (never mapped).
create_owner_window :: proc(comp: ^Comp) -> xlib.Window {
	attrs: xlib.XSetWindowAttributes
	attrs.override_redirect = true
	attrs.event_mask = {.PropertyChange, .StructureNotify}
	win := xlib.CreateWindow(comp.dpy, comp.root, -100, -100, 1, 1, 0, 0, .InputOnly, nil,
	                         {.CWOverrideRedirect, .CWEventMask}, &attrs)
	hint := xlib.XClassHint{res_name = "lactase", res_class = "Lactase"}
	xlib.SetClassHint(comp.dpy, win, &hint)
	xlib.StoreName(comp.dpy, win, "lactase")
	tx.set_utf8_string(comp.c, win, "_NET_WM_NAME", "lactase")
	tx.set_cardinals(comp.c, win, "_NET_WM_PID", {uint(os.get_pid())})
	return win
}

// A server timestamp (for the selection), from a property change on `win`.
server_time :: proc(comp: ^Comp, win: xlib.Window) -> xlib.Time {
	a := tx.atom(comp.c, "_LACTASE_TIMESTAMP")
	xlib.ChangeProperty(comp.dpy, win, a, tx.ATOM_CARDINAL, 32, xlib.PropModeAppend, nil, 0)
	ev: xlib.XEvent
	for _ in 0 ..< 200 {
		if xlib.CheckTypedWindowEvent(comp.dpy, win, .PropertyNotify, &ev) && ev.xproperty.atom == a {
			return ev.xproperty.time
		}
		xlib.Sync(comp.dpy, false)
		time.sleep(5 * time.Millisecond)
	}
	return xlib.CurrentTime
}

// Take _NET_WM_CM_Sn, waiting for a previous owner (another lactase being
// replaced) to go away first.
acquire_selection :: proc(comp: ^Comp) -> bool {
	previous := xlib.GetSelectionOwner(comp.dpy, comp.cm_atom)
	if previous != 0 { xlib.SelectInput(comp.dpy, previous, {.StructureNotify}) }
	stamp := server_time(comp, comp.owner)
	xlib.SetSelectionOwner(comp.dpy, comp.cm_atom, comp.owner, stamp)
	if xlib.GetSelectionOwner(comp.dpy, comp.cm_atom) != comp.owner {
		log.error("Could not take the compositor selection")
		return false
	}
	if previous != 0 {
		log.info("Waiting for the previous compositor to stop")
		ev: xlib.XEvent
		gone := false
		for _ in 0 ..< 300 {
			if xlib.CheckTypedWindowEvent(comp.dpy, previous, .DestroyNotify, &ev) { gone = true; break }
			xlib.Sync(comp.dpy, false)
			time.sleep(10 * time.Millisecond)
		}
		if !gone { log.warn("The previous compositor did not stop in time; continuing") }
	}
	return true
}

comp_create :: proc(c: ^tx.Connection, cfg: ^Config, cfg_path: string, preferred: Backend_Kind) -> (comp: ^Comp, ok: bool) {
	comp = new(Comp)
	comp.c = c
	comp.dpy = c.dpy
	comp.root = c.root
	comp.cfg = cfg
	comp.cfg_path = cfg_path
	comp.cfg_mtime = mtime(cfg_path)
	comp.milk_path = find_milk_config()
	comp.milk_mtime = mtime(comp.milk_path)
	comp.by_id = make(map[xlib.Window]^Win)
	if !check_extensions(comp) {
		free(comp)
		return nil, false
	}
	comp.cm_atom = tx.atom(c, fmt_cm_atom(c.screen))
	comp.control_atom = tx.atom(c, "_LACTASE_CONTROL")
	comp.owner = create_owner_window(comp)
	if !acquire_selection(comp) {
		xlib.DestroyWindow(comp.dpy, comp.owner)
		free(comp)
		return nil, false
	}
	update_screen(comp)
	apply_milk_values(comp)

	xlib.GrabServer(comp.dpy)
	XCompositeRedirectSubwindows(comp.dpy, comp.root, COMPOSITE_REDIRECT_MANUAL)
	comp.redirected = true
	xlib.SelectInput(comp.dpy, comp.root, {.SubstructureNotify, .Exposure, .StructureNotify, .PropertyChange})
	for child in tx.root_children(c) { add_win(comp, child, comp.wins[len(comp.wins) - 1].id if len(comp.wins) > 0 else 0) }
	xlib.UngrabServer(comp.dpy)

	comp.overlay = XCompositeGetOverlayWindow(comp.dpy, comp.root)
	// Clicks go through the overlay to the windows below.
	empty := XFixesCreateRegion(comp.dpy, nil, 0)
	XFixesSetWindowShapeRegion(comp.dpy, comp.overlay, SHAPE_INPUT, 0, 0, empty)
	XFixesDestroyRegion(comp.dpy, empty)
	xlib.SelectInput(comp.dpy, comp.overlay, {.Exposure})
	comp.damage = XFixesCreateRegion(comp.dpy, nil, 0)

	if active, found := tx.get_window(c, comp.root, "_NET_ACTIVE_WINDOW"); found { comp.active = active }
	comp.root_changed = true
	if !backend_init(comp, preferred) {
		comp_destroy(comp)
		return nil, false
	}
	for w in comp.wins { w.opacity = target_opacity(comp, w) }
	damage_everything(comp)
	return comp, true
}

@(private="file")
fmt_cm_atom :: proc(screen: i32) -> string { return fmt.tprintf("_NET_WM_CM_S%d", screen) }

comp_destroy :: proc(comp: ^Comp) {
	if comp == nil { return }
	for len(comp.wins) > 0 { free_win(comp, comp.wins[len(comp.wins) - 1]) }
	backend_shutdown(comp)
	if comp.damage != 0 { XFixesDestroyRegion(comp.dpy, comp.damage) }
	if comp.overlay != 0 { XCompositeReleaseOverlayWindow(comp.dpy, comp.overlay) }
	if comp.redirected { XCompositeUnredirectSubwindows(comp.dpy, comp.root, COMPOSITE_REDIRECT_MANUAL) }
	if comp.owner != 0 {
		if xlib.GetSelectionOwner(comp.dpy, comp.cm_atom) == comp.owner {
			xlib.SetSelectionOwner(comp.dpy, comp.cm_atom, 0, xlib.CurrentTime)
		}
		xlib.DestroyWindow(comp.dpy, comp.owner)
	}
	xlib.Sync(comp.dpy, false)
	delete(comp.wins)
	delete(comp.by_id)
	delete(comp.monitors)
	delete(comp.milk_path)
	free(comp)
}

// Screen size, monitors and refresh rate.
update_screen :: proc(comp: ^Comp) {
	comp.screen = tx.screen_rect(comp.c)
	clear(&comp.monitors)
	for m in tx.monitors(comp.c) { append(&comp.monitors, m.rect) }
	comp.refresh = 60
	if res := xlib.XRRGetScreenResources(comp.dpy, comp.root); res != nil {
		defer xlib.XRRFreeScreenResources(res)
		best := 0.0
		for i in 0 ..< int(res.ncrtc) {
			crtc := xlib.XRRGetCrtcInfo(comp.dpy, res, res.crtcs[i])
			if crtc == nil { continue }
			mode := crtc.mode
			xlib.XRRFreeCrtcInfo(crtc)
			if mode == 0 { continue }
			for j in 0 ..< int(res.nmode) {
				mi := res.modes[j]
				if mi.id != mode || mi.hTotal == 0 || mi.vTotal == 0 { continue }
				rate := f64(mi.dotClock) / (f64(mi.hTotal) * f64(mi.vTotal))
				if rate > best { best = rate }
			}
		}
		if best >= 20 && best <= 500 { comp.refresh = best }
	}
}

mtime :: proc(path: string) -> time.Time {
	if path == "" { return {} }
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil { return {} }
	return fi.modification_time
}

// Corner radius and animation speed: lactase.json, or milk.json when followMilk is on.
apply_milk_values :: proc(comp: ^Comp) {
	comp.corner_radius = i32(comp.cfg.corners.radius)
	comp.anim_scale = 1
	if comp.cfg.follow_milk {
		comp.milk = read_milk_values(comp.milk_path)
		if comp.milk.found {
			comp.corner_radius = i32(comp.milk.corner_radius)
			comp.anim_scale = clamp(comp.milk.animation_scale, 0, 3)
		}
	}
}

// A new configuration (lactase.json or milk.json changed): re-evaluate every
// window; a different backend or vsync setting restarts the renderer.
apply_config :: proc(comp: ^Comp, cfg: ^Config) {
	old := comp.cfg
	comp.cfg = cfg
	apply_milk_values(comp)
	for w in comp.wins {
		if !w.input_only && !w.destroyed { eval_effects(comp, w) }
	}
	if old != cfg {
		restart := old.backend != cfg.backend || old.vsync != cfg.vsync
		if restart {
			backend_shutdown_windows(comp)
			backend_shutdown(comp)
			if !backend_init(comp, backend_kind(cfg.backend)) { log.error("No renderer could start") }
		} else {
			backend_config_changed(comp)
		}
		destroy(old)
	}
	damage_everything(comp)
}

backend_kind :: proc(name: string) -> Backend_Kind {
	return name == "xrender" ? .XRender : .GLX
}

// ---------------------------------------------------------------------------
// Damage
// ---------------------------------------------------------------------------
damage_everything :: proc(comp: ^Comp) {
	comp.damage_all = true
	comp.dirty = true
}

damage_rect :: proc(comp: ^Comp, r: Rect) {
	if r.w <= 0 || r.h <= 0 { return }
	comp.dirty = true
	if comp.damage_all || comp.backend != .XRender { return }
	reg := region_rect(comp.dpy, r)
	XFixesUnionRegion(comp.dpy, comp.damage, comp.damage, reg)
	XFixesDestroyRegion(comp.dpy, reg)
}

SLIDE_DISTANCE :: 26

// Everything a window can paint: itself, its shadow, and animation slack.
win_extents :: proc(comp: ^Comp, w: ^Win) -> Rect {
	r := draw_rect(w)
	if w.eff.shadow {
		s := comp.cfg.shadows
		e := i32(s.radius) * 3 / 2 + 2
		sr := Rect{r.x - e + i32(s.offset_x), r.y - e + i32(s.offset_y), r.w + 2 * e, r.h + 2 * e}
		r = rect_union(r, sr)
	}
	if w.vis < 1 && w.vis_style == .Slide { r.h += SLIDE_DISTANCE }
	return r
}

damage_win :: proc(comp: ^Comp, w: ^Win) {
	damage_rect(comp, win_extents(comp, w))
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
handle_event :: proc(comp: ^Comp, ev: ^xlib.XEvent) {
	#partial switch ev.type {
	case .CreateNotify:
		e := ev.xcreatewindow
		if e.parent != comp.root { return }
		top := xlib.Window(0)
		if len(comp.wins) > 0 { top = comp.wins[len(comp.wins) - 1].id }
		add_win(comp, e.window, top)
	case .DestroyNotify:
		if w := find_win(comp, ev.xdestroywindow.window); w != nil { forget_win(comp, w, true) }
	case .MapNotify:
		w := find_win(comp, ev.xmap.window)
		if w == nil || w.input_only { return }
		w.mapped = true
		w.override = bool(ev.xmap.override_redirect)
		if w.pixmap != 0 { release_pixmap(comp, w) } // contents from before the unmap are stale
		read_props(comp, w)
		w.shape_dirty = true
		w.opacity = target_opacity(comp, w)
		w.dim = target_dim(comp, w)
		w.offscreen = !rect_intersects(outer_rect(w), comp.screen)
		if !w.offscreen { start_show(comp, w, false) }
	case .UnmapNotify:
		w := find_win(comp, ev.xunmap.window)
		if w == nil || w.input_only || ev.xunmap.event != comp.root { return }
		w.mapped = false
		if w.vis > 0 { start_hide(comp, w, false) }
		if w.vis == 0 { release_pixmap(comp, w) }
	case .ReparentNotify:
		e := ev.xreparent
		if e.parent == comp.root {
			top := xlib.Window(0)
			if len(comp.wins) > 0 { top = comp.wins[len(comp.wins) - 1].id }
			add_win(comp, e.window, top)
		} else if w := find_win(comp, e.window); w != nil {
			// Taken into a frame by a reparenting window manager.
			forget_win(comp, w, false)
		}
	case .ConfigureNotify:
		e := ev.xconfigure
		if e.window == comp.root {
			update_screen(comp)
			backend_resize(comp)
			damage_everything(comp)
			return
		}
		if w := find_win(comp, e.window); w != nil { configure_win(comp, w, e) }
	case .CirculateNotify:
		w := find_win(comp, ev.xcirculate.window)
		if w == nil { return }
		i := win_index(comp, w)
		if i >= 0 { ordered_remove(&comp.wins, i) }
		if ev.xcirculate.place == .PlaceOnTop { append(&comp.wins, w) } else { inject_at(&comp.wins, 0, w) }
		damage_win(comp, w)
	case .PropertyNotify:
		property_changed(comp, ev.xproperty)
	case .Expose:
		if ev.xexpose.window == comp.overlay || ev.xexpose.window == comp.root {
			e := ev.xexpose
			damage_rect(comp, {e.x, e.y, e.width, e.height})
		}
	case .SelectionClear:
		if ev.xselectionclear.selection == comp.cm_atom {
			log.info("Another compositor took over; stopping")
			comp.quit = true
		}
	case .ClientMessage:
		e := ev.xclient
		if e.window == comp.owner && e.message_type == comp.control_atom {
			switch e.data.l[0] {
			case CONTROL_QUIT:   comp.quit = true
			case CONTROL_RELOAD: comp.reload = true
			}
		}
	case:
		t := i32(ev.type)
		if t == comp.damage_event + DAMAGE_NOTIFY {
			de := (^XDamageNotifyEvent)(ev)
			damage_notify(comp, de)
		} else if comp.has_shape && t == comp.shape_event + SHAPE_NOTIFY {
			se := (^XShapeEvent)(ev)
			if w := find_win(comp, se.window); w != nil {
				damage_win(comp, w)
				w.shape_dirty = true
				damage_win(comp, w)
			}
		}
	}
}

@(private="file")
damage_notify :: proc(comp: ^Comp, de: ^XDamageNotifyEvent) {
	w := find_win(comp, de.drawable)
	if w == nil || w.damage != de.damage { return }
	w.damaged = true
	comp.dirty = true
	if comp.backend == .XRender && !comp.damage_all && w.vis == 1 && !w.ghosting {
		parts := XFixesCreateRegion(comp.dpy, nil, 0)
		XDamageSubtract(comp.dpy, w.damage, 0, parts)
		XFixesTranslateRegion(comp.dpy, parts, w.x + w.bw, w.y + w.bw)
		XFixesUnionRegion(comp.dpy, comp.damage, comp.damage, parts)
		XFixesDestroyRegion(comp.dpy, parts)
		// A blurred window above sees this change through its blur.
		return
	}
	XDamageSubtract(comp.dpy, w.damage, 0, 0)
	if w.vis < 1 || w.ghosting { damage_win(comp, w) } else { damage_rect(comp, outer_rect(w)) }
}

@(private="file")
configure_win :: proc(comp: ^Comp, w: ^Win, e: xlib.XConfigureEvent) {
	before := win_extents(comp, w)
	old := outer_rect(w)
	w.x, w.y, w.w, w.h, w.bw = e.x, e.y, e.width, e.height, e.border_width
	w.override = bool(e.override_redirect)
	now := outer_rect(w)
	if now.w != old.w || now.h != old.h {
		// The window pixmap has the old size: name a new one at the next frame.
		if w.mapped && !w.ghosting { release_pixmap(comp, w) }
		w.shape_dirty = true
	}
	// Restack right above `above`.
	i := win_index(comp, w)
	if i >= 0 {
		below := xlib.Window(0)
		if i > 0 { below = comp.wins[i - 1].id }
		if below != e.above { insert_above(comp, w, e.above) }
	}
	// milk's window manager hides the windows of other areas by moving them
	// off-screen: that is a hide (and coming back a show) with the last
	// on-screen place as the ghost.
	off := !rect_intersects(now, comp.screen)
	if w.mapped && off != w.offscreen {
		w.offscreen = off
		if off {
			if w.vis > 0 && w.pixmap != 0 {
				w.ghost = old
				w.ghosting = true
			}
			start_hide(comp, w, true)
			if w.vis == 0 { w.ghosting = false }
		} else {
			w.ghosting = false
			start_show(comp, w, true)
		}
	}
	damage_rect(comp, before)
	damage_win(comp, w)
}

@(private="file")
property_changed :: proc(comp: ^Comp, e: xlib.XPropertyEvent) {
	name := tx.atom_name(comp.c, e.atom)
	if e.window == comp.root {
		switch name {
		case "_NET_ACTIVE_WINDOW":
			active, _ := tx.get_window(comp.c, comp.root, "_NET_ACTIVE_WINDOW")
			if active != comp.active {
				comp.active = active
				comp.dirty = true
			}
		case "_XROOTPMAP_ID", "ESETROOT_PMAP_ID":
			comp.root_changed = true
			damage_everything(comp)
		}
		return
	}
	switch name {
	case "WM_CLASS", "WM_NAME", "_NET_WM_NAME", "_NET_WM_WINDOW_TYPE", "_NET_WM_STATE", "_NET_WM_WINDOW_OPACITY",
	     "_GTK_FRAME_EXTENTS", "WM_STATE", "WM_TRANSIENT_FOR":
		w := find_win(comp, e.window)
		if w == nil { w = find_client(comp, e.window) }
		if w != nil {
			w.props_dirty = true
			comp.dirty = true
		}
	}
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------
// Refresh what the events marked stale; true when a frame should be drawn.
prepare_frame :: proc(comp: ^Comp) {
	for w in comp.wins {
		if w.input_only || w.destroyed { continue }
		if w.props_dirty && (w.mapped || w.vis > 0) {
			before := win_extents(comp, w)
			read_props(comp, w)
			damage_rect(comp, before)
			damage_win(comp, w)
		}
		if w.shape_dirty && w.mapped { read_shape(comp, w) }
	}
}

// Unredirect while an opaque window covers the whole screen (games, video):
// it then draws straight to the screen with no compositor in between.
check_unredirect :: proc(comp: ^Comp, now: f64) {
	want := false
	if comp.cfg.unredirect_fullscreen {
		for i := len(comp.wins) - 1; i >= 0; i -= 1 {
			w := comp.wins[i]
			if w.input_only || !w.mapped || w.offscreen { continue }
			if w.vis < 1 || w.vis_target < 1 { break }
			want = rect_covers(outer_rect(w), comp.screen) && !w.argb && !w.shaped && w.opacity >= 1 && w.dim <= 0
			break
		}
	}
	if want {
		if comp.unredir_since == 0 { comp.unredir_since = now }
		if comp.redirected && now - comp.unredir_since >= 0.3 {
			log.debug("Unredirecting (full-screen window)")
			backend_shutdown_windows(comp)
			for w in comp.wins { if w.pixmap != 0 { xlib.FreePixmap(comp.dpy, w.pixmap); w.pixmap = 0 } }
			XCompositeUnredirectSubwindows(comp.dpy, comp.root, COMPOSITE_REDIRECT_MANUAL)
			xlib.UnmapWindow(comp.dpy, comp.overlay)
			comp.redirected = false
		}
		return
	}
	comp.unredir_since = 0
	if !comp.redirected {
		log.debug("Redirecting again")
		XCompositeRedirectSubwindows(comp.dpy, comp.root, COMPOSITE_REDIRECT_MANUAL)
		xlib.MapWindow(comp.dpy, comp.overlay)
		comp.redirected = true
		damage_everything(comp)
	}
}

// Draw a frame if something changed (and the renderer is up).
paint :: proc(comp: ^Comp, now: f64) {
	if !comp.redirected || comp.backend == .None { return }
	backend_paint(comp, now)
	comp.dirty = comp.paint_again
	comp.paint_again = false
	comp.damage_all = false
	XFixesSetRegion(comp.dpy, comp.damage, nil, 0)
	for w in comp.wins { w.damaged = false }
}
