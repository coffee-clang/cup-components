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

gcc_target_library_flags() {
    if is_windows_platform "$TARGET_PLATFORM"; then
        printf '%s\n' "-O2 -fms-extensions"
    fi
}

tool_exe_suffix() {
    if [ "$HOST_PLATFORM" = "windows-x64" ]; then
        printf '.exe\n'
    else
        printf '\n'
    fi
}

ensure_prefixed_binutils_tools() {
    local tool
    local src
    local dst
    local tmp
    local exe_suffix

    exe_suffix="$(tool_exe_suffix)"

    log "ensuring prefixed Binutils target tool names"

    for tool in as ld ar ranlib strip dlltool dllwrap windres windmc nm objdump objcopy readelf size strings addr2line c++filt elfedit gprof; do
        src="$PREFIX/bin/$tool$exe_suffix"
        dst="$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
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

    for tool in as ld ar ranlib strip dlltool dllwrap windres windmc nm objdump objcopy readelf size strings addr2line c++filt elfedit gprof; do
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

    for tool in gcc g++ c++ cpp gcov gcov-dump gcov-tool ar as ld nm ranlib strip dlltool dllwrap windres windmc objdump objcopy readelf size strings addr2line c++filt elfedit gprof; do
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
    printf '%s\n' "$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
}

resolve_target_tool() {
    local tool="$1"
    local path

    path="$(target_tool_path "$tool")"

    if [ -x "$path" ]; then
        printf '%s\n' "$path"
    fi
}

require_bundled_target_tool() {
    local tool="$1"
    local path

    path="$(target_tool_path "$tool")"

    if [ ! -x "$path" ]; then
        die "target tool not found: $path"
    fi

    log "  $TARGET_TRIPLE-$tool -> $path"
}

require_bundled_binutils_tools() {
    local tool
    local tool_path
    local exe_suffix

    exe_suffix="$(tool_exe_suffix)"

    log "checking bundled Binutils target tools"

    for tool in as ld ar ranlib strip nm objdump objcopy readelf; do
        if is_cross_build "$HOST_PLATFORM" "$TARGET_PLATFORM"; then
            tool_path="$PREFIX/bin/$TARGET_TRIPLE-$tool$exe_suffix"
        else
            tool_path="$PREFIX/bin/$tool$exe_suffix"
        fi

        if [ ! -x "$tool_path" ]; then
            die "target tool not found: $tool_path"
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

gcc_native_target_names() {
    printf '%s\n' "$TARGET_TRIPLE"

    if [ "$HOST_PLATFORM" = "linux-x64" ] && [ "$TARGET_PLATFORM" = "linux-x64" ]; then
        printf '%s\n' "x86_64-pc-linux-gnu"
    fi
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

    log "building native GCC $VERSION for $HOST_PLATFORM"

    mapfile -t gcc_dep_args < <(gcc_dependency_configure_args)
    mapfile -t gcc_feature_args < <(gcc_feature_configure_args)

    prepare_gcc_prerequisites "$gcc_src"
    require_bundled_native_binutils_tools

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    (
        cd "$build_dir"
        export PATH="$PREFIX/bin:$PATH"

        "$(configure_script_for_build "$gcc_src" "$build_dir")" \
            --prefix="$PREFIX" \
            --disable-werror \
            --disable-multilib \
            --enable-bootstrap \
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
        --prefix="$PREFIX" \
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
        export PATH="$PREFIX/bin:$PATH"

        "$configure_script" \
            --prefix="$PREFIX" \
            --target="$TARGET_TRIPLE" \
            --disable-werror \
            --disable-multilib \
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
        export PATH="$PREFIX/bin:$PATH"

        CC="$TARGET_TRIPLE-gcc" \
        AR="$TARGET_TRIPLE-ar" \
        RANLIB="$TARGET_TRIPLE-ranlib" \
        STRIP="$TARGET_TRIPLE-strip" \
        DLLTOOL="$TARGET_TRIPLE-dlltool" \
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
        export PATH="$PREFIX/bin:$PATH"

        CC="$TARGET_TRIPLE-gcc" \
        AR="$TARGET_TRIPLE-ar" \
        RANLIB="$TARGET_TRIPLE-ranlib" \
        STRIP="$TARGET_TRIPLE-strip" \
        DLLTOOL="$TARGET_TRIPLE-dlltool" \
        "$configure_script" \
            --host="$TARGET_TRIPLE" \
            --prefix="$PREFIX/$TARGET_TRIPLE"
        make -j"$CUP_JOBS"
        make install
    )
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
    local target_library_flags

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
    target_library_flags="$(gcc_target_library_flags)"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    configure_script="$(configure_script_for_build "$gcc_src" "$build_dir")"

    (
        cd "$build_dir"

        export PATH="$PREFIX/bin:$PATH"

        export CC="$host_cc"
        export CXX="$host_cxx"

        unset CC_FOR_TARGET
        unset CXX_FOR_TARGET

        if [ -n "$target_library_flags" ]; then
            log "using target library flags for GCC runtime libraries: $target_library_flags"
            export CFLAGS_FOR_TARGET="$target_library_flags"
            export CXXFLAGS_FOR_TARGET="$target_library_flags"
        fi

        export AR_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-ar$exe_suffix"
        export AS_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-as$exe_suffix"
        export LD_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-ld$exe_suffix"
        export NM_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-nm$exe_suffix"
        export RANLIB_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-ranlib$exe_suffix"
        export STRIP_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-strip$exe_suffix"
        export DLLTOOL_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-dlltool$exe_suffix"
        export WINDRES_FOR_TARGET="$PREFIX/bin/$TARGET_TRIPLE-windres$exe_suffix"

        log_final_gcc_tools

        "$configure_script" \
            --prefix="$PREFIX" \
            --target="$TARGET_TRIPLE" \
            --disable-werror \
            --disable-multilib \
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

    create_native_windows_aliases
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
    local has_target_prefix

    includes_libstdcxx="$(metadata_bool_for_files "$PREFIX" 'libstdc++*')"
    includes_lto="$(metadata_bool_for_files "$PREFIX" 'liblto_plugin*' 'lto1*')"
    includes_openmp="$(metadata_bool_for_files "$PREFIX" 'libgomp*' 'omp.h')"
    includes_sanitizers="$(metadata_bool_for_files "$PREFIX" 'libasan*' 'libubsan*' 'libtsan*' 'liblsan*')"
    includes_asan="$(metadata_bool_for_files "$PREFIX" 'libasan*')"
    includes_ubsan="$(metadata_bool_for_files "$PREFIX" 'libubsan*')"
    has_gcc="$(metadata_bool_for_executable "$PREFIX" gcc)"
    has_gpp="$(metadata_bool_for_executable "$PREFIX" g++)"
    has_cpp="$(metadata_bool_for_executable "$PREFIX" cpp)"
    has_lto_dump="$(metadata_bool_for_executable "$PREFIX" lto-dump)"
    has_gcov="$(metadata_bool_for_executable "$PREFIX" gcov)"
    has_plugin="$(metadata_bool_for_files "$PREFIX" 'liblto_plugin*')"
    has_sysroot="$(metadata_bool_for_dirs "$PREFIX" "$TARGET_TRIPLE")"
    has_target_prefix="$(metadata_bool_for_executable "$PREFIX" "$TARGET_TRIPLE-gcc")"

    if [ "$TARGET_PLATFORM" = "linux-x64" ]; then
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
            tool_naming="native-and-target-prefixed"
        fi
    elif [ "$HOST_PLATFORM" = "linux-x64" ] && [ "$TARGET_PLATFORM" = "linux-x64" ]; then
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
        "config.bootstrap=$bootstrap"
        "config.tool_naming=$tool_naming"
        "config.openmp=attempted"
        "config.sanitizers=attempted"
        "entry.gcc=$(package_bin_entry_path "$PREFIX" gcc)"
        "entry.g++=$(package_bin_entry_path "$PREFIX" g++)"
        "entry.cpp=$(package_bin_entry_path "$PREFIX" cpp)"
        "entry.gcov=$(package_bin_entry_path "$PREFIX" gcov)"
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
        "features.target_prefixed_tools=$has_target_prefix"
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
            "entry.target_gcc=$(package_bin_entry_path "$PREFIX" $TARGET_TRIPLE-gcc)"
            "entry.target_g++=$(package_bin_entry_path "$PREFIX" $TARGET_TRIPLE-g++)"
            "entry.target_ar=$(package_bin_entry_path "$PREFIX" $TARGET_TRIPLE-ar)"
            "entry.target_ld=$(package_bin_entry_path "$PREFIX" $TARGET_TRIPLE-ld)"
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

    write_gcc_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"