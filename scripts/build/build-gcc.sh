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
  $0 stable linux-x64 linux-x64 1
  $0 stable linux-x64 windows-x64 1
  $0 stable windows-x64 windows-x64 1
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

TOOL="gcc"
COMPONENT="compiler"

VERSION="$(resolve_version gcc "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

BINUTILS_VERSION="$(resolve_version binutils stable)"
MINGW_VERSION="$(resolve_version mingw stable)"

HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"

BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="source-release"

PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"

GCC_SOURCE_URL="$(source_url_gcc "$VERSION")"
BINUTILS_SOURCE_URL="$(source_url_binutils "$BINUTILS_VERSION")"
MINGW_SOURCE_URL="$(source_url_mingw "$MINGW_VERSION")"


need_common_tools() {
    need curl
    need tar
    need make
    need zip
    need realpath

    require_host_compilers
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

prepare_gcc_prerequisites() {
    local gcc_src="$1"

    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        log "using MSYS2 packaged GCC prerequisites on Windows host"
        return 0
    fi

    log "downloading GCC prerequisites with contrib/download_prerequisites"

    (
        cd "$gcc_src"
        ./contrib/download_prerequisites
    )
}

gcc_dependency_configure_args() {
    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        if [ -z "${MINGW_PREFIX:-}" ]; then
            die "MINGW_PREFIX is not set; run this build inside an MSYS2 MinGW/UCRT environment"
        fi

        printf '%s\n' \
            --with-gmp="$MINGW_PREFIX" \
            --with-mpfr="$MINGW_PREFIX" \
            --with-mpc="$MINGW_PREFIX" \
            --with-isl="$MINGW_PREFIX"
    fi
}

gcc_windows_target_configure_args() {
    if is_windows_platform "$TARGET_PLATFORM"; then
        printf '%s\n' \
            --with-sysroot="$PREFIX/$TARGET_TRIPLE" \
            --with-build-sysroot="$PREFIX/$TARGET_TRIPLE" \
            --with-native-system-header-dir=/include
    fi
}

gcc_bootstrap_configure_args() {
    if is_windows_platform "$TARGET_PLATFORM"; then
        printf '%s\n' --disable-bootstrap
    else
        printf '%s\n' --enable-bootstrap
    fi
}

gcc_feature_configure_args() {
    printf '%s\n' \
        --enable-languages=c,c++,lto \
        --enable-libgomp

    if is_windows_platform "$TARGET_PLATFORM"; then
        printf '%s\n' --disable-libsanitizer
    else
        printf '%s\n' --enable-libsanitizer
    fi
}

tool_exe_suffix() {
    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        printf '.exe\n'
    else
        printf '\n'
    fi
}

gcc_driver_tools() {
    printf '%s\n' gcc g++ c++ cpp gcov gcov-dump gcov-tool lto-dump
}

gcc_binutils_tools() {
    printf '%s\n' as ld ar ranlib strip dlltool dllwrap windres windmc nm objdump objcopy readelf size strings addr2line c++filt elfedit gprof
}

gcc_native_windows_duplicate_binutils_tools() {
    printf '%s\n' as ld ld.bfd ar ranlib strip dlltool dllwrap windres windmc nm objdump objcopy readelf size strings addr2line c++filt elfedit gprof
}


native_windows_gcc_package() {
    [ "$HOST_PLATFORM" = "windows-x64" ] && [ "$TARGET_PLATFORM" = "windows-x64" ]
}

gcc_build_tools_prefix() {
    printf '%s\n' "$CUP_BUILD_DIR/gcc-build-tools-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
}

gcc_build_tools_bin() {
    printf '%s/bin\n' "$(gcc_build_tools_prefix)"
}

gcc_binutils_install_prefix() {
    if native_windows_gcc_package; then
        gcc_build_tools_prefix
    else
        printf '%s\n' "$PREFIX"
    fi
}

gcc_tool_search_path() {
    if native_windows_gcc_package; then
        printf '%s:%s:%s\n' "$(gcc_build_tools_bin)" "$PREFIX/bin" "$PATH"
    else
        printf '%s:%s\n' "$PREFIX/bin" "$PATH"
    fi
}

ensure_prefixed_binutils_tools() {
    local tool
    local src
    local dst
    local tmp
    local exe_suffix
    local bin_dir

    exe_suffix="$(tool_exe_suffix)"

    if native_windows_gcc_package; then
        bin_dir="$(gcc_build_tools_bin)"
        log "ensuring build-only target-prefixed Binutils aliases for native Windows package"
    else
        bin_dir="$PREFIX/bin"
        log "ensuring prefixed Binutils target tool names"
    fi

    for tool in $(gcc_binutils_tools); do
        src="$bin_dir/$tool$exe_suffix"
        dst="$bin_dir/$TARGET_TRIPLE-$tool$exe_suffix"
        tmp="$dst.tmp"

        if [ -x "$dst" ]; then
            if [ -L "$dst" ]; then
                cp -f -L "$dst" "$tmp"
                mv -f "$tmp" "$dst"
                chmod +x "$dst"
                log "  materialized symlink: $dst"
            else
                log "  existing: $dst"
            fi

            continue
        fi

        if [ ! -x "$src" ]; then
            log "  missing: $dst and fallback $src"
            continue
        fi

        cp -f "$src" "$dst"
        chmod +x "$dst"

        log "  created: $dst from $src"
    done
}

remove_unprefixed_binutils_tools() {
    local tool
    local path
    local exe_suffix

    if ! is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        log "keeping unprefixed Binutils tools for native package"
        return 0
    fi

    exe_suffix="$(tool_exe_suffix)"

    log "removing unprefixed Binutils tools from cross package prefix"

    for tool in $(gcc_binutils_tools); do
        path="$PREFIX/bin/$tool$exe_suffix"

        if [ -e "$path" ] || [ -L "$path" ]; then
            rm -f "$path"
            log "  removed: $path"
        fi
    done
}

create_native_windows_aliases() {
    local tool
    local exe_suffix
    local prefixed
    local plain

    if [ "$HOST_PLATFORM" != "windows-x64" ] || [ "$TARGET_PLATFORM" != "windows-x64" ]; then
        return 0
    fi

    exe_suffix="$(tool_exe_suffix)"

    log "ensuring native Windows tool aliases"

    for tool in $(gcc_driver_tools); do
        prefixed="$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
        plain="$PREFIX/bin/$tool$exe_suffix"

        if [ -x "$plain" ]; then
            log "  existing: $plain"
            continue
        fi

        if [ ! -x "$prefixed" ]; then
            log "  missing prefixed tool for alias: $prefixed"
            continue
        fi

        cp "$prefixed" "$plain"
        chmod +x "$plain"
        log "  created: $plain from $prefixed"
    done
}

ensure_prefixed_gcc_tools() {
    local tool
    local exe_suffix
    local plain
    local prefixed

    if [ "$HOST_PLATFORM" != "windows-x64" ] || [ "$TARGET_PLATFORM" != "windows-x64" ]; then
        return 0
    fi

    exe_suffix="$(tool_exe_suffix)"

    log "ensuring native Windows target-prefixed GCC tool names"

    for tool in $(gcc_driver_tools); do
        plain="$PREFIX/bin/$tool$exe_suffix"
        prefixed="$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"

        if [ -x "$prefixed" ]; then
            log "  existing: $prefixed"
            continue
        fi

        if [ ! -x "$plain" ]; then
            log "  missing plain tool for prefixed alias: $plain"
            continue
        fi

        cp -f "$plain" "$prefixed"
        chmod +x "$prefixed"
        log "  created: $prefixed from $plain"
    done
}

prune_native_windows_prefixed_binutils_from_bin() {
    local tool
    local exe_suffix
    local prefixed
    local plain
    local target_layout_tool

    if [ "$HOST_PLATFORM" != "windows-x64" ] || [ "$TARGET_PLATFORM" != "windows-x64" ]; then
        return 0
    fi

    exe_suffix="$(tool_exe_suffix)"

    log "pruning duplicate target-prefixed Binutils from native Windows bin directory"

    for tool in $(gcc_native_windows_duplicate_binutils_tools); do
        prefixed="$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
        plain="$PREFIX/bin/$tool$exe_suffix"
        target_layout_tool="$PREFIX/$TARGET_TRIPLE/bin/$tool$exe_suffix"

        if [ ! -e "$prefixed" ] && [ ! -L "$prefixed" ]; then
            continue
        fi

        if [ ! -e "$plain" ] && [ ! -L "$plain" ]; then
            log "  keeping target-prefixed tool without plain equivalent: $prefixed"
            continue
        fi

        if [ -e "$target_layout_tool" ] || [ -L "$target_layout_tool" ]; then
            log "  removing duplicate: $prefixed (plain and target-layout copies exist)"
        else
            log "  removing public duplicate: $prefixed (plain copy exists)"
        fi

        rm -f "$prefixed"
    done
}


strip_gcc_package_binaries() {
    local strip_tool
    local file

    strip_tool="$(command -v strip 2>/dev/null || true)"

    if [ -z "$strip_tool" ]; then
        log "strip not found; skipping GCC package stripping"
        return 0
    fi

    log "stripping GCC package binaries where safe"

    while IFS= read -r file; do
        [ -f "$file" ] || continue
        "$strip_tool" --strip-unneeded "$file" >/dev/null 2>&1 || true
    done < <(
        {
            find "$PREFIX" -type f -path '*/bin/*' 2>/dev/null || true
            find "$PREFIX/libexec/gcc" -type f \( \
                -name 'cc1' -o -name 'cc1plus' -o -name 'collect2' -o \
                -name 'lto1' -o -name 'lto-wrapper' -o -name 'lto-dump' \
            \) 2>/dev/null || true
            find "$PREFIX" -type f \( \
                -name '*.dll' -o -name '*.so' -o -name '*.so.*' \
            \) 2>/dev/null || true
        } | sort -u
    )
}

gcc_metadata_bool_for_tool() {
    local name="$1"

    if prefix_executable_exists "$PREFIX" "$name"; then
        printf 'true\n'
        return 0
    fi

    if prefix_executable_exists "$PREFIX" "$TARGET_TRIPLE-$name"; then
        printf 'true\n'
        return 0
    fi

    printf 'false\n'
}

host_c_compiler() {
    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        if [ -z "${MINGW_PREFIX:-}" ]; then
            die "MINGW_PREFIX is not set; run this build inside an MSYS2 MinGW/UCRT environment"
        fi

        printf '%s/bin/gcc.exe\n' "$MINGW_PREFIX"
        return 0
    fi

    command -v gcc 2>/dev/null || command -v cc 2>/dev/null || true
}

host_cxx_compiler() {
    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        if [ -z "${MINGW_PREFIX:-}" ]; then
            die "MINGW_PREFIX is not set; run this build inside an MSYS2 MinGW/UCRT environment"
        fi

        printf '%s/bin/g++.exe\n' "$MINGW_PREFIX"
        return 0
    fi

    command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || true
}

require_host_compilers() {
    local cc
    local cxx

    cc="$(host_c_compiler)"
    cxx="$(host_cxx_compiler)"

    if [ -z "$cc" ] || [ ! -x "$cc" ]; then
        die "host C compiler not found"
    fi

    if [ -z "$cxx" ] || [ ! -x "$cxx" ]; then
        die "host C++ compiler not found"
    fi

    log "host compiler: CC=$cc"
    log "host compiler: CXX=$cxx"
}

require_target_gcc_tools() {
    local tool

    log "checking bundled GCC target tools"

    for tool in gcc g++ ar as ld nm ranlib strip dlltool windres; do
        require_bundled_target_tool "$tool"
    done
}

log_final_gcc_tools() {
    log "final GCC host tools:"
    log "  CC=$CC"
    log "  CXX=$CXX"

    log "final GCC target binutils:"
    log "  AR_FOR_TARGET=$AR_FOR_TARGET"
    log "  AS_FOR_TARGET=$AS_FOR_TARGET"
    log "  LD_FOR_TARGET=$LD_FOR_TARGET"
    log "  NM_FOR_TARGET=$NM_FOR_TARGET"
    log "  RANLIB_FOR_TARGET=$RANLIB_FOR_TARGET"
    log "  STRIP_FOR_TARGET=$STRIP_FOR_TARGET"
    log "  DLLTOOL_FOR_TARGET=$DLLTOOL_FOR_TARGET"
    log "  WINDRES_FOR_TARGET=$WINDRES_FOR_TARGET"
}

target_tool_path() {
    local tool="$1"
    local exe_suffix

    exe_suffix="$(tool_exe_suffix)"

    if native_windows_gcc_package; then
        case "$tool" in
            gcc|g++|c++|cpp|gcov|gcov-dump|gcov-tool|lto-dump)
                printf '%s\n' "$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
                ;;
            *)
                printf '%s\n' "$(gcc_build_tools_bin)/$TARGET_TRIPLE-$tool$exe_suffix"
                ;;
        esac
    else
        printf '%s\n' "$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
    fi
}

resolve_target_tool() {
    local tool="$1"
    local path
    local exe_suffix

    path="$(target_tool_path "$tool")"

    if [ -x "$path" ]; then
        printf '%s\n' "$path"
        return 0
    fi

    if native_windows_gcc_package; then
        exe_suffix="$(tool_exe_suffix)"
        case "$tool" in
            gcc|g++|c++|cpp|gcov|gcov-dump|gcov-tool|lto-dump)
                ;;
            *)
                path="$(gcc_build_tools_bin)/$tool$exe_suffix"
                if [ -x "$path" ]; then
                    printf '%s\n' "$path"
                    return 0
                fi
                ;;
        esac
    fi

    return 1
}

require_bundled_target_tool() {
    local tool="$1"
    local path
    local expected

    expected="$(target_tool_path "$tool")"
    path="$(resolve_target_tool "$tool")"

    if [ -z "$path" ] || [ ! -x "$path" ]; then
        die "target tool not found: $expected"
    fi

    log "  $TARGET_TRIPLE-$tool -> $path"
}

require_bundled_binutils_tools() {
    local tool
    local tool_path

    log "checking bundled Binutils target tools"

    for tool in as ld ar ranlib strip nm objdump objcopy readelf; do
        if native_windows_gcc_package || is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
            tool_path="$(resolve_target_tool "$tool")"
        else
            tool_path="$PREFIX/bin/$tool$(tool_exe_suffix)"
        fi

        if [ -z "$tool_path" ] || [ ! -x "$tool_path" ]; then
            die "target tool not found: $tool"
        fi

        log "  $tool -> $tool_path"
    done
}

require_bundled_crt_tools() {
    local tool

    log "checking bundled tools for MinGW CRT build"

    for tool in gcc ar ranlib strip dlltool; do
        require_bundled_target_tool "$tool"
    done
}

log_target_tools_for_crt() {
    local tool
    local resolved

    log "target tools resolved for CRT/winpthreads:"

    for tool in gcc ar ranlib strip dlltool; do
        resolved="$(resolve_target_tool "$tool")"

        if [ -n "$resolved" ]; then
            log "  $TARGET_TRIPLE-$tool -> $resolved"
        else
            log "  missing: $(target_tool_path "$tool")"
        fi
    done
}

configure_and_build() {
    local source_dir="$1"
    local build_dir="$2"
    local configure_script

    shift 2

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$source_dir" "$build_dir")"

    (
        cd "$build_dir"
        "$configure_script" "$@"
        make -j"$CUP_JOBS"
        make install
    )
}


build_native_binutils() {
    local binutils_src="$1"
    local build_dir="$CUP_BUILD_DIR/binutils-$BINUTILS_VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"

    log "building bundled native Binutils $BINUTILS_VERSION for $HOST_PLATFORM"

    configure_and_build "$binutils_src" "$build_dir" \
        --prefix="$PREFIX" \
        --disable-werror \
        --disable-nls \
        --enable-ld \
        --enable-plugins
}

gcc_effective_target_triple() {
    if [ "$HOST_PLATFORM" = "$TARGET_PLATFORM" ]; then
        case "$TARGET_PLATFORM" in
            linux-x64)
                printf '%s\n' "x86_64-pc-linux-gnu"
                return 0
                ;;
            linux-arm64)
                printf '%s\n' "aarch64-unknown-linux-gnu"
                return 0
                ;;
        esac
    fi

    printf '%s\n' "$TARGET_TRIPLE"
}

gcc_native_target_names() {
    gcc_effective_target_triple
}

install_native_binutils_for_gcc() {
    local target_name
    local tool
    local source_path
    local target_dir
    local target_path
    local exe_suffix

    if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
        return 0
    fi

    if [ "$TOOL" != "gcc" ]; then
        return 0
    fi

    exe_suffix="$(tool_exe_suffix)"

    copy_native_binutils_tool() {
        source_path="$1"
        target_path="$2"

        if [ ! -e "$source_path" ]; then
            return 0
        fi

        mkdir -p "$(dirname "$target_path")"

        if [ -e "$target_path" ] && [ "$source_path" -ef "$target_path" ]; then
            log "  already installed: $target_path"
            return 0
        fi

        cp -f "$source_path" "$target_path"
        chmod +x "$target_path" 2>/dev/null || true
        log "  installed: $target_path"
    }

    log "installing bundled native Binutils where GCC searches for target tools"

    for target_name in $(gcc_native_target_names | sort -u); do
        target_dir="$PREFIX/$target_name/bin"

        for tool in as ld ar ranlib strip nm objdump objcopy readelf size strings addr2line c++filt elfedit gprof; do
            copy_native_binutils_tool \
                "$PREFIX/bin/$tool$exe_suffix" \
                "$target_dir/$tool$exe_suffix"
        done

        if [ -e "$PREFIX/bin/ld.bfd$exe_suffix" ]; then
            copy_native_binutils_tool \
                "$PREFIX/bin/ld.bfd$exe_suffix" \
                "$target_dir/ld.bfd$exe_suffix"
        fi
    done
}

require_bundled_native_binutils_tools() {
    local tool
    local target_alias
    local found
    local exe_suffix

    exe_suffix="$(tool_exe_suffix)"

    log "checking bundled native Binutils tools"

    for tool in as ld ar ranlib strip nm objdump objcopy readelf; do
        if [ ! -x "$PREFIX/bin/$tool$exe_suffix" ]; then
            die "bundled native Binutils tool missing: $PREFIX/bin/$tool$exe_suffix"
        fi

        found=0
        for target_alias in $(gcc_native_target_names | sort -u); do
            if [ -x "$PREFIX/$target_alias/bin/$tool$exe_suffix" ]; then
                found=1
                break
            fi
        done

        if [ "$found" = "0" ]; then
            die "bundled native Binutils target-layout tool missing: $tool"
        fi
    done
}

build_native_gcc() {
    local gcc_src="$1"
    local build_dir="$CUP_BUILD_DIR/gcc-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local gcc_dep_args=()
    local gcc_feature_args=()
    local gcc_bootstrap_args=()

    log "building native GCC $VERSION for $HOST_PLATFORM"

    mapfile -t gcc_dep_args < <(gcc_dependency_configure_args)
    mapfile -t gcc_feature_args < <(gcc_feature_configure_args)
    mapfile -t gcc_bootstrap_args < <(gcc_bootstrap_configure_args)

    prepare_gcc_prerequisites "$gcc_src"
    require_bundled_native_binutils_tools

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    (
        cd "$build_dir"
        export PATH="$(gcc_tool_search_path)"

        "$(configure_script_for_build "$gcc_src" "$build_dir")" \
            --prefix="$PREFIX" \
            --disable-werror \
            --disable-nls \
            --disable-multilib \
            --enable-checking=release \
            --with-system-zlib \
            "${gcc_bootstrap_args[@]}" \
            "${gcc_feature_args[@]}" \
            --with-gnu-as \
            --with-gnu-ld \
            "${gcc_dep_args[@]}"
        make -j"$CUP_JOBS"
        make install
    )
}

build_cross_binutils() {
    local binutils_src="$1"
    local build_dir="$CUP_BUILD_DIR/binutils-$BINUTILS_VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"

    log "building bundled Binutils $BINUTILS_VERSION for $TARGET_TRIPLE"

    configure_and_build "$binutils_src" "$build_dir" \
        --prefix="$(gcc_binutils_install_prefix)" \
        --target="$TARGET_TRIPLE" \
        --disable-werror \
        --disable-nls \
        --enable-ld \
        --enable-plugins
}

install_mingw_headers() {
    local mingw_src="$1"
    local headers_src="$mingw_src/mingw-w64-headers"
    local build_dir="$CUP_BUILD_DIR/mingw-headers-$MINGW_VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_script

    log "installing bundled MinGW-w64 headers $MINGW_VERSION"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$headers_src" "$build_dir")"

    (
        cd "$build_dir"
        "$configure_script" \
            --host="$TARGET_TRIPLE" \
            --prefix="$PREFIX/$TARGET_TRIPLE" \
            --enable-sdk=all \
            --with-default-msvcrt=ucrt
        make install
    )
}

build_gcc_stage1() {
    local gcc_src="$1"
    local build_dir="$CUP_BUILD_DIR/gcc-stage1-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_script
    local gcc_dep_args=()
    local gcc_target_args=()

    log "building stage-1 GCC for $TARGET_TRIPLE"

    mapfile -t gcc_dep_args < <(gcc_dependency_configure_args)
    mapfile -t gcc_target_args < <(gcc_windows_target_configure_args)

    prepare_gcc_prerequisites "$gcc_src"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$gcc_src" "$build_dir")"

    (
        cd "$build_dir"
        export PATH="$(gcc_tool_search_path)"

        "$configure_script" \
            --prefix="$PREFIX" \
            --target="$TARGET_TRIPLE" \
            --disable-werror \
            --disable-nls \
            --disable-multilib \
            --enable-checking=release \
            --with-system-zlib \
            --enable-languages=c,c++ \
            --enable-threads=posix \
            --with-gnu-as \
            --with-gnu-ld \
            "${gcc_dep_args[@]}" \
            "${gcc_target_args[@]}"
        make -j"$CUP_JOBS" all-gcc
        make install-gcc
    )
}

build_mingw_crt() {
    local mingw_src="$1"
    local crt_src="$mingw_src/mingw-w64-crt"
    local build_dir="$CUP_BUILD_DIR/mingw-crt-$MINGW_VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_script

    log "building bundled MinGW-w64 CRT $MINGW_VERSION"

    require_bundled_crt_tools
    log_target_tools_for_crt

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$crt_src" "$build_dir")"

    (
        cd "$build_dir"
        export PATH="$(gcc_tool_search_path)"

        CC="$(resolve_target_tool gcc)" \
        AR="$(resolve_target_tool ar)" \
        RANLIB="$(resolve_target_tool ranlib)" \
        STRIP="$(resolve_target_tool strip)" \
        DLLTOOL="$(resolve_target_tool dlltool)" \
        "$configure_script" \
            --host="$TARGET_TRIPLE" \
            --prefix="$PREFIX/$TARGET_TRIPLE" \
            --with-default-msvcrt=ucrt
        make -j"$CUP_JOBS"
        make install
    )
}

build_winpthreads() {
    local mingw_src="$1"
    local pthreads_src="$mingw_src/mingw-w64-libraries/winpthreads"
    local build_dir="$CUP_BUILD_DIR/winpthreads-$MINGW_VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_script

    if [ ! -d "$pthreads_src" ]; then
        log "winpthreads source directory not found; skipping"
        return 0
    fi

    log "building bundled winpthreads from MinGW-w64 $MINGW_VERSION"

    require_bundled_crt_tools
    log_target_tools_for_crt

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$pthreads_src" "$build_dir")"

    (
        cd "$build_dir"
        export PATH="$(gcc_tool_search_path)"

        CC="$(resolve_target_tool gcc)" \
        AR="$(resolve_target_tool ar)" \
        RANLIB="$(resolve_target_tool ranlib)" \
        STRIP="$(resolve_target_tool strip)" \
        DLLTOOL="$(resolve_target_tool dlltool)" \
        "$configure_script" \
            --host="$TARGET_TRIPLE" \
            --prefix="$PREFIX/$TARGET_TRIPLE"
        make -j"$CUP_JOBS"
        make install
    )
}


install_native_windows_binutils_layout() {
    local tool
    local exe_suffix
    local source
    local plain
    local target_layout

    if ! native_windows_gcc_package; then
        return 0
    fi

    exe_suffix="$(tool_exe_suffix)"
    log "installing native Windows Binutils package layout from build-only tools"

    mkdir -p "$PREFIX/bin" "$PREFIX/$TARGET_TRIPLE/bin"

    for tool in $(gcc_binutils_tools); do
        source="$(gcc_build_tools_bin)/$TARGET_TRIPLE-$tool$exe_suffix"
        if [ ! -x "$source" ]; then
            source="$(gcc_build_tools_bin)/$tool$exe_suffix"
        fi
        [ -x "$source" ] || continue

        plain="$PREFIX/bin/$tool$exe_suffix"
        target_layout="$PREFIX/$TARGET_TRIPLE/bin/$tool$exe_suffix"

        if [ ! -x "$plain" ]; then
            cp -f "$source" "$plain"
            chmod +x "$plain"
            log "  installed public Binutils tool: $plain"
        fi

        cp -f "$source" "$target_layout"
        chmod +x "$target_layout"
        log "  installed target-layout Binutils tool: $target_layout"
    done
}

build_gcc_final() {
    local gcc_src="$1"
    local build_dir="$CUP_BUILD_DIR/gcc-final-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_script
    local gcc_dep_args=()
    local gcc_target_args=()
    local gcc_bootstrap_args=()
    local gcc_feature_args=()
    local exe_suffix
    local host_cc
    local host_cxx

    log "building final bundled GCC $VERSION for $TARGET_TRIPLE"

    require_bundled_binutils_tools
    require_target_gcc_tools

    exe_suffix="$(tool_exe_suffix)"
    host_cc="$(host_c_compiler)"
    host_cxx="$(host_cxx_compiler)"

    if [ -z "$host_cc" ] || [ ! -x "$host_cc" ]; then
        die "host C compiler not found"
    fi

    if [ -z "$host_cxx" ] || [ ! -x "$host_cxx" ]; then
        die "host C++ compiler not found"
    fi

    mapfile -t gcc_dep_args < <(gcc_dependency_configure_args)
    mapfile -t gcc_target_args < <(gcc_windows_target_configure_args)
    mapfile -t gcc_bootstrap_args < <(gcc_bootstrap_configure_args)
    mapfile -t gcc_feature_args < <(gcc_feature_configure_args)

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$gcc_src" "$build_dir")"

    (
        cd "$build_dir"

        export PATH="$(gcc_tool_search_path)"

        export CC="$host_cc"
        export CXX="$host_cxx"

        unset CC_FOR_TARGET
        unset CXX_FOR_TARGET

        export AR_FOR_TARGET="$(resolve_target_tool ar)"
        export AS_FOR_TARGET="$(resolve_target_tool as)"
        export LD_FOR_TARGET="$(resolve_target_tool ld)"
        export NM_FOR_TARGET="$(resolve_target_tool nm)"
        export RANLIB_FOR_TARGET="$(resolve_target_tool ranlib)"
        export STRIP_FOR_TARGET="$(resolve_target_tool strip)"
        export DLLTOOL_FOR_TARGET="$(resolve_target_tool dlltool)"
        export WINDRES_FOR_TARGET="$(resolve_target_tool windres)"

        log_final_gcc_tools

        "$configure_script" \
            --prefix="$PREFIX" \
            --target="$TARGET_TRIPLE" \
            --disable-werror \
            --disable-nls \
            --disable-multilib \
            --enable-checking=release \
            --with-system-zlib \
            "${gcc_bootstrap_args[@]}" \
            "${gcc_feature_args[@]}" \
            --enable-threads=posix \
            --with-gnu-as \
            --with-gnu-ld \
            "${gcc_dep_args[@]}" \
            "${gcc_target_args[@]}"
        make -j"$CUP_JOBS"
        make install
    )

    install_native_windows_binutils_layout
    create_native_windows_aliases
    ensure_prefixed_gcc_tools
    prune_native_windows_prefixed_binutils_from_bin
    copy_windows_runtime_dlls "$PREFIX/bin"
    verify_windows_runtime_dlls "$PREFIX/bin"
}


build_bundled_native_gcc() {
    local gcc_src="$1"
    local binutils_src="$2"

    log "building self-contained native GCC package with bundled Binutils"

    build_native_binutils "$binutils_src"
    install_native_binutils_for_gcc
    require_bundled_native_binutils_tools
    build_native_gcc "$gcc_src"
}

build_bundled_windows_gcc() {
    local gcc_src="$1"
    local binutils_src="$2"
    local mingw_src="$3"

    log "building self-contained GCC package with bundled Binutils and MinGW-w64"

    build_cross_binutils "$binutils_src"
    ensure_prefixed_binutils_tools
    remove_unprefixed_binutils_tools
    require_bundled_binutils_tools

    install_mingw_headers "$mingw_src"
    build_gcc_stage1 "$gcc_src"
    build_mingw_crt "$mingw_src"
    build_winpthreads "$mingw_src"
    build_gcc_final "$gcc_src"
}

gcc_prefix_has_any() {
    local pattern

    for pattern in "$@"; do
        if find "$PREFIX" -type f -name "$pattern" -print -quit | grep -q .; then
            return 0
        fi
    done

    return 1
}

gcc_bool_for_files() {
    if gcc_prefix_has_any "$@"; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

write_gcc_info() {
    local bundle_components=""
    local includes_binutils="false"
    local includes_mingw="false"
    local bootstrap="true"
    local tool_naming="native"
    local includes_libstdcxx
    local includes_lto
    local includes_openmp
    local includes_sanitizers
    local includes_asan
    local includes_ubsan
    local has_gcc
    local has_gpp
    local has_cpp
    local has_lto_dump
    local has_gcov
    local has_plugin
    local has_pthread
    local has_sysroot
    local has_target_prefixed_compiler_drivers
    local has_target_prefixed_binutils
    local has_target_layout_binutils
    local gcc_effective_target

    includes_libstdcxx="$(metadata_bool_for_files "$PREFIX" 'libstdc++*')"
    includes_lto="$(metadata_bool_for_files "$PREFIX" 'liblto_plugin*' 'lto1*')"
    includes_openmp="$(metadata_bool_for_files "$PREFIX" 'libgomp*' 'omp.h')"
    includes_sanitizers="$(metadata_bool_for_files "$PREFIX" 'libasan*' 'libubsan*' 'libtsan*' 'liblsan*')"
    includes_asan="$(metadata_bool_for_files "$PREFIX" 'libasan*')"
    includes_ubsan="$(metadata_bool_for_files "$PREFIX" 'libubsan*')"
    has_gcc="$(gcc_metadata_bool_for_tool gcc)"
    has_gpp="$(gcc_metadata_bool_for_tool g++)"
    has_cpp="$(gcc_metadata_bool_for_tool cpp)"
    has_lto_dump="$(gcc_metadata_bool_for_tool lto-dump)"
    has_gcov="$(gcc_metadata_bool_for_tool gcov)"
    has_plugin="$(metadata_bool_for_files "$PREFIX" 'liblto_plugin*')"
    gcc_effective_target="$(gcc_effective_target_triple)"
    if is_windows_platform "$TARGET_PLATFORM"; then
        has_sysroot="$(metadata_bool_for_dirs "$PREFIX" "$TARGET_TRIPLE")"
    else
        has_sysroot="false"
    fi
    has_target_prefixed_compiler_drivers="$(metadata_bool_for_executable "$PREFIX" "$gcc_effective_target-gcc")"
    has_target_prefixed_binutils="$(metadata_bool_for_executable "$PREFIX" "$gcc_effective_target-ar")"
    if [ -x "$PREFIX/$gcc_effective_target/bin/as$(tool_exe_suffix)" ]; then
        has_target_layout_binutils="true"
    else
        has_target_layout_binutils="false"
    fi

    if is_linux_platform "$TARGET_PLATFORM"; then
        has_pthread="true"
    else
        has_pthread="$(metadata_bool_for_files "$PREFIX" 'libwinpthread*' 'pthread.h')"
    fi

    if is_windows_platform "$TARGET_PLATFORM"; then
        bundle_components="binutils,mingw-w64"
        includes_binutils="true"
        includes_mingw="true"
        bootstrap="false"

        if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
            tool_naming="target-prefixed"
        else
            tool_naming="native-with-prefixed-compiler-drivers"
        fi
    elif [ "$HOST_PLATFORM" = "$TARGET_PLATFORM" ] && is_linux_platform "$TARGET_PLATFORM"; then
        bundle_components="binutils"
        includes_binutils="true"
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
        "source.primary.name=gcc"
        "source.primary.version=$VERSION"
        "source.primary.url=$GCC_SOURCE_URL"
        "config.languages=c,c++,lto"
        "config.multilib=false"
        "config.nls=false"
        "config.checking=release"
        "config.zlib=system"
        "config.bootstrap=$bootstrap"
        "config.tool_naming=$tool_naming"
        "config.gcc_target_triple=$gcc_effective_target"
        "config.openmp=attempted"
        "config.sanitizers=attempted"
        "$(info_entry_if_present entry.gcc "$PREFIX" gcc)"
        "$(info_entry_if_present entry.g++ "$PREFIX" g++)"
        "$(info_entry_if_present entry.cpp "$PREFIX" cpp)"
        "$(info_entry_if_present entry.gcov "$PREFIX" gcov)"
        "contents.self_contained=true"
        "contents.libstdcxx=$includes_libstdcxx"
        "contents.lto=$includes_lto"
        "contents.openmp=$includes_openmp"
        "contents.libgomp=$includes_openmp"
        "contents.sanitizers=$includes_sanitizers"
        "contents.asan=$includes_asan"
        "contents.ubsan=$includes_ubsan"
        "features.c=$has_gcc"
        "features.cpp=$has_gpp"
        "features.preprocessor=$has_cpp"
        "features.gcov=$has_gcov"
        "features.lto=$includes_lto"
        "features.lto_dump=$has_lto_dump"
        "features.openmp=$includes_openmp"
        "features.pthread=$has_pthread"
        "features.sanitizers=$includes_sanitizers"
        "features.asan=$includes_asan"
        "features.ubsan=$includes_ubsan"
        "features.plugin=$has_plugin"
        "features.binutils=$includes_binutils"
        "features.target_prefixed_compiler_drivers=$has_target_prefixed_compiler_drivers"
        "features.target_prefixed_binutils=$has_target_prefixed_binutils"
        "features.target_layout_binutils=$has_target_layout_binutils"
        "features.sysroot=$has_sysroot"
    )

    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        info+=("build.gcc_prerequisites=msys2")
    else
        info+=("build.gcc_prerequisites=contrib-download_prerequisites")
    fi

    if is_windows_platform "$TARGET_PLATFORM"; then
        info+=(
            "config.sysroot=$TARGET_TRIPLE"
            "config.native_system_header_dir=/include"
            "$(info_entry_if_present entry.target_gcc "$PREFIX" "$TARGET_TRIPLE-gcc")"
            "$(info_entry_if_present entry.target_g++ "$PREFIX" "$TARGET_TRIPLE-g++")"
            "$(info_entry_if_present entry.target_cpp "$PREFIX" "$TARGET_TRIPLE-cpp")"
            "$(info_entry_if_present entry.target_gcov "$PREFIX" "$TARGET_TRIPLE-gcov")"
            "$(info_entry_if_present entry.target_ar "$PREFIX" "$TARGET_TRIPLE-ar")"
            "$(info_entry_if_present entry.target_ld "$PREFIX" "$TARGET_TRIPLE-ld")"
            "features.windows_target=true"
        )
    else
        info+=("features.windows_target=false")
    fi

    if [ -n "$bundle_components" ]; then
        info+=(
            "bundle.components=$bundle_components"
            "bundle.binutils.version=$BINUTILS_VERSION"
            "bundle.binutils.url=$BINUTILS_SOURCE_URL"
            "contents.includes_binutils=$includes_binutils"
            "contents.includes_mingw=$includes_mingw"
        )

        if is_windows_platform "$TARGET_PLATFORM"; then
            info+=(
                "bundle.mingw-w64.version=$MINGW_VERSION"
                "bundle.mingw-w64.url=$MINGW_SOURCE_URL"
                "features.winpthreads=$has_pthread"
            )
        fi
    fi

    write_info_file "$PREFIX" "${info[@]}"
}


main() {
    local gcc_src

    make_dirs
    need_common_tools

    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"

    gcc_src="$(prepare_source_tree gcc "$VERSION" "$GCC_SOURCE_URL" "gcc-$VERSION.tar.xz")"

    if is_windows_platform "$TARGET_PLATFORM"; then
        local binutils_src
        local mingw_src

        binutils_src="$(prepare_source_tree binutils "$BINUTILS_VERSION" "$BINUTILS_SOURCE_URL" "binutils-$BINUTILS_VERSION.tar.xz")"
        mingw_src="$(prepare_source_tree mingw-w64 "$MINGW_VERSION" "$MINGW_SOURCE_URL" "mingw-w64-v$MINGW_VERSION.tar.bz2")"

        build_bundled_windows_gcc "$gcc_src" "$binutils_src" "$mingw_src"
    else
        if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
            die "unsupported GCC target: $HOST_PLATFORM -> $TARGET_PLATFORM"
        fi

        local binutils_src
        binutils_src="$(prepare_source_tree binutils "$BINUTILS_VERSION" "$BINUTILS_SOURCE_URL" "binutils-$BINUTILS_VERSION.tar.xz")"
        build_bundled_native_gcc "$gcc_src" "$binutils_src"
    fi

    strip_gcc_package_binaries
    write_gcc_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"