#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/package/package-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 <version|stable> <host_platform> <target_platform>

Examples:
  $0 stable linux-x64 linux-x64
  $0 stable windows-x64 windows-x64
USAGE
}

if [ "$#" -ne 3 ]; then
    usage >&2
    exit 2
fi

REQUESTED_VERSION="$1"
HOST_PLATFORM="$2"
TARGET_PLATFORM="$3"
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

validate_platforms() {
    case "$HOST_PLATFORM:$TARGET_PLATFORM" in
        linux-x64:linux-x64|linux-arm64:linux-arm64|windows-x64:windows-x64) ;;
        *) die "unsupported GDB build combination: $HOST_PLATFORM -> $TARGET_PLATFORM" ;;
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

    if ! python_command >/dev/null 2>&1; then
        die "python3 or python is required to build GDB with Python support"
    fi

    if ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
        die "a host C compiler is required"
    fi
}

gdb_linux_feature_configure_args() {
    printf '%s\n' \
        --with-debuginfod \
        --enable-source-highlight \
        --with-xxhash \
        --with-babeltrace

    if [ "$HOST_PLATFORM" = "linux-x64" ] && [ "$TARGET_PLATFORM" = "linux-x64" ]; then
        printf '%s\n' --with-intel-pt
    else
        printf '%s\n' --without-intel-pt
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

build_gdb() {
    local source_dir="$1"
    local build_dir="$CUP_BUILD_DIR/gdb-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local python_cmd
    local feature_args=()
    local python_args=()

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        die "cross GDB is not supported by this build recipe yet: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi

    python_cmd="$(python_command)"
    if ! is_windows_platform "$HOST_PLATFORM"; then
        mapfile -t feature_args < <(gdb_linux_feature_configure_args)
        python_args+=(--with-python-libdir="$PREFIX/lib")
    fi

    log "building GDB $VERSION for $HOST_PLATFORM"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    (
        cd "$build_dir"
        "$source_dir/configure" \
            --prefix="$PREFIX" \
            --disable-werror \
            --with-python="$python_cmd" \
            "${python_args[@]}" \
            --enable-tui \
            --with-curses \
            --with-expat \
            --with-system-readline \
            --with-system-zlib \
            --with-lzma \
            --with-zstd \
            "${feature_args[@]}"
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
        copy_posix_python_runtime "$python_cmd"
    fi

    validate_gdb_required_features
}

write_gdb_info() {
    local debuginfod=false
    local source_highlight=false
    local xxhash=false
    local babeltrace=false
    local intel_pt=false
    local has_gdb
    local has_gdbserver
    local has_python
    local has_tui

    if ! is_windows_platform "$HOST_PLATFORM"; then
        debuginfod=true
        source_highlight=true
        xxhash=true
        babeltrace=true
        if [ "$HOST_PLATFORM" = "linux-x64" ] && [ "$TARGET_PLATFORM" = "linux-x64" ]; then
            intel_pt=true
        fi
    fi

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
        "config.cross=false"
        "config.python=$has_python"
        "config.tui=$has_tui"
        "config.readline=system"
        "config.expat=true"
        "config.zlib=true"
        "config.lzma=true"
        "config.zstd=true"
        "config.debuginfod=$debuginfod"
        "config.source_highlight=$source_highlight"
        "config.xxhash=$xxhash"
        "config.babeltrace=$babeltrace"
        "config.intel_pt=$intel_pt"
        "$(info_required_entry entry.gdb "$PREFIX" gdb)"
        "$(info_entry_if_present entry.gdbserver "$PREFIX" gdbserver)"
        "contents.uses_python=$has_python"
        "contents.python_runtime=packaged"
        "contents.uses_readline=true"
        "contents.uses_expat=true"
        "contents.uses_zlib=true"
        "contents.uses_lzma=true"
        "contents.uses_zstd=true"
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
    source_dir="$(prepare_source_tree gdb "$VERSION" "$SOURCE_URL" "gdb-$VERSION.tar.xz")"

    build_gdb "$source_dir"
    write_gdb_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
