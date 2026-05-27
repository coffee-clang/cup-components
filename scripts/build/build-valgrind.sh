#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/package/package-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 <version|stable|latest> <host_platform> <revision>

Examples:
  $0 stable linux-x64 1
  $0 stable linux-arm64 1
  $0 3.27.0 linux-arm64 1
USAGE
}

if [ "$#" -ne 3 ]; then
    usage >&2
    exit 2
fi

REQUESTED_VERSION="$1"
HOST_PLATFORM="$2"
TARGET_PLATFORM="$HOST_PLATFORM"
REVISION="$3"

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

need_valgrind_tools() {
    need curl
    need tar
    need make
    need gcc
    need perl
    need zip
    need mpicc
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

find_valgrind_mpi_library() {
    find "$PREFIX" \
        \( -path "$PREFIX/libexec/valgrind/libmpiwrap-*" -o -path "$PREFIX/lib/valgrind/libmpiwrap-*" \) \
        -type f -print -quit
}

valgrind_has_mpi_support() {
    [ -n "$(find_valgrind_mpi_library)" ]
}

valgrind_mpi_metadata_value() {
    if valgrind_has_mpi_support; then
        printf '%s\n' true
    else
        printf '%s\n' false
    fi
}

valgrind_mpi_library_metadata_value() {
    local mpi_library
    mpi_library="$(find_valgrind_mpi_library)"

    if [ -n "$mpi_library" ]; then
        printf '%s\n' "${mpi_library#$PREFIX/}"
    else
        printf '%s\n' ""
    fi
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
    local configure_args=(
        --prefix="$PREFIX"
        --enable-only64bit
    )

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
}

write_valgrind_info() {
    local runtime_dir
    local mpi_library
    local has_mpi
    local has_valgrind
    local has_relocatable

    runtime_dir="$(find_valgrind_runtime_dir)"
    mpi_library="$(valgrind_mpi_library_metadata_value)"
    has_mpi="$(valgrind_mpi_metadata_value)"
    has_valgrind="$(metadata_bool_for_executable "$PREFIX" valgrind)"
    has_relocatable="$(metadata_bool_for_executable "$PREFIX" valgrind)"

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
        "source.primary.name=valgrind"
        "source.primary.version=$VERSION"
        "source.primary.url=$SOURCE_URL"
        "config.configure=--enable-only64bit"
        "config.only64bit=true"
        "config.mpi=auto"
        "entry.valgrind=bin/valgrind"
        "contents.self_contained=true"
        "contents.relocatable_wrapper=true"
        "contents.runtime_dir=${runtime_dir#$PREFIX/}"
        "contents.tools=memcheck,cachegrind,callgrind,massif,helgrind,drd,dhat,lackey"
        "contents.experimental_tools=exp-bbv"
        "contents.internal_tools=none"
        "contents.mpi=$has_mpi"
        "features.memcheck=$has_valgrind"
        "features.cachegrind=$(metadata_bool_for_files "$PREFIX" 'cachegrind-*' 'vgpreload_*cachegrind*')"
        "features.callgrind=$(metadata_bool_for_files "$PREFIX" 'callgrind-*' 'vgpreload_*callgrind*')"
        "features.massif=$(metadata_bool_for_files "$PREFIX" 'massif-*' 'vgpreload_*massif*')"
        "features.helgrind=$(metadata_bool_for_files "$PREFIX" 'helgrind-*' 'vgpreload_*helgrind*')"
        "features.drd=$(metadata_bool_for_files "$PREFIX" 'drd-*' 'vgpreload_*drd*')"
        "features.dhat=$(metadata_bool_for_files "$PREFIX" 'dhat-*' 'vgpreload_*dhat*')"
        "features.lackey=$(metadata_bool_for_files "$PREFIX" 'lackey-*')"
        "features.exp_bbv=$(metadata_bool_for_files "$PREFIX" 'exp-bbv-*')"
        "features.mpiwrap=$has_mpi"
        "features.gdbserver=$has_valgrind"
        "features.relocatable=$has_relocatable"
    )

    if [ -n "$mpi_library" ]; then
        info+=("contents.mpi_library=$mpi_library")
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
    source_dir="$(prepare_source_tree valgrind "$VERSION" "$SOURCE_URL" "valgrind-$VERSION.tar.bz2")"

    build_valgrind "$source_dir"
    write_valgrind_info
    create_packages "$TOOL" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION" "$PREFIX"
}

main "$@"
