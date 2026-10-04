// Pure helpers main.qml relies on.  Run: QT_QPA_PLATFORM=offscreen QT_ASSUME_STDERR_HAS_CONSOLE=1 qml6 tests/test_ntfy.qml
import QtQuick
import "../contents/ui/ntfy.js" as Ntfy

QtObject {
    // Plasma supplies this context function when it creates the settings page.
    function i18n(text) { return text }

    // Throws, because Qt.exit only schedules - a failed check must not fall through to the ok
    function eq(got, want, what) {
        if (got !== want) throw new Error(what + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want))
    }

    Component.onCompleted: {
      try {
        // Expected values from coreutils: base64 -w0 / basenc --base64url | tr -d =
        eq(Ntfy.base64("u:p"), "dTpw", "no padding needed")
        eq(Ntfy.base64("ab"), "YWI=", "one pad")
        eq(Ntfy.base64("a"), "YQ==", "two pads")
        eq(Ntfy.base64(""), "", "empty")
        eq(Ntfy.base64("\u00fcser:p\u00e4ss\ud83d\ude00"), "w7xzZXI6cMOkc3Pwn5iA", "UTF-8 incl. surrogate pair")
        eq(Ntfy.base64("???>>>"), "Pz8/Pj4+", "standard alphabet")
        eq(Ntfy.base64("???>>>", true), "Pz8_Pj4-", "url alphabet")
        eq(Ntfy.base64("a", true), "YQ", "url form is unpadded")

        eq(Ntfy.authHeader("tk_x", "u", "p"), "Bearer tk_x", "token wins over user/pass")
        eq(Ntfy.authHeader("", "u", "p"), "Basic dTpw", "basic")
        eq(Ntfy.authHeader("", "", ""), "", "anonymous")

        eq(Ntfy.baseUrl(" ntfy.sh/ "), "https://ntfy.sh", "bare host gets https")
        eq(Ntfy.baseUrl("http://10.0.0.1:7777//"), "http://10.0.0.1:7777", "trailing slashes")
        eq(Ntfy.baseUrl("wss://x.org"), "https://x.org", "ws scheme mapped back")
        eq(Ntfy.baseUrl("WSS://x.org/"), "https://x.org", "schemes are case-insensitive")
        eq(Ntfy.baseUrl(""), "", "unset")
        eq(Ntfy.validServer("https://x.org/ntfy"), true, "reverse-proxy path")
        eq(Ntfy.validServer("http://[::1]:8080"), true, "IPv6")
        eq(Ntfy.validServer("ftp://x.org"), false, "HTTP(S) only")
        eq(Ntfy.validServer("https://u:p@x.org"), false, "no URL credentials")
        eq(Ntfy.validServer("https://x.org?auth=x"), false, "no query")
        eq(Ntfy.validServer("https://x.org/#fragment"), false, "no fragment")
        eq(Ntfy.validServer("https://x.org\n"), false, "no line breaks")

        eq(Ntfy.wsUrl("https://x.org", ["a", "b"], "Bearer tk_abc123", "all"),
           "wss://x.org/a,b/ws?since=all&auth=QmVhcmVyIHRrX2FiYzEyMw", "ws url with token")
        eq(Ntfy.wsUrl("http://x.org", ["a"], "", "Ab1_x"), "ws://x.org/a/ws?since=Ab1_x", "ws url anonymous")

        eq(JSON.stringify(Ntfy.splitTopics(" a, ,b,a ")), '["a","b"]', "trim, drop empty and duplicates")
        eq(Ntfy.validTopic("my-topic_1"), true, "valid topic")
        eq(Ntfy.validTopic("has space"), false, "space")
        eq(Ntfy.validTopic("a,b"), false, "comma")
        eq(Ntfy.validTopic("a".repeat(65)), false, "topic length limit")
        eq(JSON.stringify(Ntfy.splitTopics("")), "[]", "no topics")
        eq(JSON.stringify(Ntfy.splitTopics("constructor,__proto__,constructor")), '["constructor","__proto__"]',
           "object prototype names remain valid topics")

        var r = Ntfy.toRow({ id: "x1", topic: "t", time: 5, tags: ["warning", "backup", "Skull", "db-1"],
                             message: "You received a file: shot.PNG",
                             attachment: { name: "shot.PNG", url: "https://x/f/1.png" } })
        eq(r.image, true, "image by extension when type is missing")
        eq(r.emoji, "\u26a0\ufe0f\ud83d\udc80", "emoji tags, case-insensitive")
        eq(r.tags, "backup, db-1", "other tags stay words")
        eq(Ntfy.splitTags(["magnifying_glass", "mag", "woman_in"]).emoji, "\ud83d\udd0d\ud83d\udd0d",
           "Unicode names and their word-boundary prefixes, but not ones ending in a preposition")
        eq(r.message, "", "server filler for a bare file is dropped")
        eq(Ntfy.toRow({ message: "You received a file: b.txt", attachment: { name: "a.txt" } }).message,
           "You received a file: b.txt", "filler only matches the file's own name")
        eq(r.priority, 3, "default priority")
        eq(r.title + r.click, "", "missing fields become empty strings")
        eq(Ntfy.toRow({ attachment: { name: "a.pdf", type: "application/pdf", url: "u" } }).image, false, "pdf")
        eq(Ntfy.splitTags(["constructor", "__proto__", "toString"]).emoji, "", "inherited properties are not emoji")
        eq(Ntfy.splitTags("warning").emoji, "", "ignore malformed tag lists")
        eq(Ntfy.toRow(null).title, "", "null message")
        eq(Ntfy.toRow({ priority: 99, time: "bad", attachment: { size: -1, url: "file:///etc/passwd" } }).priority,
           3, "invalid priority")
        eq(Ntfy.toRow({ time: "bad" }).time, 0, "invalid timestamp")
        eq(Ntfy.toRow({ attachment: { size: -1 } }).attachSize, 0, "negative attachment size")
        eq(Ntfy.toRow({ click: "file:///etc/passwd", attachment: { url: "file:///etc/passwd" } }).attachUrl,
           "", "no local attachments from a remote message")
        eq(Ntfy.toRow({ click: "javascript:alert(1)" }).click, "", "no application-handler click links")

        eq(Ntfy.linkify("<b> see https://x.org/a?b=1&c=2.\nok"),
           '&lt;b&gt; see <a href="https://x.org/a?b=1&amp;c=2">https://x.org/a?b=1&amp;c=2</a>.<br>ok',
           "escape, link, trailing dot outside")
        eq(Ntfy.linkify('https://x.org/" <img src="file:///tmp/x">'),
           '<a href="https://x.org/">https://x.org/</a>&quot; &lt;img src=&quot;file:///tmp/x&quot;&gt;',
           "quotes and markup stay outside the link")
        eq(Ntfy.linkify("https://x"), '<a href="https://x">https://x</a>', "single-character host")

        eq(Ntfy.localPath("file:///home/u/My%20File.txt"), "/home/u/My File.txt", "decoded path")
        eq(Ntfy.fileName("file:///home/u/%C3%A4.txt"), "\u00e4.txt", "decoded name")
        eq(Ntfy.localPath("file://localhost/tmp/file.txt"), "/tmp/file.txt", "localhost file URL")
        eq(Ntfy.localPath("https://x.org/f.txt"), "", "drop only local files")
        eq(Ntfy.localPath("file://other-host/tmp/file.txt"), "", "reject remote file authorities")
        eq(Ntfy.localPath("file:///tmp/%ZZ"), "", "malformed encoding")
        eq(Ntfy.localPath("file:///tmp/%00"), "", "no NUL in a file path")

        function bytes(a) { return new Uint8Array(a).buffer }
        eq(Ntfy.imageExt(bytes([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])), ".png", "PNG")
        eq(Ntfy.imageExt(bytes([0xff, 0xd8, 0xff, 0xe0])), ".jpg", "JPEG")
        eq(Ntfy.imageExt(bytes([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80])), ".webp", "WebP")
        eq(Ntfy.imageExt(bytes([82, 73, 70, 70, 0, 0, 0, 0, 87, 65, 86, 69])), "", "RIFF that is not WebP")
        eq(Ntfy.imageExt(bytes([])), "", "empty")

        eq(Ntfy.errorText(0, ""), "Server unreachable", "no status")
        eq(Ntfy.errorText(403, '{"code":40301,"http":403,"error":"forbidden"}'), "forbidden (403)", "ntfy error")
        eq(Ntfy.errorText(502, "<html>"), "HTTP 502", "non-JSON body")
        eq(Ntfy.errorText(502, "{}"), "HTTP 502", "missing error field")
        eq(Ntfy.errorText(502, "null"), "HTTP 502", "null error body")

        for (var path of ["../contents/ui/main.qml", "../contents/ui/configGeneral.qml", "../contents/config/config.qml"]) {
            var component = Qt.createComponent(path)
            eq(component.status, Component.Ready, "QML compilation: " + path + " " + component.errorString())
            if (path.endsWith("/configGeneral.qml")) {
                var page = component.createObject(null, { cfg_notificationsEnabled: true })
                if (!page) throw new Error("Could not instantiate the settings page")
                var key = "cfg_notificationsEnabled"
                eq(page[key], true, "Plasma initializes the notification checkbox")
                var changes = 0
                page[key + "Changed"].connect(function() { changes++ })
                page[key] = false
                eq(changes, 1, "checkbox change emits the signal Plasma monitors for Apply")
                page[key] = true
                eq(page[key], true, "notification setting can be restored")
                eq(changes, 2, "both checkbox states notify Plasma")
                page.destroy()
            }
            component.destroy()
        }

        console.log("ok - ntfy helpers")
        Qt.exit(0)
      } catch (e) {
        console.log("FAIL: " + e.message)
        Qt.exit(1)
      }
    }
}
