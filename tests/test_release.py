"""Run: python3 tests/test_release.py (stdlib only; kpackagetool6 if installed)."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
metadata = json.loads((root / "metadata.json").read_text())
widget_id = metadata["KPlugin"]["Id"]
assert metadata["KPlugin"]["License"] == "GPL-3.0-or-later"
for name in ("contents/config/main.xml", "contents/icons/ntfy_logo.svg"):
    ET.parse(root / name)
entries = ET.parse(root / "contents/config/main.xml").findall(".//{*}entry")
aliases = re.findall(r"property alias cfg_(\w+):", (root / "contents/ui/configGeneral.qml").read_text())
assert {entry.get("name") for entry in entries} == set(aliases), "settings and config aliases must match"
notification_entry = next(entry for entry in entries if entry.get("name") == "notificationsEnabled")
assert notification_entry.get("type") == "Bool"
assert notification_entry.find("{*}default").text == "true", "notifications must stay enabled on upgrade"

with tempfile.TemporaryDirectory() as directory:
    tmp = Path(directory)
    fixture = tmp / "emoji.json"
    fixture.write_text(json.dumps([
        {"aliases": ["mag", "magnifying_glass"], "description": "Magnifying glass tilted left", "emoji": "🔍"},
        {"aliases": ["woman"], "description": "Woman in suit", "emoji": "👩"},
    ]))
    output = subprocess.check_output([sys.executable, root / "tools/gen-emoji.py", fixture], text=True)
    table = json.loads(output.split("var byTag = ", 1)[1])
    assert table == {
        "mag": "🔍", "magnifying_glass": "🔍", "woman": "👩",
        "magnifying_glass_tilted_left": "🔍", "woman_in_suit": "👩", "magnifying_glass_tilted": "🔍",
    }

    # Mock only the external commands. Exercise the real staging/install script.
    commands = tmp / "bin"
    commands.mkdir()
    mock = commands / "kpackagetool6"
    mock.write_text(f"#!{sys.executable}\n" + """
import json, os, shutil, sys
from pathlib import Path
if "-l" in sys.argv:
    if os.environ["INSTALLED"] == "yes":
        print(os.environ["WIDGET_ID"])
else:
    mode = "-u" if "-u" in sys.argv else "-i"
    stage = Path(sys.argv[sys.argv.index(mode) + 1])
    capture = Path(os.environ["CAPTURE"])
    shutil.copytree(stage, capture)
    (capture.parent / (capture.name + ".mode")).write_text(mode)
""")
    mock.chmod(0o755)
    quit_app = commands / "kquitapp6"
    quit_app.write_text(f"#!{sys.executable}\n" + """
import os, sys
from pathlib import Path
assert sys.argv[1:] == ["plasmashell"]
Path(os.environ["QUIT_MARKER"]).touch()
""")
    quit_app.chmod(0o755)
    systemctl = commands / "systemctl"
    systemctl.write_text(f"#!{sys.executable}\n" + """
import os, sys
from pathlib import Path
assert sys.argv[1:] == ["--user", "start", "plasma-plasmashell.service"]
assert Path(os.environ["QUIT_MARKER"]).is_file(), "plasmashell must quit before the service starts"
sys.exit(int(os.environ["RESTART_EXIT"]))
""")
    systemctl.chmod(0o755)
    for installed, expected in (("no", "-i"), ("yes", "-u")):
        capture = tmp / installed
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   INSTALLED=installed, WIDGET_ID=widget_id, CAPTURE=str(capture),
                   QUIT_MARKER=str(tmp / (installed + ".quit")), RESTART_EXIT="0" if installed == "no" else "1")
        result = subprocess.run(["bash", root / "install.sh"], env=env, text=True, capture_output=True, check=True)
        assert not result.stderr, result.stderr
        assert ("restart plasmashell yourself" in result.stdout) == (installed == "yes")
        assert Path(env["QUIT_MARKER"]).is_file()
        assert (tmp / (installed + ".mode")).read_text() == expected
        assert {p.name for p in capture.iterdir()} == {"metadata.json", "contents", "LICENSE"}
        assert (capture / "contents/THIRD_PARTY_NOTICES.md").is_file()
        assert (capture / "contents/ui/main.qml").read_bytes() == (root / "contents/ui/main.qml").read_bytes()

    tool = shutil.which("kpackagetool6")
    if tool:
        package_root = tmp / "packages"
        package_root.mkdir()
        subprocess.run([tool, "-t", "Plasma/Applet", "-i", str(capture), "-p", str(package_root)],
                       env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), check=True)
        assert (package_root / widget_id / "contents/ui/main.qml").is_file()
    else:
        print("skip - isolated KPackage install (kpackagetool6 not installed)")
print("ok - generator, metadata, XML, install/update staging, and package hygiene")
