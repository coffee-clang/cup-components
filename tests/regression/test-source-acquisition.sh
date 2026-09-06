#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
source "$ROOT/scripts/package/package-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(resolve_version gcc stable)" = "$DEFAULT_GCC_VERSION" ]
[ "$(resolve_version gdb stable)" = "$DEFAULT_GDB_VERSION" ]
[ "$(resolve_version binutils stable)" = "$DEFAULT_BINUTILS_VERSION" ]
[ "$(resolve_version mingw stable)" = "$DEFAULT_GCC_MINGW_VERSION" ]
[ "$(resolve_version llvm stable)" = "$DEFAULT_LLVM_VERSION" ]
[ "$(resolve_version valgrind stable)" = "$DEFAULT_VALGRIND_VERSION" ]
package_revision_is_valid "$DEFAULT_GCC_REVISION"

# Every configured stable source must have one built-in digest. Exact digest
# correctness is an upstream fact and is verified independently when defaults
# are updated; duplicating the same literal here would only test internal
# agreement between two repository files.
for source_spec in \
    "gcc:$DEFAULT_GCC_VERSION" \
    "gdb:$DEFAULT_GDB_VERSION" \
    "binutils:$DEFAULT_BINUTILS_VERSION" \
    "binutils:$DEFAULT_GCC_BINUTILS_VERSION" \
    "mingw:$DEFAULT_GCC_MINGW_VERSION" \
    "llvm:$DEFAULT_LLVM_VERSION" \
    "valgrind:$DEFAULT_VALGRIND_VERSION"; do
    source_id="${source_spec%%:*}"
    version="${source_spec#*:}"
    digest="$(known_source_sha256 "$source_id" "$version")" || {
        echo "configured stable source has no known digest: $source_id $version" >&2
        exit 1
    }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "configured stable source has an invalid SHA-256: $source_id $version" >&2
        exit 1
    }
done

if known_source_sha256 gdb 99.99.99 >/dev/null 2>&1; then
    echo 'unknown explicit versions must not acquire a fake known digest' >&2
    exit 1
fi

CUP_SRC_DIR="$TMP/src"
CUP_BUILD_RECORDS_DIR="$TMP/build-records"
mkdir -p "$CUP_SRC_DIR" "$TMP/root/fixture-99.99.99"
printf 'arbitrary-version\n' > "$TMP/root/fixture-99.99.99/marker"
tar -cJf "$CUP_SRC_DIR/fixture-99.99.99.tar.xz" -C "$TMP/root" fixture-99.99.99
actual="$(sha256_file "$CUP_SRC_DIR/fixture-99.99.99.tar.xz")"

# An explicit version outside the current known set remains buildable without
# modifying repository data. Its actual source digest is still recorded.
source_dir="$(prepare_source_tree fixture 99.99.99 https://example.invalid/fixture-99.99.99.tar.xz fixture-99.99.99.tar.xz)"
[ -f "$source_dir/marker" ]
[ "$(source_archive_sha256 https://example.invalid/fixture-99.99.99.tar.xz fixture-99.99.99.tar.xz)" = "$actual" ]
grep -F $'fixture\t99.99.99\tfixture-99.99.99.tar.xz\t-\t'"$actual"$'\tready-unverified\thttps://example.invalid/fixture-99.99.99.tar.xz' "$CUP_BUILD_RECORDS_DIR/sources.tsv" >/dev/null || {
    echo 'actual source identity for an unlocked explicit source was not recorded' >&2
    exit 1
}

if (prepare_source_tree fixture 99.99.99 https://example.invalid/fixture-99.99.99.tar.xz fixture-99.99.99.tar.xz "$(printf '0%.0s' {1..64})") >/dev/null 2>&1; then
    echo 'operator-supplied source digest mismatch was accepted' >&2
    exit 1
fi
grep -F $'fixture\t99.99.99\tfixture-99.99.99.tar.xz\t'"$(printf '0%.0s' {1..64})"$'\t'"$actual"$'\tsha256-mismatch\thttps://example.invalid/fixture-99.99.99.tar.xz' "$CUP_BUILD_RECORDS_DIR/sources.tsv" >/dev/null || {
    echo 'source digest mismatch was not preserved in build records' >&2
    exit 1
}

# MSYS2's default deepcopy symlink mode can fail on a link-before-target tar
# ordering. Exercise the common retry contract without pretending this Linux
# regression is the native MSYS2 proof.
retry_bin="$TMP/retry-bin"
retry_state="$TMP/retry-state"
retry_dest="$TMP/retry-dest"
real_tar="$(command -v tar)"
mkdir -p "$retry_bin"
cat > "$retry_bin/tar" <<EOF_RETRY_TAR
#!/usr/bin/env sh
count=0
[ ! -f '$retry_state' ] || count=\$(cat '$retry_state')
count=\$((count + 1))
printf '%s\n' "\$count" > '$retry_state'
'$real_tar' "\$@"
status=\$?
[ "\$status" -eq 0 ] || exit "\$status"
[ "\$count" -ne 1 ] || exit 17
exit 0
EOF_RETRY_TAR
chmod 0755 "$retry_bin/tar"
HOST_PLATFORM=windows-x64 PATH="$retry_bin:$PATH" extract_archive \
    "$CUP_SRC_DIR/fixture-99.99.99.tar.xz" "$retry_dest"
[ "$(cat "$retry_state")" = 2 ] || {
    echo 'Windows tar source extraction did not retry exactly once' >&2
    exit 1
}
[ -f "$retry_dest/marker" ] || {
    echo 'Windows tar source extraction retry lost extracted content' >&2
    exit 1
}
rm -f "$retry_state"
if HOST_PLATFORM=linux-x64 PATH="$retry_bin:$PATH" extract_archive \
    "$CUP_SRC_DIR/fixture-99.99.99.tar.xz" "$retry_dest" >/dev/null 2>&1; then
    echo 'non-Windows tar extraction incorrectly retried a failed first pass' >&2
    exit 1
fi
[ "$(cat "$retry_state")" = 1 ] || {
    echo 'non-Windows tar extraction did not remain single-pass' >&2
    exit 1
}

for builder in build-gcc.sh build-gdb.sh build-ld.sh build-llvm-tool.sh build-valgrind.sh; do
    grep -F 'prepare_source_tree' "$ROOT/scripts/build/$builder" >/dev/null || {
        echo "builder does not use common source acquisition: $builder" >&2
        exit 1
    }
done

# GCC bundled-source selection is independent from the selected GCC release.
# The workflow may supply a digest for either bundled source exactly as it does
# for the primary source.
gcc_builder="$ROOT/scripts/build/build-gcc.sh"
grep -F 'BINUTILS_VERSION="$DEFAULT_GCC_BINUTILS_VERSION"' "$gcc_builder" >/dev/null || {
    echo 'GCC builder does not use its own configured default Binutils composition' >&2
    exit 1
}
grep -F 'resolve_version binutils "$REQUESTED_BINUTILS_VERSION"' "$gcc_builder" >/dev/null || {
    echo 'GCC builder does not accept an independent explicit Binutils selection' >&2
    exit 1
}
grep -F '"${CUP_BINUTILS_SOURCE_SHA256:-}"' "$gcc_builder" >/dev/null || {
    echo 'GCC builder does not forward an operator-supplied Binutils digest' >&2
    exit 1
}
grep -F '"${CUP_MINGW_SOURCE_SHA256:-}"' "$gcc_builder" >/dev/null || {
    echo 'GCC builder does not forward an operator-supplied MinGW-w64 digest' >&2
    exit 1
}

echo SOURCE_ACQUISITION=PASS
