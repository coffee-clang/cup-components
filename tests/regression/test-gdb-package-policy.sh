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

echo GDB_PACKAGE_POLICY=PASS
