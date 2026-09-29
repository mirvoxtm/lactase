// The settings app's look, borrowed from milk's own settings: colours, fonts
// and the Tabler icon font from milk.json; shapes composed on the CPU canvas
// (milk's tx package) and text drawn with Xft on the uploaded pixmap.
package lactase

import "core:os"
import "core:strings"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import config "milk:config"
import tx "milk:tx"

SIDEBAR_W :: 236
ROW_H     :: 56
BUTTON_H  :: 44

Theme :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning: tx.Color,
	dark:    bool,
	field:   tx.Color,
	outline: tx.Color,
	hover:   tx.Color,
	sidebar: tx.Color,
	divider: tx.Color,
	sub:     tx.Color, // secondary text
}

Icon :: enum {
	None, Adjustments, Shadow, Sparkles, Droplet, Blur, Border_Radius, List, Info, Play, Stop, Check, Trash,
	Plus, Crosshair, File_Code, Restore, Milk, X, App_Window,
}

@(rodata)
ICON_CODES := [Icon]rune{
	.None = 0, .Adjustments = 0xEA03, .Shadow = 0xEED8, .Sparkles = 0xF6D7, .Droplet = 0xEE82, .Blur = 0xEF8C,
	.Border_Radius = 0xEB7C, .List = 0xEF40, .Info = 0xEAC5, .Play = 0xED46, .Stop = 0xED4A, .Check = 0xEA5E,
	.Trash = 0xEB41, .Plus = 0xEB0B, .Crosshair = 0xEC3E, .File_Code = 0xEBD0, .Restore = 0xFAFD, .Milk = 0xEF13,
	.X = 0xEB55, .App_Window = 0xEFE6,
}

Text_Item :: struct {
	x, y, h: i32, // vertically centred in [y, y + h)
	s:       string,
	font:    ^tx.Font,
	color:   tx.Color,
}

Hit :: struct {
	r:      Rect,
	action: Action,
	arg:    int,
}

opaque :: proc(c: tx.Color) -> tx.Color { return {c.r, c.g, c.b, 255} }
mix :: proc(a, b: tx.Color, t: f32) -> tx.Color { return opaque(tx.color_mix(a, b, t)) }

luminance :: proc(c: tx.Color) -> f32 {
	return (0.2126 * f32(c.r) + 0.7152 * f32(c.g) + 0.0722 * f32(c.b)) / 255
}

make_theme :: proc(t: config.Bar_Theme) -> Theme {
	th: Theme
	th.bg = opaque(tx.color_from_hex(t.background, tx.rgb(0xF5, 0xEE, 0xE6)))
	th.fg = opaque(tx.color_from_hex(t.foreground, tx.rgb(0x3C, 0x3A, 0x38)))
	th.muted = opaque(tx.color_from_hex(t.muted, tx.rgb(0xA8, 0x9E, 0x94)))
	th.accent = opaque(tx.color_from_hex(t.accent, tx.rgb(0x4A, 0x3F, 0x35)))
	th.accent_fg = opaque(tx.color_from_hex(t.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6)))
	th.surface = opaque(tx.color_from_hex(t.surface, tx.rgb(0xE9, 0xE0, 0xD6)))
	th.warning = opaque(tx.color_from_hex(t.warning, tx.rgb(0xB5, 0x47, 0x3A)))
	th.dark = luminance(th.bg) < 0.5
	if th.dark {
		th.field = mix(th.bg, th.surface, 0.8)
		th.outline = mix(th.surface, th.muted, 0.28)
		th.hover = mix(th.surface, th.muted, 0.22)
		th.sidebar = mix(th.bg, tx.rgb(0, 0, 0), 0.18)
	} else {
		th.field = mix(th.bg, th.surface, 0.7)
		th.outline = mix(th.surface, th.muted, 0.4)
		th.hover = mix(th.surface, th.muted, 0.2)
		th.sidebar = mix(th.bg, th.surface, 0.75)
	}
	th.divider = mix(th.bg, th.muted, 0.2)
	th.sub = mix(th.fg, th.muted, 0.55)
	return th
}

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------
Fonts :: struct {
	title, h2, body, small, tiny: ^tx.Font,
	icon, icon_small, icon_big:   ^tx.Font,
}

open_fonts :: proc(c: ^tx.Connection, family, icon_file: string) -> (f: Fonts, ok: bool) {
	open :: proc(c: ^tx.Connection, family, style: string, px: i32) -> ^tx.Font {
		pattern := style == "" ? family : strings.concatenate({family, ":", style}, context.temp_allocator)
		if font, fok := tx.font_open(c, pattern, px); fok { return font }
		fallback := style == "" ? "sans" : strings.concatenate({"sans:", style}, context.temp_allocator)
		font, _ := tx.font_open(c, fallback, px)
		return font
	}
	f.title = open(c, family, "bold", 30)
	f.h2 = open(c, family, "bold", 17)
	f.body = open(c, family, "", 15)
	f.small = open(c, family, "", 13)
	f.tiny = open(c, family, "bold", 11)
	if f.title == nil || f.h2 == nil || f.body == nil || f.small == nil || f.tiny == nil { return f, false }
	if icon_file != "" && os.exists(icon_file) {
		f.icon, _ = tx.font_open_file(c, icon_file, 20)
		f.icon_small, _ = tx.font_open_file(c, icon_file, 17)
		f.icon_big, _ = tx.font_open_file(c, icon_file, 40)
		if f.icon != nil && !tx.font_has_glyph(c, f.icon, ICON_CODES[.Check]) {
			tx.font_close(c, f.icon); tx.font_close(c, f.icon_small); tx.font_close(c, f.icon_big)
			f.icon, f.icon_small, f.icon_big = nil, nil, nil
		}
	}
	return f, true
}

close_fonts :: proc(c: ^tx.Connection, f: ^Fonts) {
	for font in ([]^tx.Font{f.title, f.h2, f.body, f.small, f.tiny, f.icon, f.icon_small, f.icon_big}) {
		if font != nil { tx.font_close(c, font) }
	}
	f^ = {}
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------
text_width :: proc(a: ^App, f: ^tx.Font, s: string) -> i32 {
	if f == nil { return 0 }
	return tx.text_width(a.c, f, s)
}

text :: proc(a: ^App, f: ^tx.Font, x, y, h: i32, s: string, color: tx.Color) {
	if f == nil || s == "" { return }
	append(&a.texts, Text_Item{x = x, y = y, h = h, s = s, font = f, color = color})
}

text_centered :: proc(a: ^App, f: ^tx.Font, r: Rect, s: string, color: tx.Color) {
	if f == nil { return }
	text(a, f, r.x + (r.w - text_width(a, f, s)) / 2, r.y, r.h, s, color)
}

ellipsize :: proc(a: ^App, f: ^tx.Font, s: string, max_w: i32) -> string {
	if f == nil { return s }
	return tx.text_ellipsize(a.c, f, s, max_w)
}

icon :: proc(a: ^App, f: ^tx.Font, r: Rect, which: Icon, color: tx.Color) {
	if f == nil || which == .None { return }
	buf, n := utf8.encode_rune(ICON_CODES[which])
	text_centered(a, f, r, strings.clone(string(buf[:n]), context.temp_allocator), color)
}

fill_rounded :: proc(cv: ^tx.Canvas, r: Rect, radius: f32, c: tx.Color) {
	tx.canvas_fill_rounded_rect(cv, r, radius, c)
}

add_hit :: proc(a: ^App, r: Rect, action: Action, arg: int = 0) {
	append(&a.hits, Hit{r = r, action = action, arg = arg})
}

hovered :: proc(a: ^App, action: Action, arg: int = 0) -> bool {
	return a.hover.action == action && a.hover.arg == arg
}

hit_at :: proc(a: ^App, x, y: i32) -> Hit {
	#reverse for h in a.hits {
		if tx.rect_contains(h.r, x, y) { return h }
	}
	return {}
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------
Button_Kind :: enum { Filled, Tonal, Text }

button_width :: proc(a: ^App, label: string, lead: Icon = .None) -> i32 {
	w := text_width(a, a.fonts.h2, label) + 2 * 22
	if lead != .None && a.fonts.icon_small != nil { w += 26 }
	return w
}

button :: proc(a: ^App, cv: ^tx.Canvas, r: Rect, label: string, kind: Button_Kind, action: Action, arg: int = 0,
               lead: Icon = .None, enabled := true) {
	th := &a.theme
	hot := enabled && hovered(a, action, arg)
	fill, fg: tx.Color
	switch kind {
	case .Filled:
		fill = hot ? mix(th.accent, th.accent_fg, 0.14) : th.accent
		fg = th.accent_fg
	case .Tonal:
		fill = hot ? th.hover : th.surface
		fg = th.fg
	case .Text:
		fill = hot ? th.surface : tx.Color{}
		fg = hot ? th.fg : th.sub
	}
	if !enabled {
		fill = kind == .Text ? tx.Color{} : mix(th.surface, th.bg, 0.4)
		fg = th.muted
	}
	if fill.a > 0 { fill_rounded(cv, r, f32(r.h) / 2, fill) }
	tw := text_width(a, a.fonts.h2, label)
	inner := tw
	has_icon := lead != .None && a.fonts.icon_small != nil
	if has_icon { inner += 26 }
	x := r.x + (r.w - inner) / 2
	if has_icon {
		icon(a, a.fonts.icon_small, {x, r.y, 18, r.h}, lead, fg)
		x += 26
	}
	text(a, a.fonts.h2, x, r.y, r.h, label, fg)
	if enabled { add_hit(a, r, action, arg) }
}

// Label and description on the left of a settings row.
row_label :: proc(a: ^App, row: Rect, label, desc: string, dimmed := false, reserve: i32 = 330) {
	th := &a.theme
	fg := dimmed ? th.muted : th.fg
	sub := dimmed ? th.muted : th.sub
	if desc == "" {
		text(a, a.fonts.body, row.x, row.y, row.h, label, fg)
		return
	}
	text(a, a.fonts.body, row.x, row.y + 8, 22, label, fg)
	text(a, a.fonts.small, row.x, row.y + 29, 18, ellipsize(a, a.fonts.small, desc, row.w - reserve), sub)
}

// Room the controls take on the right of a row (so descriptions stop before them).
RESERVE_TOGGLE  :: 90
RESERVE_STEPPER :: 190
RESERVE_BUTTON  :: 190

// Start a row at *y: label, description and a divider; returns the row.
next_row :: proc(a: ^App, cv: ^tx.Canvas, c: Rect, y: ^i32, label, desc: string, dimmed := false, reserve: i32 = 330) -> Rect {
	row := Rect{c.x, y^, c.w, ROW_H}
	row_label(a, row, label, desc, dimmed, reserve)
	y^ += ROW_H
	tx.canvas_fill_rect(cv, {c.x, y^ - 1, c.w, 1}, a.theme.divider)
	return row
}

// − value + (the arrows report (control, direction) through .Step).
stepper :: proc(a: ^App, cv: ^tx.Canvas, row: Rect, value: string, ctrl: Control, enabled := true) {
	th := &a.theme
	bw: i32 = 34
	value_w: i32 = 96
	plus := Rect{row.x + row.w - bw, row.y + (row.h - bw) / 2, bw, bw}
	minus := Rect{plus.x - value_w - bw, plus.y, bw, bw}
	for b, i in ([2]Rect{minus, plus}) {
		arg := int(ctrl) * 10 + i
		fill := enabled && hovered(a, .Step, arg) ? th.hover : th.surface
		fill_rounded(cv, b, f32(bw) / 2, fill)
		text_centered(a, a.fonts.h2, b, i == 0 ? "−" : "+", enabled ? th.fg : th.muted)
		if enabled { add_hit(a, b, .Step, arg) }
	}
	text_centered(a, a.fonts.body, {minus.x + bw, row.y, value_w, row.h}, value, enabled ? th.fg : th.muted)
}

toggle :: proc(a: ^App, cv: ^tx.Canvas, row: Rect, on: bool, ctrl: Control, enabled := true) {
	th := &a.theme
	track := Rect{row.x + row.w - 50, row.y + (row.h - 28) / 2, 50, 28}
	hot := enabled && hovered(a, .Toggle, int(ctrl))
	fill := on ? th.accent : (hot ? th.hover : mix(th.surface, th.muted, 0.2))
	if !enabled { fill = on ? mix(th.accent, th.bg, 0.55) : mix(th.surface, th.bg, 0.4) }
	fill_rounded(cv, track, 14, fill)
	if !on { tx.canvas_stroke_rounded_rect(cv, track, 14, 1.5, enabled ? th.muted : mix(th.muted, th.bg, 0.5)) }
	knob: f32 = on ? 10 : 7
	kx := on ? f32(track.x + track.w - 14) : f32(track.x + 14)
	tx.canvas_fill_circle(cv, kx, f32(track.y) + 14, knob, on ? th.accent_fg : th.muted)
	if enabled { add_hit(a, {track.x - 6, track.y - 6, track.w + 12, track.h + 12}, .Toggle, int(ctrl)) }
}

// Segmented control; options report (control, option) through .Choice.
choice :: proc(a: ^App, cv: ^tx.Canvas, r: Rect, labels: []string, selected: int, ctrl: Control, enabled := true) {
	th := &a.theme
	fill_rounded(cv, r, f32(r.h) / 2, th.field)
	tx.canvas_stroke_rounded_rect(cv, r, f32(r.h) / 2, 1, th.outline)
	n := i32(len(labels))
	if n == 0 { return }
	seg_w := (r.w - 8) / n
	for label, i in labels {
		seg := Rect{r.x + 4 + i32(i) * seg_w, r.y + 4, seg_w, r.h - 8}
		arg := int(ctrl) * 100 + i
		sel := i == selected
		if sel {
			fill_rounded(cv, seg, f32(seg.h) / 2, enabled ? th.accent : mix(th.accent, th.bg, 0.55))
		} else if enabled && hovered(a, .Choice, arg) {
			fill_rounded(cv, seg, f32(seg.h) / 2, th.hover)
		}
		fg := sel ? th.accent_fg : (enabled ? th.fg : th.muted)
		text_centered(a, a.fonts.body, seg, ellipsize(a, a.fonts.body, label, seg.w - 12), fg)
		if enabled { add_hit(a, seg, .Choice, arg) }
	}
}

// A one-line text field; `focused` shows the caret.
field :: proc(a: ^App, cv: ^tx.Canvas, r: Rect, value, placeholder: string, focused: bool, action: Action, arg: int = 0) {
	th := &a.theme
	fill_rounded(cv, r, 12, th.field)
	tx.canvas_stroke_rounded_rect(cv, r, 12, focused ? 2 : 1, focused ? th.accent : th.outline)
	x := r.x + 14
	shown := value == "" ? placeholder : value
	fg := value == "" ? th.muted : th.fg
	shown = ellipsize(a, a.fonts.body, shown, r.w - 28)
	text(a, a.fonts.body, x, r.y, r.h, shown, fg)
	if focused {
		cx := x + (value == "" ? 0 : text_width(a, a.fonts.body, shown)) + 1
		tx.canvas_fill_rect(cv, {cx, r.y + 10, 2, r.h - 20}, th.accent)
	}
	add_hit(a, r, action, arg)
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------
render :: proc(a: ^App) {
	c := a.c
	cv := tx.canvas_make(a.w, a.h, context.temp_allocator)
	clear(&a.hits)
	a.texts = make([dynamic]Text_Item, context.temp_allocator)
	draw_app(a, &cv)

	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	for t in a.texts { tx.draw_text_centered_v(&ts, t.font, t.x, t.y, t.h, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	tx.set_background(c, a.win, pm)
	tx.pixmap_free(c, a.pixmap)
	a.pixmap = pm
	a.dirty = false
	tx.flush(c)

	// The layout may have moved under the pointer.
	h := hit_at(a, a.pointer.x, a.pointer.y)
	if h.action != a.hover.action || h.arg != a.hover.arg {
		a.hover = h
		a.dirty = true
	}
}
