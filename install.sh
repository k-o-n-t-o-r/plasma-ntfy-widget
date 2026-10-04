#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ID="com.github.k-o-n-t-o-r.ntfy"

# Keep development files and private test configuration out of the installed package.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DIR/metadata.json" "$STAGE/"
cp "$DIR/LICENSE" "$STAGE/"
cp -r "$DIR/contents" "$STAGE/"

if kpackagetool6 -t Plasma/Applet -l | grep -Fqx "$ID"; then
    kpackagetool6 -t Plasma/Applet -u "$STAGE"
else
    kpackagetool6 -t Plasma/Applet -i "$STAGE"
fi

kquitapp6 plasmashell && systemctl --user start plasma-plasmashell.service ||
    echo "package installed - restart plasmashell yourself to load it"
