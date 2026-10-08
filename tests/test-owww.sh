#!/usr/bin/env bash
# Headless tests for the owww watcher. No audio device, no /sys, no shell.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../bin/owww
source "$ROOT/bin/owww"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}

not_ok() {
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$1" >&2
    if [[ -n "${2:-}" ]]; then
        printf '     %s\n' "$2" >&2
    fi
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        ok "$name"
    else
        not_ok "$name" "got $(printf '%q' "$got") want $(printf '%q' "$want")"
    fi
}

assert_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        ok "$name"
    else
        not_ok "$name" "missing $(printf '%q' "$needle")"
    fi
}

make_supply() {
    local root="$1" name="$2" type="$3" online="$4"
    mkdir -p "$root/$name"
    if [[ -n "$type" ]]; then
        printf '%s\n' "$type" > "$root/$name/type"
    fi
    if [[ -n "$online" ]]; then
        printf '%s\n' "$online" > "$root/$name/online"
    fi
}

ac_is() {
    local root="$1" want="$2" name="$3" got
    OWWW_POWER_SUPPLY="$root" got=$(ac_online)
    assert_eq "$name" "$got" "$want"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- bundled sound ----------------------------------------------------------
header=$(od -An -t x1 -N 12 "$ROOT/sounds/owww-tts.wav" | tr -s ' ')
assert_contains "bundled clip is a RIFF WAVE" "$header" "52 49 46 46"
assert_contains "bundled clip has a WAVE tag" "$header" "57 41 56 45"

# --- service locates its own directory --------------------------------------
# Installed third-party manifests have no __sourceDir. The QML has to derive
# the plugin root from its own file URL so bin/owww and the bundled sound
# still resolve. No Qt runtime here, so this is a static check of Service.qml.
service_qml=$(cat "$ROOT/Service.qml")
assert_contains "Service.qml resolves its directory from the component URL" \
    "$service_qml" 'Qt.resolvedUrl(".")'
assert_contains "Service.qml strips the file:// prefix" "$service_qml" 'file://'
assert_contains "Service.qml URL-decodes the component path" \
    "$service_qml" "decodeURIComponent"
assert_contains "watcher launches bin/owww from pluginDir" \
    "$service_qml" 'root.pluginDir + "/bin/owww"'
assert_contains "watcher passes pluginDir as OWWW_PLUGIN_DIR" \
    "$service_qml" "OWWW_PLUGIN_DIR: root.pluginDir"
dir_block=$(awk '
    /readonly property string pluginDir:/ { grab=1 }
    grab { print }
    grab && /^    }/ { exit }
' "$ROOT/Service.qml")
url_line=$(printf '%s\n' "$dir_block" | grep -n 'Qt.resolvedUrl' | head -1 | cut -d: -f1)
src_line=$(printf '%s\n' "$dir_block" | grep -n '__sourceDir' | head -1 | cut -d: -f1)
if [[ -n "${url_line}" && -n "${src_line}" && "$url_line" -lt "$src_line" ]]; then
    ok "pluginDir consults __sourceDir only after the file URL"
else
    not_ok "pluginDir consults __sourceDir only after the file URL" \
        "url line=${url_line:-missing} __sourceDir line=${src_line:-missing}"
fi

# --- transitions ------------------------------------------------------------
transition=$(
    prev=""
    last_play=0
    DRYRUN=1
    DEBOUNCE=5
    SOUND="$tmp/nope.wav"
    handle_state 1 1000
    handle_state 0 1010
    handle_state 1 1020
    handle_state 0 1021
    handle_state 1 1022
    handle_state 0 1040
    handle_state 1 1050
    handle_state 1 1051
)
plays=$(grep -c 'would play' <<<"$transition" || true)
debounced=$(grep -c 'debounced' <<<"$transition" || true)
unplugs=$(grep -c 'charger unplugged' <<<"$transition" || true)
assert_eq "offline to online plays twice" "$plays" "2"
assert_eq "repeat plug inside the window is debounced once" "$debounced" "1"
assert_eq "unplug is logged and does not play" "$unplugs" "3"
assert_eq "first reading produced no plug line before the first unplug" \
    "${transition%%charger unplugged*}" ""

boundary=$(
    prev=""
    last_play=0
    DRYRUN=1
    DEBOUNCE=5
    SOUND="$tmp/nope.wav"
    handle_state 0 1000
    handle_state 1 1000
    handle_state 0 1001
    handle_state 1 1004
    handle_state 0 1005
    handle_state 1 1005
)
early=$(grep -c 'debounced' <<<"$boundary" || true)
later=$(grep -c 'would play' <<<"$boundary" || true)
assert_eq "plug one second before the window is debounced" "$early" "1"
assert_eq "plug exactly at the debounce mark plays" "$later" "2"

# --- AC detection -----------------------------------------------------------
sys="$tmp/sys"
mkdir -p "$sys"

ac_is "$sys" 0 "empty power_supply tree is offline"

make_supply "$sys" AC Mains 0
ac_is "$sys" 0 "AC type Mains online 0 is offline"

printf '1\n' > "$sys/AC/online"
ac_is "$sys" 1 "AC type Mains online 1 is online"

rm -rf "$sys"/*
make_supply "$sys" ACAD Mains 1
ac_is "$sys" 1 "ACAD type Mains is online"

rm -rf "$sys"/*
make_supply "$sys" ADP1 Mains 1
ac_is "$sys" 1 "ADP1 type Mains is online"

rm -rf "$sys"/*
make_supply "$sys" AC Mains 0
make_supply "$sys" ADP1 Mains 1
ac_is "$sys" 1 "an offline AC node does not hide ADP1"

rm -rf "$sys"/*
make_supply "$sys" BAT0 Battery 1
ac_is "$sys" 0 "a battery is not a charger"

rm -rf "$sys"/*
make_supply "$sys" usb-gadget USB 0
ac_is "$sys" 0 "USB type online 0 is offline"

printf '1 \n' > "$sys/usb-gadget/online"
ac_is "$sys" 1 "USB type online 1 counts, including trailing space"

rm -rf "$sys"/*
make_supply "$sys" "ucsi-source-psy-USBC000:001" USB_PD 1
make_supply "$sys" BAT0 Battery 1
ac_is "$sys" 1 "USB_PD online 1 counts beside a battery"

rm -rf "$sys"/*
make_supply "$sys" port USB_C 1
ac_is "$sys" 1 "USB_C online 1 counts"

rm -rf "$sys"/*
make_supply "$sys" pad Wireless 1
ac_is "$sys" 1 "Wireless online 1 counts"

rm -rf "$sys"/*
mkdir -p "$sys/ADP1"
printf '1\n' > "$sys/ADP1/online"
ac_is "$sys" 1 "ADP1 with no type file still counts"

rm -rf "$sys"/*
mkdir -p "$sys/AC"
printf '0\n' > "$sys/AC/online"
make_supply "$sys" charger USB_PD 1
ac_is "$sys" 1 "named AC offline still yields to USB_PD"

rm -rf "$sys"/*
make_supply "$sys" WEIRD Unknown 1
ac_is "$sys" 0 "unknown type and unknown name is ignored"

rm -rf "$sys"/*
make_supply "$sys" hidpp_battery_0 Battery 1
make_supply "$sys" brick BrickID 1
ac_is "$sys" 1 "BrickID counts and a HID battery does not"

ac_is "$tmp/missing-sysfs" 0 "missing sysfs root is offline"

# --- settings ---------------------------------------------------------------
cfg="$tmp/shell.json"
cat > "$cfg" <<EOF
{
  "version": 1,
  "plugins": [
    {
      "id": "someone.else",
      "sound": "/nope.wav",
      "volume": 0.1
    },
    {
      "id": "io.github.richfeather-cpu.omarchy-owww",
      "sound": "~/Music/charger.wav",
      "volume": 0.4,
      "debounce": 9,
      "poll": 3
    }
  ]
}
EOF

settings=$(
    # shellcheck disable=SC2030
    HOME=/home/rich
    unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL
    OWWW_SHELL_CONFIG="$cfg"
    OWWW_PLUGIN_DIR="$ROOT"
    load_config
    printf 'sound=%s\nvolume=%s\ndebounce=%s\npoll=%s\n' \
        "$SOUND" "$VOLUME" "$DEBOUNCE" "$POLL"
)
assert_eq "shell.json sound expands tilde and ignores other plugins" \
    "$(printf '%s\n' "$settings" | sed -n 's/^sound=//p')" "/home/rich/Music/charger.wav"
assert_eq "shell.json volume" "$(printf '%s\n' "$settings" | sed -n 's/^volume=//p')" "0.4"
assert_eq "shell.json debounce" "$(printf '%s\n' "$settings" | sed -n 's/^debounce=//p')" "9"
assert_eq "shell.json poll" "$(printf '%s\n' "$settings" | sed -n 's/^poll=//p')" "3"

override=$(
    HOME=/home/rich
    OWWW_SHELL_CONFIG="$cfg"
    OWWW_PLUGIN_DIR="$ROOT"
    OWWW_SOUND="/tmp/override.wav"
    OWWW_VOLUME=0
    OWWW_DEBOUNCE=0
    OWWW_POLL=1
    load_config
    printf '%s %s %s %s' "$SOUND" "$VOLUME" "$DEBOUNCE" "$POLL"
)
assert_eq "env vars override shell.json" "$override" "/tmp/override.wav 0 0 1"

bad=$(
    unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL
    OWWW_SHELL_CONFIG="$tmp/bad.json"
    OWWW_PLUGIN_DIR="$ROOT"
    printf '%s\n' '{ "plugins": [ {' > "$OWWW_SHELL_CONFIG"
    load_config 2>"$tmp/bad.err"
    printf 'sound=%s\nvolume=%s\n' "$SOUND" "$VOLUME"
)
assert_eq "invalid shell.json keeps the default sound" \
    "$(printf '%s\n' "$bad" | sed -n 's/^sound=//p')" "$ROOT/sounds/owww-tts.wav"
assert_eq "invalid shell.json keeps the default volume" \
    "$(printf '%s\n' "$bad" | sed -n 's/^volume=//p')" "1.0"
assert_contains "invalid shell.json is reported" "$(cat "$tmp/bad.err")" "not a JSON object"

partial="$tmp/partial.json"
cat > "$partial" <<EOF
{ "version": 1, "plugins": [ { "id": "$PLUGIN_ID", "volume": "nope", "debounce": 2 } ] }
EOF
partial_out=$(
    unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL
    OWWW_SHELL_CONFIG="$partial"
    OWWW_PLUGIN_DIR="$ROOT"
    load_config 2>"$tmp/partial.err"
    printf '%s %s %s' "$SOUND" "$VOLUME" "$DEBOUNCE"
)
assert_eq "invalid volume falls back and a valid debounce is kept" \
    "$partial_out" "$ROOT/sounds/owww-tts.wav 1.0 2"
assert_contains "invalid volume is reported" "$(cat "$tmp/partial.err")" "invalid volume"

loud=$(
    unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL
    OWWW_SHELL_CONFIG=/dev/null
    OWWW_VOLUME=2.1
    OWWW_PLUGIN_DIR="$ROOT"
    load_config 2>"$tmp/loud.err"
    printf '%s' "$VOLUME"
)
assert_eq "volume above 2 falls back" "$loud" "1.0"

poll0=$(
    unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL
    OWWW_SHELL_CONFIG=/dev/null
    OWWW_POLL=0
    OWWW_PLUGIN_DIR="$ROOT"
    load_config 2>/dev/null
    printf '%s' "$POLL"
)
assert_eq "poll of 0 falls back so the loop cannot spin" "$poll0" "10"

defaults=$(
    unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL OWWW_SHELL_CONFIG
    OWWW_PLUGIN_DIR="$ROOT"
    HOME="$tmp/home"
    mkdir -p "$HOME"
    load_config
    printf '%s %s %s %s' "$SOUND" "$VOLUME" "$DEBOUNCE" "$POLL"
)
assert_eq "missing shell.json uses built-in defaults" \
    "$defaults" "$ROOT/sounds/owww-tts.wav 1.0 5 10"

if command -v python3 >/dev/null 2>&1; then
    stub="$tmp/stub-path"
    mkdir -p "$stub"
    ln -s "$(command -v python3)" "$stub/python3"
    if command -v awk >/dev/null 2>&1; then
        ln -s "$(command -v awk)" "$stub/awk"
    fi
    py=$(
        unset OWWW_SOUND OWWW_VOLUME OWWW_DEBOUNCE OWWW_POLL
        PATH="$stub"
        HOME=/home/rich
        OWWW_SHELL_CONFIG="$cfg"
        OWWW_PLUGIN_DIR="$ROOT"
        load_config
        printf '%s %s' "$VOLUME" "$DEBOUNCE"
    )
    assert_eq "settings still load through python3 when jq is absent" "$py" "0.4 9"
else
    not_ok "python3 fallback" "python3 is not installed"
fi

# --- playback ---------------------------------------------------------------
players="$tmp/players"
mkdir -p "$players"
cat > "$players/pw-play" <<'EOF'
#!/bin/bash
printf 'pw %s\n' "$*" >> "$OWWW_PLAYER_LOG"
exit "${PW_PLAY_EXIT:-0}"
EOF
cat > "$players/paplay" <<'EOF'
#!/bin/bash
printf 'pa %s\n' "$*" >> "$OWWW_PLAYER_LOG"
exit 0
EOF
chmod +x "$players/pw-play" "$players/paplay"
printf 'hello\n' > "$tmp/sound.wav"

played=$(
    PATH="$players:$PATH"
    export OWWW_PLAYER_LOG="$tmp/play.log"
    export PW_PLAY_EXIT=0
    : > "$OWWW_PLAYER_LOG"
    DRYRUN=0
    SOUND="$tmp/sound.wav"
    VOLUME=0.5
    play_owww
    cat "$OWWW_PLAYER_LOG"
)
assert_eq "pw-play gets the linear volume and paplay is not called" \
    "$played" "pw --volume 0.5 $tmp/sound.wav"

fallback=$(
    PATH="$players:$PATH"
    export OWWW_PLAYER_LOG="$tmp/play-fallback.log"
    export PW_PLAY_EXIT=1
    : > "$OWWW_PLAYER_LOG"
    DRYRUN=0
    SOUND="$tmp/sound.wav"
    VOLUME=0.5
    play_owww
    cat "$OWWW_PLAYER_LOG"
)
assert_contains "failed pw-play falls through to paplay" "$fallback" "pa --volume"
assert_contains "paplay volume is the 16-bit equivalent of 0.5" "$fallback" "pa --volume 32768 $tmp/sound.wav"

dry=$(
    DRYRUN=1
    SOUND="$tmp/sound.wav"
    play_owww
)
assert_eq "dry-run prints the path and does not play" "$dry" "[dry-run] would play $tmp/sound.wav"

missing=$(
    PATH="$players:$PATH"
    OWWW_PLAYER_LOG="$tmp/play-missing.log"
    : > "$OWWW_PLAYER_LOG"
    DRYRUN=0
    SOUND="$tmp/no-such.wav"
    play_owww 2>&1
    cat "$OWWW_PLAYER_LOG"
)
assert_contains "missing sound is reported" "$missing" "sound file missing"
assert_eq "missing sound does not call a player" "$(cat "$tmp/play-missing.log")" ""

# --- command line -----------------------------------------------------------
printf '%s\n' '{ "version": 1, "plugins": [] }' > "$tmp/empty.json"
sim=$(
    env -u OWWW_SOUND -u OWWW_VOLUME -u OWWW_DEBOUNCE -u OWWW_POLL -u OWWW_DRYRUN \
        OWWW_SHELL_CONFIG="$tmp/empty.json" \
        OWWW_PLUGIN_DIR="$ROOT" \
        "$ROOT/bin/owww" --simulate
)
assert_contains "simulate describes the script" "$sim" "simulating: start=1"
assert_eq "simulate plays twice" "$(grep -c 'would play' <<<"$sim")" "2"
assert_eq "simulate debounces the close pair" "$(grep -c 'charger plugged in (debounced)' <<<"$sim")" "1"

mkdir -p "$tmp/status-sys/ADP1"
printf 'Mains\n' > "$tmp/status-sys/ADP1/type"
printf '1\n' > "$tmp/status-sys/ADP1/online"
status=$(
    env -u OWWW_SOUND -u OWWW_VOLUME -u OWWW_DEBOUNCE -u OWWW_POLL \
        OWWW_SHELL_CONFIG="$cfg" \
        OWWW_PLUGIN_DIR="$ROOT" \
        OWWW_POWER_SUPPLY="$tmp/status-sys" \
        HOME=/home/rich \
        "$ROOT/bin/owww" --status
)
assert_eq "status reports resolved settings and AC" "$status" \
$'sound=/home/rich/Music/charger.wav\nvolume=0.4\ndebounce=9\npoll=3\nac=1'

set +e
"$ROOT/bin/owww" --nope >/dev/null 2>&1
usage_rc=$?
set +e
assert_eq "unknown flag exits 2" "$usage_rc" "2"

# --- stop cleans up the udev child -----------------------------------------
# Quickshell signals only the watcher pid: SIGTERM when Process.running is
# cleared, SIGKILL when the Process object is destroyed. The fake udevadm is
# one process (exec sleep) and must not survive either, including when bash
# is blocked in read -t and cannot run a trap (SIGKILL).
fakebin="$tmp/udev-bin"
mkdir -p "$fakebin"
cat > "$fakebin/udevadm" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$OWWW_UDEV_PIDFILE"
exec sleep 30
EOF
chmod +x "$fakebin/udevadm"

stop_udev_case() {
    local signal="$1" label="$2" expect_zero="$3"
    local pidfile="$tmp/udev-${signal}-${label}.pid"
    local out="$tmp/watch-${signal}-${label}.out"
    local err="$tmp/watch-${signal}-${label}.err"
    local watcher started=0 stopped=0 stop_rc=0 udev="" alive=0 i
    rm -f "$pidfile"
    PATH="$fakebin:$PATH" \
        OWWW_UDEV_PIDFILE="$pidfile" \
        OWWW_NO_PDEATHSIG="${OWWW_NO_PDEATHSIG:-0}" \
        OWWW_SHELL_CONFIG="$tmp/empty.json" \
        OWWW_PLUGIN_DIR="$ROOT" \
        OWWW_POWER_SUPPLY="$tmp/missing-sysfs" \
        "$ROOT/bin/owww" >"$out" 2>"$err" &
    watcher=$!
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        if [[ -s "$pidfile" ]] && grep -q "AC online=0" "$out" 2>/dev/null; then
            started=1
            break
        fi
        sleep 0.05
    done
    if (( started )); then
        ok "$label udevadm monitor was started"
    else
        not_ok "$label udevadm monitor was started" "$(cat "$err" 2>/dev/null || true)"
    fi
    udev=$(cat "$pidfile" 2>/dev/null || true)
    kill "-${signal}" "$watcher" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        if ! kill -0 "$watcher" 2>/dev/null; then
            stopped=1
            break
        fi
        sleep 0.05
    done
    if (( stopped )); then
        set +e
        wait "$watcher" 2>/dev/null
        stop_rc=$?
        set +e
        if (( expect_zero )); then
            assert_eq "$label exits 0" "$stop_rc" "0"
        else
            ok "$label parent was killed"
        fi
    else
        not_ok "$label parent was killed" "watcher still running"
        kill -KILL "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
    fi
    alive=0
    if [[ -n "$udev" ]]; then
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
            if ! kill -0 "$udev" 2>/dev/null; then
                alive=0
                break
            fi
            alive=1
            sleep 0.05
        done
    fi
    if (( alive )); then
        not_ok "$label leaves no udevadm child" "pid $udev still running"
        kill -KILL "$udev" 2>/dev/null || true
    else
        ok "$label leaves no udevadm child"
    fi
    assert_contains "$label logged the first AC reading" "$(cat "$out" 2>/dev/null || true)" "AC online=0"
}

OWWW_NO_PDEATHSIG=0 stop_udev_case TERM "SIGTERM" 1
OWWW_NO_PDEATHSIG=0 stop_udev_case KILL "SIGKILL" 0
# Same kill, without setpriv, so the parent-pid watchdog has to reap the child.
OWWW_NO_PDEATHSIG=1 stop_udev_case KILL "SIGKILL without setpriv" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
    exit 1
fi
