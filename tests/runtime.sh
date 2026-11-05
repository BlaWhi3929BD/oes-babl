#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$source_dir/oes-babl"
test_dir=$(mktemp -d)
child_pid=
cleanup_test() {
    [[ -z $child_pid ]] || kill "$child_pid" 2>/dev/null || true
    rm -rf -- "$test_dir"
}
trap cleanup_test EXIT
export HOME="$test_dir/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="$test_dir/runtime"
mkdir -p "$XDG_CONFIG_HOME/niri" "$test_dir/bin"
mkdir -m 700 "$XDG_RUNTIME_DIR"
unset OES_BABL_LAYOUT OES_BABL_XKB_OPTIONS XDG_SESSION_DESKTOP

# The same directory validator handles both XDG_RUNTIME_DIR and the /tmp fallback.
mkdir -m 755 "$test_dir/victim"
printf 'keep this data\n' > "$test_dir/victim/lock"
ln -s "$test_dir/victim" "$XDG_RUNTIME_DIR/oes-babl"
if (prepare_runtime) 2>/dev/null; then
    printf '%s\n' 'FAIL runtime symlink accepted' >&2; exit 1
fi
[[ $(stat -c '%a' "$test_dir/victim") == 755 ]]
[[ $(cat "$test_dir/victim/lock") == 'keep this data' ]]
rm "$XDG_RUNTIME_DIR/oes-babl"
printf '%s\n' 'PASS symlink rejected without changing target permissions or contents'

mkdir -m 755 "$XDG_RUNTIME_DIR/oes-babl"
if (prepare_runtime) 2>/dev/null; then
    printf '%s\n' 'FAIL public runtime directory accepted' >&2; exit 1
fi
[[ $(stat -c '%a' "$XDG_RUNTIME_DIR/oes-babl") == 755 ]]
rmdir "$XDG_RUNTIME_DIR/oes-babl"
printf '%s\n' 'PASS unsafe permissions rejected without chmod'

(prepare_runtime)
ln -s "$test_dir/victim/lock" "$XDG_RUNTIME_DIR/oes-babl/lock-link"
mv "$XDG_RUNTIME_DIR/oes-babl/lock-link" "$XDG_RUNTIME_DIR/oes-babl/lock"
if (prepare_runtime) 2>/dev/null; then
    printf '%s\n' 'FAIL lock symlink accepted' >&2; exit 1
fi
[[ $(cat "$test_dir/victim/lock") == 'keep this data' ]]
rm "$XDG_RUNTIME_DIR/oes-babl/lock"
printf '%s\n' 'PASS lock symlink rejected without truncating its target'

printf 'existing lock content\n' > "$XDG_RUNTIME_DIR/oes-babl/lock"
prepare_runtime
[[ $(cat "$runtime_dir/lock") == 'existing lock content' ]]
if (exec 9>&-; prepare_runtime) 2>/dev/null; then
    printf '%s\n' 'FAIL concurrent launcher acquired lock' >&2; exit 1
fi
exec 9>&-
printf '%s\n' 'PASS exclusive lock preserves existing content'

cat > "$test_dir/bin/xprop" <<'SH'
#!/bin/sh
printf '%s\n' '_XKB_RULES_NAMES(STRING) = "evdev", "pc105", "de", "", ""'
SH
chmod +x "$test_dir/bin/xprop"
export PATH="$test_dir/bin:$PATH"
printf 'layout "us,ru"\noptions "grp:win_space_toggle"\n' > "$XDG_CONFIG_HOME/niri/config.kdl"
printf '[Layout]\nLayoutList=us,de\nOptions=grp:ctrl_shift_toggle\n' > "$XDG_CONFIG_HOME/kxkbrc"
export XDG_CURRENT_DESKTOP=niri
select_keyboard
[[ $xkb_layout == us,ru && $xkb_options == grp:win_space_toggle ]]
printf '%s\n' 'PASS niri layout and options take priority over stale KDE config'

export XDG_CURRENT_DESKTOP=KDE
select_keyboard
[[ $xkb_layout == us,de && $xkb_options == grp:ctrl_shift_toggle ]]
printf '%s\n' 'PASS KDE uses its own layout and options'

printf '[Layout]\nLayoutList=us,ru\nOptions=scrolllock:mod3\n' > "$XDG_CONFIG_HOME/kxkbrc"
printf '[KDE Keyboard Layout Switcher]\nSwitch to Next Keyboard Layout=Alt+Shift,Alt+Shift,Switch to Next Keyboard Layout\n' > "$XDG_CONFIG_HOME/kglobalshortcutsrc"
select_keyboard
[[ $xkb_layout == us,ru && $xkb_options == scrolllock:mod3,grp:alt_shift_toggle ]]
printf '%s\n' 'PASS KDE appends kglobalshortcutsrc toggle when kxkbrc Options lacks grp:*'

printf '[KDE Keyboard Layout Switcher]\nSwitch to Next Keyboard Layout=Meta+Space,Meta+Space,Switch to Next Keyboard Layout\n' > "$XDG_CONFIG_HOME/kglobalshortcutsrc"
select_keyboard
[[ $xkb_layout == us,ru && $xkb_options == scrolllock:mod3,grp:win_space_toggle ]]
printf '%s\n' 'PASS KDE maps Meta+Space shortcut from kglobalshortcutsrc to grp:win_space_toggle'

unset XDG_CURRENT_DESKTOP
select_keyboard
[[ $xkb_layout == de ]]
printf '%s\n' 'PASS unknown desktop preserves single host layout'

OES_BABL_LAYOUT=us,kz OES_BABL_XKB_OPTIONS= select_keyboard
[[ $xkb_layout == us,kz && -z $xkb_options ]]
printf '%s\n' 'PASS explicit keyboard overrides, including empty options'
if (OES_BABL_LAYOUT='us;false' select_keyboard) 2>/dev/null; then
    printf '%s\n' 'FAIL invalid keyboard override accepted' >&2; exit 1
fi
printf '%s\n' 'PASS invalid keyboard override rejected'

profile=$test_dir/profile
mkdir "$profile"
ln -s "test-host-$$" "$profile/SingletonLock"
if profile_in_use "$profile"; then
    printf '%s\n' 'FAIL unrelated reused PID treated as Chrome' >&2; exit 1
fi
printf '%s\n' 'PASS unrelated process does not block Chrome profile'

bash -c 'exec -a chrome sleep 30' &
child_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    process=
    IFS= read -r -d '' process < "/proc/$child_pid/cmdline" || true
    [[ $process == chrome ]] && break
    sleep 0.01
done
rm "$profile/SingletonLock"
ln -s "test-host-$child_pid" "$profile/SingletonLock"
profile_in_use "$profile"
stop_process "$child_pid" 10
wait "$child_pid" 2>/dev/null || true
! kill -0 "$child_pid" 2>/dev/null
child_pid=
printf '%s\n' 'PASS active Chrome identity detected and process stops'

bash -c 'trap "" TERM; exec -a stubborn sleep 30' &
child_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    process=
    IFS= read -r -d '' process < "/proc/$child_pid/cmdline" || true
    [[ $process == stubborn ]] && break
    sleep 0.01
done
stop_process "$child_pid" 1
wait "$child_pid" 2>/dev/null || true
! kill -0 "$child_pid" 2>/dev/null
child_pid=
printf '%s\n' 'PASS process ignoring TERM is stopped after the grace period'

OES_BABL_CLIPBOARD=0 start_clipboard_bridge :0 :99 "$test_dir/nonexistent" "$test_dir/clipboard.log"
[[ -z $clipboard_pid ]]
printf '%s\n' 'PASS clipboard bridge skipped when OES_BABL_CLIPBOARD=0'

if (OES_BABL_CLIPBOARD=invalid start_clipboard_bridge :0 :99 "$test_dir/nonexistent" "$test_dir/clipboard.log") 2>/dev/null; then
    printf '%s\n' 'FAIL invalid OES_BABL_CLIPBOARD accepted' >&2; exit 1
fi
printf '%s\n' 'PASS invalid OES_BABL_CLIPBOARD rejected'
