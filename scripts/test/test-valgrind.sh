#!/usr/bin/env bash
set -euo pipefail

PUBLIC_CLIENT_HEADERS=(
    valgrind.h
    cachegrind.h
    callgrind.h
    dhat.h
    drd.h
    helgrind.h
    memcheck.h
)

decode_pkgconfig_single_path() {
    local raw="$1"
    local -a decoded=()

    mapfile -t decoded < <(printf '%s\n' "$raw" | xargs -r -n1 printf '%s\n')
    if [ "${#decoded[@]}" -ne 1 ]; then
        echo "pkg-config path did not decode to exactly one path: $raw" >&2
        return 1
    fi
    printf '%s\n' "${decoded[0]}"
}

require_path_within_root() {
    local root="$1"
    local candidate="$2"
    local label="$3"
    local root_real candidate_real

    root_real="$(realpath -e -- "$root")"
    candidate_real="$(realpath -e -- "$candidate")"

    case "$candidate_real" in
        "$root_real"|"$root_real"/*) ;;
        *)
            echo "$label resolves outside package root: $candidate_real" >&2
            return 1
            ;;
    esac
}

verify_public_client_api() {
    local api_root="$1"
    local mode="${2:-primary}"
    local pc_dir="$api_root/lib/pkgconfig"
    local pc_file="$pc_dir/valgrind.pc"
    local api_tmp api_cflags raw_prefix raw_includedir raw_pcfiledir
    local prefix includedir pcfiledir header witness response

    for tool in pkg-config gcc realpath xargs; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "$tool is required for Valgrind public-client API validation" >&2
            return 1
        }
    done

    [ -f "$pc_file" ] || {
        echo "missing deliberate Valgrind client pkg-config metadata: $pc_file" >&2
        return 1
    }

    for header in "${PUBLIC_CLIENT_HEADERS[@]}"; do
        [ -f "$api_root/include/valgrind/$header" ] || {
            echo "missing deliberate Valgrind client header: $header" >&2
            return 1
        }
    done

    grep -Fx 'prefix=${pcfiledir}/../..' "$pc_file" >/dev/null || {
        echo "Valgrind pkg-config prefix is not package-relative" >&2
        return 1
    }
    if grep -E '(^|[[:space:]])prefix=/|/\.cup-build/|/tmp/' "$pc_file" >/dev/null; then
        echo "Valgrind pkg-config metadata contains an absolute/stale prefix" >&2
        return 1
    fi

    raw_pcfiledir="$(PKG_CONFIG_PATH="$pc_dir" PKG_CONFIG_LIBDIR="$pc_dir" pkg-config --variable=pcfiledir valgrind)"
    raw_prefix="$(PKG_CONFIG_PATH="$pc_dir" PKG_CONFIG_LIBDIR="$pc_dir" pkg-config --variable=prefix valgrind)"
    raw_includedir="$(PKG_CONFIG_PATH="$pc_dir" PKG_CONFIG_LIBDIR="$pc_dir" pkg-config --variable=includedir valgrind)"
    api_cflags="$(PKG_CONFIG_PATH="$pc_dir" PKG_CONFIG_LIBDIR="$pc_dir" pkg-config --cflags valgrind)"

    pcfiledir="$(decode_pkgconfig_single_path "$raw_pcfiledir")"
    prefix="$(decode_pkgconfig_single_path "$raw_prefix")"
    includedir="$(decode_pkgconfig_single_path "$raw_includedir")"

    [ "$(realpath -e -- "$pcfiledir")" = "$(realpath -e -- "$pc_dir")" ] || {
        echo "pkg-config resolved valgrind.pc outside the package: $pcfiledir" >&2
        return 1
    }
    [ "$(realpath -e -- "$prefix")" = "$(realpath -e -- "$api_root")" ] || {
        echo "pkg-config prefix does not resolve to package root: $prefix" >&2
        return 1
    }
    [ "$(realpath -e -- "$includedir")" = "$(realpath -e -- "$api_root/include")" ] || {
        echo "pkg-config includedir does not resolve to package include root: $includedir" >&2
        return 1
    }
    require_path_within_root "$api_root" "$includedir" "pkg-config includedir"

    grep -Fx 'Cflags: -I${includedir}' "$pc_file" >/dev/null || {
        echo "Valgrind pkg-config Cflags are not the expected package-owned include contract" >&2
        return 1
    }
    [ -n "$api_cflags" ] || {
        echo "Valgrind pkg-config returned empty Cflags" >&2
        return 1
    }

    api_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cup-valgrind-public-api.XXXXXX")"
    response="$api_tmp/valgrind-cflags.rsp"
    printf '%s\n' "$api_cflags" >"$response"

    for header in "${PUBLIC_CLIENT_HEADERS[@]}"; do
        cat >"$api_tmp/header-${header%.h}.c" <<C_EOF
#include <valgrind/$header>
int cup_valgrind_header_${header//[-.]/_}(void) { return 0; }
C_EOF
        gcc @"$response" -std=c11 -c "$api_tmp/header-${header%.h}.c" \
            -o "$api_tmp/header-${header%.h}.o" || {
            echo "Valgrind public client header does not compile: $header" >&2
            rm -rf "$api_tmp"
            return 1
        }
    done

    witness="$api_tmp/client-request-witness.c"
    cat >"$witness" <<'C_EOF'
#include <stddef.h>
#include <valgrind/valgrind.h>
#include <valgrind/memcheck.h>

int cup_valgrind_client_request_witness(int *value) {
    unsigned int running = RUNNING_ON_VALGRIND;
    VALGRIND_MAKE_MEM_DEFINED(value, sizeof(*value));
    return running ? *value : 0;
}
C_EOF
    gcc @"$response" -std=c11 -c "$witness" -o "$api_tmp/client-request-witness.o" || {
        echo "Valgrind representative client-request witness does not compile" >&2
        rm -rf "$api_tmp"
        return 1
    }

    rm -rf "$api_tmp"

    if [ "$mode" = "relocated" ]; then
        printf '%s\n' \
            'RELOCATED_PKGCONFIG_PREFIX=PASS' \
            'RELOCATED_PUBLIC_CLIENT_HEADERS_COMPILE=PASS'
    else
        printf '%s\n' \
            'PUBLIC_CLIENT_HEADERS_PRESENT=PASS' \
            'PACKAGE_OWNED_PKGCONFIG_CFLAGS=PASS' \
            'PUBLIC_CLIENT_HEADERS_COMPILE=PASS'
    fi
}

if [ -n "${CUP_VALGRIND_PUBLIC_API_TEST_ROOT:-}" ]; then
    verify_public_client_api \
        "$CUP_VALGRIND_PUBLIC_API_TEST_ROOT" \
        "${CUP_VALGRIND_PUBLIC_API_TEST_MODE:-primary}"
    exit 0
fi

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"

bash scripts/test/package-capabilities.sh "$root" valgrind
tmpdir="$(mktemp -d /tmp/cup-valgrind-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

info_value() {
    local key="$1"
    local info_file="$root/info.txt"

    if [ ! -f "$info_file" ]; then
        printf '\n'
        return 0
    fi

    awk -F= -v key="$key" '$1 == key { print $2; found=1 } END { if (!found) print "" }' "$info_file"
}

feature_enabled() {
    local key="$1"
    [ "$(info_value "$key")" = "true" ]
}

require_executable() {
    local path="$1"

    if [ ! -x "$path" ]; then
        echo "missing executable: $path" >&2
        exit 1
    fi
}

require_executable "$root/bin/valgrind"
"$root/bin/valgrind" --version
if feature_enabled "contents.vgdb"; then
    require_executable "$root/bin/vgdb"
    "$root/bin/vgdb" --help >"$tmpdir/vgdb-help.txt" 2>&1
    if grep -F '/.cup-build/' "$tmpdir/vgdb-help.txt" >/dev/null; then
        echo "vgdb help retains an absolute build/staging prefix" >&2
        cat "$tmpdir/vgdb-help.txt" >&2
        exit 1
    fi
fi
"$root/bin/valgrind" --tool=memcheck --help >"$tmpdir/valgrind-help.txt"
grep -A3 "available tools are:" "$tmpdir/valgrind-help.txt"

if [ "$(info_value contents.mpi)" != "false" ]; then
    echo "core Valgrind package does not declare MPI payload exclusion" >&2
    exit 1
fi
if find "$root" -type f -name "libmpiwrap-*" -print -quit | grep -q .; then
    echo "core Valgrind package unexpectedly contains an MPI wrapper" >&2
    exit 1
fi

if [ "$(info_value config.gdbscripts_disabled)" != "true" ]; then
    echo "relocatable core Valgrind package does not declare GDB Python front-end exclusion" >&2
    exit 1
fi
if find "$root" -type f -name 'valgrind-monitor.py' -print -quit | grep -q .; then
    echo "relocatable core Valgrind package unexpectedly contains valgrind-monitor.py" >&2
    exit 1
fi

# Client-request headers are deliberate public API.  The separate SDK for
# developing new Valgrind tools is not part of the CUP package contract.
verify_public_client_api "$root" primary

for forbidden_header in \
    "$root/include/valgrind/config.h" \
    "$root/include/valgrind/vki"; do
    if [ -e "$forbidden_header" ]; then
        echo "Valgrind tool-development SDK leaked into core package: $forbidden_header" >&2
        exit 1
    fi
done
if find "$root/include/valgrind" -maxdepth 1 -type f \
    \( -name 'libvex*.h' -o -name 'pub_tool_*.h' \) -print -quit | grep -q .; then
    echo "Valgrind tool-development headers leaked into core package" >&2
    exit 1
fi
if find "$root" -type f \
    \( -name 'libcoregrind-*.a' \
    -o -name 'libgcc-sup-*.a' \
    -o -name 'libreplacemalloc_toolpreload-*.a' \
    -o -name 'libvex-*.a' \
    -o -name 'libvexmultiarch-*.a' \) -print -quit | grep -q .; then
    echo "Valgrind tool-development static archives leaked into core package" >&2
    exit 1
fi

cat > "$tmpdir/valgrind-leak.c" <<'C_EOF'
#include <stdlib.h>

int main(void) {
    int *p = malloc(sizeof(int));
    *p = 42;
    return 0;
}
C_EOF

gcc -g -O0 "$tmpdir/valgrind-leak.c" -o "$tmpdir/valgrind-leak"
"$root/bin/valgrind" --leak-check=full "$tmpdir/valgrind-leak" 2>&1 | tee "$tmpdir/valgrind-output.txt"
grep "definitely lost: 4 bytes in 1 blocks" "$tmpdir/valgrind-output.txt"

# The Valgrind package uses a relocatable wrapper, so moving the extracted tree is
# part of the package contract and should be tested explicitly.
reloc_root="$tmpdir/valgrind-reloc"
cp -RPp "$root" "$reloc_root"
verify_public_client_api "$reloc_root" relocated
"$reloc_root/bin/valgrind" --leak-check=full "$tmpdir/valgrind-leak" 2>&1 | tee "$tmpdir/valgrind-reloc-output.txt"
grep "definitely lost: 4 bytes in 1 blocks" "$tmpdir/valgrind-reloc-output.txt"

reloc_space_root="$tmpdir/valgrind reloc with real spaces"
cp -RPp "$root" "$reloc_space_root"
"$reloc_space_root/bin/valgrind" --leak-check=full "$tmpdir/valgrind-leak" 2>&1 | tee "$tmpdir/valgrind-reloc-spaces-output.txt"
grep "definitely lost: 4 bytes in 1 blocks" "$tmpdir/valgrind-reloc-spaces-output.txt"
printf 'REAL_SPACES_RUNTIME_RELOCATION=PASS\n'
