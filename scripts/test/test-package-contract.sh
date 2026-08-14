#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
source "$ROOT/scripts/package/package-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CUP_WORK_DIR="$TMP/work"
CUP_OUT_DIR="$TMP/out"
mkdir -p "$CUP_WORK_DIR" "$CUP_OUT_DIR"

# Source acquisition is used through command substitution by every producer
# family. Load-bearing failures must be propagated explicitly rather than
# relying on errexit behavior inside the substitution.
(
    source_test_root="$TMP/source-fetch-failure"
    CUP_SRC_DIR="$source_test_root/src"
    mkdir -p "$CUP_SRC_DIR"
    extract_marker="$source_test_root/extract-reached"
    downstream_marker="$source_test_root/downstream-reached"

    fetch() { return 7; }
    extract_archive() { : > "$extract_marker"; return 8; }

    set +e
    source_path="$(prepare_source_tree fixture 1.0 https://example.invalid/fixture-1.0.tar.xz fixture-1.0.tar.xz)"
    prepare_status=$?
    set -e
    if [ "$prepare_status" -eq 0 ]; then
        : > "$downstream_marker"
    fi

    [ "$prepare_status" -ne 0 ] || { echo 'source preparation accepted a failed fetch' >&2; exit 1; }
    [ ! -e "$extract_marker" ] || { echo 'source extraction ran after a failed fetch' >&2; exit 1; }
    [ -z "$source_path" ] || { echo 'source preparation returned a path after a failed fetch' >&2; exit 1; }
    [ ! -e "$downstream_marker" ] || { echo 'downstream build phase was reached after a failed fetch' >&2; exit 1; }
)
printf 'source fetch-failure propagation test passed\n'

(
    source_test_root="$TMP/source-corrupt-cache"
    CUP_SRC_DIR="$source_test_root/src"
    mkdir -p "$CUP_SRC_DIR"
    archive="$CUP_SRC_DIR/corrupt-1.0.tar.xz"
    downstream_marker="$source_test_root/downstream-reached"
    printf 'not-an-xz-archive' > "$archive"

    set +e
    source_path="$(prepare_source_tree corrupt 1.0 https://example.invalid/corrupt-1.0.tar.xz corrupt-1.0.tar.xz 2>"$source_test_root/extract.log")"
    prepare_status=$?
    set -e
    if [ "$prepare_status" -eq 0 ]; then
        : > "$downstream_marker"
    fi

    [ "$prepare_status" -ne 0 ] || { echo 'source preparation accepted a corrupt cached archive' >&2; exit 1; }
    [ -z "$source_path" ] || { echo 'source preparation returned a path after extraction failure' >&2; exit 1; }
    [ ! -e "$downstream_marker" ] || { echo 'downstream build phase was reached after extraction failure' >&2; exit 1; }
    grep -Eq 'File format not recognized|not a tar archive|Error is not recoverable' "$source_test_root/extract.log" || {
        echo 'corrupt cached archive did not exercise the real extractor failure' >&2
        exit 1
    }
)
printf 'source corrupt-cache propagation test passed\n'

(
    source_test_root="$TMP/source-success"
    CUP_SRC_DIR="$source_test_root/src"
    mkdir -p "$CUP_SRC_DIR" "$source_test_root/archive-root/fixture-1.0"
    printf 'source-ok\n' > "$source_test_root/archive-root/fixture-1.0/marker.txt"
    tar -cJf "$CUP_SRC_DIR/fixture-1.0.tar.xz" -C "$source_test_root/archive-root" fixture-1.0

    source_path="$(prepare_source_tree fixture 1.0 https://example.invalid/fixture-1.0.tar.xz fixture-1.0.tar.xz)"
    [ "$source_path" = "$CUP_SRC_DIR/fixture-1.0" ] || { echo 'successful source preparation returned the wrong path' >&2; exit 1; }
    [ "$(cat "$source_path/marker.txt")" = source-ok ] || { echo 'successful source preparation did not extract expected content' >&2; exit 1; }
)
printf 'source acquisition success-path test passed\n'

prefix="$TMP/prefix"
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/share/data"
printf '#!/bin/sh\nprintf fixture\\n' > "$prefix/bin/gdb"
chmod 0711 "$prefix/bin/gdb"
ln -s gdb "$prefix/bin/gdb-alias"
printf 'payload\n' > "$prefix/lib/libfixture.so.2"
ln -s libfixture.so.2 "$prefix/lib/libfixture.so"
ln -s libfixture.so "$prefix/lib/libfixture-current.so"
mkdir -p "$prefix/lib/aliases"
ln -s ../libfixture.so.2 "$prefix/lib/aliases/libfixture.so"
printf 'hardlinked\n' > "$prefix/share/data/a"
chmod 0600 "$prefix/share/data/a"
ln "$prefix/share/data/a" "$prefix/share/data/b"
chmod 0700 "$prefix/share/data"
cat > "$prefix/info.txt" <<'EOF_INFO'
package.component=debugger
package.tool=gdb
package.version=1.0
package.mode=self-contained
package.formats=tar.xz,tar.gz,zip
platform.host=linux-x64
platform.target=linux-x64
platform.host_triple=x86_64-linux-gnu
platform.target_triple=x86_64-linux-gnu
platform.family=gnu
platform.runtime=glibc
platform.thread_model=posix
build.environment=test
build.source_policy=fixture
source.primary.name=fixture
source.primary.version=1.0
source.primary.url=https://example.invalid/fixture-1.0.tar.xz
entry.gdb=bin/gdb-alias
features.fixture=true
config.fixture=true
EOF_INFO

create_packages gdb 1.0 linux-x64 linux-x64 "" "$prefix"
base=gdb-1.0-linux-x64-linux-x64
package_root="$CUP_WORK_DIR/package-root/$base"

[ -f "$package_root/manifest.txt" ] || { echo 'manifest missing' >&2; exit 1; }
grep -Fx 'format=2' "$package_root/manifest.txt" >/dev/null
if package_info_value "$package_root/info.txt" package.revision >/dev/null 2>&1; then
    echo 'revisionless GDB package retained package.revision metadata' >&2
    exit 1
fi
[ -L "$package_root/bin/gdb-alias" ] || { echo 'entry symlink was not preserved' >&2; exit 1; }
[ "$(readlink "$package_root/bin/gdb-alias")" = gdb ] || { echo 'entry symlink target changed' >&2; exit 1; }
[ -L "$package_root/lib/libfixture.so" ] || { echo 'symlink was not preserved' >&2; exit 1; }
[ -L "$package_root/lib/libfixture-current.so" ] || { echo 'symlink chain was not preserved' >&2; exit 1; }
[ -L "$package_root/lib/aliases/libfixture.so" ] || { echo 'parent-relative symlink was not preserved' >&2; exit 1; }
[ "$(cat "$package_root/lib/libfixture-current.so")" = payload ] || { echo 'preserved symlink chain resolves to wrong bytes' >&2; exit 1; }
[ "$(find "$package_root" -type f -links +1 -print -quit)" = "" ] || {
    echo 'hardlink identity survived package normalization' >&2
    exit 1
}

link_digest="$(package_text_digest 'libfixture.so.2')"
grep -F $'l\t-\t'"$link_digest"$'\tlib/libfixture.so' "$package_root/manifest.txt" >/dev/null
grep -F $'f\t0644\t' "$package_root/manifest.txt" | grep -F $'\tshare/data/a' >/dev/null
grep -F $'f\t0644\t' "$package_root/manifest.txt" | grep -F $'\tshare/data/b' >/dev/null
find "$package_root/bin/gdb" -perm 0755 -print -quit | grep -q . || {
    echo 'executable mode was not normalized to 0755' >&2
    exit 1
}
find "$package_root/share/data/a" -perm 0644 -print -quit | grep -q . || {
    echo 'regular-file mode was not normalized to 0644' >&2
    exit 1
}
find "$package_root/share/data" -perm 0755 -print -quit | grep -q . || {
    echo 'directory mode was not normalized to 0755' >&2
    exit 1
}

tar -tf "$CUP_OUT_DIR/$base.tar.xz" >/dev/null
tar -tf "$CUP_OUT_DIR/$base.tar.gz" >/dev/null
unzip -tqq "$CUP_OUT_DIR/$base.zip"
for archive in "$CUP_OUT_DIR/$base.tar.xz" "$CUP_OUT_DIR/$base.tar.gz"; do
    tar -tvf "$archive" | grep -F 'lib/libfixture.so -> libfixture.so.2' >/dev/null || {
        echo "tar archive did not preserve symbolic link: $archive" >&2
        exit 1
    }
done
zip_extract="$TMP/zip-extract"
mkdir -p "$zip_extract"
unzip -q "$CUP_OUT_DIR/$base.zip" -d "$zip_extract"
[ -L "$zip_extract/$base/lib/libfixture.so" ] || { echo 'zip did not preserve symbolic link' >&2; exit 1; }
[ -L "$zip_extract/$base/lib/libfixture-current.so" ] || { echo 'zip did not preserve symbolic-link chain' >&2; exit 1; }
[ "$(cat "$zip_extract/$base/lib/libfixture-current.so")" = payload ] || { echo 'zip symlink chain resolves to wrong bytes' >&2; exit 1; }

# Every advertised archive format must reconstruct the same logical package graph.
# Recompute manifest v2 after extraction so ZIP cannot pass merely by carrying the
# same manifest.txt while silently changing object kinds, modes, link text or bytes.
parity_xz="$TMP/parity-xz"
parity_gz="$TMP/parity-gz"
parity_zip="$TMP/parity-zip"
mkdir -p "$parity_xz" "$parity_gz" "$parity_zip"
tar -xJf "$CUP_OUT_DIR/$base.tar.xz" -C "$parity_xz"
tar -xzf "$CUP_OUT_DIR/$base.tar.gz" -C "$parity_gz"
unzip -q "$CUP_OUT_DIR/$base.zip" -d "$parity_zip"

for extracted in "$parity_xz/$base" "$parity_gz/$base" "$parity_zip/$base"; do
    package_verify_tree "$extracted" linux-x64
    recomputed="$TMP/$(basename "$(dirname "$extracted")").manifest"
    package_write_manifest "$extracted" linux-x64 "$recomputed"
    cmp -s "$extracted/manifest.txt" "$recomputed" || {
        echo "archive logical graph does not match its manifest: $extracted" >&2
        exit 1
    }
done
cmp -s "$TMP/parity-xz.manifest" "$TMP/parity-gz.manifest" || {
    echo 'tar.xz and tar.gz logical package graphs differ' >&2
    exit 1
}
cmp -s "$TMP/parity-xz.manifest" "$TMP/parity-zip.manifest" || {
    echo 'tar.xz and zip logical package graphs differ' >&2
    exit 1
}

# Unsupported producer objects must fail before publication.
if command -v mkfifo >/dev/null 2>&1; then
    bad_prefix="$TMP/bad-prefix"
    cp -RPp "$prefix" "$bad_prefix"
    rm -f "$bad_prefix/lib/libfixture.so"
    mkfifo "$bad_prefix/lib/not-a-file"
    if (create_packages gdb 1.0 linux-x64 linux-x64 "" "$bad_prefix") >/dev/null 2>&1; then
        echo 'special object was accepted by common package finalization' >&2
        exit 1
    fi
fi

printf 'package archive/object tests passed\n'

# Revision is part of package identity only when the tool deliberately bundles
# independently versioned internal components. GCC currently does; the other
# producer families do not.
gcc_prefix="$TMP/gcc-prefix"
mkdir -p "$gcc_prefix/bin"
printf '#!/bin/sh\nprintf gcc-fixture\n' > "$gcc_prefix/bin/gcc"
chmod 0755 "$gcc_prefix/bin/gcc"
cat > "$gcc_prefix/info.txt" <<'EOF_GCC_INFO'
package.component=compiler
package.tool=gcc
package.version=1.0-rev1
package.revision=1
package.mode=self-contained
package.formats=tar.xz,tar.gz,zip
platform.host=linux-x64
platform.target=linux-x64
platform.host_triple=x86_64-linux-gnu
platform.target_triple=x86_64-linux-gnu
platform.family=gnu
platform.runtime=glibc
platform.thread_model=posix
build.environment=test
build.source_policy=fixture
source.primary.name=gcc
source.primary.version=1.0
source.primary.url=https://example.invalid/gcc-1.0.tar.xz
entry.gcc=bin/gcc
EOF_GCC_INFO
create_packages gcc 1.0 linux-x64 linux-x64 1 "$gcc_prefix"
gcc_base=gcc-1.0-rev1-linux-x64-linux-x64
for format in tar.xz tar.gz zip; do
    [ -f "$CUP_OUT_DIR/$gcc_base.$format" ] || { echo "missing GCC revision-bearing archive: $format" >&2; exit 1; }
done
grep -Fx "release_tag=$gcc_base" "$CUP_OUT_DIR/release.env" >/dev/null
[ "$(package_version_name gcc 1.0 linux-x64 linux-x64 2)" = 1.0-rev2 ] || {
    echo 'future GCC revision was not accepted' >&2
    exit 1
}
printf 'GCC revision-bearing package identity tests passed\n'

# Link admission is deliberately narrow: only POSIX relative internal finite
# symbolic-link chains resolving to regular files may be published.
assert_link_rejected() {
    local name="$1"
    local setup="$2"
    local candidate="$TMP/link-$name"

    cp -RPp "$prefix" "$candidate"
    rm -f "$candidate/lib/libfixture.so"
    eval "$setup"
    if (create_packages gdb 1.0 linux-x64 linux-x64 "" "$candidate") >/dev/null 2>&1; then
        echo "unsafe staging link was accepted: $name" >&2
        exit 1
    fi
}

assert_link_rejected absolute 'ln -s /etc/passwd "$candidate/lib/libfixture.so"'
assert_link_rejected dangling 'ln -s missing.so "$candidate/lib/libfixture.so"'
assert_link_rejected directory 'ln -s ../share "$candidate/lib/libfixture.so"'
assert_link_rejected cycle 'ln -s cycle-b "$candidate/lib/libfixture.so"; ln -s libfixture.so "$candidate/lib/cycle-b"'
assert_link_rejected newline 'ln -s "$(printf "libfixture.so.2\njunk")" "$candidate/lib/libfixture.so"'

# A finite internal chain is admitted by contract regardless of an arbitrary
# implementation hop count. Cycle detection, not a fixed depth cap, provides
# termination for malformed chains.
deep_link_root="$TMP/link-deep-finite"
cp -RPp "$prefix" "$deep_link_root"
for i in $(seq 80 -1 1); do
    if [ "$i" -eq 80 ]; then
        target=libfixture.so.2
    else
        target=deep-$((i + 1))
    fi
    ln -s "$target" "$deep_link_root/lib/deep-$i"
done
[ "$(package_resolve_staging_link "$deep_link_root" lib/deep-1)" = lib/libfixture.so.2 ] || {
    echo 'finite internal symbolic-link chain was rejected by an implementation depth limit' >&2
    exit 1
}
windows_root="$TMP/windows-root"
if (package_normalize_root "$prefix" "$windows_root" windows-x64) >/dev/null 2>&1; then
    echo 'Windows package normalization accepted a symbolic link' >&2
    exit 1
fi

printf 'package link-admission tests passed\n'

# Producer self-validation must reject metadata/path states that CUP cannot consume.
assert_package_rejected() {
    local name="$1"
    local setup="$2"
    local candidate="$TMP/contract-$name"

    cp -RPp "$prefix" "$candidate"
    eval "$setup"
    if (create_packages gdb 1.0 linux-x64 linux-x64 "" "$candidate") >/dev/null 2>&1; then
        echo "producer contract violation was accepted: $name" >&2
        exit 1
    fi
}

assert_package_rejected missing-required 'grep -v "^source.primary.url=" "$candidate/info.txt" > "$candidate/info.txt.tmp"; mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_package_rejected duplicate-field 'printf "package.tool=gdb\\n" >> "$candidate/info.txt"'
assert_package_rejected missing-final-newline 'printf %s "$(cat "$candidate/info.txt")" > "$candidate/info.txt"'
assert_package_rejected case-collision 'printf x > "$candidate/share/Case"; printf y > "$candidate/share/case"'
assert_package_rejected newline-path 'printf x > "$candidate/share/$(printf "bad\\nname")"'

# Newlines must be rejected by the central path grammar itself, before any
# runtime-closure mechanism is allowed to inspect the malformed staging tree.
if package_relative_path_is_safe $'safe\nname'; then
    echo 'package path grammar truncated and accepted an embedded newline' >&2
    exit 1
fi
if package_relative_path_is_safe 'safe/'; then
    echo 'package path grammar accepted a non-canonical trailing slash' >&2
    exit 1
fi
newline_stage="$TMP/staging-newline-preclosure"
cp -RPp "$prefix" "$newline_stage"
printf x > "$newline_stage/share/$(printf 'bad\nname')"
closure_marker="$TMP/newline-runtime-closure-ran"
if (
    prepare_linux_runtime_closure() { : > "$closure_marker"; }
    create_packages gdb 1.0 linux-x64 linux-x64 "" "$newline_stage"
) >/dev/null 2>&1; then
    echo 'newline-bearing staging path was accepted' >&2
    exit 1
fi
[ ! -e "$closure_marker" ] || {
    echo 'runtime closure ran before malformed staging path rejection' >&2
    exit 1
}

printf 'package metadata/path compatibility tests passed\n'
# Version inputs and package revisions form part of package identity and must not
# admit path syntax or arbitrary symbolic aliases. Revisionless families must
# reject a meaningless revision rather than silently creating a new identity.
[ "$(resolve_version gcc stable)" = "$DEFAULT_GCC_VERSION" ]
[ "$(resolve_version gcc 16.1.0)" = "16.1.0" ]
[ "$(package_version_name gcc 16.1.0 linux-x64 linux-x64 1)" = "16.1.0-rev1" ]
[ "$(package_version_name gdb 17.1 linux-x64 linux-x64 "")" = "17.1" ]
[ "$(package_base_name clang 22.1.5 linux-x64 linux-x64 "")" = "clang-22.1.5-linux-x64-linux-x64" ]
[ "$(package_base_name valgrind 3.27.0 linux-x64 linux-x64 "")" = "valgrind-3.27.0-linux-x64-linux-x64" ]
if (resolve_version gcc latest) >/dev/null 2>&1; then
    echo 'latest symbolic alias was accepted' >&2
    exit 1
fi
if (resolve_version gcc '../16.1.0') >/dev/null 2>&1; then
    echo 'non-numeric explicit version was accepted' >&2
    exit 1
fi
if (package_version_name gcc 16.1.0 linux-x64 linux-x64 '../3') >/dev/null 2>&1; then
    echo 'unsafe package revision was accepted' >&2
    exit 1
fi
if (package_version_name gcc 16.1.0 linux-x64 linux-x64 '') >/dev/null 2>&1; then
    echo 'GCC package without a required revision was accepted' >&2
    exit 1
fi
if (package_version_name gdb 17.1 linux-x64 linux-x64 1) >/dev/null 2>&1; then
    echo 'revisionless GDB package accepted a meaningless revision' >&2
    exit 1
fi
printf 'package version/revision input tests passed\n'

# The build scripts are producer authorities too; they must reject unsupported
# identities before creating work directories or attempting source downloads.
assert_build_matrix_rejected() {
    local name="$1"
    shift
    local isolated="$TMP/matrix-$name"

    if CUP_ROOT="$isolated" "$@" >/dev/null 2>&1; then
        echo "unsupported producer matrix was accepted: $name" >&2
        exit 1
    fi
    [ ! -e "$isolated/.cup-build" ] || {
        echo "unsupported producer matrix was rejected too late: $name" >&2
        exit 1
    }
}

assert_build_matrix_rejected gcc-macos \
    "$ROOT/scripts/build/build-gcc.sh" stable macos-x64 macos-x64 3
assert_build_matrix_rejected gcc-unsupported-cross \
    "$ROOT/scripts/build/build-gcc.sh" stable linux-arm64 windows-x64 3
assert_build_matrix_rejected gdb-macos \
    "$ROOT/scripts/build/build-gdb.sh" stable macos-x64 macos-x64
assert_build_matrix_rejected gdb-cross \
    "$ROOT/scripts/build/build-gdb.sh" stable linux-x64 windows-x64
assert_build_matrix_rejected llvm-cross \
    "$ROOT/scripts/build/build-llvm-tool.sh" clang stable linux-x64 windows-x64
printf 'producer platform-matrix tests passed\n'

# Revision-bearing/revisionless producer interfaces and publication semantics
# are repository contracts. These checks are static because live GitHub release
# mutation belongs to CI evidence, not a local source test.
gcc_workflow="$ROOT/.github/workflows/build-gcc.yml"
for workflow in \
    "$ROOT/.github/workflows/build-gdb.yml" \
    "$ROOT/.github/workflows/build-llvm.yml" \
    "$ROOT/.github/workflows/build-valgrind.yml"; do
    if grep -Eq '^[[:space:]]+revision:' "$workflow" || grep -F 'inputs.revision' "$workflow" >/dev/null; then
        echo "revisionless workflow still exposes package revision: $workflow" >&2
        exit 1
    fi
done
grep -Eq '^[[:space:]]+revision:' "$gcc_workflow" || { echo 'GCC workflow lost revision input' >&2; exit 1; }
grep -F "default: '1'" "$gcc_workflow" >/dev/null || { echo 'GCC workflow revision default is not 1' >&2; exit 1; }
grep -F 'GCC package revision must be a positive canonical integer' "$gcc_workflow" >/dev/null || { echo 'GCC workflow does not validate revision' >&2; exit 1; }
[ "$(grep -Fc 'inputs.revision' "$gcc_workflow")" -ge 3 ] || { echo 'GCC workflow does not validate and propagate revision' >&2; exit 1; }

grep -F 'if [ "$#" -ne 3 ]; then' "$ROOT/scripts/build/build-gdb.sh" >/dev/null || { echo 'GDB build CLI still expects revision' >&2; exit 1; }
grep -F 'if [ "$#" -ne 4 ]; then' "$ROOT/scripts/build/build-llvm-tool.sh" >/dev/null || { echo 'LLVM build CLI still expects revision' >&2; exit 1; }
grep -F 'if [ "$#" -ne 2 ]; then' "$ROOT/scripts/build/build-valgrind.sh" >/dev/null || { echo 'Valgrind build CLI still expects revision' >&2; exit 1; }
for builder in build-gdb.sh build-llvm-tool.sh build-valgrind.sh; do
    if grep -F 'package.revision=' "$ROOT/scripts/build/$builder" >/dev/null; then
        echo "revisionless builder still writes package.revision: $builder" >&2
        exit 1
    fi
done
grep -F 'package.revision=$REVISION' "$ROOT/scripts/build/build-gcc.sh" >/dev/null || {
    echo 'GCC builder lost package.revision metadata' >&2
    exit 1
}

publication_extract_script() {
    local workflow="$1"
    local output="$2"

    awk '
        index($0, "tag=\"${{ steps.release.outputs.tag }}\"") { capture = 1 }
        capture {
            line = $0
            sub(/^          /, "", line)
            print line
        }
        capture && index($0, "--notes \"Automated cup component build for $tag\"") { exit }
    ' "$workflow" |
        sed 's|^tag=.*|tag="fixture-tag"|; s|^repo=.*|repo="owner/repo"|' > "$output"
}

publication_run_fixture() {
    local workflow="$1"
    local release_state="$2"
    local tag_state="$3"
    local name="$4"
    local fixture="$TMP/publication-$name"

    rm -rf "$fixture"
    mkdir -p "$fixture/bin"
    publication_extract_script "$workflow" "$fixture/publication.sh"

    cat > "$fixture/bin/gh" <<'EOF_GH_STUB'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$PUBLICATION_CALL_LOG"
if [ "$1" = api ]; then
    case "$PUBLICATION_RELEASE_STATE" in
        FOUND) printf 'HTTP/2.0 200 OK\n\n{}\n'; exit 0 ;;
        NOT_FOUND) printf 'HTTP/2.0 404 Not Found\n\n{}\n'; exit 1 ;;
        ERROR) printf 'HTTP/2.0 503 Service Unavailable\n\n{}\n'; exit 1 ;;
        *) exit 64 ;;
    esac
fi
if [ "$1 $2" = 'release view' ]; then
    case "$PUBLICATION_RELEASE_STATE" in
        FOUND) exit 0 ;;
        NOT_FOUND) exit 1 ;;
        ERROR) exit 4 ;;
        *) exit 64 ;;
    esac
fi
exit 0
EOF_GH_STUB

    cat > "$fixture/bin/git" <<'EOF_GIT_STUB'
#!/bin/sh
printf 'git %s\n' "$*" >> "$PUBLICATION_CALL_LOG"
if [ "$1" = ls-remote ]; then
    case "$PUBLICATION_TAG_STATE" in
        FOUND) exit 0 ;;
        NOT_FOUND) exit 2 ;;
        ERROR) exit 128 ;;
        *) exit 64 ;;
    esac
fi
exit 0
EOF_GIT_STUB
    chmod +x "$fixture/bin/gh" "$fixture/bin/git"
    : > "$fixture/calls"

    set +e
    PATH="$fixture/bin:$PATH" \
        PUBLICATION_CALL_LOG="$fixture/calls" \
        PUBLICATION_RELEASE_STATE="$release_state" \
        PUBLICATION_TAG_STATE="$tag_state" \
        GITHUB_SHA=0123456789abcdef \
        bash -e "$fixture/publication.sh" >"$fixture/stdout" 2>"$fixture/stderr"
    PUBLICATION_FIXTURE_STATUS=$?
    set -e
    PUBLICATION_FIXTURE_CALLS="$fixture/calls"
}

assert_publication_not_called() {
    local pattern="$1"
    if grep -F "$pattern" "$PUBLICATION_FIXTURE_CALLS" >/dev/null; then
        echo "unexpected publication operation reached: $pattern" >&2
        cat "$PUBLICATION_FIXTURE_CALLS" >&2
        exit 1
    fi
}

for workflow in "$ROOT"/.github/workflows/build-*.yml; do
    grep -F 'if: ${{ inputs.publish }}' "$workflow" >/dev/null || { echo "publish=true gate missing: $workflow" >&2; exit 1; }
    grep -F 'if: ${{ !inputs.publish }}' "$workflow" >/dev/null || { echo "publish=false artifact gate missing: $workflow" >&2; exit 1; }
    grep -F 'gh api --include "repos/$repo/releases/tags/$tag"' "$workflow" >/dev/null || { echo "fail-closed release lookup missing: $workflow" >&2; exit 1; }
    grep -F 'if [ "$http_status" != 404 ]; then' "$workflow" >/dev/null || { echo "release lookup does not distinguish 404 from errors: $workflow" >&2; exit 1; }
    grep -F 'git ls-remote --exit-code --tags origin "refs/tags/$tag"' "$workflow" >/dev/null || { echo "remote tag lookup missing: $workflow" >&2; exit 1; }
    grep -F '2) ;;' "$workflow" >/dev/null || { echo "tag not-found status is not distinguished: $workflow" >&2; exit 1; }
    grep -F 'failed to determine remote tag state' "$workflow" >/dev/null || { echo "tag lookup errors are not fail-closed: $workflow" >&2; exit 1; }
    grep -F 'gh release delete "$tag" --repo "$repo" --cleanup-tag --yes' "$workflow" >/dev/null || { echo "same-identity replacement path missing: $workflow" >&2; exit 1; }
    grep -F 'git push origin ":refs/tags/$tag"' "$workflow" >/dev/null || { echo "stale standalone tag replacement path missing: $workflow" >&2; exit 1; }
    grep -F -- '--target "$GITHUB_SHA"' "$workflow" >/dev/null || { echo "release tag is not bound to current source SHA: $workflow" >&2; exit 1; }
    grep -F 'gh release create "$tag" dist/*.tar.xz dist/*.tar.gz dist/*.zip dist/SHA256SUMS' "$workflow" >/dev/null || { echo "publication asset set is incomplete: $workflow" >&2; exit 1; }
    if grep -Eqi 'increment package revision|immutable assets|never replaced' "$workflow"; then
        echo "stale immutable/revision-collision policy remains: $workflow" >&2
        exit 1
    fi

    stem="$(basename "$workflow" .yml)"

    publication_run_fixture "$workflow" FOUND NOT_FOUND "$stem-found"
    [ "$PUBLICATION_FIXTURE_STATUS" -eq 0 ] || { echo "existing release replacement failed: $workflow" >&2; exit 1; }
    grep -F 'gh release delete fixture-tag --repo owner/repo --cleanup-tag --yes' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "existing release was not replaced: $workflow" >&2; exit 1; }
    grep -F 'gh release create fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "replacement release was not recreated: $workflow" >&2; exit 1; }
    assert_publication_not_called 'git ls-remote'

    publication_run_fixture "$workflow" NOT_FOUND FOUND "$stem-stale-tag"
    [ "$PUBLICATION_FIXTURE_STATUS" -eq 0 ] || { echo "stale tag publication failed: $workflow" >&2; exit 1; }
    grep -F 'git push origin :refs/tags/fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "stale standalone tag was not removed: $workflow" >&2; exit 1; }
    grep -F 'gh release create fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "release was not created after stale tag removal: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'

    publication_run_fixture "$workflow" NOT_FOUND NOT_FOUND "$stem-new"
    [ "$PUBLICATION_FIXTURE_STATUS" -eq 0 ] || { echo "new publication path failed: $workflow" >&2; exit 1; }
    grep -F 'gh release create fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "new release was not created: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'
    assert_publication_not_called 'git push'

    publication_run_fixture "$workflow" ERROR FOUND "$stem-release-error"
    [ "$PUBLICATION_FIXTURE_STATUS" -ne 0 ] || { echo "release lookup operational error was accepted: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'
    assert_publication_not_called 'git ls-remote'
    assert_publication_not_called 'git push'
    assert_publication_not_called 'gh release create'

    publication_run_fixture "$workflow" NOT_FOUND ERROR "$stem-tag-error"
    [ "$PUBLICATION_FIXTURE_STATUS" -ne 0 ] || { echo "tag lookup operational error was accepted: $workflow" >&2; exit 1; }
    grep -F 'git ls-remote' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "tag lookup was not exercised: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'
    assert_publication_not_called 'git push'
    assert_publication_not_called 'gh release create'
done
printf 'workflow revision/publication fail-closed contract tests passed\n'

llvm_builder="$ROOT/scripts/build/build-llvm-tool.sh"
llvm_workflow="$ROOT/.github/workflows/build-llvm.yml"
grep -F 'macos-x64) runner="macos-15-intel"' "$llvm_workflow" >/dev/null || { echo 'macOS x64 workflow path is missing' >&2; exit 1; }
grep -F 'macos-arm64) runner="macos-15"' "$llvm_workflow" >/dev/null || { echo 'macOS arm64 workflow path is missing' >&2; exit 1; }
grep -F '"${CUP_MACOS_DEPLOYMENT_TARGET:-15.0}"' "$llvm_builder" >/dev/null || {
    echo 'default macOS deployment target is not 15.0' >&2
    exit 1
}
[ "$(grep -Fc 'CMAKE_OSX_DEPLOYMENT_TARGET="$(macos_deployment_target)"' "$llvm_builder")" -eq 2 ] || {
    echo 'macOS deployment target is not applied to both LLVM build paths' >&2
    exit 1
}
printf 'macOS 15.0 source contract tests passed\n'

# Runtime-closure discovery must be independent of the builder's ambient
# LD_LIBRARY_PATH. A fake ldd records the exact value it receives.
fake_bin="$TMP/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/ldd" <<'EOF_FAKE_LDD'
#!/bin/sh
printf '%s' "$LD_LIBRARY_PATH" > "$LDD_CAPTURE"
printf 'linux-vdso.so.1 (0x0000000000000000)\n'
EOF_FAKE_LDD
chmod +x "$fake_bin/ldd"
ldd_capture="$TMP/ldd-environment"
PATH="$fake_bin:$PATH" \
LDD_CAPTURE="$ldd_capture" \
LD_LIBRARY_PATH=/ambient/builder/path \
LINUX_RUNTIME_SEARCH_PATH=/package/lib:/package/lib64 \
    linux_ldd_dependencies /fixture >/dev/null
[ "$(cat "$ldd_capture")" = '/package/lib:/package/lib64' ] || {
    echo 'Linux runtime discovery inherited ambient LD_LIBRARY_PATH' >&2
    exit 1
}
printf 'Linux runtime-environment isolation test passed\n'

# Runtime closure depth is data-driven, not capped at an arbitrary number of
# transitive levels. A ten-library fixture must converge naturally.
deep_prefix="$TMP/deep-elf-prefix"
deep_external="$TMP/deep-elf-external"
mkdir -p "$deep_prefix/bin" "$deep_external"
printf tool > "$deep_prefix/bin/tool"
for i in $(seq 1 10); do printf 'lib%s' "$i" > "$deep_external/lib$i.so"; done
(
    linux_dynamic_elf_files() { find "$1" -type f | LC_ALL=C sort; }
    linux_ldd_dependencies() {
        local base next
        base="$(basename "$1")"
        if [ "$base" = tool ]; then
            printf 'lib1.so\t%s\n' "$deep_external/lib1.so"
        elif [[ "$base" =~ ^lib([0-9]+)\.so$ ]]; then
            next=$((BASH_REMATCH[1] + 1))
            if [ "$next" -le 10 ]; then
                printf 'lib%s.so\t%s/lib%s.so\n' "$next" "$deep_external" "$next"
            fi
        fi
    }
    linux_copy_resolved_runtime_libraries "$deep_prefix"
)
[ -f "$deep_prefix/lib/lib10.so" ] || {
    echo 'deep Linux runtime closure did not reach the tenth transitive dependency' >&2
    exit 1
}
printf 'Linux runtime-closure convergence-depth test passed\n'

# Binary dependency metadata must never become a path-construction primitive.
# Reject path-bearing ELF/PE dependency names before any copy can escape lib/bin.
unsafe_elf_prefix="$TMP/unsafe-elf-prefix"
mkdir -p "$unsafe_elf_prefix/bin"
printf fixture > "$unsafe_elf_prefix/bin/tool"
if (
    linux_dynamic_elf_files() { printf '%s\n' "$unsafe_elf_prefix/bin/tool"; }
    linux_ldd_dependencies() { printf '../../escape.so\t/tmp/escape.so\n'; }
    linux_copy_resolved_runtime_libraries "$unsafe_elf_prefix"
) >/dev/null 2>&1; then
    echo 'Linux runtime closure accepted a path-bearing dependency name' >&2
    exit 1
fi

unsafe_pe_prefix="$TMP/unsafe-pe-prefix"
mkdir -p "$unsafe_pe_prefix/bin"
printf fixture > "$unsafe_pe_prefix/bin/tool.exe"
if (
    HOST_PLATFORM=windows-x64
    PREFIX="$unsafe_pe_prefix"
    windows_pe_import_tool() { printf '%s\n' fixture-objdump; }
    windows_pe_import_dll_names() { printf '%s\n' '../../escape.dll'; }
    copy_windows_runtime_dlls "$unsafe_pe_prefix/bin"
) >/dev/null 2>&1; then
    echo 'Windows runtime closure accepted a path-bearing DLL import name' >&2
    exit 1
fi
[ ! -e "$TMP/escape.dll" ] || { echo 'unsafe PE import escaped package bin directory' >&2; exit 1; }
printf 'runtime dependency-name path-safety tests passed\n'

# @rpath alone is not a proof of relocatability. The macOS closure canonicalizes
# package-owned @rpath edges to a deterministic @loader_path reference.
mac_prefix="$TMP/mac-prefix"
mkdir -p "$mac_prefix/bin" "$mac_prefix/lib"
printf x > "$mac_prefix/bin/tool"
printf y > "$mac_prefix/lib/libfixture.dylib"
mac_changes="$TMP/mac-install-name-changes"
: > "$mac_changes"
(
    macos_macho_files() { printf '%s\n' "$mac_prefix/bin/tool"; }
    macos_macho_dependencies() { printf '%s\n' '@rpath/libfixture.dylib'; }
    install_name_tool() { printf '%s\n' "$*" >> "$mac_changes"; }
    macos_copy_and_rewrite_runtime_libraries "$mac_prefix"
)
grep -Fx -- "-change @rpath/libfixture.dylib @loader_path/../lib/libfixture.dylib $mac_prefix/bin/tool" \
    "$mac_changes" >/dev/null || {
    echo 'macOS @rpath dependency was not canonicalized to package-relative @loader_path' >&2
    exit 1
}
if (
    bad_mac_prefix="$TMP/mac-prefix-missing"
    mkdir -p "$bad_mac_prefix/bin" "$bad_mac_prefix/lib"
    printf x > "$bad_mac_prefix/bin/tool"
    macos_macho_files() { printf '%s\n' "$bad_mac_prefix/bin/tool"; }
    macos_macho_dependencies() { printf '%s\n' '@rpath/libmissing.dylib'; }
    install_name_tool() { :; }
    macos_copy_and_rewrite_runtime_libraries "$bad_mac_prefix"
) >/dev/null 2>&1; then
    echo 'macOS closure accepted an unresolved package-owned @rpath dependency' >&2
    exit 1
fi
if (
    bad_mac_prefix="$TMP/mac-prefix-unsafe"
    mkdir -p "$bad_mac_prefix/bin" "$bad_mac_prefix/lib"
    printf x > "$bad_mac_prefix/bin/tool"
    macos_macho_files() { printf '%s\n' "$bad_mac_prefix/bin/tool"; }
    macos_macho_dependencies() { printf '%s\n' '@rpath/../../outside.dylib'; }
    install_name_tool() { :; }
    macos_copy_and_rewrite_runtime_libraries "$bad_mac_prefix"
) >/dev/null 2>&1; then
    echo 'macOS closure accepted an unsafe package-owned @rpath dependency' >&2
    exit 1
fi
printf 'macOS @rpath closure-mechanism tests passed\n'

# codesign is a required part of macOS closure whenever Mach-O objects are
# present. Its absence must fail closed rather than silently skipping signing.
mac_codesign_path="$TMP/mac-codesign-path"
mkdir -p "$mac_codesign_path"
ln -s "$(command -v file)" "$mac_codesign_path/file"
ln -s "$(command -v grep)" "$mac_codesign_path/grep"
for tool in otool install_name_tool; do
    printf '#!/bin/sh\nexit 0\n' > "$mac_codesign_path/$tool"
    chmod +x "$mac_codesign_path/$tool"
done
mac_codesign_log="$TMP/mac-codesign-missing.log"
if (
    PATH="$mac_codesign_path"
    macos_macho_files() { printf '%s\n' "$TMP/fake-mach-o"; }
    prepare_macos_runtime_closure "$TMP/mac-codesign-prefix" macos-x64
) >"$mac_codesign_log" 2>&1; then
    echo 'macOS runtime closure accepted Mach-O input without codesign' >&2
    exit 1
fi
grep -F 'required command not found: codesign' "$mac_codesign_log" >/dev/null || {
    echo 'macOS runtime closure did not report missing codesign prerequisite' >&2
    exit 1
}
if ! (
    PATH="$mac_codesign_path"
    macos_macho_files() { :; }
    prepare_macos_runtime_closure "$TMP/mac-no-macho-prefix" macos-x64
) >/dev/null 2>&1; then
    echo 'macOS runtime closure required codesign without any Mach-O input' >&2
    exit 1
fi
printf 'macOS codesign prerequisite mechanism test passed\n'

# Presence predicates must consume the complete enumerator output under pipefail.
# This deliberately emits far more than a pipe buffer so an early-exiting consumer
# would SIGPIPE the producer and could misclassify a non-empty object set as empty.
emit_many_runtime_objects() {
    local i
    for ((i = 0; i < 32768; i++)); do
        printf '/synthetic/%080d/object\n' "$i"
    done
}

linux_presence_marker="$TMP/linux-presence-marker"
rm -f "$linux_presence_marker"
(
    linux_dynamic_elf_files() { emit_many_runtime_objects; }
    readelf() { :; }
    ldd() { :; }
    realpath() { :; }
    linux_copy_resolved_runtime_libraries() { : > "$linux_presence_marker"; }
    linux_patch_runtime_search_paths() { :; }
    verify_linux_runtime_libraries() { :; }
    prepare_linux_runtime_closure "$TMP/linux-many-objects" linux-x64
)
[ -e "$linux_presence_marker" ] || {
    echo 'Linux runtime closure misclassified many dynamic ELF objects as empty' >&2
    exit 1
}
rm -f "$linux_presence_marker"
(
    linux_dynamic_elf_files() { :; }
    readelf() { :; }
    ldd() { :; }
    realpath() { :; }
    linux_copy_resolved_runtime_libraries() { : > "$linux_presence_marker"; }
    prepare_linux_runtime_closure "$TMP/linux-zero-objects" linux-x64
)
[ ! -e "$linux_presence_marker" ] || {
    echo 'Linux runtime closure did not preserve the zero-object fast path' >&2
    exit 1
}

mac_pipefail_log="$TMP/mac-pipefail-presence.log"
if (
    PATH="$mac_codesign_path"
    macos_macho_files() { emit_many_runtime_objects; }
    prepare_macos_runtime_closure "$TMP/mac-many-objects" macos-x64
) >"$mac_pipefail_log" 2>&1; then
    echo 'macOS runtime closure misclassified many Mach-O objects as empty' >&2
    exit 1
fi
grep -F 'required command not found: codesign' "$mac_pipefail_log" >/dev/null || {
    echo 'macOS runtime closure did not reach the codesign prerequisite with many Mach-O objects' >&2
    exit 1
}
printf 'runtime-closure pipefail presence tests passed\n'

# macOS closure uses the same natural fixed-point rule: dependency depth must
# not be limited by an arbitrary pass count.
deep_mac_prefix="$TMP/deep-mac-prefix"
deep_mac_external="$TMP/deep-mac-external"
mkdir -p "$deep_mac_prefix/bin" "$deep_mac_external"
printf tool > "$deep_mac_prefix/bin/tool"
for i in $(seq 1 10); do printf 'dylib%s' "$i" > "$deep_mac_external/lib$i.dylib"; done
(
    macos_macho_files() { find "$1" -type f | LC_ALL=C sort; }
    macos_macho_dependencies() {
        local base next
        base="$(basename "$1")"
        if [ "$base" = tool ]; then
            printf '%s\n' "$deep_mac_external/lib1.dylib"
        elif [[ "$base" =~ ^lib([0-9]+)\.dylib$ ]]; then
            next=$((BASH_REMATCH[1] + 1))
            if [ "$next" -le 10 ]; then
                printf '%s/lib%s.dylib\n' "$deep_mac_external" "$next"
            fi
        fi
    }
    otool() { :; }
    install_name_tool() { :; }
    macos_copy_and_rewrite_runtime_libraries "$deep_mac_prefix"
)
[ -f "$deep_mac_prefix/lib/lib10.dylib" ] || {
    echo 'deep macOS runtime closure did not reach the tenth transitive dependency' >&2
    exit 1
}
printf 'macOS runtime-closure convergence-depth test passed\n'
