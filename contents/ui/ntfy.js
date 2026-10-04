.pragma library
.import "emoji.js" as Emoji

var ABC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

// UTF-8 base64. Qt.btoa(string) is deprecated since Qt 6.11 and warns on every call
function base64(s, urlSafe) {
    var bin = unescape(encodeURIComponent(s))
    var abc = ABC + (urlSafe ? "-_" : "+/")
    var out = ""
    for (var i = 0; i < bin.length; i += 3) {
        // charCodeAt past the end is NaN, which the shifts turn into 0
        var n = bin.charCodeAt(i) << 16 | bin.charCodeAt(i + 1) << 8 | bin.charCodeAt(i + 2)
        out += abc[n >> 18 & 63] + abc[n >> 12 & 63] + abc[n >> 6 & 63] + abc[n & 63]
    }
    out = out.slice(0, Math.ceil(bin.length * 4 / 3))
    return urlSafe ? out : out + "===".slice((out.length + 3) % 4)
}

function authHeader(token, user, pass) {
    if (token) return "Bearer " + token
    if (user || pass) return "Basic " + base64(user + ":" + pass)
    return ""
}

function baseUrl(server) {
    var u = String(server || "").trim().replace(/\/+$/, "")
    if (!u) return ""
    if (!/^[a-z]+:\/\//i.test(u)) u = "https://" + u
    return u.replace(/^ws(s?):/i, "http$1:").replace(/^[a-z]+:/i, scheme => scheme.toLowerCase())
}

function validServer(url) {
    return !/[\r\n]/.test(url)
        && /^https?:\/\/(?:\[[0-9a-f:.]+\]|[^\s\/\\:?#@<>"']+)(?::[0-9]{1,5})?(?:\/[^\s?#]*)?$/i.test(url)
}

// Remote messages may open web links, never local files or application handlers.
function httpUrl(url) {
    return !/[\r\n]/.test(url) && /^https?:\/\/[^\s<>"']+$/i.test(String(url || "")) ? String(url) : ""
}

// The server decodes ?auth= as unpadded base64url of the whole Authorization value
function wsUrl(base, topics, auth, since) {
    return base.replace(/^http/i, "ws") + "/" + topics.map(encodeURIComponent).join(",")
        + "/ws?since=" + encodeURIComponent(since) + (auth ? "&auth=" + base64(auth, true) : "")
}

function splitTopics(s) {
    return Array.from(new Set(String(s || "").split(",").map(t => t.trim()).filter(Boolean)))
}

// Same rule as the server, so a typo is caught here instead of as a silent 404 loop
function validTopic(t) {
    return !/[\r\n]/.test(t) && /^[-_A-Za-z0-9]{1,64}$/.test(t)
}

function isImage(type, name) {
    return /^image\//.test(type || "") || /\.(png|jpe?g|gif|webp|bmp|svg)$/i.test(name || "")
}

// Pasted images come as whatever encoding the source app offered
function imageExt(bytes) {
    // Array.from: Qt's engine reads a typed array passed to apply() as zeros
    var head = String.fromCharCode.apply(null, Array.from(new Uint8Array(bytes, 0, Math.min(12, bytes.byteLength))))
    return /^\x89PNG/.test(head) ? ".png" : /^\xff\xd8/.test(head) ? ".jpg" : /^GIF8/.test(head) ? ".gif"
        : /^RIFF[^]{4}WEBP/.test(head) ? ".webp" : /^BM/.test(head) ? ".bmp" : ""
}

// What the server puts in when a file is sent without a message
var FILE_FILLER = "You received a file: "

// Tags that name an emoji become that emoji, as in ntfy's own apps; the rest stay words
function splitTags(tags) {
    var emoji = "", words = []
    if (!Array.isArray(tags)) tags = []
    for (var i = 0; i < (tags || []).length; i++) {
        var t = String(tags[i])
        var key = t.toLowerCase()
        var e = Object.prototype.hasOwnProperty.call(Emoji.byTag, key) ? Emoji.byTag[key] : ""
        if (e) emoji += e
        else words.push(t)
    }
    return { emoji: emoji, words: words.join(", ") }
}

// A ListModel fixes each role's type on first insert, so every field is always present
function toRow(d) {
    d = d || {}
    var a = d.attachment || {}
    var message = String(d.message || "")
    if (a.name && message === FILE_FILLER + a.name) message = ""
    var tags = splitTags(d.tags)
    return {
        msgId: String(d.id || ""),
        topic: String(d.topic || ""),
        title: String(d.title || ""),
        message: message,
        markdown: d.content_type === "text/markdown",
        priority: [1, 2, 3, 4, 5].indexOf(Number(d.priority)) !== -1 ? Number(d.priority) : 3,
        emoji: tags.emoji,
        tags: tags.words,
        time: Number.isFinite(Number(d.time)) ? Math.max(0, Number(d.time)) : 0,
        click: httpUrl(d.click),
        attachName: String(a.name || ""),
        attachUrl: httpUrl(a.url),
        attachSize: Number.isFinite(Number(a.size)) ? Math.max(0, Number(a.size)) : 0,
        image: !!httpUrl(a.url) && isImage(a.type, a.name || a.url),
        unread: false
    }
}

function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

// For Text.StyledText: plain text with clickable links
function linkify(s) {
    // Find URLs before escaping, so quotes and HTML entities cannot enter the markup.
    return String(s).split(/(\bhttps?:\/\/[^\s<>"']*[^\s<>"'.,;:!?)\]])/gi).map(function(part, i) {
        var safe = escapeHtml(part)
        return i % 2 ? '<a href="' + safe + '">' + safe + "</a>" : safe
    }).join("").replace(/\n/g, "<br>")
}

function fileName(url) {
    return localPath(url).replace(/^.*\//, "")
}

function localPath(url) {
    var match = /^file:\/\/(?:localhost)?(\/[^?#]*)$/i.exec(String(url))
    if (!match) return ""
    try {
        var path = decodeURIComponent(match[1])
        return path.indexOf("\0") === -1 ? path : ""
    } catch (e) {
        return ""
    }
}

function errorText(status, body) {
    if (!status) return "Server unreachable"
    try {
        var data = JSON.parse(body)
        if (data && typeof data.error === "string" && data.error) return data.error + " (" + status + ")"
    } catch (e) {}
    return "HTTP " + status
}
