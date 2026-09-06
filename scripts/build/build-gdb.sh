#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/package/package-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 <version|stable> <platform>

Examples:
  $0 stable linux-x64
  $0 stable windows-x64
USAGE
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 2
fi

REQUESTED_VERSION="$1"
HOST_PLATFORM="$2"
TARGET_PLATFORM="$2"
REVISION=""

TOOL="gdb"
COMPONENT="debugger"
VERSION="$(resolve_version gdb "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"
BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="source-release"
PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
SOURCE_URL="$(source_url_gdb "$VERSION")"
PACKAGE_PREFIX="$PREFIX"
GDB_BUILD_DIR=""
GDB_SOURCE_HIGHLIGHT_RELOCATABLE=false
GDB_READLINE_POLICY=upstream-default
GDB_ZLIB_POLICY=false

validate_platforms() {
    case "$HOST_PLATFORM" in
        linux-x64|linux-arm64|windows-x64) ;;
        *) die "unsupported GDB platform: $HOST_PLATFORM" ;;
    esac
}

python_command() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' python3
        return 0
    fi

    if command -v python >/dev/null 2>&1; then
        printf '%s\n' python
        return 0
    fi

    return 1
}

need_common_tools() {
    need curl
    need tar
    need make
    need zip
    need unzip

    if ! python_command >/dev/null 2>&1; then
        die "python3 or python is required to build GDB with Python support"
    fi

    if ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
        die "a host C compiler is required"
    fi
}


relocate_gdb_source_highlight_data() {
    local source_dir="$1"
    local target="$source_dir/gdb/source-cache.c"
    local tmp="${target}.cup-relocate.$$"
    local add_defs=1

    GDB_SOURCE_HIGHLIGHT_RELOCATABLE=false
    is_linux_platform "$HOST_PLATFORM" || return 0
    [ -f "$target" ] || return 0

    if grep -F 'Settings::setGlobalDataDir' "$target" >/dev/null &&
       grep -F 'gdb_datadir' "$target" >/dev/null; then
        GDB_SOURCE_HIGHLIGHT_RELOCATABLE=true
        return 0
    fi

    # Versions without GNU Source Highlight integration need no adaptation.
    grep -F 'srchilite::SourceHighlight' "$target" >/dev/null || return 0

    grep -F '#include "defs.h"' "$target" >/dev/null && add_defs=0

    if awk -v add_defs="$add_defs" '
        add_defs && $0 == "#include \"source-cache.h\"" {
            print "#include \"defs.h\""
            add_defs = 0
        }
        /new[[:space:]]+srchilite::SourceHighlight[[:space:]]*\(/ && !inserted {
            print "\t  /* Keep GNU Source Highlight data under the relocatable GDB data root.  */"
            print "\t  srchilite::Settings::setGlobalDataDir"
            print "\t    (gdb_datadir + SLASH_STRING + \"source-highlight\");"
            print ""
            inserted = 1
        }
        { print }
        END { if (add_defs || inserted != 1) exit 1 }
    ' "$target" > "$tmp"; then
        chmod --reference="$target" "$tmp"
        mv "$tmp" "$target"
        GDB_SOURCE_HIGHLIGHT_RELOCATABLE=true
    else
        rm -f "$tmp"
        log "GDB $VERSION Source Highlight integration is not recognized; building without that optional feature"
    fi
}

gdb_configure_has_option() {
    local source_dir="$1"
    local option="$2"
    "$source_dir/configure" --help 2>/dev/null | grep -F -- "$option" >/dev/null
}

gdb_subconfigure_has_option() {
    local source_dir="$1"
    local option="$2"
    [ -x "$source_dir/gdb/configure" ] || return 1
    "$source_dir/gdb/configure" --help 2>/dev/null | grep -F -- "$option" >/dev/null
}

gdb_config_bool() {
    local macro="$1"
    local header="${GDB_BUILD_DIR:-}/gdb/config.h"
    if [ -f "$header" ] && grep -Eq "^#define[[:space:]]+$macro[[:space:]]+1([[:space:]]|$)" "$header"; then
        printf '%s\n' true
    else
        printf '%s\n' false
    fi
}

gdb_linux_feature_configure_args() {
    local source_dir="$1"

    gdb_configure_has_option "$source_dir" --with-debuginfod && printf '%s\n' --with-debuginfod
    if gdb_configure_has_option "$source_dir" --enable-source-highlight; then
        if [ "$GDB_SOURCE_HIGHLIGHT_RELOCATABLE" = true ]; then
            printf '%s\n' --enable-source-highlight
        else
            printf '%s\n' --disable-source-highlight
        fi
    fi
    gdb_configure_has_option "$source_dir" --with-xxhash && printf '%s\n' --with-xxhash
    gdb_configure_has_option "$source_dir" --with-babeltrace && printf '%s\n' --with-babeltrace
    if gdb_configure_has_option "$source_dir" --with-intel-pt; then
        if [ "$HOST_PLATFORM" = linux-x64 ]; then
            printf '%s\n' --with-intel-pt
        else
            printf '%s\n' --without-intel-pt
        fi
    fi
}

gdb_supports_python() {
    local gdb_bin="$PREFIX/bin/gdb"
    local output

    if is_windows_platform "$HOST_PLATFORM"; then
        gdb_bin="$PREFIX/bin/gdb.exe"
    fi

    [ -x "$gdb_bin" ] || {
        printf '%s\n' false
        return 0
    }

    if output="$($gdb_bin -q -batch -ex 'python import sys, gdb; print("python-ok")' 2>/dev/null)" \
        && printf '%s\n' "$output" | grep -F 'python-ok' >/dev/null; then
        printf '%s\n' true
    else
        printf '%s\n' false
    fi
}

gdb_supports_tui() {
    local gdb_bin
    local output

    gdb_bin="$PREFIX/bin/gdb"
    if is_windows_platform "$HOST_PLATFORM"; then
        gdb_bin="$PREFIX/bin/gdb.exe"
    fi

    [ -x "$gdb_bin" ] || {
        printf '%s\n' false
        return 0
    }

    if output="$(LC_ALL=C "$gdb_bin" -q -batch -ex 'help tui' 2>&1)" \
        && ! printf '%s\n' "$output" | grep -F 'Undefined command' >/dev/null \
        && printf '%s\n' "$output" | grep -Ei 'text user interface|^tui[[:space:]]+--' >/dev/null; then
        printf '%s\n' true
    else
        printf '%s\n' false
    fi
}

validate_gdb_required_features() {
    if [ "$(gdb_supports_python)" != "true" ]; then
        die "required GDB Python support is not working"
    fi
    if [ "$(gdb_supports_tui)" != "true" ]; then
        die "required GDB TUI support is not working"
    fi
}


package_gdb_source_highlight_data() {
    local source_dir=/usr/share/source-highlight

    is_linux_platform "$HOST_PLATFORM" || return 0
    [ "$(gdb_config_bool HAVE_SOURCE_HIGHLIGHT)" = true ] || return 0
    [ "$GDB_SOURCE_HIGHLIGHT_RELOCATABLE" = true ] ||
        die "GDB was built with Source Highlight but its package data path is not relocatable"

    [ -d "$source_dir" ] || die "GDB Source Highlight runtime data missing: $source_dir"
    [ -f "$source_dir/lang.map" ] || die "GDB Source Highlight lang.map missing: $source_dir"

    mkdir -p "$PREFIX/share/gdb/source-highlight"
    cp -RPp "$source_dir/." "$PREFIX/share/gdb/source-highlight/"
}

build_gdb() {
    local source_dir="$1"
    local build_dir="$CUP_BUILD_DIR/gdb-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local python_cmd
    local configure_args=(--prefix="$PREFIX")
    local feature_args=()

    GDB_BUILD_DIR="$build_dir"

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        die "cross GDB is not supported by this build recipe yet: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi

    python_cmd="$(python_command)"
    gdb_configure_has_option "$source_dir" --disable-werror && configure_args+=(--disable-werror)
    configure_args+=(--with-python="$python_cmd")

    # Options owned by gdb/configure are not necessarily advertised by the
    # top-level Binutils/GDB configure script. Query their real owner, while
    # keeping top-level component-library options at the top level.
    for option in --with-python-libdir --enable-tui --with-curses --with-expat \
                  --with-system-readline --with-lzma; do
        gdb_subconfigure_has_option "$source_dir" "$option" || continue
        case "$option" in
            --with-python-libdir)
                configure_args+=(--with-python-libdir="$PREFIX/lib")
                ;;
            --with-system-readline)
                configure_args+=("$option")
                GDB_READLINE_POLICY=system
                ;;
            *)
                configure_args+=("$option")
                ;;
        esac
    done

    if gdb_configure_has_option "$source_dir" --with-system-zlib; then
        configure_args+=(--with-system-zlib)
        GDB_ZLIB_POLICY=true
    fi
    gdb_configure_has_option "$source_dir" --with-zstd && configure_args+=(--with-zstd)

    if ! is_windows_platform "$HOST_PLATFORM"; then
        mapfile -t feature_args < <(gdb_linux_feature_configure_args "$source_dir")
        configure_args+=("${feature_args[@]}")
    fi

    log "building GDB $VERSION for $HOST_PLATFORM"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    (
        cd "$build_dir"
        "$source_dir/configure" "${configure_args[@]}"
        make -j"$CUP_JOBS"
        make install
    )

    if is_windows_platform "$HOST_PLATFORM"; then
        need strip
        need objdump
        strip --strip-debug "$PREFIX/bin/gdb.exe"
        if objdump -h "$PREFIX/bin/gdb.exe" | grep -Eq '[[:space:]]\.debug_'; then
            die "GDB Windows executable retains debug-only sections after stripping"
        fi
        copy_windows_python_runtime
        copy_windows_runtime_dlls "$PREFIX/bin"
        verify_windows_runtime_dlls "$PREFIX/bin"
    else
        package_gdb_source_highlight_data
        copy_posix_python_runtime "$python_cmd"
    fi

    validate_gdb_required_features
}


copy_path_into_seed() {
    local relative="$1"
    local source="$PREFIX/$relative"
    local destination="$PACKAGE_PREFIX/$relative"

    [ -e "$source" ] || [ -L "$source" ] || return 0
    mkdir -p "$(dirname "$destination")"
    cp -RPp "$source" "$destination"
}

prepare_gdb_package_seed() {
    local locale_file
    local python_dir
    local runtime_file
    local relative

    PACKAGE_PREFIX="$CUP_STAGE_DIR/${PACKAGE_VERSION}-gdb-$HOST_PLATFORM-package-seed"
    rm -rf "$PACKAGE_PREFIX"
    mkdir -p "$PACKAGE_PREFIX/bin" "$PACKAGE_PREFIX/lib" "$PACKAGE_PREFIX/share"

    if is_windows_platform "$HOST_PLATFORM"; then
        copy_path_into_seed bin/gdb.exe
        copy_path_into_seed bin/gdbserver.exe

        # Windows runtime closure has already converged in PREFIX/bin. Preserve
        # those closed DLL edges and Python path configuration in the minimal seed.
        while IFS= read -r -d '' runtime_file; do
            relative="${runtime_file#"$PREFIX/"}"
            mkdir -p "$PACKAGE_PREFIX/$(dirname "$relative")"
            cp -p "$runtime_file" "$PACKAGE_PREFIX/$relative"
        done < <(find "$PREFIX/bin" -maxdepth 1 -type f \
            \( -iname '*.dll' -o -iname '*._pth' \) -print0)
    else
        copy_path_into_seed bin/gdb
        copy_path_into_seed bin/gdbserver
    fi

    copy_path_into_seed share/gdb
    copy_path_into_seed info.txt

    while IFS= read -r -d '' locale_file; do
        relative="${locale_file#"$PREFIX/"}"
        mkdir -p "$PACKAGE_PREFIX/$(dirname "$relative")"
        cp -p "$locale_file" "$PACKAGE_PREFIX/$relative"
    done < <(find "$PREFIX/share/locale" -type f -path '*/LC_MESSAGES/gdb.mo' -print0 2>/dev/null || true)

    for python_dir in "$PREFIX"/lib/python[0-9]*; do
        [ -d "$python_dir" ] || continue
        copy_path_into_seed "lib/$(basename "$python_dir")"
    done

    if is_windows_platform "$HOST_PLATFORM"; then
        [ -x "$PACKAGE_PREFIX/bin/gdb.exe" ] || die "GDB package seed is missing bin/gdb.exe"
        [ -x "$PACKAGE_PREFIX/bin/gdbserver.exe" ] || die "GDB package seed is missing bin/gdbserver.exe"
    else
        [ -x "$PACKAGE_PREFIX/bin/gdb" ] || die "GDB package seed is missing bin/gdb"
        [ -x "$PACKAGE_PREFIX/bin/gdbserver" ] || die "GDB package seed is missing bin/gdbserver"
    fi
    [ -f "$PACKAGE_PREFIX/info.txt" ] || die "GDB package seed is missing info.txt"
    [ -d "$PACKAGE_PREFIX/share/gdb" ] || die "GDB package seed is missing share/gdb"
}


write_gdb_info() {
    local debuginfod
    local source_highlight
    local xxhash
    local babeltrace
    local intel_pt
    local expat
    local zlib
    local lzma
    local zstd
    local has_gdb
    local has_gdbserver
    local has_python
    local has_tui

    debuginfod="$(gdb_config_bool HAVE_LIBDEBUGINFOD)"
    source_highlight="$(gdb_config_bool HAVE_SOURCE_HIGHLIGHT)"
    xxhash="$(gdb_config_bool HAVE_LIBXXHASH)"
    babeltrace="$(gdb_config_bool HAVE_LIBBABELTRACE)"
    intel_pt="$(gdb_config_bool HAVE_LIBIPT)"
    expat="$(gdb_config_bool HAVE_LIBEXPAT)"
    zlib="$GDB_ZLIB_POLICY"
    lzma="$(gdb_config_bool HAVE_LIBLZMA)"
    zstd="$(gdb_config_bool HAVE_ZSTD)"

    has_gdb="$(metadata_bool_for_executable "$PREFIX" gdb)"
    has_gdbserver="$(metadata_bool_for_executable "$PREFIX" gdbserver)"
    has_python="$(gdb_supports_python)"
    has_tui="$(gdb_supports_tui)"

    local info=(
        "package.component=$COMPONENT"
        "package.tool=$TOOL"
        "package.version=$PACKAGE_VERSION"
        "package.mode=self-contained"
        "package.formats=$(package_formats_csv "$HOST_PLATFORM")"
        "platform.host=$HOST_PLATFORM"
        "platform.target=$TARGET_PLATFORM"
        "platform.host_triple=$HOST_TRIPLE"
        "platform.target_triple=$TARGET_TRIPLE"
        "platform.family=$TARGET_FAMILY"
        "platform.runtime=$TARGET_RUNTIME"
        "platform.thread_model=$THREAD_MODEL"
        "build.environment=$BUILD_ENVIRONMENT"
        "build.source_policy=$SOURCE_POLICY"
        "source.primary.name=gdb"
        "source.primary.version=$VERSION"
        "source.primary.url=$SOURCE_URL"
        "source.primary.sha256=$(source_archive_sha256 "$SOURCE_URL" "gdb-$VERSION.tar.xz")"
        "config.cross=false"
        "config.python=$has_python"
        "config.tui=$has_tui"
        "config.readline=$GDB_READLINE_POLICY"
        "config.expat=$expat"
        "config.zlib=$zlib"
        "config.lzma=$lzma"
        "config.zstd=$zstd"
        "config.debuginfod=$debuginfod"
        "config.source_highlight=$source_highlight"
        "config.xxhash=$xxhash"
        "config.babeltrace=$babeltrace"
        "config.intel_pt=$intel_pt"
        "$(info_required_entry entry.gdb "$PREFIX" gdb)"
        "$(info_required_entry entry.gdbserver "$PREFIX" gdbserver)"
        "contents.uses_python=$has_python"
        "contents.python_runtime=packaged"
        "contents.python_runtime.version=$PACKAGED_PYTHON_RUNTIME_VERSION"
        "contents.uses_readline=true"
        "contents.uses_expat=$expat"
        "contents.uses_zlib=$zlib"
        "contents.uses_lzma=$lzma"
        "contents.uses_zstd=$zstd"
        "contents.uses_debuginfod=$debuginfod"
        "contents.uses_source_highlight=$source_highlight"
        "contents.uses_xxhash=$xxhash"
        "contents.uses_babeltrace=$babeltrace"
        "contents.uses_intel_pt=$intel_pt"
        "features.debug_native=$has_gdb"
        "features.breakpoints=$has_gdb"
        "features.backtrace=$has_gdb"
        "features.python=$has_python"
        "features.tui=$has_tui"
        "features.gdbserver=$has_gdbserver"
        "features.remote_debugging=$has_gdbserver"
        "features.debuginfod=$debuginfod"
        "features.source_highlight=$source_highlight"
    )

    write_info_file "$PREFIX" "${info[@]}"
}


main() {
    validate_platforms
    make_dirs
    need_common_tools
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"

    local source_dir
    source_dir="$(prepare_source_tree gdb "$VERSION" "$SOURCE_URL" "gdb-$VERSION.tar.xz" "${CUP_SOURCE_SHA256:-}")"
    if is_linux_platform "$HOST_PLATFORM"; then
        relocate_gdb_source_highlight_data "$source_dir"
    fi

    build_gdb "$source_dir"
    write_gdb_info
    prepare_gdb_package_seed
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PACKAGE_PREFIX"
}

main "$@"
