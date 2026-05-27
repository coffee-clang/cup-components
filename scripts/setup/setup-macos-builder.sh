#!/usr/bin/env bash
set -euo pipefail

brew_install_if_missing() {
    local package="$1"

    if brew list --formula "$package" >/dev/null 2>&1; then
        echo "$package already installed"
    else
        brew install "$package"
    fi
}

brew_prefix_if_installed() {
    brew --prefix "$1" 2>/dev/null || true
}

append_github_env() {
    local name="$1"
    local value="$2"

    if [ -n "$value" ] && [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "$name" "$value" >> "$GITHUB_ENV"
    fi
}

append_path_list() {
    local current="$1"
    local separator="$2"
    local value="$3"

    if [ -z "$value" ]; then
        printf '%s\n' "$current"
    elif [ -z "$current" ]; then
        printf '%s\n' "$value"
    else
        printf '%s%s%s\n' "$current" "$separator" "$value"
    fi
}

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required on macOS runners" >&2
    exit 1
fi

brew update

brew_install_if_missing bash
brew_install_if_missing cmake
brew_install_if_missing ninja
brew_install_if_missing python
brew_install_if_missing swig
brew_install_if_missing xz
brew_install_if_missing zstd
brew_install_if_missing zlib
brew_install_if_missing libxml2
brew_install_if_missing ncurses
brew_install_if_missing libedit
brew_install_if_missing pkg-config

cmake_prefix_path="${CMAKE_PREFIX_PATH:-}"
pkg_config_path="${PKG_CONFIG_PATH:-}"

for package in zlib xz zstd libxml2 ncurses libedit python swig; do
    prefix="$(brew_prefix_if_installed "$package")"
    if [ -z "$prefix" ]; then
        continue
    fi

    cmake_prefix_path="$(append_path_list "$cmake_prefix_path" ';' "$prefix")"

    if [ -d "$prefix/lib/pkgconfig" ]; then
        pkg_config_path="$(append_path_list "$pkg_config_path" ':' "$prefix/lib/pkgconfig")"
    fi
done

append_github_env CMAKE_PREFIX_PATH "$cmake_prefix_path"
append_github_env PKG_CONFIG_PATH "$pkg_config_path"

if [ -n "${GITHUB_PATH:-}" ]; then
    brew_bash_prefix="$(brew --prefix bash)"
    printf '%s/bin\n' "$brew_bash_prefix" >> "$GITHUB_PATH"
fi
