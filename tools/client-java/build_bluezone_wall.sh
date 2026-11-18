#!/usr/bin/env bash
# Builds the Viewpoint addon of Blue Zone (the blue zone wall in Viewpoint 1st/3rd person).
#   source : Contents/mods/[ZEDGROUND] Blue Zone/42/src/t3bluezone/**/*.java
#   output : Contents/mods/[ZEDGROUND] Blue Zone/42/media/viewpoint/addons/t3bluezone/BlueZoneWall.jar
# Loaded by Viewpoint's own addon loader (addon.properties next to the jar), not by ZombieBuddy.
# Compiles against Viewpoint's public API (viewpoint.api.*) in Viewpoint.jar; Viewpoint.jar is not shipped.
# Usage: tools/client-java/build_bluezone_wall.sh <path to Viewpoint.jar>
#   e.g. "/e/Steam/steamapps/workshop/content/108600/3809306528/mods/Viewpoint/42/media/java/client/Viewpoint.jar"
# Needs a JDK 21+.
set -euo pipefail
vp="${1:?path to Viewpoint.jar}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mod="$repo/Contents/mods/[ZEDGROUND] Blue Zone/42"
out="$mod/media/viewpoint/addons/t3bluezone"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/classes" "$out"
javac --release 21 -Xlint:all -cp "$vp" -d "$tmp/classes" $(find "$mod/src/t3bluezone" -name '*.java')
ver="$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$mod/src/t3bluezone/ZoneState.java")"
grep -q "^version=$ver$" "$out/addon.properties" || { echo "addon.properties version differs from ZoneState.VERSION $ver"; exit 1; }
printf 'Implementation-Title: ZEDGROUND Blue Zone Wall\nImplementation-Version: %s\n' "$ver" > "$tmp/manifest.txt"
jar --create --file "$out/BlueZoneWall.jar" --manifest "$tmp/manifest.txt" -C "$tmp/classes" .
echo "built BlueZoneWall.jar $ver"
jar --list --file "$out/BlueZoneWall.jar"
