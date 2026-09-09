#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/package/package-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 <version|stable> <platform>

Examples:
  $0 stable linux-x64
  $0 stable linux-arm64
USAGE
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 2
fi

REQUESTED_VERSION="$1"
HOST_PLATFORM="$2"
TARGET_PLATFORM="$HOST_PLATFORM"
REVISION=""

TOOL="valgrind"
COMPONENT="analyzer"
VERSION="$(resolve_version valgrind "$REQUESTED_VERSION")"
PACKAGE_VERSION="$(package_version_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
HOST_TRIPLE="$(platform_triple "$HOST_PLATFORM")"
TARGET_TRIPLE="$(platform_triple "$TARGET_PLATFORM")"
TARGET_FAMILY="$(platform_family "$TARGET_PLATFORM")"
TARGET_RUNTIME="$(platform_runtime "$TARGET_PLATFORM")"
THREAD_MODEL="$(platform_thread_model "$TARGET_PLATFORM")"
BUILD_ENVIRONMENT="${CUP_BUILD_ENVIRONMENT:-manual}"
SOURCE_POLICY="source-release"
SOURCE_URL="$(source_url_valgrind "$VERSION")"
PREFIX="$CUP_STAGE_DIR/$(package_base_name "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION")"
VALGRIND_ONLY64BIT=false
VALGRIND_MPI_DISABLED=false
VALGRIND_GDBSCRIPTS_DISABLED=false
VALGRIND_CONFIGURE_POLICY=default

need_valgrind_tools() {
    need curl
    need tar
    need make
    need gcc
    need perl
    need zip
    need unzip
}


validate_platforms() {
    case "$HOST_PLATFORM" in
        linux-x64|linux-arm64)
            ;;
        *)
            die "Valgrind packages are currently supported only for linux-x64 and linux-arm64 hosts"
            ;;
    esac

    if [ "$TARGET_PLATFORM" != "$HOST_PLATFORM" ]; then
        die "Valgrind packages use only a host platform and do not support cross builds: $HOST_PLATFORM -> $TARGET_PLATFORM"
    fi
}

find_valgrind_runtime_dir() {
    if [ -d "$PREFIX/libexec/valgrind" ]; then
        printf '%s\n' "$PREFIX/libexec/valgrind"
        return 0
    fi

    if [ -d "$PREFIX/lib/valgrind" ]; then
        printf '%s\n' "$PREFIX/lib/valgrind"
        return 0
    fi

    die "could not find installed Valgrind runtime directory under $PREFIX"
}

make_valgrind_relocatable() {
    local valgrind_bin="$PREFIX/bin/valgrind"
    local real_bin="$PREFIX/bin/valgrind.bin"
    local runtime_dir
    local runtime_name

    if [ ! -x "$valgrind_bin" ]; then
        die "expected Valgrind binary not found: $valgrind_bin"
    fi

    runtime_dir="$(find_valgrind_runtime_dir)"
    runtime_name="$(basename "$runtime_dir")"

    mv "$valgrind_bin" "$real_bin"

    cat > "$valgrind_bin" <<'WRAPPER'
#!/usr/bin/env sh
set -eu

resolve_self() {
    case "$0" in
        /*)
            printf '%s\n' "$0"
            ;;
        *)
            command -v -- "$0"
            ;;
    esac
}

self_path="$(resolve_self)"

if command -v realpath >/dev/null 2>&1; then
    self_path="$(realpath "$self_path")"
elif command -v readlink >/dev/null 2>&1; then
    resolved_path="$(readlink -f "$self_path" 2>/dev/null || true)"
    if [ -n "$resolved_path" ]; then
        self_path="$resolved_path"
    fi
fi

bin_dir="$(CDPATH= cd -- "$(dirname -- "$self_path")" && pwd)"
prefix="$(CDPATH= cd -- "$bin_dir/.." && pwd)"

if [ -d "$prefix/libexec/valgrind" ]; then
    VALGRIND_LIB="$prefix/libexec/valgrind"
elif [ -d "$prefix/lib/valgrind" ]; then
    VALGRIND_LIB="$prefix/lib/valgrind"
fi

# Valgrind propagates runtime preload paths through LD_PRELOAD.  The Linux
# dynamic loader treats whitespace and ':' as entry separators and offers no
# escaping, so expose a separator-free process-local alias only when needed.
case "$VALGRIND_LIB" in
    *[[:space:]]*|*:*)
        exec 9<"$VALGRIND_LIB"
        VALGRIND_LIB=/proc/self/fd/9
        ;;
esac

export VALGRIND_LIB
exec "$bin_dir/valgrind.bin" "$@"
WRAPPER

    chmod +x "$valgrind_bin"
    chmod +x "$real_bin"

    log "made Valgrind relocatable with runtime directory: $runtime_name"
}


build_valgrind() {
    local source_dir="$1"
    local build_dir="$CUP_BUILD_DIR/valgrind-$VERSION-$HOST_PLATFORM-$TARGET_PLATFORM"
    local configure_help
    local configure_args=(--prefix="$PREFIX")
    local policy_args=()

    configure_help="$("$source_dir/configure" --help)" ||
        die "could not inspect Valgrind configure options"

    if printf '%s\n' "$configure_help" | grep -F -- '--enable-only64bit' >/dev/null; then
        configure_args+=(--enable-only64bit)
        policy_args+=(--enable-only64bit)
        VALGRIND_ONLY64BIT=true
    fi
    if printf '%s\n' "$configure_help" | grep -F -- '--with-mpicc' >/dev/null; then
        configure_args+=(--without-mpicc)
        policy_args+=(--without-mpicc)
        VALGRIND_MPI_DISABLED=true
    fi
    if printf '%s\n' "$configure_help" | grep -F -- '--with-gdbscripts-dir' >/dev/null; then
        configure_args+=(--without-gdbscripts-dir)
        policy_args+=(--without-gdbscripts-dir)
        VALGRIND_GDBSCRIPTS_DISABLED=true
    fi
    if [ "${#policy_args[@]}" -gt 0 ]; then
        VALGRIND_CONFIGURE_POLICY="$(IFS=';'; printf '%s' "${policy_args[*]}")"
    fi

    log "building Valgrind $VERSION for $HOST_PLATFORM -> $TARGET_PLATFORM"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    (
        cd "$build_dir"
        "$source_dir/configure" "${configure_args[@]}"
        make -j"$CUP_JOBS"
        make install
    )

    make_valgrind_relocatable
    prune_valgrind_tool_development_sdk
    make_valgrind_pkgconfig_relocatable
}

prune_valgrind_tool_development_sdk() {
    local include_dir="$PREFIX/include/valgrind"

    # Keep the public client-request headers used by Valgrind-aware programs,
    # but exclude the separate SDK for developing new Valgrind tools.
    if [ -d "$include_dir" ]; then
        rm -f "$include_dir/config.h"
        find "$include_dir" -maxdepth 1 -type f \
            \( -name 'libvex*.h' -o -name 'pub_tool_*.h' \) -delete
        rm -rf "$include_dir/vki"
    fi

    # These archives are link-time inputs for developing Valgrind tools; they
    # are not used by the installed runtime tool suite.
    find "$PREFIX" -type f \
        \( -name 'libcoregrind-*.a' \
        -o -name 'libgcc-sup-*.a' \
        -o -name 'libreplacemalloc_toolpreload-*.a' \
        -o -name 'libvex-*.a' \
        -o -name 'libvexmultiarch-*.a' \) -delete

    # The optional GDB Python monitor is not part of the relocatable core package.
    # Some Valgrind releases can suppress it at configure time; remove it here
    # as well so older layouts keep the same package contract.
    find "$PREFIX" -type f -name 'valgrind-monitor.py' -delete

    # The SDK archives are the only upstream payload installed under lib/valgrind
    # when the runtime itself lives in libexec/valgrind. Remove only the empty
    # residue; a real/nonempty runtime layout is deliberately left untouched.
    rmdir "$PREFIX/lib/valgrind" 2>/dev/null || true
}


make_valgrind_pkgconfig_relocatable() {
    local pc_file="$PREFIX/lib/pkgconfig/valgrind.pc"

    [ -f "$pc_file" ] || return 0

    awk '
        /^prefix=/ { print "prefix=${pcfiledir}/../.."; next }
        /^includedir=/ { print "includedir=${prefix}/include"; next }
        { print }
    ' "$pc_file" > "$pc_file.tmp"
    mv "$pc_file.tmp" "$pc_file"
}

write_valgrind_info() {
    local runtime_dir
    local has_valgrind
    local has_vgdb
    local has_memcheck
    local has_cachegrind
    local has_callgrind
    local has_massif
    local has_helgrind
    local has_drd
    local has_dhat
    local has_lackey
    local has_exp_bbv
    local tools=()
    local tools_csv

    runtime_dir="$(find_valgrind_runtime_dir)"
    has_valgrind="$(metadata_bool_for_executable "$PREFIX" valgrind)"
    has_vgdb="$(metadata_bool_for_executable "$PREFIX" vgdb)"
    has_memcheck="$(metadata_bool_for_files "$PREFIX" 'memcheck-*' 'vgpreload_*memcheck*')"
    has_cachegrind="$(metadata_bool_for_files "$PREFIX" 'cachegrind-*' 'vgpreload_*cachegrind*')"
    has_callgrind="$(metadata_bool_for_files "$PREFIX" 'callgrind-*' 'vgpreload_*callgrind*')"
    has_massif="$(metadata_bool_for_files "$PREFIX" 'massif-*' 'vgpreload_*massif*')"
    has_helgrind="$(metadata_bool_for_files "$PREFIX" 'helgrind-*' 'vgpreload_*helgrind*')"
    has_drd="$(metadata_bool_for_files "$PREFIX" 'drd-*' 'vgpreload_*drd*')"
    has_dhat="$(metadata_bool_for_files "$PREFIX" 'dhat-*' 'vgpreload_*dhat*')"
    has_lackey="$(metadata_bool_for_files "$PREFIX" 'lackey-*')"
    has_exp_bbv="$(metadata_bool_for_files "$PREFIX" 'exp-bbv-*')"

    [ "$has_memcheck" = true ] && tools+=(memcheck)
    [ "$has_cachegrind" = true ] && tools+=(cachegrind)
    [ "$has_callgrind" = true ] && tools+=(callgrind)
    [ "$has_massif" = true ] && tools+=(massif)
    [ "$has_helgrind" = true ] && tools+=(helgrind)
    [ "$has_drd" = true ] && tools+=(drd)
    [ "$has_dhat" = true ] && tools+=(dhat)
    [ "$has_lackey" = true ] && tools+=(lackey)
    tools_csv="$(IFS=,; printf '%s' "${tools[*]}")"
    [ "$has_memcheck" = true ] || die "Valgrind package is missing the core Memcheck runtime"
    [ -n "$tools_csv" ] || die "Valgrind package has no realized runtime tools"

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
        "source.primary.name=valgrind"
        "source.primary.version=$VERSION"
        "source.primary.url=$SOURCE_URL"
        "source.primary.sha256=$(source_archive_sha256 "$SOURCE_URL" "valgrind-$VERSION.tar.bz2")"
        "config.configure=$VALGRIND_CONFIGURE_POLICY"
        "config.only64bit=$VALGRIND_ONLY64BIT"
        "config.mpi_disabled=$VALGRIND_MPI_DISABLED"
        "config.gdbscripts_disabled=$VALGRIND_GDBSCRIPTS_DISABLED"
        "$(info_required_entry entry.valgrind "$PREFIX" valgrind)"
        "contents.relocatable_wrapper=true"
        "contents.runtime_dir=${runtime_dir#$PREFIX/}"
        "contents.tools=$tools_csv"
        "contents.mpi=false"
        "contents.vgdb=$has_vgdb"
        "features.memcheck=$has_memcheck"
    )

    if [ "$has_exp_bbv" = true ]; then
        info+=("contents.experimental_tools=exp-bbv")
    fi

    write_info_file "$PREFIX" "${info[@]}"
}


main() {
    validate_platforms
    make_dirs
    need_valgrind_tools

    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"

    local source_dir
    source_dir="$(prepare_source_tree valgrind "$VERSION" "$SOURCE_URL" "valgrind-$VERSION.tar.bz2" "${CUP_SOURCE_SHA256:-}")"

    build_valgrind "$source_dir"
    write_valgrind_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
