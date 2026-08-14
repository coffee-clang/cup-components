#!/usr/bin/env bash
# Qualify real cup-components common finalization against CUP's production package validator.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
: "${CUP_PACKAGE_VALIDATOR:?set CUP_PACKAGE_VALIDATOR to CUP package-validator helper}"
[ -x "$CUP_PACKAGE_VALIDATOR" ] || {
    printf 'CUP package validator is not executable: %s\n' "$CUP_PACKAGE_VALIDATOR" >&2
    exit 2
}

WORK="${CUP_CONTRACT_TEST_WORK:-$(mktemp -d)}"
KEEP_WORK="${CUP_CONTRACT_TEST_KEEP_WORK:-0}"
cleanup() {
    if [ "$KEEP_WORK" != 1 ]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT HUP INT TERM

export CUP_ROOT="$ROOT"
export CUP_WORK_DIR="$WORK/work"
export CUP_SRC_DIR="$CUP_WORK_DIR/src"
export CUP_BUILD_DIR="$CUP_WORK_DIR/build"
export CUP_STAGE_DIR="$CUP_WORK_DIR/stage"
export CUP_OUT_DIR="$WORK/out"
. "$ROOT/scripts/package/package-common.sh"
make_dirs

prefix="$WORK/prefix"
mkdir -p "$prefix/bin" "$prefix/share"
printf '#!/bin/sh\nprintf "gdb contract fixture\\n"\n' > "$prefix/bin/gdb"
chmod 0755 "$prefix/bin/gdb"
ln -s gdb "$prefix/bin/gdb-alias"
printf 'owned payload\n' > "$prefix/share/data.txt"

write_info_file "$prefix" \
    'package.component=debugger' \
    'package.tool=gdb' \
    'package.version=99.1' \
    'package.mode=self-contained' \
    'package.formats=tar.xz,tar.gz,zip' \
    'platform.host=linux-x64' \
    'platform.target=linux-x64' \
    'platform.host_triple=x86_64-linux-gnu' \
    'platform.target_triple=x86_64-linux-gnu' \
    'platform.family=gnu' \
    'platform.runtime=glibc' \
    'platform.thread_model=posix' \
    'build.environment=contract-test' \
    'build.source_policy=contract-test' \
    'source.primary.name=gdb' \
    'source.primary.version=99.1' \
    'source.primary.url=https://example.invalid/gdb-99.1.tar.xz' \
    'entry.gdb=bin/gdb-alias' \
    'features.debug_native=true'

create_packages gdb 99.1 linux-x64 linux-x64 "" "$prefix"
package_base='gdb-99.1-linux-x64-linux-x64'
archive="$CUP_OUT_DIR/$package_base.tar.gz"
extract_root="$WORK/extracted"
mkdir -p "$extract_root"
tar -xzf "$archive" -C "$extract_root"
package_root="$extract_root/$package_base"

validate() {
    local root=$1
    local version=${2:-99.1}
    "$CUP_PACKAGE_VALIDATOR" "$root" debugger gdb linux-x64 linux-x64 "$version"
}
expect_reject() {
    local root=$1
    local version=${2:-99.1}
    if validate "$root" "$version" >/dev/null 2>&1; then
        printf 'Expected CUP to reject producer package: %s\n' "$root" >&2
        exit 1
    fi
}

case "${CUP_CONTRACT_MODE:-reject}" in
    reject)
        # The current CUP consumer still implements the previous package
        # contract, so it must reject this manifest-v2/symlink producer fixture.
        expect_reject "$package_root"
        printf 'current CUP consumer rejection of revisionless manifest-v2/symlink package confirmed\n'
        exit 0
        ;;
    accept)
        # This mode qualifies a CUP consumer that implements the current
        # producer object model; the valid fixture must pass before mutations run.
        validate "$package_root"
        ;;
    *)
        printf 'CUP_CONTRACT_MODE must be reject or accept\n' >&2
        exit 2
        ;;
esac

mutation="$WORK/missing-manifest"
cp -RPp "$package_root" "$mutation"
rm "$mutation/manifest.txt"
expect_reject "$mutation"

mutation="$WORK/extra-file"
cp -RPp "$package_root" "$mutation"
printf 'unowned\n' > "$mutation/unowned.txt"
expect_reject "$mutation"

mutation="$WORK/modified-file"
cp -RPp "$package_root" "$mutation"
printf 'modified\n' >> "$mutation/bin/gdb"
expect_reject "$mutation"

mutation="$WORK/object-type"
cp -RPp "$package_root" "$mutation"
rm "$mutation/share/data.txt"
mkdir "$mutation/share/data.txt"
expect_reject "$mutation"

mutation="$WORK/unsafe-symlink-object"
cp -RPp "$package_root" "$mutation"
ln -s /etc/passwd "$mutation/unsafe-alias"
expect_reject "$mutation"

printf 'cross-repository package contract passed\n'
