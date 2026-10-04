<div align="center">

<img src="contents/icons/ntfy_logo.svg" width="80" alt="">

# ntfy for KDE Plasma

Your [ntfy](https://ntfy.sh) topics in the Plasma 6 panel, with notifications and replies.

[![KDE Store](https://img.shields.io/badge/KDE_Store-ntfy_for_KDE_Plasma-1d99f3?logo=kde&logoColor=white)](https://store.kde.org/p/2377064)
[![KDE Plasma 6](https://img.shields.io/badge/KDE_Plasma-6-1d99f3?logo=kde&logoColor=white)](https://kde.org/plasma-desktop/)
[![Qt 6](https://img.shields.io/badge/Qt-6-41cd52?logo=qt&logoColor=white)](https://www.qt.io/)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

<img src="docs/screenshot.png" width="566" alt="The widget's popup with tabs for the topics alerts, homelab, backups and ci, their unread counts, and message cards for an urgent disk alert, a CPU load alert with a chart preview, a CI build and a markdown backup report">

</div>

## Install

Needs Plasma 6, the Qt 6 WebSockets QML module, and `curl` 7.76+ for file uploads.

From the [KDE Store](https://store.kde.org/p/2377064): right-click the panel -> **Add Widgets** ->
**Get New Widgets** -> **Download New Plasma Widgets**, then search for "ntfy".

From source:

```bash
git clone https://github.com/k-o-n-t-o-r/plasma-ntfy-widget.git
cd plasma-ntfy-widget
./install.sh   # restarts plasmashell
```

Then right-click the panel -> **Add Widgets** -> **ntfy**.

<details>
<summary>Install without restarting Plasma</summary>

```bash
zip -r ntfy.plasmoid metadata.json LICENSE contents
kpackagetool6 -t Plasma/Applet -i ntfy.plasmoid   # -u to update
```

Zip only these files, not the whole checkout.

</details>

## Settings

- **Server:** `ntfy.example.com` is enough, HTTPS is assumed
- **Topics:** comma separated, in tab order
- **Login:** username + password, or an access token (the token wins)
- **Desktop notifications:** on by default

## Good to know

- Credentials are stored **unencrypted** in the Plasma config. Use a restricted access token.
- The WebSocket sends credentials as a base64 `auth` query parameter. Keep query strings
  out of proxy logs.
- History lives in memory only (200 messages). After a Plasma restart the widget reloads
  what the server still caches (12h by default).
- Image previews load from URLs in the messages, which can be third-party hosts.
- A send that times out after 60 s may still have arrived, so retrying can duplicate it.

## Development

```bash
QT_QPA_PLATFORM=offscreen QT_ASSUME_STDERR_HAS_CONSOLE=1 qml6 tests/test_ntfy.qml
node tests/test_runtime.js
python3 tests/test_network.py
python3 tests/test_release.py
```

Tests never contact your ntfy server. `contents/ui/emoji.js` is generated from gemoji's
`db/emoji.json` with `tools/gen-emoji.py`.

## License

[GPL-3.0-or-later](LICENSE). Bundled emoji data (MIT) and ntfy artwork (Apache-2.0):
[THIRD_PARTY_NOTICES](contents/THIRD_PARTY_NOTICES.md). Not an official ntfy or KDE project.

## Disclaimer

This project was developed with the assistance of AI tools. AI was used for tasks such as code generation, refactoring, debugging, documentation, reverse engineering and general development support.
