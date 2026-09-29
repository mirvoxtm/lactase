// X extensions a compositor needs and vendor:x11/xlib does not bind:
// Composite (redirection, window pixmaps, the overlay), Damage (what
// changed), XFixes regions, Render (the xrender backend and pixel formats)
// and the parts of SHAPE that milk's tx package leaves out.
package lactase

import xlib "vendor:x11/xlib"
import tx "milk:tx"

XserverRegion :: xlib.XID
Damage        :: xlib.XID
Picture       :: xlib.XID
PictFormat    :: xlib.XID

// ---------------------------------------------------------------------------
// Composite
// ---------------------------------------------------------------------------
COMPOSITE_REDIRECT_AUTOMATIC :: 0
COMPOSITE_REDIRECT_MANUAL    :: 1

foreign import xcomposite "system:Xcomposite"
@(default_calling_convention="c")
foreign xcomposite {
	XCompositeQueryExtension        :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XCompositeQueryVersion          :: proc(dpy: ^xlib.Display, major, minor: ^i32) -> i32 ---
	XCompositeRedirectSubwindows    :: proc(dpy: ^xlib.Display, window: xlib.Window, update: i32) ---
	XCompositeUnredirectSubwindows  :: proc(dpy: ^xlib.Display, window: xlib.Window, update: i32) ---
	XCompositeRedirectWindow        :: proc(dpy: ^xlib.Display, window: xlib.Window, update: i32) ---
	XCompositeUnredirectWindow      :: proc(dpy: ^xlib.Display, window: xlib.Window, update: i32) ---
	XCompositeNameWindowPixmap      :: proc(dpy: ^xlib.Display, window: xlib.Window) -> xlib.Pixmap ---
	XCompositeGetOverlayWindow      :: proc(dpy: ^xlib.Display, window: xlib.Window) -> xlib.Window ---
	XCompositeReleaseOverlayWindow  :: proc(dpy: ^xlib.Display, window: xlib.Window) ---
}

// ---------------------------------------------------------------------------
// Damage
// ---------------------------------------------------------------------------
DAMAGE_REPORT_RAW_RECTANGLES   :: 0
DAMAGE_REPORT_DELTA_RECTANGLES :: 1
DAMAGE_REPORT_BOUNDING_BOX     :: 2
DAMAGE_REPORT_NON_EMPTY        :: 3
DAMAGE_NOTIFY                  :: 0 // event offset from the extension's event base

XDamageNotifyEvent :: struct {
	type:       i32,
	serial:     uint,
	send_event: b32,
	display:    ^xlib.Display,
	drawable:   xlib.Drawable,
	damage:     Damage,
	level:      i32,
	more:       b32,
	timestamp:  xlib.Time,
	area:       xlib.XRectangle,
	geometry:   xlib.XRectangle,
}

foreign import xdamage "system:Xdamage"
@(default_calling_convention="c")
foreign xdamage {
	XDamageQueryExtension :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XDamageCreate         :: proc(dpy: ^xlib.Display, drawable: xlib.Drawable, level: i32) -> Damage ---
	XDamageDestroy        :: proc(dpy: ^xlib.Display, damage: Damage) ---
	XDamageSubtract       :: proc(dpy: ^xlib.Display, damage: Damage, repair, parts: XserverRegion) ---
}

// ---------------------------------------------------------------------------
// XFixes regions
// ---------------------------------------------------------------------------
WINDOW_REGION_BOUNDING :: 0
SHAPE_INPUT            :: 2 // ShapeInput, for XFixesSetWindowShapeRegion

foreign import xfixes "system:Xfixes"
@(default_calling_convention="c")
foreign xfixes {
	XFixesQueryExtension         :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XFixesQueryVersion           :: proc(dpy: ^xlib.Display, major, minor: ^i32) -> i32 ---
	XFixesCreateRegion           :: proc(dpy: ^xlib.Display, rects: [^]xlib.XRectangle, nrects: i32) -> XserverRegion ---
	XFixesCreateRegionFromWindow :: proc(dpy: ^xlib.Display, window: xlib.Window, kind: i32) -> XserverRegion ---
	XFixesDestroyRegion          :: proc(dpy: ^xlib.Display, region: XserverRegion) ---
	XFixesSetRegion              :: proc(dpy: ^xlib.Display, region: XserverRegion, rects: [^]xlib.XRectangle, nrects: i32) ---
	XFixesCopyRegion             :: proc(dpy: ^xlib.Display, dst, src: XserverRegion) ---
	XFixesUnionRegion            :: proc(dpy: ^xlib.Display, dst, src1, src2: XserverRegion) ---
	XFixesIntersectRegion        :: proc(dpy: ^xlib.Display, dst, src1, src2: XserverRegion) ---
	XFixesSubtractRegion         :: proc(dpy: ^xlib.Display, dst, src1, src2: XserverRegion) ---
	XFixesTranslateRegion        :: proc(dpy: ^xlib.Display, region: XserverRegion, dx, dy: i32) ---
	XFixesFetchRegion            :: proc(dpy: ^xlib.Display, region: XserverRegion, nrects: ^i32) -> [^]xlib.XRectangle ---
	XFixesSetWindowShapeRegion   :: proc(dpy: ^xlib.Display, win: xlib.Window, shape_kind: i32, x_off, y_off: i32, region: XserverRegion) ---
	XFixesSetPictureClipRegion   :: proc(dpy: ^xlib.Display, picture: Picture, clip_x, clip_y: i32, region: XserverRegion) ---
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------
PICT_OP_CLEAR :: 0
PICT_OP_SRC   :: 1
PICT_OP_OVER  :: 3

PICT_STANDARD_ARGB32 :: 0
PICT_STANDARD_RGB24  :: 1
PICT_STANDARD_A8     :: 2

CP_REPEAT         :: 1 << 0
CP_SUBWINDOW_MODE :: 1 << 8
INCLUDE_INFERIORS :: 1
REPEAT_NORMAL     :: 1
REPEAT_PAD        :: 2

XRenderDirectFormat :: struct {
	red, red_mask:     i16,
	green, green_mask: i16,
	blue, blue_mask:   i16,
	alpha, alpha_mask: i16,
}

XRenderPictFormat :: struct {
	id:       PictFormat,
	type:     i32,
	depth:    i32,
	direct:   XRenderDirectFormat,
	colormap: xlib.Colormap,
}

XRenderPictureAttributes :: struct {
	repeat:             i32,
	alpha_map:          Picture,
	alpha_x_origin:     i32,
	alpha_y_origin:     i32,
	clip_x_origin:      i32,
	clip_y_origin:      i32,
	clip_mask:          xlib.Pixmap,
	graphics_exposures: b32,
	subwindow_mode:     i32,
	poly_edge:          i32,
	poly_mode:          i32,
	dither:             xlib.Atom,
	component_alpha:    b32,
}

XRenderColor :: struct { red, green, blue, alpha: u16 }

XFixed :: i32
XTransform :: struct { m: [3][3]XFixed }

xfixed :: proc(v: f64) -> XFixed { return XFixed(v * 65536) }

foreign import xrender "system:Xrender"
@(default_calling_convention="c")
foreign xrender {
	XRenderQueryExtension      :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XRenderFindVisualFormat    :: proc(dpy: ^xlib.Display, visual: ^xlib.Visual) -> ^XRenderPictFormat ---
	XRenderFindStandardFormat  :: proc(dpy: ^xlib.Display, format: i32) -> ^XRenderPictFormat ---
	XRenderCreatePicture       :: proc(dpy: ^xlib.Display, drawable: xlib.Drawable, format: ^XRenderPictFormat, valuemask: uint, attributes: ^XRenderPictureAttributes) -> Picture ---
	XRenderChangePicture       :: proc(dpy: ^xlib.Display, picture: Picture, valuemask: uint, attributes: ^XRenderPictureAttributes) ---
	XRenderFreePicture         :: proc(dpy: ^xlib.Display, picture: Picture) ---
	XRenderComposite           :: proc(dpy: ^xlib.Display, op: i32, src, mask, dst: Picture, src_x, src_y, mask_x, mask_y, dst_x, dst_y: i32, width, height: u32) ---
	XRenderCreateSolidFill     :: proc(dpy: ^xlib.Display, color: ^XRenderColor) -> Picture ---
	XRenderFillRectangle       :: proc(dpy: ^xlib.Display, op: i32, dst: Picture, color: ^XRenderColor, x, y: i32, width, height: u32) ---
	XRenderSetPictureTransform :: proc(dpy: ^xlib.Display, picture: Picture, transform: ^XTransform) ---
	XRenderSetPictureFilter    :: proc(dpy: ^xlib.Display, picture: Picture, filter: cstring, params: [^]XFixed, nparams: i32) ---
}

// ---------------------------------------------------------------------------
// SHAPE (queries; milk's tx sets shapes)
// ---------------------------------------------------------------------------
SHAPE_BOUNDING    :: 0
SHAPE_NOTIFY_MASK :: 1
SHAPE_NOTIFY      :: 0 // event offset

XShapeEvent :: struct {
	type:       i32,
	serial:     uint,
	send_event: b32,
	display:    ^xlib.Display,
	window:     xlib.Window,
	kind:       i32,
	x, y:       i32,
	width:      u32,
	height:     u32,
	time:       xlib.Time,
	shaped:     b32,
}

foreign import xext "system:Xext"
@(default_calling_convention="c")
foreign xext {
	XShapeQueryExtension :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XShapeSelectInput    :: proc(dpy: ^xlib.Display, window: xlib.Window, mask: uint) ---
	XShapeGetRectangles  :: proc(dpy: ^xlib.Display, window: xlib.Window, kind: i32, count: ^i32, ordering: ^i32) -> [^]xlib.XRectangle ---
	XShapeQueryExtents   :: proc(dpy: ^xlib.Display, window: xlib.Window,
	                             bounding_shaped: ^b32, x_bounding, y_bounding: ^i32, w_bounding, h_bounding: ^u32,
	                             clip_shaped: ^b32, x_clip, y_clip: ^i32, w_clip, h_clip: ^u32) -> i32 ---
}

// ---------------------------------------------------------------------------
// Region helpers
// ---------------------------------------------------------------------------
Rect :: tx.Rect

region_from_rects :: proc(dpy: ^xlib.Display, rects: []Rect) -> XserverRegion {
	xr := make([]xlib.XRectangle, len(rects), context.temp_allocator)
	n := 0
	for r in rects {
		if r.w <= 0 || r.h <= 0 { continue }
		xr[n] = {i16(clamp(r.x, -32768, 32767)), i16(clamp(r.y, -32768, 32767)), u16(min(r.w, 65535)), u16(min(r.h, 65535))}
		n += 1
	}
	return XFixesCreateRegion(dpy, raw_data(xr), i32(n))
}

region_rect :: proc(dpy: ^xlib.Display, r: Rect) -> XserverRegion {
	return region_from_rects(dpy, {r})
}

region_rects :: proc(dpy: ^xlib.Display, region: XserverRegion, allocator := context.temp_allocator) -> []Rect {
	n: i32
	xr := XFixesFetchRegion(dpy, region, &n)
	if xr == nil { return nil }
	defer xlib.Free(xr)
	out := make([]Rect, int(n), allocator)
	for i in 0 ..< int(n) { out[i] = {i32(xr[i].x), i32(xr[i].y), i32(xr[i].width), i32(xr[i].height)} }
	return out
}

rect_union :: proc(a, b: Rect) -> Rect {
	if a.w <= 0 || a.h <= 0 { return b }
	if b.w <= 0 || b.h <= 0 { return a }
	x0 := min(a.x, b.x)
	y0 := min(a.y, b.y)
	x1 := max(a.x + a.w, b.x + b.w)
	y1 := max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

rect_intersects :: proc(a, b: Rect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

rect_covers :: proc(outer, inner: Rect) -> bool {
	return outer.x <= inner.x && outer.y <= inner.y && outer.x + outer.w >= inner.x + inner.w && outer.y + outer.h >= inner.y + inner.h
}
