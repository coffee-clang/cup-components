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
LLVM_BUILD_DIR=""

llvm_runtimes_enabled() {
    [ "$TOOL" = "clang" ] && [ -n "$LLVM_RUNTIMES" ]
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

cmake_native_path() {
    local path="$1"

    if is_windows_platform "$HOST_PLATFORM" && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

llvm_windows_runtime_cmake_args() {
    local args=()

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    [ -n "${MINGW_PREFIX:-}" ] || die "MINGW_PREFIX is not set; run this build inside an MSYS2 CLANG64 environment"

    args+=(
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_SYSROOT="$MINGW_PREFIX"
        -DCMAKE_PREFIX_PATH="$PREFIX;$MINGW_PREFIX"
        -DCMAKE_FIND_ROOT_PATH="$PREFIX;$MINGW_PREFIX"
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
        -DCMAKE_SYSTEM_IGNORE_PATH=/usr/lib
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
        -DMINGW:BOOL=ON
    )

    printf '%s\n' "${args[@]}"
}

llvm_windows_cxx_runtime_cmake_args() {
    local args=()

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    args+=(
        -DLIBUNWIND_HAS_C_LIB:BOOL=OFF
        -DLIBUNWIND_HAS_DL_LIB:BOOL=OFF
        -DLIBUNWIND_HAS_PTHREAD_LIB:BOOL=OFF
    )

    printf '%s\n' "${args[@]}"
}

llvm_compiler_rt_windows_cmake_args() {
    local args=()

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    args+=(
        -DCOMPILER_RT_HAS_VERSION_SCRIPT:BOOL=OFF
        -DCOMPILER_RT_HAS_GNU_VERSION_SCRIPT_COMPAT:BOOL=OFF
        -DCOMPILER_RT_HAS_Z_TEXT:BOOL=OFF
        -DCOMPILER_RT_HAS_LIBC:BOOL=OFF
        -DCOMPILER_RT_HAS_LIBDL:BOOL=OFF
        -DCOMPILER_RT_HAS_LIBRT:BOOL=OFF
        -DCOMPILER_RT_HAS_LIBM:BOOL=OFF
        -DCOMPILER_RT_HAS_LIBPTHREAD:BOOL=OFF
        -DCOMPILER_RT_HAS_LIBSTDCXX:BOOL=OFF
        -DCOMPILER_RT_CXX_LIBRARY:STRING=libcxx
        -DCOMPILER_RT_STATIC_CXX_LIBRARY:BOOL=OFF
        -DCOMPILER_RT_USE_LLVM_UNWINDER:BOOL=OFF
        -DCOMPILER_RT_ENABLE_STATIC_UNWINDER:BOOL=OFF
        -DSANITIZER_CXX_ABI:STRING=libc++
        -DSANITIZER_CXX_ABI_INTREE:BOOL=OFF
        -DSANITIZER_TEST_CXX:STRING=libc++
        -DSANITIZER_TEST_CXX_INTREE:BOOL=OFF
        -DSANITIZER_USE_STATIC_CXX_ABI:BOOL=OFF
        -DSANITIZER_USE_STATIC_TEST_CXX:BOOL=OFF
        -DSANITIZER_USE_STATIC_LLVM_UNWINDER:BOOL=OFF
    )

    printf '%s\n' "${args[@]}"
}

llvm_compiler_rt_installed_cxx_abi_args() {
    local args=()

    if is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    args+=(
        -DCOMPILER_RT_CXX_LIBRARY:STRING=libcxx
        -DCOMPILER_RT_STATIC_CXX_LIBRARY:BOOL=ON
        -DSANITIZER_CXX_ABI:STRING=libc++
        -DSANITIZER_CXX_ABI_INTREE:BOOL=OFF
        -DSANITIZER_TEST_CXX:STRING=libc++
        -DSANITIZER_TEST_CXX_INTREE:BOOL=OFF
        -DSANITIZER_USE_STATIC_CXX_ABI:BOOL=ON
        -DSANITIZER_USE_STATIC_TEST_CXX:BOOL=ON
        -DSANITIZER_USE_STATIC_LLVM_UNWINDER:BOOL=ON
    )

    printf '%s\n' "${args[@]}"
}

llvm_compiler_rt_sanitizer_cmake_args() {
    local args=(
        -DCOMPILER_RT_BUILD_SANITIZERS=ON
        -DCOMPILER_RT_BUILD_PROFILE=ON
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
        -DCOMPILER_RT_BUILD_XRAY=OFF
        -DCOMPILER_RT_BUILD_MEMPROF=OFF
        -DCOMPILER_RT_BUILD_ORC=OFF
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
    )

    printf '%s\n' "${args[@]}"
}


windows_clang_sysroot_target_aliases() {
    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    printf '%s\n' "$HOST_TRIPLE"
    printf '%s\n' "$TARGET_TRIPLE"
    printf '%s\n' "x86_64-w64-windows-gnu"
}

copy_windows_clang_mingw_sysroot() {
    local source_sysroot
    local canonical_target_dir
    local alias
    local alias_path

    if ! is_windows_platform "$HOST_PLATFORM" || [ "$TOOL" != "clang" ]; then
        return 0
    fi

    [ -n "${MINGW_PREFIX:-}" ] || die "MINGW_PREFIX is not set; cannot package the MinGW sysroot for Clang"

    source_sysroot="$MINGW_PREFIX/$HOST_TRIPLE"
    canonical_target_dir="$PREFIX/$HOST_TRIPLE"

    [ -d "$source_sysroot/include" ] || die "MinGW headers not found: $source_sysroot/include"
    [ -d "$source_sysroot/lib" ] || die "MinGW CRT/import libraries not found: $source_sysroot/lib"

    log "copying MinGW sysroot for Clang from $source_sysroot"

    rm -rf "$canonical_target_dir"
    mkdir -p "$canonical_target_dir"
    cp -a "$source_sysroot/include" "$canonical_target_dir/"
    cp -a "$source_sysroot/lib" "$canonical_target_dir/"

    while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        [ "$alias" != "$HOST_TRIPLE" ] || continue

        log "  MinGW sysroot alias not materialized: $alias (covered by driver config)"
    done < <(windows_clang_sysroot_target_aliases | sort -u)
}

write_windows_clang_driver_config() {
    local bin_dir="$PREFIX/bin"
    local cfg_common="$bin_dir/cup-windows-clang-common.cfg"
    local cfg_c="$bin_dir/clang.cfg"
    local cfg_cxx="$bin_dir/clang++.cfg"
    local target_cfg_1="$bin_dir/$HOST_TRIPLE.cfg"
    local target_cfg_2="$bin_dir/x86_64-w64-windows-gnu.cfg"

    if ! is_windows_platform "$HOST_PLATFORM" || [ "$TOOL" != "clang" ]; then
        return 0
    fi

    mkdir -p "$bin_dir"

    log "writing portable Clang driver configuration for bundled MinGW sysroot"

    cat > "$cfg_common" <<EOF
# Generated by cup-components.
# Keep Clang self-contained by pointing the driver at the sysroot and
# runtime libraries packaged next to the executable.
--target=$HOST_TRIPLE
--sysroot=<CFGDIR>/..
-resource-dir
<CFGDIR>/../lib/clang/22
-isystem
<CFGDIR>/../$HOST_TRIPLE/include
-L<CFGDIR>/../$HOST_TRIPLE/lib
-L<CFGDIR>/../lib
-fuse-ld=lld
--start-no-unused-arguments
--rtlib=compiler-rt
--end-no-unused-arguments
EOF

    cat > "$cfg_c" <<'EOF'
@cup-windows-clang-common.cfg
EOF

    cat > "$cfg_cxx" <<'EOF'
@cup-windows-clang-common.cfg
-stdlib=libc++
-isystem
<CFGDIR>/../include/c++/v1
EOF

    cat > "$target_cfg_1" <<'EOF'
# The driver-specific clang.cfg/clang++.cfg files carry the package defaults.
EOF

    if [ "$target_cfg_2" != "$target_cfg_1" ]; then
        cat > "$target_cfg_2" <<'EOF'
# The driver-specific clang.cfg/clang++.cfg files carry the package defaults.
EOF
    fi
}

llvm_dump_cmake_cache_entries() {
    local cache_file="$1"
    local pattern="$2"

    [ -f "$cache_file" ] || return 0
    grep -E "$pattern" "$cache_file" || true
}

llvm_runtime_files_present() {
    metadata_bool_for_files "$PREFIX" \
        'clang_rt.*' 'libclang_rt.*' \
        'libc++*' 'libcxx*' 'libc++abi*' 'libcxxabi*' 'libunwind*'
}

llvm_cxx_runtime_files_present() {
    metadata_bool_for_files "$PREFIX" \
        'libc++*' 'libcxx*' 'libc++abi*' 'libcxxabi*' 'libunwind*'
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


clang_resource_dir() {
    local dir

    if [ -d "$PREFIX/lib/clang" ]; then
        dir="$(find "$PREFIX/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1 || true)"
        if [ -n "$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    fi

    return 1
}

clang_runtime_platform_dir() {
    case "$HOST_PLATFORM" in
        linux-*) printf '%s\n' "linux" ;;
        macos-*) printf '%s\n' "darwin" ;;
        windows-*) printf '%s\n' "windows" ;;
        *) printf '%s\n' "$TARGET_FAMILY" ;;
    esac
}

clang_resource_runtime_alias_dirs() {
    local resource_dir="$1"
    local platform_dir

    platform_dir="$(clang_runtime_platform_dir)"
    printf '%s\n' "$resource_dir/lib/$platform_dir"

    if is_windows_platform "$HOST_PLATFORM"; then
        printf '%s\n' "$resource_dir/lib/$HOST_TRIPLE"
        printf '%s\n' "$resource_dir/lib/$TARGET_TRIPLE"
        printf '%s\n' "$resource_dir/lib/x86_64-w64-windows-gnu"
    fi
}

copy_clang_runtimes_to_resource_dir() {
    local resource_dir
    local platform_dir
    local destination
    local copied=false
    local source_dir_candidate

    if ! llvm_runtimes_enabled; then
        return 0
    fi

    resource_dir="$(clang_resource_dir || true)"
    if [ -z "$resource_dir" ]; then
        log "warning: unable to locate installed clang resource dir under $PREFIX/lib/clang"
        return 0
    fi

    platform_dir="$(clang_runtime_platform_dir)"
    destination="$resource_dir/lib/$platform_dir"
    mkdir -p "$destination"

    for source_dir_candidate in \
        "$PREFIX/lib/$platform_dir" \
        "$PREFIX/lib/clang_rt/$platform_dir" \
        "$PREFIX/lib/$HOST_TRIPLE" \
        "$PREFIX/lib/$TARGET_TRIPLE"
    do
        if [ -d "$source_dir_candidate" ]; then
            log "copying clang runtimes from $source_dir_candidate to $destination"
            cp -a "$source_dir_candidate"/. "$destination"/
            copied=true
        fi
    done

    if [ "$copied" = true ] && is_windows_platform "$HOST_PLATFORM"; then
        copy_clang_resource_runtime_aliases "$destination" "$resource_dir"
    fi

    if [ "$copied" = false ]; then
        log "no separate clang runtime directory found to copy into resource dir"
    fi
}

copy_clang_resource_runtime_aliases() {
    local canonical_dir="$1"
    local resource_dir="$2"
    local alias_dir

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    while IFS= read -r alias_dir; do
        [ -n "$alias_dir" ] || continue
        [ "$alias_dir" != "$canonical_dir" ] || continue
        mkdir -p "$alias_dir"
        cp -a "$canonical_dir"/. "$alias_dir"/
    done < <(clang_resource_runtime_alias_dirs "$resource_dir" | sort -u)
}

copy_compiler_rt_builtins_to_resource_dir() {
    local builtins_build_dir="$1"
    local resource_dir
    local builtin
    local copied=false
    local destinations=()
    local destination

    resource_dir="$(clang_resource_dir || true)"
    if [ -z "$resource_dir" ]; then
        log "warning: unable to locate installed clang resource dir before copying compiler-rt builtins"
        return 0
    fi

    while IFS= read -r destination; do
        [ -n "$destination" ] && destinations+=("$destination")
    done < <(clang_resource_runtime_alias_dirs "$resource_dir" | sort -u)

    while IFS= read -r builtin; do
        [ -n "$builtin" ] || continue
        [ -f "$builtin" ] || continue

        for destination in "${destinations[@]}"; do
            mkdir -p "$destination"
            cp -f "$builtin" "$destination/$(basename "$builtin")"
        done

        log "  copied compiler-rt builtin: $(basename "$builtin")"
        copied=true
    done < <(find "$builtins_build_dir" -type f \
        \( -name 'libclang_rt.builtins*.a' -o -name 'clang_rt.builtins*.lib' \) | sort -u)

    if [ "$copied" = false ]; then
        log "warning: no compiler-rt builtins were found under $builtins_build_dir"
    fi
}

find_compiler_rt_builtins_library() {
    local resource_dir

    resource_dir="$(clang_resource_dir || true)"
    [ -n "$resource_dir" ] || return 1

    find "$resource_dir/lib" -type f \
        \( -name 'libclang_rt.builtins*.a' -o -name 'clang_rt.builtins*.lib' \) \
        | sort | head -n 1
}


create_clang_runtime_compiler_wrappers() {
    local wrapper_dir="$1"
    local clang_c="$2"
    local clang_cxx="$3"
    local resource_dir="$4"
    local cc_wrapper="$wrapper_dir/clang-runtime-cc"
    local cxx_wrapper="$wrapper_dir/clang-runtime-cxx"
    local common_flags="-resource-dir $resource_dir"

    mkdir -p "$wrapper_dir"

    cat > "$cc_wrapper" <<EOF
#!/usr/bin/env bash
exec "$clang_c" $common_flags "\$@"
EOF

    cat > "$cxx_wrapper" <<EOF
#!/usr/bin/env bash
exec "$clang_cxx" $common_flags "\$@"
EOF

    chmod +x "$cc_wrapper" "$cxx_wrapper"

    printf '%s\n%s\n' "$cc_wrapper" "$cxx_wrapper"
}

require_compiler_rt_builtins_library() {
    local builtins_library
    builtins_library="$(find_compiler_rt_builtins_library || true)"

    if [ -z "$builtins_library" ]; then
        die "compiler-rt builtins library was not staged into clang resource dir"
    fi

    printf '%s\n' "$builtins_library"
}

llvm_runtime_common_args() {
    local clang_c="$1"
    local clang_cxx="$2"
    local llvm_ar="$3"
    local llvm_ranlib="$4"
    local llvm_nm="$5"
    local llvm_linker="$6"
    local args=()
    local sdk_path

    args+=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_PREFIX_PATH="$PREFIX"
        -DCMAKE_C_COMPILER="$clang_c"
        -DCMAKE_CXX_COMPILER="$clang_cxx"
        -DCMAKE_C_COMPILER_TARGET="$HOST_TRIPLE"
        -DCMAKE_CXX_COMPILER_TARGET="$HOST_TRIPLE"
        -DLLVM_DEFAULT_TARGET_TRIPLE="$HOST_TRIPLE"
    )

    [ -x "$llvm_ar" ] && args+=(-DCMAKE_AR="$llvm_ar")
    [ -x "$llvm_ranlib" ] && args+=(-DCMAKE_RANLIB="$llvm_ranlib")
    [ -x "$llvm_nm" ] && args+=(-DCMAKE_NM="$llvm_nm")

    while IFS= read -r arg; do
        [ -n "$arg" ] && args+=("$arg")
    done < <(llvm_common_cmake_args)

    if ! is_macos_platform "$HOST_PLATFORM" && [ -x "$llvm_linker" ]; then
        args+=(
            -DLLVM_ENABLE_LLD=ON
            -DCMAKE_LINKER="$llvm_linker"
        )
    fi

    if is_windows_platform "$HOST_PLATFORM"; then
        while IFS= read -r arg; do
            [ -n "$arg" ] && args+=("$arg")
        done < <(llvm_windows_runtime_cmake_args)
    elif is_macos_platform "$HOST_PLATFORM"; then
        sdk_path="$(macos_sdk_path)"
        if [ -n "$sdk_path" ]; then
            args+=(
                -DCMAKE_OSX_SYSROOT="$sdk_path"
            )
        fi
    fi

    printf '%s\n' "${args[@]}"
}

build_clang_builtins_runtime() {
    local source_dir="$1"
    local tool_build_dir="$2"
    local builtins_build_dir="$CUP_BUILD_DIR/llvm-$TOOL-builtins-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local exe_suffix
    local clang_c
    local clang_cxx
    local llvm_ar
    local llvm_ranlib
    local llvm_nm
    local llvm_linker
    local cmake_builtins_args=()

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

    log "building compiler-rt builtins for $TOOL $VERSION"

    rm -rf "$builtins_build_dir"
    mkdir -p "$builtins_build_dir"

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_builtins_args+=("$arg")
    done < <(llvm_runtime_common_args "$clang_c" "$clang_cxx" "$llvm_ar" "$llvm_ranlib" "$llvm_nm" "$llvm_linker")

    cmake_builtins_args+=(
        -DLLVM_ENABLE_RUNTIMES=compiler-rt
        -DCOMPILER_RT_BUILD_BUILTINS=ON
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF
        -DCOMPILER_RT_BUILD_PROFILE=OFF
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
        -DCOMPILER_RT_BUILD_XRAY=OFF
        -DCOMPILER_RT_BUILD_MEMPROF=OFF
        -DCOMPILER_RT_BUILD_ORC=OFF
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
    )

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_builtins_args+=("$arg")
    done < <(llvm_compiler_rt_windows_cmake_args)

    cmake -S "$source_dir/runtimes" -B "$builtins_build_dir" -G Ninja \
        "${cmake_builtins_args[@]}"

    log "selected compiler-rt builtins CMake cache entries:"
    if [ -f "$builtins_build_dir/CMakeCache.txt" ]; then
        llvm_dump_cmake_cache_entries "$builtins_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|LLVM_DEFAULT_TARGET_TRIPLE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_C_COMPILER_TARGET|CMAKE_CXX_COMPILER_TARGET|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_OSX_SYSROOT|CMAKE_TRY_COMPILE_TARGET_TYPE|MINGW|COMPILER_RT_BUILD_BUILTINS|COMPILER_RT_BUILD_SANITIZERS|COMPILER_RT_BUILD_PROFILE|COMPILER_RT_BUILD_LIBFUZZER|COMPILER_RT_BUILD_XRAY|COMPILER_RT_BUILD_MEMPROF|COMPILER_RT_BUILD_ORC|COMPILER_RT_BUILD_GWP_ASAN|COMPILER_RT_HAS_VERSION_SCRIPT|COMPILER_RT_HAS_GNU_VERSION_SCRIPT_COMPAT|COMPILER_RT_HAS_Z_TEXT|COMPILER_RT_HAS_LIBC|COMPILER_RT_HAS_LIBCXX|COMPILER_RT_HAS_LIBSTDCXX|COMPILER_RT_HAS_LIBDL|COMPILER_RT_HAS_LIBRT|COMPILER_RT_HAS_LIBM|COMPILER_RT_HAS_LIBPTHREAD|COMPILER_RT_CXX_LIBRARY|COMPILER_RT_STATIC_CXX_LIBRARY|COMPILER_RT_USE_LLVM_UNWINDER|COMPILER_RT_ENABLE_STATIC_UNWINDER|SANITIZER_CXX_ABI|SANITIZER_CXX_ABI_LIBNAME|SANITIZER_CXX_ABI_INTREE|SANITIZER_TEST_CXX|SANITIZER_TEST_CXX_LIBNAME|SANITIZER_TEST_CXX_INTREE|SANITIZER_USE_STATIC_CXX_ABI|SANITIZER_USE_STATIC_TEST_CXX|SANITIZER_USE_STATIC_LLVM_UNWINDER|COMPILER_RT_DEFAULT_TARGET_ONLY):'
    fi

    if ! cmake --build "$builtins_build_dir" --target builtins --parallel "$CUP_JOBS"; then
        log "compiler-rt builtins build failed; selected CMake cache entries:"
        llvm_dump_cmake_cache_entries "$builtins_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_OSX_SYSROOT|CMAKE_TRY_COMPILE_TARGET_TYPE|MINGW|COMPILER_RT_|SANITIZER_CXX_ABI|SANITIZER_TEST_CXX|SANITIZER_USE_STATIC_):'
        return 1
    fi

    copy_compiler_rt_builtins_to_resource_dir "$builtins_build_dir"
}

build_clang_cxx_runtimes() {
    local source_dir="$1"
    local tool_build_dir="$2"
    local cxx_build_dir="$CUP_BUILD_DIR/llvm-$TOOL-cxx-runtimes-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local exe_suffix
    local clang_c
    local clang_cxx
    local llvm_ar
    local llvm_ranlib
    local llvm_nm
    local llvm_linker
    local cmake_cxx_args=()
    local resource_dir
    local resource_dir_cmake
    local wrapper_dir
    local runtime_cc
    local runtime_cxx
    local runtime_wrappers=()

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

    resource_dir="$(clang_resource_dir || true)"
    if [ -z "$resource_dir" ]; then
        die "clang resource dir not found before C++ runtime build"
    fi

    resource_dir_cmake="$(cmake_native_path "$resource_dir")"
    log "building LLVM C++ runtimes for $TOOL $VERSION: libunwind;libcxxabi;libcxx"
    log "clang runtime resource dir: $resource_dir"

    rm -rf "$cxx_build_dir"
    mkdir -p "$cxx_build_dir"

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_cxx_args+=("$arg")
    done < <(llvm_runtime_common_args "$clang_c" "$clang_cxx" "$llvm_ar" "$llvm_ranlib" "$llvm_nm" "$llvm_linker")

    if is_windows_platform "$HOST_PLATFORM"; then
        runtime_cc="$clang_c"
        runtime_cxx="$clang_cxx"
    else
        wrapper_dir="$cxx_build_dir/compiler-wrappers"
        mapfile -t runtime_wrappers < <(create_clang_runtime_compiler_wrappers "$wrapper_dir" "$clang_c" "$clang_cxx" "$resource_dir")
        runtime_cc="${runtime_wrappers[0]}"
        runtime_cxx="${runtime_wrappers[1]}"
    fi

    cmake_cxx_args+=(
        -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx"
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
        "-DCMAKE_C_COMPILER=$runtime_cc"
        "-DCMAKE_CXX_COMPILER=$runtime_cxx"
    )

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_cxx_args+=("$arg")
    done < <(llvm_windows_cxx_runtime_cmake_args)

    if is_windows_platform "$HOST_PLATFORM"; then
        cmake_cxx_args+=(
            "-DCMAKE_C_FLAGS_INIT=-resource-dir $resource_dir_cmake"
            "-DCMAKE_CXX_FLAGS_INIT=-resource-dir $resource_dir_cmake"
            "-DCMAKE_ASM_FLAGS_INIT=-resource-dir $resource_dir_cmake"
            "-DCMAKE_EXE_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
            "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
        )
    elif ! is_macos_platform "$HOST_PLATFORM"; then
        cmake_cxx_args+=(
            "-DCMAKE_EXE_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
            "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
        )
    fi

    if ! cmake -S "$source_dir/runtimes" -B "$cxx_build_dir" -G Ninja \
        "${cmake_cxx_args[@]}"; then
        log "LLVM C++ runtime configure failed; selected CMake cache entries:"
        llvm_dump_cmake_cache_entries "$cxx_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_PREFIX_PATH|CMAKE_FIND_ROOT_PATH|CMAKE_TRY_COMPILE_TARGET_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|CMAKE_EXE_LINKER_FLAGS|CMAKE_SHARED_LINKER_FLAGS|MINGW|LIBUNWIND_|LIBCXXABI_|LIBCXX_):'
        return 1
    fi

    log "selected LLVM C++ runtimes CMake cache entries:"
    if [ -f "$cxx_build_dir/CMakeCache.txt" ]; then
        llvm_dump_cmake_cache_entries "$cxx_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|LLVM_DEFAULT_TARGET_TRIPLE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_C_COMPILER_TARGET|CMAKE_CXX_COMPILER_TARGET|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_PREFIX_PATH|CMAKE_FIND_ROOT_PATH|CMAKE_TRY_COMPILE_TARGET_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|CMAKE_EXE_LINKER_FLAGS|CMAKE_SHARED_LINKER_FLAGS|CMAKE_LINKER|MINGW|LLVM_ENABLE_LLD|LIBUNWIND_ENABLE_SHARED|LIBUNWIND_ENABLE_STATIC|LIBUNWIND_USE_COMPILER_RT|LIBUNWIND_HAS_C_LIB|LIBUNWIND_HAS_DL_LIB|LIBUNWIND_HAS_PTHREAD_LIB|LIBCXXABI_ENABLE_SHARED|LIBCXXABI_ENABLE_STATIC|LIBCXXABI_USE_LLVM_UNWINDER|LIBCXXABI_USE_COMPILER_RT|LIBCXX_ENABLE_SHARED|LIBCXX_ENABLE_STATIC|LIBCXX_ENABLE_STATIC_ABI_LIBRARY|LIBCXX_USE_COMPILER_RT):'
    fi

    if ! cmake --build "$cxx_build_dir" --parallel "$CUP_JOBS"; then
        log "LLVM C++ runtime build failed; selected CMake cache entries:"
        llvm_dump_cmake_cache_entries "$cxx_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_PREFIX_PATH|CMAKE_FIND_ROOT_PATH|CMAKE_TRY_COMPILE_TARGET_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|CMAKE_EXE_LINKER_FLAGS|CMAKE_SHARED_LINKER_FLAGS|MINGW|LIBUNWIND_|LIBCXXABI_|LIBCXX_):'
        return 1
    fi

    cmake --install "$cxx_build_dir"
}

build_clang_sanitizer_runtimes() {
    local source_dir="$1"
    local tool_build_dir="$2"
    local sanitizer_build_dir="$CUP_BUILD_DIR/llvm-$TOOL-sanitizer-runtimes-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local exe_suffix
    local clang_c
    local clang_cxx
    local llvm_ar
    local llvm_ranlib
    local llvm_nm
    local llvm_linker
    local cmake_sanitizer_args=()
    local resource_dir
    local resource_dir_cmake
    local builtins_library
    local builtins_library_cmake
    local wrapper_dir
    local runtime_cc
    local runtime_cxx
    local runtime_wrappers=()
    local compiler_rt_test_cflags

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

    resource_dir="$(clang_resource_dir || true)"
    if [ -z "$resource_dir" ]; then
        die "clang resource dir not found before sanitizer runtime build"
    fi

    builtins_library="$(require_compiler_rt_builtins_library)"
    resource_dir_cmake="$(cmake_native_path "$resource_dir")"
    builtins_library_cmake="$(cmake_native_path "$builtins_library")"
    log "building LLVM sanitizer runtimes for $TOOL $VERSION: compiler-rt sanitizers/profile"
    log "clang runtime resource dir: $resource_dir"
    log "clang runtime resource dir for CMake/compiler invocations: $resource_dir_cmake"
    log "compiler-rt builtins staged for sanitizer build: $builtins_library"
    log "compiler-rt builtins path for CMake/compiler invocations: $builtins_library_cmake"

    rm -rf "$sanitizer_build_dir"
    mkdir -p "$sanitizer_build_dir"

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_sanitizer_args+=("$arg")
    done < <(llvm_runtime_common_args "$clang_c" "$clang_cxx" "$llvm_ar" "$llvm_ranlib" "$llvm_nm" "$llvm_linker")

    if is_windows_platform "$HOST_PLATFORM"; then
        runtime_cc="$clang_c"
        runtime_cxx="$clang_cxx"
    else
        wrapper_dir="$sanitizer_build_dir/compiler-wrappers"
        mapfile -t runtime_wrappers < <(create_clang_runtime_compiler_wrappers "$wrapper_dir" "$clang_c" "$clang_cxx" "$resource_dir")
        runtime_cc="${runtime_wrappers[0]}"
        runtime_cxx="${runtime_wrappers[1]}"
    fi

    cmake_sanitizer_args+=(
        -DLLVM_ENABLE_RUNTIMES=compiler-rt
        -DCOMPILER_RT_BUILD_BUILTINS=OFF
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
        -DCOMPILER_RT_USE_LIBCXX=ON
        -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF
        "-DCMAKE_C_COMPILER=$runtime_cc"
        "-DCMAKE_CXX_COMPILER=$runtime_cxx"
        "-DCOMPILER_RT_BUILTINS_LIBRARY:FILEPATH=$builtins_library_cmake"
        "-DCOMPILER_RT_TEST_TARGET_TRIPLE=$HOST_TRIPLE"
    )

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_sanitizer_args+=("$arg")
    done < <(llvm_compiler_rt_sanitizer_cmake_args)

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_sanitizer_args+=("$arg")
    done < <(llvm_compiler_rt_windows_cmake_args)

    while IFS= read -r arg; do
        [ -n "$arg" ] && cmake_sanitizer_args+=("$arg")
    done < <(llvm_compiler_rt_installed_cxx_abi_args)

    compiler_rt_test_cflags="-resource-dir $resource_dir_cmake"

    cmake_sanitizer_args+=(
        "-DCOMPILER_RT_TEST_COMPILER_CFLAGS=$compiler_rt_test_cflags"
    )

    if is_windows_platform "$HOST_PLATFORM"; then
        cmake_sanitizer_args+=(
            "-DCMAKE_C_FLAGS_INIT=-resource-dir $resource_dir_cmake"
            "-DCMAKE_CXX_FLAGS_INIT=-resource-dir $resource_dir_cmake"
            "-DCMAKE_ASM_FLAGS_INIT=-resource-dir $resource_dir_cmake"
            "-DCMAKE_EXE_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
            "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
        )
    elif ! is_macos_platform "$HOST_PLATFORM"; then
        cmake_sanitizer_args+=(
            "-DCMAKE_EXE_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
            "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-resource-dir $resource_dir_cmake --rtlib=compiler-rt -fuse-ld=lld"
        )
    fi

    if ! cmake -S "$source_dir/runtimes" -B "$sanitizer_build_dir" -G Ninja \
        "${cmake_sanitizer_args[@]}"; then
        log "LLVM sanitizer runtime configure failed; selected CMake cache entries:"
        llvm_dump_cmake_cache_entries "$sanitizer_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_PREFIX_PATH|CMAKE_FIND_ROOT_PATH|CMAKE_TRY_COMPILE_TARGET_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|CMAKE_EXE_LINKER_FLAGS|CMAKE_SHARED_LINKER_FLAGS|MINGW|COMPILER_RT_|SANITIZER_CXX_ABI|SANITIZER_TEST_CXX|SANITIZER_USE_STATIC_):'
        return 1
    fi

    log "selected LLVM sanitizer runtimes CMake cache entries:"
    if [ -f "$sanitizer_build_dir/CMakeCache.txt" ]; then
        llvm_dump_cmake_cache_entries "$sanitizer_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|LLVM_DEFAULT_TARGET_TRIPLE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_C_COMPILER_TARGET|CMAKE_CXX_COMPILER_TARGET|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_PREFIX_PATH|CMAKE_FIND_ROOT_PATH|CMAKE_TRY_COMPILE_TARGET_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|CMAKE_EXE_LINKER_FLAGS|CMAKE_SHARED_LINKER_FLAGS|CMAKE_LINKER|MINGW|LLVM_ENABLE_LLD|COMPILER_RT_BUILD_BUILTINS|COMPILER_RT_BUILD_SANITIZERS|COMPILER_RT_BUILD_PROFILE|COMPILER_RT_BUILD_LIBFUZZER|COMPILER_RT_BUILD_XRAY|COMPILER_RT_BUILD_MEMPROF|COMPILER_RT_BUILD_ORC|COMPILER_RT_BUILD_GWP_ASAN|COMPILER_RT_HAS_VERSION_SCRIPT|COMPILER_RT_HAS_GNU_VERSION_SCRIPT_COMPAT|COMPILER_RT_HAS_Z_TEXT|COMPILER_RT_HAS_LIBC|COMPILER_RT_HAS_LIBCXX|COMPILER_RT_HAS_LIBSTDCXX|COMPILER_RT_HAS_LIBDL|COMPILER_RT_HAS_LIBRT|COMPILER_RT_HAS_LIBM|COMPILER_RT_HAS_LIBPTHREAD|COMPILER_RT_CXX_LIBRARY|COMPILER_RT_STATIC_CXX_LIBRARY|COMPILER_RT_USE_BUILTINS_LIBRARY|COMPILER_RT_USE_LIBCXX|COMPILER_RT_USE_LLVM_UNWINDER|COMPILER_RT_ENABLE_STATIC_UNWINDER|COMPILER_RT_DEFAULT_TARGET_ONLY|COMPILER_RT_TEST_COMPILER_CFLAGS|COMPILER_RT_TEST_TARGET_TRIPLE|COMPILER_RT_BUILTINS_LIBRARY|SANITIZER_CXX_ABI|SANITIZER_CXX_ABI_LIBNAME|SANITIZER_CXX_ABI_INTREE|SANITIZER_TEST_CXX|SANITIZER_TEST_CXX_LIBNAME|SANITIZER_TEST_CXX_INTREE|SANITIZER_USE_STATIC_CXX_ABI|SANITIZER_USE_STATIC_TEST_CXX|SANITIZER_USE_STATIC_LLVM_UNWINDER):'
    fi

    if ! cmake --build "$sanitizer_build_dir" --parallel "$CUP_JOBS"; then
        log "LLVM sanitizer runtime build failed; selected CMake cache entries:"
        llvm_dump_cmake_cache_entries "$sanitizer_build_dir/CMakeCache.txt" '^(LLVM_ENABLE_RUNTIMES|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_SYSTEM_NAME|CMAKE_SYSTEM_PROCESSOR|CMAKE_SYSROOT|CMAKE_PREFIX_PATH|CMAKE_FIND_ROOT_PATH|CMAKE_TRY_COMPILE_TARGET_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|CMAKE_EXE_LINKER_FLAGS|CMAKE_SHARED_LINKER_FLAGS|MINGW|COMPILER_RT_|SANITIZER_CXX_ABI|SANITIZER_TEST_CXX|SANITIZER_USE_STATIC_):'
        return 1
    fi

    cmake --install "$sanitizer_build_dir"
    copy_clang_runtimes_to_resource_dir
}

build_llvm_runtimes() {
    local source_dir="$1"
    local tool_build_dir="$2"
    local runtime_build_dir="$CUP_BUILD_DIR/llvm-$TOOL-runtimes-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"

    if ! llvm_runtimes_enabled; then
        return 0
    fi

    LLVM_RUNTIME_BUILD_DIR="$runtime_build_dir"
    log "building LLVM runtimes for $TOOL $VERSION using split runtime stages: builtins -> C++ runtimes -> sanitizers/profile"

    build_clang_builtins_runtime "$source_dir" "$tool_build_dir"
    build_clang_cxx_runtimes "$source_dir" "$tool_build_dir"
    build_clang_sanitizer_runtimes "$source_dir" "$tool_build_dir"
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
            -DLLDB_INCLUDE_TESTS=OFF
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
    copy_windows_clang_mingw_sysroot
    write_windows_clang_driver_config

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
    local has_llvm_runtimes
    local has_mingw_sysroot
    local has_driver_config

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

    if [ -z "${LLVM_BUILD_DIR:-}" ]; then
        die "LLVM_BUILD_DIR is not set; write_llvm_info must be called after build_llvm_tool"
    fi

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
    has_cxx_runtime="$(llvm_cxx_runtime_files_present)"
    has_llvm_runtimes="$(llvm_runtime_files_present)"
    if is_windows_platform "$HOST_PLATFORM" && [ "$TOOL" = "clang" ] &&         [ -d "$PREFIX/$HOST_TRIPLE/include" ] && [ -d "$PREFIX/$HOST_TRIPLE/lib" ]; then
        has_mingw_sysroot=true
    else
        has_mingw_sysroot=false
    fi
    if is_windows_platform "$HOST_PLATFORM" && [ "$TOOL" = "clang" ] &&         [ -f "$PREFIX/bin/clang.cfg" ] && [ -f "$PREFIX/bin/clang++.cfg" ]; then
        has_driver_config=true
    else
        has_driver_config=false
    fi

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
                "contents.llvm_runtimes=$has_llvm_runtimes"
                "features.sanitizers=$has_sanitizers"
                "features.asan=$has_asan"
                "features.ubsan=$has_ubsan"
                "features.profile_runtime=$has_profile_runtime"
                "features.cxx_runtime=$has_cxx_runtime"
                "features.cxx_runtime_default=false"
                "contents.mingw_sysroot=$has_mingw_sysroot"
                "features.sysroot=$has_mingw_sysroot"
                "config.driver_config=$has_driver_config"
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
