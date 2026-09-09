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
  $0 stable linux-x64 windows-x64
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

TOOL="ld"
COMPONENT="linker"
VERSION="$(resolve_version ld "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"
BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="source-release"
SOURCE_URL="$(source_url_binutils "$VERSION")"
UPSTREAM_PREFIX="$CUP_STAGE_DIR/ld-$PACKAGE_VERSION-$HOST_PLATFORM-$TARGET_PLATFORM-upstream"
PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

validate_platforms() {
    case "$HOST_PLATFORM:$TARGET_PLATFORM" in
        linux-x64:linux-x64|linux-arm64:linux-arm64|windows-x64:windows-x64|linux-x64:windows-x64) ;;
        *) die "unsupported GNU ld build combination: $HOST_PLATFORM -> $TARGET_PLATFORM" ;;
    esac
}

need_common_tools() {
    need curl
    need tar
    need make
    need zip
    need unzip
    need realpath

    if ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
        die "a host C compiler is required"
    fi
}

configure_script_for_build() {
    local source_dir="$1"
    local build_dir="$2"
    local source_ref

    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        source_ref="$(realpath --relative-to="$build_dir" "$source_dir")"
    else
        source_ref="$source_dir"
    fi

    printf '%s/configure\n' "$source_ref"
}

configure_and_build_binutils() {
    local source_dir="$1"
    local build_dir="$CUP_BUILD_DIR/ld-binutils-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_script
    local configure_args=(
        --prefix="$UPSTREAM_PREFIX"
        --disable-werror
        --disable-nls
        --without-debuginfod
        --enable-ld
        --enable-plugins
    )

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        configure_args+=(--target="$TARGET_TRIPLE")
    fi

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    configure_script="$(configure_script_for_build "$source_dir" "$build_dir")"

    log "building GNU ld from Binutils $VERSION for $HOST_PLATFORM -> $TARGET_PLATFORM"
    (
        cd "$build_dir"
        "$configure_script" "${configure_args[@]}"
        make -j"$CUP_JOBS" all-ld
        make install-ld
    )
}

ld_exe_suffix() {
    if is_windows_platform "$HOST_PLATFORM"; then
        printf '.exe\n'
    else
        printf '\n'
    fi
}

find_upstream_ld() {
    local suffix
    local candidate

    suffix="$(ld_exe_suffix)"

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        for candidate in \
            "$UPSTREAM_PREFIX/bin/$TARGET_TRIPLE-ld$suffix" \
            "$UPSTREAM_PREFIX/$TARGET_TRIPLE/bin/ld$suffix"; do
            if [ -f "$candidate" ] || [ -L "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
        die "cross GNU ld executable was not installed for target: $TARGET_TRIPLE"
    fi

    candidate="$UPSTREAM_PREFIX/bin/ld$suffix"
    if [ -f "$candidate" ] || [ -L "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    die "GNU ld executable was not installed: $candidate"
}

find_upstream_ld_bfd() {
    local suffix
    local candidate

    suffix="$(ld_exe_suffix)"
    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        for candidate in \
            "$UPSTREAM_PREFIX/bin/$TARGET_TRIPLE-ld.bfd$suffix" \
            "$UPSTREAM_PREFIX/$TARGET_TRIPLE/bin/ld.bfd$suffix"; do
            if [ -f "$candidate" ] || [ -L "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
        return 1
    fi

    candidate="$UPSTREAM_PREFIX/bin/ld.bfd$suffix"
    if [ -f "$candidate" ] || [ -L "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

copy_real_executable() {
    local source="$1"
    local destination="$2"

    mkdir -p "$(dirname "$destination")"
    cp -pL "$source" "$destination"
    chmod +x "$destination"
}

prepare_ld_package_seed() {
    local suffix
    local source_ld
    local source_ld_bfd=""
    local package_ld
    local package_ld_bfd
    local target_ld

    suffix="$(ld_exe_suffix)"
    source_ld="$(find_upstream_ld)"
    package_ld="$PREFIX/bin/ld$suffix"

    rm -rf "$PREFIX"
    mkdir -p "$PREFIX/bin"
    copy_real_executable "$source_ld" "$package_ld"

    if source_ld_bfd="$(find_upstream_ld_bfd)" && cmp -s "$source_ld" "$source_ld_bfd"; then
        package_ld_bfd="$PREFIX/bin/ld.bfd$suffix"
        if is_windows_platform "$HOST_PLATFORM"; then
            copy_real_executable "$source_ld_bfd" "$package_ld_bfd"
        else
            ln -s "ld$suffix" "$package_ld_bfd"
        fi
        log "included equivalent GNU ld.bfd compatibility entry"
    fi

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        target_ld="$PREFIX/bin/$TARGET_TRIPLE-ld$suffix"
        if is_windows_platform "$HOST_PLATFORM"; then
            copy_real_executable "$source_ld" "$target_ld"
        else
            ln -s "ld$suffix" "$target_ld"
        fi
    fi

    [ -x "$package_ld" ] || die "GNU ld package seed is missing its public linker entry"
}

write_ld_info() {
    local cross=false
    local link_elf=false
    local link_pe=false
    local has_ld_bfd
    local target_entry=""

    is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM" && cross=true
    is_linux_platform "$TARGET_PLATFORM" && link_elf=true
    is_windows_platform "$TARGET_PLATFORM" && link_pe=true
    has_ld_bfd="$(metadata_bool_for_executable "$PREFIX" ld.bfd)"

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        target_entry="$(info_required_entry entry.target_ld "$PREFIX" "$TARGET_TRIPLE-ld")"
    fi

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
        "source.primary.name=binutils"
        "source.primary.version=$VERSION"
        "source.primary.url=$SOURCE_URL"
        "source.primary.sha256=$(source_archive_sha256 "$SOURCE_URL" "binutils-$VERSION.tar.xz")"
        "config.cross=$cross"
        "config.nls=false"
        "config.debuginfod=false"
        "config.plugins=true"
        "config.target_triple=$TARGET_TRIPLE"
        "$(info_required_entry entry.ld "$PREFIX" ld)"
        "$(info_entry_if_present entry.ld_bfd "$PREFIX" ld.bfd)"
        "$target_entry"
        "contents.binutils_toolbox=false"
        "contents.gcc_lto_plugin=false"
        "contents.ld_bfd=$has_ld_bfd"
        "features.link=true"
        "features.link_elf=$link_elf"
        "features.link_pe=$link_pe"
    )

    write_info_file "$PREFIX" "${info[@]}"
}

prepare_windows_ld_runtime() {
    is_windows_platform "$HOST_PLATFORM" || return 0
    copy_windows_runtime_dlls "$PREFIX/bin"
}

main() {
    validate_platforms
    make_dirs
    need_common_tools

    rm -rf "$UPSTREAM_PREFIX" "$PREFIX"
    mkdir -p "$UPSTREAM_PREFIX" "$PREFIX"

    local source_dir
    source_dir="$(prepare_source_tree binutils "$VERSION" "$SOURCE_URL" "binutils-$VERSION.tar.xz" "${CUP_SOURCE_SHA256:-}")"

    configure_and_build_binutils "$source_dir"
    prepare_ld_package_seed
    write_ld_info
    prepare_windows_ld_runtime
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
