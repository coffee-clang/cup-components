#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/package/package-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 <clang|lld|lldb|clangd|clang-format|clang-tidy> <version|stable|latest> <host_platform> <target_platform> <revision>

Examples:
  $0 clang stable linux-x64 linux-x64 1
  $0 lld stable windows-x64 windows-x64 1
  $0 lldb stable windows-x64 windows-x64 1
  $0 clangd stable linux-x64 linux-x64 1
  $0 clang-format stable linux-x64 linux-x64 1
  $0 clang-tidy stable windows-x64 windows-x64 1
USAGE
}

if [ "$#" -ne 5 ]; then
    usage >&2
    exit 2
fi

TOOL="$1"
REQUESTED_VERSION="$2"
HOST_PLATFORM="$3"
TARGET_PLATFORM="$4"
REVISION="$5"

VERSION="$(resolve_version llvm "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"
BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="source-release"
SOURCE_URL="$(source_url_llvm_project "$VERSION")"

case "$TOOL" in
    clang)
        COMPONENT="compiler"
        LLVM_PROJECTS="clang;lld"
        CONTENTS_EXTRA=("contents.includes_lld=true")
        ;;
    lld)
        COMPONENT="linker"
        LLVM_PROJECTS="lld"
        CONTENTS_EXTRA=()
        ;;
    lldb)
        COMPONENT="debugger"
        LLVM_PROJECTS="clang;lld;lldb"
        CONTENTS_EXTRA=("contents.uses_clang=true" "contents.uses_lld=true" "config.python=true" "config.libxml2=true" "config.lzma=true")
        ;;
    clangd)
        COMPONENT="language-server"
        LLVM_PROJECTS="clang;clang-tools-extra"
        CONTENTS_EXTRA=("contents.uses_clang=true")
        ;;
    clang-format)
        COMPONENT="formatter"
        LLVM_PROJECTS="clang"
        CONTENTS_EXTRA=()
        ;;
    clang-tidy)
        COMPONENT="linter"
        LLVM_PROJECTS="clang;clang-tools-extra"
        CONTENTS_EXTRA=("contents.uses_clang=true")
        ;;
    *)
        die "unsupported LLVM tool: $TOOL"
        ;;
esac

PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

need_common_tools() {
    need curl
    need tar
    need cmake
    need ninja
    need zip
}

is_kept_bin_tool() {
    local base="$1"
    shift

    local tool
    for tool in "$@"; do
        case "$base" in
            "$tool"|"$tool.exe"|"$tool.cmd"|"$tool.bat")
                return 0
                ;;
        esac
    done

    return 1
}

prune_bin_except() {
    local bin_dir="$PREFIX/bin"
    local keep_tools=("$@")
    local entry
    local base

    [ -d "$bin_dir" ] || return 0

    for entry in "$bin_dir"/*; do
        [ -e "$entry" ] || continue

        base="$(basename "$entry")"

        if is_kept_bin_tool "$base" "${keep_tools[@]}"; then
            if [ -L "$entry" ]; then
                local tmp
                tmp="$entry.tmp"
                cp -f -L "$entry" "$tmp"
                mv -f "$tmp" "$entry"
                chmod +x "$entry"
            fi
            continue
        fi

        if [ -f "$entry" ] || [ -L "$entry" ]; then
            rm -f "$entry"
        fi
    done
}

prune_llvm_package_bins() {
    case "$TOOL" in
        clang)
            prune_bin_except \
                clang clang++ clang-cpp clang-cl clang-scan-deps \
                lld ld.lld lld-link wasm-ld \
                llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-objdump llvm-readelf \
                llvm-strip llvm-size llvm-strings llvm-lib llvm-dlltool llvm-rc
            ;;
        lld)
            prune_bin_except \
                lld ld.lld lld-link wasm-ld
            ;;
        lldb)
            prune_bin_except \
                lldb lldb-server lldb-dap lldb-vscode
            ;;
        clangd)
            prune_bin_except \
                clangd clangd-indexer
            ;;
        clang-format)
            prune_bin_except \
                clang-format git-clang-format
            ;;
        clang-tidy)
            prune_bin_except \
                clang-tidy clang-apply-replacements run-clang-tidy clang-tidy-diff
            ;;
    esac
}

build_llvm_tool() {
    local source_dir="$1"
    local build_dir="$CUP_BUILD_DIR/llvm-$TOOL-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local cmake_extra_args=()

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        die "cross LLVM tool builds are not supported by this recipe yet: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi

    if [ "$TOOL" = "lldb" ]; then
        cmake_extra_args+=(
            -DLLDB_ENABLE_PYTHON=ON
            -DLLDB_ENABLE_LIBXML2=ON
            -DLLDB_ENABLE_LZMA=ON
        )

        if [ "$HOST_PLATFORM" = "windows-x64" ]; then
            cmake_extra_args+=(
                -DLLDB_ENABLE_LIBEDIT=OFF
                -DLLDB_ENABLE_CURSES=OFF
            )
        else
            cmake_extra_args+=(
                -DLLDB_ENABLE_LIBEDIT=ON
                -DLLDB_ENABLE_CURSES=ON
            )
        fi
    fi

    log "building LLVM tool $TOOL $VERSION with projects: $LLVM_PROJECTS"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        cmake_extra_args+=(
            -DCMAKE_C_COMPILER=clang
            -DCMAKE_CXX_COMPILER=clang++
        )
    fi

    cmake -S "$source_dir/llvm" -B "$build_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLDB_INCLUDE_TESTS=OFF \
        "${cmake_extra_args[@]}"

    log "selected LLVM CMake cache entries:"
    if [ -f "$build_dir/CMakeCache.txt" ]; then
        grep -E '^(LLVM_ENABLE_PROJECTS|LLVM_TARGETS_TO_BUILD|LLVM_ENABLE_ZLIB|LLVM_ENABLE_ZSTD|LLVM_ENABLE_LIBXML2|LLDB_ENABLE_PYTHON|LLDB_ENABLE_LIBXML2|LLDB_ENABLE_LZMA|LLDB_ENABLE_LIBEDIT|LLDB_ENABLE_CURSES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER):' "$build_dir/CMakeCache.txt" || true
    fi

    cmake --build "$build_dir" --parallel "$CUP_JOBS"
    cmake --install "$build_dir"

    prune_llvm_package_bins
    copy_windows_runtime_dlls "$PREFIX/bin"
}

write_llvm_info() {
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
        "source.primary.name=llvm-project"
        "source.primary.version=$VERSION"
        "source.primary.url=$SOURCE_URL"
        "config.llvm_projects=$LLVM_PROJECTS"
        "config.llvm_targets=X86"
        "contents.self_contained=true"
    )

    info+=("${CONTENTS_EXTRA[@]}")

    if [ "$TOOL" = "lldb" ]; then
        if [ "$HOST_PLATFORM" = "windows-x64" ]; then
            info+=("config.libedit=false" "config.curses=false")
        else
            info+=("config.libedit=true" "config.curses=true")
        fi
    fi

    write_info_file "$PREFIX" "${info[@]}"
}

main() {
    make_dirs
    need_common_tools
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"

    local source_dir
    source_dir="$(prepare_source_tree llvm-project "$VERSION" "$SOURCE_URL" "llvm-project-$VERSION.src.tar.xz")"

    build_llvm_tool "$source_dir"
    write_llvm_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
