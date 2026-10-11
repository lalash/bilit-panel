#!/usr/bin/env bash
# Bilit Talaei — puts the server menu (bilit-panel) on a fresh server and opens it.
#   bash <(curl -Ls https://raw.githubusercontent.com/lalash/bilit-panel/main/install.sh)
# This repository holds only the menu script: the site's code is in a private repository and is fetched from the
# menu with a read-only token (or installed from an offline bundle file).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash <(curl -Ls https://raw.githubusercontent.com/lalash/bilit-panel/main/install.sh)"; exit 1; }
command -v curl >/dev/null || { apt-get update -q >/dev/null && apt-get install -y -q curl >/dev/null; }
t=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/lalash/bilit-panel/main/bilit-panel.sh -o "$t"
head -1 "$t" | grep -q bash || { echo "Download failed (GitHub not reachable from this server?)."; rm -f "$t"; exit 1; }
install -m 755 "$t" /usr/local/bin/bilit-panel && rm -f "$t"
echo "bilit-panel installed. From now on just run:  bilit-panel"
exec /usr/local/bin/bilit-panel </dev/tty
