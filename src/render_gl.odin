// The GLX renderer. Window pixmaps become textures (texture_from_pixmap);
// each frame is drawn into an off-screen scene texture: wallpaper, then per
// window its blurred background (dual Kawase), its shadow (the analytic
// Gaussian of a rounded box) and the window itself with anti-aliased
// corners. The scene is copied to the overlay window and swapped (vsync).
package lactase

import "core:log"
import "core:strings"
import gl "vendor:OpenGL"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

MAX_BLUR_LEVELS :: 6

GL_Win :: struct {
	glx_pixmap: GLXDrawable,
	tex:        u32,
	flip:       bool,
	failed:     bool, // no usable FBConfig for this window's depth
}

@(private="file")
Tfp_Config :: struct {
	fbc:  GLXFBConfig,
	flip: bool, // texture rows run bottom-up
	rgba: bool,
	ok:   bool,
}

@(private="file")
Target :: struct { fbo, tex: u32, w, h: i32, valid: bool }

// The wallpaper: the root pixmap's pixels in a texture of ours. They are
// read once per change (XGetImage): the setter may free its pixmap at any
// time, and pixmaps created by clients cannot always be bound as textures
// (Xwayland's glamor refuses to export some).
@(private="file")
Wall :: struct {
	tex:   u32,
	valid: bool,
}

@(private="file")
Program :: struct {
	id: u32,
	u:  map[string]i32,
}

GL :: struct {
	ctx:         GLXContext,
	glx_win:     GLXDrawable,
	tfp24:       Tfp_Config,
	tfp32:       Tfp_Config,
	bind_tex:    PFN_glXBindTexImageEXT,
	release_tex: PFN_glXReleaseTexImageEXT,
	vao, vbo:    u32,
	p_win:       Program,
	p_shadow:    Program,
	p_down:      Program,
	p_up:        Program,
	p_blur:      Program, // last upsample, masked to the window
	scene:       Target,
	levels:      [MAX_BLUR_LEVELS + 1]Target, // 1.. used; level 0 is the scene
	wall:        Wall,
	wall_prev:   Wall,
	w, h:        i32,
	verts:       [dynamic]f32,
	wall_size:   [2]i32,
}

// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------
@(private="file")
VS_SCREEN :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_local;
uniform vec2 u_screen;
out vec2 v_local;
void main() {
	v_local = a_local;
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
}
`

@(private="file")
VS_LEVEL :: `#version 330 core
layout(location = 0) in vec2 a_pos;
uniform vec2 u_target;
void main() {
	gl_Position = vec4(a_pos / u_target * 2.0 - 1.0, 0.0, 1.0);
}
`

// Coverage of a pixel centre p in a (0,0)-(size) box with rounded corners.
// The anti-aliasing ramp lies inside the arc, so windows already cut to a
// rounded SHAPE never show pixels from outside their shape.
@(private="file")
GLSL_COVERAGE :: `
float coverage(vec2 p, vec2 size, float r) {
	if (p.x < 0.0 || p.y < 0.0 || p.x > size.x || p.y > size.y) return 0.0;
	if (r <= 0.0) return 1.0;
	vec2 q = min(p, size - p);
	if (q.x >= r || q.y >= r) return 1.0;
	return clamp(r - length(vec2(r) - q), 0.0, 1.0);
}
`

@(private="file")
FS_WINDOW :: `#version 330 core
in vec2 v_local;
out vec4 frag;
uniform sampler2D u_tex;
uniform vec2 u_size;
uniform bool u_flip;
uniform bool u_opaque;
uniform float u_alpha;
uniform float u_dim;
uniform float u_radius;
` + GLSL_COVERAGE + `
void main() {
	vec2 uv = v_local / u_size;
	if (u_flip) uv.y = 1.0 - uv.y;
	vec4 c = texture(u_tex, uv);
	if (u_opaque) c.a = 1.0;
	c.rgb *= 1.0 - u_dim;
	frag = c * (u_alpha * coverage(v_local, u_size, u_radius));
}
`

// Evan Wallace's closed form for the shadow of a rounded box (erf along x,
// four samples of the Gaussian along y), minus the part under the window.
@(private="file")
FS_SHADOW :: `#version 330 core
in vec2 v_local;
out vec4 frag;
uniform vec4 u_box;
uniform vec4 u_win;
uniform float u_sigma;
uniform float u_radius;
uniform vec4 u_color;
` + GLSL_COVERAGE + `
float gaussian(float x, float sigma) {
	return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746 * sigma);
}
vec2 erf2(vec2 x) {
	vec2 s = sign(x), a = abs(x);
	x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
	x *= x;
	return s - s / (x * x);
}
float shadow_x(float x, float y, float sigma, float corner, vec2 half_size) {
	float delta = min(half_size.y - corner - abs(y), 0.0);
	float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
	vec2 integral = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (0.7071067811 / sigma));
	return integral.y - integral.x;
}
float box_shadow(vec2 lower, vec2 upper, vec2 point, float sigma, float corner) {
	vec2 center = (lower + upper) * 0.5;
	vec2 half_size = (upper - lower) * 0.5;
	point -= center;
	float low = point.y - half_size.y;
	float high = point.y + half_size.y;
	float start = clamp(-3.0 * sigma, low, high);
	float end = clamp(3.0 * sigma, low, high);
	float step = (end - start) / 4.0;
	float y = start + step * 0.5;
	float value = 0.0;
	for (int i = 0; i < 4; i++) {
		value += shadow_x(point.x, point.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
		y += step;
	}
	return value;
}
void main() {
	float a = box_shadow(u_box.xy, u_box.zw, v_local, u_sigma, u_radius);
	a *= 1.0 - coverage(v_local - u_win.xy, u_win.zw - u_win.xy, u_radius);
	frag = vec4(u_color.rgb, 1.0) * (u_color.a * a);
}
`

@(private="file")
FS_DOWN :: `#version 330 core
out vec4 frag;
uniform sampler2D u_tex;
uniform vec2 u_target;
uniform float u_offset;
void main() {
	vec2 uv = gl_FragCoord.xy / u_target;
	vec2 hp = 0.5 / u_target * u_offset;
	vec4 sum = texture(u_tex, uv) * 4.0;
	sum += texture(u_tex, uv - hp);
	sum += texture(u_tex, uv + hp);
	sum += texture(u_tex, uv + vec2(hp.x, -hp.y));
	sum += texture(u_tex, uv - vec2(hp.x, -hp.y));
	frag = sum / 8.0;
}
`

@(private="file")
GLSL_UP :: `
vec4 upsample(sampler2D tex, vec2 uv, vec2 hp) {
	vec4 sum = texture(tex, uv + vec2(-hp.x * 2.0, 0.0));
	sum += texture(tex, uv + vec2(-hp.x, hp.y)) * 2.0;
	sum += texture(tex, uv + vec2(0.0, hp.y * 2.0));
	sum += texture(tex, uv + vec2(hp.x, hp.y)) * 2.0;
	sum += texture(tex, uv + vec2(hp.x * 2.0, 0.0));
	sum += texture(tex, uv + vec2(hp.x, -hp.y)) * 2.0;
	sum += texture(tex, uv + vec2(0.0, -hp.y * 2.0));
	sum += texture(tex, uv + vec2(-hp.x, -hp.y)) * 2.0;
	return sum / 12.0;
}
`

@(private="file")
FS_UP :: `#version 330 core
out vec4 frag;
uniform sampler2D u_tex;
uniform vec2 u_target;
uniform float u_offset;
` + GLSL_UP + `
void main() {
	frag = upsample(u_tex, gl_FragCoord.xy / u_target, 0.5 / u_target * u_offset);
}
`

@(private="file")
FS_BLUR :: `#version 330 core
in vec2 v_local;
out vec4 frag;
uniform sampler2D u_tex;
uniform vec2 u_target;
uniform float u_offset;
uniform vec2 u_size;
uniform float u_radius;
uniform float u_alpha;
` + GLSL_COVERAGE + GLSL_UP + `
void main() {
	vec4 c = upsample(u_tex, gl_FragCoord.xy / u_target, 0.5 / u_target * u_offset);
	frag = vec4(c.rgb, 1.0) * (u_alpha * coverage(v_local, u_size, u_radius));
}
`

@(private="file")
make_program :: proc(vs, fs: string, uniforms: []string) -> (p: Program, ok: bool) {
	id, lok := gl.load_shaders_source(vs, fs)
	if !lok {
		log.error("GLX: a shader failed to compile")
		return {}, false
	}
	p.id = id
	p.u = make(map[string]i32)
	for name in uniforms {
		p.u[name] = gl.GetUniformLocation(id, strings.clone_to_cstring(name, context.temp_allocator))
	}
	return p, true
}

@(private="file")
delete_program :: proc(p: ^Program) {
	if p.id != 0 { gl.DeleteProgram(p.id) }
	delete(p.u)
	p^ = {}
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
@(private="file")
fb_attrib :: proc(dpy: ^xlib.Display, fbc: GLXFBConfig, attr: i32) -> i32 {
	v: i32
	if glXGetFBConfigAttrib(dpy, fbc, attr, &v) != 0 { return 0 }
	return v
}

// An FBConfig that can turn pixmaps of `depth` into 2D textures.
@(private="file")
choose_tfp :: proc(dpy: ^xlib.Display, screen, depth: i32) -> Tfp_Config {
	n: i32
	configs := glXGetFBConfigs(dpy, screen, &n)
	if configs == nil { return {} }
	defer xlib.Free(configs)
	for i in 0 ..< int(n) {
		fbc := configs[i]
		vi := glXGetVisualFromFBConfig(dpy, fbc)
		if vi == nil { continue }
		vdepth := vi.depth
		xlib.Free(vi)
		if vdepth != depth { continue }
		if fb_attrib(dpy, fbc, GLX_DRAWABLE_TYPE) & GLX_PIXMAP_BIT == 0 { continue }
		if fb_attrib(dpy, fbc, GLX_BIND_TO_TEXTURE_TARGETS_EXT) & GLX_TEXTURE_2D_BIT_EXT == 0 { continue }
		rgba := fb_attrib(dpy, fbc, GLX_BIND_TO_TEXTURE_RGBA_EXT) != 0
		rgb := fb_attrib(dpy, fbc, GLX_BIND_TO_TEXTURE_RGB_EXT) != 0
		if depth == 32 && !rgba { continue }
		if !rgb && !rgba { continue }
		return {fbc = fbc, flip = fb_attrib(dpy, fbc, GLX_Y_INVERTED_EXT) == 0, rgba = depth == 32 || !rgb, ok = true}
	}
	return {}
}

// The FBConfig of the overlay window's visual (double-buffered RGBA).
@(private="file")
choose_window_config :: proc(dpy: ^xlib.Display, screen: i32, visual: xlib.VisualID) -> (GLXFBConfig, bool) {
	n: i32
	configs := glXGetFBConfigs(dpy, screen, &n)
	if configs == nil { return nil, false }
	defer xlib.Free(configs)
	for i in 0 ..< int(n) {
		fbc := configs[i]
		if xlib.VisualID(fb_attrib(dpy, fbc, GLX_VISUAL_ID)) != visual { continue }
		if fb_attrib(dpy, fbc, GLX_DRAWABLE_TYPE) & GLX_WINDOW_BIT == 0 { continue }
		if fb_attrib(dpy, fbc, GLX_RENDER_TYPE) & GLX_RGBA_BIT == 0 { continue }
		if fb_attrib(dpy, fbc, GLX_DOUBLEBUFFER) == 0 { continue }
		return fbc, true
	}
	return nil, false
}

gl_init :: proc(comp: ^Comp) -> bool {
	dpy := comp.dpy
	screen := comp.c.screen
	eb, evb, major, minor: i32
	if !glXQueryExtension(dpy, &eb, &evb) {
		log.warn("GLX: the X server has no GLX extension")
		return false
	}
	glXQueryVersion(dpy, &major, &minor)
	if major < 1 || (major == 1 && minor < 3) {
		log.warnf("GLX: version %d.%d is too old (1.3 needed)", major, minor)
		return false
	}
	exts := string(glXQueryExtensionsString(dpy, screen))
	if !strings.contains(exts, "GLX_EXT_texture_from_pixmap") {
		log.warn("GLX: no GLX_EXT_texture_from_pixmap")
		return false
	}
	g := new(GL)
	g.bind_tex = PFN_glXBindTexImageEXT(glXGetProcAddressARB("glXBindTexImageEXT"))
	g.release_tex = PFN_glXReleaseTexImageEXT(glXGetProcAddressARB("glXReleaseTexImageEXT"))
	if g.bind_tex == nil || g.release_tex == nil {
		log.warn("GLX: texture_from_pixmap entry points are missing")
		free(g)
		return false
	}
	g.tfp24 = choose_tfp(dpy, screen, 24)
	g.tfp32 = choose_tfp(dpy, screen, 32)
	if !g.tfp24.ok {
		log.warn("GLX: no FBConfig binds depth-24 pixmaps to textures")
		free(g)
		return false
	}

	attrs: xlib.XWindowAttributes
	xlib.GetWindowAttributes(dpy, comp.overlay, &attrs)
	fbc, found := choose_window_config(dpy, screen, xlib.VisualIDFromVisual(attrs.visual))
	if !found {
		log.warn("GLX: no FBConfig matches the overlay window's visual")
		free(g)
		return false
	}
	if create := PFN_glXCreateContextAttribsARB(glXGetProcAddressARB("glXCreateContextAttribsARB")); create != nil {
		ctx_attrs := [?]i32{GLX_CONTEXT_MAJOR_VERSION_ARB, 3, GLX_CONTEXT_MINOR_VERSION_ARB, 3,
		                    GLX_CONTEXT_PROFILE_MASK_ARB, GLX_CONTEXT_CORE_PROFILE_BIT_ARB, 0}
		g.ctx = create(dpy, fbc, nil, true, &ctx_attrs[0])
	}
	if g.ctx == nil { g.ctx = glXCreateNewContext(dpy, fbc, GLX_RGBA_TYPE, nil, true) }
	if g.ctx == nil {
		log.warn("GLX: cannot create an OpenGL context")
		free(g)
		return false
	}
	g.glx_win = glXCreateWindow(dpy, fbc, comp.overlay, nil)
	if g.glx_win == 0 || !glXMakeContextCurrent(dpy, g.glx_win, g.glx_win, g.ctx) {
		log.warn("GLX: cannot use the overlay window")
		if g.glx_win != 0 { glXDestroyWindow(dpy, g.glx_win) }
		glXDestroyContext(dpy, g.ctx)
		free(g)
		return false
	}
	gl.load_up_to(3, 3, gl_set_proc_address)
	comp.gl = g

	// Vsync.
	interval: i32 = comp.cfg.vsync ? 1 : 0
	if strings.contains(exts, "GLX_EXT_swap_control") {
		if f := PFN_glXSwapIntervalEXT(glXGetProcAddressARB("glXSwapIntervalEXT")); f != nil { f(dpy, g.glx_win, interval) }
	} else if strings.contains(exts, "GLX_MESA_swap_control") {
		if f := PFN_glXSwapIntervalMESA(glXGetProcAddressARB("glXSwapIntervalMESA")); f != nil { f(u32(interval)) }
	}

	ok := true
	g.p_win, ok = make_program(VS_SCREEN, FS_WINDOW, {"u_screen", "u_tex", "u_size", "u_flip", "u_opaque", "u_alpha", "u_dim", "u_radius"})
	if ok { g.p_shadow, ok = make_program(VS_SCREEN, FS_SHADOW, {"u_screen", "u_box", "u_win", "u_sigma", "u_radius", "u_color"}) }
	if ok { g.p_down, ok = make_program(VS_LEVEL, FS_DOWN, {"u_target", "u_tex", "u_offset"}) }
	if ok { g.p_up, ok = make_program(VS_LEVEL, FS_UP, {"u_target", "u_tex", "u_offset"}) }
	if ok { g.p_blur, ok = make_program(VS_SCREEN, FS_BLUR, {"u_screen", "u_tex", "u_target", "u_offset", "u_size", "u_radius", "u_alpha"}) }
	if !ok {
		gl_shutdown(comp)
		return false
	}
	gl.GenVertexArrays(1, &g.vao)
	gl.GenBuffers(1, &g.vbo)
	gl.BindVertexArray(g.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
	gl.EnableVertexAttribArray(0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 4 * size_of(f32), 0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 4 * size_of(f32), 2 * size_of(f32))
	gl_resize(comp)
	comp.root_changed = true

	renderer := gl.GetString(gl.RENDERER)
	log.infof("GLX renderer: %s (vsync %s)", renderer, comp.cfg.vsync ? "on" : "off")
	return true
}

gl_shutdown :: proc(comp: ^Comp) {
	g := comp.gl
	if g == nil { return }
	for w in comp.wins { gl_release_window(comp, w) }
	free_target(&g.scene)
	free_wall(comp, &g.wall)
	free_wall(comp, &g.wall_prev)
	for &lv in g.levels { free_target(&lv) }
	delete_program(&g.p_win)
	delete_program(&g.p_shadow)
	delete_program(&g.p_down)
	delete_program(&g.p_up)
	delete_program(&g.p_blur)
	if g.vbo != 0 { gl.DeleteBuffers(1, &g.vbo) }
	if g.vao != 0 { gl.DeleteVertexArrays(1, &g.vao) }
	delete(g.verts)
	glXMakeContextCurrent(comp.dpy, 0, 0, nil)
	if g.glx_win != 0 { glXDestroyWindow(comp.dpy, g.glx_win) }
	if g.ctx != nil { glXDestroyContext(comp.dpy, g.ctx) }
	free(g)
	comp.gl = nil
}

@(private="file")
free_target :: proc(t: ^Target) {
	if t.fbo != 0 { gl.DeleteFramebuffers(1, &t.fbo) }
	if t.tex != 0 { gl.DeleteTextures(1, &t.tex) }
	t^ = {}
}

@(private="file")
make_target :: proc(t: ^Target, w, h: i32) {
	free_target(t)
	t.w, t.h = max(w, 1), max(h, 1)
	gl.GenTextures(1, &t.tex)
	gl.BindTexture(gl.TEXTURE_2D, t.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, t.w, t.h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.GenFramebuffers(1, &t.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, t.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.tex, 0)
	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE { log.warn("GLX: an off-screen buffer is incomplete") }
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

gl_resize :: proc(comp: ^Comp) {
	g := comp.gl
	if g == nil { return }
	g.w, g.h = comp.screen.w, comp.screen.h
	make_target(&g.scene, g.w, g.h)
	for i in 1 ..= MAX_BLUR_LEVELS { make_target(&g.levels[i], g.w >> u32(i), g.h >> u32(i)) }
	free_wall(comp, &g.wall_prev)
	free_wall(comp, &g.wall)
	comp.root_changed = true
}

// ---------------------------------------------------------------------------
// Window textures
// ---------------------------------------------------------------------------
gl_release_window :: proc(comp: ^Comp, w: ^Win) {
	g := comp.gl
	if g == nil { return }
	if w.gl.tex != 0 {
		g.release_tex(comp.dpy, w.gl.glx_pixmap, GLX_FRONT_LEFT_EXT)
		gl.DeleteTextures(1, &w.gl.tex)
	}
	if w.gl.glx_pixmap != 0 { glXDestroyPixmap(comp.dpy, w.gl.glx_pixmap) }
	w.gl = {}
}

@(private="file")
bind_pixmap :: proc(comp: ^Comp, pm: xlib.Pixmap, depth: i32) -> (glx_pixmap: GLXDrawable, tex: u32, flip: bool, ok: bool) {
	g := comp.gl
	cfg := depth == 32 ? g.tfp32 : g.tfp24
	if !cfg.ok || (depth != 24 && depth != 32) { return }
	attribs := [?]i32{GLX_TEXTURE_TARGET_EXT, GLX_TEXTURE_2D_EXT,
	                  GLX_TEXTURE_FORMAT_EXT, cfg.rgba ? GLX_TEXTURE_FORMAT_RGBA_EXT : GLX_TEXTURE_FORMAT_RGB_EXT, 0}
	glx_pixmap = glXCreatePixmap(comp.dpy, cfg.fbc, pm, &attribs[0])
	if glx_pixmap == 0 { return }
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	g.bind_tex(comp.dpy, glx_pixmap, GLX_FRONT_LEFT_EXT, nil)
	return glx_pixmap, tex, cfg.flip, true
}

// The window's texture, bound (and refreshed when its contents changed).
@(private="file")
window_texture :: proc(comp: ^Comp, w: ^Win) -> bool {
	g := comp.gl
	if w.gl.failed { return false }
	if w.gl.tex == 0 {
		depth := w.depth
		if w.argb { depth = 32 } else if depth != 32 { depth = 24 }
		pm, tex, flip, ok := bind_pixmap(comp, w.pixmap, depth)
		if !ok {
			if pm != 0 { glXDestroyPixmap(comp.dpy, pm) }
			w.gl.failed = true
			log.debugf("GLX: cannot bind window 0x%x (depth %d)", w.id, w.depth)
			return false
		}
		w.gl = {glx_pixmap = pm, tex = tex, flip = flip}
		return true
	}
	gl.BindTexture(gl.TEXTURE_2D, w.gl.tex)
	if w.damaged {
		g.release_tex(comp.dpy, w.gl.glx_pixmap, GLX_FRONT_LEFT_EXT)
		g.bind_tex(comp.dpy, w.gl.glx_pixmap, GLX_FRONT_LEFT_EXT, nil)
	}
	return true
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------
@(private="file")
push_quad :: proc(g: ^GL, p0, p1, p2, p3: [2]f32, l0, l1: [2]f32) {
	// p0 top-left, p1 top-right, p2 bottom-right, p3 bottom-left; l0/l1 local corners.
	v :: proc(g: ^GL, p: [2]f32, lx, ly: f32) { append(&g.verts, p.x, p.y, lx, ly) }
	v(g, p0, l0.x, l0.y); v(g, p1, l1.x, l0.y); v(g, p2, l1.x, l1.y)
	v(g, p0, l0.x, l0.y); v(g, p2, l1.x, l1.y); v(g, p3, l0.x, l1.y)
}

@(private="file")
flush_verts :: proc(g: ^GL) {
	if len(g.verts) == 0 { return }
	gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(g.verts) * size_of(f32), raw_data(g.verts), gl.STREAM_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(g.verts) / 4))
	clear(&g.verts)
}

// Quads of a window in screen space (its shape rectangles, or the whole box).
@(private="file")
push_window_geometry :: proc(g: ^GL, d: ^Draw) {
	w := d.w
	if w.shaped && len(w.shape_rects) > 0 {
		for r in w.shape_rects {
			x0, y0, x1, y1 := f32(r.x), f32(r.y), f32(r.x + r.w), f32(r.y + r.h)
			push_quad(g, draw_point(d, x0, y0), draw_point(d, x1, y0), draw_point(d, x1, y1), draw_point(d, x0, y1), {x0, y0}, {x1, y1})
		}
		return
	}
	x1, y1 := f32(d.rect.w), f32(d.rect.h)
	push_quad(g, draw_point(d, 0, 0), draw_point(d, x1, 0), draw_point(d, x1, y1), draw_point(d, 0, y1), {0, 0}, {x1, y1})
}

@(private="file")
use_screen_program :: proc(g: ^GL, p: ^Program) {
	gl.UseProgram(p.id)
	gl.Uniform2f(p.u["u_screen"], f32(g.w), f32(g.h))
}

@(private="file")
draw_wall :: proc(g: ^GL, wall: ^Wall, alpha: f32) {
	use_screen_program(g, &g.p_win)
	p := &g.p_win
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, wall.tex)
	gl.Uniform1i(p.u["u_tex"], 0)
	gl.Uniform2f(p.u["u_size"], f32(g.wall_size.x), f32(g.wall_size.y))
	gl.Uniform1i(p.u["u_flip"], 0)
	gl.Uniform1i(p.u["u_opaque"], 1)
	gl.Uniform1f(p.u["u_alpha"], alpha)
	gl.Uniform1f(p.u["u_dim"], 0)
	gl.Uniform1f(p.u["u_radius"], 0)
	w, h := f32(g.wall_size.x), f32(g.wall_size.y)
	push_quad(g, {0, 0}, {w, 0}, {w, h}, {0, h}, {0, 0}, {w, h})
	flush_verts(g)
}

@(private="file")
free_wall :: proc(comp: ^Comp, wall: ^Wall) {
	if wall.tex != 0 { gl.DeleteTextures(1, &wall.tex) }
	wall^ = {}
}

// A new root pixmap: read it, and keep the previous one for the cross-fade.
@(private="file")
update_wallpaper :: proc(comp: ^Comp) {
	g := comp.gl
	comp.root_changed = false
	free_wall(comp, &g.wall_prev)
	g.wall_prev = g.wall
	g.wall = {}
	comp.wall_fade = g.wall_prev.valid && wallpaper_fade_seconds(comp) > 0 ? 1 : 0
	pm, pw, ph, _, ok := root_background(comp)
	if !ok { return }
	w, h := min(pw, g.w), min(ph, g.h)
	img := xlib.GetImage(comp.dpy, pm, 0, 0, u32(w), u32(h), ~uint(0), .ZPixmap)
	if img == nil { return }
	defer xlib.DestroyImage(img)
	if img.bits_per_pixel != 32 {
		log.warnf("GLX: unsupported wallpaper format (%d bits per pixel)", img.bits_per_pixel)
		return
	}
	gl.GenTextures(1, &g.wall.tex)
	gl.BindTexture(gl.TEXTURE_2D, g.wall.tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, img.bytes_per_line / 4)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.BGRA, gl.UNSIGNED_BYTE, img.data)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	g.wall.valid = true
	g.wall_size = {w, h}
}

// Blur strength → Kawase iterations and sample offset.
@(private="file")
BLUR_TABLE := [10][2]f32{{1, 1.5}, {1, 2.5}, {2, 2.0}, {2, 3.0}, {3, 2.5}, {3, 3.25}, {4, 2.75}, {4, 3.5}, {5, 3.0}, {5, 3.75}}

// Blur what is behind d into the scene, inside d's (rounded) outline.
@(private="file")
draw_blur :: proc(comp: ^Comp, d: ^Draw) {
	g := comp.gl
	entry := BLUR_TABLE[clamp(comp.cfg.blur.strength, 1, 10) - 1]
	iters := int(entry[0])
	offset := entry[1]
	for iters > 1 && (g.w >> u32(iters) < 2 || g.h >> u32(iters) < 2) { iters -= 1 }
	bounds := draw_bounds(d)
	margin := i32(offset * f32(i32(1) << u32(iters + 1))) + 4
	region, ok := tx.rect_intersect({bounds.x - margin, bounds.y - margin, bounds.w + 2 * margin, bounds.h + 2 * margin}, comp.screen)
	if !ok { return }
	// Bottom-up coordinates for the off-screen levels.
	rx0 := region.x
	ry0 := g.h - (region.y + region.h)
	rx1 := region.x + region.w
	ry1 := g.h - region.y

	gl.Disable(gl.BLEND)
	gl.Enable(gl.SCISSOR_TEST)
	level_pass :: proc(g: ^GL, p: ^Program, src: u32, dst: ^Target, x0, y0, x1, y1: i32, offset: f32) {
		gl.BindFramebuffer(gl.FRAMEBUFFER, dst.fbo)
		gl.Viewport(0, 0, dst.w, dst.h)
		gl.Scissor(x0, y0, max(x1 - x0, 1), max(y1 - y0, 1))
		gl.UseProgram(p.id)
		gl.Uniform2f(p.u["u_target"], f32(dst.w), f32(dst.h))
		gl.Uniform1f(p.u["u_offset"], offset)
		gl.Uniform1i(p.u["u_tex"], 0)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, src)
		fx0, fy0, fx1, fy1 := f32(x0), f32(y0), f32(x1), f32(y1)
		push_quad(g, {fx0, fy0}, {fx1, fy0}, {fx1, fy1}, {fx0, fy1}, {0, 0}, {0, 0})
		flush_verts(g)
	}
	src := g.scene.tex
	for i in 1 ..= iters {
		s := u32(i)
		level_pass(g, &g.p_down, src, &g.levels[i], rx0 >> s, ry0 >> s, (rx1 >> s) + 1, (ry1 >> s) + 1, offset)
		src = g.levels[i].tex
	}
	for i := iters; i > 1; i -= 1 {
		s := u32(i - 1)
		level_pass(g, &g.p_up, g.levels[i].tex, &g.levels[i - 1], rx0 >> s, ry0 >> s, (rx1 >> s) + 1, (ry1 >> s) + 1, offset)
	}
	gl.Disable(gl.SCISSOR_TEST)

	// Last upsample straight into the scene, masked to the window.
	gl.BindFramebuffer(gl.FRAMEBUFFER, g.scene.fbo)
	gl.Viewport(0, 0, g.w, g.h)
	gl.Enable(gl.BLEND)
	use_screen_program(g, &g.p_blur)
	p := &g.p_blur
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, g.levels[1].tex)
	gl.Uniform1i(p.u["u_tex"], 0)
	gl.Uniform2f(p.u["u_target"], f32(g.w), f32(g.h))
	gl.Uniform1f(p.u["u_offset"], offset)
	gl.Uniform2f(p.u["u_size"], f32(d.rect.w), f32(d.rect.h))
	gl.Uniform1f(p.u["u_radius"], d.radius)
	gl.Uniform1f(p.u["u_alpha"], d.vis)
	push_window_geometry(g, d)
	flush_verts(g)
}

@(private="file")
draw_shadow :: proc(comp: ^Comp, d: ^Draw, color: tx.Color) {
	g := comp.gl
	s := comp.cfg.shadows
	sigma := shadow_sigma(comp) * d.scale
	box := draw_box(d)
	win := box
	ox, oy := f32(s.offset_x) * d.scale, f32(s.offset_y) * d.scale
	box = {box[0] + ox, box[1] + oy, box[2] + ox, box[3] + oy}
	ext := 3 * sigma + 2
	x0, y0, x1, y1 := box[0] - ext, box[1] - ext, box[2] + ext, box[3] + ext
	use_screen_program(g, &g.p_shadow)
	p := &g.p_shadow
	gl.Uniform4f(p.u["u_box"], box[0], box[1], box[2], box[3])
	gl.Uniform4f(p.u["u_win"], win[0], win[1], win[2], win[3])
	gl.Uniform1f(p.u["u_sigma"], sigma)
	gl.Uniform1f(p.u["u_radius"], d.radius * d.scale)
	alpha := f32(s.opacity) * d.alpha
	gl.Uniform4f(p.u["u_color"], f32(color.r) / 255 * alpha, f32(color.g) / 255 * alpha, f32(color.b) / 255 * alpha, alpha)
	push_quad(g, {x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}, {x0, y0}, {x1, y1})
	flush_verts(g)
}

@(private="file")
draw_window :: proc(comp: ^Comp, d: ^Draw) {
	g := comp.gl
	w := d.w
	if !window_texture(comp, w) { return }
	use_screen_program(g, &g.p_win)
	p := &g.p_win
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, w.gl.tex)
	gl.Uniform1i(p.u["u_tex"], 0)
	gl.Uniform2f(p.u["u_size"], f32(d.rect.w), f32(d.rect.h))
	gl.Uniform1i(p.u["u_flip"], i32(w.gl.flip))
	gl.Uniform1i(p.u["u_opaque"], i32(!w.argb))
	gl.Uniform1f(p.u["u_alpha"], d.alpha)
	gl.Uniform1f(p.u["u_dim"], d.dim)
	gl.Uniform1f(p.u["u_radius"], d.radius)
	push_window_geometry(g, d)
	flush_verts(g)
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------
gl_paint :: proc(comp: ^Comp, now: f64) {
	g := comp.gl
	if comp.root_changed { update_wallpaper(comp) }
	draws, first := build_draws(comp)

	gl.BindVertexArray(g.vao)
	gl.BindFramebuffer(gl.FRAMEBUFFER, g.scene.fbo)
	gl.Viewport(0, 0, g.w, g.h)
	gl.Disable(gl.SCISSOR_TEST)
	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	if first == 0 {
		if g.wall.valid { draw_wall(g, &g.wall, 1) }
		if comp.wall_fade > 0 && g.wall_prev.valid { draw_wall(g, &g.wall_prev, f32(ease(comp.wall_fade))) }
	}
	color := tx.color_from_hex(comp.cfg.shadows.color)
	for i in first ..< len(draws) {
		d := &draws[i]
		if d.blur { draw_blur(comp, d) }
		if d.shadow { draw_shadow(comp, d, color) }
		draw_window(comp, d)
	}

	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, g.scene.fbo)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	gl.BlitFramebuffer(0, 0, g.w, g.h, 0, 0, g.w, g.h, gl.COLOR_BUFFER_BIT, gl.NEAREST)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	glXSwapBuffers(comp.dpy, g.glx_win)
}
