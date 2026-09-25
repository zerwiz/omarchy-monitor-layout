import QtQuick
import QtQuick.Controls
import QtQml.Models
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Monitors.js" as Mon

// Display layout panel: drag monitors to reposition with magnetic edge
// snapping and an animated snap-in (like GNOME's Displays), change
// mode/scale/rotation, choose arrangement presets, and save a layout
// that never overlaps.

Panel {
  id: root
  moduleName: "heimdallomarchy.monitor-layout"
  ipcTarget: "heimdallomarchy.monitor-layout"
  manageIpc: false

  // ---- theme helpers ---------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- state -----------------------------------------------------------
  property string selectedName: ""
  property int dragging: -1
  property bool draggingOverlap: false
  property string status: ""
  property bool saving: false
  property bool applying: false
  // Set when an apply is requested while another is still running.
  property bool applyQueued: false
  // Status to show once the next refresh lands, so a post-apply re-read does
  // not wipe the result message.
  property string pendingStatus: ""
  property bool cursorActive: false
  property var overlapNames: []
  // Monitor name -> advertised mode strings. Kept out of monitorModel because
  // QQmlListModel mangles nested-array roles into opaque objects.
  property var modeOptions: ({})
  // Monitor name -> { sdrEotf, supportsHdr, supportsWideColor, icc }.
  // hyprctl does not read these four back, so without this a refresh would
  // silently reset them and the next Save would write the defaults instead.
  property var colorSticky: ({})
  property int totalCount: 0
  property int enabledCount: 0
  property string monitorSummary: "0 of 0 on"

  // drag bookkeeping (canvas pixels)
  property real dragStartPx: 0
  property real dragStartPy: 0
  property real dragGrabX: 0
  property real dragGrabY: 0
  property real dragPx: 0
  property real dragPy: 0

  // canvas geometry (k = logical->px scale, ox/oy = origin translation)
  property real canvasW: 0
  property real canvasH: 0
  property real k: 1
  property real ox: 0
  property real oy: 0

  property double nowMs: Date.now()

  readonly property string configPath: Color.home + "/.config/hypr/monitors.lua"

  readonly property int selectedIndex: {
    // Guard: monitorModel may not be created yet during construction.
    if (!monitorModel || monitorModel.count === undefined) return -1
    var n = monitorModel.count
    for (var i = 0; i < n; i++)
      if (monitorModel.get(i).name === root.selectedName) return i
    return -1
  }
  readonly property var sel: (root.selectedIndex >= 0 && monitorModel && monitorModel.count > root.selectedIndex)
    ? { name: monitorModel.get(root.selectedIndex).name,
        scale: monitorModel.get(root.selectedIndex).scale,
        transform: monitorModel.get(root.selectedIndex).transform,
        mode: monitorModel.get(root.selectedIndex).mode,
        description: monitorModel.get(root.selectedIndex).description,
        disabled: monitorModel.get(root.selectedIndex).disabled,
        focused: monitorModel.get(root.selectedIndex).focused,
        availableModes: root.modeOptions[monitorModel.get(root.selectedIndex).name] || [],
        cm: monitorModel.get(root.selectedIndex).cm,
        sdrBrightness: monitorModel.get(root.selectedIndex).sdrBrightness,
        sdrSaturation: monitorModel.get(root.selectedIndex).sdrSaturation,
        bitdepth: monitorModel.get(root.selectedIndex).bitdepth,
        sdrEotf: monitorModel.get(root.selectedIndex).sdrEotf,
        supportsHdr: monitorModel.get(root.selectedIndex).supportsHdr,
        supportsWideColor: monitorModel.get(root.selectedIndex).supportsWideColor,
        icc: monitorModel.get(root.selectedIndex).icc,
        ddcAvailable: monitorModel.get(root.selectedIndex).ddcAvailable,
        ddcBrightness: monitorModel.get(root.selectedIndex).ddcBrightness,
        ddcContrast: monitorModel.get(root.selectedIndex).ddcContrast }
    : null

  readonly property string writeHelper: [
    "import sys,os",
    "p=sys.argv[1]; d=sys.argv[2]",
    "try:",
    "    old=open(p).read()",
    "except Exception: old=None",
    "if old is not None:",
    "    try: open(p+'.backup','w').write(old)",
    "    except Exception: pass",
    "open(p,'w').write(d)",
    "print('written')"
  ].join("\n")

  readonly property string revertHelper: [
    "import sys,os",
    "p=sys.argv[1]",
    "try: open(p,'w').write(open(p+'.backup').read())",
    "except Exception: pass",
    "print('reverted')"
  ].join("\n")

  visible: root.totalCount > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (root.opened) {
    cursorActive = false
    nowMs = Date.now()
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: {
    // Refresh is scheduled first and unconditionally: DDC/CI is an optional
    // extra, so a failure there (no binary, no i2c permission) must never stop
    // the monitor list from loading.
    Qt.callLater(root.refresh)
    try {
      root.startDdc()
    } catch (e) {
      console.log("monitor-layout: DDC/CI unavailable:", e)
    }
  }

  onSelectedIndexChanged: {
    // ddcDisplays may only have been filled in after the first detect.
    if (root.sel && root.ddcSupports(root.sel.name)) root.readDdc(root.sel.name)
  }

  // ---- data ------------------------------------------------------------
  ListModel {
    id: monitorModel
  }

  function currentMonitors() {
    var out = []
    for (var i = 0; i < monitorModel.count; i++) out.push(monitorModel.get(i))
    return out
  }

  function refresh() {
    if (refreshProc.running) return
    refreshProc.running = true
  }

  function applyList(raw) {
    // StdioCollector can fire with an empty/undefined payload; clearing the
    // model on that would blank the panel with "No monitors found".
    if (raw === undefined || raw === null || String(raw).trim() === "") return
    if (root.dragging >= 0) return
    var arr = Mon.parse(raw)
    var keep = { name: "", x: 0, y: 0, scale: 1, transform: 0, mode: "preferred", disabled: true, focused: false }
    if (root.selectedIndex >= 0 && root.selectedIndex < monitorModel.count)
      keep = monitorModel.get(root.selectedIndex)

    monitorModel.clear()
    var modes = {}
    var sticky = {}
    for (var i = 0; i < arr.length; i++) {
      var m = arr[i]
      modes[m.name] = Mon.toArray(m.availableModes)
      var stick = root.colorSticky[m.name]
      if (stick) {
        m.sdrEotf = stick.sdrEotf
        m.supportsHdr = stick.supportsHdr
        m.supportsWideColor = stick.supportsWideColor
        m.icc = stick.icc
      }
      sticky[m.name] = { sdrEotf: m.sdrEotf, supportsHdr: m.supportsHdr,
                        supportsWideColor: m.supportsWideColor, icc: m.icc }
      // availableModes is carried in root.modeOptions, not as a model role.
      monitorModel.append({
        name: m.name, description: m.description, x: m.x, y: m.y,
        mode: m.mode, scale: m.scale, transform: m.transform,
        logicalW: m.logicalW, logicalH: m.logicalH,
        disabled: m.disabled, focused: m.focused,
        cm: m.cm, sdrBrightness: m.sdrBrightness, sdrSaturation: m.sdrSaturation,
        bitdepth: m.bitdepth, sdrEotf: m.sdrEotf, supportsHdr: m.supportsHdr,
        supportsWideColor: m.supportsWideColor, icc: m.icc,
        ddcAvailable: root.ddcNumber(m.name) > 0,
        ddcBrightness: Mon.ddcValueFor(root.ddcValues[m.name], "brightness"),
        ddcContrast: Mon.ddcValueFor(root.ddcValues[m.name], "contrast")
      })
      if (m.name === keep.name) {
        monitorModel.setProperty(monitorModel.count - 1, "x", keep.x)
        monitorModel.setProperty(monitorModel.count - 1, "y", keep.y)
      }
    }
    root.modeOptions = modes
    root.colorSticky = sticky

    var on = 0
    for (var j = 0; j < monitorModel.count; j++)
      if (!monitorModel.get(j).disabled) on++
    root.totalCount = monitorModel.count
    root.enabledCount = on
    root.monitorSummary = on + " of " + monitorModel.count + " on"

    if (root.selectedName !== "" && root.selectedIndex < 0) root.selectedName = ""
    if (root.selectedName === "" && monitorModel.count > 0) root.selectedName = monitorModel.get(0).name
    root.status = monitorModel.count === 0 ? "No monitors found" : root.pendingStatus
    root.pendingStatus = ""
    root.recalcCanvas()
  }

  function writeRow(i, values) {
    for (var key in values) monitorModel.setProperty(i, key, values[key])
  }

  function currentRow(i) {
    return i >= 0 && i < monitorModel.count ? monitorModel.get(i) : null
  }

  function recalcCanvas() {
    if (root.canvasW < 50 || root.canvasH < 50) return
    var g = Mon.geometry(root.currentMonitors(), root.canvasW, root.canvasH)
    root.k = g.k
    root.ox = g.ox
    root.oy = g.oy
  }

  // ---- model edits -----------------------------------------------------
  function setPosition(i, x, y) {
    if (i < 0 || i >= monitorModel.count) return
    writeRow(i, { x: Math.round(x), y: Math.round(y) })
    Qt.callLater(function() { root.applyOne(i) })
  }

  function setScale(name, scale) {
    var arr = root.currentMonitors()
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].name !== name) continue
      var res = Mon.resolutionOf(arr[i].mode)
      var lw = res.w / scale
      var lh = res.h / scale
      if (arr[i].transform % 2 === 1) { var t = lw; lw = lh; lh = t }
      writeRow(i, { scale: scale, logicalW: Math.max(1, Math.round(lw)), logicalH: Math.max(1, Math.round(lh)) })
      Qt.callLater(function() { root.applyOne(i) })
      return
    }
  }

  function setRotation(name, transform) {
    var t = (transform % 4 + 4) % 4
    var arr = root.currentMonitors()
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].name !== name) continue
      var res = Mon.resolutionOf(arr[i].mode)
      var lw = res.w / arr[i].scale
      var lh = res.h / arr[i].scale
      if (t % 2 === 1) { var w = lw; lw = lh; lh = w }
      writeRow(i, { transform: t, logicalW: Math.max(1, Math.round(lw)), logicalH: Math.max(1, Math.round(lh)) })
      Qt.callLater(function() { root.applyOne(i) })
      return
    }
  }

  function setMode(name, mode) {
    var arr = root.currentMonitors()
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].name !== name) continue
      var res = Mon.resolutionOf(mode)
      var lw = res.w / arr[i].scale
      var lh = res.h / arr[i].scale
      if (arr[i].transform % 2 === 1) { var w = lw; lw = lh; lh = w }
      writeRow(i, { mode: mode, logicalW: Math.max(1, Math.round(lw)), logicalH: Math.max(1, Math.round(lh)) })
      Qt.callLater(function() { root.applyOne(i) })
      return
    }
  }

  // Change only the refresh rate, keeping the current resolution.
  function setRate(name, rate) {
    var arr = root.currentMonitors()
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].name !== name) continue
      var res = Mon.splitMode(arr[i].mode).res
      if (res === "") res = Mon.splitMode(root.modeOptions[name] ? root.modeOptions[name][0] : "").res
      root.setMode(name, Mon.modeFor(res, rate))
      return
    }
  }

  function setEnabled(name, enabled) {
    var arr = root.currentMonitors()
    for (var i = 0; i < arr.length; i++)
      if (arr[i].name === name) { writeRow(i, { disabled: !enabled }); root.applyOne(i); break }
  }

  // ---- colour ----------------------------------------------------------
  // Colour changes go out as a colour-only rule, so they do not re-apply
  // geometry. The four fields hyprctl cannot read back are remembered in
  // root.colorSticky; the rest are authoritative from hyprctl.
  function setColor(name, field, value) {
    var i = -1
    var arr = root.currentMonitors()
    for (var j = 0; j < arr.length; j++) if (arr[j].name === name) { i = j; break }
    if (i < 0) return
    var values = {}
    values[field] = value
    writeRow(i, values)

    var m = monitorModel.get(i)
    var sticky = root.colorSticky[name] || {}
    sticky.sdrEotf = m.sdrEotf
    sticky.supportsHdr = m.supportsHdr
    sticky.supportsWideColor = m.supportsWideColor
    sticky.icc = m.icc
    root.colorSticky[name] = sticky

    applyColor(i)
  }

  function applyColor(i) {
    if (applyProc.running) return
    var m = monitorModel.get(i)
    if (!m || m.disabled) return
    applyProc.command = ["hyprctl", "eval", Mon.colorLuaFor(m)]
    root.applying = true
    applyProc.running = true
  }

  // ---- DDC/CI (monitor hardware) ---------------------------------------
  function monitorIndexOf(name) {
    for (var j = 0; j < monitorModel.count; j++) if (monitorModel.get(j).name === name) return j
    return -1
  }

  // Hyprland's sdrbrightness / sdrsaturation / sdr_eotf are accepted and read
  // back but do not change the rendered image on this machine (verified: 0.4
  // and 2.0 produce byte-identical pixels, while `cm` demonstrably does
  // change them). Real brightness and contrast therefore go to the monitor
  // itself over DDC/CI, which is a different pipeline and does work. Values
  // live in the monitor's own firmware, so nothing is written to monitors.lua
  // and no re-apply is needed after a reload.
  //
  // Output name -> ddcutil display number, from `ddcutil detect`.
  property var ddcDisplays: ({})
  // Last known hardware values per output, so a monitor refresh (which rebuilds the
  // ListModel) does not wipe the brightness/contrast readback until the next getvcp.
  property var ddcValues: ({})

  function ddcNumber(name) {
    var n = root.ddcDisplays[name]
    return typeof n === "number" ? n : -1
  }

  function ddcSupports(name) {
    return root.ddcNumber(name) > 0
  }

  function startDdc() {
    if (ddcDetectProc.running || Object.keys(root.ddcDisplays).length > 0) return
    ddcDetectProc.running = true
  }

  // Re-read the two features for one monitor. Reads are queued rather than
  // dropped, because ddcutil is a single shared process: asking for both
  // monitors at once would otherwise silently lose the second.
  property var ddcQueue: ([])

  function readDdc(name) {
    if (root.ddcNumber(name) <= 0) return
    if (ddcGetProc.running) {
      if (root.ddcQueue.indexOf(name) < 0) root.ddcQueue.push(name)
      return
    }
    ddcGetProc.targetName = name
    ddcGetProc.command = ["ddcutil", "-d", String(root.ddcNumber(name)), "getvcp", "10", "12"]
    ddcGetProc.running = true
  }

  // Called when a getvcp finishes: update the model, then drain the queue.
  function ddcReadDone() {
    var name = ddcGetProc.targetName
    if (name) {
      var values = ddcGetProc.lastValues
      var known = root.ddcValues[name] || {}
      if (Mon.ddcValueFor(values, "brightness") >= 0) known.brightness = values.brightness
      if (Mon.ddcValueFor(values, "contrast") >= 0) known.contrast = values.contrast
      root.ddcValues[name] = known
      var i = root.monitorIndexOf(name)
      if (i >= 0) {
        if (Mon.ddcValueFor(known, "brightness") >= 0)
          monitorModel.setProperty(i, "ddcBrightness", known.brightness)
        if (Mon.ddcValueFor(known, "contrast") >= 0)
          monitorModel.setProperty(i, "ddcContrast", known.contrast)
      }
    }
    ddcGetProc.targetName = ""
    if (root.ddcQueue.length > 0) {
      var next = root.ddcQueue.shift()
      root.ddcQueue = root.ddcQueue
      root.readDdc(next)
    }
  }

  function setDdc(name, field, value) {
    var n = root.ddcNumber(name)
    if (n <= 0 || ddcSetProc.running) return
    var code = field === "contrast" ? "12" : "10"
    ddcSetProc.targetName = name
    ddcSetProc.command = ["ddcutil", "-d", String(n), "setvcp", code, String(Math.round(value))]
    ddcSetProc.running = true
    // Optimistic update so the slider does not snap back while ddcutil runs.
    var i = root.monitorIndexOf(name)
    if (i >= 0) monitorModel.setProperty(i, "ddc" + field.charAt(0).toUpperCase() + field.slice(1), Math.round(value))
  }

  // ---- arrangements ----------------------------------------------------
  function applyPreset(kind) {
    var arr = root.currentMonitors()
    var gap = (kind === "row-gap") ? 10 : undefined
    var placements

    if (kind === "above" || kind === "below") {
      if (!root.sel || root.sel.disabled) { root.status = "Select a screen first"; return }
      placements = placeRelative(arr, kind)
    } else {
      placements = Mon.presetLayout(arr, kind, gap)
    }

    for (var j = 0; j < placements.length; j++) {
      writeRow(placements[j].index, { x: Math.round(placements[j].x), y: Math.round(placements[j].y) })
    }
    var fixed = Mon.sanitize(root.currentMonitors())
    if (fixed.changed) {
      for (j = 0; j < fixed.list.length; j++) {
        writeRow(j, { x: fixed.list[j].x, y: fixed.list[j].y })
      }
    }
    root.status = "Arrangement applied"
    Qt.callLater(function() { root.applyAll() })
  }

  function placeRelative(monitors, direction) {
    var selIdx = root.selectedIndex
    if (selIdx < 0) return []

    // Find the screen to stack against: the one most overlapping/nearest horizontally
    var sel = monitors[selIdx]
    var targetIdx = -1
    var bestOverlap = -1

    for (var i = 0; i < monitors.length; i++) {
      if (i === selIdx || monitors[i].disabled) continue
      var o = monitors[i]
      var xOverlap = Math.max(0, Math.min(sel.x + sel.logicalW, o.x + o.logicalW) - Math.max(sel.x, o.x))
      if (xOverlap > bestOverlap) { bestOverlap = xOverlap; targetIdx = i }
    }

    // If no horizontal overlap, pick nearest by center distance
    if (targetIdx < 0) {
      var selCenter = sel.x + sel.logicalW / 2
      var minDist = Infinity
      for (var j = 0; j < monitors.length; j++) {
        if (j === selIdx || monitors[j].disabled) continue
        var o = monitors[j]
        var oCenter = o.x + o.logicalW / 2
        var dist = Math.abs(selCenter - oCenter)
        if (dist < minDist) { minDist = dist; targetIdx = j }
      }
    }

    if (targetIdx < 0) return []

    var target = monitors[targetIdx]
    var newX = target.x + Math.round((target.logicalW - sel.logicalW) / 2)
    var newY = (direction === "above") ? target.y - sel.logicalH : target.y + target.logicalH

    var out = []
    for (var k = 0; k < monitors.length; k++) {
      if (k === selIdx) out.push({ index: k, x: newX, y: newY })
      else out.push({ index: k, x: monitors[k].x, y: monitors[k].y })
    }
    return out
  }

  function makeMain(name) {
    var arr = root.currentMonitors()
    var idx = -1
    for (var i = 0; i < arr.length; i++) if (arr[i].name === name) { idx = i; break }
    if (idx < 0) return
    // Pretend the chosen monitor is focused so the preset leads with it.
    var planted = arr.map(function(m) { return Mon.clone(m) })
    for (var j = 0; j < planted.length; j++) planted[j].focused = (j === idx)
    var placements = Mon.presetLayout(planted, "row-main")
    for (var p = 0; p < placements.length; p++) {
      writeRow(placements[p].index, { x: Math.round(placements[p].x), y: Math.round(placements[p].y) })
    }
    root.selectedName = name
    focusProc.command = ["hyprctl", "dispatch", "focusmonitor", name]
    focusProc.running = true
    Qt.callLater(function() { root.applyAll() })
  }

  function centerSelected() {
    if (!root.sel || root.sel.disabled) return
    var arr = root.currentMonitors()
    var c = Mon.centerFor(arr, root.selectedIndex)
    if (c) root.setPosition(root.selectedIndex, c.x, c.y)
  }

  function moveSelected(dx, dy) {
    if (root.selectedIndex < 0) return
    var arr = root.currentMonitors()
    var i = root.selectedIndex
    var m = arr[i]
    var nx = m.x + dx
    var ny = m.y + dy
    var cl = Mon.clampLogical(m, nx, ny, 6 * m.logicalW, 6 * m.logicalH)
    var r = Mon.resolveNonOverlap(arr, i, cl.x, cl.y)
    root.setPosition(i, r.x, r.y)
  }

  // ---- apply -----------------------------------------------------------
  // Hyprland 0.56 dropped the legacy parser, so `hyprctl keyword` is rejected;
  // runtime changes go through `hyprctl eval` with the config's Lua syntax.
  function applyOne(index) {
    if (applyProc.running) return
    var lua = Mon.monitorLuaFor(root.currentMonitors()[index])
    if (!lua) return
    applyProc.command = ["hyprctl", "eval", lua]
    root.applying = true
    applyProc.running = true
  }

  function applyAll() {
    // Never drop a request because one is already in flight: remember it and
    // re-run when the current apply finishes, otherwise the button looks dead.
    if (applyProc.running) { root.applyQueued = true; return }
    var arr = root.currentMonitors()
    if (arr.length === 0) { root.status = "No monitors to apply"; return }
    var lines = []
    for (var i = 0; i < arr.length; i++) lines.push(Mon.monitorLuaFor(arr[i]))
    applyProc.command = ["hyprctl", "eval", lines.join("\n")]
    root.applying = true
    applyProc.running = true
  }

  // ---- save ------------------------------------------------------------
  function saveConfig() {
    if (root.saving || monitorModel.count === 0) return
    var fixed = Mon.sanitize(root.currentMonitors())
    for (var i = 0; i < fixed.list.length; i++) {
      writeRow(i, { x: fixed.list[i].x, y: fixed.list[i].y })
    }
    root.saving = true
    root.status = fixed.changed ? "Fixed an overlapping layout, saving…" : "Saving layout…"
    saveWriteProc.command = ["python3", "-c", root.writeHelper, root.configPath, Mon.luaFor(fixed.list)]
    saveWriteProc.running = true
  }

  function handleConfigErrors(text) {
    var t = String(text || "").trim()
    if (/error/i.test(t)) {
      root.status = "Config errors — restoring previous file."
      revertProc.command = ["python3", "-c", root.revertHelper, root.configPath]
      revertProc.running = true
    } else {
      root.status = "Saved to " + root.configPath.replace(Color.home, "~")
      root.saving = false
    }
  }

  // ---- dragging --------------------------------------------------------
  function startDrag(index, px, py, gx, gy) {
    root.dragging = index
    root.dragStartPx = px
    root.dragStartPy = py
    root.dragPx = px
    root.dragPy = py
    root.dragGrabX = gx
    root.dragGrabY = gy
    root.draggingOverlap = false
    root.overlapNames = []
  }

  function dragTo(px, py) {
    if (root.dragging < 0) return
    var targetPx = root.dragStartPx + (px - root.dragGrabX)
    var targetPy = root.dragStartPy + (py - root.dragGrabY)

    // Convert to logical and clamp inside canvas bounds so screens never
    // escape the canvas area (which would overlap the header/controls).
    var arr = root.currentMonitors()
    var m = arr[root.dragging]
    if (!m) return
    var nx = (targetPx - root.ox) / root.k
    var ny = (targetPy - root.oy) / root.k
    var cw = Math.max(1, root.canvasW / root.k)
    var ch = Math.max(1, root.canvasH / root.k)
    var cl = Mon.clampLogical(m, nx, ny, cw, ch)

    // Convert back to canvas pixels for the delegate position.
    root.dragPx = root.ox + cl.x * root.k
    root.dragPy = root.oy + cl.y * root.k

    // Live overlap feedback (still shows red glow if overlap remains).
    var names = Mon.overlappedNames(arr, root.dragging, cl.x, cl.y)
    root.overlapNames = names
    root.draggingOverlap = names.length > 0
  }

  function endDrag(index) {
    if (index < 0) return
    var arr = root.currentMonitors()
    var m = arr[index]
    var cw = Math.max(1, root.canvasW / root.k)
    var ch = Math.max(1, root.canvasH / root.k)
    var nx = (root.dragPx - root.ox) / root.k
    var ny = (root.dragPy - root.oy) / root.k
    var cl = Mon.clampLogical(m, nx, ny, cw, ch)
    var r = Mon.resolveNonOverlap(arr, index, cl.x, cl.y)
    var s = Mon.snapPositions(arr, index, r.x, r.y, root.k)
    var r2 = Mon.resolveNonOverlap(arr, index, s.x, s.y)
    // Commit the final position first so the binding re-evaluation that
    // follows `dragging = -1` targets the snapped spot in one animation.
    root.setPosition(index, r2.x, r2.y)
    root.dragging = -1
    root.draggingOverlap = false
    root.overlapNames = []
  }

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 20000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function save(): string { root.saveConfig(); return "ok" }
    // Exercises the real DDC path so it can be driven and checked without a
    // mouse: ddcprobe <output>, ddcset <output> <brightness|contrast> <0-100>
    function ddcprobe(output: string): string {
      root.startDdc()
      if (output) root.readDdc(output)
      return JSON.stringify(root.ddcDisplays)
    }
    function ddcset(output: string, field: string, value: string): string {
      root.setDdc(output, field, parseInt(value, 10))
      return "ok"
    }
    function dump(): string {
      var out = []
      for (var i = 0; i < monitorModel.count; i++) {
        var m = monitorModel.get(i)
        var modes = root.modeOptions[m.name] || []
        var res = Mon.splitMode(m.mode).res
        out.push({
          name: m.name, mode: m.mode, resolution: res,
          rate: Mon.splitMode(m.mode).rate,
          ratesForResolution: Mon.ratesFor(modes, res),
          modeCount: modes.length,
          cm: m.cm, sdrEotf: m.sdrEotf,
          sdrBrightness: m.sdrBrightness, sdrSaturation: m.sdrSaturation,
          bitdepth: m.bitdepth, supportsHdr: m.supportsHdr,
          supportsWideColor: m.supportsWideColor, icc: m.icc,
          ddcNumber: root.ddcNumber(m.name), ddcAvailable: m.ddcAvailable,
          ddcBrightness: m.ddcBrightness, ddcContrast: m.ddcContrast
        })
      }
      return JSON.stringify({
        count: monitorModel.count,
        selectedIndex: root.selectedIndex,
        ddcDisplays: root.ddcDisplays,
        monitors: out
      })
    }
  }

  // ---- processes -------------------------------------------------------
  Process {
    id: refreshProc
    running: false
    command: ["hyprctl", "-j", "monitors"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyList(text)
        // The monitor's own firmware is the source of truth here, so re-read
        // on every refresh: the value may have been changed with the monitor's
        // physical buttons since the panel was last open.
        if (root.sel && root.ddcSupports(root.sel.name)) root.readDdc(root.sel.name)
      }
    }

    onExited: function(code) {
      if (code !== 0) root.status = "Failed to query monitors"
    }
  }

  Process {
    id: applyProc
    running: false
    command: ["true"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "" && t !== "ok") root.status = "hyprctl: " + t
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") root.status = "hyprctl: " + t
      }
    }

    onExited: function(code) {
      root.applying = false
      if (code === 0) {
        if (root.status.indexOf("hyprctl:") !== 0) root.pendingStatus = "Layout applied"
        // Re-read so the panel shows what Hyprland actually took, not what we
        // asked for; a rejected rule shows up as a mismatch here.
        root.refresh()
      } else if (root.status.indexOf("hyprctl:") !== 0) {
        root.status = "Apply failed (hyprctl exit " + code + ")"
      }
      if (root.applyQueued) {
        root.applyQueued = false
        Qt.callLater(function() { root.applyAll() })
      }
    }
  }

  Process {
    id: ddcDetectProc
    running: false
    command: ["ddcutil", "detect"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = Mon.parseDdcDetect(text)
        var names = Object.keys(found)
        if (names.length === 0) {
          // No DDC/CI, or no permission for the i2c device. The panel falls back
          // to showing only the Hyprland colour fields.
          root.ddcDisplays = ({})
          return
        }
        root.ddcDisplays = found
        for (var i = 0; i < names.length; i++) {
          root.readDdc(names[i])
          var row = root.monitorIndexOf(names[i])
          if (row >= 0) monitorModel.setProperty(row, "ddcAvailable", true)
        }
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "") root.status = "ddcutil: " + String(text).trim()
      }
    }
  }

  Process {
    id: ddcGetProc
    running: false
    command: ["true"]
    property string targetName: ""
    // Parsed by the collector, applied in onExited so the model is only touched
    // once the whole (possibly empty) output has arrived.
    property var lastValues: ({})

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: ddcGetProc.lastValues = Mon.parseDdcValues(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "") root.status = "ddcutil: " + String(text).trim()
      }
    }

    onExited: root.ddcReadDone()
  }

  Process {
    id: ddcSetProc
    running: false
    command: ["true"]
    property string targetName: ""

    onExited: function(code) {
      if (code !== 0) root.status = "Monitor rejected the value (ddcutil exit " + code + ")"
      // Read back so the slider shows the value the monitor actually stored.
      if (ddcSetProc.targetName) root.readDdc(ddcSetProc.targetName)
    }
  }

  Process {
    id: focusProc
    running: false
    command: ["true"]
  }

  Process {
    id: saveWriteProc
    running: false
    command: ["true"]

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "") root.status = "save error: " + String(text).trim()
      }
    }

    onExited: function(code) {
      if (code === 0) {
        root.status = "Reloading Hyprland…"
        saveReloadProc.running = true
      } else {
        root.saving = false
      }
    }
  }

  Process {
    id: saveReloadProc
    running: false
    command: ["hyprctl", "reload"]

    onExited: function(code) {
      root.status = code === 0 ? "Checking config…" : "hyprctl reload failed"
      saveCheckProc.running = true
    }
  }

  Process {
    id: saveCheckProc
    running: false
    command: ["hyprctl", "configerrors"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleConfigErrors(text)
    }
  }

  Process {
    id: revertProc
    running: false
    command: ["true"]

    onExited: function(code) {
      root.saving = false
      if (code === 0) {
        root.status = "Configuration restored to previous version"
        reloadAgainProc.running = true
      } else {
        root.status = "Could not restore previous config"
      }
    }
  }

  Process {
    id: reloadAgainProc
    running: false
    command: ["hyprctl", "reload"]
  }

  // ---- bar button ------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\ue9c3"
    slotSize: Style.bar.statusSlot
    tooltipText: "Display layout"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  // ---- panel -----------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0 || dy !== 0) {
          root.cursorActive = true
          if (root.selectedIndex < 0) {
            root.selectedName = monitorModel.count > 0 ? monitorModel.get(0).name : ""
            return
          }
          root.moveSelected(dx * 20, dy * 20)
        }
      }
      onActivateRequested: {
        if (root.selectedIndex < 0) return
        if (root.sel && root.sel.disabled) root.setEnabled(root.sel.name, true)
        else if (root.sel) root.makeMain(root.sel.name)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "A") root.applyAll()
        else if (t === "s" || t === "S") root.saveConfig()
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "c" || t === "C") root.centerSelected()
      }
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: parent.width
        spacing: Style.spacing.lg

        // ---- header ----
        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, countText.implicitHeight)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Display layout"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: root.foreground
            font.bold: true
          }

          Text {
            id: countText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.monitorSummary
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.dim
          }
        }

        // ---- canvas ----
        Item {
          id: canvas
          width: parent.width
          height: Math.max(120, Math.min(230, Math.round(width * 0.42)))
          clip: true
          onWidthChanged: { root.canvasW = width; root.recalcCanvas() }
          onHeightChanged: { root.canvasH = height; root.recalcCanvas() }

          Rectangle {
            id: canvasBg
            anchors.fill: parent
            radius: Style.cornerRadius > 0 ? Math.min(6, Style.space(6)) : 0
            color: Qt.darker(root.surface, 1.07)
            border.color: root.line
            border.width: 1
          }

          Text {
            anchors.centerIn: parent
            visible: monitorModel.count === 0
            text: "No monitors"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.dim
          }

          Repeater {
            model: monitorModel
            delegate: monDelegate
          }
        }

        Text {
          width: parent.width
          text: root.draggingOverlap
            ? "Overlapping — release to snap the screen into place."
            : "Drag a screen to move it (screens snap edge-to-edge). Click to select."
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: root.draggingOverlap ? root.urgent : root.dim
          wrapMode: Text.WordWrap
        }

        // ---- arrangement presets ----
        Dropdown {
          id: presetDrop
          width: parent.width
          showLabel: true
          label: "Arrange"
          fontFamily: root.fontFamily
          foreground: root.foreground
          options: [
            { value: "row", label: "Side by side" },
            { value: "row-gap", label: "Side by side (with gap)" },
            { value: "row-main", label: "Side by side (main first)" },
            { value: "stack", label: "Stack vertically" },
            { value: "above", label: "Place selected above" },
            { value: "below", label: "Place selected below" }
          ]
          onChanged: function(value) { root.applyPreset(value) }
        }

        // ---- selected controls ----
        Item {
          width: parent.width
          height: root.sel ? controls.implicitHeight : 0
          visible: !!root.sel

          Column {
            id: controls
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.md

            // name row
            Row {
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                text: root.sel ? root.sel.name : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
                font.bold: true
              }

              Text {
                text: root.sel && root.sel.focused ? "  main" : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.accent
                font.bold: true
              }

              Text {
                text: root.sel && root.sel.description !== "" ? "  " + root.sel.description : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                elide: Text.ElideRight
              }
            }

            // scale + rotation
            Row {
              width: parent.width
              spacing: Style.spacing.md

              Dropdown {
                width: (parent.width - parent.spacing) / 2
                showLabel: true
                label: "Scale"
                fontFamily: root.fontFamily
                foreground: root.foreground
                options: ["0.75", "1", "1.25", "1.5", "1.75", "2"]
                value: root.sel ? String(root.sel.scale) : "1"
                onChanged: function(value) {
                  if (root.sel) root.setScale(root.sel.name, parseFloat(value))
                }
              }

              Dropdown {
                width: (parent.width - parent.spacing) / 2
                showLabel: true
                label: "Rotation"
                fontFamily: root.fontFamily
                foreground: root.foreground
                options: [
                  { value: "0", label: "0°" },
                  { value: "1", label: "90°" },
                  { value: "2", label: "180°" },
                  { value: "3", label: "270°" }
                ]
                value: root.sel ? String(root.sel.transform) : "0"
                onChanged: function(value) {
                  if (root.sel) root.setRotation(root.sel.name, parseInt(value, 10))
                }
              }
            }

            // mode
            Dropdown {
              width: parent.width
              showLabel: true
              label: "Resolution"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: root.sel ? root.sel.availableModes : []
              value: root.sel ? root.sel.mode : ""
              onChanged: function(value) {
                if (root.sel) root.setMode(root.sel.name, value)
              }
            }

            // refresh rate, restricted to the rates the chosen resolution offers
            Dropdown {
              width: parent.width
              showLabel: true
              label: "Refresh rate"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: root.sel
                ? Mon.ratesFor(root.sel.availableModes, Mon.splitMode(root.sel.mode).res)
                    .map(function(r) { return { value: r, label: r + " Hz" } })
                : []
              value: root.sel ? Mon.splitMode(root.sel.mode).rate : ""
              onChanged: function(value) {
                if (root.sel) root.setRate(root.sel.name, value)
              }
            }

            // enabled
            Item {
              width: parent.width
              height: Math.max(enabledText.implicitHeight, 20)

              Text {
                id: enabledText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Screen enabled"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
              }

              ToggleSwitch {
                id: enableSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.sel ? !root.sel.disabled : false
                onToggled: if (root.sel) root.setEnabled(root.sel.name, checked)
              }
            }

            // ---- monitor hardware (DDC/CI) ----
            Rectangle {
              width: parent.width
              height: 1
              color: root.line
            }

            Text {
              width: parent.width
              text: "Monitor"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.foreground
            }

            Text {
              width: parent.width
              text: root.sel && root.sel.ddcAvailable
                    ? "Brightness and contrast are set on the monitor itself over DDC/CI, so they work for everything on screen and survive a reload."
                    : "This monitor did not answer DDC/CI, so hardware brightness and contrast are unavailable. Try adding yourself to the i2c group if it should have."
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.dim
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.sel !== null && root.sel.ddcAvailable

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Item {
                  width: parent.width
                  height: Style.font.caption * 1.6

                  Text {
                    text: "Brightness"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.sel && root.sel.ddcBrightness >= 0
                          ? Math.round(ddcBrightnessSlider.liveValue) + "%" : "—"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                PanelSlider {
                  id: ddcBrightnessSlider
                  width: parent.width
                  minimum: 0
                  maximum: 100
                  step: 1
                  value: root.sel && root.sel.ddcBrightness >= 0 ? root.sel.ddcBrightness : 100
                  // Commit on release: a ddcutil call per drag step would be
                  // far too chatty over I2C.
                  onReleased: function(v) {
                    if (root.sel) root.setDdc(root.sel.name, "brightness", v)
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Item {
                  width: parent.width
                  height: Style.font.caption * 1.6

                  Text {
                    text: "Contrast"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.sel && root.sel.ddcContrast >= 0
                          ? Math.round(ddcContrastSlider.liveValue) + "%" : "—"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                PanelSlider {
                  id: ddcContrastSlider
                  width: parent.width
                  minimum: 0
                  maximum: 100
                  step: 1
                  value: root.sel && root.sel.ddcContrast >= 0 ? root.sel.ddcContrast : 50
                  onReleased: function(v) {
                    if (root.sel) root.setDdc(root.sel.name, "contrast", v)
                  }
                }
              }
            }

            // ---- Hyprland colour pipeline ----
            Rectangle {
              width: parent.width
              height: 1
              color: root.line
            }

            Text {
              width: parent.width
              text: "Colour"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.foreground
            }

            Text {
              width: parent.width
              text: "Handled by Hyprland's compositor. The colour preset works everywhere; the SDR brightness, saturation and gamma fields are stored and read back by Hyprland but are known to have no visible effect on some setups (observed on Hyprland 0.56), so prefer the hardware controls above."
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.dim
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.spacing.md

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Item {
                  width: parent.width
                  height: Style.font.caption * 1.6

                  Text {
                    text: "SDR brightness"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.sel ? brightnessSlider.liveValue.toFixed(2) : "1.00"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                PanelSlider {
                  id: brightnessSlider
                  width: parent.width
                  minimum: 0.4
                  maximum: 2
                  step: 0.05
                  value: root.sel ? root.sel.sdrBrightness : 1
                  enabled: root.sel !== null && !root.sel.disabled
                  opacity: enabled ? 1.0 : 0.5
                  // Commit on release: a hyprctl eval per drag step would
                  // flood the compositor and most would be dropped anyway.
                  onReleased: function(v) {
                    if (root.sel) root.setColor(root.sel.name, "sdrBrightness", v)
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Item {
                  width: parent.width
                  height: Style.font.caption * 1.6

                  Text {
                    text: "SDR saturation"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.sel ? saturationSlider.liveValue.toFixed(2) : "1.00"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                PanelSlider {
                  id: saturationSlider
                  width: parent.width
                  // 0 is not accepted by hyprctl (it falls back to 1), so the
                  // slider cannot offer a true grayscale endpoint.
                  minimum: 0.1
                  maximum: 2
                  step: 0.05
                  value: root.sel ? root.sel.sdrSaturation : 1
                  enabled: root.sel !== null && !root.sel.disabled
                  opacity: enabled ? 1.0 : 0.5
                  onReleased: function(v) {
                    if (root.sel) root.setColor(root.sel.name, "sdrSaturation", v)
                  }
                }
              }
            }

            // gamma / transfer function
            Dropdown {
              width: parent.width
              showLabel: true
              label: "Transfer function (gamma)"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: [
                { value: "default", label: "Default" },
                { value: "gamma22", label: "Gamma 2.2" },
                { value: "srgb", label: "sRGB piecewise" }
              ]
              value: root.sel ? root.sel.sdrEotf : "default"
              onChanged: function(value) {
                if (root.sel) root.setColor(root.sel.name, "sdrEotf", value)
              }
            }

            // colour primaries preset
            Dropdown {
              width: parent.width
              showLabel: true
              label: "Colour preset"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: [
                { value: "auto", label: "Auto" },
                { value: "srgb", label: "sRGB" },
                { value: "wide", label: "Wide (BT2020)" },
                { value: "dcip3", label: "DCI P3" },
                { value: "dp3", label: "Display P3" },
                { value: "adobe", label: "Adobe RGB" },
                { value: "edid", label: "EDID" },
                { value: "hdr", label: "HDR (experimental)" },
                { value: "hdredid", label: "HDR + EDID (experimental)" }
              ]
              value: root.sel ? root.sel.cm : "srgb"
              onChanged: function(value) {
                if (root.sel) root.setColor(root.sel.name, "cm", value)
              }
            }

            // bit depth + HDR + wide colour, two per row
            Row {
              width: parent.width
              spacing: Style.spacing.md

              Dropdown {
                width: (parent.width - parent.spacing) / 2
                showLabel: true
                label: "Bit depth"
                fontFamily: root.fontFamily
                foreground: root.foreground
                options: [
                  { value: "8", label: "8 bpc" },
                  { value: "10", label: "10 bpc" }
                ]
                value: root.sel ? String(root.sel.bitdepth) : "8"
                onChanged: function(value) {
                  if (root.sel) root.setColor(root.sel.name, "bitdepth", parseInt(value, 10))
                }
              }

              Dropdown {
                width: (parent.width - parent.spacing) / 2
                showLabel: true
                label: "HDR"
                fontFamily: root.fontFamily
                foreground: root.foreground
                options: [
                  { value: "-1", label: "Off" },
                  { value: "0", label: "Auto" },
                  { value: "1", label: "On" }
                ]
                value: root.sel ? String(root.sel.supportsHdr) : "0"
                onChanged: function(value) {
                  if (root.sel) root.setColor(root.sel.name, "supportsHdr", parseInt(value, 10))
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Dropdown {
                width: (parent.width - parent.spacing) / 2
                showLabel: true
                label: "Wide colour"
                fontFamily: root.fontFamily
                foreground: root.foreground
                options: [
                  { value: "-1", label: "Off" },
                  { value: "0", label: "Auto" },
                  { value: "1", label: "On" }
                ]
                value: root.sel ? String(root.sel.supportsWideColor) : "0"
                onChanged: function(value) {
                  if (root.sel) root.setColor(root.sel.name, "supportsWideColor", parseInt(value, 10))
                }
              }

              Item { width: (parent.width - parent.spacing) / 2; height: 1 }
            }

            // ICC profile
            Column {
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                text: "ICC profile"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
              }

              TextField {
                id: iccField
                width: parent.width
                text: root.sel ? root.sel.icc : ""
                placeholderText: "/home/…/profile.icc (absolute path, blank for none)"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                onEditingFinished: {
                  if (root.sel && root.sel.icc !== text)
                    root.setColor(root.sel.name, "icc", text.trim())
                }
              }
            }

            // actions
            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Make main screen"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: if (root.sel) root.makeMain(root.sel.name)
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Center"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.centerSelected()
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.line
        }

        // ---- status + global actions ----
        Text {
          width: parent.width
          text: root.status === "" ? "Edits apply to your screens as you make them. Apply layout re-pushes the whole layout; Save writes it to the config file."
            : root.status
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.dim
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Apply layout"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.applyAll()
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: root.saving ? "Saving…" : "Save to config"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: !root.saving
            onClicked: root.saveConfig()
          }
        }

        Text {
          width: parent.width
          text: "Saved layouts can never overlap — the panel untangles screens before writing the file."
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.dim
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---- monitor rectangle delegate -------------------------------------
  Component {
    id: monDelegate

    Item {
      id: monBox

      property bool isDragging: root.dragging === index
      property bool isOverlapped: root.draggingOverlap
        && root.dragging >= 0
        && root.overlapNames.indexOf(model.name) >= 0
      property bool isSelected: index === root.selectedIndex

      x: isDragging ? root.dragPx : root.ox + model.x * root.k
      y: isDragging ? root.dragPy : root.oy + model.y * root.k
      width: model.logicalW * root.k
      height: model.logicalH * root.k
      opacity: model.disabled ? 0.35 : 1.0
      z: isDragging ? 30 : (isSelected ? 3 : (isOverlapped ? 4 : 1))

      Behavior on x {
        enabled: !isDragging
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
      Behavior on y {
        enabled: !isDragging
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }

      Rectangle {
        id: monRect
        anchors.fill: parent
        radius: Style.cornerRadius > 0 ? Math.min(6, Style.space(5)) : 0
        color: model.disabled ? Qt.darker(root.surface, 1.1)
          : (isOverlapped ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.9) : root.surface)
        border.width: isSelected ? 2 : (isOverlapped ? 2 : 1)
        border.color: isSelected ? root.accent
          : (isOverlapped ? root.urgent : (root.dragging === index ? root.accent : root.line))
      }

      // label block
      Column {
        anchors.fill: parent
        anchors.margins: Style.space(5)
        spacing: 2
        visible: width > 40 && height > 24

        Text {
          text: model.name
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          color: isOverlapped ? "black" : root.foreground
          elide: Text.ElideMiddle
          width: parent.width
        }

        Text {
          text: (model.disabled ? "off — " : "")
            + Math.round(model.logicalW) + "×" + Math.round(model.logicalH)
            + (model.transform % 4 !== 0 ? "  ⟳" + (model.transform % 4 * 90) + "°" : "")
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: isOverlapped ? "black" : root.dim
          elide: Text.ElideMiddle
          width: parent.width
        }

        Text {
          text: model.focused ? "★ main" : ""
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.accent
          font.bold: true
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        cursorShape: Qt.OpenHandCursor

        onPressed: function(mouse) {
          root.cursorActive = true
          root.selectedName = model.name
          if (!model.disabled && !root.saving && !root.applying) {
            root.startDrag(index, monBox.x, monBox.y, mouse.x, mouse.y)
          }
        }
        onPositionChanged: function(mouse) {
          if (root.dragging === index) root.dragTo(mouse.x, mouse.y)
        }
        onReleased: function(mouse) {
          if (root.dragging === index) {
            root.dragTo(mouse.x, mouse.y)
            root.endDrag(index)
          }
        }
      }
    }
  }
}