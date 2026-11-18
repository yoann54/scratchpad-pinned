import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons as Commons
import "Model.js" as Model

// One instance per shell (manifest kind "service"), whatever the number of
// monitors. It owns the pinned-app list, the login launch, the "always" rule,
// and the IPC target. Bar widgets reach it with bar.shell.serviceFor(id).
Item {
  id: root
  visible: false

  // Injected by the host.
  property var shell: null
  property var manifest: null

  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string configDir: configHome + "/scratchpad-pinned"
  readonly property string configPath: configDir + "/apps.json"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  // One marker per Hyprland session: a shell restart or a plugin reload must
  // not launch the apps a second time, a new login must.
  readonly property string sessionMarker: runtimeDir + "/scratchpad-pinned-" +
    (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "session") + ".started"

  property var config: ({ apps: [] })
  readonly property var apps: config.apps

  // Launches waiting for their first window: { appId, desktopId, until }.
  // The exec rule tied to the launched PID usually puts that window in the
  // scratchpad; an app that hands its window to another process escapes it,
  // and then the first window is caught here instead. One window per launch,
  // so a call or dialog opening right after login stays visible.
  property var pendingLaunches: []
  readonly property int launchWaitMs: 60000

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // --- windows --------------------------------------------------------------

  function appIdOf(toplevel) {
    if (!toplevel) return ""
    if (toplevel.wayland && toplevel.wayland.appId) return String(toplevel.wayland.appId)
    var ipc = toplevel.lastIpcObject
    return ipc && ipc["class"] ? String(ipc["class"]) : ""
  }

  // The name people know the app by: the pinned entry's, else the desktop
  // entry's, else the raw window class.
  function displayName(appId) {
    if (!appId) return ""
    var app = Model.findApp(root.config, appId)
    if (app && app.name && app.name !== app.appId) return app.name
    var entry = DesktopEntries.heuristicLookup(appId)
    return entry && entry.name ? String(entry.name) : String(appId)
  }

  function toplevelAt(address) {
    var key = String(address).replace(/^0x/, "")
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].address).replace(/^0x/, "") === key) return list[i]
    }
    return null
  }

  readonly property var scratchpadWindows: {
    var out = []
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var appsRevision = DesktopEntries.applications.values.length
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || !t.workspace || t.workspace.name !== Model.SCRATCHPAD) continue
      var appId = appIdOf(t)
      out.push({
        address: String(t.address),
        appId: appId,
        name: displayName(appId),
        title: String(t.title || ""),
        pinned: Model.findApp(root.config, appId) !== null
      })
    }
    return out
  }
  readonly property int count: scratchpadWindows.length

  readonly property string activeAppId: appIdOf(Hyprland.activeToplevel)
  readonly property string activeName: displayName(activeAppId)
  readonly property bool activeIsPinned: Model.findApp(config, activeAppId) !== null
  // Only offer to pin a regular window: not one already in the scratchpad, and
  // not one living on another special workspace (the Omarchy agent console,
  // other scratchpads), which are hidden by design.
  readonly property bool activeIsPinnable: {
    var t = Hyprland.activeToplevel
    if (!t || activeAppId === "" || activeIsPinned) return false
    var ws = t.workspace ? String(t.workspace.name || "") : ""
    return ws !== "" && ws.indexOf("special:") !== 0
  }

  function windowsOf(appId) {
    var key = String(appId).toLowerCase()
    var out = []
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      if (appIdOf(list[i]).toLowerCase() === key) out.push(list[i])
    }
    return out
  }

  function hideAddress(address) {
    if (!Model.isAddress(address)) return
    Hyprland.dispatch(Model.hideDispatch(address))
  }

  function toggleScratchpad() {
    Hyprland.dispatch('hl.dsp.workspace.toggle_special("scratchpad")')
  }

  // Take a window out of the scratchpad onto the workspace shown on the
  // focused monitor (not the scratchpad itself, even while it is open).
  function bringWindow(address) {
    if (!Model.isAddress(address)) return
    var monitor = Hyprland.focusedMonitor
    var ws = monitor && monitor.activeWorkspace ? monitor.activeWorkspace : null
    var id = ws ? Number(ws.id) : NaN
    if (!(id > 0)) return
    Hyprland.dispatch(Model.bringDispatch(address, id))
    focusWindow(address)
  }

  function focusWindow(address) {
    if (!Model.isAddress(address)) return
    var a = String(address).indexOf("0x") === 0 ? String(address) : "0x" + address
    Hyprland.dispatch("hl.dsp.focus({ window = hl.get_window(" + Model.luaString("address:" + a) + ") })")
  }

  // --- config ---------------------------------------------------------------

  FileView {
    id: configFile
    path: root.configPath
    printErrors: false
    blockLoading: true
    property string lastText: "\u0000"
    onLoaded: root.applyText(text())
    onLoadFailed: root.applyText("")
  }

  // Watch the directory, not the file: editors and `jq … > tmp && mv` replace
  // the file, and a watch on the file itself stays on the old inode.
  // apps.json can hold a full command line (an app pinned from its process,
  // arguments included), so the directory and the file are owner-only, also
  // for lists written by an earlier version under the default umask.
  Process {
    id: configWatch
    running: true
    command: ["sh", "-c",
      'umask 077 && mkdir -p "$1" && chmod 700 "$1" && { [ ! -e "$1/apps.json" ] || chmod 600 "$1/apps.json"; } && ' +
      'exec inotifywait -m -q -e close_write,moved_to,create,delete --format %f "$1"',
      "sh", root.configDir]
    stdout: SplitParser {
      onRead: function(name) { if (String(name) === "apps.json") configFile.reload() }
    }
  }

  Process {
    id: writer
    property string pending: ""
    onExited: {
      if (pending !== "") { var next = pending; pending = ""; root.write(next) }
    }
  }

  function write(text) {
    if (writer.running) { writer.pending = text; return }
    writer.command = ["sh", "-c",
      'umask 077 && mkdir -p "$(dirname "$1")" && chmod 700 "$(dirname "$1")" && ' +
      'rm -f "$1.tmp" && printf "%s" "$2" > "$1.tmp" && chmod 600 "$1.tmp" && mv "$1.tmp" "$1"',
      "sh", root.configPath, text]
    writer.running = true
  }

  // Only replace `config` when the file really changed, so the periodic
  // re-read does not rebuild the popup's lists every few seconds.
  function applyText(text) {
    if (text === configFile.lastText) return
    configFile.lastText = text
    root.config = Model.parseConfig(text)
  }

  function save(next) {
    root.config = Model.normalizeConfig(next)
    var text = Model.serializeConfig(root.config)
    configFile.lastText = text
    write(text)
  }

  function setMode(appId, mode) { save(Model.withMode(config, appId, mode)) }
  function unpin(appId) { save(Model.withoutApp(config, appId)) }

  // --- launching ------------------------------------------------------------

  function launch(app) {
    var now = Date.now()
    root.pendingLaunches = root.pendingLaunches.filter(function(p) {
      return p.until > now && p.appId !== app.appId.toLowerCase()
    }).concat([{ appId: app.appId.toLowerCase(), desktopId: app.desktopId || "", until: now + root.launchWaitMs }])
    Hyprland.dispatch(Model.launchDispatch(app.command))
  }

  // The pinned app a new window belongs to: by window class, else through
  // the desktop entry that claims the class. A class found that second way is
  // learned, so an app pinned from the launcher list whose windows carry an
  // unexpected class (Electron, Chrome web apps) is recognised from then on.
  function resolveApp(appId) {
    var app = Model.findApp(root.config, appId)
    if (app) return app
    var entry = DesktopEntries.heuristicLookup(appId)
    if (!entry) return null
    var byEntry = Model.findAppByDesktopId(root.config, entry.id)
    if (!byEntry) return null
    learnAppId(byEntry, appId)
    return Model.findApp(root.config, appId)
  }

  function learnAppId(app, appId) {
    var oldKey = app.appId.toLowerCase()
    save(Model.withAppId(root.config, app.appId, appId))
    root.pendingLaunches = root.pendingLaunches.map(function(p) {
      return p.appId === oldKey ? { appId: appId.toLowerCase(), desktopId: p.desktopId, until: p.until } : p
    })
  }

  // Remove and return the live pending launch for this app, if any.
  function takePending(appId) {
    var key = String(appId).toLowerCase()
    var now = Date.now()
    var found = null
    root.pendingLaunches = root.pendingLaunches.filter(function(p) {
      if (p.until <= now) return false
      if (!found && p.appId === key) { found = p; return false }
      return true
    })
    return found
  }

  function onOpenWindow(win) {
    var inScratchpad = win.workspace === Model.SCRATCHPAD || win.workspace === "scratchpad"
    var app = resolveApp(win.appId)
    // An unknown class landing straight in the scratchpad can only come from
    // our exec rule: with a single launch pending, that is its window.
    if (!app && inScratchpad) {
      var now = Date.now()
      var live = root.pendingLaunches.filter(function(p) { return p.until > now })
      var owner = live.length === 1 ? Model.findApp(root.config, live[0].appId) : null
      if (owner) {
        learnAppId(owner, win.appId)
        app = Model.findApp(root.config, win.appId)
      }
    }
    if (!app) return
    if (takePending(app.appId)) {
      if (!inScratchpad) hideAddress(win.address)
      return
    }
    // "Always": hide the app's first window only. Its dialogs, calls and
    // other secondary windows open next to it as usual.
    if (app.mode === "always" && !inScratchpad && Model.isFirstWindow(otherWindows(app.appId, win.address)))
      hideAddress(win.address)
  }

  function otherWindows(appId, address) {
    var key = String(address).replace(/^0x/, "")
    return windowsOf(appId).filter(function(t) { return String(t.address).replace(/^0x/, "") !== key })
  }

  // Run each pinned app hidden in the scratchpad, or hide it if it is
  // already running (another autostart may have beaten us to it).
  function startPinned() {
    for (var i = 0; i < apps.length; i++) {
      var running = windowsOf(apps[i].appId)
      if (running.length === 0) launch(apps[i])
      else for (var j = 0; j < running.length; j++) hideAddress(running[j].address)
    }
  }

  function launchNow(appId) {
    var app = Model.findApp(config, appId)
    if (app) launch(app)
  }

  // The marker is claimed only once the delay is over, right before launching:
  // the shell can mount and drop this service several times in a row (plugin
  // enable, hot reload), and an instance destroyed during the delay must not
  // leave a marker behind without having launched anything.
  Process {
    id: markerClaim
    command: ["sh", "-c", '[ -e "$1" ] && echo seen || { : > "$1"; echo first; }', "sh", root.sessionMarker]
    stdout: StdioCollector {
      onStreamFinished: if (text.trim() === "first") root.startPinned()
    }
  }

  // Leave Hyprland and the toplevel list a moment to settle at login.
  Timer {
    id: startDelay
    interval: 1500
    running: true
    onTriggered: {
      Hyprland.refreshToplevels()
      settle.start()
    }
  }
  Timer { id: settle; interval: 300; onTriggered: markerClaim.running = true }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || event.name !== "openwindow") return
      var win = Model.parseOpenWindow(event.data)
      if (win) root.onOpenWindow(win)
    }
  }

  // --- pinning the focused window -------------------------------------------

  // App names and ids come from desktop entries and windows: escape them so a
  // notification daemon that renders markup shows them as text.
  function notify(summary, body) {
    Quickshell.execDetached(["notify-send", "-a", "Scratchpad Pinned", "-i", "view-pin",
      Model.escapeMarkup(summary), Model.escapeMarkup(body || "")])
  }

  Process {
    id: cmdlineReader
    property var target: null
    stdout: StdioCollector {
      onStreamFinished: root.finishPin(cmdlineReader.target, Model.commandFromCmdline(text.split("\n").join("\u0000")))
    }
  }

  function pinActive(mode) {
    pinToplevel(Hyprland.activeToplevel, mode)
  }

  // Pin the app of a window listed in the scratchpad (popup button).
  function pinWindow(address, mode) {
    pinToplevel(toplevelAt(address), mode)
  }

  // The popup's per-window button toggles: unpin when already pinned.
  function togglePinWindow(address) {
    var appId = appIdOf(toplevelAt(address))
    if (Model.findApp(config, appId)) unpin(appId)
    else pinWindow(address, "startup")
  }

  // Apps that can be pinned from the popup's picker: every launcher entry not
  // pinned yet, the ones with an open window first.
  readonly property var pinnableEntries: {
    var appsRevision = DesktopEntries.applications.values.length
    var running = {}
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var entryOf = DesktopEntries.heuristicLookup(appIdOf(list[i]))
      if (entryOf) running[entryOf.id] = true
    }
    var out = []
    var values = DesktopEntries.applications.values || []
    for (var j = 0; j < values.length; j++) {
      var e = values[j]
      if (!e || e.noDisplay || !e.command || e.command.length === 0 || e.runInTerminal) continue
      if (Model.findApp(root.config, appIdForEntry(e))) continue
      out.push({ id: String(e.id), name: String(e.name || e.id), running: !!running[e.id],
                 genericName: String(e.genericName || "") })
    }
    out.sort(function(a, b) {
      if (a.running !== b.running) return a.running ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    return out
  }

  // The window class an entry's windows will carry: StartupWMClass when the
  // entry declares one, else the class of an open window it claims, else its
  // desktop id (what Wayland apps use as app id). Matching ignores case.
  function appIdForEntry(entry) {
    if (!entry) return ""
    if (entry.startupClass) return String(entry.startupClass)
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var id = appIdOf(list[i])
      var claimed = DesktopEntries.heuristicLookup(id)
      if (claimed && claimed.id === entry.id) return id
    }
    return String(entry.id).replace(/\.desktop$/, "")
  }

  // Pin an installed app from the launcher list, open or not.
  function pinEntry(desktopId, mode) {
    var entry = DesktopEntries.byId(String(desktopId))
    if (!entry) return
    var command = Model.stripFieldCodes(entry.command)
    if (command.length === 0) {
      notify(strings.t("notify.noCommand").arg(entry.name || desktopId), "")
      return
    }
    var app = {
      appId: appIdForEntry(entry), name: String(entry.name || desktopId),
      desktopId: String(entry.id), command: command,
      mode: Model.MODES.indexOf(mode) !== -1 ? mode : "startup"
    }
    save(Model.withApp(config, app))
    notify(strings.t("notify.pinned").arg(app.name),
           app.mode === "always" ? strings.t("mode.alwaysHint") : strings.t("mode.startupHint"))
  }

  function pinToplevel(t, mode) {
    var appId = appIdOf(t)
    if (!t || appId === "") {
      notify(strings.t("notify.noWindow"), "")
      return
    }
    // A window on another special workspace (the Omarchy agent console, other
    // scratchpads) is already managed by its own toggle: never pin it.
    var ws = t.workspace ? String(t.workspace.name || "") : ""
    if (ws.indexOf("special:") === 0 && ws !== Model.SCRATCHPAD) {
      notify(strings.t("notify.otherSpecial").arg(displayName(appId)), "")
      return
    }
    var target = {
      appId: appId,
      address: String(t.address),
      mode: Model.MODES.indexOf(mode) !== -1 ? mode : "startup",
      name: appId, desktopId: ""
    }
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry && entry.command && entry.command.length > 0 && !entry.runInTerminal) {
      target.name = entry.name || appId
      target.desktopId = entry.id || ""
      finishPin(target, Model.stripFieldCodes(entry.command))
      return
    }
    // No desktop entry: fall back to the command line that started the window.
    var pid = t.lastIpcObject ? Number(t.lastIpcObject.pid) : 0
    if (!(pid > 0)) {
      notify(strings.t("notify.noCommand").arg(appId), "")
      return
    }
    cmdlineReader.target = target
    cmdlineReader.command = ["sh", "-c", 'tr "\\000" "\\n" < "/proc/$1/cmdline"', "sh", String(pid)]
    cmdlineReader.running = true
  }

  function finishPin(target, command) {
    if (!target) return
    if (!command || command.length === 0) {
      notify(strings.t("notify.noCommand").arg(target.appId), "")
      return
    }
    save(Model.withApp(config, {
      appId: target.appId, name: target.name, desktopId: target.desktopId,
      command: command, mode: target.mode
    }))
    hideAddress(target.address)
    notify(strings.t("notify.pinned").arg(target.name),
           target.mode === "always" ? strings.t("mode.alwaysHint") : strings.t("mode.startupHint"))
  }

  function unpinActive() {
    var appId = activeAppId
    var app = Model.findApp(config, appId)
    if (!app) {
      notify(strings.t("notify.notPinned").arg(appId || "?"), "")
      return
    }
    unpin(app.appId)
    notify(strings.t("notify.unpinned").arg(app.name), "")
  }

  // --- IPC ------------------------------------------------------------------
  // omarchy-shell scratchpad-pinned <method>

  IpcHandler {
    target: "scratchpad-pinned"

    function pin(): void { root.pinActive("startup") }
    function pinAlways(): void { root.pinActive("always") }
    function unpin(): void { root.unpinActive() }
    function togglePin(): void { if (root.activeIsPinned) root.unpinActive(); else root.pinActive("startup") }
    function toggle(): void { root.toggleScratchpad() }
    function launch(appId: string): void { root.launchNow(appId) }
    function bring(address: string): void { root.bringWindow(address) }
    function pinApp(desktopId: string): void { root.pinEntry(desktopId, "startup") }
    function pinnable(): string { return JSON.stringify(root.pinnableEntries) }
    function startAll(): void { root.startPinned() }
    function list(): string { return JSON.stringify(root.config, null, 2) }
    function count(): int { return root.count }
  }
}
