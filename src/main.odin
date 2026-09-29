// lactase: milk's compositor.
//
// A picom-like compositing manager for X11 written for milk: soft shadows,
// fading and zooming windows, transparency rules, background blur and
// anti-aliased rounded corners (including the corners milk's window manager
// cuts with SHAPE). One instance per screen, found through the compositor
// selection (_NET_WM_CM_Sn); `lactase settings` opens its settings app, which
// milk's settings also open.
package lactase

import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

VERSION :: "0.1.0"

Options :: struct {
	command:     string,
	config_path: string,
	backend:     string,
	foreground:  bool,
	replace:     bool,
	verbose:     bool,
}

usage :: proc() {
	fmt.eprintln(`lactase - milk's compositor (shadows, fades, transparency, blur, rounded corners)

usage: lactase [command] [options]

commands:
  start        run in the background (nothing happens when lactase already runs)  [default]
  restart      replace the running lactase
  stop         stop the running lactase
  reload       re-read lactase.json in the running lactase
  status       show whether lactase runs on this display
  settings     open the settings app
  check        validate lactase.json and print the options in effect
  version      print the version

options:
  --foreground, -f     stay attached to the terminal and log to stderr
  --config FILE        configuration file (default: lactase.json in the clone, or $LACTASE_CONFIG)
  --backend NAME       glx or xrender, overriding lactase.json
  --replace            take over from another compositor (picom, compton, ...)
  --verbose, -v        debug logging`)
}

main :: proc() {
	opts, ok := parse_args(os.args[1:])
	if !ok {
		usage()
		os.exit(2)
	}
	if opts.config_path == "" { opts.config_path = default_config_path() }
	code := 0
	switch opts.command {
	case "start":            code = cmd_start(&opts, false)
	case "restart":          code = cmd_start(&opts, true)
	case "stop":             code = cmd_control(&opts, CONTROL_QUIT)
	case "reload":           code = cmd_control(&opts, CONTROL_RELOAD)
	case "status":           code = cmd_status(&opts)
	case "settings", "config": code = cmd_settings(&opts)
	case "check":            code = cmd_check(&opts)
	case "version":          fmt.println("lactase", VERSION)
	case "help":             usage()
	case:
		fmt.eprintfln("unknown command: %s", opts.command)
		usage()
		code = 2
	}
	os.exit(code)
}

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.command = "start"
	positional := 0
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--foreground", "-f": opts.foreground = true
		case "--replace":          opts.replace = true
		case "--verbose", "-v":    opts.verbose = true
		case "--help", "-h":       opts.command = "help"
		case "--config", "--backend":
			if i + 1 >= len(args) {
				fmt.eprintfln("%s needs a value", a)
				return opts, false
			}
			i += 1
			if a == "--config" { opts.config_path = args[i] } else { opts.backend = args[i] }
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintfln("unknown option: %s", a)
				return opts, false
			}
			if positional > 0 {
				fmt.eprintfln("unexpected argument: %s", a)
				return opts, false
			}
			opts.command = a
			positional += 1
		}
		i += 1
	}
	if opts.backend != "" && opts.backend != "glx" && opts.backend != "xrender" {
		fmt.eprintln("--backend must be glx or xrender")
		return opts, false
	}
	return opts, true
}

make_logger :: proc(opts: ^Options) -> log.Logger {
	level := opts.verbose ? log.Level.Debug : log.Level.Info
	options := opts.foreground ? log.Options{.Level, .Terminal_Color} : log.Options{.Level, .Date, .Time}
	return log.create_console_logger(level, options)
}

// ---------------------------------------------------------------------------
// The running instance (owner of the compositor selection)
// ---------------------------------------------------------------------------
Instance :: struct {
	owner:   xlib.Window,
	lactase: bool, // the owner is lactase (not picom & co.)
	pid:     int,
	name:    string,
	backend: string,
}

find_instance :: proc(c: ^tx.Connection) -> (inst: Instance, running: bool) {
	cm := tx.atom(c, fmt.tprintf("_NET_WM_CM_S%d", c.screen))
	owner := xlib.GetSelectionOwner(c.dpy, cm)
	if owner == 0 { return {}, false }
	inst.owner = owner
	_, class := tx.window_class(c, owner)
	inst.lactase = class == "Lactase"
	inst.name = tx.window_title(c, owner)
	if inst.name == "" { inst.name = class }
	if pid, ok := tx.get_cardinal(c, owner, "_NET_WM_PID"); ok { inst.pid = int(pid) }
	inst.backend = tx.get_utf8_string(c, owner, "_LACTASE_BACKEND")
	return inst, true
}

send_control :: proc(c: ^tx.Connection, owner: xlib.Window, command: int) {
	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = owner
	ev.xclient.message_type = tx.atom(c, "_LACTASE_CONTROL")
	ev.xclient.format = 32
	ev.xclient.data.l = {command, 0, 0, 0, 0}
	xlib.SendEvent(c.dpy, owner, false, {}, &ev)
	tx.flush(c)
}

open_display :: proc() -> (^tx.Connection, bool) {
	if display, found := os.lookup_env("DISPLAY", context.temp_allocator); !found || display == "" {
		fmt.eprintln("lactase: DISPLAY is not set")
		return nil, false
	}
	c, ok := tx.connect()
	if !ok { fmt.eprintln("lactase: cannot open the X display") }
	return c, ok
}

cmd_control :: proc(opts: ^Options, command: int) -> int {
	c, ok := open_display()
	if !ok { return 1 }
	defer tx.disconnect(c)
	inst, running := find_instance(c)
	if !running || !inst.lactase {
		fmt.println("lactase is not running")
		return 1
	}
	send_control(c, inst.owner, command)
	if command == CONTROL_RELOAD {
		fmt.println("Reload requested")
		return 0
	}
	for _ in 0 ..< 60 {
		time.sleep(50 * time.Millisecond)
		if _, still := find_instance(c); !still {
			fmt.println("lactase stopped")
			return 0
		}
	}
	if inst.pid > 0 { posix.kill(posix.pid_t(inst.pid), .SIGTERM) }
	fmt.println("lactase stopped (terminated)")
	return 0
}

cmd_status :: proc(opts: ^Options) -> int {
	c, ok := open_display()
	if !ok { return 1 }
	defer tx.disconnect(c)
	inst, running := find_instance(c)
	if !running {
		fmt.println("No compositor is running")
		return 1
	}
	if !inst.lactase {
		fmt.printfln("Another compositor is running: %s (pid %d)", inst.name == "" ? "unknown" : inst.name, inst.pid)
		return 1
	}
	fmt.printfln("lactase is running (pid %d, %s renderer)", inst.pid, inst.backend == "" ? "unknown" : inst.backend)
	fmt.printfln("Configuration: %s", opts.config_path)
	return 0
}

cmd_check :: proc(opts: ^Options) -> int {
	cfg, err := load(opts.config_path)
	if err != "" {
		fmt.printfln("%s: %s", opts.config_path, err)
		return 1
	}
	defer destroy(cfg)
	fmt.printfln("# %s%s", opts.config_path, os.exists(opts.config_path) ? "" : " (not created yet: defaults)")
	fmt.print(to_json(cfg))
	return 0
}

cmd_settings :: proc(opts: ^Options) -> int {
	c, ok := open_display()
	if !ok { return 1 }
	defer tx.disconnect(c)
	context.logger = make_logger(opts)
	settings_run(c, opts.config_path)
	return 0
}

// ---------------------------------------------------------------------------
// start
// ---------------------------------------------------------------------------
log_path :: proc() -> string {
	display, _ := os.lookup_env("DISPLAY", context.temp_allocator)
	suffix := strings.trim_left(display, ":")
	if dot := strings.index_byte(suffix, '.'); dot >= 0 { suffix = suffix[:dot] }
	if runtime, found := os.lookup_env("MILK_RUNTIME", context.temp_allocator); found && runtime != "" && os.is_directory(runtime) {
		return join({runtime, "lactase.log"})
	}
	cache, found := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	if !found || cache == "" { cache = join({home_dir(), ".cache"}) }
	dir := join({cache, "lactase"})
	os.make_directory_all(dir)
	return join({dir, fmt.tprintf("lactase-%s.log", suffix)})
}

daemonize :: proc(log_file: string) -> bool {
	pid := posix.fork()
	if pid < 0 { return false }
	if pid > 0 { posix._exit(0) }
	posix.setsid()
	pid = posix.fork()
	if pid < 0 { return false }
	if pid > 0 { posix._exit(0) }
	posix.chdir("/")
	null := posix.open("/dev/null", {})
	clog := strings.clone_to_cstring(log_file, context.temp_allocator)
	logfd := posix.open(clog, {.WRONLY, .CREAT, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if null >= 0 {
		posix.dup2(null, 0)
		posix.close(null)
	}
	if logfd >= 0 {
		posix.dup2(logfd, 1)
		posix.dup2(logfd, 2)
		posix.close(logfd)
	}
	return true
}

cmd_start :: proc(opts: ^Options, restart: bool) -> int {
	cfg, err := load(opts.config_path)
	if err != "" {
		fmt.eprintfln("lactase: %s", err)
		return 1
	}
	{
		c, ok := open_display()
		if !ok { return 1 }
		inst, running := find_instance(c)
		tx.disconnect(c)
		if running {
			if inst.lactase && !restart {
				fmt.printfln("lactase is already running (pid %d)", inst.pid)
				return 0
			}
			if !inst.lactase && !opts.replace {
				fmt.eprintfln("lactase: another compositor is running (%s, pid %d); stop it or use --replace",
				              inst.name == "" ? "unknown" : inst.name, inst.pid)
				return 1
			}
		}
	}
	if !opts.foreground {
		if !daemonize(log_path()) {
			fmt.eprintln("lactase: could not fork into the background")
			return 1
		}
	}
	context.logger = make_logger(opts)
	return run(opts, cfg)
}

g_stop:    bool
g_reload:  bool
g_wake_fd: posix.FD = -1

signal_handler :: proc "c" (sig: posix.Signal) {
	#partial switch sig {
	case .SIGTERM, .SIGINT: g_stop = true
	case .SIGHUP:           g_reload = true
	case:
	}
	if g_wake_fd >= 0 {
		b: [1]u8 = {1}
		posix.write(g_wake_fd, &b[0], 1)
	}
}

install_signals :: proc() -> (wake_read: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return -1, false }
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
	}
	g_wake_fd = fds[1]
	act: posix.sigaction_t
	act.sa_handler = signal_handler
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {.RESTART}
	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) { posix.sigaction(sig, &act, nil) }
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	return fds[0], true
}

// Load lactase.json again; a broken file keeps the current configuration.
reload_config :: proc(comp: ^Comp) {
	comp.cfg_mtime = mtime(comp.cfg_path)
	comp.milk_mtime = mtime(comp.milk_path)
	cfg, err := load(comp.cfg_path)
	if err != "" {
		log.errorf("Reload failed, keeping the previous configuration: %s", err)
		delete(err)
		return
	}
	apply_config(comp, cfg)
	publish_state(comp)
	log.info("Configuration reloaded")
}

// What `lactase status` and the settings app read from the selection owner.
publish_state :: proc(comp: ^Comp) {
	name := "none"
	switch comp.backend {
	case .GLX:     name = "glx"
	case .XRender: name = "xrender"
	case .None:
	}
	tx.set_utf8_string(comp.c, comp.owner, "_LACTASE_BACKEND", name)
	tx.set_utf8_string(comp.c, comp.owner, "_LACTASE_CONFIG", comp.cfg_path)
	// milk's window manager stops cutting corners with SHAPE while this is > 0.
	tx.set_cardinals(comp.c, comp.owner, "_LACTASE_CORNERS", {uint(max(comp.corner_radius, 0))})
	tx.flush(comp.c)
}

run :: proc(opts: ^Options, cfg: ^Config) -> int {
	c, connected := tx.connect()
	if !connected {
		log.error("Could not open the X display")
		return 1
	}
	defer tx.disconnect(c)
	preferred := backend_kind(opts.backend != "" ? opts.backend : cfg.backend)
	comp, ok := comp_create(c, cfg, opts.config_path, preferred)
	if !ok {
		log.error("lactase could not start")
		destroy(cfg)
		return 1
	}
	defer comp_destroy(comp)
	publish_state(comp)
	wake_read, sig_ok := install_signals()
	if !sig_ok {
		log.error("Could not install signal handlers")
		return 1
	}
	log.infof("lactase %s started (pid %d, %.0f Hz, config %s)", VERSION, os.get_pid(), comp.refresh, opts.config_path)
	loop(comp, wake_read)
	log.info("lactase stopped")
	return 0
}

loop :: proc(comp: ^Comp, wake_read: posix.FD) {
	conn := comp.c
	last_tick := tx.now()
	last_check := last_tick
	next_frame := last_tick
	for !g_stop && !comp.quit {
		for tx.pending(conn) > 0 {
			ev: xlib.XEvent
			tx.next_event(conn, &ev)
			handle_event(comp, &ev)
		}
		now := tx.now()
		if now - last_check >= 1 {
			last_check = now
			if mtime(comp.cfg_path) != comp.cfg_mtime || mtime(comp.milk_path) != comp.milk_mtime { comp.reload = true }
		}
		if g_reload || comp.reload {
			g_reload, comp.reload = false, false
			reload_config(comp)
		}
		dt := clamp(now - last_tick, 0, 1.0 / 30)
		last_tick = now
		prepare_frame(comp)
		moving := step_animations(comp, dt)
		if comp.wall_fade > 0 {
			secs := wallpaper_fade_seconds(comp)
			comp.wall_fade = secs > 0 ? max(comp.wall_fade - dt / secs, 0) : 0
			damage_everything(comp)
			moving = true
		}
		check_unredirect(comp, now)
		interval := 1 / comp.refresh
		if comp.backend == .GLX && comp.cfg.vsync { interval *= 0.5 } // the swap waits for the display
		if comp.dirty && now >= next_frame {
			paint(comp, now)
			next_frame = now + interval
		}
		free_all(context.temp_allocator)

		timeout_ms: c.int = 1000
		if comp.dirty || moving {
			timeout_ms = c.int(max(next_frame - tx.now(), 0) * 1000)
		}
		if tx.pending(conn) > 0 { continue }
		fds := [2]posix.pollfd{{fd = posix.FD(conn.fd), events = {.IN}}, {fd = wake_read, events = {.IN}}}
		n := posix.poll(&fds[0], 2, timeout_ms)
		if n > 0 && fds[1].revents != {} {
			buf: [64]u8
			for posix.read(wake_read, &buf[0], len(buf)) > 0 {}
		}
	}
}
