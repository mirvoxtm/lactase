// lactase.json: what the compositor draws. The loader validates the file the
// same way milk validates milk.json (unknown keys and out-of-range values are
// errors that name the key); `save` writes it back in a fixed, readable order,
// which is what the settings app does after every change.
package lactase

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import config "milk:config"

// Globals, not constants: they are indexed with run-time values.
@(rodata) BACKENDS        := []string{"glx", "xrender"}
@(rodata) ANIMATION_KINDS := []string{"none", "fade", "zoom", "slide"}
@(rodata) WINDOW_TYPES    := []string{"normal", "dialog", "utility", "toolbar", "splash", "menu", "dropdown_menu", "popup_menu",
                                      "tooltip", "notification", "combo", "dnd", "dock", "desktop", "unknown"}

Shadow_Options :: struct {
	enabled:  bool,
	radius:   int,    // blur radius in pixels
	opacity:  f64,    // 0..1
	offset_x: int,
	offset_y: int,
	color:    string, // "#RRGGBB"
}

Animation_Options :: struct {
	enabled:        bool,
	open:           string, // none | fade | zoom | slide
	close:          string,
	open_duration:  int,    // milliseconds
	close_duration: int,
	workspaces:     bool,   // fade windows hidden or shown by an area switch
}

Opacity_Options :: struct {
	active:       f64, // focused windows
	inactive:     f64, // the other application windows
	dim_inactive: f64, // 0 = off; darkens unfocused windows by this much
}

Blur_Options :: struct {
	enabled:  bool,
	strength: int, // 1..10
}

Corner_Options :: struct {
	radius: int, // pixels; 0 = square (windows the WM rounds itself stay rounded, smoothed)
}

// A window rule: windows matching every non-empty field get the options set.
Rule :: struct {
	class:    string, // WM_CLASS class, case-insensitive ("" = any)
	instance: string, // WM_CLASS instance, case-insensitive
	title:    string, // substring of the title, case-insensitive
	type:     string, // a WINDOW_TYPES name
	opacity:  Maybe(f64),
	shadow:   Maybe(bool),
	blur:     Maybe(bool),
	corners:  Maybe(int),
	animate:  Maybe(bool),
	dim:      Maybe(bool),
}

Config :: struct {
	version:               int,
	backend:               string,
	vsync:                 bool,
	unredirect_fullscreen: bool,
	follow_milk:           bool, // corner radius and animation speed from milk.json
	shadows:               Shadow_Options,
	animations:            Animation_Options,
	opacity:               Opacity_Options,
	blur:                  Blur_Options,
	corners:               Corner_Options,
	rules:                 []Rule,
	arena:                 virtual.Arena,
}

@(rodata) DEFAULT_RULES := []Rule{
	{type = "desktop", shadow = false, blur = false, corners = 0},
	{type = "dock", shadow = false, blur = false, corners = 0},
	{type = "dnd", shadow = false, corners = 0},
}

// Defaults: soft shadows and quick zoom-and-fade animations, no transparency.
// Strings and slices are literals; the loader clones what it keeps.
default_config :: proc() -> Config {
	return {
		version = 1, backend = "glx", vsync = true, unredirect_fullscreen = false, follow_milk = true,
		shadows = {enabled = true, radius = 22, opacity = 0.32, offset_x = 0, offset_y = 7, color = "#000000"},
		animations = {enabled = true, open = "zoom", close = "zoom", open_duration = 190, close_duration = 150, workspaces = true},
		opacity = {active = 1, inactive = 1, dim_inactive = 0},
		blur = {enabled = false, strength = 5},
		corners = {radius = 10},
		rules = DEFAULT_RULES,
	}
}

// A heap copy of the defaults that `destroy` can free like a loaded config.
default_config_owned :: proc() -> ^Config {
	cfg := new(Config)
	cfg^ = default_config()
	if err := virtual.arena_init_growing(&cfg.arena); err != nil { return cfg }
	a := virtual.arena_allocator(&cfg.arena)
	cfg.backend = strings.clone(cfg.backend, a)
	cfg.shadows.color = strings.clone(cfg.shadows.color, a)
	cfg.animations.open = strings.clone(cfg.animations.open, a)
	cfg.animations.close = strings.clone(cfg.animations.close, a)
	rules := make([]Rule, len(DEFAULT_RULES), a)
	for r, i in DEFAULT_RULES { rules[i] = clone_rule(r, a) }
	cfg.rules = rules
	return cfg
}

clone_rule :: proc(r: Rule, a := context.allocator) -> Rule {
	out := r
	out.class = strings.clone(r.class, a)
	out.instance = strings.clone(r.instance, a)
	out.title = strings.clone(r.title, a)
	out.type = strings.clone(r.type, a)
	return out
}

destroy :: proc(cfg: ^Config) {
	if cfg == nil { return }
	virtual.arena_destroy(&cfg.arena)
	free(cfg)
}

// ---------------------------------------------------------------------------
// Where the files are
// ---------------------------------------------------------------------------
join :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(elems, allocator)
	return s
}

clean :: proc(p: string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.clean(p, allocator)
	return s
}

home_dir :: proc() -> string {
	if v, found := os.lookup_env("HOME", context.temp_allocator); found && v != "" { return v }
	return "/"
}

// lactase.json: $LACTASE_CONFIG, else next to the clone (bin/lactase → ../lactase.json),
// else ~/.config/lactase/lactase.json.
default_config_path :: proc(allocator := context.allocator) -> string {
	if v, found := os.lookup_env("LACTASE_CONFIG", context.temp_allocator); found && v != "" { return strings.clone(v, allocator) }
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for rel in ([]string{"../lactase.json", "lactase.json"}) {
			p := clean(join({dir, rel}))
			if os.is_file(p) { return strings.clone(p, allocator) }
		}
		// No file yet: the clone is where it belongs (the settings app creates it).
		if strings.has_suffix(dir, "/bin") { return clean(join({dir, "..", "lactase.json"}), allocator) }
	}
	config_home, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || config_home == "" { config_home = join({home_dir(), ".config"}) }
	return join({config_home, "lactase", "lactase.json"}, allocator)
}

// milk.json (for the corner radius, the animation speed and the settings app's
// look): $MILK_CONFIG, else ../milk/milk.json next to lactase's folder, else
// the milk folder recorded by the milk session (~/.config/milk/location).
find_milk_config :: proc(allocator := context.allocator) -> string {
	if v, found := os.lookup_env("MILK_CONFIG", context.temp_allocator); found && v != "" { return strings.clone(v, allocator) }
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for rel in ([]string{"../../milk/milk.json", "../milk/milk.json"}) {
			p := clean(join({dir, rel}))
			if os.is_file(p) { return strings.clone(p, allocator) }
		}
	}
	config_home, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || config_home == "" { config_home = join({home_dir(), ".config"}) }
	if data, err := os.read_entire_file(join({config_home, "milk", "location"}), context.temp_allocator); err == nil {
		p := join({strings.trim_space(string(data)), "milk.json"})
		if os.is_file(p) { return strings.clone(p, allocator) }
	}
	return ""
}

// What lactase takes from milk.json when followMilk is on.
Milk_Values :: struct {
	found:           bool,
	corner_radius:   int,
	animation_scale: f64,
}

read_milk_values :: proc(path: string) -> Milk_Values {
	if path == "" { return {} }
	cfg, err := config.load(path)
	if err != "" {
		delete(err)
		return {}
	}
	defer config.destroy(cfg)
	return {found = true, corner_radius = cfg.wm.corner_radius, animation_scale = cfg.appearance.animation_scale}
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------
@(private="file")
Loader :: struct {
	err: string,
	a:   virtual.Arena,
}

@(private="file")
fail :: proc(l: ^Loader, format: string, args: ..any) -> bool {
	if l.err == "" { l.err = fmt.aprintf(format, ..args) }
	return false
}

@(private="file")
get_object :: proc(l: ^Loader, obj: json.Object, key, scope: string) -> (json.Object, bool) {
	v, present := obj[key]
	if !present { return nil, true }
	o, ok := v.(json.Object)
	if !ok { return nil, fail(l, "%s.%s must be an object.", scope, key) }
	return o, true
}

@(private="file")
reject_unknown :: proc(l: ^Loader, obj: json.Object, allowed: []string, scope: string) -> bool {
	for key, _ in obj {
		known := false
		for a in allowed { if a == key { known = true; break } }
		if !known { return fail(l, "Unknown key in %s: %s", scope, key) }
	}
	return true
}

@(private="file")
get_bool :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: bool) -> (bool, bool) {
	v, present := obj[key]
	if !present { return default_value, true }
	b, ok := v.(bool)
	if !ok { return false, fail(l, "%s.%s must be true or false.", scope, key) }
	return b, true
}

@(private="file")
get_number :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value, minimum, maximum: f64) -> (f64, bool) {
	v, present := obj[key]
	if !present { return default_value, true }
	n: f64
	#partial switch x in v {
	case i64: n = f64(x)
	case f64: n = x
	case: return 0, fail(l, "%s.%s must be a number.", scope, key)
	}
	if n < minimum { return 0, fail(l, "%s.%s must be at least %v.", scope, key, minimum) }
	if n > maximum { return 0, fail(l, "%s.%s must be at most %v.", scope, key, maximum) }
	return n, true
}

@(private="file")
get_int :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value, minimum, maximum: int) -> (int, bool) {
	n, ok := get_number(l, obj, key, scope, f64(default_value), f64(minimum), f64(maximum))
	return int(n), ok
}

@(private="file")
get_string :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: string) -> (string, bool) {
	a := virtual.arena_allocator(&l.a)
	v, present := obj[key]
	if !present { return strings.clone(default_value, a), true }
	if _, is_null := v.(json.Null); is_null { return "", true }
	s, ok := v.(string)
	if !ok { return "", fail(l, "%s.%s must be a string.", scope, key) }
	return strings.clone(s, a), true
}

@(private="file")
get_choice :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: string, choices: []string) -> (value: string, ok: bool) {
	s := get_string(l, obj, key, scope, default_value) or_return
	for c in choices { if c == s { return s, true } }
	return "", fail(l, "%s.%s must be one of: %s", scope, key, strings.join(choices, ", ", context.temp_allocator))
}

@(private="file")
valid_color :: proc(s: string) -> bool {
	if len(s) != 7 || s[0] != '#' { return false }
	for ch in s[1:] {
		switch ch {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case: return false
		}
	}
	return true
}

// Load and validate lactase.json. A missing file gives the defaults; `err`
// is "" on success.
load :: proc(path: string) -> (cfg: ^Config, err: string) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		if !os.exists(path) { return default_config_owned(), "" }
		return nil, fmt.aprintf("Cannot read %s: %v", path, read_err)
	}
	value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	if perr != .None { return nil, fmt.aprintf("Could not read lactase.json: %v", perr) }
	root, is_obj := value.(json.Object)
	if !is_obj { return nil, strings.clone("lactase.json must contain a JSON object.") }

	cfg = new(Config)
	l: Loader
	if aerr := virtual.arena_init_growing(&l.a); aerr != nil {
		free(cfg)
		return nil, strings.clone("Out of memory")
	}
	if !parse_root(&l, root, cfg) {
		virtual.arena_destroy(&l.a)
		free(cfg)
		return nil, l.err
	}
	cfg.arena = l.a
	return cfg, ""
}

@(private="file")
parse_root :: proc(l: ^Loader, root: json.Object, cfg: ^Config) -> bool {
	d := default_config()
	reject_unknown(l, root, {"version", "backend", "vsync", "unredirectFullscreen", "followMilk", "shadows", "animations",
	                         "opacity", "blur", "corners", "rules"}, "lactase.json") or_return
	if v, present := root["version"]; present {
		n, is_int := v.(i64)
		if !is_int || n != 1 { return fail(l, "Unsupported lactase.json version. Expected version 1.") }
	}
	cfg.version = 1
	cfg.backend = get_choice(l, root, "backend", "lactase", d.backend, BACKENDS) or_return
	cfg.vsync = get_bool(l, root, "vsync", "lactase", d.vsync) or_return
	cfg.unredirect_fullscreen = get_bool(l, root, "unredirectFullscreen", "lactase", d.unredirect_fullscreen) or_return
	cfg.follow_milk = get_bool(l, root, "followMilk", "lactase", d.follow_milk) or_return

	sh := get_object(l, root, "shadows", "lactase") or_return
	reject_unknown(l, sh, {"enabled", "radius", "opacity", "offsetX", "offsetY", "color"}, "shadows") or_return
	cfg.shadows.enabled = get_bool(l, sh, "enabled", "shadows", d.shadows.enabled) or_return
	cfg.shadows.radius = get_int(l, sh, "radius", "shadows", d.shadows.radius, 0, 100) or_return
	cfg.shadows.opacity = get_number(l, sh, "opacity", "shadows", d.shadows.opacity, 0, 1) or_return
	cfg.shadows.offset_x = get_int(l, sh, "offsetX", "shadows", d.shadows.offset_x, -100, 100) or_return
	cfg.shadows.offset_y = get_int(l, sh, "offsetY", "shadows", d.shadows.offset_y, -100, 100) or_return
	cfg.shadows.color = get_string(l, sh, "color", "shadows", d.shadows.color) or_return
	if !valid_color(cfg.shadows.color) { return fail(l, "shadows.color must be a colour like \"#000000\".") }

	an := get_object(l, root, "animations", "lactase") or_return
	reject_unknown(l, an, {"enabled", "open", "close", "openDuration", "closeDuration", "workspaces"}, "animations") or_return
	cfg.animations.enabled = get_bool(l, an, "enabled", "animations", d.animations.enabled) or_return
	cfg.animations.open = get_choice(l, an, "open", "animations", d.animations.open, ANIMATION_KINDS) or_return
	cfg.animations.close = get_choice(l, an, "close", "animations", d.animations.close, ANIMATION_KINDS) or_return
	cfg.animations.open_duration = get_int(l, an, "openDuration", "animations", d.animations.open_duration, 0, 2000) or_return
	cfg.animations.close_duration = get_int(l, an, "closeDuration", "animations", d.animations.close_duration, 0, 2000) or_return
	cfg.animations.workspaces = get_bool(l, an, "workspaces", "animations", d.animations.workspaces) or_return

	op := get_object(l, root, "opacity", "lactase") or_return
	reject_unknown(l, op, {"active", "inactive", "dimInactive"}, "opacity") or_return
	cfg.opacity.active = get_number(l, op, "active", "opacity", d.opacity.active, 0.1, 1) or_return
	cfg.opacity.inactive = get_number(l, op, "inactive", "opacity", d.opacity.inactive, 0.1, 1) or_return
	cfg.opacity.dim_inactive = get_number(l, op, "dimInactive", "opacity", d.opacity.dim_inactive, 0, 0.9) or_return

	bl := get_object(l, root, "blur", "lactase") or_return
	reject_unknown(l, bl, {"enabled", "strength"}, "blur") or_return
	cfg.blur.enabled = get_bool(l, bl, "enabled", "blur", d.blur.enabled) or_return
	cfg.blur.strength = get_int(l, bl, "strength", "blur", d.blur.strength, 1, 10) or_return

	co := get_object(l, root, "corners", "lactase") or_return
	reject_unknown(l, co, {"radius"}, "corners") or_return
	cfg.corners.radius = get_int(l, co, "radius", "corners", d.corners.radius, 0, 64) or_return

	a := virtual.arena_allocator(&l.a)
	rv, has_rules := root["rules"]
	if !has_rules {
		rules := make([]Rule, len(DEFAULT_RULES), a)
		for r, i in DEFAULT_RULES { rules[i] = clone_rule(r, a) }
		cfg.rules = rules
		return true
	}
	arr, is_arr := rv.(json.Array)
	if !is_arr { return fail(l, "rules must be an array of objects.") }
	rules := make([dynamic]Rule, a)
	for item, i in arr {
		scope := fmt.tprintf("rules[%d]", i)
		obj, is_obj := item.(json.Object)
		if !is_obj { return fail(l, "%s must be an object.", scope) }
		reject_unknown(l, obj, {"class", "instance", "title", "type", "opacity", "shadow", "blur", "corners", "animate", "dim"}, scope) or_return
		r: Rule
		r.class = get_string(l, obj, "class", scope, "") or_return
		r.instance = get_string(l, obj, "instance", scope, "") or_return
		r.title = get_string(l, obj, "title", scope, "") or_return
		r.type = get_string(l, obj, "type", scope, "") or_return
		if r.type != "" {
			known := false
			for t in WINDOW_TYPES { if t == r.type { known = true; break } }
			if !known { return fail(l, "%s.type must be one of: %s", scope, strings.join(WINDOW_TYPES, ", ", context.temp_allocator)) }
		}
		if r.class == "" && r.instance == "" && r.title == "" && r.type == "" {
			return fail(l, "%s must match something (class, instance, title or type).", scope)
		}
		if _, present := obj["opacity"]; present { r.opacity = get_number(l, obj, "opacity", scope, 1, 0.05, 1) or_return }
		if _, present := obj["shadow"]; present { r.shadow = get_bool(l, obj, "shadow", scope, true) or_return }
		if _, present := obj["blur"]; present { r.blur = get_bool(l, obj, "blur", scope, false) or_return }
		if _, present := obj["corners"]; present { r.corners = get_int(l, obj, "corners", scope, 0, 0, 64) or_return }
		if _, present := obj["animate"]; present { r.animate = get_bool(l, obj, "animate", scope, true) or_return }
		if _, present := obj["dim"]; present { r.dim = get_bool(l, obj, "dim", scope, true) or_return }
		append(&rules, r)
	}
	cfg.rules = rules[:]
	return true
}

// ---------------------------------------------------------------------------
// Saving (fixed key order, two-space indent, short numbers)
// ---------------------------------------------------------------------------
@(private="file")
num :: proc(v: f64) -> string {
	if v == f64(i64(v)) { return fmt.tprintf("%d", i64(v)) }
	s := fmt.tprintf("%.3f", v)
	s = strings.trim_right(s, "0")
	return strings.trim_right(s, ".")
}

@(private="file")
quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_quoted_string(&b, s)
	return strings.to_string(b)
}

to_json :: proc(cfg: ^Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	w :: strings.write_string
	yes :: proc(v: bool) -> string { return v ? "true" : "false" }
	w(&b, "{\n")
	fmt.sbprintf(&b, "  \"version\": 1,\n")
	fmt.sbprintf(&b, "  \"backend\": %s,\n", quote(cfg.backend))
	fmt.sbprintf(&b, "  \"vsync\": %s,\n", yes(cfg.vsync))
	fmt.sbprintf(&b, "  \"unredirectFullscreen\": %s,\n", yes(cfg.unredirect_fullscreen))
	fmt.sbprintf(&b, "  \"followMilk\": %s,\n", yes(cfg.follow_milk))
	s := cfg.shadows
	fmt.sbprintf(&b, "  \"shadows\": {{\n    \"enabled\": %s,\n    \"radius\": %d,\n    \"opacity\": %s,\n    \"offsetX\": %d,\n    \"offsetY\": %d,\n    \"color\": %s\n  }},\n",
	             yes(s.enabled), s.radius, num(s.opacity), s.offset_x, s.offset_y, quote(s.color))
	an := cfg.animations
	fmt.sbprintf(&b, "  \"animations\": {{\n    \"enabled\": %s,\n    \"open\": %s,\n    \"close\": %s,\n    \"openDuration\": %d,\n    \"closeDuration\": %d,\n    \"workspaces\": %s\n  }},\n",
	             yes(an.enabled), quote(an.open), quote(an.close), an.open_duration, an.close_duration, yes(an.workspaces))
	op := cfg.opacity
	fmt.sbprintf(&b, "  \"opacity\": {{\n    \"active\": %s,\n    \"inactive\": %s,\n    \"dimInactive\": %s\n  }},\n",
	             num(op.active), num(op.inactive), num(op.dim_inactive))
	fmt.sbprintf(&b, "  \"blur\": {{\n    \"enabled\": %s,\n    \"strength\": %d\n  }},\n", yes(cfg.blur.enabled), cfg.blur.strength)
	fmt.sbprintf(&b, "  \"corners\": {{\n    \"radius\": %d\n  }},\n", cfg.corners.radius)
	w(&b, "  \"rules\": [")
	for r, i in cfg.rules {
		w(&b, i == 0 ? "\n    {" : ",\n    {")
		first := true
		field :: proc(b: ^strings.Builder, first: ^bool, key, value: string) {
			strings.write_string(b, first^ ? "" : ", ")
			fmt.sbprintf(b, "\"%s\": %s", key, value)
			first^ = false
		}
		if r.class != ""    { field(&b, &first, "class", quote(r.class)) }
		if r.instance != "" { field(&b, &first, "instance", quote(r.instance)) }
		if r.title != ""    { field(&b, &first, "title", quote(r.title)) }
		if r.type != ""     { field(&b, &first, "type", quote(r.type)) }
		if v, ok := r.opacity.?; ok { field(&b, &first, "opacity", num(v)) }
		if v, ok := r.shadow.?; ok  { field(&b, &first, "shadow", yes(v)) }
		if v, ok := r.blur.?; ok    { field(&b, &first, "blur", yes(v)) }
		if v, ok := r.corners.?; ok { field(&b, &first, "corners", fmt.tprintf("%d", v)) }
		if v, ok := r.animate.?; ok { field(&b, &first, "animate", yes(v)) }
		if v, ok := r.dim.?; ok     { field(&b, &first, "dim", yes(v)) }
		w(&b, "}")
	}
	w(&b, len(cfg.rules) > 0 ? "\n  ]\n}\n" : "]\n}\n")
	return strings.to_string(b)
}

// Write lactase.json atomically (temp file + rename).
save :: proc(cfg: ^Config, path: string) -> (ok: bool, err: string) {
	dir := filepath.dir(path)
	if !os.is_directory(dir) {
		if merr := os.make_directory_all(dir); merr != nil && merr != .Exist {
			return false, fmt.tprintf("cannot create %s: %v", dir, merr)
		}
	}
	tmp := fmt.tprintf("%s.tmp", path)
	if werr := os.write_entire_file(tmp, to_json(cfg)); werr != nil { return false, fmt.tprintf("cannot write %s: %v", tmp, werr) }
	if rerr := os.rename(tmp, path); rerr != nil { return false, fmt.tprintf("cannot replace %s: %v", path, rerr) }
	return true, ""
}
