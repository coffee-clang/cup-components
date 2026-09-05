#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build/build-gdb.sh"
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
grep -F 'copy_path_into_seed lib/libinproctrace.so' "$SCRIPT" >/dev/null

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

echo GDB_PACKAGE_POLICY=PASS
