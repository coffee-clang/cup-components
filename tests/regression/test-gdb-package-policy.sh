#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build/build-gdb.sh"
PRODUCT_TEST="$ROOT/scripts/test/test-gdb.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 ~ "^" name "\\(\\) \\{" { on=1 }
        on { print }
        on && /^}/ { exit }
    ' "$SCRIPT"
}

source "$ROOT/scripts/package/package-common.sh"
eval "$(extract_function relocate_gdb_source_highlight_data)"
eval "$(extract_function gdb_configure_has_option)"
eval "$(extract_function gdb_subconfigure_has_option)"

HOST_PLATFORM=linux-x64
VERSION=99.98.7
GDB_SOURCE_HIGHLIGHT_RELOCATABLE=false
mkdir -p "$TMP/src/gdb"
cat > "$TMP/src/gdb/source-cache.c" <<'EOF_C'
#include "source-cache.h"
void f ()
{
  highlighter = new srchilite::SourceHighlight ("esc.outlang");
}
EOF_C
relocate_gdb_source_highlight_data "$TMP/src"
[ "$GDB_SOURCE_HIGHLIGHT_RELOCATABLE" = true ]
grep -F '#include "defs.h"' "$TMP/src/gdb/source-cache.c" >/dev/null
grep -F 'Settings::setGlobalDataDir' "$TMP/src/gdb/source-cache.c" >/dev/null
grep -F 'gdb_datadir + SLASH_STRING + "source-highlight"' "$TMP/src/gdb/source-cache.c" >/dev/null

# A GDB version without Source Highlight integration remains buildable; the
# optional feature is simply not enabled by the recipe.
printf '#include "source-cache.h"\n' > "$TMP/src/gdb/source-cache.c"
GDB_SOURCE_HIGHLIGHT_RELOCATABLE=true
relocate_gdb_source_highlight_data "$TMP/src"
[ "$GDB_SOURCE_HIGHLIGHT_RELOCATABLE" = false ]

grep -F 'gdb_configure_has_option' "$SCRIPT" >/dev/null
grep -F 'gdb_config_bool HAVE_SOURCE_HIGHLIGHT' "$SCRIPT" >/dev/null
grep -F 'prepare_gdb_package_seed' "$SCRIPT" >/dev/null
if grep -F 'copy_path_into_seed lib/libinproctrace.so' "$SCRIPT" >/dev/null; then
    echo 'GDB package seed still ships unsupported fast-tracepoint in-process agent' >&2
    exit 1
fi
if grep -F 'contents.inproctrace=' "$SCRIPT" >/dev/null; then
    echo 'GDB metadata still advertises unsupported inproctrace payload' >&2
    exit 1
fi

# GDB-owned configure options must be discovered from gdb/configure rather than
# silently dropped because the top-level Binutils/GDB configure does not list them.
mkdir -p "$TMP/config-owner/gdb"
cat > "$TMP/config-owner/configure" <<'EOF_TOP'
#!/usr/bin/env sh
printf '%s\n' '--with-system-zlib --with-zstd'
EOF_TOP
cat > "$TMP/config-owner/gdb/configure" <<'EOF_GDB'
#!/usr/bin/env sh
printf '%s\n' '--with-python-libdir --enable-tui --with-curses --with-expat --with-system-readline --with-lzma'
EOF_GDB
chmod 0755 "$TMP/config-owner/configure" "$TMP/config-owner/gdb/configure"
! gdb_configure_has_option "$TMP/config-owner" --with-python-libdir
gdb_subconfigure_has_option "$TMP/config-owner" --with-python-libdir
gdb_configure_has_option "$TMP/config-owner" --with-system-zlib

grep -F 'configure_args+=(--with-python-libdir="$PREFIX/lib")' "$SCRIPT" >/dev/null || {
    echo 'GDB builder lost relocatable Python libdir configuration' >&2
    exit 1
}
grep -F 'GDB_ZLIB_POLICY=true' "$SCRIPT" >/dev/null || {
    echo 'GDB builder no longer records explicit system-zlib selection' >&2
    exit 1
}
if grep -F 'gdb_config_bool HAVE_ZLIB_H' "$SCRIPT" >/dev/null; then
    echo 'GDB zlib metadata reverted to an unrelated header macro' >&2
    exit 1
fi


if grep -F 'features.gdbserver=' "$SCRIPT" >/dev/null; then
    echo 'GDB still duplicates gdbserver command presence as a behavioral feature' >&2
    exit 1
fi
grep -F 'info_required_entry entry.gdbserver' "$SCRIPT" >/dev/null || {
    echo 'GDB builder lost the public gdbserver entry' >&2
    exit 1
}
grep -F 'features.remote_debugging=$has_gdbserver' "$SCRIPT" >/dev/null || {
    echo 'GDB builder lost remote-debugging behavioral metadata' >&2
    exit 1
}

grep -F 'features.remote_debugging' "$PRODUCT_TEST" >/dev/null || {
    echo 'GDB POSIX product test no longer requires declared remote debugging' >&2
    exit 1
}
grep -F 'target remote 127.0.0.1:$port' "$PRODUCT_TEST" >/dev/null || {
    echo 'GDB POSIX product test no longer exercises packaged gdbserver over loopback' >&2
    exit 1
}

[ "$(grep -F 'PYTHONDONTWRITEBYTECODE=1 "$gdb_bin"' "$SCRIPT" | wc -l)" -eq 2 ] || {
    echo 'GDB Python/TUI metadata probes are not both protected from bytecode-cache regeneration' >&2
    exit 1
}
grep -F 'for python_dir in "$PACKAGE_PREFIX"/lib/python[0-9]*; do' "$SCRIPT" >/dev/null || {
    echo 'GDB package seed lost its bounded final Python-runtime cleanup loop' >&2
    exit 1
}
grep -F 'prune_python_runtime_nonruntime_payload "$python_dir"' "$SCRIPT" >/dev/null || {
    echo 'GDB package seed lost its final Python non-runtime cleanup boundary' >&2
    exit 1
}
seed_line="$(grep -n -F 'prepare_gdb_package_seed' "$SCRIPT" | tail -n 1 | cut -d: -f1)"
python_cleanup_line="$(grep -n -F 'prune_python_runtime_nonruntime_payload "$python_dir"' "$SCRIPT" | tail -n 1 | cut -d: -f1)"
archive_line="$(grep -n -F 'create_packages "$TOOL"' "$SCRIPT" | tail -n 1 | cut -d: -f1)"
[ "$seed_line" -lt "$python_cleanup_line" ] && [ "$python_cleanup_line" -lt "$archive_line" ] || {
    echo 'GDB final Python cleanup is not bounded between package-seed materialization and archive creation' >&2
    exit 1
}

echo GDB_PACKAGE_POLICY=PASS
