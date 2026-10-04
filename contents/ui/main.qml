import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Templates as T
import QtQuick.Dialogs
import QtQuick.Shapes
import QtWebSockets
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.notification
import org.kde.coreaddons as KCoreAddons
import org.kde.kquickcontrolsaddons as KQuickControlsAddons
import "ntfy.js" as Ntfy

PlasmoidItem {
    id: root

    // Gruvbox Dark Hard
    readonly property color bgHard: "#1d2021"
    readonly property color bg0: "#282828"
    readonly property color bg1: "#3c3836"
    readonly property color bg2: "#504945"
    readonly property color fg: "#ebdbb2"
    // Secondary text ink. #928374 is the gruvbox muted step but only reaches 3.16:1 on bg1
    readonly property color muted: "#bdae93"
    readonly property color gray: "#928374"
    readonly property color red: "#fb4934"
    readonly property color green: "#b8bb26"
    readonly property color yellow: "#fabd2f"
    readonly property color blue: "#83a598"
    readonly property color orange: "#fe8019"
    readonly property color redSurface: "#3c1f1e"
    // Topic accents, in chip order. Orange, red and green are taken by unread counts, priority and "Copied"
    readonly property var topicColors: ["#83a598", "#8ec07c", "#d3869b", "#fabd2f",
        "#458588", "#689d6a", "#b16286", "#d79921"]

    readonly property url logo: Qt.resolvedUrl("../icons/ntfy_logo.svg")
    readonly property int historyLimit: 200

    readonly property string baseUrl: Ntfy.baseUrl(Plasmoid.configuration.serverUrl)
    // The scheme stays visible unless it is https, so an assumed https on a plain-http port shows
    readonly property string host: baseUrl.replace(/^https:\/\//, "")
    readonly property var topics: Ntfy.splitTopics(Plasmoid.configuration.topics)
    readonly property string auth: Ntfy.authHeader(Plasmoid.configuration.token,
        Plasmoid.configuration.username, Plasmoid.configuration.password)
    readonly property string configurationError: baseUrl && !Ntfy.validServer(baseUrl)
        ? i18n("Use an HTTP(S) server URL without credentials, a query or a fragment")
        : topics.some(t => !Ntfy.validTopic(t))
        ? i18n("Topic names need 1-64 letters, digits, - or _")
        : /[\r\n]/.test(auth) ? i18n("The access token must not contain line breaks") : ""
    // Everything the subscription depends on. The config dialog writes keys one by one,
    // so the reconnect is deferred to collapse an Apply into a single reconnect
    readonly property string subscription: baseUrl && topics.length && !configurationError
        ? [baseUrl, topics.join(","), auth].join("\n") : ""
    onSubscriptionChanged: Qt.callLater(connect, true)
    onBaseUrlChanged: Qt.callLater(connect, true)
    onTopicsChanged: prune()

    readonly property bool connected: socket.status === WebSocket.Open
    readonly property bool connecting: socket.status === WebSocket.Connecting
    property string socketError: ""
    property string lastId: ""
    property string historyServer: ""
    property real lastFrame: 0
    property int retryDelay: 2000
    // Anything older is history replayed on (re)subscribe: listed, but not notified or counted
    property real quietBefore: 0
    property real now: Date.now()

    property string selected: ""
    readonly property string sendTopic: selected || topics[0] || ""
    property var unread: Object.create(null)
    readonly property int unreadTotal: {
        var n = 0
        for (var t in unread) n += unread[t]
        return n
    }
    property bool urgentUnread: false
    property int sending: 0
    property string sendError: ""
    // Own messages come back over the subscription; these must not notify
    property var outbox: []
    property int nextUpload: 0

    Plasmoid.icon: "notifications"
    Plasmoid.status: unreadTotal > 0 ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus
    toolTipMainText: "ntfy" + (host ? " @ " + host : "")
    toolTipSubText: configurationError || (!subscription ? i18n("Not configured")
        : connected ? i18np("%1 topic", "%1 topics", topics.length)
                      + (unreadTotal ? ", " + i18np("%1 unread", "%1 unread", unreadTotal) : "")
        : socketError || i18n("Connecting..."))

    onExpandedChanged: if (root.expanded) markRead(selected)
    onSelectedChanged: if (root.expanded) markRead(selected)
    Component.onCompleted: Qt.callLater(connect, true)

    function connect(fresh) {
        retryTimer.stop()
        socket.active = false
        if (historyServer !== baseUrl) {
            messages.clear()
            recountUnread()
            outbox = []
            historyServer = baseUrl
        }
        if (fresh) {
            lastId = ""
            quietBefore = Math.floor(Date.now() / 1000)
            retryDelay = 2000
            socketError = ""
        }
        if (!subscription) return
        // A fresh subscription reloads the server cache; a reconnect only asks for what it missed
        socket.url = Ntfy.wsUrl(baseUrl, topics, auth, fresh || !lastId ? "all" : lastId)
        lastFrame = Date.now()
        socket.active = true
    }

    function receive(d) {
        if (!d || typeof d !== "object" || typeof d.id !== "string" || !d.id
                || topics.indexOf(d.topic) === -1 || !Number.isFinite(d.time) || d.time <= 0) return
        var row = Ntfy.toRow(d)
        lastId = row.msgId
        for (var i = 0; i < messages.count; i++)
            if (messages.get(i).msgId === row.msgId) return

        outbox = outbox.filter(o => Date.now() - o.time < 120000)
        var own = outbox.findIndex(o => o.id ? o.id === row.msgId : o.topic === row.topic && o.body === row.message)
        if (own !== -1) outbox.splice(own, 1)
        var visible = expanded && (!selected || selected === row.topic)
        var fresh = row.time >= quietBefore && own === -1
        row.unread = fresh && !visible

        // Newest first, and history arrives oldest first, so insert by time
        var at = 0
        while (at < messages.count && messages.get(at).time > row.time) at++
        messages.insert(at, row)
        if (messages.count > historyLimit) messages.remove(historyLimit, messages.count - historyLimit)

        recountUnread()
        if (fresh && !visible && Plasmoid.configuration.notificationsEnabled) notify(row)
    }

    function notify(row) {
        notificationFactory.createObject(root, {
            row: row,
            title: (row.emoji ? row.emoji + " " : "") + (row.title ? row.topic + ": " + row.title : row.topic),
            text: Ntfy.escapeHtml(row.message || row.attachName),
            urgency: row.priority >= 5 ? Notification.CriticalUrgency
                : row.priority === 4 ? Notification.HighUrgency
                : row.priority <= 2 ? Notification.LowUrgency : Notification.NormalUrgency
        })
    }

    function openMessage(row) {
        if (row.click) {
            Qt.openUrlExternally(row.click)
        } else {
            selected = row.topic
            expanded = true
        }
    }

    function markRead(topic) {
        for (var i = 0; i < messages.count; i++)
            if ((!topic || messages.get(i).topic === topic) && messages.get(i).unread)
                messages.setProperty(i, "unread", false)
        recountUnread()
    }

    function recountUnread() {
        // ponytail: scan at most 200 cached rows instead of maintaining counters that drift.
        var u = Object.create(null), urgent = false
        for (var i = 0; i < messages.count; i++) {
            var row = messages.get(i)
            if (!row.unread) continue
            u[row.topic] = (u[row.topic] || 0) + 1
            if (row.priority >= 4) urgent = true
        }
        unread = u
        urgentUnread = urgent
    }

    function dismiss(index) {
        messages.remove(index)
        recountUnread()
    }

    // "" clears everything
    function clear(topic) {
        for (var i = messages.count - 1; i >= 0; i--)
            if (!topic || messages.get(i).topic === topic) messages.remove(i)
        recountUnread()
    }

    function prune() {
        for (var i = messages.count - 1; i >= 0; i--)
            if (topics.indexOf(messages.get(i).topic) === -1) messages.remove(i)
        recountUnread()
        if (selected && topics.indexOf(selected) === -1) selected = ""
    }

    function addTopic(t) {
        if (topics.indexOf(t) === -1) Plasmoid.configuration.topics = topics.concat([t]).join(",")
        selected = t
    }

    function removeTopic(t) {
        Plasmoid.configuration.topics = topics.filter(function(x) { return x !== t }).join(",")
    }

    function shownCount(topic) {
        var n = 0
        for (var i = 0; i < messages.count; i++)
            if (!topic || messages.get(i).topic === topic) n++
        return n
    }

    function topicColor(t) {
        var i = topics.indexOf(t)
        return i === -1 ? gray : topicColors[i % topicColors.length]
    }

    function timeText(t) {
        var d = new Date(t * 1000)
        // Plain clock time for today; "Just now" and "Yesterday at" come from KFormat
        return now - d < 60000 || new Date(now).toDateString() !== d.toDateString()
            ? KCoreAddons.Format.formatRelativeDateTime(d, Locale.ShortFormat)
            : Qt.formatTime(d, Qt.locale().timeFormat(Locale.ShortFormat))
    }

    function publish(topic, body, done, filename) {
        if (!baseUrl || configurationError || !Ntfy.validTopic(topic)) {
            sendError = configurationError || i18n("Set a server and a valid topic before sending")
            if (done) done(false)
            return
        }
        var xhr = new XMLHttpRequest()
        var own = { topic: topic, body: body, time: Date.now(), id: "" }
        var finished = false
        var timeout = sendTimeout.createObject(root, { expired: function() {
            finish(false, i18n("Request timed out"))
            xhr.abort()
        } })
        function finish(ok, error) {
            if (finished) return
            finished = true
            timeout.stop()
            timeout.destroy()
            sending--
            if (!ok) {
                outbox = outbox.filter(o => o !== own)
                sendError = i18n("Not sent: %1", error)
            } else {
                try { own.id = String(JSON.parse(xhr.responseText).id || "") } catch (e) {}
            }
            if (done) done(ok)
        }
        outbox.push(own)
        if (outbox.length > 20) outbox.shift()
        sending++
        sendError = ""
        try {
            xhr.open("POST", baseUrl + "/" + encodeURIComponent(topic))
            if (auth) xhr.setRequestHeader("Authorization", auth)
            if (filename) xhr.setRequestHeader("Filename", filename)
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE)
                    finish(xhr.status >= 200 && xhr.status < 300, Ntfy.errorText(xhr.status, xhr.responseText))
            }
            timeout.start()
            xhr.send(body)
        } catch (e) {
            finish(false, e.message)
        }
    }

    // The executable engine runs its source through a shell, so every argument goes through this
    function shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    function publishFile(topic, url) {
        var path = Ntfy.localPath(url)
        if (!path || path.endsWith("/")) {
            sendError = i18n("Only local files can be uploaded")
            return
        }
        if (!baseUrl || configurationError || !Ntfy.validTopic(topic)) {
            sendError = configurationError || i18n("Set a server and a valid topic before sending")
            return
        }
        sending++
        sendError = ""
        // Each source must be unique, even when the same file is submitted twice.
        uploader.connectSource(": " + (++nextUpload) + "; "
            + "curl -sS --fail-with-body --connect-timeout 10 --max-time 60 --proto '=http,https' -T " + shQuote(path)
            + " -H " + shQuote("Filename: " + Ntfy.fileName(url).replace(/[\r\n]/g, "_"))
            + (auth ? " -H " + shQuote("Authorization: " + auth) : "")
            + " -- " + shQuote(baseUrl + "/" + encodeURIComponent(topic)))
    }

    // Anything that also carries plain text pastes as text, since office apps and browsers
    // put a rendered image next to copied text
    function clipboardImage() {
        var formats = clipboard.formats || []
        return !formats.some(f => /^text\/plain/.test(f)) && formats.some(f => /^image\//.test(f))
    }

    // A copied image goes out as a file
    function pasteImage(topic) {
        if (!clipboardImage()) return false
        // contentFormat("image/png") decodes to a QImage. Qt's internal image format hands over
        // the source app's encoded bytes instead, PNG when it is on offer
        var data = clipboard.contentFormat("application/x-qt-image")
        if (data && data.byteLength)
            publish(topic, data, null, "pasted-" + Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss") + Ntfy.imageExt(data))
        else
            sendError = i18n("Could not read the copied image")
        return true
    }

    WebSocket {
        id: socket
        onTextMessageReceived: function(text) {
            root.lastFrame = Date.now()
            var d
            try {
                d = JSON.parse(text)
            } catch (e) {
                return
            }
            if (!d || typeof d !== "object") return
            if (d.event === "open") {
                root.retryDelay = 2000
                root.socketError = ""
            } else if (d.event === "message") {
                root.receive(d)
            }
        }
        onStatusChanged: {
            if (socket.status === WebSocket.Error)
                root.socketError = /\b40[13]\b|Authenticate/.test(socket.errorString)
                    ? i18n("Login rejected - check the credentials in the settings")
                    : /SSL/.test(socket.errorString) && root.baseUrl.startsWith("https:")
                    ? i18n("TLS handshake failed - for a plain HTTP server, start the URL with http://")
                    : socket.errorString
            if ((socket.status === WebSocket.Error || socket.status === WebSocket.Closed)
                    && socket.active && !retryTimer.running) {
                retryTimer.interval = root.retryDelay
                retryTimer.start()
                root.retryDelay = Math.min(root.retryDelay * 2, 60000)
            }
        }
    }

    Timer {
        id: retryTimer
        onTriggered: root.connect(false)
    }

    // ntfy sends a keepalive every 45s by default. A socket that stays "open" through a
    // suspend or a network change never reports an error, it just goes quiet
    Timer {
        interval: 30000
        running: socket.active
        repeat: true
        onTriggered: if (Date.now() - root.lastFrame > 100000) root.connect(false)
    }

    Timer {
        interval: 30000
        running: root.expanded
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    Component {
        id: sendTimeout
        Timer {
            interval: 60000
            property var expired
            onTriggered: expired()
        }
    }

    Plasma5Support.DataSource {
        id: uploader
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            root.sending--
            if (!data["exit code"]) return
            var out = String(data["stdout"] || "")
            root.sendError = i18n("Upload failed: %1", out
                ? Ntfy.errorText(1, out).replace(/ \(1\)$/, "")
                : String(data["stderr"] || "").split("\n")[0].replace(/^curl: \(\d+\) /, "")
                    || i18n("Command exited with code %1", data["exit code"]))
        }
    }

    Component {
        id: notificationFactory

        Notification {
            id: popupNote
            property var row
            Component.onCompleted: sendEvent()
            // An old notification must not send a reply to a newly configured server.
            property Connections serverWatcher: Connections {
                target: root
                function onBaseUrlChanged() { popupNote.close() }
            }
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: Ntfy.localPath(root.logo)
            defaultAction: NotificationAction {
                label: popupNote.row.click ? i18n("Open link") : i18n("Show")
                onActivated: root.openMessage(popupNote.row)
            }
            replyAction {
                label: i18n("Reply")
                placeholderText: i18n("Reply in %1", popupNote.row.topic)
                onReplied: text => root.publish(popupNote.row.topic, text)
            }
            onClosed: destroy()
        }
    }

    KQuickControlsAddons.Clipboard { id: clipboard }

    ListModel { id: messages }

    FontMetrics {
        id: fontMetrics
        font: Kirigami.Theme.defaultFont
    }

    // The time slot keeps room for this so a click doesn't reflow the card
    TextMetrics {
        id: copiedMetrics
        font: Kirigami.Theme.smallFont
        text: i18n("Copied")
    }

    // The time's digits, which the priority triangle spans
    TextMetrics {
        id: digitMetrics
        font: Kirigami.Theme.smallFont
        text: "0"
    }

    component NLabel: PlasmaComponents.Label {
        color: root.fg
        textFormat: Text.PlainText
    }

    component Dot: Rectangle {
        implicitWidth: 8
        implicitHeight: 8
        radius: 4
    }

    component Body: Text {
        property string raw
        property bool markdown
        text: markdown ? raw : Ntfy.linkify(raw)
        textFormat: markdown ? Text.MarkdownText : Text.StyledText
        wrapMode: Text.Wrap
        color: root.fg
        linkColor: root.blue
        font: Kirigami.Theme.defaultFont
        onLinkActivated: link => { if (Ntfy.httpUrl(link)) Qt.openUrlExternally(link) }
        HoverHandler {
            cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : undefined
        }
    }

    component IconButton: Kirigami.Icon {
        id: btn
        property string tip
        readonly property bool hovered: area.containsMouse || activeFocus
        signal clicked
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: tip
        Accessible.onPressAction: clicked()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                clicked()
                event.accepted = true
            }
        }
        implicitWidth: Kirigami.Units.iconSizes.small
        implicitHeight: Kirigami.Units.iconSizes.small
        opacity: enabled ? (hovered ? 1 : 0.7) : 0.3
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: 2
            color: "transparent"
            border.width: btn.activeFocus ? 1 : 0
            border.color: root.orange
        }
        MouseArea {
            id: area
            anchors.fill: parent
            anchors.margins: -Kirigami.Units.smallSpacing
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
        QQC2.ToolTip.text: tip
        QQC2.ToolTip.visible: area.containsMouse && tip !== ""
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
    }

    // A text tab: the selected one is underlined in its topic's colour, orange without one
    component Chip: Item {
        id: chip
        property string label
        property int count: 0
        property bool checked: false
        property color accent: "transparent"
        readonly property bool hovered: chipArea.containsMouse || activeFocus
        signal clicked
        signal menuRequested
        activeFocusOnTab: true
        Accessible.role: Accessible.PageTab
        Accessible.name: label
        Accessible.checked: checked
        Accessible.onPressAction: clicked()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                clicked()
                event.accepted = true
            } else if (event.key === Qt.Key_Menu || event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier) {
                menuRequested()
                event.accepted = true
            }
        }

        implicitWidth: chipRow.implicitWidth + Kirigami.Units.smallSpacing * 2
        implicitHeight: chipRow.implicitHeight + Kirigami.Units.smallSpacing * 2 + underline.height

        RowLayout {
            id: chipRow
            anchors.horizontalCenter: parent.horizontalCenter
            y: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Dot {
                visible: chip.accent.a > 0
                color: chip.accent
            }

            // Colour only, no bold: a bold label would widen the tab and shift its neighbours
            NLabel {
                text: chip.label
                color: chip.checked || chip.hovered ? root.fg : root.muted
            }

            NLabel {
                visible: chip.count > 0
                text: chip.count > 99 ? "99+" : chip.count
                color: root.orange
                font.bold: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        Rectangle {
            id: underline
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 2
            radius: 1
            visible: chip.checked || chip.hovered
            color: !chip.checked ? root.bg2 : chip.accent.a > 0 ? chip.accent : root.orange
        }

        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => mouse.button === Qt.RightButton ? chip.menuRequested() : chip.clicked()
        }
    }

    // Flat, in the palette: the theme's field frame and accent-coloured focus ring clash with it
    component NField: PlasmaComponents.TextField {
        id: nf
        color: root.fg
        placeholderTextColor: root.muted
        selectionColor: root.bg2
        selectedTextColor: root.fg
        leftPadding: Kirigami.Units.largeSpacing
        rightPadding: Kirigami.Units.largeSpacing
        topPadding: Kirigami.Units.smallSpacing * 1.5
        bottomPadding: Kirigami.Units.smallSpacing * 1.5
        background: Rectangle {
            color: root.bg0
            radius: 4
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: parent.radius
                anchors.rightMargin: parent.radius
                height: 2
                // Focus alone stays grey: the message field takes focus whenever the popup opens
                color: nf.activeFocus && nf.text ? root.orange : root.bg1
            }
        }
    }

    component FileLink: RowLayout {
        id: fileLink
        property string name
        property string url
        property real size
        spacing: Kirigami.Units.smallSpacing
        activeFocusOnTab: true
        Accessible.role: Accessible.Link
        Accessible.name: name
        Accessible.onPressAction: Qt.openUrlExternally(url)
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                Qt.openUrlExternally(url)
                event.accepted = true
            }
        }

        Kirigami.Icon {
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            source: "mail-attachment"
        }

        NLabel {
            Layout.fillWidth: true
            text: fileLink.name + (fileLink.size
                ? " (" + KCoreAddons.Format.formatByteSize(fileLink.size, 1) + ")" : "")
            color: root.blue
            font.underline: fileArea.containsMouse || fileLink.activeFocus
            elide: Text.ElideMiddle
            MouseArea {
                id: fileArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally(fileLink.url)
            }
        }
    }

    compactRepresentation: Item {
        Layout.minimumWidth: compactRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.preferredWidth: Layout.minimumWidth

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: root.urgentUnread ? root.redSurface : root.bgHard
            opacity: 0.96
            border.width: compactArea.activeFocus ? 1 : 0
            border.color: root.orange
        }

        MouseArea {
            id: compactArea
            anchors.fill: parent
            activeFocusOnTab: true
            onClicked: root.expanded = !root.expanded
            Accessible.role: Accessible.Button
            Accessible.name: root.toolTipMainText + ", " + root.toolTipSubText
            Accessible.onPressAction: root.expanded = !root.expanded
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.expanded = !root.expanded
                    event.accepted = true
                }
            }
        }

        RowLayout {
            id: compactRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: root.logo
                opacity: root.connected ? 1 : 0.4
            }

            NLabel {
                visible: root.unreadTotal > 0
                text: root.unreadTotal > 99 ? "99+" : root.unreadTotal
                color: root.urgentUnread ? root.red : root.orange
                font.bold: true
            }
        }
    }

    fullRepresentation: Item {
        id: popup

        readonly property int shown: root.shownCount(root.selected)
        property bool adding: false

        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        // Grow with the list instead of always claiming a tall empty popup
        Layout.preferredHeight: Math.min(Kirigami.Units.gridUnit * 36,
            content.implicitHeight + content.anchors.margins * 2 - bg.padTop - bg.padBottom)

        Connections {
            target: root
            function onExpandedChanged() {
                if (root.expanded) field.forceActiveFocus()
            }
        }

        // The popup window keeps a padding of its themed frame around this item, which showed as a
        // border in the theme's colour and doubled the margins. Background and content both reach
        // into it, so the content sits one margin from the window edge. Only a Plasma popup window
        // has these paddings; on the desktop they are undefined and everything keeps to our size
        Rectangle {
            id: bg
            readonly property var win: popup.Window.window
            readonly property real padTop: win && win.topPadding || 0
            readonly property real padBottom: win && win.bottomPadding || 0
            anchors.fill: parent
            anchors.leftMargin: -(win && win.leftPadding || 0)
            anchors.topMargin: -padTop
            anchors.rightMargin: -(win && win.rightPadding || 0)
            anchors.bottomMargin: -padBottom
            color: root.bgHard
            radius: 4
        }

        FileDialog {
            id: fileDialog
            title: i18n("Send files to %1", root.sendTopic)
            fileMode: FileDialog.OpenFiles
            onAccepted: selectedFiles.forEach(function(u) { root.publishFile(root.sendTopic, u) })
        }

        QQC2.Menu {
            id: fieldMenu

            QQC2.MenuItem {
                readonly property bool image: root.clipboardImage()
                text: image ? i18n("Send copied image") : i18n("Paste")
                icon.name: image ? "document-send" : "edit-paste"
                enabled: image || field.canPaste
                onTriggered: if (!root.pasteImage(root.sendTopic)) field.paste()
            }
        }

        QQC2.Menu {
            id: topicMenu
            property string topic

            QQC2.MenuItem {
                text: i18n("Clear messages")
                icon.name: "edit-clear-history"
                enabled: root.shownCount(topicMenu.topic) > 0
                onTriggered: root.clear(topicMenu.topic)
            }
            QQC2.MenuItem {
                text: i18n("Unsubscribe")
                icon.name: "list-remove"
                onTriggered: root.removeTopic(topicMenu.topic)
            }
        }

        ColumnLayout {
            id: content
            anchors.fill: bg
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    source: root.logo
                }

                NLabel {
                    text: "NTFY"
                    font.bold: true
                    font.letterSpacing: 1.2
                    color: root.orange
                }

                NLabel {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: root.host
                    color: root.muted
                    elide: Text.ElideMiddle
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }

                Dot {
                    color: root.connected ? root.green : root.connecting ? root.yellow : root.red
                }

                NLabel {
                    text: root.connected ? i18n("live") : root.connecting ? i18n("connecting") : i18n("offline")
                    color: root.muted
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }

                IconButton {
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    source: "edit-clear-history"
                    tip: root.selected ? i18n("Clear %1", root.selected) : i18n("Clear all messages")
                    enabled: popup.shown > 0
                    onClicked: root.clear(root.selected)
                }

                IconButton {
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    source: "configure"
                    tip: i18n("Configure...")
                    onClicked: Plasmoid.internalAction("configure").trigger()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: root.bg1
            }

            Flow {
                Layout.fillWidth: true
                // Tab text lines up with the header, the tab's own padding hangs out to the left
                Layout.leftMargin: -Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing
                visible: root.baseUrl !== ""

                Chip {
                    visible: root.topics.length > 1
                    label: i18n("All")
                    count: root.unreadTotal
                    checked: root.selected === ""
                    onClicked: root.selected = ""
                }

                Repeater {
                    model: root.topics

                    Chip {
                        required property string modelData
                        label: modelData
                        accent: root.topics.length > 1 ? root.topicColor(modelData) : "transparent"
                        count: root.unread[modelData] || 0
                        checked: root.selected === modelData || root.topics.length === 1
                        onClicked: root.selected = root.selected === modelData ? "" : modelData
                        onMenuRequested: {
                            topicMenu.topic = modelData
                            topicMenu.popup()
                        }
                        QQC2.ToolTip.text: i18n("Right-click to clear or unsubscribe")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay * 3
                    }
                }

                Chip {
                    visible: !popup.adding
                    Accessible.role: Accessible.Button
                    label: root.topics.length ? "+" : i18n("+ Add topic")
                    onClicked: {
                        popup.adding = true
                        topicField.forceActiveFocus()
                    }
                    QQC2.ToolTip.text: i18n("Subscribe to a topic")
                    QQC2.ToolTip.visible: hovered && root.topics.length > 0
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                }

                NField {
                    id: topicField
                    visible: popup.adding
                    width: Kirigami.Units.gridUnit * 10
                    placeholderText: i18n("New topic")
                    readonly property bool valid: Ntfy.validTopic(text.trim())
                    color: valid || !text ? root.fg : root.red
                    onAccepted: {
                        if (!valid) return
                        root.addTopic(text.trim())
                        text = ""
                        popup.adding = false
                    }
                    onActiveFocusChanged: if (!activeFocus && !text) popup.adding = false
                    Keys.onEscapePressed: {
                        text = ""
                        popup.adding = false
                    }
                    QQC2.ToolTip.text: i18n("Letters, digits, - and _ only")
                    QQC2.ToolTip.visible: !valid && text !== ""
                }
            }

            NLabel {
                Layout.fillWidth: true
                visible: root.configurationError !== "" || root.socketError !== "" && !root.connected
                text: root.configurationError || root.socketError
                color: root.red
                wrapMode: Text.Wrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            NLabel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: Kirigami.Units.largeSpacing
                visible: popup.shown === 0
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignTop
                wrapMode: Text.Wrap
                color: root.muted
                text: !root.baseUrl ? i18n("Set a server in the settings")
                    : !root.topics.length ? i18n("Add a topic to start listening")
                    : root.selected ? i18n("Nothing in %1 yet", root.selected)
                    : i18n("No messages yet")
            }

            QQC2.ScrollView {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: popup.shown > 0
                // The bar floats over the cards' right padding instead of taking a gutter,
                // so the list is as wide as the header
                leftPadding: 0
                rightPadding: 0
                contentWidth: availableWidth
                clip: true

                QQC2.ScrollBar.vertical: T.ScrollBar {
                    id: vbar
                    parent: scroll
                    x: scroll.width - width
                    y: scroll.topPadding
                    height: scroll.availableHeight
                    // Clear of the cards' rounded corners and right edge
                    topPadding: 4
                    bottomPadding: 4
                    leftPadding: 1
                    rightPadding: 2
                    minimumSize: 0.1
                    visible: size < 1
                    implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
                    contentItem: Rectangle {
                        implicitWidth: vbar.hovered || vbar.pressed ? 6 : 3
                        radius: width / 2
                        color: vbar.pressed ? root.gray : root.bg2
                        opacity: vbar.active || vbar.hovered ? 1 : 0.6
                    }
                }

                ColumnLayout {
                    width: scroll.availableWidth
                    spacing: Math.round(Kirigami.Units.smallSpacing * 1.5)

                    Repeater {
                        model: messages

                        Rectangle {
                            id: card
                            required property int index
                            required property string topic
                            required property string title
                            required property string message
                            required property bool markdown
                            required property int priority
                            required property string emoji
                            required property string tags
                            required property real time
                            required property string click
                            required property string attachName
                            required property string attachUrl
                            required property real attachSize
                            required property bool image
                            property bool copied: false
                            function copy() {
                                clipboard.content = card.image || !card.title && !card.message ? card.attachUrl
                                    : [card.title, card.message].filter(Boolean).join("\n")
                                card.copied = true
                                copiedTimer.restart()
                            }
                            // Filtering a multi-topic list keeps the rail space, so cards do not shift.
                            readonly property bool railed: root.topics.length > 1
                            readonly property bool hovered: cardHover.hovered || copyArea.activeFocus
                            // Whatever the message has first leads the header line, next to the time
                            readonly property string lead: title ? "title" : message ? "message"
                                : attachUrl && !image ? "file" : ""

                            visible: !root.selected || topic === root.selected
                            Layout.fillWidth: true
                            Layout.preferredHeight: cardCol.implicitHeight + Kirigami.Units.largeSpacing * 2
                            radius: 4
                            color: hovered ? root.bg1 : root.bg0
                            opacity: priority <= 2 ? 0.75 : 1

                            Timer {
                                id: copiedTimer
                                interval: 1200
                                onTriggered: card.copied = false
                            }

                            // A handler, not the MouseArea: it keeps seeing the pointer over the text and
                            // the buttons, which a MouseArea underneath them does not
                            HoverHandler {
                                id: cardHover
                                cursorShape: Qt.PointingHandCursor
                            }

                            MouseArea {
                                id: copyArea
                                anchors.fill: parent
                                activeFocusOnTab: true
                                onClicked: card.copy()
                                Accessible.role: Accessible.Button
                                Accessible.name: i18n("Copy message: %1", card.title || card.message || card.attachName)
                                Accessible.onPressAction: card.copy()
                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                        card.copy()
                                        event.accepted = true
                                    }
                                }
                            }

                            // The topic as a rail in its tab's colour, named on hover under All
                            Rectangle {
                                id: rail
                                visible: card.railed
                                x: Math.round(Kirigami.Units.smallSpacing * 1.5)
                                y: Kirigami.Units.largeSpacing
                                width: 3
                                height: parent.height - y * 2
                                radius: 1.5
                                color: root.topicColor(card.topic)
                            }

                            QQC2.ToolTip.text: card.topic
                            QQC2.ToolTip.visible: card.railed && !root.selected && card.hovered
                                && !linkButton.hovered && !dismissButton.hovered
                            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay

                            ColumnLayout {
                                id: cardCol
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.largeSpacing
                                anchors.leftMargin: Kirigami.Units.largeSpacing + (card.railed ? rail.x + rail.width : 0)
                                spacing: Kirigami.Units.smallSpacing

                                // Everything is top aligned and the smaller labels are pushed down to the
                                // lead line's baseline; AlignBaseline did not line them up reliably
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    NLabel {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: fontMetrics.ascent - baselineOffset
                                        visible: card.emoji !== ""
                                        text: card.emoji
                                    }

                                    NLabel {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        visible: card.lead === "title"
                                        text: card.title
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }

                                    Body {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        visible: card.lead === "message"
                                        raw: card.message
                                        markdown: card.markdown
                                    }

                                    FileLink {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        visible: card.lead === "file"
                                        name: card.attachName
                                        url: card.attachUrl
                                        size: card.attachSize
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                        visible: card.lead === ""
                                    }

                                    NLabel {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: fontMetrics.ascent - baselineOffset
                                        // Room for "Copied" too, so a click doesn't reflow the card
                                        Layout.minimumWidth: copiedMetrics.advanceWidth + leftPadding
                                        leftPadding: priorityMark.visible ? priorityMark.width + Kirigami.Units.smallSpacing : 0
                                        horizontalAlignment: Text.AlignRight
                                        text: card.copied ? i18n("Copied") : root.timeText(card.time)
                                        color: card.copied ? root.green : root.muted
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize

                                        // Drawn: a triangle glyph sits differently in every font that has one.
                                        // It spans the digits and stays next to the text however short it is
                                        Shape {
                                            id: priorityMark
                                            x: parent.width - parent.contentWidth - width - Kirigami.Units.smallSpacing
                                            y: parent.baselineOffset + digitMetrics.tightBoundingRect.y
                                            width: Math.round(height * 1.15)
                                            height: digitMetrics.tightBoundingRect.height
                                            visible: card.priority >= 4
                                            preferredRendererType: Shape.CurveRenderer
                                            Accessible.role: Accessible.StaticText
                                            Accessible.name: card.priority >= 5 ? i18n("Urgent") : i18n("High priority")
                                            ShapePath {
                                                strokeColor: "transparent"
                                                fillColor: card.priority >= 5 ? root.red : root.orange
                                                startX: priorityMark.width / 2
                                                startY: 0
                                                PathLine { x: priorityMark.width; y: priorityMark.height }
                                                PathLine { x: 0; y: priorityMark.height }
                                            }
                                        }

                                        // The hover actions cover the end of the header line instead of
                                        // keeping a column free, so the time stays visible at the card's edge
                                        Rectangle {
                                            x: (priorityMark.visible ? priorityMark.x : parent.width - parent.contentWidth)
                                                - width - Kirigami.Units.smallSpacing
                                            y: (parent.height - height) / 2
                                            width: actions.implicitWidth + Kirigami.Units.smallSpacing * 2
                                            height: actions.implicitHeight
                                            color: card.color
                                            // Focus keeps them for keyboard users moving from the card to them
                                            visible: card.hovered || linkButton.activeFocus || dismissButton.activeFocus

                                            Row {
                                                id: actions
                                                anchors.centerIn: parent
                                                spacing: Kirigami.Units.smallSpacing

                                                IconButton {
                                                    id: linkButton
                                                    visible: card.click !== ""
                                                    source: "internet-web-browser"
                                                    tip: card.click
                                                    onClicked: Qt.openUrlExternally(card.click)
                                                }

                                                IconButton {
                                                    id: dismissButton
                                                    source: "window-close"
                                                    tip: i18n("Dismiss")
                                                    onClicked: root.dismiss(card.index)
                                                }
                                            }
                                        }
                                    }
                                }

                                Body {
                                    Layout.fillWidth: true
                                    visible: card.lead === "title" && card.message !== "" && card.message !== card.title
                                    raw: card.message
                                    markdown: card.markdown
                                    color: root.muted
                                }

                                NLabel {
                                    Layout.fillWidth: true
                                    visible: card.tags !== ""
                                    text: card.tags
                                    color: root.muted
                                    elide: Text.ElideRight
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }

                                Image {
                                    id: preview
                                    Layout.fillWidth: true
                                    Layout.maximumHeight: Kirigami.Units.gridUnit * 12
                                    visible: card.image && status !== Image.Error
                                    // Fetched once the card first comes near the view of the open popup.
                                    // Fetching every preview at once ran into the server's rate limit.
                                    // A card the layout has not placed yet has no height
                                    readonly property bool near: card.image && card.visible && root.expanded
                                        && card.height > 0
                                        && card.y < scroll.contentItem.contentY + scroll.height * 2
                                        && card.y + card.height > scroll.contentItem.contentY - scroll.height
                                    property bool wanted: false
                                    onNearChanged: if (near) wanted = true
                                    source: wanted ? card.attachUrl : ""
                                    // Network images ignore the screen scale, so this is in device pixels
                                    sourceSize.height: Layout.maximumHeight * Screen.devicePixelRatio
                                    fillMode: Image.PreserveAspectFit
                                    horizontalAlignment: Image.AlignLeft
                                    asynchronous: true
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Qt.openUrlExternally(card.attachUrl)
                                    }
                                }

                                FileLink {
                                    Layout.fillWidth: true
                                    visible: card.attachUrl !== "" && (!card.image || preview.status === Image.Error)
                                        && card.lead !== "file"
                                    name: card.attachName
                                    url: card.attachUrl
                                    size: card.attachSize
                                }
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.topics.length > 0
                spacing: Kirigami.Units.smallSpacing

                NField {
                    id: field
                    Layout.fillWidth: true
                    // Sending shows here rather than in a row that would pop in and shift the layout
                    placeholderText: root.sending > 0 ? i18n("Sending...") : i18n("Message to %1", root.sendTopic)
                    onAccepted: send()
                    Keys.onPressed: event => {
                        if (event.matches(StandardKey.Paste) && root.pasteImage(root.sendTopic)) event.accepted = true
                    }
                    Keys.onEscapePressed: event => {
                        event.accepted = text !== ""
                        text = ""
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: fieldMenu.popup()
                    }

                    function send() {
                        var body = text.trim()
                        if (!body || root.sending > 0) return
                        text = ""
                        root.publish(root.sendTopic, body, function(ok) {
                            // Hand the text back on failure unless something new was typed meanwhile
                            if (!ok && !field.text) field.text = body
                        })
                    }
                }

                PlasmaComponents.ToolButton {
                    focusPolicy: Qt.StrongFocus
                    icon.name: "mail-attachment"
                    onClicked: fileDialog.open()
                    QQC2.ToolTip.text: i18n("Send files (or drop or paste them here)")
                    QQC2.ToolTip.visible: hovered
                    Accessible.name: i18n("Send files")
                }

                PlasmaComponents.ToolButton {
                    focusPolicy: Qt.StrongFocus
                    icon.name: "document-send"
                    enabled: field.text.trim() !== "" && root.sending === 0
                    onClicked: field.send()
                    QQC2.ToolTip.text: i18n("Send")
                    QQC2.ToolTip.visible: hovered
                    Accessible.name: i18n("Send")
                }
            }

            NLabel {
                Layout.fillWidth: true
                visible: root.sendError !== ""
                text: root.sendError
                color: root.red
                wrapMode: Text.Wrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        DropArea {
            id: drop
            anchors.fill: bg
            enabled: root.sendTopic !== ""
            onDropped: event => {
                if (event.hasUrls) event.urls.forEach(function(u) { root.publishFile(root.sendTopic, u) })
            }

            Rectangle {
                anchors.fill: parent
                visible: drop.containsDrag
                radius: 4
                color: Qt.rgba(0.11, 0.13, 0.13, 0.92)
                border.width: 2
                border.color: root.orange

                NLabel {
                    anchors.centerIn: parent
                    text: i18n("Drop to send to %1", root.sendTopic)
                    color: root.orange
                    font.bold: true
                }
            }
        }
    }
}
