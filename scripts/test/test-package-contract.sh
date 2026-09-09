#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
source "$ROOT/scripts/package/package-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CUP_WORK_DIR="$TMP/work"
CUP_OUT_DIR="$TMP/out"
mkdir -p "$CUP_WORK_DIR" "$CUP_OUT_DIR"

# Generic package graph/metadata fixtures are intentionally platform-neutral.
# Runtime closure has dedicated mechanism tests below and must not make these
# generic fixtures depend on tooling for a declared, non-native host platform.
create_packages_without_runtime_closure() {
    (
        prepare_linux_runtime_closure() { :; }
        prepare_macos_runtime_closure() { :; }
        create_packages "$@"
    )
}

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
    source_path="$(prepare_source_tree corrupt 1.0 https://example.invalid/corrupt-1.0.tar.xz corrupt-1.0.tar.xz "$(sha256_file "$archive")" 2>"$source_test_root/extract.log")"
    prepare_status=$?
    set -e
    if [ "$prepare_status" -eq 0 ]; then
        : > "$downstream_marker"
    fi

    [ "$prepare_status" -ne 0 ] || { echo 'source preparation accepted a corrupt cached archive' >&2; exit 1; }
    [ -z "$source_path" ] || { echo 'source preparation returned a path after extraction failure' >&2; exit 1; }
    [ ! -e "$downstream_marker" ] || { echo 'downstream build phase was reached after extraction failure' >&2; exit 1; }
)
printf 'source corrupt-cache propagation test passed\n'

(
    source_test_root="$TMP/source-success"
    CUP_SRC_DIR="$source_test_root/src"
    mkdir -p "$CUP_SRC_DIR" "$source_test_root/archive-root/fixture-1.0"
    printf 'source-ok\n' > "$source_test_root/archive-root/fixture-1.0/marker.txt"
    tar -cJf "$CUP_SRC_DIR/fixture-1.0.tar.xz" -C "$source_test_root/archive-root" fixture-1.0

    source_path="$(prepare_source_tree fixture 1.0 https://example.invalid/fixture-1.0.tar.xz fixture-1.0.tar.xz "$(sha256_file "$CUP_SRC_DIR/fixture-1.0.tar.xz")")"
    [ "$source_path" = "$CUP_SRC_DIR/fixture-1.0" ] || { echo 'successful source preparation returned the wrong path' >&2; exit 1; }
    [ "$(cat "$source_path/marker.txt")" = source-ok ] || { echo 'successful source preparation did not extract expected content' >&2; exit 1; }
)
printf 'source acquisition success-path test passed\n'

# Executable capability metadata must mean executable on POSIX, while native
# Windows command identity remains extension-based rather than dependent on
# MSYS2 mode bits.
(
    executable_root="$TMP/executable-semantics"
    mkdir -p "$executable_root/bin"
    printf 'fixture\n' > "$executable_root/bin/tool"
    HOST_PLATFORM=linux-x64
    if prefix_executable_exists "$executable_root" tool; then
        echo 'POSIX executable detection accepted a non-executable file' >&2
        exit 1
    fi
    chmod 0755 "$executable_root/bin/tool"
    prefix_executable_exists "$executable_root" tool || {
        echo 'POSIX executable detection rejected an executable file' >&2
        exit 1
    }

    printf 'fixture\n' > "$executable_root/bin/windows-tool.exe"
    chmod 0644 "$executable_root/bin/windows-tool.exe"
    HOST_PLATFORM=windows-x64
    prefix_executable_exists "$executable_root" windows-tool || {
        echo 'Windows executable detection incorrectly depends on MSYS2 mode bits' >&2
        exit 1
    }
)
printf 'platform executable-semantics test passed\n'

symlink_probe="$TMP/symlink-probe"
mkdir -p "$symlink_probe"
printf target > "$symlink_probe/target"
supports_symlinks=false
if ln -s target "$symlink_probe/link" 2>/dev/null &&
   [ -L "$symlink_probe/link" ] &&
   [ "$(readlink "$symlink_probe/link" 2>/dev/null || true)" = target ]; then
    supports_symlinks=true
fi

prefix="$TMP/prefix"
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/share/data"
printf '#!/bin/sh\nprintf fixture\\n' > "$prefix/bin/gdb"
chmod 0711 "$prefix/bin/gdb"
printf 'payload\n' > "$prefix/lib/libfixture.so.2"
if [ "$supports_symlinks" = true ]; then
    ln -s gdb "$prefix/bin/gdb-alias"
    ln -s libfixture.so.2 "$prefix/lib/libfixture.so"
    ln -s libfixture.so "$prefix/lib/libfixture-current.so"
    mkdir -p "$prefix/lib/aliases"
    ln -s ../libfixture.so.2 "$prefix/lib/aliases/libfixture.so"
fi
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
source.primary.name=gdb
source.primary.version=1.0
source.primary.url=https://example.invalid/gdb-1.0.tar.xz
source.primary.sha256=0000000000000000000000000000000000000000000000000000000000000000
features.fixture=true
config.fixture=true
EOF_INFO
if [ "$supports_symlinks" = true ]; then
    printf 'entry.gdb=bin/gdb-alias\n' >> "$prefix/info.txt"
else
    printf 'entry.gdb=bin/gdb\n' >> "$prefix/info.txt"
fi

create_packages_without_runtime_closure gdb 1.0 linux-x64 linux-x64 "" "$prefix"
base=gdb-1.0-linux-x64-linux-x64
package_root="$CUP_WORK_DIR/package-root/$base"

[ -f "$package_root/manifest.txt" ] || { echo 'manifest missing' >&2; exit 1; }
grep -Fx 'format=2' "$package_root/manifest.txt" >/dev/null
if package_info_value "$package_root/info.txt" package.revision >/dev/null 2>&1; then
    echo 'revisionless GDB package retained package.revision metadata' >&2
    exit 1
fi
if [ "$supports_symlinks" = true ]; then
    [ -L "$package_root/bin/gdb-alias" ] || { echo 'entry symlink was not preserved' >&2; exit 1; }
    [ "$(readlink "$package_root/bin/gdb-alias")" = gdb ] || { echo 'entry symlink target changed' >&2; exit 1; }
    [ -L "$package_root/lib/libfixture.so" ] || { echo 'symlink was not preserved' >&2; exit 1; }
    [ -L "$package_root/lib/libfixture-current.so" ] || { echo 'symlink chain was not preserved' >&2; exit 1; }
    [ -L "$package_root/lib/aliases/libfixture.so" ] || { echo 'parent-relative symlink was not preserved' >&2; exit 1; }
    [ "$(cat "$package_root/lib/libfixture-current.so")" = payload ] || { echo 'preserved symlink chain resolves to wrong bytes' >&2; exit 1; }
    link_digest="$(package_text_digest 'libfixture.so.2')"
    grep -F $'l\t-\t'"$link_digest"$'\tlib/libfixture.so' "$package_root/manifest.txt" >/dev/null
fi
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

# Windows package modes are logical archive modes. PE loadable images are kept
# executable so MSYS2 tar/ZIP metadata and manifest v2 describe the same tree.
[ "$(package_file_mode_class tool.exe windows-x64)" = 0755 ]
[ "$(package_file_mode_class runtime.dll windows-x64)" = 0755 ]
[ "$(package_file_mode_class extension.pyd windows-x64)" = 0755 ]
windows_script="$TMP/windows-script-without-extension"
printf '#!/bin/sh\nexit 0\n' > "$windows_script"
[ "$(package_file_mode_class "$windows_script" windows-x64)" = 0755 ]
printf 'plain-data\n' > "$windows_script"
[ "$(package_file_mode_class "$windows_script" windows-x64)" = 0644 ]
[ "$(package_file_mode_class metadata.txt windows-x64)" = 0644 ]

tar -tf "$CUP_OUT_DIR/$base.tar.xz" >/dev/null
tar -tf "$CUP_OUT_DIR/$base.tar.gz" >/dev/null
unzip -tqq "$CUP_OUT_DIR/$base.zip"
zip_extract="$TMP/zip-extract"
mkdir -p "$zip_extract"
unzip -q "$CUP_OUT_DIR/$base.zip" -d "$zip_extract"
if [ "$supports_symlinks" = true ]; then
    for archive in "$CUP_OUT_DIR/$base.tar.xz" "$CUP_OUT_DIR/$base.tar.gz"; do
        tar -tvf "$archive" | grep -F 'lib/libfixture.so -> libfixture.so.2' >/dev/null || {
            echo "tar archive did not preserve symbolic link: $archive" >&2
            exit 1
        }
    done
    [ -L "$zip_extract/$base/lib/libfixture.so" ] || { echo 'zip did not preserve symbolic link' >&2; exit 1; }
    [ -L "$zip_extract/$base/lib/libfixture-current.so" ] || { echo 'zip did not preserve symbolic-link chain' >&2; exit 1; }
    [ "$(cat "$zip_extract/$base/lib/libfixture-current.so")" = payload ] || { echo 'zip symlink chain resolves to wrong bytes' >&2; exit 1; }
fi

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

# The final archive verifier owns the extracted logical graph. Windows execute
# semantics are extension/shebang based, so platform-specific ZIP listing mode
# rendering is not a separate package contract.
windows_archive_root="$TMP/windows-archive-root"
windows_archive_base="gdb-1.0-windows-x64-windows-x64"
mkdir -p "$windows_archive_root/$windows_archive_base/bin"
printf '#!/bin/sh\nexit 0\n' > "$windows_archive_root/$windows_archive_base/bin/helper"
chmod 0755 "$windows_archive_root/$windows_archive_base/bin/helper"
cat > "$windows_archive_root/$windows_archive_base/manifest.txt" <<EOF_WINDOWS_MANIFEST
format=2
d	0755	-	bin
f	0755	$(package_file_digest "$windows_archive_root/$windows_archive_base/bin/helper")	bin/helper
EOF_WINDOWS_MANIFEST
(
    cd "$windows_archive_root"
    zip -qr "$TMP/$windows_archive_base.zip" "$windows_archive_base"
)

# Info-ZIP status 1 is a warning status. A self-produced Windows ZIP may
# therefore report a warning even though listing/extraction completed. The
# common verifier must continue into its manifest/tree checks, while true
# unzip failures remain fatal.
chmod 0755 "$windows_archive_root/$windows_archive_base/bin/helper"
rm -f "$TMP/$windows_archive_base.zip"
(
    cd "$windows_archive_root"
    zip -qr "$TMP/$windows_archive_base.zip" "$windows_archive_base"
)
real_unzip="$(command -v unzip)"
unzip_stub="$TMP/unzip-stub"
mkdir -p "$unzip_stub"
cat > "$unzip_stub/unzip" <<EOF_UNZIP_STUB
#!/usr/bin/env bash
"$real_unzip" "\$@" || exit \$?
exit "\${CUP_UNZIP_TEST_STATUS:-0}"
EOF_UNZIP_STUB
chmod 0755 "$unzip_stub/unzip"

CUP_UNZIP_TEST_STATUS=1 PATH="$unzip_stub:$PATH" \
    package_verify_archive zip "$windows_archive_base" \
    "$windows_archive_root/$windows_archive_base" "$TMP" windows-x64 >/dev/null

if CUP_UNZIP_TEST_STATUS=2 PATH="$unzip_stub:$PATH" \
    package_verify_archive zip "$windows_archive_base" \
    "$windows_archive_root/$windows_archive_base" "$TMP" windows-x64 >/dev/null 2>&1; then
    echo 'final archive verifier accepted a hard unzip failure' >&2
    exit 1
fi

# Unsupported producer objects must fail before publication when the host
# filesystem can actually represent the fixture object.
fifo_probe="$TMP/fifo-probe"
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$fifo_probe" 2>/dev/null && [ -p "$fifo_probe" ]; then
    bad_prefix="$TMP/bad-prefix"
    cp -RPp "$prefix" "$bad_prefix"
    rm -f "$bad_prefix/lib/libfixture.so" 2>/dev/null || true
    mv "$fifo_probe" "$bad_prefix/lib/not-a-file"
    if (create_packages_without_runtime_closure gdb 1.0 linux-x64 linux-x64 "" "$bad_prefix") >/dev/null 2>&1; then
        echo 'special object was accepted by common package finalization' >&2
        exit 1
    fi
else
    rm -f "$fifo_probe" 2>/dev/null || true
    printf 'special-object FIFO rejection test skipped: host filesystem cannot represent a FIFO\n'
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
source.primary.sha256=0000000000000000000000000000000000000000000000000000000000000000
bundle.components=binutils
bundle.binutils.version=8.7.6
bundle.binutils.url=https://example.invalid/binutils-8.7.6.tar.xz
bundle.binutils.sha256=1111111111111111111111111111111111111111111111111111111111111111
entry.gcc=bin/gcc
EOF_GCC_INFO
create_packages_without_runtime_closure gcc 1.0 linux-x64 linux-x64 1 "$gcc_prefix"
gcc_base=gcc-1.0-rev1-linux-x64-linux-x64
for format in tar.xz tar.gz zip; do
    [ -f "$CUP_OUT_DIR/$gcc_base.$format" ] || { echo "missing GCC revision-bearing archive: $format" >&2; exit 1; }
done
grep -Fx "release_tag=$gcc_base" "$CUP_OUT_DIR/release.env" >/dev/null
[ "$(package_version_name gcc 1.0 linux-x64 linux-x64 2)" = 1.0-rev2 ] || {
    echo 'future GCC revision was not accepted' >&2
    exit 1
}
# The finalizer must preserve enough GCC composition metadata to make a
# revision meaningful without consulting repository-side version mappings.
assert_gcc_composition_rejected() {
    local name="$1"
    local command="$2"
    local candidate="$TMP/gcc-composition-$name"

    cp -RPp "$gcc_prefix" "$candidate"
    eval "$command"
    if (package_verify_info_contract "$candidate" gcc 1.0 linux-x64 linux-x64 1) >/dev/null 2>&1; then
        echo "invalid GCC composition metadata was accepted: $name" >&2
        exit 1
    fi
}
assert_gcc_composition_rejected missing-binutils-version 'sed "/^bundle.binutils.version=/d" "$candidate/info.txt" > "$candidate/info.txt.tmp" && mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_gcc_composition_rejected invalid-binutils-digest 'sed "s/^bundle.binutils.sha256=.*/bundle.binutils.sha256=bad/" "$candidate/info.txt" > "$candidate/info.txt.tmp" && mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_gcc_composition_rejected wrong-components 'sed "s/^bundle.components=binutils$/bundle.components=binutils,mingw-w64/" "$candidate/info.txt" > "$candidate/info.txt.tmp" && mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_gcc_composition_rejected stray-mingw 'printf "bundle.mingw-w64.version=5.4.3\n" >> "$candidate/info.txt"'
printf 'GCC revision/composition package identity tests passed\n'

# Link admission is deliberately narrow: only POSIX relative internal finite
# symbolic-link chains resolving to regular files may be published.
assert_link_rejected() {
    local name="$1"
    local setup="$2"
    local candidate="$TMP/link-$name"

    cp -RPp "$prefix" "$candidate"
    rm -f "$candidate/lib/libfixture.so"
    eval "$setup"
    if (create_packages_without_runtime_closure gdb 1.0 linux-x64 linux-x64 "" "$candidate") >/dev/null 2>&1; then
        echo "unsafe staging link was accepted: $name" >&2
        exit 1
    fi
}

if [ "$supports_symlinks" = true ]; then
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
    for ((i=80; i>=1; i--)); do
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

else
    printf 'package link-admission tests skipped: host filesystem cannot represent symbolic links\n'
fi

printf 'package link-admission tests passed\n'

# Producer self-validation must reject metadata/path states that CUP cannot consume.
assert_package_rejected() {
    local name="$1"
    local setup="$2"
    local candidate="$TMP/contract-$name"

    cp -RPp "$prefix" "$candidate"
    eval "$setup"
    if (create_packages_without_runtime_closure gdb 1.0 linux-x64 linux-x64 "" "$candidate") >/dev/null 2>&1; then
        echo "producer contract violation was accepted: $name" >&2
        exit 1
    fi
}

assert_package_rejected missing-required 'grep -v "^source.primary.url=" "$candidate/info.txt" > "$candidate/info.txt.tmp"; mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_package_rejected source-name-mismatch 'sed "s/^source.primary.name=gdb$/source.primary.name=llvm-project/" "$candidate/info.txt" > "$candidate/info.txt.tmp"; mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_package_rejected source-version-mismatch 'sed "s/^source.primary.version=1.0$/source.primary.version=1.1/" "$candidate/info.txt" > "$candidate/info.txt.tmp"; mv "$candidate/info.txt.tmp" "$candidate/info.txt"'
assert_package_rejected duplicate-field 'printf "package.tool=gdb\\n" >> "$candidate/info.txt"'
assert_package_rejected missing-final-newline 'printf %s "$(cat "$candidate/info.txt")" > "$candidate/info.txt"'
assert_package_rejected packaged-python-version-missing 'printf "contents.python_runtime=packaged\n" >> "$candidate/info.txt"'
assert_package_rejected packaged-python-version-invalid 'printf "contents.python_runtime=packaged\ncontents.python_runtime.version=not-a-version\n" >> "$candidate/info.txt"'
assert_package_rejected invalid-feature-boolean 'printf "features.invalid=yes\n" >> "$candidate/info.txt"'
assert_package_rejected invalid-requirement-boolean 'printf "requires.invalid=1\n" >> "$candidate/info.txt"'

# A case-fold collision can only exist in a staging tree when the host
# filesystem can represent names that differ by case. Probe that capability
# before constructing the negative fixture; otherwise both writes name the
# same object and there is no collision for the producer to reject.
case_probe="$TMP/case-distinct-path-probe"
mkdir -p "$case_probe"
printf upper > "$case_probe/Case"
printf lower > "$case_probe/case"
if [ "$(cat "$case_probe/Case")" = upper ] && [ "$(cat "$case_probe/case")" = lower ]; then
    assert_package_rejected case-collision 'printf x > "$candidate/share/Case"; printf y > "$candidate/share/case"'
    printf 'producer case-fold collision rejection test passed\n'
else
    printf 'producer case-fold collision rejection test skipped: host filesystem cannot represent case-distinct paths\n'
fi

# Newlines must always be rejected by the central path grammar. Filesystem
# fixtures are exercised only when the host can represent such a name.
if package_relative_path_is_safe $'safe\nname'; then
    echo 'package path grammar truncated and accepted an embedded newline' >&2
    exit 1
fi
if package_relative_path_is_safe 'safe/'; then
    echo 'package path grammar accepted a non-canonical trailing slash' >&2
    exit 1
fi
newline_probe_dir="$TMP/newline-path-probe"
newline_probe_name="$(printf 'bad\nname')"
mkdir -p "$newline_probe_dir"
if printf x > "$newline_probe_dir/$newline_probe_name" 2>/dev/null && [ -f "$newline_probe_dir/$newline_probe_name" ]; then
    assert_package_rejected newline-path 'printf x > "$candidate/share/$(printf "bad\nname")"'

    newline_stage="$TMP/staging-newline-preclosure"
    cp -RPp "$prefix" "$newline_stage"
    printf x > "$newline_stage/share/$newline_probe_name"
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
else
    printf 'newline-path filesystem fixtures skipped: host filesystem cannot represent newline-bearing names\n'
fi

printf 'package metadata/path compatibility tests passed\n'
# Version inputs and package revisions form part of package identity and must not
# admit path syntax or arbitrary symbolic aliases. Revisionless families must
# reject a meaningless revision rather than silently creating a new identity.
[ "$(resolve_version gcc stable)" = "$DEFAULT_GCC_VERSION" ]
[ "$(resolve_version gcc 9.8.7)" = "9.8.7" ]
[ "$(package_version_name gcc 9.8.7 linux-x64 linux-x64 1)" = "9.8.7-rev1" ]
[ "$(package_version_name gdb 8.7.6 linux-x64 linux-x64 "")" = "8.7.6" ]
[ "$(package_base_name clang 7.6.5 linux-x64 linux-x64 "")" = "clang-7.6.5-linux-x64-linux-x64" ]
[ "$(package_base_name valgrind 6.5.4 linux-x64 linux-x64 "")" = "valgrind-6.5.4-linux-x64-linux-x64" ]
if (resolve_version gcc latest) >/dev/null 2>&1; then
    echo 'latest symbolic alias was accepted' >&2
    exit 1
fi
if (resolve_version gcc '../9.8.7') >/dev/null 2>&1; then
    echo 'non-numeric explicit version was accepted' >&2
    exit 1
fi
if (package_version_name gcc 9.8.7 linux-x64 linux-x64 '../3') >/dev/null 2>&1; then
    echo 'unsafe package revision was accepted' >&2
    exit 1
fi
if (package_version_name gcc 9.8.7 linux-x64 linux-x64 '') >/dev/null 2>&1; then
    echo 'GCC package without a required revision was accepted' >&2
    exit 1
fi
if (package_version_name gdb 8.7.6 linux-x64 linux-x64 1) >/dev/null 2>&1; then
    echo 'revisionless GDB package accepted a meaningless revision' >&2
    exit 1
fi
printf 'package version/revision input tests passed\n'


# Runtime-closure discovery must be independent of the builder's ambient
# LD_LIBRARY_PATH. A fake ldd records the exact value it receives.
fake_bin="$TMP/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/readelf" <<'EOF_FAKE_READELF'
#!/bin/sh
printf ' 0x0000000000000001 (NEEDED)             Shared library: [libfixture.so]\n'
EOF_FAKE_READELF
cat > "$fake_bin/ldd" <<'EOF_FAKE_LDD'
#!/bin/sh
printf '%s' "$LD_LIBRARY_PATH" > "$LDD_CAPTURE"
printf 'libfixture.so => /package/lib/libfixture.so (0x0000000000000000)\n'
EOF_FAKE_LDD
chmod +x "$fake_bin/readelf" "$fake_bin/ldd"
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
for ((i=1; i<=10; i++)); do printf 'lib%s' "$i" > "$deep_external/lib$i.so"; done
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
printf 'Linux recursive runtime-closure test passed\n'

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

missing_pe_prefix="$TMP/missing-pe-prefix"
mkdir -p "$missing_pe_prefix/bin"
printf fixture > "$missing_pe_prefix/bin/tool.exe"
if (
    HOST_PLATFORM=windows-x64
    PREFIX="$missing_pe_prefix"
    windows_pe_import_tool() { printf '%s\n' fixture-objdump; }
    windows_pe_import_dll_names() { printf '%s\n' missing-runtime.dll; }
    find_windows_runtime_dll_by_name() { :; }
    copy_windows_runtime_dlls "$missing_pe_prefix/bin"
) >/dev/null 2>&1; then
    echo 'Windows runtime closure accepted an unresolved non-system DLL import' >&2
    exit 1
fi
system_path_pe_prefix="$TMP/system-path-pe-prefix"
mkdir -p "$system_path_pe_prefix/bin"
printf fixture > "$system_path_pe_prefix/bin/tool.exe"
if (
    HOST_PLATFORM=windows-x64
    PREFIX="$system_path_pe_prefix"
    windows_pe_import_tool() { printf '%s\n' fixture-objdump; }
    windows_pe_import_dll_names() { printf '%s\n' package-runtime.dll; }
    find_windows_runtime_dll_by_name() { printf '%s\n' /c/windows/system32/package-runtime.dll; }
    windows_runtime_dll_allowed_path() { return 1; }
    copy_windows_runtime_dlls "$system_path_pe_prefix/bin"
) >/dev/null 2>&1; then
    echo 'Windows runtime closure accepted a non-system import from a system path' >&2
    exit 1
fi
printf 'runtime dependency-name path-safety tests passed\n'

windows_chain_prefix="$TMP/windows-chain-prefix"
windows_chain_provider="$TMP/windows-chain-provider"
mkdir -p "$windows_chain_prefix/bin" "$windows_chain_provider"
printf tool > "$windows_chain_prefix/bin/tool.exe"
printf first > "$windows_chain_provider/first.dll"
printf second > "$windows_chain_provider/second.dll"
(
    HOST_PLATFORM=windows-x64
    PREFIX="$windows_chain_prefix"
    windows_pe_import_tool() { printf '%s\n' fixture-objdump; }
    windows_pe_import_dll_names() {
        case "$(basename "$1")" in
            tool.exe) printf '%s\n' first.dll ;;
            first.dll) printf '%s\n' second.dll ;;
        esac
    }
    find_windows_runtime_dll_by_name() {
        [ -f "$windows_chain_provider/$1" ] && printf '%s\n' "$windows_chain_provider/$1"
    }
    windows_runtime_dll_allowed_path() { return 0; }
    copy_windows_runtime_dlls "$windows_chain_prefix/bin"
)
[ -f "$windows_chain_prefix/bin/first.dll" ] || {
    echo 'Windows runtime closure did not copy the first dependency' >&2
    exit 1
}
[ -f "$windows_chain_prefix/bin/second.dll" ] || {
    echo 'Windows runtime closure did not traverse a copied dependency' >&2
    exit 1
}
printf 'Windows recursive runtime-closure test passed\n'

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


# Runtime-library collision detection must compare source identities, not a
# packaged copy that install_name_tool has already rewritten in place.
mac_repeat_prefix="$TMP/mac-repeat-prefix"
mac_repeat_external="$TMP/mac-repeat-external"
mkdir -p "$mac_repeat_prefix/bin" "$mac_repeat_external"
printf a > "$mac_repeat_prefix/bin/a"
printf b > "$mac_repeat_prefix/bin/b"
printf 'same-runtime\n' > "$mac_repeat_external/libshared.dylib"
if ! (
    macos_macho_files() {
        printf '%s\n' "$mac_repeat_prefix/bin/a" "$mac_repeat_prefix/bin/b"
    }
    macos_macho_dependencies() { printf '%s\n' "$mac_repeat_external/libshared.dylib"; }
    otool() {
        [ "$1" = -D ] || return 2
        printf '%s:\n%s\n' "$2" "$2"
    }
    install_name_tool() {
        case "$1" in
            -id) printf '\nrewritten-install-name\n' >> "$3" ;;
            -change) : ;;
            *) return 2 ;;
        esac
    }
    macos_copy_and_rewrite_runtime_libraries "$mac_repeat_prefix"
); then
    echo 'macOS closure misclassified a previously rewritten copy of the same runtime library as a conflict' >&2
    exit 1
fi

mac_collision_prefix="$TMP/mac-collision-prefix"
mac_collision_external_a="$TMP/mac-collision-a"
mac_collision_external_b="$TMP/mac-collision-b"
mkdir -p "$mac_collision_prefix/bin" "$mac_collision_external_a" "$mac_collision_external_b"
printf a > "$mac_collision_prefix/bin/a"
printf b > "$mac_collision_prefix/bin/b"
printf 'runtime-a\n' > "$mac_collision_external_a/libcollision.dylib"
printf 'runtime-b\n' > "$mac_collision_external_b/libcollision.dylib"
if (
    macos_macho_files() {
        printf '%s\n' "$mac_collision_prefix/bin/a" "$mac_collision_prefix/bin/b"
    }
    macos_macho_dependencies() {
        case "$(basename "$1")" in
            a) printf '%s\n' "$mac_collision_external_a/libcollision.dylib" ;;
            b) printf '%s\n' "$mac_collision_external_b/libcollision.dylib" ;;
        esac
    }
    otool() {
        [ "$1" = -D ] || return 2
        printf '%s:\n%s\n' "$2" "$2"
    }
    install_name_tool() { :; }
    macos_copy_and_rewrite_runtime_libraries "$mac_collision_prefix"
) >/dev/null 2>&1; then
    echo 'macOS closure accepted different runtime libraries with the same package basename' >&2
    exit 1
fi
printf 'macOS rewritten-runtime identity/collision tests passed\n'

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
for ((i=1; i<=10; i++)); do printf 'dylib%s' "$i" > "$deep_mac_external/lib$i.dylib"; done
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
printf 'macOS recursive runtime-closure test passed\n'
# Linux runtime closure is exercised with real synthetic ELF objects on Linux.
# DT_NEEDED is the dependency graph; ldd is only a resolver for those names.
if [ "$(uname -s)" = Linux ] && command -v gcc >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
    elf_tmp="$TMP/linux-runtime-fixtures"
    mkdir -p "$elf_tmp"

    cat > "$elf_tmp/nodeps.c" <<'EOF_NODEPS'
int fixture_nodeps(void) { return 0; }
EOF_NODEPS
    gcc -shared -fPIC -nostdlib -Wl,-soname,libnodeps.so \
        "$elf_tmp/nodeps.c" -o "$elf_tmp/libnodeps.so"
    [ -z "$(linux_elf_needed_names "$elf_tmp/libnodeps.so")" ] || {
        echo 'synthetic no-DT_NEEDED ELF unexpectedly has dependencies' >&2
        exit 1
    }
    [ -z "$(linux_ldd_dependencies "$elf_tmp/libnodeps.so")" ] || {
        echo 'dynamic ELF without DT_NEEDED produced a runtime dependency' >&2
        exit 1
    }
    if (
        readelf() { return 7; }
        linux_ldd_dependencies "$elf_tmp/libnodeps.so"
    ) >/dev/null 2>&1; then
        echo 'Linux dependency inspection accepted a readelf failure' >&2
        exit 1
    fi
    printf 'Linux zero-DT_NEEDED/readelf fail-closed tests passed\n'

    # Local test substitute for patchelf. Every fixture starts with a deliberately
    # padded RUNPATH, so this helper only needs to replace existing DT_RPATH/RUNPATH
    # text in-place. Real producer builds still use patchelf.
    fixture_tools="$elf_tmp/tools"
    mkdir -p "$fixture_tools"
    cat > "$fixture_tools/patchelf" <<'EOF_PATCHELF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = --set-rpath ] || exit 2
new="$2"
file="$3"
old="$(readelf -d "$file" | sed -n 's/.*Library .*path: \[\([^]]*\)\].*/\1/p' | head -n 1)"
[ -n "$old" ] || { echo "fixture patchelf requires an existing RUNPATH: $file" >&2; exit 1; }
OLD="$old" NEW="$new" FILE="$file" perl -e '
use strict;
use warnings;
my ($file, $old, $new) = @ENV{qw(FILE OLD NEW)};
open my $fh, "+<:raw", $file or die "$file: $!";
local $/;
my $data = <$fh>;
my $pos = index($data, $old . "\0");
die "existing RUNPATH not found\n" if $pos < 0;
die "replacement RUNPATH exceeds fixture capacity\n" if length($new) > length($old);
substr($data, $pos, length($old), $new . ("\0" x (length($old) - length($new))));
seek($fh, 0, 0) or die $!;
print {$fh} $data;
truncate($fh, length($data)) or die $!;
close $fh;
'
EOF_PATCHELF
    chmod 0755 "$fixture_tools/patchelf"

    cat > "$elf_tmp/libfixture.c" <<'EOF_LIB'
#include <unistd.h>
int fixture_value(void) { return getpid() < 0 ? 8 : 7; }
EOF_LIB
    cat > "$elf_tmp/tool.c" <<'EOF_TOOL'
extern int fixture_value(void);
int main(void) { return fixture_value() == 7 ? 0 : 1; }
EOF_TOOL

    hard_prefix="$elf_tmp/hardlink-prefix"
    mkdir -p "$hard_prefix/bin" "$hard_prefix/nested/bin" "$hard_prefix/lib"
    hard_padding='$ORIGIN/../lib:$ORIGIN/CUP_RPATH_PADDING________________________________________________________________________________'
    lib_padding='$ORIGIN/CUP_RPATH_PADDING_________________________________________________________________________________________'
    gcc -shared -fPIC "$elf_tmp/libfixture.c" -Wl,-soname,libfixture.so \
        -Wl,-rpath,"$lib_padding" -o "$hard_prefix/lib/libfixture.so"
    gcc "$elf_tmp/tool.c" -L"$hard_prefix/lib" -lfixture \
        -Wl,-rpath,"$hard_padding" -o "$hard_prefix/bin/tool"
    ln "$hard_prefix/bin/tool" "$hard_prefix/nested/bin/tool"

    normal_dependencies="$(LINUX_RUNTIME_SEARCH_PATH="$hard_prefix/lib" linux_ldd_dependencies "$hard_prefix/bin/tool")"
    printf '%s\n' "$normal_dependencies" | grep -F $'libfixture.so\t' >/dev/null || {
        echo 'normal DT_NEEDED resolution did not report libfixture.so' >&2
        exit 1
    }

    PATH="$fixture_tools:$PATH" linux_patch_runtime_search_paths "$hard_prefix"
    LD_LIBRARY_PATH='' "$hard_prefix/bin/tool"
    LD_LIBRARY_PATH='' "$hard_prefix/nested/bin/tool"
    hard_relocated="$elf_tmp/hardlink-relocated"
    cp -RPp "$hard_prefix" "$hard_relocated"
    LD_LIBRARY_PATH='' "$hard_relocated/bin/tool"
    LD_LIBRARY_PATH='' "$hard_relocated/nested/bin/tool"
    [ "$(readelf -d "$hard_prefix/bin/tool" | sed -n 's/.*Library .*path: \[\([^]]*\)\].*/\1/p' | head -n 1)" = '$ORIGIN/../lib' ] || {
        echo 'top-level hardlink alias has the wrong package-relative RUNPATH' >&2
        exit 1
    }
    [ "$(readelf -d "$hard_prefix/nested/bin/tool" | sed -n 's/.*Library .*path: \[\([^]]*\)\].*/\1/p' | head -n 1)" = '$ORIGIN/../../lib' ] || {
        echo 'nested hardlink alias has the wrong package-relative RUNPATH' >&2
        exit 1
    }
    printf 'Linux hardlinked path-specific RUNPATH test passed\n'

    # A dynamic ELF may also be loaded through a symlink from another package
    # directory. $ORIGIN is evaluated from that alias pathname, so the real ELF
    # must carry runtime search entries for every package-internal load path.
    alias_prefix="$elf_tmp/symlink-alias-prefix"
    alias_native="$alias_prefix/lib/python3.12/site-packages/lldb/native"
    mkdir -p "$alias_prefix/lib" "$alias_native"
    cat > "$elf_tmp/alias-dep.c" <<'EOF_ALIAS_DEP'
int alias_dependency_value(void) { return 42; }
EOF_ALIAS_DEP
    cat > "$elf_tmp/alias-target.c" <<'EOF_ALIAS_TARGET'
extern int alias_dependency_value(void);
int alias_target_value(void) { return alias_dependency_value(); }
EOF_ALIAS_TARGET
    cat > "$elf_tmp/alias-loader.c" <<'EOF_ALIAS_LOADER'
#include <dlfcn.h>
#include <stdio.h>

typedef int (*value_fn)(void);

int main(int argc, char **argv) {
    void *handle;
    value_fn value;

    if (argc != 2) return 2;
    handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    value = (value_fn)dlsym(handle, "alias_target_value");
    if (!value) return 1;
    return value() == 42 ? 0 : 1;
}
EOF_ALIAS_LOADER
    alias_padding='$ORIGIN/CUP_ALIAS_RPATH_PADDING____________________________________________________________________________________'
    gcc -shared -fPIC "$elf_tmp/alias-dep.c" -Wl,-soname,libaliasdep.so.1 \
        -Wl,-rpath,"$alias_padding" -o "$alias_prefix/lib/libaliasdep.so.1"
    ln -s libaliasdep.so.1 "$alias_prefix/lib/libaliasdep.so"
    gcc -shared -fPIC "$elf_tmp/alias-target.c" -L"$alias_prefix/lib" -laliasdep \
        -Wl,-soname,libaliastarget.so.1 -Wl,-rpath,"$alias_padding" \
        -o "$alias_prefix/lib/libaliastarget.so.1"
    ln -s ../../../../libaliastarget.so.1 "$alias_native/_alias.so"
    gcc "$elf_tmp/alias-loader.c" -ldl -o "$elf_tmp/alias-loader"

    if env -i PATH=/usr/bin:/bin "$elf_tmp/alias-loader" "$alias_native/_alias.so" >/dev/null 2>&1; then
        echo 'synthetic ELF alias unexpectedly loaded before alias-aware RUNPATH rewrite' >&2
        exit 1
    fi
    PATH="$fixture_tools:$PATH" linux_patch_runtime_search_paths "$alias_prefix"
    alias_target_runpath="$(readelf -d "$alias_prefix/lib/libaliastarget.so.1" |
        sed -n 's/.*Library .*path: \[\([^]]*\)\].*/\1/p' | head -n 1)"
    [ "$alias_target_runpath" = '$ORIGIN:$ORIGIN/../../../..' ] || {
        echo "symlink-loaded ELF has the wrong alias-aware RUNPATH: $alias_target_runpath" >&2
        exit 1
    }
    env -i PATH=/usr/bin:/bin "$elf_tmp/alias-loader" "$alias_native/_alias.so"
    alias_relocated="$elf_tmp/symlink-alias-relocated"
    cp -RPp "$alias_prefix" "$alias_relocated"
    env -i PATH=/usr/bin:/bin "$elf_tmp/alias-loader" \
        "$alias_relocated/lib/python3.12/site-packages/lldb/native/_alias.so"
    printf 'Linux symlink-loaded ELF alias RUNPATH test passed\n'

    missing_prefix="$elf_tmp/missing-prefix"
    mkdir -p "$missing_prefix/bin"
    cp -p "$hard_prefix/bin/tool" "$missing_prefix/bin/tool"
    missing_dependencies="$(LINUX_RUNTIME_SEARCH_PATH="$missing_prefix/lib" linux_ldd_dependencies "$missing_prefix/bin/tool")"
    printf '%s\n' "$missing_dependencies" | grep -F $'libfixture.so\t!NOT_FOUND!' >/dev/null || {
        echo 'unresolved DT_NEEDED dependency was not reported as not found' >&2
        exit 1
    }
    if (linux_copy_resolved_runtime_libraries "$missing_prefix") >/dev/null 2>&1; then
        echo 'Linux closure accepted an unresolved non-base dependency' >&2
        exit 1
    fi

    verifier_fixture="$elf_tmp/verifier-fixture"
    mkdir -p "$verifier_fixture/bin"
    : > "$verifier_fixture/bin/tool"

    # Final verification applies the base-ABI exception before unresolved-path
    # rejection. Non-base dependencies remain fail-closed.
    (
        linux_dynamic_elf_files() { printf '%s\n' "$verifier_fixture/bin/tool"; }
        linux_ldd_dependencies() { printf 'ld-linux-fixture.so.2\t!NOT_FOUND!\n'; }
        verify_linux_runtime_libraries "$verifier_fixture"
    )
    if (
        linux_dynamic_elf_files() { printf '%s\n' "$verifier_fixture/bin/tool"; }
        linux_ldd_dependencies() { printf 'libmissingfixture.so.1\t!NOT_FOUND!\n'; }
        verify_linux_runtime_libraries "$verifier_fixture"
    ) >/dev/null 2>&1; then
        echo 'Linux verifier accepted an unresolved non-base dependency' >&2
        exit 1
    fi
    if (
        linux_dynamic_elf_files() { printf '%s\n' "$verifier_fixture/bin/tool"; }
        linux_ldd_dependencies() { printf 'libexternalfixture.so.1\t/outside/libexternalfixture.so.1\n'; }
        verify_linux_runtime_libraries "$verifier_fixture"
    ) >/dev/null 2>&1; then
        echo 'Linux verifier accepted a resolved external non-base dependency' >&2
        exit 1
    fi
    printf 'Linux final-verifier base/non-base ordering test passed\n'

    external_root="$elf_tmp/external"
    external_prefix="$elf_tmp/external-prefix"
    mkdir -p "$external_root" "$external_prefix/bin"
    gcc -shared -fPIC "$elf_tmp/libfixture.c" -Wl,-soname,libexternalfixture.so \
        -Wl,-rpath,"$lib_padding" -o "$external_root/libexternalfixture.so"
    cat > "$elf_tmp/external-tool.c" <<'EOF_EXTERNAL'
extern int fixture_value(void);
int main(void) { return fixture_value() == 7 ? 0 : 1; }
EOF_EXTERNAL
    gcc "$elf_tmp/external-tool.c" -L"$external_root" -lexternalfixture \
        -Wl,-rpath,"$external_root" -o "$external_prefix/bin/tool"
    if (verify_linux_runtime_libraries "$external_prefix") >/dev/null 2>&1; then
        echo 'Linux verifier accepted an external non-base runtime dependency' >&2
        exit 1
    fi
    printf 'Linux normal/unresolved/external dependency tests passed\n'

    internal_prefix="$elf_tmp/internal-prefix"
    mkdir -p "$internal_prefix/lib64" "$internal_prefix/lib/deep"
    internal_padding="$internal_prefix/lib64:$internal_prefix/CUP_RPATH_PADDING________________________________________________________________________"
    gcc -shared -fPIC "$elf_tmp/libfixture.c" -Wl,-soname,libfixture.so.1 \
        -Wl,-rpath,"$lib_padding" -o "$internal_prefix/lib64/libfixture.so.1"
    ln -s libfixture.so.1 "$internal_prefix/lib64/libfixture.so"
    cat > "$elf_tmp/plugin.c" <<'EOF_PLUGIN'
extern int fixture_value(void);
int plugin_value(void) { return fixture_value(); }
EOF_PLUGIN
    gcc -shared -fPIC "$elf_tmp/plugin.c" -L"$internal_prefix/lib64" -lfixture \
        -Wl,-rpath,"$internal_padding" -o "$internal_prefix/lib/deep/plugin.so"
    cat > "$elf_tmp/libconsumer.c" <<'EOF_LIBCONSUMER'
extern int fixture_value(void);
int consumer_value(void) { return fixture_value(); }
EOF_LIBCONSUMER
    gcc -shared -fPIC "$elf_tmp/libconsumer.c" -L"$internal_prefix/lib64" -lfixture \
        -Wl,-rpath,"$internal_padding" -o "$internal_prefix/lib64/libconsumer.so"

    # The producer must replace the absolute staging search path with an
    # equivalent package-relative path, not redesign the upstream lib64 layout.
    PATH="$fixture_tools:$PATH" prepare_linux_runtime_closure "$internal_prefix" linux-x64
    [ -f "$internal_prefix/lib64/libfixture.so.1" ] || {
        echo 'package-owned lib64 runtime was removed from its upstream layout' >&2
        exit 1
    }
    [ ! -e "$internal_prefix/lib/libfixture.so.1" ] || {
        echo 'package-owned lib64 runtime was unnecessarily duplicated into lib/' >&2
        exit 1
    }
    internal_runpath="$(readelf -d "$internal_prefix/lib/deep/plugin.so" | sed -n 's/.*Library .*path: \[\([^]]*\)\].*/\1/p' | head -n 1)"
    [ "$internal_runpath" = '$ORIGIN/../../lib64' ] || {
        echo "internal runtime rewrite did not preserve lib64 reachability: $internal_runpath" >&2
        exit 1
    }
    ! printf '%s\n' "$internal_runpath" | grep -F "$internal_prefix" >/dev/null || {
        echo 'absolute staging path remained in internal runtime RUNPATH' >&2
        exit 1
    }
    internal_same_runpath="$(readelf -d "$internal_prefix/lib64/libconsumer.so" | sed -n 's/.*Library .*path: \[\([^]]*\)\].*/\1/p' | head -n 1)"
    [ "$internal_same_runpath" = '$ORIGIN' ] || {
        echo "same-directory internal runtime rewrite lost lib64 reachability: $internal_same_runpath" >&2
        exit 1
    }
    ! printf '%s\n' "$internal_same_runpath" | grep -F "$internal_prefix" >/dev/null || {
        echo 'absolute staging path remained in same-directory internal RUNPATH' >&2
        exit 1
    }
    internal_resolved="$(LD_LIBRARY_PATH='' ldd "$internal_prefix/lib/deep/plugin.so" | awk '/libfixture\.so\.1/{print $3; exit}')"
    internal_resolved="$(realpath -m "$internal_resolved")"
    case "$internal_resolved" in
        "$internal_prefix/lib64"/*) ;;
        *) echo "internal runtime dependency did not remain in package lib64: $internal_resolved" >&2; exit 1 ;;
    esac
    internal_same_resolved="$(LD_LIBRARY_PATH='' ldd "$internal_prefix/lib64/libconsumer.so" | awk '/libfixture\.so\.1/{print $3; exit}')"
    internal_same_resolved="$(realpath -m "$internal_same_resolved")"
    case "$internal_same_resolved" in
        "$internal_prefix/lib64"/*) ;;
        *) echo "same-directory runtime dependency did not remain in package lib64: $internal_same_resolved" >&2; exit 1 ;;
    esac
    internal_relocated="$elf_tmp/internal-relocated"
    cp -RPp "$internal_prefix" "$internal_relocated"
    internal_relocated_resolved="$(LD_LIBRARY_PATH='' ldd "$internal_relocated/lib/deep/plugin.so" | awk '/libfixture\.so\.1/{print $3; exit}')"
    internal_relocated_resolved="$(realpath -m "$internal_relocated_resolved")"
    case "$internal_relocated_resolved" in
        "$internal_relocated/lib64"/*) ;;
        *) echo "relocated internal runtime dependency escaped upstream package layout: $internal_relocated_resolved" >&2; exit 1 ;;
    esac
    internal_same_relocated_resolved="$(LD_LIBRARY_PATH='' ldd "$internal_relocated/lib64/libconsumer.so" | awk '/libfixture\.so\.1/{print $3; exit}')"
    internal_same_relocated_resolved="$(realpath -m "$internal_same_relocated_resolved")"
    case "$internal_same_relocated_resolved" in
        "$internal_relocated/lib64"/*) ;;
        *) echo "relocated same-directory runtime dependency escaped upstream package layout: $internal_same_relocated_resolved" >&2; exit 1 ;;
    esac
    printf 'Linux package-owned internal runtime reachability test passed\n'
else
    printf 'Linux synthetic ELF regressions skipped on non-Linux/non-compiler host\n'
fi

# Hardlink inode sharing is not logical package semantics. Both paths and bytes
# matter, but the producer and archive formats need not preserve a shared inode.
[ -f "$package_root/share/data/a" ] && [ -f "$package_root/share/data/b" ] || {
    echo 'hardlinked staging paths did not remain regular package paths' >&2
    exit 1
}
[ "$(cat "$package_root/share/data/a")" = hardlinked ] &&
    [ "$(cat "$package_root/share/data/b")" = hardlinked ] || {
    echo 'hardlinked staging paths did not preserve file contents' >&2
    exit 1
}

# Nonrelocatable libtool metadata is not a packaged capability. Remove only .la
# files that retain producer build/staging roots; benign metadata is untouched.
la_prefix="$TMP/la-prune-prefix"
mkdir -p "$la_prefix/lib"
printf "dependency_libs=' -L%s/build/tool/lib'\n" "$CUP_WORK_DIR" > "$la_prefix/lib/nonrelocatable.la"
printf "libdir='${la_prefix}/lib'\n" > "$la_prefix/lib/prefix-bound.la"
printf "libdir='relative'\n" > "$la_prefix/lib/benign.la"
package_prune_nonrelocatable_libtool_archives "$la_prefix"
[ ! -e "$la_prefix/lib/nonrelocatable.la" ] || { echo 'build-root-bearing .la survived pruning' >&2; exit 1; }
[ ! -e "$la_prefix/lib/prefix-bound.la" ] || { echo 'staging-prefix-bearing .la survived pruning' >&2; exit 1; }
[ -f "$la_prefix/lib/benign.la" ] || { echo 'benign .la was removed without cause' >&2; exit 1; }
printf 'nonrelocatable libtool metadata pruning test passed\n'

# Windows Python path configs are shared infrastructure, but LLDB-specific files
# belong only to an LLDB package.
pth_gdb="$TMP/python-pth-gdb"
pth_lldb="$TMP/python-pth-lldb"
mkdir -p "$pth_gdb" "$pth_lldb"
create_windows_python_path_config "$pth_gdb" 3.12 false
[ ! -e "$pth_gdb/lldb._pth" ] && [ ! -e "$pth_gdb/lldb-dap._pth" ] || {
    echo 'generic Windows Python path config leaked LLDB-only files' >&2
    exit 1
}
create_windows_python_path_config "$pth_lldb" 3.12 true
[ -f "$pth_lldb/lldb._pth" ] && [ -f "$pth_lldb/lldb-dap._pth" ] || {
    echo 'LLDB Windows Python path config lost LLDB-specific files' >&2
    exit 1
}
printf 'Windows Python path-config ownership test passed\n'

# Exact producer source must use the supported Valgrind configure spelling and
# derive GDB TUI metadata from the packaged capability rather than host OS.
grep -F 'configure_help="$("$source_dir/configure" --help)"' "$ROOT/scripts/build/build-valgrind.sh" >/dev/null || {
    echo 'Valgrind builder does not inspect the exact source configure interface' >&2
    exit 1
}
grep -F -- '--with-gdbscripts-dir' "$ROOT/scripts/build/build-valgrind.sh" >/dev/null || {
    echo 'Valgrind builder does not verify gdbscripts-dir configure support' >&2
    exit 1
}
grep -F -- '--without-gdbscripts-dir' "$ROOT/scripts/build/build-valgrind.sh" >/dev/null || {
    echo 'Valgrind builder does not use the supported gdbscripts configure option spelling' >&2
    exit 1
}
if grep -F -- '--without-gdb-scripts-dir' "$ROOT/scripts/build/build-valgrind.sh" >/dev/null; then
    echo 'Valgrind builder still uses the unrecognized gdb-scripts option spelling' >&2
    exit 1
fi
grep -F 'has_tui="$(gdb_supports_tui)"' "$ROOT/scripts/build/build-gdb.sh" >/dev/null || {
    echo 'GDB metadata does not derive TUI capability from the packaged executable' >&2
    exit 1
}
grep -F 'strip --strip-debug "$PREFIX/bin/gdb.exe"' "$ROOT/scripts/build/build-gdb.sh" >/dev/null || {
    echo 'GDB Windows debug-only payload is not stripped deliberately' >&2
    exit 1
}
grep -F 'copy_windows_python_runtime "$build_dir" false true' "$ROOT/scripts/build/build-llvm-tool.sh" >/dev/null || {
    echo 'LLDB Windows packaging does not explicitly opt into LLDB Python path configs' >&2
    exit 1
}
printf 'producer source/configuration alignment tests passed\n'

# Explicit numeric versions are preserved verbatim and remain independent of
# the current stable selector. This is an identity test, not a support promise.
[ "$(resolve_version clang 99.98.7)" = 99.98.7 ] || { echo 'explicit LLVM version was replaced by stable' >&2; exit 1; }
explicit_base="$(package_base_name clang 99.98.7 linux-x64 linux-x64 '')"
stable_base="$(package_base_name clang "$DEFAULT_LLVM_VERSION" linux-x64 linux-x64 '')"
[ "$explicit_base" = clang-99.98.7-linux-x64-linux-x64 ] || { echo 'explicit LLVM version produced wrong revisionless identity' >&2; exit 1; }
[ "$explicit_base" != "$stable_base" ] || { echo 'different explicit/stable versions produced the same package identity' >&2; exit 1; }
printf 'explicit non-default version identity test passed\n'

# The MSYS2 setup entry point must resolve its package list from its own location,
# not from the operator's current working directory.
msys_fixture="$TMP/msys2-cwd"
mkdir -p "$msys_fixture/bin" "$msys_fixture/cwd"
cat > "$msys_fixture/bin/pacman" <<'EOF_PACMAN'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$PACMAN_FIXTURE_LOG"
EOF_PACMAN
chmod 0755 "$msys_fixture/bin/pacman"
(
    cd "$msys_fixture/cwd"
    PACMAN_FIXTURE_LOG="$msys_fixture/pacman.log" PATH="$msys_fixture/bin:$PATH" \
        bash "$ROOT/scripts/setup/setup-windows-msys2.sh" ucrt64
)
grep -Fx -- '-S' "$msys_fixture/pacman.log" >/dev/null || { echo 'MSYS2 setup did not reach pacman from external cwd' >&2; exit 1; }
first_ucrt_package="$(grep -v '^[[:space:]]*$' "$ROOT/scripts/setup/msys2-ucrt64-packages.txt" | grep -v '^[[:space:]]*#' | head -n 1)"
grep -Fx -- "$first_ucrt_package" "$msys_fixture/pacman.log" >/dev/null || { echo 'MSYS2 setup did not load its repository-relative package list' >&2; exit 1; }
printf 'MSYS2 arbitrary-cwd setup test passed\n'

# Keep checksum tamper detection in the normal common producer contract path.
bash "$ROOT/scripts/test/test-package-checksums.sh"
