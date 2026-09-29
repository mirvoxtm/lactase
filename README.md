# lactase

lactase is the compositor of [milk](https://github.com/mirvoxtm/milk): soft shadows, windows that
fade and zoom in and out, transparency, background blur and smooth rounded corners, in the spirit of
picom. milk starts it with the session and its settings open from milk's settings (Efeitos), but it
also runs on its own under any X11 window manager.

milk's installer fetches and builds lactase next to milk. To build it by hand, clone it beside your
milk folder:

```sh
git clone https://github.com/mirvoxtm/lactase.git   # next to the milk folder
cd lactase
./build.sh
./lactase start
```

It needs the Odin compiler, milk's sources (for its X11 layer and look) and the usual X libraries:
libXcomposite, libXdamage, libXfixes, libXrender and an OpenGL driver (Mesa).

## Using it

```sh
lactase              # start in the background (does nothing when it already runs)
lactase settings     # the settings app, in milk's look
lactase restart      # replace the running lactase
lactase stop
lactase status       # renderer and configuration in use
lactase check        # validate lactase.json and print every option in effect
```

`lactase start --replace` takes over from another compositor (picom, compton...). Logs go to
`lactase.log` in milk's runtime folder, or to `~/.cache/lactase/` outside milk.

## Settings

Everything lives in `lactase.json` (in this folder, or `$LACTASE_CONFIG`). The settings app writes
it for you, and the running lactase reloads it by itself whenever it changes, so you can edit it by
hand too. Run `lactase check` to see the whole file with its defaults.

- **backend**: `glx` (OpenGL, the default) or `xrender`, the fallback, which has no blur and no
  vsync. When GLX cannot start, lactase falls back to XRender by itself.
- **followMilk**: take the corner radius and the animation speed from milk's settings.
- **shadows**: `radius` (softness), `opacity`, `offsetX`, `offsetY`, `color`.
- **animations**: `open` and `close` are `none`, `fade`, `zoom` or `slide`, with `openDuration` and
  `closeDuration` in milliseconds. `workspaces` fades windows and the wallpaper when milk switches
  areas.
- **opacity**: `active` and `inactive` windows, and `dimInactive` to darken unfocused ones.
- **blur**: blurs what is behind transparent windows, with a `strength` from 1 to 10.
- **corners**: `radius` in pixels. Windows the window manager already rounds are smoothed.
- **unredirectFullscreen**: full-screen games and videos skip the compositor.
- **rules**: per-window changes. A rule matches on `class`, `instance`, `title` (part of it) or
  `type` (`normal`, `dialog`, `dock`, `desktop`, `menu`, `tooltip`, `notification`...), and sets
  `opacity`, `shadow`, `blur`, `corners`, `animate` or `dim`. Later rules win.

```json
"rules": [
  {"type": "dock", "shadow": false, "corners": 0},
  {"class": "Alacritty", "opacity": 0.9, "blur": true}
]
```

The settings app can also pick a window with the mouse to make a rule for it.

### Credits
- [picom](https://github.com/yshui/picom), and compton and xcompmgr before it, for showing how an X11
  compositor should behave.
- Evan Wallace's closed form for the shadow of a rounded rectangle.
- Marius Bjørge's dual Kawase blur (ARM, "Bandwidth-Efficient Rendering").
