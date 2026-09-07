#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_GCC="${CUP_TEST_GCC_SCRIPT:-$ROOT/scripts/test/test-gcc.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { in_function=1 }
        in_function { print }
        in_function && $0 == "}" { exit }
    ' "$TEST_GCC"
}

# Exercise the exact production helper bodies, not a parallel reimplementation.
eval "$(extract_function require_package_owned_program)"
eval "$(extract_function require_package_owned_file)"

package_root="$tmp/package root with real spaces"
outside_root="$tmp/outside"
mkdir -p "$package_root/bin" "$package_root/libexec" "$package_root/lib" "$outside_root"
touch "$package_root/libexec/cc1" "$package_root/lib/libgcc.a" "$outside_root/cc1" "$outside_root/libgcc.a"

compiler="$package_root/bin/fake gcc"
cat > "$compiler" <<EOF_COMPILER
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
    -print-prog-name=cc1) printf '%s\\n' '$package_root/libexec/cc1' ;;
    -print-file-name=libgcc.a) printf '%s\\n' '$package_root/lib/libgcc.a' ;;
    *) exit 2 ;;
esac
EOF_COMPILER
chmod 0755 "$compiler"

require_package_owned_program "$package_root" "$compiler" cc1 >/dev/null
require_package_owned_file "$package_root" "$compiler" libgcc.a >/dev/null

cat > "$compiler" <<EOF_COMPILER
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
    -print-prog-name=cc1) printf '%s\\n' '$outside_root/cc1' ;;
    -print-file-name=libgcc.a) printf '%s\\n' '$outside_root/libgcc.a' ;;
    *) exit 2 ;;
esac
EOF_COMPILER
chmod 0755 "$compiler"

if ( require_package_owned_program "$package_root" "$compiler" cc1 ) >/dev/null 2>&1; then
    echo 'outside-package GCC program result was accepted' >&2
    exit 1
fi
if ( require_package_owned_file "$package_root" "$compiler" libgcc.a ) >/dev/null 2>&1; then
    echo 'outside-package GCC file result was accepted' >&2
    exit 1
fi

grep -F -- '--disable-gprofng' "$ROOT/scripts/build/build-gcc.sh" >/dev/null || {
    echo 'GCC bundled Binutils still builds unowned gprofng payload' >&2
    exit 1
}

printf '%s\n' 'GCC_PACKAGE_OWNERSHIP=PASS'
