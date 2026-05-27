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
SOURCE_POLICY="source-release"
SOURCE_URL="${CUP_DRMEMORY_GIT_URL:-https://github.com/DynamoRIO/drmemory.git}"
SOURCE_REF="${CUP_DRMEMORY_GIT_REF:-release_$VERSION}"
PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

need_drmemory_tools() {
    need git
    need cmake
    need ninja
    need clang
    need clang++
    need python
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

prepare_drmemory_source() {
    local source_dir="$CUP_SRC_DIR/drmemory-$VERSION"

    if [ ! -d "$source_dir/.git" ]; then
        rm -rf "$source_dir"
        log "cloning Dr. Memory source: $SOURCE_URL"
        git clone "$SOURCE_URL" "$source_dir"
    fi

    (
        cd "$source_dir"
        git fetch --tags --force
        git checkout "$SOURCE_REF"
        git submodule update --init --recursive

        if [ -x make/git/devsetup.sh ]; then
            make/git/devsetup.sh
        fi
    )

    printf '%s\n' "$source_dir"
}

drmemory_cmake_args() {
    local source_dir="$1"
    local install_dir="$2"

    printf '%s\n' \
        -S "$source_dir" \
        -B "$CUP_BUILD_DIR/drmemory-$VERSION" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_MAKE_PROGRAM=ninja \
        -DTOOL_DR_HEAPSTAT=OFF \
        -DBUILD_VISUALIZER=OFF \
        -DBUILD_DOCS=OFF \
        -DDynamoRIO_BUILD_DOCS=OFF \
        -DCMAKE_RULE_MESSAGES=OFF
}

find_drmemory_runtime_root() {
    local root="$1"
    local found
    local runtime_root

    found="$(find "$root" -maxdepth 8 -type f \( -path '*/bin64/drmemory.exe' -o -path '*/bin/drmemory.exe' \) -print | sort | head -n 1)"
    if [ -z "$found" ]; then
        log "Dr. Memory runtime search root: $root"
        find "$root" -maxdepth 5 -print | sort | sed -n '1,200p'
        die "could not find drmemory.exe in built Dr. Memory tree"
    fi

    case "$found" in
        */bin64/drmemory.exe) runtime_root="$(dirname "$(dirname "$found")")" ;;
        */bin/drmemory.exe) runtime_root="$(dirname "$(dirname "$found")")" ;;
        *) die "internal error resolving Dr. Memory root from $found" ;;
    esac

    printf '%s\n' "$runtime_root"
}

find_built_package() {
    local build_dir="$1"
    find "$build_dir" -type f \( -iname 'DrMemory*.zip' -o -iname 'drmemory*.zip' \) -print | sort | head -n 1
}

stage_from_runtime_root() {
    local runtime_root="$1"

    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"

    log "staging Dr. Memory runtime from $runtime_root"
    cp -a "$runtime_root"/. "$PREFIX"/

    if [ ! -f "$PREFIX/bin64/drmemory.exe" ] && [ ! -f "$PREFIX/bin/drmemory.exe" ]; then
        find "$PREFIX" -maxdepth 4 -print | sort
        die "staged Dr. Memory package does not contain bin64/drmemory.exe or bin/drmemory.exe"
    fi
}

stage_from_package_zip() {
    local package_zip="$1"
    local extracted="$CUP_BUILD_DIR/drmemory-package-extract-$VERSION"
    local runtime_root

    rm -rf "$extracted"
    mkdir -p "$extracted"
    unzip -q "$package_zip" -d "$extracted"

    runtime_root="$(find_drmemory_runtime_root "$extracted")"
    stage_from_runtime_root "$runtime_root"
}

build_drmemory_from_source() {
    local source_dir
    local build_dir="$CUP_BUILD_DIR/drmemory-$VERSION"
    local install_dir="$CUP_BUILD_DIR/drmemory-install-$VERSION"
    local package_zip
    local runtime_root

    source_dir="$(prepare_drmemory_source)"

    rm -rf "$build_dir" "$install_dir"
    mkdir -p "$build_dir" "$install_dir"

    log "configuring Dr. Memory source build with CLANG64"
    cmake $(drmemory_cmake_args "$source_dir" "$install_dir")

    log "building Dr. Memory from source"
    cmake --build "$build_dir" --parallel "$CUP_JOBS"

    log "trying to create Dr. Memory package through CPack/CMake"
    if cmake --build "$build_dir" --target package --parallel "$CUP_JOBS"; then
        package_zip="$(find_built_package "$build_dir")"
        if [ -n "$package_zip" ]; then
            log "using built Dr. Memory package: $package_zip"
            stage_from_package_zip "$package_zip"
            return 0
        fi
    fi

    log "no CPack zip package found; trying CMake install"
    if cmake --install "$build_dir" --prefix "$install_dir"; then
        runtime_root="$(find_drmemory_runtime_root "$install_dir")"
        stage_from_runtime_root "$runtime_root"
        return 0
    fi

    log "CMake install did not produce a package; staging runtime files from build tree"
    runtime_root="$(find_drmemory_runtime_root "$build_dir")"
    stage_from_runtime_root "$runtime_root"
}

drmemory_entry_path() {
    local name="$1"
    local candidate

    for candidate in \
        "bin64/$name.exe" \
        "bin/$name.exe" \
        "bin64/$name" \
        "bin/$name"; do
        if [ -e "$PREFIX/$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'bin64/%s.exe\n' "$name"
}

drmemory_executable_exists() {
    local name="$1"

    [ -x "$PREFIX/bin64/$name.exe" ] || \
        [ -x "$PREFIX/bin/$name.exe" ] || \
        [ -x "$PREFIX/bin64/$name" ] || \
        [ -x "$PREFIX/bin/$name" ]
}

drmemory_executable_bool() {
    local name="$1"
    info_bool drmemory_executable_exists "$name"
}

write_drmemory_info() {
    local has_drmemory
    local has_drconfig
    local has_symquery
    local has_drstrace
    local has_dynamorio
    local has_docs

    has_drmemory="$(drmemory_executable_bool drmemory)"
    has_drconfig="$(drmemory_executable_bool drconfig)"
    has_symquery="$(drmemory_executable_bool symquery)"
    has_drstrace="$(drmemory_executable_bool drstrace)"
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
        "source.primary.ref=$SOURCE_REF"
        "entry.drmemory=$(drmemory_entry_path drmemory)"
        "entry.drconfig=$(drmemory_entry_path drconfig)"
        "entry.symquery=$(drmemory_entry_path symquery)"
        "entry.drstrace=$(drmemory_entry_path drstrace)"
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

    build_drmemory_from_source
    write_drmemory_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
