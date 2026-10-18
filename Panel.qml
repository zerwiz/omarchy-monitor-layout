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
  moduleName: "zerwiz.monitor-layout"
  ipcTarget: "zerwiz.monitor-layout"
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
  property bool cursorActive: false
  property var overlapNames: []
  // Monitor name -> advertised mode strings. Kept out of monitorModel because
  // QQmlListModel mangles nested-array roles into opaque objects.
  property var modeOptions: ({})
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
        availableModes: root.modeOptions[monitorModel.get(root.selectedIndex).name] || [] }
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

  Component.onCompleted: Qt.callLater(root.refresh)

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
    if (root.dragging >= 0) return
    var arr = Mon.parse(raw)
    var keep = { name: "", x: 0, y: 0, scale: 1, transform: 0, mode: "preferred", disabled: true, focused: false }
    if (root.selectedIndex >= 0 && root.selectedIndex < monitorModel.count)
      keep = monitorModel.get(root.selectedIndex)

    monitorModel.clear()
    var modes = {}
    for (var i = 0; i < arr.length; i++) {
      var m = arr[i]
      modes[m.name] = Mon.toArray(m.availableModes)
      // availableModes is carried in root.modeOptions, not as a model role.
      monitorModel.append({
        name: m.name, description: m.description, x: m.x, y: m.y,
        mode: m.mode, scale: m.scale, transform: m.transform,
        logicalW: m.logicalW, logicalH: m.logicalH,
        disabled: m.disabled, focused: m.focused
      })
      if (m.name === keep.name) {
        monitorModel.setProperty(monitorModel.count - 1, "x", keep.x)
        monitorModel.setProperty(monitorModel.count - 1, "y", keep.y)
      }
    }
    root.modeOptions = modes

    var on = 0
    for (var j = 0; j < monitorModel.count; j++)
      if (!monitorModel.get(j).disabled) on++
    root.totalCount = monitorModel.count
    root.enabledCount = on
    root.monitorSummary = on + " of " + monitorModel.count + " on"

    if (root.selectedName !== "" && root.selectedIndex < 0) root.selectedName = ""
    if (root.selectedName === "" && monitorModel.count > 0) root.selectedName = monitorModel.get(0).name
    root.status = monitorModel.count === 0 ? "No monitors found" : ""
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
    if (applyProc.running) return
    var arr = root.currentMonitors()
    if (arr.length === 0) return
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
          modeCount: modes.length
        })
      }
      return JSON.stringify(out)
    }
  }

  // ---- processes -------------------------------------------------------
  Process {
    id: refreshProc
    running: false
    command: ["hyprctl", "-j", "monitors"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyList(text)
    }

    onExited: function(code) {
      if (code !== 0) root.status = "Failed to query monitors"
    }
  }

  Process {
    id: applyProc
    running: false
    command: ["true"]

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        if (String(text || "").trim() !== "") root.status = "hyprctl: " + String(text).trim()
      }
    }

    onExited: function(code) {
      root.applying = false
      if (code === 0 && root.status.indexOf("hyprctl:") !== 0) root.status = "Layout applied"
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
      onStreamFinished: function(text) {
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
          text: root.status === "" ? "Positions apply instantly; Save writes the config file."
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