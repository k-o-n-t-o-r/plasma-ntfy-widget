"""Run: python3 tests/test_network.py. Uses Qt's real XHR; all traffic stays on localhost."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
runner = shutil.which("qml6") or shutil.which("qml") or "/usr/lib/qt6/bin/qml"
received = []


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        received.append((self.path, self.headers.get("Authorization"), body.decode("utf-8")))
        if self.path == "/slow":
            threading.Event().wait(1)  # Deliberately exceed the test's 300ms timeout.
        if self.path == "/drop":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        status = 403 if self.path == "/forbidden" else 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        try:
            self.wfile.write(json.dumps({"error": "forbidden"} if status == 403 else {"id": "mine"}).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


source = (root / "contents/ui/main.qml").read_text()
publish = source[source.index("    function publish("):source.index("    // The executable engine")]
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory() as directory:
        for topic, expected, error in (
            ("ok", True, ""), ("forbidden", False, "forbidden"),
            ("slow", False, "timed out"), ("drop", False, "unreachable")
        ):
            qml = f"""
import QtQuick
import {json.dumps((root / 'contents/ui/ntfy.js').as_uri())} as Ntfy
Item {{
    id: root
    property string baseUrl: "http://127.0.0.1:{server.server_port}"
    property string configurationError: ""
    property string auth: "Bearer test-token"
    property int sending: 0
    property string sendError: ""
    property var outbox: []
    function i18n(text, value) {{ return text.replace("%1", value) }}
{publish}
    Component {{
        id: sendTimeout
        Timer {{
            interval: 300
            property var expired
            onTriggered: expired()
        }}
    }}
    Timer {{ interval: 4000; running: true; onTriggered: Qt.exit(1) }}
    Component.onCompleted: {{
        publish({json.dumps(topic)}, "Grüße 😀", function(ok) {{
            try {{
                if (ok !== {str(expected).lower()} || sending !== 0) throw new Error("bad completion state")
                if (!ok && outbox.length) throw new Error("failed outbox entry retained")
                if (ok && outbox[0].id !== "mine") throw new Error("response ID not recorded")
                if (ok && sendError !== "") throw new Error("unexpected error: " + sendError)
                if (!ok && sendError.indexOf({json.dumps(error)}) === -1) throw new Error("missing error: " + sendError)
                console.log("ok - real Qt XHR: {topic}")
                Qt.exit(0)
            }} catch (e) {{
                console.log("FAIL ({topic}): " + e.message)
                Qt.exit(1)
            }}
        }})
    }}
}}
"""
            script = Path(directory) / "network.qml"
            script.write_text(qml)
            subprocess.run([runner, str(script)],
                           env=dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_ASSUME_STDERR_HAS_CONSOLE="1"),
                           check=True, timeout=8)
    assert sorted(received) == sorted(
        ("/" + topic, "Bearer test-token", "Grüße 😀") for topic in ("ok", "forbidden", "slow", "drop")
    ), received
finally:
    server.shutdown()
    server.server_close()
    thread.join()
print("ok - localhost POST, UTF-8, auth headers, rejection, timeout, and disconnect")
