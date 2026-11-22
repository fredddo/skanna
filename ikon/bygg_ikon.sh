#!/bin/zsh
# Bygger app/AppIcon.icns ur ikon/rita_ikon.swift (bygg-beta.sh lägger den i appen).
set -e
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; mkdir "$T/AppIcon.iconset"
swift ikon/rita_ikon.swift "$T/1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/1024.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((2*s)) $((2*s)) "$T/1024.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o app/AppIcon.icns
cp "$T/1024.png" ikon/AppIcon-1024.png
rm -rf "$T"
echo app/AppIcon.icns
