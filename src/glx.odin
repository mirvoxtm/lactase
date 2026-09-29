// GLX: the parts a compositor uses (FBConfigs, contexts, window and pixmap
// drawables) plus the extension entry points fetched at run time
// (texture_from_pixmap, swap control, context attributes).
package lactase

import xlib "vendor:x11/xlib"

GLXFBConfig :: rawptr
GLXContext  :: rawptr
GLXDrawable :: xlib.XID

GLX_BUFFER_SIZE                 :: 2
GLX_DOUBLEBUFFER                :: 5
GLX_RED_SIZE                    :: 8
GLX_GREEN_SIZE                  :: 9
GLX_BLUE_SIZE                   :: 10
GLX_ALPHA_SIZE                  :: 11
GLX_DEPTH_SIZE                  :: 12
GLX_STENCIL_SIZE                :: 13
GLX_CONFIG_CAVEAT               :: 0x20
GLX_NONE                        :: 0x8000
GLX_VISUAL_ID                   :: 0x800B
GLX_DRAWABLE_TYPE               :: 0x8010
GLX_RENDER_TYPE                 :: 0x8011
GLX_X_RENDERABLE                :: 0x8012
GLX_RGBA_TYPE                   :: 0x8014
GLX_WINDOW_BIT                  :: 0x1
GLX_PIXMAP_BIT                  :: 0x2
GLX_RGBA_BIT                    :: 0x1
GLX_BIND_TO_TEXTURE_RGB_EXT     :: 0x20D0
GLX_BIND_TO_TEXTURE_RGBA_EXT    :: 0x20D1
GLX_BIND_TO_TEXTURE_TARGETS_EXT :: 0x20D3
GLX_Y_INVERTED_EXT              :: 0x20D4
GLX_TEXTURE_FORMAT_EXT          :: 0x20D5
GLX_TEXTURE_TARGET_EXT          :: 0x20D6
GLX_TEXTURE_FORMAT_RGB_EXT      :: 0x20D9
GLX_TEXTURE_FORMAT_RGBA_EXT     :: 0x20DA
GLX_TEXTURE_2D_BIT_EXT          :: 0x2
GLX_TEXTURE_2D_EXT              :: 0x20DC
GLX_FRONT_LEFT_EXT              :: 0x20DE
GLX_CONTEXT_MAJOR_VERSION_ARB   :: 0x2091
GLX_CONTEXT_MINOR_VERSION_ARB   :: 0x2092
GLX_CONTEXT_PROFILE_MASK_ARB    :: 0x9126
GLX_CONTEXT_CORE_PROFILE_BIT_ARB :: 0x1

foreign import libgl "system:GL"
@(default_calling_convention="c")
foreign libgl {
	glXQueryExtension         :: proc(dpy: ^xlib.Display, error_base, event_base: ^i32) -> b32 ---
	glXQueryVersion           :: proc(dpy: ^xlib.Display, major, minor: ^i32) -> b32 ---
	glXQueryExtensionsString  :: proc(dpy: ^xlib.Display, screen: i32) -> cstring ---
	glXGetFBConfigs           :: proc(dpy: ^xlib.Display, screen: i32, nelements: ^i32) -> [^]GLXFBConfig ---
	glXGetFBConfigAttrib      :: proc(dpy: ^xlib.Display, config: GLXFBConfig, attribute: i32, value: ^i32) -> i32 ---
	glXGetVisualFromFBConfig  :: proc(dpy: ^xlib.Display, config: GLXFBConfig) -> ^xlib.XVisualInfo ---
	glXCreateNewContext       :: proc(dpy: ^xlib.Display, config: GLXFBConfig, render_type: i32, share_list: GLXContext, direct: b32) -> GLXContext ---
	glXDestroyContext         :: proc(dpy: ^xlib.Display, ctx: GLXContext) ---
	glXMakeContextCurrent     :: proc(dpy: ^xlib.Display, draw, read: GLXDrawable, ctx: GLXContext) -> b32 ---
	glXCreateWindow           :: proc(dpy: ^xlib.Display, config: GLXFBConfig, win: xlib.Window, attribs: [^]i32) -> GLXDrawable ---
	glXDestroyWindow          :: proc(dpy: ^xlib.Display, win: GLXDrawable) ---
	glXCreatePixmap           :: proc(dpy: ^xlib.Display, config: GLXFBConfig, pixmap: xlib.Pixmap, attribs: [^]i32) -> GLXDrawable ---
	glXDestroyPixmap          :: proc(dpy: ^xlib.Display, pixmap: GLXDrawable) ---
	glXSwapBuffers            :: proc(dpy: ^xlib.Display, drawable: GLXDrawable) ---
	glXGetProcAddressARB      :: proc(name: cstring) -> rawptr ---
}

PFN_glXCreateContextAttribsARB :: #type proc "c" (dpy: ^xlib.Display, config: GLXFBConfig, share: GLXContext, direct: b32, attribs: [^]i32) -> GLXContext
PFN_glXBindTexImageEXT         :: #type proc "c" (dpy: ^xlib.Display, drawable: GLXDrawable, buffer: i32, attribs: [^]i32)
PFN_glXReleaseTexImageEXT      :: #type proc "c" (dpy: ^xlib.Display, drawable: GLXDrawable, buffer: i32)
PFN_glXSwapIntervalEXT         :: #type proc "c" (dpy: ^xlib.Display, drawable: GLXDrawable, interval: i32)
PFN_glXSwapIntervalMESA        :: #type proc "c" (interval: u32) -> i32

gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(^rawptr)(p)^ = glXGetProcAddressARB(name)
}
