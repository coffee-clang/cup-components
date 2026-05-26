#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/package/package-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 <version|stable|latest> <host_platform> <target_platform> <revision>

Examples:
  $0 stable windows-x64 windows-x64 1
  $0 2.6.0 windows-x64 windows-x64 1
USAGE
}

if [ "$#" -ne 4 ]; then
    usage >&2
    exit 2
fi

REQUESTED_VERSION="$1"
HOST_PLATFORM="$2"
TARGET_PLATFORM="$3"
REVISION="$4"

TOOL="drmemory"
COMPONENT="analyzer"
VERSION="$(resolve_version drmemory "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"
BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="binary-release"
SOURCE_URL="$(source_url_drmemory_windows "$VERSION")"
PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

need_drmemory_tools() {
    need curl
    need unzip
    need zip
    need tar
}

validate_platforms() {
    if [ "$HOST_PLATFORM" != "windows-x64" ] || [ "$TARGET_PLATFORM" != "windows-x64" ]; then
        die "Dr. Memory packages are currently supported only for windows-x64 -> windows-x64"
    fi

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        die "cross Dr. Memory packages are not supported: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi
}

find_drmemory_root() {
    local extracted="$1"
    local found

    found="$(find "$extracted" -maxdepth 2 -type f -iname 'drmemory.exe' -print -quit)"
    if [ -z "$found" ]; then
        die "could not find drmemory.exe in extracted Dr. Memory archive"
    fi

    dirname "$(dirname "$found")"
}

stage_drmemory() {
    local archive="$CUP_SRC_DIR/$(archive_name_from_url "$SOURCE_URL" "DrMemory-Windows-$VERSION.zip")"
    local extracted="$CUP_BUILD_DIR/drmemory-extract-$VERSION"
    local source_root

    fetch "$SOURCE_URL" "$archive"

    rm -rf "$extracted" "$PREFIX"
    mkdir -p "$extracted" "$PREFIX"

    unzip -q "$archive" -d "$extracted"
    source_root="$(find_drmemory_root "$extracted")"

    log "staging Dr. Memory from $source_root"
    cp -a "$source_root"/. "$PREFIX"/

    if [ ! -x "$PREFIX/bin/drmemory.exe" ] && [ -f "$PREFIX/bin/drmemory.exe" ]; then
        chmod +x "$PREFIX/bin/drmemory.exe"
    fi
}

write_drmemory_info() {
    local has_drmemory
    local has_drconfig
    local has_symquery
    local has_drstrace
    local has_dynamorio
    local has_docs

    has_drmemory="$(metadata_bool_for_executable "$PREFIX" drmemory)"
    has_drconfig="$(metadata_bool_for_executable "$PREFIX" drconfig)"
    has_symquery="$(metadata_bool_for_executable "$PREFIX" symquery)"
    has_drstrace="$(metadata_bool_for_executable "$PREFIX" drstrace)"
    has_dynamorio="$(metadata_bool_for_dirs "$PREFIX" 'dynamorio')"
    has_docs="$(metadata_bool_for_dirs "$PREFIX" 'docs' 'doc')"

    local info=(
        "package.component=$COMPONENT"
        "package.tool=$TOOL"
        "package.version=$PACKAGE_VERSION"
        "package.revision=$REVISION"
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
        "source.primary.name=drmemory"
        "source.primary.version=$VERSION"
        "source.primary.url=$SOURCE_URL"
        "entry.drmemory=$(package_bin_entry_path "$PREFIX" drmemory)"
        "entry.drconfig=$(package_bin_entry_path "$PREFIX" drconfig)"
        "entry.symquery=$(package_bin_entry_path "$PREFIX" symquery)"
        "entry.drstrace=$(package_bin_entry_path "$PREFIX" drstrace)"
        "contents.self_contained=true"
        "contents.dynamorio=$has_dynamorio"
        "contents.docs=$has_docs"
        "features.memory_check=$has_drmemory"
        "features.leak_check=$has_drmemory"
        "features.heap_check=$has_drmemory"
        "features.uninitialized_read_check=$has_drmemory"
        "features.handle_leak_check=$has_drmemory"
        "features.gdi_check=$has_drmemory"
        "features.drconfig=$has_drconfig"
        "features.symquery=$has_symquery"
        "features.drstrace=$has_drstrace"
    )

    write_info_file "$PREFIX" "${info[@]}"
}

main() {
    validate_platforms
    make_dirs
    need_drmemory_tools

    stage_drmemory
    write_drmemory_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
