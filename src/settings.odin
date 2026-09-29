// The settings app ("Configurações do lactase"): a normal window in milk's
// look with a sidebar of sections. Every change is written to lactase.json
// shortly after it is made and the running lactase is asked to reload, so
// the desktop itself is the preview. milk's settings open this app too.
package lactase

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"
import config "milk:config"
import tx "milk:tx"

Section :: enum { General, Shadows, Animations, Opacity, Blur, Corners, Rules, About }

Action :: enum {
	None, Section, Step, Toggle, Choice, Start_Stop, Open_Json, Reset, Rule_Edit, Rule_Delete, Rule_New,
	Rule_Save, Rule_Cancel, Rule_Pick, Rule_Field,
}

Control :: enum {
	None,
	Backend, Vsync, Follow_Milk, Unredirect,
	Shadow_On, Shadow_Radius, Shadow_Opacity, Shadow_X, Shadow_Y,
	Anim_On, Anim_Open, Anim_Close, Anim_Open_Ms, Anim_Close_Ms, Anim_Areas,
	Op_Active, Op_Inactive, Op_Dim,
	Blur_On, Blur_Strength,
	Corners,
	Ed_Match, Ed_Type, Ed_Opacity, Ed_Shadow, Ed_Blur, Ed_Corners, Ed_Animate,
}

// The rule being added or changed. Tri-states: 0 = leave as is, 1 = on, 2 = off.
Rule_Editor :: struct {
	open:    bool,
	index:   int, // -1 = a new rule
	match:   int, // 0 class, 1 title, 2 type
	text:    [dynamic]u8,
	type:    int, // WINDOW_TYPES index
	opacity: int, // 0 = leave as is, else percent
	shadow:  int,
	blur:    int,
	animate: int,
	corners: int, // -1 = leave as is
	focused: bool,
}

App :: struct {
	c:           ^tx.Connection,
	win:         xlib.Window,
	pixmap:      xlib.Pixmap,
	input:       tx.Input,
	cursor:      xlib.Cursor,
	w, h:        i32,
	theme:       Theme,
	fonts:       Fonts,
	pt:          bool,
	milk_cfg:    ^config.Config,
	milk_path:   string,
	milk:        Milk_Values,

	cfg:         ^Config,
	rules:       [dynamic]Rule, // the rules being edited (own strings)
	cfg_path:    string,
	section:     Section,
	editor:      Rule_Editor,
	rules_scroll: int,
	picking:     bool,

	instance:    Instance,
	running:     bool,
	status_at:   f64,

	texts:       [dynamic]Text_Item,
	hits:        [dynamic]Hit,
	hover:       Hit,
	pointer:     [2]i32,
	dirty:       bool,
	quit:        bool,
	save_at:     f64,
	notice:      string,
	notice_until: f64,
	preview:     tx.Canvas,
	preview_key: [12]f32,
}

tr :: proc(a: ^App, pt, en: string) -> string { return a.pt ? pt : en }

// Open the settings window and block until it is closed.
settings_run :: proc(c: ^tx.Connection, config_path: string) {
	a := new(App)
	defer free(a)
	a.c = c
	a.cfg_path = config_path
	cfg, err := load(config_path)
	if err != "" {
		log.errorf("Settings: %s; starting from the defaults", err)
		cfg = default_config_owned()
	}
	a.cfg = cfg
	for r in cfg.rules { append(&a.rules, clone_rule(r)) }

	a.milk_path = find_milk_config()
	if a.milk_path != "" {
		if mc, merr := config.load(a.milk_path); merr == "" { a.milk_cfg = mc } else { delete(merr) }
	}
	a.milk = read_milk_values(a.milk_path)
	bar := a.milk_cfg != nil ? a.milk_cfg.bar : config.default_bar()
	a.theme = make_theme(bar.theme)
	a.pt = strings.has_prefix(bar.locale, "pt")

	if !open_window(a) { return }
	fonts, fok := open_fonts(c, bar.font, bar.icon_font_file)
	if !fok {
		log.error("Settings: no usable font")
		return
	}
	a.fonts = fonts
	refresh_status(a)
	a.dirty = true
	loop_settings(a)
	if a.save_at > 0 { save_now(a) }

	close_fonts(c, &a.fonts)
	tx.input_close(&a.input)
	tx.pixmap_free(c, a.pixmap)
	xlib.DestroyWindow(c.dpy, a.win)
	tx.flush(c)
	tx.canvas_destroy(&a.preview)
	for &r in a.rules { free_rule(&r) }
	delete(a.rules)
	delete(a.editor.text)
	delete(a.hits)
	destroy(a.cfg)
	if a.milk_cfg != nil { config.destroy(a.milk_cfg) }
	delete(a.milk_path)
	delete(a.instance.backend)
}

free_rule :: proc(r: ^Rule) {
	delete(r.class); delete(r.instance); delete(r.title); delete(r.type)
	r^ = {}
}

@(private="file")
open_window :: proc(a: ^App) -> bool {
	c := a.c
	mon := tx.monitor_rect(c)
	a.w = min(i32(960), mon.w - 40)
	a.h = min(i32(660), mon.h - 60)
	x := mon.x + (mon.w - a.w) / 2
	y := mon.y + (mon.h - a.h) / 2
	attrs: xlib.XSetWindowAttributes
	bg := a.theme.bg
	attrs.background_pixel = uint(bg.r) << 16 | uint(bg.g) << 8 | uint(bg.b)
	attrs.event_mask = {.ButtonPress, .PointerMotion, .LeaveWindow, .KeyPress, .Exposure, .StructureNotify}
	a.win = xlib.CreateWindow(c.dpy, c.root, x, y, u32(a.w), u32(a.h), 0, c.depth, .InputOutput, c.visual,
	                          {.CWBackPixel, .CWEventMask}, &attrs)
	if a.win == 0 { return false }
	a.input = tx.input_open(c, a.win)
	hint := xlib.XClassHint{res_name = "lactase-settings", res_class = "Lactase-settings"}
	xlib.SetClassHint(c.dpy, a.win, &hint)
	xlib.StoreName(c.dpy, a.win, "lactase settings")
	tx.set_utf8_string(c, a.win, "_NET_WM_NAME", tr(a, "Configurações do lactase", "lactase settings"))
	tx.set_atom_list(c, a.win, "_NET_WM_WINDOW_TYPE", {tx.atom(c, "_NET_WM_WINDOW_TYPE_DIALOG")})
	tx.set_cardinals(c, a.win, "_NET_WM_PID", {uint(posix.getpid())})
	protocols := [1]xlib.Atom{tx.atom(c, "WM_DELETE_WINDOW")}
	xlib.SetWMProtocols(c.dpy, a.win, &protocols[0], 1)
	if sh := xlib.AllocSizeHints(); sh != nil {
		sh.flags = {.PMinSize, .PPosition, .PSize}
		sh.x, sh.y, sh.width, sh.height = x, y, a.w, a.h
		sh.min_width, sh.min_height = min(a.w, 820), min(a.h, 560)
		xlib.SetWMNormalHints(c.dpy, a.win, sh)
		xlib.Free(sh)
	}
	if wmh := xlib.AllocWMHints(); wmh != nil {
		wmh.flags = {.InputHint}
		wmh.input = true
		xlib.SetWMHints(c.dpy, a.win, wmh)
		xlib.Free(wmh)
	}
	a.cursor = xlib.CreateFontCursor(c.dpy, .XC_left_ptr)
	xlib.DefineCursor(c.dpy, a.win, a.cursor)
	tx.map_window(c, a.win)
	tx.flush(c)
	return true
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------
@(private="file")
loop_settings :: proc(a: ^App) {
	c := a.c
	for !a.quit {
		for tx.pending(c) > 0 && !a.quit {
			ev: xlib.XEvent
			tx.next_event(c, &ev)
			if tx.input_filter(&ev) { continue }
			handle_settings_event(a, &ev)
		}
		if a.quit { break }
		now := tx.now()
		if a.save_at > 0 && now >= a.save_at { save_now(a) }
		if now >= a.status_at { refresh_status(a) }
		if a.notice != "" && now >= a.notice_until {
			a.notice = ""
			a.dirty = true
		}
		if a.dirty { render(a) }
		free_all(context.temp_allocator)
		if tx.pending(c) > 0 { continue }
		timeout := a.status_at - tx.now()
		if a.save_at > 0 { timeout = min(timeout, a.save_at - tx.now()) }
		if a.notice != "" { timeout = min(timeout, a.notice_until - tx.now()) }
		pfd := posix.pollfd{fd = posix.FD(c.fd), events = {.IN}}
		posix.poll(&pfd, 1, i32(max(timeout, 0) * 1000) + 1)
	}
}

@(private="file")
refresh_status :: proc(a: ^App) {
	inst, running := find_instance(a.c)
	running = running && inst.lactase
	if running != a.running || inst.backend != a.instance.backend || inst.pid != a.instance.pid { a.dirty = true }
	old := a.instance.backend
	a.running = running
	a.instance = inst
	a.instance.name = "" // temporary strings; only the backend is kept
	a.instance.backend = running ? strings.clone(inst.backend) : ""
	delete(old)
	a.status_at = tx.now() + 1
}

@(private="file")
handle_settings_event :: proc(a: ^App, ev: ^xlib.XEvent) {
	#partial switch ev.type {
	case .Expose:
		if ev.xexpose.count == 0 { a.dirty = true }
	case .ConfigureNotify:
		if ev.xconfigure.window == a.win && (ev.xconfigure.width != a.w || ev.xconfigure.height != a.h) {
			a.w, a.h = ev.xconfigure.width, ev.xconfigure.height
			a.dirty = true
		}
	case .MappingNotify:
		xlib.RefreshKeyboardMapping(&ev.xmapping)
	case .ButtonPress:
		if a.picking {
			pick_window(a, ev.xbutton.subwindow)
			return
		}
		if ev.xbutton.window != a.win { return }
		switch ev.xbutton.button {
		case .Button4: scroll_rules(a, -1)
		case .Button5: scroll_rules(a, 1)
		case .Button1:
			h := hit_at(a, ev.xbutton.x, ev.xbutton.y)
			a.editor.focused = h.action == .Rule_Field
			do_action(a, h.action, h.arg)
			a.dirty = true
		case .Button2, .Button3:
		}
	case .MotionNotify:
		if ev.xmotion.window != a.win { return }
		a.pointer = {ev.xmotion.x, ev.xmotion.y}
		h := hit_at(a, a.pointer.x, a.pointer.y)
		if h.action != a.hover.action || h.arg != a.hover.arg {
			a.hover = h
			a.dirty = true
		}
	case .LeaveNotify:
		if a.hover.action != .None {
			a.hover = {}
			a.dirty = true
		}
	case .KeyPress:
		on_key(a, &ev.xkey)
	case .ClientMessage:
		if ev.xclient.window == a.win && xlib.Atom(ev.xclient.data.l[0]) == tx.atom(a.c, "WM_DELETE_WINDOW") { a.quit = true }
	}
}

@(private="file")
on_key :: proc(a: ^App, ev: ^xlib.XKeyEvent) {
	s, sym := tx.input_lookup(&a.input, ev)
	ctrl := .ControlMask in ev.state
	if ctrl && (sym == .XK_q || sym == .XK_w) {
		a.quit = true
		return
	}
	if sym == .XK_Escape {
		if a.picking {
			stop_picking(a)
		} else if a.editor.open {
			a.editor.open = false
		} else {
			a.quit = true
		}
		a.dirty = true
		return
	}
	if !a.editor.open || !a.editor.focused { return }
	#partial switch sym {
	case .XK_BackSpace:
		ed := &a.editor
		for len(ed.text) > 0 {
			b := pop(&ed.text)
			if b & 0xC0 != 0x80 { break }
		}
	case .XK_Return, .XK_KP_Enter:
		save_rule(a)
	case:
		if s != "" && !ctrl && s[0] >= 0x20 && len(a.editor.text) + len(s) <= 120 {
			append(&a.editor.text, ..transmute([]u8)s)
		}
	}
	a.dirty = true
}

@(private="file")
scroll_rules :: proc(a: ^App, dir: int) {
	if a.section != .Rules || a.editor.open { return }
	a.rules_scroll = clamp(a.rules_scroll + dir, 0, max(len(a.rules) - 1, 0))
	a.dirty = true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
section_info :: proc(a: ^App, s: Section) -> (ic: Icon, title, desc: string) {
	switch s {
	case .General:
		return .Adjustments, tr(a, "Geral", "General"), tr(a, "O compositor, o renderizador e a sincronia com a tela.", "The compositor, the renderer and display sync.")
	case .Shadows:
		return .Shadow, tr(a, "Sombras", "Shadows"), tr(a, "A sombra suave sob as janelas.", "The soft shadow under windows.")
	case .Animations:
		return .Sparkles, tr(a, "Animações", "Animations"), tr(a, "Como as janelas aparecem, somem e trocam de área.", "How windows appear, disappear and change areas.")
	case .Opacity:
		return .Droplet, tr(a, "Transparência", "Transparency"), tr(a, "Opacidade das janelas em foco e fora de foco.", "Opacity of focused and unfocused windows.")
	case .Blur:
		return .Blur, tr(a, "Desfoque", "Blur"), tr(a, "Desfoca o que fica atrás das janelas transparentes.", "Blurs what is behind transparent windows.")
	case .Corners:
		return .Border_Radius, tr(a, "Cantos", "Corners"), tr(a, "Cantos arredondados e suavizados.", "Rounded, smooth corners.")
	case .Rules:
		return .List, tr(a, "Regras", "Rules"), tr(a, "Ajustes por aplicativo ou tipo de janela.", "Settings per application or window type.")
	case .About:
		return .Info, tr(a, "Sobre", "About"), tr(a, "Versão e arquivo de configuração.", "Version and configuration file.")
	}
	return .None, "", ""
}

content_rect :: proc(a: ^App) -> Rect {
	return {SIDEBAR_W + 36, 112, a.w - SIDEBAR_W - 72, a.h - 112 - 28}
}

draw_app :: proc(a: ^App, cv: ^tx.Canvas) {
	th := &a.theme
	tx.canvas_fill(cv, th.bg)
	tx.canvas_fill_rect(cv, {0, 0, SIDEBAR_W, cv.h}, th.sidebar)
	tx.canvas_fill_rect(cv, {SIDEBAR_W, 0, 1, cv.h}, mix(th.bg, th.muted, 0.25))

	c := content_rect(a)
	switch a.section {
	case .General:    page_general(a, cv, c)
	case .Shadows:    page_shadows(a, cv, c)
	case .Animations: page_animations(a, cv, c)
	case .Opacity:    page_opacity(a, cv, c)
	case .Blur:       page_blur(a, cv, c)
	case .Corners:    page_corners(a, cv, c)
	case .Rules:      page_rules(a, cv, c)
	case .About:      page_about(a, cv, c)
	}

	// Sidebar.
	x: i32 = 22
	if a.fonts.icon_small != nil {
		tx.canvas_fill_circle(cv, f32(x + 15), 39, 15, th.accent)
		icon(a, a.fonts.icon_small, {x, 24, 30, 30}, .Milk, th.accent_fg)
		x += 40
	}
	text(a, a.fonts.h2, x, 24, 30, "lactase", th.fg)
	y: i32 = 80
	for sec in Section {
		ic, title, _ := section_info(a, sec)
		r := Rect{12, y, SIDEBAR_W - 24, 40}
		sel := sec == a.section
		if sel {
			fill_rounded(cv, r, 12, th.accent)
		} else if hovered(a, .Section, int(sec)) {
			fill_rounded(cv, r, 12, th.hover)
		}
		icon(a, a.fonts.icon_small, {r.x + 12, r.y, 22, r.h}, ic, sel ? th.accent_fg : mix(th.fg, th.muted, 0.35))
		text(a, a.fonts.body, r.x + 46, r.y, r.h, ellipsize(a, a.fonts.body, title, r.w - 54), sel ? th.accent_fg : th.fg)
		add_hit(a, r, .Section, int(sec))
		y += 44
	}
	// Status at the bottom of the sidebar.
	dot := a.running ? tx.rgb(0x4C, 0xAF, 0x50) : th.muted
	tx.canvas_fill_circle(cv, 30, f32(a.h - 30), 5, dot)
	status := a.running ? fmt.tprintf(tr(a, "Ativo (%s)", "Running (%s)"), a.instance.backend == "" ? "?" : a.instance.backend) : tr(a, "Parado", "Stopped")
	text(a, a.fonts.small, 44, a.h - 40, 20, status, th.sub)

	// Header.
	_, title, desc := section_info(a, a.section)
	cx := i32(SIDEBAR_W + 36)
	text(a, a.fonts.title, cx, 26, 42, title, th.fg)
	text(a, a.fonts.small, cx, 68, 22, ellipsize(a, a.fonts.small, desc, a.w - cx - 36), th.sub)
	if a.notice != "" && tx.now() < a.notice_until {
		nw := text_width(a, a.fonts.small, a.notice) + 44
		r := Rect{a.w - 36 - nw, 32, nw, 30}
		fill_rounded(cv, r, 15, mix(th.accent, th.bg, 0.82))
		icon(a, a.fonts.icon_small, {r.x + 10, r.y, 18, r.h}, .Check, th.accent)
		text(a, a.fonts.small, r.x + 32, r.y, r.h, a.notice, th.fg)
	}
}

@(private="file")
percent :: proc(v: f64) -> string { return fmt.tprintf("%d%%", int(math.round(v * 100))) }

@(private="file")
milk_follows :: proc(a: ^App) -> bool { return a.cfg.follow_milk && a.milk.found }

@(private="file")
page_general :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	th := &a.theme
	cfg := a.cfg
	y := c.y
	row := next_row(a, cv, c, &y, tr(a, "Compositor", "Compositor"),
	                a.running ? fmt.tprintf(tr(a, "Ativo neste monitor (pid %d)", "Running on this display (pid %d)"), a.instance.pid) :
	                          tr(a, "Parado: janelas sem efeitos", "Stopped: windows without effects"))
	label := a.running ? tr(a, "Parar", "Stop") : tr(a, "Iniciar", "Start")
	bw := button_width(a, label, .Play)
	button(a, cv, {row.x + row.w - bw, row.y + (row.h - 40) / 2, bw, 40}, label, a.running ? .Tonal : .Filled, .Start_Stop, 0,
	       a.running ? .Stop : .Play)

	row = next_row(a, cv, c, &y, tr(a, "Renderizador", "Renderer"), tr(a, "GLX usa a placa de vídeo; XRender é a alternativa simples", "GLX uses the GPU; XRender is the simple fallback"))
	choice(a, cv, {row.x + row.w - 300, row.y + 8, 300, 40}, {"GLX (OpenGL)", "XRender"}, cfg.backend == "xrender" ? 1 : 0, .Backend)
	row = next_row(a, cv, c, &y, tr(a, "Sincronia vertical", "Vertical sync"), tr(a, "Quadros no ritmo da tela, sem cortes (GLX)", "Frames in step with the display, no tearing (GLX)"), reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, cfg.vsync, .Vsync)
	follow_desc := a.milk.found ? tr(a, "Raio dos cantos e velocidade das animações das configurações do milk", "Corner radius and animation speed from milk's settings") :
	                            tr(a, "milk.json não encontrado", "milk.json not found")
	row = next_row(a, cv, c, &y, tr(a, "Seguir o milk", "Follow milk"), follow_desc, !a.milk.found, reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, cfg.follow_milk, .Follow_Milk, a.milk.found)
	row = next_row(a, cv, c, &y, tr(a, "Tela cheia direta", "Direct full screen"), tr(a, "Jogos e vídeos em tela cheia sem passar pelo compositor", "Full-screen games and video skip the compositor"), reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, cfg.unredirect_fullscreen, .Unredirect)
	_ = th
}

@(private="file")
page_shadows :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	s := &a.cfg.shadows
	ph := min(i32(150), c.h / 3)
	draw_preview(a, cv, {c.x, c.y, c.w, ph})
	y := c.y + ph + 12
	row := next_row(a, cv, c, &y, tr(a, "Sombras", "Shadows"), tr(a, "Sob janelas, menus e avisos", "Under windows, menus and pop-ups"), reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, s.enabled, .Shadow_On)
	on := s.enabled
	row = next_row(a, cv, c, &y, tr(a, "Suavidade", "Softness"), tr(a, "Raio do desfoque da sombra", "Blur radius of the shadow"), !on, reserve = RESERVE_STEPPER)
	stepper(a, cv, row, fmt.tprintf("%d px", s.radius), .Shadow_Radius, on)
	row = next_row(a, cv, c, &y, tr(a, "Intensidade", "Strength"), "", !on, reserve = RESERVE_STEPPER)
	stepper(a, cv, row, percent(s.opacity), .Shadow_Opacity, on)
	if y + ROW_H <= c.y + c.h + 8 {
		half := (c.w - 24) / 2
		left := Rect{c.x, y, half, ROW_H}
		right := Rect{c.x + half + 24, y, half, ROW_H}
		row_label(a, left, tr(a, "Deslocamento X", "Offset X"), "", !on)
		stepper(a, cv, left, fmt.tprintf("%d px", s.offset_x), .Shadow_X, on)
		row_label(a, right, tr(a, "Deslocamento Y", "Offset Y"), "", !on)
		stepper(a, cv, right, fmt.tprintf("%d px", s.offset_y), .Shadow_Y, on)
	}
}

ANIM_LABELS_PT :: []string{"Nenhuma", "Esmaecer", "Zoom", "Deslizar"}
ANIM_LABELS_EN :: []string{"None", "Fade", "Zoom", "Slide"}

@(private="file")
anim_index :: proc(name: string) -> int {
	for k, i in ANIMATION_KINDS { if k == name { return i } }
	return 0
}

@(private="file")
page_animations :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	an := &a.cfg.animations
	y := c.y
	scale_note := ""
	if milk_follows(a) {
		scale_note = a.milk.animation_scale <= 0 ? tr(a, "desligadas pelo milk", "turned off by milk") :
		             fmt.tprintf(tr(a, "velocidade do milk: ×%.2g", "milk's speed: ×%.2g"), a.milk.animation_scale)
	}
	row := next_row(a, cv, c, &y, tr(a, "Animações", "Animations"), scale_note, reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, an.enabled, .Anim_On)
	on := an.enabled
	labels := a.pt ? ANIM_LABELS_PT : ANIM_LABELS_EN
	cw := min(i32(420), c.w - 220)
	row = next_row(a, cv, c, &y, tr(a, "Ao abrir", "Opening"), "", !on)
	choice(a, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, labels, anim_index(an.open), .Anim_Open, on)
	row = next_row(a, cv, c, &y, tr(a, "Ao fechar", "Closing"), "", !on)
	choice(a, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, labels, anim_index(an.close), .Anim_Close, on)
	row = next_row(a, cv, c, &y, tr(a, "Duração ao abrir", "Opening time"), "", !on, reserve = RESERVE_STEPPER)
	stepper(a, cv, row, fmt.tprintf("%d ms", an.open_duration), .Anim_Open_Ms, on)
	row = next_row(a, cv, c, &y, tr(a, "Duração ao fechar", "Closing time"), "", !on, reserve = RESERVE_STEPPER)
	stepper(a, cv, row, fmt.tprintf("%d ms", an.close_duration), .Anim_Close_Ms, on)
	row = next_row(a, cv, c, &y, tr(a, "Troca de área", "Area switch"), tr(a, "Janelas e papel de parede esmaecem entre as áreas", "Windows and wallpaper fade between areas"), !on, reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, an.workspaces, .Anim_Areas, on)
}

@(private="file")
page_opacity :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	op := &a.cfg.opacity
	ph := min(i32(150), c.h / 3)
	draw_preview(a, cv, {c.x, c.y, c.w, ph})
	y := c.y + ph + 12
	row := next_row(a, cv, c, &y, tr(a, "Janela em foco", "Focused window"), "", reserve = RESERVE_STEPPER)
	stepper(a, cv, row, percent(op.active), .Op_Active)
	row = next_row(a, cv, c, &y, tr(a, "Outras janelas", "Other windows"), tr(a, "Janelas de aplicativos fora de foco", "Application windows without focus"), reserve = RESERVE_STEPPER)
	stepper(a, cv, row, percent(op.inactive), .Op_Inactive)
	row = next_row(a, cv, c, &y, tr(a, "Escurecer fora de foco", "Dim unfocused"), tr(a, "Escurece as janelas fora de foco", "Darkens windows without focus"), reserve = RESERVE_STEPPER)
	stepper(a, cv, row, op.dim_inactive <= 0 ? tr(a, "Desligado", "Off") : percent(op.dim_inactive), .Op_Dim)
}

@(private="file")
page_blur :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	bl := &a.cfg.blur
	y := c.y
	row := next_row(a, cv, c, &y, tr(a, "Desfoque de fundo", "Background blur"), tr(a, "Atrás de janelas transparentes (precisa do GLX)", "Behind transparent windows (needs GLX)"), reserve = RESERVE_TOGGLE)
	toggle(a, cv, row, bl.enabled, .Blur_On)
	row = next_row(a, cv, c, &y, tr(a, "Intensidade", "Strength"), "", !bl.enabled, reserve = RESERVE_STEPPER)
	stepper(a, cv, row, fmt.tprintf("%d", bl.strength), .Blur_Strength, bl.enabled)
	y += 12
	th := &a.theme
	hint := tr(a, "Deixe janelas transparentes em Transparência ou em Regras para ver o desfoque.",
	              "Make windows transparent under Transparency or Rules to see the blur.")
	text(a, a.fonts.small, c.x, y, 22, ellipsize(a, a.fonts.small, hint, c.w), th.sub)
}

@(private="file")
page_corners :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	ph := min(i32(150), c.h / 3)
	draw_preview(a, cv, {c.x, c.y, c.w, ph})
	y := c.y + ph + 12
	follows := milk_follows(a)
	desc := follows ? fmt.tprintf(tr(a, "Segue o milk: %d px (mude em Janelas, nas configurações do milk)", "Follows milk: %d px (change it under Windows in milk's settings)"), a.milk.corner_radius) :
	                tr(a, "Janelas, menus e avisos; tela cheia fica reta", "Windows, menus and pop-ups; full screen stays square")
	row := next_row(a, cv, c, &y, tr(a, "Raio dos cantos", "Corner radius"), desc, follows, reserve = RESERVE_STEPPER)
	value := a.cfg.corners.radius == 0 ? tr(a, "Retos", "Square") : fmt.tprintf("%d px", a.cfg.corners.radius)
	if follows { value = a.milk.corner_radius == 0 ? tr(a, "Retos", "Square") : fmt.tprintf("%d px", a.milk.corner_radius) }
	stepper(a, cv, row, value, .Corners, !follows)
	y += 12
	hint := tr(a, "Janelas que o gerenciador já arredonda ficam com as bordas suavizadas.",
	              "Windows the window manager already rounds get smooth edges.")
	text(a, a.fonts.small, c.x, y, 22, ellipsize(a, a.fonts.small, hint, c.w), a.theme.sub)
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------
@(private="file")
type_label :: proc(a: ^App, t: string) -> string {
	if !a.pt { return t }
	switch t {
	case "normal":        return "normal"
	case "dialog":        return "diálogo"
	case "utility":       return "utilitário"
	case "toolbar":       return "barra de ferramentas"
	case "splash":        return "abertura"
	case "menu":          return "menu"
	case "dropdown_menu": return "menu suspenso"
	case "popup_menu":    return "menu de contexto"
	case "tooltip":       return "dica"
	case "notification":  return "notificação"
	case "combo":         return "lista"
	case "dnd":           return "arrastar"
	case "dock":          return "painel (dock)"
	case "desktop":       return "área de trabalho"
	case "unknown":       return "desconhecido"
	}
	return t
}

@(private="file")
rule_match_text :: proc(a: ^App, r: Rule) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if r.class != ""    { append(&parts, fmt.tprintf(tr(a, "Classe %s", "Class %s"), r.class)) }
	if r.instance != "" { append(&parts, fmt.tprintf(tr(a, "Instância %s", "Instance %s"), r.instance)) }
	if r.title != ""    { append(&parts, fmt.tprintf(tr(a, "Título com \"%s\"", "Title with \"%s\""), r.title)) }
	if r.type != ""     { append(&parts, fmt.tprintf(tr(a, "Tipo %s", "Type %s"), type_label(a, r.type))) }
	return strings.join(parts[:], " · ", context.temp_allocator)
}

@(private="file")
rule_effect_text :: proc(a: ^App, r: Rule) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if v, ok := r.opacity.?; ok { append(&parts, fmt.tprintf(tr(a, "opacidade %s", "opacity %s"), percent(v))) }
	if v, ok := r.shadow.?; ok  { append(&parts, v ? tr(a, "com sombra", "shadow") : tr(a, "sem sombra", "no shadow")) }
	if v, ok := r.blur.?; ok    { append(&parts, v ? tr(a, "com desfoque", "blur") : tr(a, "sem desfoque", "no blur")) }
	if v, ok := r.corners.?; ok { append(&parts, v == 0 ? tr(a, "cantos retos", "square corners") : fmt.tprintf(tr(a, "cantos %d px", "corners %d px"), v)) }
	if v, ok := r.animate.?; ok { append(&parts, v ? tr(a, "com animações", "animated") : tr(a, "sem animações", "no animations")) }
	if v, ok := r.dim.?; ok     { append(&parts, v ? tr(a, "escurece", "dims") : tr(a, "não escurece", "never dims")) }
	if len(parts) == 0 { return tr(a, "sem mudanças", "no changes") }
	return strings.join(parts[:], ", ", context.temp_allocator)
}

@(private="file")
page_rules :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	if a.editor.open {
		page_rule_editor(a, cv, c)
		return
	}
	th := &a.theme
	y := c.y
	bottom := c.y + c.h - BUTTON_H - 16
	if len(a.rules) == 0 {
		text(a, a.fonts.body, c.x, y, 40, tr(a, "Nenhuma regra ainda.", "No rules yet."), th.sub)
	}
	for i := a.rules_scroll; i < len(a.rules); i += 1 {
		if y + ROW_H > bottom { break }
		r := a.rules[i]
		row := Rect{c.x, y, c.w, ROW_H}
		if hovered(a, .Rule_Edit, i) { fill_rounded(cv, {row.x - 10, row.y + 2, row.w + 20, row.h - 4}, 12, th.field) }
		add_hit(a, {row.x, row.y, row.w - 60, row.h}, .Rule_Edit, i)
		row_label(a, row, rule_match_text(a, r), rule_effect_text(a, r))
		del := Rect{row.x + row.w - 40, row.y + (row.h - 36) / 2, 36, 36}
		if hovered(a, .Rule_Delete, i) { fill_rounded(cv, del, 18, th.hover) }
		icon(a, a.fonts.icon_small, del, .Trash, hovered(a, .Rule_Delete, i) ? th.warning : th.sub)
		add_hit(a, del, .Rule_Delete, i)
		y += ROW_H
		tx.canvas_fill_rect(cv, {c.x, y - 1, c.w, 1}, th.divider)
	}
	if a.rules_scroll > 0 || y + ROW_H > bottom && len(a.rules) > 0 {
		more := fmt.tprintf(tr(a, "%d regras · role para ver todas", "%d rules · scroll to see them all"), len(a.rules))
		text(a, a.fonts.small, c.x, bottom - 4, 20, more, th.muted)
	}
	label := tr(a, "Nova regra", "New rule")
	bw := button_width(a, label, .Plus)
	button(a, cv, {c.x, c.y + c.h - BUTTON_H, bw, BUTTON_H}, label, .Filled, .Rule_New, 0, .Plus)
}

@(private="file")
TRI_PT :: []string{"Padrão", "Sim", "Não"}
@(private="file")
TRI_EN :: []string{"Default", "Yes", "No"}

@(private="file")
page_rule_editor :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	ed := &a.editor
	th := &a.theme
	y := c.y
	cw := min(i32(360), c.w - 240)
	row := next_row(a, cv, c, &y, tr(a, "Janelas por", "Windows by"), "")
	choice(a, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(a, "Classe", "Class"), tr(a, "Título", "Title"), tr(a, "Tipo", "Type")}, ed.match, .Ed_Match)
	if ed.match == 2 {
		row = next_row(a, cv, c, &y, tr(a, "Tipo de janela", "Window type"), "", reserve = RESERVE_STEPPER)
		stepper(a, cv, {row.x, row.y, row.w + 0, row.h}, type_label(a, WINDOW_TYPES[ed.type]), .Ed_Type)
	} else {
		row = next_row(a, cv, c, &y, ed.match == 0 ? tr(a, "Classe (WM_CLASS)", "Class (WM_CLASS)") : tr(a, "O título contém", "Title contains"), "")
		pick := tr(a, "Escolher", "Pick")
		pw := button_width(a, pick, .Crosshair)
		fw := min(i32(300), row.w - pw - 220)
		field(a, cv, {row.x + row.w - pw - 12 - fw, row.y + 8, fw, 40}, string(ed.text[:]),
		      ed.match == 0 ? "Alacritty" : tr(a, "parte do título", "part of the title"), ed.focused, .Rule_Field)
		button(a, cv, {row.x + row.w - pw, row.y + 8, pw, 40}, a.picking ? tr(a, "Clique…", "Click…") : pick, .Tonal, .Rule_Pick, 0, .Crosshair)
	}
	tri := a.pt ? TRI_PT : TRI_EN
	tw := min(i32(300), c.w - 260)
	row = next_row(a, cv, c, &y, tr(a, "Opacidade", "Opacity"), "", reserve = RESERVE_STEPPER)
	stepper(a, cv, row, ed.opacity == 0 ? tri[0] : fmt.tprintf("%d%%", ed.opacity), .Ed_Opacity)
	row = next_row(a, cv, c, &y, tr(a, "Sombra", "Shadow"), "")
	choice(a, cv, {row.x + row.w - tw, row.y + 8, tw, 40}, tri, ed.shadow, .Ed_Shadow)
	row = next_row(a, cv, c, &y, tr(a, "Desfoque", "Blur"), "")
	choice(a, cv, {row.x + row.w - tw, row.y + 8, tw, 40}, tri, ed.blur, .Ed_Blur)
	row = next_row(a, cv, c, &y, tr(a, "Cantos", "Corners"), "", reserve = RESERVE_STEPPER)
	stepper(a, cv, row, ed.corners < 0 ? tri[0] : (ed.corners == 0 ? tr(a, "Retos", "Square") : fmt.tprintf("%d px", ed.corners)), .Ed_Corners)
	if y + ROW_H <= c.y + c.h - BUTTON_H - 8 {
		row = next_row(a, cv, c, &y, tr(a, "Animações", "Animations"), "")
		choice(a, cv, {row.x + row.w - tw, row.y + 8, tw, 40}, tri, ed.animate, .Ed_Animate)
	}
	by := c.y + c.h - BUTTON_H
	save := tr(a, "Salvar regra", "Save rule")
	sw := button_width(a, save, .Check)
	valid := ed.match == 2 || strings.trim_space(string(ed.text[:])) != ""
	button(a, cv, {c.x + c.w - sw, by, sw, BUTTON_H}, save, .Filled, .Rule_Save, 0, .Check, valid)
	cancel := tr(a, "Cancelar", "Cancel")
	cw2 := button_width(a, cancel)
	button(a, cv, {c.x + c.w - sw - 12 - cw2, by, cw2, BUTTON_H}, cancel, .Text, .Rule_Cancel)
	_ = th
}

@(private="file")
open_editor :: proc(a: ^App, index: int) {
	ed := &a.editor
	clear(&ed.text)
	ed^ = {text = ed.text, open = true, index = index, corners = -1}
	if index < 0 || index >= len(a.rules) {
		ed.index = -1
		ed.focused = true
		return
	}
	r := a.rules[index]
	switch {
	case r.class != "":
		ed.match = 0
		append(&ed.text, ..transmute([]u8)r.class)
	case r.title != "":
		ed.match = 1
		append(&ed.text, ..transmute([]u8)r.title)
	case r.type != "":
		ed.match = 2
		for t, i in WINDOW_TYPES { if t == r.type { ed.type = i } }
	case r.instance != "":
		ed.match = 0
		append(&ed.text, ..transmute([]u8)r.instance)
	}
	tri :: proc(v: Maybe(bool)) -> int {
		if b, ok := v.?; ok { return b ? 1 : 2 }
		return 0
	}
	if v, ok := r.opacity.?; ok { ed.opacity = int(math.round(v * 100)) }
	ed.shadow = tri(r.shadow)
	ed.blur = tri(r.blur)
	ed.animate = tri(r.animate)
	if v, ok := r.corners.?; ok { ed.corners = v }
}

@(private="file")
save_rule :: proc(a: ^App) {
	ed := &a.editor
	value := strings.trim_space(string(ed.text[:]))
	if ed.match != 2 && value == "" { return }
	r: Rule
	switch ed.match {
	case 0: r.class = strings.clone(value)
	case 1: r.title = strings.clone(value)
	case 2: r.type = strings.clone(WINDOW_TYPES[ed.type])
	}
	from_tri :: proc(v: int) -> Maybe(bool) {
		switch v {
		case 1: return true
		case 2: return false
		}
		return nil
	}
	if ed.opacity > 0 { r.opacity = f64(ed.opacity) / 100 }
	r.shadow = from_tri(ed.shadow)
	r.blur = from_tri(ed.blur)
	r.animate = from_tri(ed.animate)
	if ed.corners >= 0 { r.corners = ed.corners }
	if ed.index >= 0 && ed.index < len(a.rules) {
		r.dim = a.rules[ed.index].dim // not editable here: keep it
		if ed.match == 0 { r.instance = strings.clone(a.rules[ed.index].instance) }
		free_rule(&a.rules[ed.index])
		a.rules[ed.index] = r
	} else {
		append(&a.rules, r)
	}
	ed.open = false
	changed(a)
}

// Pick a window with the mouse: its class goes into the editor.
@(private="file")
start_picking :: proc(a: ^App) {
	c := a.c
	cross := xlib.CreateFontCursor(c.dpy, .XC_crosshair)
	status := xlib.GrabPointer(c.dpy, c.root, false, {.ButtonPress}, .GrabModeAsync, .GrabModeAsync, 0, cross, xlib.CurrentTime)
	xlib.FreeCursor(c.dpy, cross)
	if status != 0 { return } // GrabSuccess
	a.picking = true
}

@(private="file")
stop_picking :: proc(a: ^App) {
	xlib.UngrabPointer(a.c.dpy, xlib.CurrentTime)
	a.picking = false
	a.dirty = true
}

@(private="file")
pick_window :: proc(a: ^App, top: xlib.Window) {
	stop_picking(a)
	if top == 0 || top == a.win { return }
	c := a.c
	target := top
	// A reparenting window manager: the class lives on the client inside the frame.
	if _, class := tx.window_class(c, target); class == "" {
		root, parent: xlib.Window
		children: [^]xlib.Window
		n: u32
		if xlib.QueryTree(c.dpy, top, &root, &parent, &children, &n) != xlib.Status(0) && children != nil {
			for i in 0 ..< int(n) {
				if _, cl := tx.window_class(c, children[i]); cl != "" { target = children[i]; break }
			}
			xlib.Free(children)
		}
	}
	instance, class := tx.window_class(c, target)
	name := class != "" ? class : instance
	if name == "" { return }
	ed := &a.editor
	clear(&ed.text)
	append(&ed.text, ..transmute([]u8)name)
	ed.match = 0
	a.dirty = true
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------
@(private="file")
page_about :: proc(a: ^App, cv: ^tx.Canvas, c: Rect) {
	th := &a.theme
	y := c.y + 8
	tx.canvas_fill_circle(cv, f32(c.x + 36), f32(y + 36), 36, th.accent)
	icon(a, a.fonts.icon_big, {c.x, y, 72, 72}, .Milk, th.accent_fg)
	text(a, a.fonts.title, c.x + 92, y + 4, 40, "lactase", th.fg)
	text(a, a.fonts.body, c.x + 92, y + 42, 24, fmt.tprintf(tr(a, "Versão %s · o compositor do milk", "Version %s · milk's compositor"), VERSION), th.sub)
	y += 104
	text(a, a.fonts.tiny, c.x, y, 18, tr(a, "CONFIGURAÇÃO", "CONFIGURATION"), th.muted)
	text(a, a.fonts.small, c.x, y + 18, 22, ellipsize(a, a.fonts.small, a.cfg_path, c.w), th.fg)
	y += 64
	edit := tr(a, "Abrir lactase.json", "Open lactase.json")
	ew := button_width(a, edit, .File_Code)
	button(a, cv, {c.x, y, ew, BUTTON_H}, edit, .Tonal, .Open_Json, 0, .File_Code)
	reset := tr(a, "Restaurar padrões", "Restore defaults")
	rw := button_width(a, reset, .Restore)
	button(a, cv, {c.x + ew + 12, y, rw, BUTTON_H}, reset, .Text, .Reset, 0, .Restore)
	y += BUTTON_H + 20
	credit := tr(a, "Inspirado no picom (e no compton e xcompmgr antes dele).", "Inspired by picom (and compton and xcompmgr before it).")
	text(a, a.fonts.small, c.x, y, 22, credit, th.sub)
}

// ---------------------------------------------------------------------------
// Preview: two small windows over a gradient, drawn with the current settings
// ---------------------------------------------------------------------------
@(private="file")
draw_preview :: proc(a: ^App, cv: ^tx.Canvas, r: Rect) {
	cfg := a.cfg
	radius := f32(milk_follows(a) ? a.milk.corner_radius : cfg.corners.radius)
	key := [12]f32{f32(r.w), f32(r.h), radius, f32(cfg.shadows.radius), f32(cfg.shadows.opacity), f32(cfg.shadows.offset_x),
	               f32(cfg.shadows.offset_y), cfg.shadows.enabled ? 1 : 0, f32(cfg.opacity.active), f32(cfg.opacity.inactive),
	               f32(cfg.opacity.dim_inactive), a.theme.dark ? 1 : 0}
	if a.preview.w != r.w || a.preview.h != r.h || a.preview_key != key {
		tx.canvas_destroy(&a.preview)
		a.preview = build_preview(a, r.w, r.h, radius)
		a.preview_key = key
	}
	// Copy the cached preview through a rounded mask.
	pv := &a.preview
	for y in 0 ..< pv.h {
		dy := r.y + y
		if dy < 0 || dy >= cv.h { continue }
		for x in 0 ..< pv.w {
			dx := r.x + x
			if dx < 0 || dx >= cv.w { continue }
			cov := box_coverage(f32(x) + 0.5, f32(y) + 0.5, f32(pv.w), f32(pv.h), 18)
			if cov <= 0 { continue }
			i := int(dy) * int(cv.w) + int(dx)
			cv.px[i] = lerp_px(cv.px[i], pv.px[int(y) * int(pv.w) + int(x)], cov)
		}
	}
}

@(private="file")
box_coverage :: proc(px, py, w, h, rad: f32) -> f32 {
	if rad <= 0 { return 1 }
	cx := clamp(px, rad, w - rad)
	cy := clamp(py, rad, h - rad)
	dx, dy := px - cx, py - cy
	if dx == 0 && dy == 0 { return 1 }
	return clamp(rad - math.sqrt(dx * dx + dy * dy), 0, 1)
}

@(private="file")
lerp_px :: proc(dst, src: u32, t: f32) -> u32 {
	if t >= 1 { return src }
	out: u32
	for sh in ([]u32{16, 8, 0}) {
		d := f32((dst >> sh) & 0xFF)
		s := f32((src >> sh) & 0xFF)
		out |= u32(d + (s - d) * t) << sh
	}
	return out
}

@(private="file")
build_preview :: proc(a: ^App, w, h: i32, radius: f32) -> tx.Canvas {
	th := &a.theme
	cfg := a.cfg
	cv := tx.canvas_make(w, h)
	// Background: a diagonal gradient between two accent tones with stripes.
	c0 := mix(th.accent, th.bg, 0.35)
	c1 := mix(th.accent, tx.rgb(0x6F, 0x9F, 0xD8), 0.45)
	for y in 0 ..< h {
		for x in 0 ..< w {
			t := clamp((f32(x) / f32(w) + f32(y) / f32(h)) / 2, 0, 1)
			col := tx.color_mix(c0, c1, t)
			if (x + y * 2) % 44 < 3 { col = tx.color_mix(col, tx.rgb(255, 255, 255), 0.25) }
			cv.px[int(y) * int(w) + int(x)] = u32(col.r) << 16 | u32(col.g) << 8 | u32(col.b)
		}
	}
	scale: f32 = 0.6 // the preview is smaller than the real thing
	win_w, win_h := i32(f32(w) * 0.34), i32(f32(h) * 0.62)
	back := Rect{w / 2 - win_w + 10, h / 2 - win_h / 2 - 10, win_w, win_h}
	front := Rect{w / 2 - 10, h / 2 - win_h / 2 + 8, win_w, win_h}
	preview_window(a, &cv, back, radius * scale, f32(cfg.opacity.inactive), f32(cfg.opacity.dim_inactive), scale, false)
	preview_window(a, &cv, front, radius * scale, f32(cfg.opacity.active), 0, scale, true)
	return cv
}

@(private="file")
preview_window :: proc(a: ^App, cv: ^tx.Canvas, r: Rect, radius, opacity, dim, scale: f32, focused: bool) {
	th := &a.theme
	cfg := a.cfg
	if cfg.shadows.enabled && cfg.shadows.opacity > 0 {
		sigma := max(f32(cfg.shadows.radius) / 2 * scale, 0.5)
		ox, oy := f32(cfg.shadows.offset_x) * scale, f32(cfg.shadows.offset_y) * scale
		lower := [2]f32{f32(r.x) + ox, f32(r.y) + oy}
		upper := [2]f32{f32(r.x + r.w) + ox, f32(r.y + r.h) + oy}
		ext := i32(3 * sigma) + 2
		for y in max(r.y - ext + i32(oy), 0) ..< min(r.y + r.h + ext + i32(oy), cv.h) {
			for x in max(r.x - ext + i32(ox), 0) ..< min(r.x + r.w + ext + i32(ox), cv.w) {
				v := shadow_value(lower, upper, {f32(x) + 0.5, f32(y) + 0.5}, sigma, radius) * f32(cfg.shadows.opacity) * opacity
				inside := box_coverage(f32(x - r.x) + 0.5, f32(y - r.y) + 0.5, f32(r.w), f32(r.h), radius)
				if x < r.x || y < r.y || x >= r.x + r.w || y >= r.y + r.h { inside = 0 }
				v *= 1 - inside
				if v <= 0.002 { continue }
				i := int(y) * int(cv.w) + int(x)
				cv.px[i] = lerp_px(cv.px[i], 0, v)
			}
		}
	}
	body := mix(th.bg, tx.rgb(0, 0, 0), dim)
	title := mix(mix(th.surface, th.muted, 0.2), tx.rgb(0, 0, 0), dim)
	line := mix(mix(th.muted, th.bg, 0.3), tx.rgb(0, 0, 0), dim)
	bar_h := i32(18)
	for y in 0 ..< r.h {
		for x in 0 ..< r.w {
			cov := box_coverage(f32(x) + 0.5, f32(y) + 0.5, f32(r.w), f32(r.h), radius) * opacity
			if cov <= 0 { continue }
			col := body
			if y < bar_h { col = title }
			if y >= bar_h + 14 && y < bar_h + 20 && x >= 14 && x < r.w * 3 / 5 { col = line }
			if y >= bar_h + 30 && y < bar_h + 36 && x >= 14 && x < r.w * 2 / 5 { col = line }
			if focused && y >= bar_h + 46 && y < bar_h + 52 && x >= 14 && x < r.w / 2 { col = mix(th.accent, tx.rgb(0, 0, 0), dim) }
			dx, dy := r.x + x, r.y + y
			if dx < 0 || dy < 0 || dx >= cv.w || dy >= cv.h { continue }
			i := int(dy) * int(cv.w) + int(dx)
			cv.px[i] = lerp_px(cv.px[i], u32(col.r) << 16 | u32(col.g) << 8 | u32(col.b), cov)
		}
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
@(private="file")
do_action :: proc(a: ^App, action: Action, arg: int) {
	#partial switch action {
	case .Section:
		sec := Section(clamp(arg, 0, len(Section) - 1))
		if sec != a.section {
			a.section = sec
			a.editor.open = false
			a.hover = {}
		}
	case .Step:
		step(a, Control(arg / 10), arg % 10 == 1 ? 1 : -1)
	case .Toggle:
		flip(a, Control(arg))
	case .Choice:
		pick_choice(a, Control(arg / 100), arg % 100)
	case .Start_Stop:
		start_stop(a)
	case .Open_Json:
		if !os.exists(a.cfg_path) { save_now(a) }
		if p, err := os.process_start({command = {"xdg-open", a.cfg_path}}); err == nil {
			_ = p
		} else {
			log.warnf("Settings: cannot run xdg-open: %v", err)
		}
	case .Reset:
		destroy(a.cfg)
		a.cfg = default_config_owned()
		for &r in a.rules { free_rule(&r) }
		clear(&a.rules)
		for r in DEFAULT_RULES { append(&a.rules, clone_rule(r)) }
		changed(a)
	case .Rule_New:    open_editor(a, -1)
	case .Rule_Edit:   open_editor(a, arg)
	case .Rule_Cancel: a.editor.open = false
	case .Rule_Save:   save_rule(a)
	case .Rule_Pick:   start_picking(a)
	case .Rule_Delete:
		if arg >= 0 && arg < len(a.rules) {
			free_rule(&a.rules[arg])
			ordered_remove(&a.rules, arg)
			a.rules_scroll = clamp(a.rules_scroll, 0, max(len(a.rules) - 1, 0))
			changed(a)
		}
	}
}

@(private="file")
step_f :: proc(v, delta, lo, hi: f64) -> f64 { return clamp(math.round((v + delta) * 100) / 100, lo, hi) }

@(private="file")
step :: proc(a: ^App, ctrl: Control, dir: int) {
	cfg := a.cfg
	d := f64(dir)
	#partial switch ctrl {
	case .Shadow_Radius:  cfg.shadows.radius = clamp(cfg.shadows.radius + 2 * dir, 2, 80)
	case .Shadow_Opacity: cfg.shadows.opacity = step_f(cfg.shadows.opacity, 0.05 * d, 0.05, 1)
	case .Shadow_X:       cfg.shadows.offset_x = clamp(cfg.shadows.offset_x + dir, -40, 40)
	case .Shadow_Y:       cfg.shadows.offset_y = clamp(cfg.shadows.offset_y + dir, -40, 40)
	case .Anim_Open_Ms:   cfg.animations.open_duration = clamp(cfg.animations.open_duration + 10 * dir, 0, 1000)
	case .Anim_Close_Ms:  cfg.animations.close_duration = clamp(cfg.animations.close_duration + 10 * dir, 0, 1000)
	case .Op_Active:      cfg.opacity.active = step_f(cfg.opacity.active, 0.05 * d, 0.3, 1)
	case .Op_Inactive:    cfg.opacity.inactive = step_f(cfg.opacity.inactive, 0.05 * d, 0.3, 1)
	case .Op_Dim:         cfg.opacity.dim_inactive = step_f(cfg.opacity.dim_inactive, 0.05 * d, 0, 0.6)
	case .Blur_Strength:  cfg.blur.strength = clamp(cfg.blur.strength + dir, 1, 10)
	case .Corners:        cfg.corners.radius = clamp(cfg.corners.radius + 2 * dir, 0, 40)
	case .Ed_Type:        a.editor.type = (a.editor.type + dir + len(WINDOW_TYPES)) % len(WINDOW_TYPES)
	case .Ed_Opacity:
		ed := &a.editor
		ed.opacity = ed.opacity == 0 ? (dir < 0 ? 95 : 100) : ed.opacity + 5 * dir
		if ed.opacity > 100 || ed.opacity < 10 { ed.opacity = 0 }
		return
	case .Ed_Corners:
		ed := &a.editor
		ed.corners = ed.corners < 0 ? (dir < 0 ? -1 : 0) : ed.corners + 2 * dir
		ed.corners = clamp(ed.corners, -1, 40)
		return
	case:
		return
	}
	if ctrl != .Ed_Type { changed(a) }
}

@(private="file")
flip :: proc(a: ^App, ctrl: Control) {
	cfg := a.cfg
	#partial switch ctrl {
	case .Vsync:       cfg.vsync = !cfg.vsync
	case .Follow_Milk: cfg.follow_milk = !cfg.follow_milk
	case .Unredirect:  cfg.unredirect_fullscreen = !cfg.unredirect_fullscreen
	case .Shadow_On:   cfg.shadows.enabled = !cfg.shadows.enabled
	case .Anim_On:     cfg.animations.enabled = !cfg.animations.enabled
	case .Anim_Areas:  cfg.animations.workspaces = !cfg.animations.workspaces
	case .Blur_On:     cfg.blur.enabled = !cfg.blur.enabled
	case:
		return
	}
	changed(a)
}

@(private="file")
pick_choice :: proc(a: ^App, ctrl: Control, opt: int) {
	cfg := a.cfg
	#partial switch ctrl {
	case .Backend:    cfg.backend = opt == 1 ? "xrender" : "glx"
	case .Anim_Open:  cfg.animations.open = ANIMATION_KINDS[clamp(opt, 0, len(ANIMATION_KINDS) - 1)]
	case .Anim_Close: cfg.animations.close = ANIMATION_KINDS[clamp(opt, 0, len(ANIMATION_KINDS) - 1)]
	case .Ed_Match:
		a.editor.match = opt
		a.editor.focused = opt != 2
		return
	case .Ed_Shadow:  a.editor.shadow = opt; return
	case .Ed_Blur:    a.editor.blur = opt; return
	case .Ed_Animate: a.editor.animate = opt; return
	case:
		return
	}
	changed(a)
}

@(private="file")
start_stop :: proc(a: ^App) {
	if a.running {
		send_control(a.c, a.instance.owner, CONTROL_QUIT)
	} else {
		if a.save_at > 0 { save_now(a) }
		exe, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			log.errorf("Settings: cannot find the lactase binary: %v", err)
			return
		}
		p, perr := os.process_start({command = {exe, "start", "--config", a.cfg_path}})
		if perr != nil {
			log.errorf("Settings: cannot start lactase: %v", perr)
			return
		}
		// `start` forks into the background and returns at once.
		_, _ = os.process_wait(p, 3 * time.Second)
	}
	time.sleep(250 * time.Millisecond)
	refresh_status(a)
}

// Something changed: save soon (the desktop follows at once).
@(private="file")
changed :: proc(a: ^App) {
	a.save_at = tx.now() + 0.3
	a.dirty = true
}

@(private="file")
save_now :: proc(a: ^App) {
	a.save_at = 0
	a.cfg.rules = a.rules[:]
	ok, err := save(a.cfg, a.cfg_path)
	a.cfg.rules = nil
	if !ok {
		log.errorf("Settings: %s", err)
		show_notice(a, tr(a, "Não foi possível salvar", "Could not save"))
		return
	}
	if a.running {
		send_control(a.c, a.instance.owner, CONTROL_RELOAD)
		show_notice(a, tr(a, "Salvo e aplicado", "Saved and applied"))
	} else {
		show_notice(a, tr(a, "Salvo", "Saved"))
	}
}

@(private="file")
show_notice :: proc(a: ^App, s: string) {
	a.notice = s // literals only
	a.notice_until = tx.now() + 2.2
	a.dirty = true
}
