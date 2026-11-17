.pragma library

// Pure helpers shared by Service.qml and the tests. No QML or Quickshell
// types here, so tests/model.test.js can run them under plain Node.

var SCRATCHPAD = "special:scratchpad"
var MODES = ["startup", "always"]
var MAX_APPS = 32
var MAX_FIELD = 256

function cleanString(value) {
  if (typeof value !== "string") return ""
  return value.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, MAX_FIELD)
}

// Desktop entry commands arrive as a Qt list (array-like, not an Array).
function cleanCommand(value) {
  if (!value || typeof value === "string" || typeof value.length !== "number") return []
  var out = []
  for (var i = 0; i < value.length && out.length < 64; i++) {
    var word = cleanString(value[i])
    if (word !== "") out.push(word)
  }
  return out
}

// Accepts whatever came off disk and returns { apps: [...] } with only
// well-formed, de-duplicated entries (keyed by appId, first one wins).
function normalizeConfig(raw) {
  var apps = []
  var seen = {}
  var list = raw && Array.isArray(raw.apps) ? raw.apps : []
  for (var i = 0; i < list.length && apps.length < MAX_APPS; i++) {
    var item = list[i] || {}
    var appId = cleanString(item.appId)
    if (appId === "" || seen[appId.toLowerCase()]) continue
    var command = cleanCommand(item.command)
    if (command.length === 0) continue
    seen[appId.toLowerCase()] = true
    apps.push({
      appId: appId,
      name: cleanString(item.name) || appId,
      desktopId: cleanString(item.desktopId),
      command: command,
      mode: MODES.indexOf(item.mode) !== -1 ? item.mode : "startup"
    })
  }
  return { apps: apps }
}

function parseConfig(text) {
  if (!text || !String(text).trim()) return { apps: [] }
  try {
    return normalizeConfig(JSON.parse(text))
  } catch (e) {
    return { apps: [] }
  }
}

function serializeConfig(config) {
  return JSON.stringify(normalizeConfig(config), null, 2) + "\n"
}

function findApp(config, appId) {
  var key = String(appId || "").toLowerCase()
  var apps = config && config.apps ? config.apps : []
  for (var i = 0; i < apps.length; i++) {
    if (apps[i].appId.toLowerCase() === key) return apps[i]
  }
  return null
}

function withApp(config, app) {
  var apps = (config && config.apps ? config.apps : []).filter(function(a) {
    return a.appId.toLowerCase() !== String(app.appId).toLowerCase()
  })
  apps.push(app)
  return normalizeConfig({ apps: apps })
}

function withoutApp(config, appId) {
  var key = String(appId || "").toLowerCase()
  return normalizeConfig({
    apps: (config && config.apps ? config.apps : []).filter(function(a) {
      return a.appId.toLowerCase() !== key
    })
  })
}

function withMode(config, appId, mode) {
  var app = findApp(config, appId)
  if (!app || MODES.indexOf(mode) === -1) return normalizeConfig(config)
  var copy = JSON.parse(JSON.stringify(app))
  copy.mode = mode
  var apps = (config.apps || []).map(function(a) { return a.appId === app.appId ? copy : a })
  return normalizeConfig({ apps: apps })
}

function findAppByDesktopId(config, desktopId) {
  var key = String(desktopId || "").replace(/\.desktop$/, "").toLowerCase()
  if (key === "") return null
  var apps = config && config.apps ? config.apps : []
  for (var i = 0; i < apps.length; i++) {
    if (apps[i].desktopId.replace(/\.desktop$/, "").toLowerCase() === key) return apps[i]
  }
  return null
}

// Rename an app's window class (learned from a real window). Keeps the rest.
function withAppId(config, oldAppId, newAppId) {
  var app = findApp(config, oldAppId)
  var fresh = cleanString(newAppId)
  if (!app || fresh === "" || app.appId === fresh) return normalizeConfig(config)
  var clash = findApp(config, fresh)
  if (clash && clash !== app) return normalizeConfig(config)
  var copy = JSON.parse(JSON.stringify(app))
  copy.appId = fresh
  if (copy.name === app.appId) copy.name = fresh
  var apps = (config.apps || []).map(function(a) { return a === app ? copy : a })
  return normalizeConfig({ apps: apps })
}

// "Always" mode hides an app's window only when no other window of the app
// exists: that is its main window, not a dialog or a call window.
function isFirstWindow(otherWindows) {
  return !otherWindows || otherWindows.length === 0
}

// Desktop entry Exec field codes (%U, %f, ...) are placeholders, not words.
function stripFieldCodes(command) {
  return cleanCommand(command).filter(function(word) { return !/^%[a-zA-Z]$/.test(word) })
}

// /proc/<pid>/cmdline is NUL separated.
function commandFromCmdline(text) {
  return cleanCommand(String(text || "").split("\u0000"))
}

// Quote one word for `sh -c`, which is how Hyprland's exec runs a command.
function shellQuote(word) {
  return "'" + String(word).replace(/'/g, "'\\''") + "'"
}

function shellCommand(command) {
  return cleanCommand(command).map(shellQuote).join(" ")
}

// A Lua string literal for Hyprland.dispatch. Long brackets avoid every escape
// problem; the level grows until the closing bracket cannot occur in the text.
function luaString(text) {
  var s = String(text)
  var level = ""
  while (s.indexOf("]" + level + "]") !== -1) level += "="
  return "[" + level + "[" + s + "]" + level + "]"
}

function launchDispatch(command) {
  return "hl.dsp.exec_cmd(" + luaString(shellCommand(command)) +
    ", { workspace = " + luaString(SCRATCHPAD + " silent") + " })"
}

function isAddress(address) {
  return /^(0x)?[0-9a-fA-F]{1,16}$/.test(String(address || ""))
}

function hideDispatch(address) {
  var a = String(address)
  if (a.indexOf("0x") !== 0) a = "0x" + a
  return "hl.dsp.window.move({ workspace = " + luaString(SCRATCHPAD) +
    ", follow = false, window = " + luaString("address:" + a) + " })"
}

function bringDispatch(address, workspaceId) {
  var a = String(address)
  if (a.indexOf("0x") !== 0) a = "0x" + a
  var id = Math.floor(Number(workspaceId))
  return "hl.dsp.window.move({ workspace = " + luaString(String(id)) +
    ", follow = true, window = " + luaString("address:" + a) + " })"
}

function escapeMarkup(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Hyprland's openwindow event data: "address,workspace,class,title".
// The title may itself contain commas, so only split the first three.
function parseOpenWindow(data) {
  var s = String(data || "")
  var parts = []
  for (var i = 0; i < 3; i++) {
    var comma = s.indexOf(",")
    if (comma === -1) return null
    parts.push(s.slice(0, comma))
    s = s.slice(comma + 1)
  }
  return { address: parts[0], workspace: parts[1], appId: parts[2], title: s }
}
