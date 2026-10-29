#!/bin/bash
# Installs Vanguard.app from a DMG the way a player does (drag to Applications) and runs it on this Mac:
# the bundled-Java check, the launcher window, a real update from the live release, then the game itself.
# Writes smoke/summary.json, screenshots and logs.   smoke.sh <dmg>
set -uo pipefail
DMG="$1"
OUT="$PWD/smoke"; mkdir -p "$OUT"
APP="$HOME/Applications/Vanguard.app"
VG="$HOME/Vanguard"
[ "${CHANNEL:-live}" = staff ] && VG="$HOME/VanguardStaff"   # the staff channel's own home (client update/Channel)
res() { echo "$1=$2" >> "$OUT/results.txt"; }   # bash 3.2 (macOS) has no associative arrays
: > "$OUT/results.txt"

limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # macOS has no timeout(1)
shot() { screencapture -x "$OUT/$1.png" 2>>"$OUT/screencapture.err" || true; }

{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string; system_profiler SPDisplaysDataType 2>/dev/null | head -20; } > "$OUT/system.txt"

MNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
ls -la "$MNT" > "$OUT/dmg-contents.txt"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$MNT/Vanguard.app" "$APP" && res installed true || res installed false
hdiutil detach "$MNT" >/dev/null || true

codesign --verify --deep --strict --verbose=2 "$APP" > "$OUT/codesign.txt" 2>&1 && res signature_valid true || res signature_valid false
echo "launcher: $(lipo -archs "$APP/Contents/MacOS/Vanguard")  libjvm: $(lipo -archs "$APP/Contents/runtime/Contents/Home/lib/server/libjvm.dylib")" >> "$OUT/codesign.txt"
# what Gatekeeper will say to a player who downloaded it (expected: rejected until they choose Open Anyway)
spctl --assess --type execute -vv "$APP" >> "$OUT/codesign.txt" 2>&1 || true

limit 120 "$APP/Contents/MacOS/Vanguard" --runtime-check "$OUT/runtime-check.txt" > "$OUT/runtime-check.out" 2>&1
grep -q '^PASS:' "$OUT/runtime-check.txt" 2>/dev/null && res runtime_check true || res runtime_check false
limit 120 "$APP/Contents/MacOS/Vanguard" --preview "$OUT/launcher-preview.png" > "$OUT/preview.out" 2>&1
[ -s "$OUT/launcher-preview.png" ] && res launcher_preview true || res launcher_preview false

# The real thing: open the app from Finder's point of view. The launcher updates at once (cache + client from the
# latest release) and then waits for Play.
shot desktop-before
open "$APP"
sleep 15; shot launcher-open
installed=false
for i in $(seq 1 200); do
  if ls "$VG"/client/*/client.jar >/dev/null 2>&1 && ls "$VG"/cache/*/.verified >/dev/null 2>&1; then installed=true; break; fi
  [ -f "$VG/launcher-error.log" ] && break
  sleep 5
done
sleep 5; shot launcher-after-update
res update_installed $installed
# launcher v2: the bootstrap fetched the release's launcher window and it started (UiBootstrap writes last-good.txt)
[ -f "$VG/launcherui/last-good.txt" ] && res launcher_ui_started true || res launcher_ui_started false
[ -f "$VG/launcher-ui-error.log" ] && cp "$VG/launcher-ui-error.log" "$OUT/"
[ -f "$VG/launcher-error.log" ] && cp "$VG/launcher-error.log" "$OUT/"

# Play: click the launcher's button through the accessibility API if this Mac allows it...
started=none
if [ "$installed" = true ]; then
  osascript -e 'tell application "System Events" to tell process "Vanguard" to get entire contents of window 1' > "$OUT/launcher-ui-tree.txt" 2>&1
  osascript "$(dirname "$0")/click_play.applescript" > "$OUT/click.txt" 2>&1
  sleep 3; shot after-click   # the launcher's own message (a toast) shows for about 3 s
  sleep 22
  if pgrep -f 'vanguard.build=player' >/dev/null; then
    started="launcher-play-button ($(head -c 120 "$OUT/click.txt"))"
    # the game must run on the app's own Java, not anything else on the Mac
    ps -o command= -p "$(pgrep -f 'vanguard.build=player' | head -1)" | tr ' ' '\n' | head -1 > "$OUT/game-java.txt"
    grep -q 'Vanguard.app/Contents/runtime' "$OUT/game-java.txt" && res game_on_bundled_java true || res game_on_bundled_java false
  else
    # ...otherwise start the game exactly as Launcher.start() does on a Mac, with the app's own Java
    started=same-command
    CACHE=$(dirname "$(ls "$VG"/cache/*/.verified | head -1)")
    JAR=$(ls "$VG"/client/*/client.jar | head -1)
    ( cd "$VG" && "$APP/Contents/runtime/Contents/Home/bin/java" -Xms512m -Xmx2g -XX:+UseZGC \
        --add-exports=java.desktop/com.apple.eawt=ALL-UNNAMED --add-opens=java.desktop/com.apple.eawt=ALL-UNNAMED \
        -Xshare:auto -Dvanguard.build=player "-Dvanguard.cache=$CACHE" -Dvanguard.managedCache=true -Dvanguard.launcher=2 -jar "$JAR" \
        >> "$VG/client.log" 2>&1 & )
  fi
  for t in 30 60 90 120 150; do sleep 30; shot "game-${t}s"; done
fi
res game_started_by "$started"
# launcher v2: one line per PLAY - what the press found and how the start went
[ -f "$VG/launcher-play.log" ] && cp "$VG/launcher-play.log" "$OUT/"
pgrep -f 'vanguard.build=player' >/dev/null && res game_alive_after_150s true || res game_alive_after_150s false
[ -f "$VG/client.log" ] && tail -n 600 "$VG/client.log" > "$OUT/client-log-tail.txt"
ls "$VG"/hs_err_pid*.log >/dev/null 2>&1 && { cp "$VG"/hs_err_pid*.log "$OUT/"; res jvm_crash true; } || res jvm_crash false
grep -c -E 'Exception|Error' "$OUT/client-log-tail.txt" > "$OUT/client-log-error-lines.txt" 2>/dev/null || true
pkill -f 'vanguard.build=player' || true
pkill -f 'Vanguard.app/Contents/MacOS/Vanguard' || true

python3 - "$OUT/results.txt" "$OUT/summary.json" <<'PY'
import json, sys
r = {}
for line in open(sys.argv[1]):
    k, _, v = line.strip().partition('=')
    r[k] = {'true': True, 'false': False}.get(v, v)
json.dump(r, open(sys.argv[2], 'w'), indent=2)
PY
cat "$OUT/summary.json"
