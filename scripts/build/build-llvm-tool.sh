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
        CONTENTS_EXTRA=("contents.uses_clang=true" "contents.uses_lld=true")
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

llvm_targets_to_build() {
    if [ -n "${CUP_LLVM_TARGETS_TO_BUILD:-}" ]; then
        printf '%s\n' "$CUP_LLVM_TARGETS_TO_BUILD"
        return 0
    fi

    case "$TARGET_PLATFORM" in
        linux-x64|windows-x64|macos-x64)
            printf '%s\n' "X86"
            ;;
        linux-arm64|macos-arm64)
            printf '%s\n' "AArch64"
            ;;
        *)
            die "unsupported LLVM target platform for backend selection: $TARGET_PLATFORM"
            ;;
    esac
}

llvm_target_enabled() {
    local target="$1"

    case ";$LLVM_TARGETS;" in
        *";$target;"*) return 0 ;;
        *) return 1 ;;
    esac
}

llvm_target_feature_bool() {
    local target="$1"

    if llvm_target_enabled "$target"; then
        printf '%s\n' true
    else
        printf '%s\n' false
    fi
}

LLVM_TARGETS="$(llvm_targets_to_build)"

llvm_runtimes_for_tool() {
    case "$TOOL" in
        clang)
            printf '%s\n' "compiler-rt;libunwind;libcxxabi;libcxx"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

LLVM_RUNTIMES="$(llvm_runtimes_for_tool)"
LLVM_RUNTIME_BUILD_DIR=""

llvm_runtimes_enabled() {
    case "${CUP_LLVM_ENABLE_RUNTIMES:-auto}" in
        auto|on|yes|true|1)
            [ "$TOOL" = "clang" ] && [ -n "$LLVM_RUNTIMES" ]
            ;;
        off|no|false|0)
            return 1
            ;;
        *)
            die "unsupported CUP_LLVM_ENABLE_RUNTIMES value: ${CUP_LLVM_ENABLE_RUNTIMES:-}"
            ;;
    esac
}

llvm_common_cmake_args() {
    printf '%s\n' \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_BUILD_DOCS=OFF \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_ENABLE_ASSERTIONS=OFF
}

macos_sdk_path() {
    if is_macos_platform "$HOST_PLATFORM" && command -v xcrun >/dev/null 2>&1; then
        xcrun --sdk macosx --show-sdk-path
    fi
}

llvm_dump_cmake_cache_entries() {
    local cache_file="$1"
    local pattern="$2"

    [ -f "$cache_file" ] || return 0
    grep -E "$pattern" "$cache_file" || true
}

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

        if is_windows_platform "$HOST_PLATFORM"; then
            case "$base" in
                *.dll)
                    continue
                    ;;
            esac
        fi

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

copy_clang_sanitizer_runtime_dlls() {
    local dll
    local bin_dir="$PREFIX/bin"

    if ! is_windows_platform "$HOST_PLATFORM" || [ "$TOOL" != "clang" ]; then
        return 0
    fi

    [ -d "$PREFIX" ] || return 0
    mkdir -p "$bin_dir"

    log "copying Clang sanitizer runtime DLLs to bin"

    while IFS= read -r dll; do
        [ -n "$dll" ] || continue
        [ -f "$dll" ] || continue

        if [ ! -f "$bin_dir/$(basename "$dll")" ]; then
            cp -f "$dll" "$bin_dir/$(basename "$dll")"
            log "  copied sanitizer runtime: $(basename "$dll")"
        fi
    done < <(find "$PREFIX" -type f \
        \( -name 'clang_rt.asan*.dll' -o \
           -name 'clang_rt.ubsan*.dll' -o \
           -name 'clang_rt.profile*.dll' \) | sort)
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
                lld ld.lld lld-link wasm-ld ld64.lld
            ;;
        lldb)
            prune_bin_except \
                lldb lldb-server lldb-dap lldb-vscode lldb-argdumper
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

build_llvm_runtimes() {
    local source_dir="$1"
    local tool_build_dir="$2"
    local runtime_build_dir="$CUP_BUILD_DIR/llvm-$TOOL-runtimes-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local exe_suffix
    local clang_c
    local clang_cxx
    local llvm_ar
    local llvm_ranlib
    local llvm_nm
    local llvm_linker
    local cmake_runtime_args=()
    local sdk_path

    if ! llvm_runtimes_enabled; then
        return 0
    fi

    if is_windows_platform "$HOST_PLATFORM"; then
        exe_suffix=".exe"
    else
        exe_suffix=""
    fi

    clang_c="$tool_build_dir/bin/clang$exe_suffix"
    clang_cxx="$tool_build_dir/bin/clang++$exe_suffix"
    llvm_ar="$tool_build_dir/bin/llvm-ar$exe_suffix"
    llvm_ranlib="$tool_build_dir/bin/llvm-ranlib$exe_suffix"
    llvm_nm="$tool_build_dir/bin/llvm-nm$exe_suffix"
    llvm_linker="$tool_build_dir/bin/ld.lld$exe_suffix"

    [ -x "$clang_c" ] || die "just-built clang not found: $clang_c"
    [ -x "$clang_cxx" ] || die "just-built clang++ not found: $clang_cxx"

    LLVM_RUNTIME_BUILD_DIR="$runtime_build_dir"
    log "building LLVM runtimes for $TOOL $VERSION: $LLVM_RUNTIMES"

    rm -rf "$runtime_build_dir"
    mkdir -p "$runtime_build_dir"

    cmake_runtime_args+=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_C_COMPILER="$clang_c"
        -DCMAKE_CXX_COMPILER="$clang_cxx"
        -DCMAKE_C_COMPILER_TARGET="$HOST_TRIPLE"
        -DCMAKE_CXX_COMPILER_TARGET="$HOST_TRIPLE"
        -DLLVM_DEFAULT_TARGET_TRIPLE="$HOST_TRIPLE"
        -DLLVM_ENABLE_RUNTIMES="$LLVM_RUNTIMES"
        -DCOMPILER_RT_BUILD_BUILTINS=ON
        -DCOMPILER_RT_BUILD_SANITIZERS=ON
        -DCOMPILER_RT_BUILD_PROFILE=ON
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
        -DCOMPILER_RT_USE_LIBCXX=ON
        -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF
        -DLIBUNWIND_ENABLE_SHARED=OFF
        -DLIBUNWIND_ENABLE_STATIC=ON
        -DLIBUNWIND_USE_COMPILER_RT=ON
        -DLIBCXXABI_ENABLE_SHARED=OFF
        -DLIBCXXABI_ENABLE_STATIC=ON
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON
        -DLIBCXXABI_USE_COMPILER_RT=ON
        -DLIBCXX_ENABLE_SHARED=OFF
        -DLIBCXX_ENABLE_STATIC=ON
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
        -DLIBCXX_USE_COMPILER_RT=ON
    )

    [ -x "$llvm_ar" ] && cmake_runtime_args+=(-DCMAKE_AR="$llvm_ar")
    [ -x "$llvm_ranlib" ] && cmake_runtime_args+=(-DCMAKE_RANLIB="$llvm_ranlib")
    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_runtime_args+=("$arg")
    done < <(llvm_common_cmake_args)

    [ -x "$llvm_nm" ] && cmake_runtime_args+=(-DCMAKE_NM="$llvm_nm")

    if ! is_macos_platform "$HOST_PLATFORM" && [ -x "$llvm_linker" ]; then
        cmake_runtime_args+=(
            -DLLVM_ENABLE_LLD=ON
            -DCMAKE_LINKER="$llvm_linker"
        )
    fi

    if is_windows_platform "$HOST_PLATFORM"; then
        [ -n "${MINGW_PREFIX:-}" ] || die "MINGW_PREFIX is not set; run this build inside an MSYS2 CLANG64 environment"
        cmake_runtime_args+=(
            -DCMAKE_SYSROOT="$MINGW_PREFIX"
            -DCMAKE_SYSTEM_IGNORE_PATH=/usr/lib
        )
    elif is_macos_platform "$HOST_PLATFORM"; then
        sdk_path="$(macos_sdk_path)"
        if [ -n "$sdk_path" ]; then
            cmake_runtime_args+=(
                -DCMAKE_OSX_SYSROOT="$sdk_path"
            )
        fi
    fi

    cmake -S "$source_dir/runtimes" -B "$runtime_build_dir" -G Ninja \
        "${cmake_runtime_args[@]}"

    log "selected LLVM runtimes CMake cache entries:"
    if [ -f "$runtime_build_dir/CMakeCache.txt" ]; then
        llvm_dump_cmake_cache_entries "$runtime_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|LLVM_DEFAULT_TARGET_TRIPLE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_C_COMPILER_TARGET|CMAKE_CXX_COMPILER_TARGET|CMAKE_SYSROOT|CMAKE_OSX_SYSROOT|CMAKE_LINKER|LLVM_ENABLE_LLD|LLVM_INCLUDE_TESTS|LLVM_INCLUDE_BENCHMARKS|LLVM_INCLUDE_DOCS|LLVM_ENABLE_BINDINGS|LLVM_ENABLE_ASSERTIONS|COMPILER_RT_BUILD_BUILTINS|COMPILER_RT_BUILD_SANITIZERS|COMPILER_RT_BUILD_PROFILE|COMPILER_RT_BUILD_LIBFUZZER|COMPILER_RT_USE_BUILTINS_LIBRARY|COMPILER_RT_USE_LIBCXX|COMPILER_RT_DEFAULT_TARGET_ONLY|LIBUNWIND_ENABLE_SHARED|LIBUNWIND_ENABLE_STATIC|LIBUNWIND_USE_COMPILER_RT|LIBCXXABI_ENABLE_SHARED|LIBCXXABI_ENABLE_STATIC|LIBCXXABI_USE_LLVM_UNWINDER|LIBCXXABI_USE_COMPILER_RT|LIBCXX_ENABLE_SHARED|LIBCXX_ENABLE_STATIC|LIBCXX_ENABLE_STATIC_ABI_LIBRARY|LIBCXX_USE_COMPILER_RT):'
    fi

    if ! cmake --build "$runtime_build_dir" --parallel "$CUP_JOBS"; then
        log "LLVM runtime build failed; selected runtime CMake cache entries:"
        llvm_dump_cmake_cache_entries "$runtime_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_SYSROOT|CMAKE_OSX_SYSROOT|COMPILER_RT_|LIBUNWIND_|LIBCXXABI_|LIBCXX_):'
        return 1
    fi
    cmake --install "$runtime_build_dir"
}

build_llvm_tool() {
    local source_dir="$1"
    local build_dir="$CUP_BUILD_DIR/llvm-$TOOL-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    LLVM_BUILD_DIR="$build_dir"
    local cmake_extra_args=()
    local cmake_common_args=()
    local sdk_path

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        die "cross LLVM tool builds are not supported by this recipe yet: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi

    if [ "$TOOL" = "lldb" ]; then
        cmake_extra_args+=(
            -DLLDB_ENABLE_PYTHON=ON
            -DLLDB_ENABLE_SWIG=ON
            -DLLDB_EMBED_PYTHON_HOME=OFF
            -DLLDB_ENABLE_LIBXML2=ON
            -DLLDB_ENABLE_LZMA=ON
        )

        if [ "$HOST_PLATFORM" = "windows-x64" ]; then
            if [ -z "${MINGW_PREFIX:-}" ]; then
                die "MINGW_PREFIX is not set; run this build inside an MSYS2 MinGW/UCRT environment"
            fi

            cmake_extra_args+=(
                -DLLDB_ENABLE_LIBEDIT=OFF
                -DLLDB_ENABLE_CURSES=OFF
                -DPython3_EXECUTABLE="$MINGW_PREFIX/bin/python.exe"
                -DPython3_ROOT_DIR="$MINGW_PREFIX"
                -DPython3_FIND_REGISTRY=NEVER
                -DPython3_FIND_STRATEGY=LOCATION
            )
        else
            cmake_extra_args+=(
                -DLLDB_ENABLE_LIBEDIT=ON
                -DLLDB_ENABLE_CURSES=ON
            )

            if is_macos_platform "$HOST_PLATFORM"; then
                cmake_extra_args+=(
                    -DLLDB_USE_SYSTEM_DEBUGSERVER=ON
                )
            fi
        fi
    fi

    log "building LLVM tool $TOOL $VERSION with projects: $LLVM_PROJECTS"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        cmake_extra_args+=(
            -DCMAKE_C_COMPILER=clang
            -DCMAKE_CXX_COMPILER=clang++
            -DLLVM_HOST_TRIPLE="$HOST_TRIPLE"
            -DCMAKE_SYSTEM_IGNORE_PATH=/usr/lib
        )
    fi

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_common_args+=("$arg")
    done < <(llvm_common_cmake_args)

    if is_macos_platform "$HOST_PLATFORM"; then
        sdk_path="$(macos_sdk_path)"
        if [ -n "$sdk_path" ]; then
            cmake_extra_args+=(
                -DCMAKE_OSX_SYSROOT="$sdk_path"
            )
        fi
    fi

    cmake -S "$source_dir/llvm" -B "$build_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
        -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
        -DLLDB_INCLUDE_TESTS=OFF \
        "${cmake_common_args[@]}" \
        "${cmake_extra_args[@]}"

    log "selected LLVM CMake cache entries:"
    if [ -f "$build_dir/CMakeCache.txt" ]; then
        llvm_dump_cmake_cache_entries "$build_dir/CMakeCache.txt" '^(LLVM_ENABLE_PROJECTS|LLVM_ENABLE_RUNTIMES|LLVM_TARGETS_TO_BUILD|LLVM_ENABLE_ZLIB|LLVM_ENABLE_ZSTD|LLVM_ENABLE_LIBXML2|LLVM_INCLUDE_TESTS|LLVM_INCLUDE_BENCHMARKS|LLVM_INCLUDE_DOCS|LLVM_ENABLE_BINDINGS|LLVM_ENABLE_ASSERTIONS|LLVM_HOST_TRIPLE|LLDB_ENABLE_PYTHON|LLDB_ENABLE_SWIG|LLDB_EMBED_PYTHON_HOME|LLDB_ENABLE_LIBXML2|LLDB_ENABLE_LZMA|LLDB_ENABLE_LIBEDIT|LLDB_ENABLE_CURSES|Python3_EXECUTABLE|Python3_LIBRARY|Python3_INCLUDE_DIR|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_OSX_SYSROOT):'
    fi

    if ! cmake --build "$build_dir" --parallel "$CUP_JOBS"; then
        log "LLVM tool build failed; selected CMake cache entries:"
        llvm_dump_cmake_cache_entries "$build_dir/CMakeCache.txt" '^(LLVM_ENABLE_PROJECTS|LLVM_TARGETS_TO_BUILD|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|LLVM_HOST_TRIPLE|LLDB_|Python3_):'
        return 1
    fi
    cmake --install "$build_dir"

    build_llvm_runtimes "$source_dir" "$build_dir"

    prune_llvm_package_bins

    if is_windows_platform "$HOST_PLATFORM" && [ "$TOOL" = "lldb" ]; then
        copy_windows_python_runtime "$build_dir"
    fi

    copy_clang_sanitizer_runtime_dlls
    copy_windows_runtime_dlls "$PREFIX/bin"
    verify_windows_runtime_dlls "$PREFIX/bin"
}

llvm_exe_suffix() {
    if is_windows_platform "$HOST_PLATFORM"; then
        printf '%s\n' ".exe"
    else
        printf '%s\n' ""
    fi
}

llvm_bin_exists() {
    local name="$1"
    local exe_suffix
    exe_suffix="$(llvm_exe_suffix)"

    [ -x "$PREFIX/bin/$name" ] || [ -x "$PREFIX/bin/$name$exe_suffix" ]
}

append_lld_frontend_info() {
    local -n out_ref="$1"
    local frontends=()
    local frontend

    [ "$TOOL" = "lld" ] || return 0

    for frontend in ld.lld lld-link wasm-ld ld64.lld; do
        if llvm_bin_exists "$frontend"; then
            frontends+=("$frontend")
            case "$frontend" in
                ld.lld) out_ref+=("contents.frontend.ld_lld=true") ;;
                lld-link) out_ref+=("contents.frontend.lld_link=true") ;;
                wasm-ld) out_ref+=("contents.frontend.wasm_ld=true") ;;
                ld64.lld) out_ref+=("contents.frontend.ld64_lld=true") ;;
            esac
        else
            case "$frontend" in
                ld.lld) out_ref+=("contents.frontend.ld_lld=false") ;;
                lld-link) out_ref+=("contents.frontend.lld_link=false") ;;
                wasm-ld) out_ref+=("contents.frontend.wasm_ld=false") ;;
                ld64.lld) out_ref+=("contents.frontend.ld64_lld=false") ;;
            esac
        fi
    done

    if [ "${#frontends[@]}" -gt 0 ]; then
        local joined
        joined="$(IFS=,; printf '%s' "${frontends[*]}")"
        out_ref+=("contents.frontends=$joined")
    else
        out_ref+=("contents.frontends=")
    fi
}

write_llvm_info() {
    local has_clang
    local has_clangpp
    local has_resource_dir
    local has_lld
    local has_lld_link
    local has_wasm_ld
    local has_ld64_lld
    local has_lldb
    local has_lldb_server
    local has_lldb_dap
    local has_clangd
    local has_clangd_indexer
    local has_clang_format
    local has_git_clang_format
    local has_clang_tidy
    local has_clang_apply_replacements
    local has_run_clang_tidy
    local has_clang_tidy_diff
    local cmake_python
    local cmake_libxml2
    local cmake_lzma
    local cmake_libedit
    local cmake_curses
    local cmake_zlib
    local cmake_zstd
    local has_target_x86
    local has_target_aarch64
    local has_compiler_rt
    local has_asan
    local has_ubsan
    local has_sanitizers
    local has_profile_runtime
    local has_cxx_runtime

    has_clang="$(metadata_bool_for_executable "$PREFIX" clang)"
    has_clangpp="$(metadata_bool_for_executable "$PREFIX" clang++)"
    has_resource_dir="$(metadata_bool_for_dirs "$PREFIX" 'clang')"
    has_lld="$(metadata_bool_for_executable "$PREFIX" ld.lld)"
    has_lld_link="$(metadata_bool_for_executable "$PREFIX" lld-link)"
    has_wasm_ld="$(metadata_bool_for_executable "$PREFIX" wasm-ld)"
    has_ld64_lld="$(metadata_bool_for_executable "$PREFIX" ld64.lld)"
    has_lldb="$(metadata_bool_for_executable "$PREFIX" lldb)"
    has_lldb_server="$(metadata_bool_for_executable "$PREFIX" lldb-server)"
    has_lldb_dap="$(metadata_bool_for_executable "$PREFIX" lldb-dap)"
    has_clangd="$(metadata_bool_for_executable "$PREFIX" clangd)"
    has_clangd_indexer="$(metadata_bool_for_executable "$PREFIX" clangd-indexer)"
    has_clang_format="$(metadata_bool_for_executable "$PREFIX" clang-format)"
    has_git_clang_format="$(metadata_bool_for_executable "$PREFIX" git-clang-format)"
    has_clang_tidy="$(metadata_bool_for_executable "$PREFIX" clang-tidy)"
    has_clang_apply_replacements="$(metadata_bool_for_executable "$PREFIX" clang-apply-replacements)"
    has_run_clang_tidy="$(metadata_bool_for_executable "$PREFIX" run-clang-tidy)"
    has_clang_tidy_diff="$(metadata_bool_for_executable "$PREFIX" clang-tidy-diff)"

    cmake_python="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLDB_ENABLE_PYTHON)"
    cmake_libxml2="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLDB_ENABLE_LIBXML2)"
    cmake_lzma="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLDB_ENABLE_LZMA)"
    cmake_libedit="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLDB_ENABLE_LIBEDIT)"
    cmake_curses="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLDB_ENABLE_CURSES)"
    cmake_zlib="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLVM_ENABLE_ZLIB)"
    cmake_zstd="$(cmake_cache_bool "${LLVM_BUILD_DIR:-}" LLVM_ENABLE_ZSTD)"
    has_target_x86="$(llvm_target_feature_bool X86)"
    has_target_aarch64="$(llvm_target_feature_bool AArch64)"
    has_compiler_rt="$(metadata_bool_for_files "$PREFIX" 'clang_rt.*' 'libclang_rt.*')"
    has_asan="$(metadata_bool_for_files "$PREFIX" 'clang_rt.asan*' 'libclang_rt.asan*')"
    has_ubsan="$(metadata_bool_for_files "$PREFIX" 'clang_rt.ubsan*' 'libclang_rt.ubsan*')"
    if [ "$has_asan" = true ] || [ "$has_ubsan" = true ]; then
        has_sanitizers=true
    else
        has_sanitizers=false
    fi
    has_profile_runtime="$(metadata_bool_for_files "$PREFIX" 'clang_rt.profile*' 'libclang_rt.profile*')"
    has_cxx_runtime="$(metadata_bool_for_files "$PREFIX" 'libc++*' 'libcxx*' 'libunwind*')"

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
        "config.llvm_targets=$LLVM_TARGETS"
        "config.llvm_runtimes=$LLVM_RUNTIMES"
        "config.llvm_runtimes_enabled=$(llvm_runtimes_enabled && printf true || printf false)"
        "config.zlib=$cmake_zlib"
        "config.zstd=$cmake_zstd"
        "contents.self_contained=true"
    )

    info+=("${CONTENTS_EXTRA[@]}")

    append_lld_frontend_info info

    case "$TOOL" in
        clang)
            info+=(
                "$(info_required_entry entry.clang "$PREFIX" clang)"
                "$(info_required_entry entry.clang++ "$PREFIX" clang++)"
                "$(info_entry_if_present entry.lld "$PREFIX" ld.lld)"
                "features.c=$has_clang"
                "features.cpp=$has_clangpp"
                "features.resource_dir=$has_resource_dir"
                "features.lld_integration=$has_lld"
                "features.lto=$has_lld"
                "features.llvm_ar=$(metadata_bool_for_executable "$PREFIX" llvm-ar)"
                "features.llvm_ranlib=$(metadata_bool_for_executable "$PREFIX" llvm-ranlib)"
                "features.llvm_objdump=$(metadata_bool_for_executable "$PREFIX" llvm-objdump)"
                "features.target_x86=$has_target_x86"
                "features.target_aarch64=$has_target_aarch64"
                "features.target_linux_x64=$( [ "$TARGET_PLATFORM" = "linux-x64" ] && printf true || printf false )"
                "features.target_linux_arm64=$( [ "$TARGET_PLATFORM" = "linux-arm64" ] && printf true || printf false )"
                "features.target_windows_x64=$( [ "$TARGET_PLATFORM" = "windows-x64" ] && printf true || printf false )"
                "features.target_macos_x64=$( [ "$TARGET_PLATFORM" = "macos-x64" ] && printf true || printf false )"
                "features.target_macos_arm64=$( [ "$TARGET_PLATFORM" = "macos-arm64" ] && printf true || printf false )"
                "contents.compiler_rt=$has_compiler_rt"
                "contents.llvm_runtimes=$has_compiler_rt"
                "features.sanitizers=$has_sanitizers"
                "features.asan=$has_asan"
                "features.ubsan=$has_ubsan"
                "features.profile_runtime=$has_profile_runtime"
                "features.cxx_runtime=$has_cxx_runtime"
            )
            ;;
        lld)
            info+=(
                "$(info_required_entry entry.ld_lld "$PREFIX" ld.lld)"
                "$(info_entry_if_present entry.lld_link "$PREFIX" lld-link)"
                "$(info_entry_if_present entry.wasm_ld "$PREFIX" wasm-ld)"
                "features.link_elf=$has_lld"
                "features.link_coff=$has_lld_link"
                "features.link_wasm=$has_wasm_ld"
                "features.link_macho=$has_ld64_lld"
            )
            ;;
        lldb)
            if is_windows_platform "$HOST_PLATFORM"; then
                info+=("contents.python_runtime=packaged")
            else
                info+=("contents.python_runtime=system")
            fi
            info+=(
                "$(info_required_entry entry.lldb "$PREFIX" lldb)"
                "$(info_entry_if_present entry.lldb_server "$PREFIX" lldb-server)"
                "$(info_entry_if_present entry.lldb_dap "$PREFIX" lldb-dap)"
                "config.python=$cmake_python"
                "config.libxml2=$cmake_libxml2"
                "config.lzma=$cmake_lzma"
                "config.libedit=$cmake_libedit"
                "config.curses=$cmake_curses"
                "features.python=$cmake_python"
                "features.target_create=$has_lldb"
                "features.breakpoints=$has_lldb"
                "features.symbol_lookup=$has_lldb"
                "features.process_launch=$has_lldb"
                "features.lldb_server=$has_lldb_server"
                "features.lldb_dap=$has_lldb_dap"
                "features.remote_debugging=$has_lldb_server"
            )
            ;;
        clangd)
            info+=(
                "$(info_required_entry entry.clangd "$PREFIX" clangd)"
                "$(info_entry_if_present entry.clangd_indexer "$PREFIX" clangd-indexer)"
                "features.check_compile_commands=$has_clangd"
                "features.background_index=$has_clangd"
                "features.indexer=$has_clangd_indexer"
            )
            ;;
        clang-format)
            info+=(
                "$(info_required_entry entry.clang_format "$PREFIX" clang-format)"
                "$(info_entry_if_present entry.git_clang_format "$PREFIX" git-clang-format)"
                "features.format_file=$has_clang_format"
                "features.style_config=$has_clang_format"
                "features.dry_run_werror=$has_clang_format"
                "features.git_clang_format=$has_git_clang_format"
            )
            ;;
        clang-tidy)
            info+=(
                "$(info_required_entry entry.clang_tidy "$PREFIX" clang-tidy)"
                "$(info_entry_if_present entry.clang_apply_replacements "$PREFIX" clang-apply-replacements)"
                "$(info_entry_if_present entry.run_clang_tidy "$PREFIX" run-clang-tidy)"
                "$(info_entry_if_present entry.clang_tidy_diff "$PREFIX" clang-tidy-diff)"
                "features.list_checks=$has_clang_tidy"
                "features.analyze_c=$has_clang_tidy"
                "features.clang_analyzer=$has_clang_tidy"
                "features.apply_replacements=$has_clang_apply_replacements"
                "features.run_clang_tidy=$has_run_clang_tidy"
                "features.clang_tidy_diff=$has_clang_tidy_diff"
            )
            ;;
    esac

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
