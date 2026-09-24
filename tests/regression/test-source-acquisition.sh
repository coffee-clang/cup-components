#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
source "$ROOT/scripts/package/package-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(resolve_version gcc default)" = "$DEFAULT_GCC_VERSION" ]
[ "$(resolve_version gdb default)" = "$DEFAULT_GDB_VERSION" ]
[ "$(resolve_version binutils default)" = "$DEFAULT_BINUTILS_VERSION" ]
[ "$(resolve_version mingw default)" = "$DEFAULT_GCC_MINGW_VERSION" ]
[ "$(resolve_version llvm default)" = "$DEFAULT_LLVM_VERSION" ]
[ "$(resolve_version valgrind default)" = "$DEFAULT_VALGRIND_VERSION" ]

# Every configured default source must resolve to a pinned digest.
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
        echo "configured default source has no known digest: $source_id $version" >&2
        exit 1
    }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "configured default source has an invalid SHA-256: $source_id $version" >&2
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

# Unpinned explicit versions remain buildable and record their actual digest.
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

# Build scripts capture prepare_source_tree through command substitution. A fetch
# failure must therefore propagate explicitly and must not reach extraction.
(
    fail_root="$TMP/prepare-fetch-failure"
    CUP_SRC_DIR="$fail_root/src"
    mkdir -p "$CUP_SRC_DIR"
    extract_marker="$fail_root/extract-reached"
    fetch() { return 7; }
    extract_archive() { : > "$extract_marker"; return 8; }

    set +e
    source_path="$(prepare_source_tree fixture 1.0 https://example.invalid/fixture-1.0.tar.xz fixture-1.0.tar.xz)"
    status=$?
    set -e
    [ "$status" -ne 0 ] || { echo 'source preparation accepted a failed fetch' >&2; exit 1; }
    [ -z "$source_path" ] || { echo 'failed source preparation returned a path' >&2; exit 1; }
    [ ! -e "$extract_marker" ] || { echo 'source extraction ran after a failed fetch' >&2; exit 1; }
)

# A cached archive with the expected digest is still rejected when its archive
# structure is invalid; cache presence is not source-preparation success.
(
    corrupt_root="$TMP/prepare-corrupt-cache"
    CUP_SRC_DIR="$corrupt_root/src"
    mkdir -p "$CUP_SRC_DIR"
    archive="$CUP_SRC_DIR/corrupt-1.0.tar.xz"
    printf 'not-an-xz-archive' > "$archive"
    set +e
    source_path="$(prepare_source_tree corrupt 1.0 https://example.invalid/corrupt-1.0.tar.xz corrupt-1.0.tar.xz "$(sha256_file "$archive")" 2>"$corrupt_root/extract.log")"
    status=$?
    set -e
    [ "$status" -ne 0 ] || { echo 'source preparation accepted a corrupt cached archive' >&2; exit 1; }
    [ -z "$source_path" ] || { echo 'corrupt source preparation returned a path' >&2; exit 1; }
)

# Transfer failures use bounded curl retry and never leave a partial archive.
fetch_bin="$TMP/fetch-bin"
fetch_args="$TMP/fetch-args"
fetch_output="$TMP/fetch-output"
mkdir -p "$fetch_bin"
cat > "$fetch_bin/curl" <<EOF_FETCH_CURL
#!/usr/bin/env sh
printf '%s\n' "\$@" > '$fetch_args'
out=''
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = -o ]; then
        shift
        out="\$1"
        break
    fi
    shift
done
[ -n "\$out" ] || exit 97
printf 'downloaded\n' > "\$out"
EOF_FETCH_CURL
chmod 0755 "$fetch_bin/curl"
PATH="$fetch_bin:$PATH" fetch https://example.invalid/retry-source.tar.xz "$fetch_output"
[ -f "$fetch_output" ] || {
    echo 'source fetch stub did not create the requested output' >&2
    exit 1
}
grep -Fx -- '--retry-all-errors' "$fetch_args" >/dev/null || {
    echo 'source fetch does not retry transfer errors beyond curl default transient classes' >&2
    exit 1
}
grep -Fx -- '--retry' "$fetch_args" >/dev/null || {
    echo 'source fetch lost its bounded retry count' >&2
    exit 1
}

cat > "$fetch_bin/curl" <<EOF_FETCH_FAIL
#!/usr/bin/env sh
out=''
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = -o ]; then
        shift
        out="\$1"
        break
    fi
    shift
done
[ -z "\$out" ] || printf 'partial\n' > "\$out"
exit 56
EOF_FETCH_FAIL
chmod 0755 "$fetch_bin/curl"
rm -f "$fetch_output"
if PATH="$fetch_bin:$PATH" fetch https://example.invalid/failing-source.tar.xz "$fetch_output"; then
    echo 'failed source fetch was accepted' >&2
    exit 1
fi
[ ! -e "$fetch_output" ] || {
    echo 'failed source fetch left a partial archive behind' >&2
    exit 1
}

# MSYS2 deepcopy extraction can fail when a link precedes its target. The
# Windows path retries once; other hosts remain single-pass.
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


echo SOURCE_ACQUISITION=PASS
