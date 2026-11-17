// Run: node tests/model.test.js
// Loads Model.js (a QML .pragma library) as plain JavaScript.
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = new Function(src + "; return { SCRATCHPAD, normalizeConfig, parseConfig, serializeConfig, findApp, findAppByDesktopId, withAppId, isFirstWindow, withApp, withoutApp, withMode, stripFieldCodes, commandFromCmdline, shellCommand, luaString, launchDispatch, isAddress, hideDispatch, bringDispatch, escapeMarkup, parseOpenWindow }")()

let n = 0
function test(name, fn) { fn(); n++; console.log("ok - " + name) }

test("parseConfig tolerates junk", () => {
  assert.deepStrictEqual(M.parseConfig(""), { apps: [] })
  assert.deepStrictEqual(M.parseConfig("{not json"), { apps: [] })
  assert.deepStrictEqual(M.parseConfig('{"apps": 3}'), { apps: [] })
})

test("normalizeConfig drops bad entries, dedups, defaults the mode", () => {
  const c = M.normalizeConfig({ apps: [
    { appId: "Slack", command: ["slack"], mode: "weird" },
    { appId: "slack", command: ["other"] },
    { appId: "", command: ["x"] },
    { appId: "NoCmd", command: [] },
    { appId: "Spotify", command: ["spotify", 5, ""], mode: "always" },
  ] })
  assert.strictEqual(c.apps.length, 2)
  assert.strictEqual(c.apps[0].mode, "startup")
  assert.strictEqual(c.apps[0].name, "Slack")
  assert.deepStrictEqual(c.apps[1].command, ["spotify"])
  assert.strictEqual(c.apps[1].mode, "always")
})

test("withApp replaces, withMode and withoutApp", () => {
  let c = M.withApp({ apps: [] }, { appId: "Slack", command: ["slack"], mode: "startup" })
  c = M.withApp(c, { appId: "slack", command: ["slack", "-u"], mode: "startup" })
  assert.strictEqual(c.apps.length, 1)
  assert.deepStrictEqual(c.apps[0].command, ["slack", "-u"])
  c = M.withMode(c, "SLACK", "always")
  assert.strictEqual(M.findApp(c, "slack").mode, "always")
  assert.strictEqual(M.withMode(c, "slack", "bogus").apps[0].mode, "always")
  assert.strictEqual(M.withoutApp(c, "Slack").apps.length, 0)
})

test("findAppByDesktopId ignores case and .desktop", () => {
  const c = M.withApp({ apps: [] }, { appId: "Slack", desktopId: "slack.desktop", command: ["slack"] })
  assert.strictEqual(M.findAppByDesktopId(c, "Slack").appId, "Slack")
  assert.strictEqual(M.findAppByDesktopId(c, ""), null)
})

test("withAppId learns a class, keeps the rest, refuses clashes", () => {
  let c = M.withApp({ apps: [] }, { appId: "chrome-app", name: "chrome-app", desktopId: "x", command: ["x"], mode: "always" })
  c = M.withApp(c, { appId: "Other", command: ["o"] })
  const learned = M.withAppId(c, "chrome-app", "chrome-abc-Default")
  const app = M.findApp(learned, "chrome-abc-Default")
  assert.ok(app)
  assert.strictEqual(app.mode, "always")
  assert.strictEqual(app.name, "chrome-abc-Default")
  assert.strictEqual(M.findApp(learned, "chrome-app"), null)
  assert.strictEqual(M.withAppId(c, "chrome-app", "other").apps[0].appId, "chrome-app")
})

test("isFirstWindow", () => {
  assert.ok(M.isFirstWindow([]))
  assert.ok(!M.isFirstWindow([{}]))
})

test("serializeConfig round-trips", () => {
  const c = M.withApp({ apps: [] }, { appId: "a", command: ["b"], mode: "always" })
  assert.deepStrictEqual(M.parseConfig(M.serializeConfig(c)), c)
})

test("field codes and cmdline", () => {
  assert.deepStrictEqual(M.stripFieldCodes(["/usr/bin/slack", "%U"]), ["/usr/bin/slack"])
  assert.deepStrictEqual(M.commandFromCmdline("foo\u0000--bar\u0000"), ["foo", "--bar"])
})

test("array-like commands (Qt lists) are accepted", () => {
  const qtList = { length: 2, 0: "/usr/bin/slack", 1: "%U" }
  assert.deepStrictEqual(M.stripFieldCodes(qtList), ["/usr/bin/slack"])
  assert.deepStrictEqual(M.stripFieldCodes("slack"), [])
})

test("shell quoting survives quotes and $", () => {
  assert.strictEqual(M.shellCommand(["echo", "it's $HOME"]), "'echo' 'it'\\''s $HOME'")
})

test("lua long strings never close early", () => {
  assert.strictEqual(M.luaString("abc"), "[[abc]]")
  assert.strictEqual(M.luaString("a]]b"), "[=[a]]b]=]")
  assert.strictEqual(M.luaString("a]]b]=]"), "[==[a]]b]=]]==]")
})

test("dispatch strings", () => {
  assert.strictEqual(M.launchDispatch(["slack"]),
    "hl.dsp.exec_cmd([['slack']], { workspace = [[special:scratchpad silent]] })")
  assert.strictEqual(M.hideDispatch("5557d04863a0"),
    "hl.dsp.window.move({ workspace = [[special:scratchpad]], follow = false, window = [[address:0x5557d04863a0]] })")
  assert.strictEqual(M.bringDispatch("abc", 3),
    "hl.dsp.window.move({ workspace = [[3]], follow = true, window = [[address:0xabc]] })")
  assert.ok(M.isAddress("0xabc123"))
  assert.ok(!M.isAddress("0xabc]] os.execute('x') --"))
})

test("openwindow parsing keeps commas in titles", () => {
  assert.deepStrictEqual(M.parseOpenWindow("abc,2,Slack,Hello, world"),
    { address: "abc", workspace: "2", appId: "Slack", title: "Hello, world" })
  assert.strictEqual(M.parseOpenWindow("abc,2"), null)
})

test("markup escaping", () => {
  assert.strictEqual(M.escapeMarkup('<img src="x"> & co'), '&lt;img src="x"&gt; &amp; co')
})

console.log(`\n${n} tests passed`)
