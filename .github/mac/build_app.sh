#!/bin/bash
# Builds Vanguard.app for this Mac's CPU (arm64 or x64): the player launcher jar from a release, wrapped by jpackage
# with its own Java 17, so players never install Java. Run by .github/workflows/mac-app.yml on a macOS runner.
#   build_app.sh <launcher jar> <out dir> [live|staff] [new|classic]
#   (staff: a test app on the staff channel, BETA; classic: the classic window, -Dvanguard.classicLauncher=true)
set -euo pipefail
JAR="$1"; OUT="$2"; CHANNEL="${3:-live}"; WINDOW="${4:-new}"
CHANNEL_OPTS=()
[ "$CHANNEL" = staff ] && CHANNEL_OPTS=(--java-options -Dvanguard.channel=staff)
[ "$WINDOW" = classic ] && CHANNEL_OPTS+=(--java-options -Dvanguard.classicLauncher=true)
WORK="$(mktemp -d)"
mkdir -p "$OUT" "$WORK/input"
cp "$JAR" "$WORK/input/Vanguard-Launcher.jar"
unzip -l "$JAR" | grep -q 'com/volaris/launcher/Launcher.class' || { echo "not the launcher jar: $JAR"; exit 1; }

# The Dock / Finder icon: the launcher's own branding/icon.png, at every size macOS asks for
unzip -p "$JAR" branding/icon.png > "$WORK/icon.png"
mkdir "$WORK/Vanguard.iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon.png" --out "$WORK/Vanguard.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$WORK/icon.png" --out "$WORK/Vanguard.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/Vanguard.iconset" -o "$WORK/Vanguard.icns"

# The same jpackage call as the Windows package (package-launcher.py), plus the Mac bundle id and icon
jpackage --type app-image --name Vanguard --app-version 1.0.0 --vendor Vanguard \
  --description "Vanguard player launcher" \
  --input "$WORK/input" --main-jar Vanguard-Launcher.jar --main-class com.volaris.launcher.Launcher \
  --dest "$WORK/image" --add-modules ALL-MODULE-PATH \
  --jlink-options "--strip-debug --no-man-pages --no-header-files" \
  --java-options -Xmx256m "${CHANNEL_OPTS[@]+"${CHANNEL_OPTS[@]}"}" \
  --icon "$WORK/Vanguard.icns" --mac-package-identifier com.vanguardmmo.launcher --mac-package-name Vanguard

APP="$WORK/image/Vanguard.app"
[ -x "$APP/Contents/runtime/Contents/Home/bin/java" ] || { echo "no bundled Java in the app"; exit 1; }
"$APP/Contents/runtime/Contents/Home/bin/java" -version
# ad-hoc signature: Apple Silicon runs no unsigned native code (a Developer ID can replace this later)
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "launcher binary: $(lipo -archs "$APP/Contents/MacOS/Vanguard")"
# the native entry point, not just the runtime: it must start the bundled Java and find its own launcher jar
"$APP/Contents/MacOS/Vanguard" --runtime-check "$OUT/runtime-check.txt"
cat "$OUT/runtime-check.txt"; echo
grep -q '^PASS:' "$OUT/runtime-check.txt"
ditto "$APP" "$OUT/Vanguard.app"
rm -rf "$WORK"
