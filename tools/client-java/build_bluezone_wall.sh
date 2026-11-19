#!/usr/bin/env bash
# Builds the client Java part of Blue Zone (the blue zone wall in Viewpoint 1st/3rd person).
#   source : Contents/mods/[ZEDGROUND] Blue Zone/42/src/t3bluezone/*.java
#   output : Contents/mods/[ZEDGROUND] Blue Zone/42/media/java/client/BlueZoneWall.jar
# Loaded by ZombieBuddy at server join (mod.info javaJarFile / javaPkgName), like Halo Drop's client jar.
# Until 0.2.0 it was a Viewpoint addon (media/viewpoint/addons/t3bluezone): Viewpoint only discovers addons among the
# mods enabled at the main menu, so a server mod never loaded. See BlueZoneWall.java.
# Compiles against Viewpoint's public API (viewpoint.api.*, not shipped) and the compile-only stubs ./stubs/Patch.java
# (ZombieBuddy) and ./stubs/GL33.java (LWJGL: the wall draws with plain OpenGL calls since 0.4.0).
# Usage: tools/client-java/build_bluezone_wall.sh <path to Viewpoint.jar>
#   e.g. "/e/Steam/steamapps/workshop/content/108600/3809306528/mods/Viewpoint/42/media/java/client/Viewpoint.jar"
# Needs a JDK 21+.
set -euo pipefail
vp="${1:?path to Viewpoint.jar}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mod="$repo/Contents/mods/[ZEDGROUND] Blue Zone/42"
out="$mod/media/java/client"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs" "$tmp/classes" "$out"
javac --release 21 -d "$tmp/stubs" "$here/stubs/Patch.java" "$here/stubs/GL33.java"
javac --release 21 -Xlint:all -cp "$tmp/stubs:$vp" -d "$tmp/classes" "$mod/src/t3bluezone/"*.java

# ZombieBuddy inlines @Patch advice into the target class (another package): what the advice calls must be public
fail=0
for pc in "$tmp/classes/t3bluezone/"Patch*.class; do
    name="t3bluezone.$(basename "$pc" .class)"
    while read -r owner meth; do
        cls="${owner//\//.}"
        javap -cp "$tmp/classes" "$cls" | grep -q "^public .*class " || { echo "NOT PUBLIC class $cls (called from $name)"; fail=1; }
        javap -cp "$tmp/classes" "$cls" | grep -qE "^  public static .* $meth\(" || { echo "NOT PUBLIC method $cls.$meth (called from $name)"; fail=1; }
    done < <(javap -c -cp "$tmp/classes" "$name" | sed -n 's/.*invokestatic .*Method \(t3bluezone\/[A-Za-z0-9_$]*\)\.\([A-Za-z0-9_]*\):.*/\1 \2/p' | sort -u)
done
[ "$fail" = 0 ] || { echo "build stopped: advice calls non-public members"; exit 1; }

ver="$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$mod/src/t3bluezone/Main.java")"
printf 'Implementation-Title: ZEDGROUND Blue Zone Wall\nImplementation-Version: %s\n' "$ver" > "$tmp/manifest.txt"
jar --create --file "$out/BlueZoneWall.jar" --manifest "$tmp/manifest.txt" -C "$tmp/classes" .
echo "built BlueZoneWall.jar $ver"
jar --list --file "$out/BlueZoneWall.jar"
