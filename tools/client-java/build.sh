#!/usr/bin/env bash
# Builds the optional client Java part of Halo Drop (loaded by ZombieBuddy when the player has it).
#   source : Contents/mods/HALO Drop/42/src/halodropclient/*.java
#   output : Contents/mods/HALO Drop/42/media/java/client/HaloDropClient.jar
# Needs a JDK 21+ (javac, jar). Compiles against the compile-only stub ./stubs/Patch.java (ZombieBuddy's legacy @Patch);
# the game's ZombieBuddy is used at runtime, the stub is not shipped. Game classes are reached by reflection.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mod="$repo/Contents/mods/HALO Drop/42"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs" "$tmp/classes" "$mod/media/java/client"
javac --release 21 -d "$tmp/stubs" "$here/stubs/Patch.java"
javac --release 21 -Xlint:all -cp "$tmp/stubs" -d "$tmp/classes" "$mod/src/halodropclient/"*.java
ver="$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$mod/src/halodropclient/Main.java")"
printf 'Implementation-Title: Halo Drop client\nImplementation-Version: %s\n' "$ver" > "$tmp/manifest.txt"
jar --create --file "$mod/media/java/client/HaloDropClient.jar" --manifest "$tmp/manifest.txt" -C "$tmp/classes" .
echo "built HaloDropClient.jar $ver"
jar --list --file "$mod/media/java/client/HaloDropClient.jar"
