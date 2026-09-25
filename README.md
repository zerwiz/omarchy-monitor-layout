# Display layout — `zerwiz.monitor-layout`

An Omarchy bar-widget plugin that arranges monitors like the Ubuntu/GNOME
**Displays** settings panel: drag screens on a canvas with magnetic edge
snapping and animated snap-in, set resolution / scale / rotation / enabled /
main screen, apply arrangement presets, and save a layout that can never
overlap to Hyprland's `monitors.lua`.

```
┌ bar ──────────────────────────────────────────────┐
│ …  Display   ▣▣▣   Power                            │  ← click the screens icon
└────────────────────────────────────────────────────┘
```

- **Plugin id:** `zerwiz.monitor-layout`
- **Version:** 1.2.0 · **Kind:** `bar-widget` · **Entry:** `Panel.qml`
- **IPC target:** `zerwiz.monitor-layout`
- **Install path:** `~/.config/omarchy/plugins/zerwiz.monitor-layout/`
- **Config target:** `~/.config/hypr/monitors.lua` (backup: `monitors.lua.backup`)

## Features

- Drag-and-drop monitor canvas with **magnetic edge snapping** and an
  `OutBack` **snap-in animation** on release.
- **Live overlap feedback** — a screen that overlaps another turns red while
  dragging, and the layout is **untangled on release**.
- **Arrangement presets** (animated): *Side by side*, *Side by side (main
  first)*, *Stack vertically*.
- Per-screen controls: **Resolution** (from the advertised modes), **Scale**
  (0.75–2), **Rotation** (0/90/180/270), **Screen enabled**, **Make main
  screen**, **Center**.
- **Apply layout** (live via `hyprctl keyword monitor`) and **Save to config**
  (writes `monitors.lua`, reloads, verifies, and rolls back on error).
- **Hardware brightness and contrast** per screen, sent over **DDC/CI** with
  `ddcutil` (VCP `0x10` / `0x12`). The panel reads the monitor's current
  values on open and on every refresh, so a change made with the monitor's
  own buttons is picked up. If `ddcutil` or the i2c device is unavailable,
  the section is simply hidden and the rest of the panel keeps working.
- **Colour controls** for the Hyprland colour pipeline: colour-management
  preset, bit depth, transfer function, ICC profile, HDR and wide-gamut
  flags, plus SDR brightness/saturation. See *Limitations* — on several
  Hyprland versions the SDR fields are stored and read back but have no
  visible effect.
- **Reset to standard** — one button restores Hyprland's neutral colour
  (`cm = srgb`, default transfer function, SDR brightness/saturation 1, 8 bpc,
  no ICC) on every screen and sets DDC/CI hardware brightness and contrast to
  50% where the monitor answers. It confirms first. The colour half is saved
  and reloaded; the hardware half writes to the monitor's own firmware (it is
  the *only* way to undo a stray brightness/contrast change, since those are
  not in `monitors.lua`).
- Keyboard-navigable panel (arrow keys, `a`/`s`/`r`/`c`, Enter, Esc, Tab).
- **Save can never write an overlapping or negative-position layout.**

## Using it

1. Click the **Display layout** icon in the bar (right section, between
   *Display* and *Power*).
2. Arrange:
   - **Drag** a screen — it snaps edge-to-edge to nearby screens.
   - Or pick **Arrange → Side by side / (main first) / Stack vertically**.
   - Select a screen and set Resolution / Scale / Rotation / Enabled, or
     **Make main screen** / **Center**.
   - Or set **Brightness / Contrast** for the selected screen (needs
     `ddcutil`; the section hides itself when no DDC/CI is detected).
3. **Apply layout** to push positions live.
4. **Save to config** to persist to `~/.config/hypr/monitors.lua`.

### Keyboard

| Key | Action |
| --- | --- |
| Arrows | Move the selected screen 20 px (overlap-resolved) |
| Enter | Toggle enabled / make main (if enabled) |
| `a` | Apply layout |
| `s` | Save to config |
| `r` | Refresh from `hyprctl` |
| `c` | Center the selected screen |
| Tab | Switch panel |
| Esc | Close |

## Files

| File | Purpose |
| --- | --- |
| `manifest.json` | Plugin metadata (id, kind `bar-widget`, entry `Panel.qml`). |
| `Monitors.js` | Pure helper module: parsing, geometry, snapping, overlap resolution, sanitize, presets, Lua generation. |
| `Panel.qml` | The bar button + `KeyboardPanel` UI, `ListModel` data model, drag interaction, processes, IPC. |
| `README.md` | This document. |

The widget is placed in the bar by `~/.config/omarchy/shell.json` (right
section, between `omarchy.monitor` and `omarchy.power`).

## How it works

### Data flow

`hyprctl -j monitors` → `Monitors.parse()` → `ListModel` (`monitorModel` in
`Panel.qml`) → `Repeater` delegates on the canvas. Every mutation goes through
`monitorModel.setProperty(...)` so delegates persist and their `Behavior`
animations play. The model array is only reassigned on a full refresh.

`ListModel` roles: `name, description, x, y, mode, scale, transform,
logicalW, logicalH, disabled, focused, availableModes`.

### Canvas geometry (`Monitors.geometry`)

The bounding box of all enabled screens is fit into the canvas with a scale
`k` and translation `(ox, oy)`, so a monitor's on-canvas position is
`px = ox + m.x * k` (same for `y`). `logicalW/H` are the un-rotated pixel size
divided by scale, with width/height swapped for 90°/270° rotations.

### Snapping (`Monitors.snapPositions`)

A drag landing is magnetically pulled to nearby monitor edges (left/right/
top/bottom alignments) within a pixel threshold (`14 / k` logical px), plus
union-bounds and origin anchors. This is what makes screens "click" together
like the system panel.

### Overlap resolution (`Monitors.resolveNonOverlap`)

Given a proposed position, it searches candidate placements around every other
screen (all four edges, aligned corners) and the union corners, then returns
the non-overlapping candidate with the smallest L1 distance. Positions are
always clamped to `x ≥ 0, y ≥ 0`.

### Drag lifecycle

1. `startDrag` records the grab offset.
2. `dragTo` moves the delegate and recomputes `overlappedNames` for the red
   glow.
3. `endDrag`: clamp → resolve overlap → snap → resolve again, then
   `setPosition(...)` **before** clearing `dragging`, so the delegate animates
   once to the final snapped spot.

### Save pipeline

```
sanitize(current)          # resolve overlaps, clamp x/y ≥ 0
  → python3 write helper   # backs up to monitors.lua.backup, then writes
  → hyprctl reload
  → hyprctl configerrors
      ├─ clean → "Saved to ~/.config/hypr/monitors.lua"
      └─ error → revert from .backup → hyprctl reload
```

`Monitors.luaFor()` emits `hl.env("GDK_SCALE", ...)`, a generic
`hl.monitor({ output = "", ... })` line, then one `hl.monitor({...})` per
screen (`output`, `mode`, `position`, `scale`, optional `transform`; or
`disabled = true`).

### IPC

```
omarchy-shell zerwiz.monitor-layout open|close|toggle|show|hide
omarchy-shell zerwiz.monitor-layout refresh   # re-query hyprctl
omarchy-shell zerwiz.monitor-layout save      # write config
omarchy-shell zerwiz.monitor-layout dump      # JSON of current model (debug)
```

## Development notes & gotchas

- **Stale QML cache.** After editing plugin sources, clear
  `~/.cache/quickshell/qmlcache/*.jsc` or the old compiled copy can mask your
  changes (symptoms: errors pointing at old line numbers, `.pragma` complaints).
- **Hot-reload leaves a stale `IpcHandler`.** New/changed IPC methods won't be
  reachable until the shell restarts (`Handler … will not be used because
  another handler is registered for target …`).
- **Shell process.** The shell runs as `quickshell -n -p /usr/share/omarchy/shell`.
  `omarchy restart shell` can kill it without relaunching; if that happens,
  relaunch with:
  `setsid quickshell -n -p /usr/share/omarchy/shell >/tmp/quickshell.log 2>&1 </dev/null & disown`
- **Qt `Text` uses `font.family`**, not `fontFamily` (`fontFamily` only exists
  on kit widgets like `Button`/`Dropdown`).
- **Keep `monitorModel` out of eagerly-evaluated bindings.** The header summary
  is computed in `applyList` into `root.monitorSummary`; referencing the model
  from an inline binding that the layout forces during construction can throw
  `Cannot read property 'count' of undefined`.
- **Don't reassign the model array** to update a screen — use `setProperty`,
  otherwise delegates are recreated and snap animations are lost.

## Requirements

- Omarchy with Hyprland, and `hyprctl` on `PATH`.
- **Optional:** `ddcutil` for the hardware brightness/contrast controls.
  Without it (or without access to the i2c device) the panel still loads and
  works; only the DDC section is hidden.

```sh
pacman -S ddcutil
ddcutil detect          # should list your displays
ddcutil -d 1 getvcp 10 # brightness of display 1
```

## Limitations

- **Hyprland's SDR brightness and saturation are often inert.** Hyprland
  accepts, stores and reports back `sdrBrightness` and `sdrSaturation`, but on
  several setups (verified on Hyprland 0.56) changing them produces no visible
  change. That is why hardware brightness/contrast go through `ddcutil` instead.
  The compositor fields are still exposed, clearly labelled, because they do
  work on some configurations.
- **A screenshot cannot show a DDC brightness change.** The monitor scales the
  framebuffer in its own scaler, after the compositor has handed it over, so
  `grim` captures identical pixels at any brightness. Verify by eye, not with a
  screen capture.
- **DDC is monitor-specific.** Some panels implement only a subset of VCP
  codes, and a few ignore brightness entirely. A monitor that does not answer
  `getvcp 10 12` simply will not show the DDC section.
- **DDC values live in the monitor's firmware,** not in `monitors.lua`, so they
  are not written by *Save to config* and are not restored by `hyprctl reload`.
- Hyprland does not report `sdr_eotf`, HDR, wide-gamut or ICC state back from
  `hyprctl monitors`. Those fields are remembered in the plugin so saving does
  not silently drop them, but their current value cannot be read back from the
  compositor.

## Troubleshooting

```sh
# Is the plugin installed and active?
omarchy-shell shell listPlugins | grep monitor-layout

# Does the panel respond?
omarchy-shell zerwiz.monitor-layout refresh

# What is the live layout vs the saved file?
hyprctl -j monitors | python3 -m json.tool
hyprctl configerrors
cat ~/.config/hypr/monitors.lua
```

If the brightness/contrast sliders are missing, the plugin could not find a
DDC/CI display:

```sh
ddcutil detect                 # does it list both monitors?
ls -l /dev/i2c-*               # does the user have access?
id -nG | tr ' ' '\n' | grep i2c
```

Brightness/contrast need access to the i2c device, which on Arch is the
`i2c` group.

If a saved layout is bad, restore the previous file:

```sh
cp ~/.config/hypr/monitors.lua.backup ~/.config/hypr/monitors.lua
hyprctl reload
```

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 zerwiz.

## Contributors

See [CONTRIBUTORS.md](CONTRIBUTORS.md). Thanks to **Sebanionen** for Hyprland
0.56 support, the refresh-rate control, and the apply / mode-list / refresh
readback fixes.
