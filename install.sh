#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$source_dir/oes-babl"

if screen_size=$(detect_size); then
    printf 'Определено разрешение монитора: %s\n' "$screen_size"
else
    screen_size=1920x1080
    printf 'Монитор не определён. Используется стандартное разрешение: %s\n' "$screen_size"
fi
config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/oes-babl
mkdir -p "$config_dir"
printf '%s\n' "$screen_size" > "$config_dir/screen-size"
printf 'Размер сохранён: %s/screen-size\n' "$config_dir"

install -Dm755 "$source_dir/oes-babl" "$HOME/.local/bin/oes-babl"
printf 'Установлено: %s/.local/bin/oes-babl\n' "$HOME"

install -Dm644 "$source_dir/bash/oes-babl.bash" "$config_dir/oes-babl.bash"
bash_source_line='[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/oes-babl/oes-babl.bash" ] || . "${XDG_CONFIG_HOME:-$HOME/.config}/oes-babl/oes-babl.bash"'
if ! grep -Fqx -- "$bash_source_line" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# oes-babl\n%s\n' "$bash_source_line" >> "$HOME/.bashrc"
fi
printf '%s\n' 'Команда oes-babl добавлена в Bash. Откройте новый терминал или выполните: source ~/.bashrc'

if command -v zsh >/dev/null; then
    zshrc=${ZDOTDIR:-$HOME}/.zshrc
    mkdir -p -- "$(dirname -- "$zshrc")"
    if ! grep -Fqx -- "$bash_source_line" "$zshrc" 2>/dev/null; then
        printf '\n# oes-babl\n%s\n' "$bash_source_line" >> "$zshrc"
    fi
    printf 'Команда oes-babl добавлена в Zsh: %s. Откройте новый терминал.\n' "$zshrc"
fi

if command -v fish >/dev/null; then
    fish_config=${XDG_CONFIG_HOME:-$HOME/.config}/fish
    install -Dm644 "$source_dir/fish/oes-babl.fish" "$fish_config/functions/oes-babl.fish"
    install -Dm644 "$source_dir/fish/completions/oes-babl.fish" "$fish_config/completions/oes-babl.fish"
    printf '%s\n' 'Команда oes-babl и автодополнение доступны в fish без перезапуска терминала.'
else
    printf '%s\n' 'Для запуска используйте ~/.local/bin/oes-babl или добавьте ~/.local/bin в PATH.'
fi
