#!/bin/bash
# End-to-end checks against the running Omarchy shell and Hyprland.
# Opens a few short-lived foot windows. Saves and restores the pinned apps.
# Run: tests/integration.sh
set -u

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/scratchpad-pinned/apps.json"
BACKUP=$(mktemp)
cp "$CONFIG" "$BACKUP" 2>/dev/null || echo '{"apps":[]}' > "$BACKUP"
SERVER_PID=""
cleanup() {
  cp "$BACKUP" "$CONFIG"
  rm -f "$BACKUP"
  [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null
  pkill -f -- '--app-id sp-it-' 2>/dev/null
}
trap cleanup EXIT

pass=0 fail=0
check() { # name expected actual
  if [[ $2 == "$3" ]]; then echo "ok - $1"; pass=$((pass + 1))
  else echo "not ok - $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi
}
workspaces() { hyprctl clients -j | jq -r --arg c "$1" '[.[] | select(.class == $c) | .workspace.name] | join(",")'; }
set_config() { printf '%s\n' "$1" > "$CONFIG"; sleep 1; }
ipc() { omarchy-shell scratchpad-pinned "$@"; }

ipc count >/dev/null || { echo "omarchy-shell or the plugin is not running"; exit 1; }
here=$(hyprctl activeworkspace -j | jq -r .name)

# 1. A launch catches its first window only.
set_config '{"apps":[{"appId":"sp-it-once","command":["foot","--app-id","sp-it-once","-e","sleep","12"],"mode":"startup"}]}'
ipc launch sp-it-once; sleep 1.5
foot --app-id sp-it-once -e sleep 8 >/dev/null 2>&1 & sleep 1.5
check "launch: first window hidden, second one left alone" "special:scratchpad,$here" "$(workspaces sp-it-once)"

# 2. An app handing its window to another process (footclient -> foot server)
#    escapes the exec rule; the pending launch still hides it.
foot --server >/dev/null 2>&1 & SERVER_PID=$!; sleep 1
set_config '{"apps":[{"appId":"sp-it-hand","command":["footclient","--app-id","sp-it-hand","sleep","12"],"mode":"startup"}]}'
ipc launch sp-it-hand; sleep 2
check "hand-off: window caught after the fact" "special:scratchpad" "$(workspaces sp-it-hand)"

# 3. A wrong window class is learned from the first launched window.
set_config '{"apps":[{"appId":"sp-it-wrong","desktopId":"","command":["foot","--app-id","sp-it-learn","-e","sleep","12"],"mode":"always"}]}'
ipc launch sp-it-wrong; sleep 2
check "learn: window in the scratchpad" "special:scratchpad" "$(workspaces sp-it-learn)"
check "learn: class saved" "sp-it-learn" "$(jq -r '.apps[0].appId' "$CONFIG")"

# 4. "Always" hides the app's first window, not the next ones.
set_config '{"apps":[{"appId":"sp-it-always","command":["foot","--app-id","sp-it-always","-e","sleep","12"],"mode":"always"}]}'
foot --app-id sp-it-always -e sleep 10 >/dev/null 2>&1 & sleep 1.5
foot --app-id sp-it-always -e sleep 8 >/dev/null 2>&1 & sleep 1.5
check "always: first window hidden, second one left alone" "special:scratchpad,$here" "$(workspaces sp-it-always)"

# 5. bring moves a window out to the current workspace.
addr=$(hyprctl clients -j | jq -r '[.[] | select(.class == "sp-it-always" and .workspace.name == "special:scratchpad")][0].address')
ipc bring "$addr"; sleep 0.8
check "bring: back on the current workspace" "$here,$here" "$(workspaces sp-it-always)"

# 6. The pinned list can hold command lines: owner-only, even after a write.
set_config '{"apps":[]}'
ipc pinApp foot >/dev/null; sleep 1
check "permissions: config directory" "700" "$(stat -c %a "$(dirname "$CONFIG")")"
check "permissions: apps.json" "600" "$(stat -c %a "$CONFIG")"

# 7. Saving never puts the list on a command line, where other accounts can
#    read it in /proc. A save lasts a few milliseconds, so watch the shell's
#    child processes in a tight loop while saving many times. The secret reaches the scanner via
#    the environment, so the scanner's own command line does not match.
secret="sp-it-secret-$$"
set_config '{"apps":[{"appId":"sp-it-secret","command":["foot","--token","'"$secret"'"],"mode":"startup"}]}'
seen=$(mktemp)
SECRET=$secret SHELL_PID=$(pgrep -x -o quickshell) python3 -I -c '
import glob, os, time
secret = os.environ["SECRET"].encode(); root = os.environ["SHELL_PID"]; hits = set()
end = time.monotonic() + 6
while time.monotonic() < end:
    for path in glob.glob("/proc/" + root + "/task/*/children"):
        try:
            with open(path) as f: pids = f.read().split()
        except OSError: continue
        for pid in pids:
            try:
                with open("/proc/" + pid + "/cmdline", "rb") as f:
                    if secret in f.read(): hits.add(pid)
            except OSError: pass
print(len(hits))' > "$seen" &
watcher=$!; sleep 0.3
for _ in $(seq 25); do ipc pinApp foot >/dev/null; sleep 0.15; done
wait "$watcher"
check "save: list never on a command line" "0" "$(cat "$seen")"
rm -f "$seen"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
