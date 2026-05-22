#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  $0 <package-root> <tool>

Prints a non-fatal capability inventory for a packaged cup component.

The source of truth is info.txt: package/build scripts write package identity,
entry points, contents.*, config.* and features.* metadata there.  This script
prints that contract and performs light probes to highlight obvious mismatches.
It does not decide acceptance by itself; tool-specific tests fail when declared
features cannot be exercised.
USAGE
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 2
fi

root="$1"
tool="$2"
info="$root/info.txt"

if [ ! -d "$root" ]; then
    echo "package root not found: $root" >&2
    exit 1
fi

info_value() {
    local key="$1"
    if [ -f "$info" ]; then
        awk -F= -v key="$key" '$1 == key { print $2; found=1 } END { if (!found) print "" }' "$info"
    fi
}

info_true() {
    [ "$(info_value "$1")" = "true" ]
}

has_exe() {
    local exe="$1"
    [ -x "$root/bin/$exe" ] || [ -x "$root/bin/$exe.exe" ]
}

mark_exe() {
    local exe="$1"
    local declared_key="${2:-}"
    local declared=""

    if [ -n "$declared_key" ]; then
        declared="$(info_value "$declared_key")"
    fi

    if has_exe "$exe"; then
        printf '  present  %-28s' "$exe"
    else
        printf '  missing  %-28s' "$exe"
    fi

    if [ -n "$declared_key" ]; then
        printf ' declared:%s=%s' "$declared_key" "${declared:-unset}"
        if [ "$declared" = "true" ] && ! has_exe "$exe"; then
            printf '  WARNING: declared true but executable missing'
        elif [ "$declared" != "true" ] && has_exe "$exe"; then
            printf '  note: executable present but feature not declared true'
        fi
    fi
    printf '\n'
}

try_version() {
    local exe="$1"
    shift
    if has_exe "$exe"; then
        echo ""
        echo "[version: $exe]"
        if [ -x "$root/bin/$exe" ]; then
            "$root/bin/$exe" "$@" 2>&1 | sed -n '1,8p' || true
        else
            "$root/bin/$exe.exe" "$@" 2>&1 | sed -n '1,8p' || true
        fi
    fi
}

show_info_contract() {
    if [ ! -f "$info" ]; then
        echo "info.txt: missing"
        return 0
    fi

    echo ""
    echo "[package identity]"
    for key in \
        package.component package.tool package.version package.revision package.mode package.formats \
        platform.host platform.target platform.host_triple platform.target_triple \
        source.primary.name source.primary.version build.environment build.source_policy; do
        value="$(info_value "$key")"
        if [ -n "$value" ]; then
            printf '  %-30s %s\n' "$key" "$value"
        fi
    done

    echo ""
    echo "[entry points declared in info.txt]"
    grep -E '^entry\.' "$info" | sort | sed 's/^/  /' || echo "  none"

    echo ""
    echo "[features declared in info.txt]"
    grep -E '^features\.' "$info" | sort | sed 's/^/  /' || echo "  none"

    echo ""
    echo "[contents/config/bundle metadata]"
    grep -E '^(contents|config|bundle)\.' "$info" | sort | sed 's/^/  /' || echo "  none"
}

show_bin_summary() {
    echo ""
    echo "[bin summary]"
    if [ -d "$root/bin" ]; then
        find "$root/bin" -maxdepth 1 -type f -perm -111 -printf '%f\n' 2>/dev/null | sort | sed 's/^/  /' || true
        find "$root/bin" -maxdepth 1 -type f -name '*.exe' -printf '%f\n' 2>/dev/null | sort | sed 's/^/  /' || true
    else
        echo "  missing bin directory"
    fi
}

show_gcc() {
    echo ""
    echo "[GCC capability probes]"
    mark_exe gcc features.c
    mark_exe g++ features.cpp
    mark_exe cpp features.preprocessor
    mark_exe gcov features.gcov
    mark_exe lto-dump features.lto_dump
    mark_exe as features.binutils
    mark_exe ld features.binutils
    mark_exe ar features.binutils
    mark_exe ranlib features.binutils
    mark_exe strip features.binutils
    mark_exe objdump features.binutils
    mark_exe readelf features.binutils

    target_triple="$(info_value platform.target_triple)"
    if [ -n "$target_triple" ]; then
        echo ""
        echo "[target-prefixed probes: $target_triple]"
        for exe in gcc g++ cpp as ld ar ranlib strip objdump readelf; do
            mark_exe "$target_triple-$exe" features.target_prefixed_tools
        done
    fi

    try_version gcc --version
    try_version g++ --version
    [ -n "$target_triple" ] && try_version "$target_triple-gcc" --version
}

show_gdb() {
    echo ""
    echo "[GDB capability probes]"
    mark_exe gdb features.debug_native
    mark_exe gdbserver features.gdbserver
    try_version gdb --version
    if has_exe gdb; then
        echo ""
        echo "[gdb configuration excerpt]"
        "$root/bin/gdb" --configuration 2>&1 | sed -n '1,35p' || true
    fi
}

show_llvm() {
    echo ""
    echo "[LLVM-family capability probes]"
    case "$tool" in
        clang)
            mark_exe clang features.c
            mark_exe clang++ features.cpp
            mark_exe ld.lld features.lld_integration
            mark_exe llvm-ar features.llvm_ar
            mark_exe llvm-ranlib features.llvm_ranlib
            mark_exe llvm-objdump features.llvm_objdump
            try_version clang --version
            ;;
        lld)
            mark_exe ld.lld features.link_elf
            mark_exe lld-link features.link_coff
            mark_exe wasm-ld features.link_wasm
            mark_exe ld64.lld features.link_macho
            try_version ld.lld --version
            ;;
        lldb)
            mark_exe lldb features.target_create
            mark_exe lldb-server features.lldb_server
            mark_exe lldb-dap features.lldb_dap
            try_version lldb --version
            ;;
        clangd)
            mark_exe clangd features.check_compile_commands
            mark_exe clangd-indexer features.indexer
            try_version clangd --version
            ;;
        clang-format)
            mark_exe clang-format features.format_file
            mark_exe git-clang-format features.git_clang_format
            try_version clang-format --version
            ;;
        clang-tidy)
            mark_exe clang-tidy features.analyze_c
            mark_exe clang-apply-replacements features.apply_replacements
            mark_exe run-clang-tidy features.run_clang_tidy
            mark_exe clang-tidy-diff features.clang_tidy_diff
            try_version clang-tidy --version
            ;;
    esac
}

show_valgrind() {
    echo ""
    echo "[Valgrind capability probes]"
    mark_exe valgrind features.memcheck
    try_version valgrind --version

    valgrind_dir="$(find "$root" \( -type d -path '*/libexec/valgrind' -o -type d -path '*/lib/valgrind' \) -print -quit 2>/dev/null || true)"
    if [ -n "$valgrind_dir" ]; then
        echo ""
        echo "[valgrind internal tool files]"
        find "$valgrind_dir" -maxdepth 1 -type f -printf '%f\n' | sort | grep -E '^(memcheck|cachegrind|callgrind|massif|helgrind|drd|dhat|lackey|exp-)' | sed 's/^/  /' || true
    fi
}

echo ""
echo "============================================================"
echo "cup package capability contract"
echo "============================================================"
echo "package root: $root"
echo "tool: $tool"

show_info_contract
show_bin_summary

case "$tool" in
    gcc) show_gcc ;;
    gdb) show_gdb ;;
    clang|lld|lldb|clangd|clang-format|clang-tidy) show_llvm ;;
    valgrind) show_valgrind ;;
    *) echo "warning: no tool-specific capability inventory for: $tool" ;;
esac

echo "============================================================"
echo "end of capability contract"
echo "============================================================"
echo ""
