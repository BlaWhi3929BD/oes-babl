#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home"

# Stub display queries so these checks never open or contact a real display.
cat > "$test_dir/bin/niri" <<'SH'
#!/bin/bash
[[ -n ${TEST_NIRI:-} ]] || exit 1
printf '%s\n' "$TEST_NIRI"
SH
cat > "$test_dir/bin/kscreen-doctor" <<'SH'
#!/bin/bash
[[ -n ${TEST_KSCREEN:-} ]] || exit 1
printf '%s\n' "$TEST_KSCREEN"
SH
cat > "$test_dir/bin/xrandr" <<'SH'
#!/bin/bash
[[ -n ${TEST_XRANDR:-} ]] || exit 1
printf '%s\n' "$TEST_XRANDR"
SH
chmod +x "$test_dir/bin/niri" "$test_dir/bin/kscreen-doctor" "$test_dir/bin/xrandr"
export PATH="$test_dir/bin:$PATH"
export HOME="$test_dir/home"
export XDG_CONFIG_HOME="$test_dir/config with spaces"
export ZDOTDIR="$test_dir/zsh config"
unset OES_BABL_SIZE

check_case() {
    local label=$1 expected=$2 actual
    bash "$source_dir/install.sh" > "$test_dir/install.log"
    actual=$(cat "$XDG_CONFIG_HOME/oes-babl/screen-size")
    [[ $actual == "$expected" ]] || {
        printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
        exit 1
    }
    [[ -x $HOME/.local/bin/oes-babl ]]
    "$HOME/.local/bin/oes-babl" --help > "$test_dir/help"
    grep -Fq "Размер экрана: $expected " "$test_dir/help"
    printf 'PASS %s\n' "$label"
}

export TEST_NIRI='{"modes":[{"width":1920,"height":1200}],"current_mode":0,"logical":{"width":1536,"height":960,"transform":"Normal"}}'
export TEST_XRANDR='DP-1 connected primary 1536x960+0+0 (normal)'
check_case 'niri physical mode, not scaled Xwayland geometry' 1920x1200

export TEST_NIRI='{"modes":[{"width":1920,"height":1200}],"current_mode":0,"logical":{"transform":"90"}}'
check_case 'rotated niri output' 1200x1920

export TEST_NIRI='null'
export TEST_KSCREEN='{"outputs":[{"connected":true,"enabled":true,"priority":2,"currentModeId":"1","modes":[{"id":"1","size":{"width":1920,"height":1080}}],"rotation":1},{"connected":true,"enabled":true,"priority":1,"currentModeId":"2","modes":[{"id":"2","size":{"width":2560,"height":1600}}],"rotation":1}]}'
export TEST_XRANDR='eDP-1 connected primary 1600x1000+0+0 (normal)'
check_case 'KDE Plasma physical mode, primary priority output' 2560x1600

export TEST_KSCREEN='{"outputs":[{"connected":true,"enabled":true,"priority":1,"currentModeId":"1","modes":[{"id":"1","size":{"width":1920,"height":1080}}],"rotation":2}]}'
check_case 'rotated KDE Plasma output' 1080x1920

export TEST_KSCREEN=
export TEST_XRANDR=$'DP-1 connected 1920x1080+0+0 (normal)\nDP-2 connected primary 2560x1440-2560+0 (normal)'
check_case 'X11 primary active monitor' 2560x1440

export TEST_NIRI='{"modes":[],"current_mode":null}'
export TEST_XRANDR=$'DP-1 disconnected\nDP-2 connected 1600x900+0+0 (normal)\nDP-3 connected 1280x720+1600+0 (normal)'
check_case 'X11 first active monitor' 1600x900

export TEST_NIRI='invalid JSON'
export TEST_XRANDR='DP-1 disconnected'
check_case 'no active monitor: standard fallback' 1920x1080

export TEST_NIRI='{"modes":[{"width":2560,"height":1600}],"current_mode":0}'
check_case 'reinstall replaces the saved resolution' 2560x1600

[[ $(grep -Fc '# oes-babl' "$HOME/.bashrc") == 1 ]]
printf '%s\n' 'PASS reinstall does not duplicate Bash configuration'
bash --noprofile --norc -c 'source "$HOME/.bashrc"; oes-babl --help' > "$test_dir/help"
grep -Fq 'Размер экрана: 2560x1600 ' "$test_dir/help"
printf '%s\n' 'PASS Bash command works without changing PATH'

if command -v zsh >/dev/null; then
    [[ $(grep -Fc '# oes-babl' "$ZDOTDIR/.zshrc") == 1 ]]
    [[ ! -e $HOME/.zshrc ]]
    PATH=/usr/bin:/bin zsh -d -i -c 'oes-babl --help' > "$test_dir/help"
    grep -Fq 'Размер экрана: 2560x1600 ' "$test_dir/help"
    printf '%s\n' 'PASS Zsh uses ZDOTDIR, works without PATH, and installs once'
fi

OES_BABL_SIZE=1280x720 "$HOME/.local/bin/oes-babl" --help > "$test_dir/help"
grep -Fq 'Размер экрана: 1280x720 ' "$test_dir/help"
printf '%s\n' 'PASS explicit size overrides saved setting'

printf '%s\n' 'invalid saved size' > "$XDG_CONFIG_HOME/oes-babl/screen-size"
"$HOME/.local/bin/oes-babl" --help > "$test_dir/help"
grep -Fq 'Размер экрана: 1920x1080 ' "$test_dir/help"
printf '%s\n' 'PASS invalid saved setting falls back safely'

rm "$XDG_CONFIG_HOME/oes-babl/screen-size"
"$HOME/.local/bin/oes-babl" --help > "$test_dir/help"
grep -Fq 'Размер экрана: 1920x1080 ' "$test_dir/help"
printf '%s\n' 'PASS missing saved setting falls back safely'

"$HOME/.local/bin/oes-babl" --auto-size --help > "$test_dir/help"
grep -Fq 'Размер экрана: 2560x1600 ' "$test_dir/help"
printf '%s\n' 'PASS --auto-size dynamically queries active monitor at launch'

OES_BABL_SIZE=auto "$HOME/.local/bin/oes-babl" --help > "$test_dir/help"
grep -Fq 'Размер экрана: 2560x1600 ' "$test_dir/help"
printf '%s\n' 'PASS OES_BABL_SIZE=auto dynamically queries active monitor at launch'
