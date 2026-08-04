#!/bin/sh
# Copies the web app into the iOS target, so the built app carries a working
# copy of it. Run before building; the copy under Training/web is generated and
# not tracked in git.
#
# This is only the floor the app falls back to. Once installed, the shell keeps
# index.html current by itself from https://erich-bese.github.io/training/.
set -e

here=$(cd "$(dirname "$0")" && pwd)
src="$here/.."
dst="$here/Training/web"

mkdir -p "$dst"
for f in index.html sw.js manifest.webmanifest icon-192.png icon-512.png apple-touch-icon.png; do
  cp "$src/$f" "$dst/$f"
done

version=$(grep -o 'APP_VERSION = "[0-9.]*"' "$dst/index.html" | head -1 | cut -d'"' -f2)
echo "web app $version copied into $dst"
