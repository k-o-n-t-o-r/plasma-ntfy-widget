// Run with node tests/test_runtime.js. Exercise the actual QML functions, not copies.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const directory = path.join(__dirname, "../contents/ui")
const source = fs.readFileSync(path.join(directory, "main.qml"), "utf8")
const helpers = fs.readFileSync(path.join(directory, "ntfy.js"), "utf8").replace(/^\.(pragma|import).*$/gm, "")
const emoji = {}
vm.runInNewContext(fs.readFileSync(path.join(directory, "emoji.js"), "utf8").replace(/^\.pragma.*$/m, ""), emoji)
const Ntfy = { Emoji: { byTag: emoji.byTag } }
vm.runInNewContext(helpers, Ntfy)

function widget() {
    const rows = [], requests = [], timeouts = [], notifications = [], uploads = []
    class Request {
        static DONE = 4
        constructor() { requests.push(this) }
        open(method, url) { this.url = url; this.headers = {} }
        setRequestHeader(name, value) { this.headers[name] = value }
        send(body) { this.body = body }
        abort() { this.aborted = true }
        complete(status, responseText) {
            Object.assign(this, { status, responseText, readyState: Request.DONE })
            this.onreadystatechange()
        }
    }
    const ctx = {
        Ntfy, Date, XMLHttpRequest: Request,
        Plasmoid: { configuration: { notificationsEnabled: true } },
        baseUrl: "https://example.org", historyServer: "https://example.org",
        configurationError: "", topics: ["a", "b"], auth: "", subscription: "configured",
        lastId: "", quietBefore: 1, retryDelay: 60000, socketError: "old error", lastFrame: 0,
        expanded: false, selected: "", unread: {}, urgentUnread: false, sending: 0, sendError: "",
        outbox: [], nextUpload: 0, historyLimit: 200,
        socket: { active: true },
        retryTimer: { stopped: false, stop() { this.stopped = true } },
        messages: {
            get count() { return rows.length },
            get: i => rows[i],
            insert: (i, row) => rows.splice(i, 0, row),
            remove: (i, n = 1) => rows.splice(i, n),
            clear: () => rows.splice(0),
            setProperty: (i, key, value) => { rows[i][key] = value }
        },
        sendTimeout: { createObject(parent, properties) {
            const timer = { ...properties, start() {}, stop() {}, destroy() {} }
            timeouts.push(timer)
            return timer
        } },
        notificationFactory: { createObject(parent, note) { notifications.push(note); return {} } },
        Notification: { CriticalUrgency: 5, HighUrgency: 4, NormalUrgency: 3, LowUrgency: 1 },
        uploader: { connectSource: command => uploads.push(command) },
        i18n: (text, ...args) => text.replace(/%(\d+)/g, (_, n) => args[n - 1]),
        Qt: { openUrlExternally() {}, formatDateTime: () => "20261003-120000" },
        clipboard: { formats: [], contentFormat: () => undefined },
        logo: "file:///logo.svg",
        rows, requests, timeouts, notifications, uploads
    }
    ctx.root = ctx
    vm.runInNewContext(source.slice(source.indexOf("    function connect("), source.indexOf("\n    WebSocket {")), ctx)
    return ctx
}

const message = (id, topic = "a", priority = 3, time = 10) =>
    ({ id, topic, priority, time, message: "hello" })

{
    const w = widget()
    w.Plasmoid.configuration.notificationsEnabled = false
    w.receive(message("quiet", "a", 5))
    assert.equal(w.notifications.length, 0)
    assert.equal(w.rows.length, 1, "disabling notifications keeps history")
    assert.equal(w.unread.a, 1, "disabling notifications keeps unread badges")
    assert.equal(w.urgentUnread, true)
    w.Plasmoid.configuration.notificationsEnabled = true
    w.receive(message("notify"))
    assert.equal(w.notifications.length, 1)
}

{
    const w = widget()
    w.receive(message("urgent", "a", 5))
    w.receive(message("ordinary", "b"))
    assert.equal(w.unread.a, 1)
    assert.equal(w.urgentUnread, true)
    w.dismiss(w.rows.findIndex(r => r.msgId === "urgent"))
    assert.equal(w.urgentUnread, false)
    assert.equal(w.unread.a, undefined)
    w.markRead("a")
    assert.equal(w.unread.b, 1, "viewing one topic must not read another")
    w.markRead("")
    assert.equal(Object.keys(w.unread).length, 0)
    w.topics = ["constructor", "__proto__"]
    w.receive(message("prototype", "constructor"))
    w.receive(message("proto", "__proto__"))
    assert.equal(w.unread.constructor, 1)
    assert.equal(w.unread.__proto__, 1)
    w.clear("constructor")
    assert.equal(w.unread.__proto__, 1)
    w.topics = []
    w.prune()
    assert.equal(w.rows.length, 0)
    assert.equal(Object.keys(w.unread).length, 0)
}
{
    const w = widget()
    for (let i = 1; i <= 205; i++) w.receive(message(String(i), "a", i === 1 ? 5 : 3, i))
    assert.equal(w.rows.length, 200)
    assert.equal(w.unread.a, 200, "eviction must remove unread counts")
    assert.equal(w.urgentUnread, false, "eviction must clear urgency")
    w.lastId = "stale"
    w.receive(message("205", "a", 3, 205))
    assert.equal(w.rows.length, 200)
    assert.equal(w.lastId, "205", "duplicates still advance the replay cursor")
    for (const bad of [null, {}, { ...message("bad"), time: "oops" }, message("other", "unsubscribed")]) w.receive(bad)
    assert.equal(w.rows.length, 200)
}
{
    const w = widget()
    w.receive(message("old-server"))
    w.outbox.push({ body: "old" })
    w.baseUrl = "https://other.example.org"
    w.connect(true)
    assert.equal(w.rows.length, 0)
    assert.equal(w.outbox.length, 0)
    assert.equal(w.lastId, "")
    assert.equal(w.socketError, "")
    assert.equal(w.retryDelay, 2000)
    assert.match(w.socket.url, /since=all/)
    w.subscription = ""
    w.connect(true)
    assert.equal(w.socket.active, false)
    assert.equal(w.retryTimer.stopped, true)
}
{
    const w = widget()
    const results = []
    w.publish("a", "body", ok => results.push(ok))
    assert.equal(w.sending, 1)
    w.requests[0].complete(403, '{"error":"forbidden"}')
    assert.equal(w.sending, 0)
    assert.equal(w.outbox.length, 0, "failed sends must not suppress later messages")
    assert.deepEqual(results, [false])
    w.publish("a", "body", ok => results.push(ok))
    w.timeouts[1].expired()
    w.requests[1].complete(0, "")
    assert.equal(w.sending, 0, "abort/DONE cannot finish twice")
    assert.equal(w.requests[1].aborted, true)
    assert.deepEqual(results, [false, false])
    w.publish("a", "hello", ok => results.push(ok))
    w.requests[2].complete(200, '{"id":"mine"}')
    w.receive(message("mine"))
    assert.equal(w.notifications.length, 0, "own echo stays quiet")
    w.receive(message("not-mine"))
    assert.equal(w.notifications.length, 1)
    w.configurationError = "bad settings"
    w.publish("a", "body", ok => results.push(ok))
    assert.equal(w.requests.length, 3, "invalid settings cannot send")
    assert.equal(w.sending, 0)
}
{
    const w = widget()
    w.outbox = [{ topic: "a", body: "hello", time: Date.now() - 120001, id: "" }]
    w.receive(message("later"))
    assert.equal(w.notifications.length, 1, "stale outbox entries cannot silence messages")
    w.expanded = true
    w.selected = "a"
    w.receive(message("visible", "a"))
    w.receive(message("hidden", "b"))
    assert.equal(w.unread.a, 1, "new visible messages are read")
    assert.equal(w.unread.b, 1)
}
{
    const w = widget()
    w.publishFile("a", "https://example.org/file.txt")
    w.publishFile("a", "file:///tmp/%ZZ")
    assert.equal(w.uploads.length, 0)
    assert.equal(w.sending, 0)
    w.publishFile("a", "file:///tmp/a%27b%0A.txt")
    w.publishFile("a", "file:///tmp/a%27b%0A.txt")
    assert.equal(w.sending, 2)
    assert.notEqual(w.uploads[0], w.uploads[1], "duplicate uploads need separate sources")
    assert.match(w.uploads[0], /--max-time 60/)
    assert.match(w.uploads[0], /Filename: a'\\''b_\.txt/)
}
{
    const w = widget()
    w.clipboard.formats = ["text/plain", "image/png"]
    assert.equal(w.pasteImage("a"), false, "copied text with a rendered image pastes as text")
    w.clipboard.formats = ["image/png", "application/x-qt-image"]
    w.clipboard.contentFormat = format => format === "application/x-qt-image"
        ? new Uint8Array([0x89, 0x50, 0x4e, 0x47]).buffer : undefined
    assert.equal(w.pasteImage("a"), true)
    assert.equal(w.requests[0].headers.Filename, "pasted-20261003-120000.png")
    assert.equal(w.requests[0].body.byteLength, 4, "the image bytes go out unchanged")
    w.clipboard.contentFormat = () => ({})
    assert.equal(w.pasteImage("a"), true)
    assert.equal(w.requests.length, 1)
    assert.match(w.sendError, /copied image/)
}
console.log("ok - runtime state, replay, sends, uploads, and pasted images")
