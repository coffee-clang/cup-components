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
  $0 stable macos-arm64 macos-arm64 1
  $0 stable macos-x64 macos-x64 1
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

TOOL="leaks"
COMPONENT="analyzer"
VERSION="$(resolve_version leaks "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"
BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="system-tool-wrapper"
PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

validate_platforms() {
    if ! is_macos_platform "$HOST_PLATFORM" || ! is_macos_platform "$TARGET_PLATFORM"; then
        die "leaks wrapper packages are supported only for macOS host/target platforms"
    fi

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        die "cross leaks wrapper packages are not supported: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi
}

stage_leaks_wrapper() {
    if [ ! -x /usr/bin/leaks ]; then
        die "/usr/bin/leaks is not available on this macOS runner"
    fi

    rm -rf "$PREFIX"
    mkdir -p "$PREFIX/bin"

    cat > "$PREFIX/bin/leaks" <<'WRAPPER'
#!/usr/bin/env sh
set -eu

if [ ! -x /usr/bin/leaks ]; then
    echo "cup leaks wrapper error: /usr/bin/leaks is not available on this system" >&2
    exit 127
fi

exec /usr/bin/leaks "$@"
WRAPPER

    chmod +x "$PREFIX/bin/leaks"
}

write_leaks_info() {
    local has_leaks
    has_leaks="$(metadata_bool_for_executable "$PREFIX" leaks)"

    local info=(
        "package.component=$COMPONENT"
        "package.tool=$TOOL"
        "package.version=$PACKAGE_VERSION"
        "package.revision=$REVISION"
        "package.mode=system-wrapper"
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
        "source.primary.name=macos-leaks"
        "source.primary.version=system"
        "source.primary.path=/usr/bin/leaks"
        "entry.leaks=bin/leaks"
        "contents.self_contained=false"
        "contents.system_tool=true"
        "contents.wrapper=true"
        "features.memory_check=$has_leaks"
        "features.leak_check=$has_leaks"
        "features.at_exit=$has_leaks"
        "features.system_tool=true"
    )

    write_info_file "$PREFIX" "${info[@]}"
}

main() {
    validate_platforms
    make_dirs
    need tar
    need zip

    stage_leaks_wrapper
    write_leaks_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
