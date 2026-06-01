#!/usr/bin/env bash
set -euo pipefail

CUP_REPO_OWNER="${CUP_REPO_OWNER:-coffee-clang}"
CUP_REPO_NAME="${CUP_REPO_NAME:-cup}"

CUP_ROOT="${CUP_ROOT:-$(pwd)}"
CUP_WORK_DIR="${CUP_WORK_DIR:-$CUP_ROOT/.cup-build}"
CUP_SRC_DIR="${CUP_SRC_DIR:-$CUP_WORK_DIR/src}"
CUP_BUILD_DIR="${CUP_BUILD_DIR:-$CUP_WORK_DIR/build}"
CUP_STAGE_DIR="${CUP_STAGE_DIR:-$CUP_WORK_DIR/stage}"
CUP_OUT_DIR="${CUP_OUT_DIR:-$CUP_ROOT/dist}"

if [ -z "${CUP_JOBS:-}" ]; then
    if [ "${RUNNER_OS:-}" = "Windows" ] && [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then
        CUP_JOBS="$NUMBER_OF_PROCESSORS"
    elif command -v nproc >/dev/null 2>&1; then
        CUP_JOBS="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        CUP_JOBS="$(sysctl -n hw.ncpu)"
    else
        CUP_JOBS=2
    fi
fi

DEFAULT_GCC_VERSION="${DEFAULT_GCC_VERSION:-16.1.0}"
DEFAULT_GDB_VERSION="${DEFAULT_GDB_VERSION:-17.1}"
DEFAULT_BINUTILS_VERSION="${DEFAULT_BINUTILS_VERSION:-2.46.0}"
DEFAULT_MINGW_VERSION="${DEFAULT_MINGW_VERSION:-14.0.0}"
DEFAULT_LLVM_VERSION="${DEFAULT_LLVM_VERSION:-22.1.5}"
DEFAULT_VALGRIND_VERSION="${DEFAULT_VALGRIND_VERSION:-3.27.0}"
DEFAULT_DRMEMORY_VERSION="${DEFAULT_DRMEMORY_VERSION:-2.6.0}"
DEFAULT_LEAKS_VERSION="${DEFAULT_LEAKS_VERSION:-1.0.0}"

log() {
    printf '[cup-build] %s\n' "$*" >&2
}

die() {
    printf '[cup-build:error] %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

make_dirs() {
    mkdir -p "$CUP_SRC_DIR" "$CUP_BUILD_DIR" "$CUP_STAGE_DIR" "$CUP_OUT_DIR"
}

resolve_version() {
    local tool="$1"
    local requested="$2"

    if [ "$requested" != "latest" ] && [ "$requested" != "stable" ]; then
        printf '%s\n' "$requested"
        return 0
    fi

    case "$tool" in
        gcc) printf '%s\n' "$DEFAULT_GCC_VERSION" ;;
        gdb) printf '%s\n' "$DEFAULT_GDB_VERSION" ;;
        binutils) printf '%s\n' "$DEFAULT_BINUTILS_VERSION" ;;
        mingw|mingw-w64) printf '%s\n' "$DEFAULT_MINGW_VERSION" ;;
        clang|lld|lldb|clangd|clang-format|clang-tidy|llvm) printf '%s\n' "$DEFAULT_LLVM_VERSION" ;;
        valgrind) printf '%s\n' "$DEFAULT_VALGRIND_VERSION" ;;
        drmemory) printf '%s\n' "$DEFAULT_DRMEMORY_VERSION" ;;
        leaks) printf '%s\n' "$DEFAULT_LEAKS_VERSION" ;;
        *) die "cannot resolve default version for tool: $tool" ;;
    esac
}

platform_triple() {
    local platform="$1"

    case "$platform" in
        linux-x64) printf '%s\n' "x86_64-linux-gnu" ;;
        linux-arm64) printf '%s\n' "aarch64-linux-gnu" ;;
        windows-x64) printf '%s\n' "x86_64-w64-mingw32" ;;
        macos-x64) printf '%s\n' "x86_64-apple-darwin" ;;
        macos-arm64) printf '%s\n' "arm64-apple-darwin" ;;
        *) die "unsupported platform: $platform" ;;
    esac
}

platform_family() {
    local platform="$1"

    case "$platform" in
        linux-x64|linux-arm64) printf '%s\n' "gnu" ;;
        windows-x64) printf '%s\n' "gnu" ;;
        macos-x64|macos-arm64) printf '%s\n' "darwin" ;;
        *) die "unsupported platform: $platform" ;;
    esac
}

platform_runtime() {
    local platform="$1"

    case "$platform" in
        linux-x64|linux-arm64) printf '%s\n' "glibc" ;;
        windows-x64) printf '%s\n' "ucrt" ;;
        macos-x64|macos-arm64) printf '%s\n' "libSystem" ;;
        *) die "unsupported platform: $platform" ;;
    esac
}

platform_thread_model() {
    local platform="$1"

    case "$platform" in
        linux-x64|linux-arm64|windows-x64|macos-x64|macos-arm64) printf '%s\n' "posix" ;;
        *) die "unsupported platform: $platform" ;;
    esac
}

host_extension() {
    local host_platform="$1"

    case "$host_platform" in
        windows-x64) printf '%s\n' ".exe" ;;
        *) printf '%s\n' "" ;;
    esac
}

is_windows_platform() {
    case "$1" in
        windows-x64) return 0 ;;
        *) return 1 ;;
    esac
}

is_macos_platform() {
    case "$1" in
        macos-x64|macos-arm64) return 0 ;;
        *) return 1 ;;
    esac
}

is_linux_platform() {
    case "$1" in
        linux-x64|linux-arm64) return 0 ;;
        *) return 1 ;;
    esac
}

is_supported_platform() {
    case "$1" in
        linux-x64|linux-arm64|windows-x64|macos-x64|macos-arm64) return 0 ;;
        *) return 1 ;;
    esac
}

is_cross_build() {
    [ "$1" != "$2" ]
}

package_uses_revision_in_name() {
    local tool="$1"
    local host_platform="$2"
    local target_platform="$3"

    if [ "$tool" = "gcc" ]; then
        return 0
    fi

    if is_cross_build "$host_platform" "$target_platform"; then
        return 0
    fi

    return 1
}

package_version_name() {
    local tool="$1"
    local version="$2"
    local host_platform="$3"
    local target_platform="$4"
    local revision="$5"

    if package_uses_revision_in_name "$tool" "$host_platform" "$target_platform"; then
        printf '%s-rev%s\n' "$version" "$revision"
    else
        printf '%s\n' "$version"
    fi
}

package_base_name() {
    local tool="$1"
    local version="$2"
    local host_platform="$3"
    local target_platform="$4"
    local revision="$5"

    local package_version
    package_version="$(package_version_name "$tool" "$version" "$host_platform" "$target_platform" "$revision")"

    printf '%s-%s-%s-%s\n' "$tool" "$package_version" "$host_platform" "$target_platform"
}

release_tag_for_package() {
    package_base_name "$@"
}

source_url_gcc() {
    local version="$1"
    printf 'https://ftp.gnu.org/gnu/gcc/gcc-%s/gcc-%s.tar.xz\n' "$version" "$version"
}

source_url_gdb() {
    local version="$1"
    printf 'https://ftp.gnu.org/gnu/gdb/gdb-%s.tar.xz\n' "$version"
}

source_url_binutils() {
    local version="$1"
    printf 'https://ftp.gnu.org/gnu/binutils/binutils-%s.tar.xz\n' "$version"
}

source_url_mingw() {
    local version="$1"
    printf 'https://sourceforge.net/projects/mingw-w64/files/mingw-w64/mingw-w64-release/mingw-w64-v%s.tar.bz2/download\n' "$version"
}

source_url_llvm_project() {
    local version="$1"
    printf 'https://github.com/llvm/llvm-project/releases/download/llvmorg-%s/llvm-project-%s.src.tar.xz\n' "$version" "$version"
}

source_url_valgrind() {
    local version="$1"
    printf 'https://sourceware.org/pub/valgrind/valgrind-%s.tar.bz2\n' "$version"
}

source_url_drmemory_windows() {
    local version="$1"
    printf 'https://github.com/DynamoRIO/drmemory/releases/download/release_%s/DrMemory-Windows-%s.zip\n' "$version" "$version"
}


archive_name_from_url() {
    local url="$1"
    local fallback="$2"
    local base

    base="$(basename "$url")"
    if [ "$base" = "download" ] || [ -z "$base" ]; then
        printf '%s\n' "$fallback"
    else
        printf '%s\n' "$base"
    fi
}

fetch() {
    local url="$1"
    local output="$2"

    if [ -f "$output" ]; then
        log "using cached archive: $output"
        return 0
    fi

    log "downloading: $url"

    if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$output" "$url"; then
        rm -f "$output"
        return 1
    fi
}

extract_archive() {
    local archive="$1"
    local destination="$2"

    rm -rf "$destination"
    mkdir -p "$destination"

    case "$archive" in
        *.tar.xz) tar -xJf "$archive" -C "$destination" --strip-components=1 ;;
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$destination" --strip-components=1 ;;
        *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$destination" --strip-components=1 ;;
        *.zip) unzip -q "$archive" -d "$destination" ;;
        *) die "unsupported archive format: $archive" ;;
    esac
}

prepare_source_tree() {
    local name="$1"
    local version="$2"
    local url="$3"
    local fallback_archive="$4"

    local archive
    local source_dir

    archive="$CUP_SRC_DIR/$(archive_name_from_url "$url" "$fallback_archive")"
    source_dir="$CUP_SRC_DIR/$name-$version"

    fetch "$url" "$archive"
    extract_archive "$archive" "$source_dir"

    printf '%s\n' "$source_dir"
}

info_key_is_valid() {
    local key="$1"

    case "$key" in
        ""|*[!A-Za-z0-9_.+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

write_info_file() {
    local prefix="$1"
    shift

    mkdir -p "$prefix"
    : > "$prefix/info.txt"

    local seen_file="$prefix/.info-keys.tmp"
    local line
    local key
    local value

    : > "$seen_file"

    for line in "$@"; do
        [ -n "$line" ] || continue

        case "$line" in
            *=*) ;;
            *)
                rm -f "$seen_file"
                die "invalid info metadata line without '=': $line"
                ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"

        if ! info_key_is_valid "$key"; then
            rm -f "$seen_file"
            die "invalid info metadata key: $key"
        fi

        if [ -z "$value" ]; then
            rm -f "$seen_file"
            die "empty value for info metadata key: $key"
        fi

        if grep -Fx -- "$key" "$seen_file" >/dev/null 2>&1; then
            rm -f "$seen_file"
            die "duplicate info metadata key: $key"
        fi

        printf '%s\n' "$key" >> "$seen_file"
        printf '%s\n' "$line" >> "$prefix/info.txt"
    done

    rm -f "$seen_file"
}

info_bool() {
    if "$@" >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

prefix_executable_exists() {
    local prefix="$1"
    local name="$2"
    local candidate

    while IFS= read -r candidate; do
        if package_bin_exact_file_exists "$prefix" "$candidate"; then
            return 0
        fi
    done < <(package_bin_candidate_names "$name")

    return 1
}

prefix_file_exists_any() {
    local prefix="$1"
    shift

    local pattern
    for pattern in "$@"; do
        if find "$prefix" -type f -name "$pattern" -print -quit | grep -q .; then
            return 0
        fi
    done

    return 1
}

prefix_dir_exists_any() {
    local prefix="$1"
    shift

    local pattern
    for pattern in "$@"; do
        if find "$prefix" -type d -name "$pattern" -print -quit | grep -q .; then
            return 0
        fi
    done

    return 1
}

metadata_bool_for_executable() {
    local prefix="$1"
    local name="$2"
    info_bool prefix_executable_exists "$prefix" "$name"
}

package_bin_candidate_names() {
    local name="$1"

    if is_windows_platform "$HOST_PLATFORM"; then
        printf '%s\n' "$name.exe" "$name.bat" "$name.cmd" "$name"
    else
        printf '%s\n' "$name"
    fi
}

package_bin_exact_file_exists() {
    local prefix="$1"
    local candidate="$2"

    [ -n "$candidate" ] || return 1
    [ -d "$prefix/bin" ] || return 1

    [ -n "$(find "$prefix/bin" -maxdepth 1 -name "$candidate" -print -quit 2>/dev/null)" ]
}

package_bin_entry_path() {
    local prefix="$1"
    local name="$2"
    local candidate

    while IFS= read -r candidate; do
        if package_bin_exact_file_exists "$prefix" "$candidate"; then
            printf 'bin/%s\n' "$candidate"
            return 0
        fi
    done < <(package_bin_candidate_names "$name")

    printf 'bin/%s\n' "$name"
}

package_bin_entry_path_if_present() {
    local prefix="$1"
    local name="$2"
    local candidate

    while IFS= read -r candidate; do
        if package_bin_exact_file_exists "$prefix" "$candidate"; then
            printf 'bin/%s\n' "$candidate"
            return 0
        fi
    done < <(package_bin_candidate_names "$name")

    return 1
}

package_required_bin_entry_path() {
    local prefix="$1"
    local name="$2"

    if package_bin_entry_path_if_present "$prefix" "$name"; then
        return 0
    fi

    die "required package entry was not found in bin: $name"
}

info_entry_if_present() {
    local key="$1"
    local prefix="$2"
    local name="$3"
    local path

    if path="$(package_bin_entry_path_if_present "$prefix" "$name")"; then
        printf '%s=%s\n' "$key" "$path"
    fi
}

info_required_entry() {
    local key="$1"
    local prefix="$2"
    local name="$3"

    printf '%s=%s\n' "$key" "$(package_required_bin_entry_path "$prefix" "$name")"
}

metadata_bool_for_files() {
    local prefix="$1"
    shift
    info_bool prefix_file_exists_any "$prefix" "$@"
}

metadata_bool_for_dirs() {
    local prefix="$1"
    shift
    info_bool prefix_dir_exists_any "$prefix" "$@"
}

cmake_cache_value() {
    local cache_dir="$1"
    local key="$2"
    local cache_file="$cache_dir/CMakeCache.txt"

    [ -f "$cache_file" ] || return 0
    grep -E "^${key}(:[^=]*)?=" "$cache_file" | sed 's/^[^=]*=//' | tail -n 1 || true
}

cmake_cache_bool() {
    local cache_dir="$1"
    local key="$2"
    local value

    value="$(cmake_cache_value "$cache_dir" "$key" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        on|yes|true|1) printf 'true\n' ;;
        off|no|false|0|'') printf 'false\n' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

append_info_if_not_empty() {
    local -n out_ref="$1"
    local key="$2"
    local value="$3"

    if [ -n "$value" ]; then
        out_ref+=("$key=$value")
    fi
}

package_formats_for_host() {
    local host_platform="$1"

    if is_windows_platform "$host_platform"; then
        printf '%s\n' zip tar.xz tar.gz
    else
        printf '%s\n' tar.xz tar.gz zip
    fi
}

package_formats_csv() {
    local host_platform="$1"
    package_formats_for_host "$host_platform" | paste -sd, -
}


windows_runtime_dll_allowed_path() {
    local path="$1"

    if [ -n "${PREFIX:-}" ]; then
        case "$path" in
            "$PREFIX"/bin/*.dll|"$PREFIX"/lib/*.dll)
                return 0
                ;;
        esac
    fi

    case "$path" in
        /ucrt64/bin/*.dll|/mingw64/bin/*.dll|/mingw32/bin/*.dll|/clang64/bin/*.dll|/clangarm64/bin/*.dll|/usr/bin/*.dll)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

windows_runtime_dll_name_is_system() {
    local name
    name="$(basename "$1" | tr '[:upper:]' '[:lower:]')"

    case "$name" in
        api-ms-win-*.dll|ext-ms-win-*.dll)
            return 0
            ;;
        advapi32.dll|bcrypt.dll|bcryptprimitives.dll|combase.dll|comctl32.dll|comdlg32.dll|crypt32.dll|cryptbase.dll|cryptsp.dll|dbghelp.dll|dnsapi.dll|gdi32.dll|gdi32full.dll|imm32.dll|iphlpapi.dll|kernel32.dll|kernelbase.dll|msvcp_win.dll|msvcrt.dll|netapi32.dll|ntdll.dll|ole32.dll|oleaut32.dll|propsys.dll|psapi.dll|rpcrt4.dll|rsaenh.dll|sechost.dll|shell32.dll|shcore.dll|shlwapi.dll|ucrtbase.dll|user32.dll|userenv.dll|uuid.dll|version.dll|win32u.dll|winhttp.dll|winmm.dll|wintypes.dll|ws2_32.dll)
            return 0
            ;;
        vcruntime*.dll|msvcp*.dll|concrt*.dll)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

windows_runtime_dll_is_system_path() {
    local path="$1"
    local lower

    lower="$(printf '%s\n' "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        /c/windows/*|/windows/*|c:/*)
            return 0
            ;;
    esac

    if ! printf '%s\n' "$lower" | grep -q '/'; then
        windows_runtime_dll_name_is_system "$lower"
        return $?
    fi

    return 1
}

windows_runtime_dll_search_dirs() {
    local bin_dir="${1:-}"

    [ -n "$bin_dir" ] && printf '%s\n' "$bin_dir"
    [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ] && printf '%s\n' "$PREFIX/bin"
    [ -n "${MINGW_PREFIX:-}" ] && [ -d "$MINGW_PREFIX/bin" ] && printf '%s\n' "$MINGW_PREFIX/bin"

    for dir in /clang64/bin /ucrt64/bin /mingw64/bin /mingw32/bin /clangarm64/bin /usr/bin; do
        [ -d "$dir" ] && printf '%s\n' "$dir"
    done
}

collect_windows_package_pe_files() {
    local bin_dir="$1"

    if [ -d "$bin_dir" ]; then
        find "$bin_dir" -maxdepth 1 -type f \( -name '*.exe' -o -name '*.dll' \)
    fi

    if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/lib" ]; then
        find "$PREFIX/lib" -type f \( -name '*.dll' -o -name '*.pyd' \)
    fi
}

windows_runtime_dll_extract_paths() {
    local file="$1"

    ldd "$file" 2>/dev/null | while IFS= read -r line; do
        printf '%s\n' "$line" | sed -n 's/.*=>[[:space:]]*\([^[:space:]]*\.dll\).*/\1/p'
        printf '%s\n' "$line" | sed -n 's/^[[:space:]]*\([^[:space:]]*\.dll\).*/\1/p'
    done | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u
}

windows_pe_import_dll_names() {
    local file="$1"
    local objdump_cmd=""

    if command -v llvm-objdump >/dev/null 2>&1; then
        objdump_cmd="llvm-objdump"
    elif command -v objdump >/dev/null 2>&1; then
        objdump_cmd="objdump"
    else
        return 0
    fi

    "$objdump_cmd" -p "$file" 2>/dev/null | \
        sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        sed '/^$/d' | sort -u
}

find_windows_runtime_dll_by_name() {
    local dll_name="$1"
    local bin_dir="${2:-}"
    local dir
    local candidate

    [ -n "$dll_name" ] || return 0

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        candidate="$dir/$dll_name"
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi

        candidate="$(find "$dir" -maxdepth 1 -type f -iname "$dll_name" -print -quit 2>/dev/null || true)"
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(windows_runtime_dll_search_dirs "$bin_dir")

    return 0
}

copy_windows_runtime_dlls() {
    local bin_dir="$1"
    local queue_file
    local seen_file
    local current
    local dll_path
    local dll_name

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    if ! command -v ldd >/dev/null 2>&1; then
        die "ldd is required to collect Windows runtime DLLs"
    fi

    if [ ! -d "$bin_dir" ]; then
        return 0
    fi

    log "copying Windows runtime DLL closure for binaries in $bin_dir"

    queue_file="$(mktemp)"
    seen_file="$(mktemp)"

    collect_windows_package_pe_files "$bin_dir" | sort -u > "$queue_file"
    : > "$seen_file"

    while [ -s "$queue_file" ]; do
        current="$(head -n 1 "$queue_file")"
        tail -n +2 "$queue_file" > "$queue_file.next"
        mv "$queue_file.next" "$queue_file"

        if grep -Fx -- "$current" "$seen_file" >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$current" >> "$seen_file"

        while IFS= read -r dll_path; do
            [ -n "$dll_path" ] || continue
            [ -f "$dll_path" ] || continue

            if windows_runtime_dll_is_system_path "$dll_path"; then
                continue
            fi

            if ! windows_runtime_dll_allowed_path "$dll_path"; then
                log "  skipping non-package DLL dependency: $dll_path"
                continue
            fi

            dll_name="$(basename "$dll_path")"

            if [ -f "$bin_dir/$dll_name" ]; then
                continue
            fi

            cp -f "$dll_path" "$bin_dir/$dll_name"
            log "  copied: $dll_name"
            printf '%s\n' "$bin_dir/$dll_name" >> "$queue_file"
        done < <(windows_runtime_dll_extract_paths "$current")

        while IFS= read -r dll_name; do
            [ -n "$dll_name" ] || continue

            if windows_runtime_dll_name_is_system "$dll_name"; then
                continue
            fi

            if [ -f "$bin_dir/$dll_name" ]; then
                continue
            fi

            dll_path="$(find_windows_runtime_dll_by_name "$dll_name" "$bin_dir")"
            if [ -z "$dll_path" ] || [ ! -f "$dll_path" ]; then
                log "  unresolved PE import for $(basename "$current"): $dll_name"
                continue
            fi

            if windows_runtime_dll_is_system_path "$dll_path"; then
                continue
            fi

            if ! windows_runtime_dll_allowed_path "$dll_path"; then
                log "  skipping non-package PE import: $dll_path"
                continue
            fi

            cp -f "$dll_path" "$bin_dir/$dll_name"
            log "  copied PE import: $dll_name"
            printf '%s\n' "$bin_dir/$dll_name" >> "$queue_file"
        done < <(windows_pe_import_dll_names "$current")
    done

    rm -f "$queue_file" "$queue_file.next" "$seen_file"
}

copy_windows_python_runtime() {
    local cmake_cache="${1:-}"
    local python_executable=""
    local python_library=""
    local version
    local major
    local minor
    local stdlib
    local dst
    local candidate_dir
    local dll
    local dll_name
    local required_dlls
    local copied_any=0

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    if [ -n "$cmake_cache" ] && [ -f "$cmake_cache/CMakeCache.txt" ]; then
        python_executable="$(grep -E '^Python3_EXECUTABLE:FILEPATH=' "$cmake_cache/CMakeCache.txt" | sed 's/^[^=]*=//' | head -n 1 || true)"
        python_library="$(grep -E '^Python3_LIBRARY[^=]*=' "$cmake_cache/CMakeCache.txt" | sed 's/^[^=]*=//' | head -n 1 || true)"
    fi

    if [ -z "$python_executable" ]; then
        if [ -n "${MINGW_PREFIX:-}" ] && [ -x "$MINGW_PREFIX/bin/python.exe" ]; then
            python_executable="$MINGW_PREFIX/bin/python.exe"
        elif ! command -v python >/dev/null 2>&1; then
            die "python is required to package Windows Python support"
        else
            python_executable="$(command -v python)"
        fi
    fi

    if command -v cygpath >/dev/null 2>&1; then
        python_executable="$(cygpath -u "$python_executable" 2>/dev/null || printf '%s\n' "$python_executable")"
        if [ -n "$python_library" ]; then
            python_library="$(cygpath -u "$python_library" 2>/dev/null || printf '%s\n' "$python_library")"
        fi
    fi

    if [ ! -x "$python_executable" ]; then
        die "Python executable used by LLDB/GDB was not found: $python_executable"
    fi

    version="$($python_executable - <<'PYSCRIPT'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PYSCRIPT
)"
    major="$($python_executable - <<'PYSCRIPT'
import sys
print(sys.version_info.major)
PYSCRIPT
)"
    minor="$($python_executable - <<'PYSCRIPT'
import sys
print(sys.version_info.minor)
PYSCRIPT
)"
    stdlib="$($python_executable - <<'PYSCRIPT'
import sysconfig
print(sysconfig.get_paths().get('stdlib', ''))
PYSCRIPT
)"
    required_dlls="$($python_executable - <<'PYSCRIPT'
import sys
names = [
    f"python{sys.version_info.major}{sys.version_info.minor}.dll",
    f"python{sys.version_info.major}.dll",
    "libpython3.dll",
    f"libpython{sys.version_info.major}.{sys.version_info.minor}.dll",
]
for name in dict.fromkeys(names):
    print(name)
PYSCRIPT
)"

    if command -v cygpath >/dev/null 2>&1; then
        stdlib="$(cygpath -u "$stdlib" 2>/dev/null || printf '%s\n' "$stdlib")"
    fi

    if [ -z "$version" ] || [ -z "$stdlib" ] || [ ! -d "$stdlib" ]; then
        die "could not locate Python standard library for Windows package"
    fi

    dst="$PREFIX/lib/python$version"

    log "copying Python standard library: $stdlib -> $dst"

    mkdir -p "$dst"
    cp -a "$stdlib"/. "$dst"/

    if [ -d "$dst/site-packages/lldb" ]; then
        log "preserved LLDB Python package: $dst/site-packages/lldb"
        "$python_executable" -m compileall -q "$dst/site-packages/lldb" || true
        "$python_executable" -O -m compileall -q "$dst/site-packages/lldb" || true
    else
        log "warning: LLDB Python package was not found under $dst/site-packages/lldb"
    fi

    find "$dst" -type d -name __pycache__ -prune -exec rm -rf {} +
    find "$dst" -type d \( -name test -o -name tests -o -name idlelib -o -name tkinter -o -name turtledemo \) -prune -exec rm -rf {} +
    find "$dst" -type f \( -name '_tkinter*.pyd' -o -name 'tkinter*.pyd' \) -delete

    mkdir -p "$PREFIX/bin"

    log "copying Python runtime DLLs"

    while IFS= read -r candidate_dir; do
        [ -n "$candidate_dir" ] || continue
        [ -d "$candidate_dir" ] || continue

        while IFS= read -r dll_name; do
            [ -n "$dll_name" ] || continue
            dll="$candidate_dir/$dll_name"
            [ -f "$dll" ] || continue

            if [ ! -f "$PREFIX/bin/$(basename "$dll")" ]; then
                cp -f "$dll" "$PREFIX/bin/$(basename "$dll")"
                log "  copied: $(basename "$dll")"
                copied_any=1
            fi
        done <<EOF_DLLS
$required_dlls
EOF_DLLS

        for dll in \
            "$candidate_dir/python$major$minor.dll" \
            "$candidate_dir/python$version.dll" \
            "$candidate_dir/libpython$version.dll" \
            "$candidate_dir/libpython$major$minor.dll" \
            "$candidate_dir"/python*.dll \
            "$candidate_dir"/libpython*.dll; do

            [ -f "$dll" ] || continue

            if [ ! -f "$PREFIX/bin/$(basename "$dll")" ]; then
                cp -f "$dll" "$PREFIX/bin/$(basename "$dll")"
                log "  copied: $(basename "$dll")"
                copied_any=1
            fi
        done
    done < <(
        dirname "$python_executable"
        [ -n "$python_library" ] && dirname "$python_library"
        [ -n "${MINGW_PREFIX:-}" ] && printf '%s\n' "$MINGW_PREFIX/bin"
    )

    if [ "$copied_any" -eq 0 ]; then
        die "could not locate Python runtime DLLs for Windows package"
    fi

    create_windows_python_dll_aliases "$PREFIX/bin"
    create_windows_python_path_config "$PREFIX/bin" "$version"
}


create_windows_python_path_config() {
    local bin_dir="$1"
    local version="$2"
    local major
    local minor
    local names=()
    local name
    local pth_file

    [ -d "$bin_dir" ] || return 0
    [ -n "$version" ] || return 0

    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"

    [ -n "$major" ] || return 0
    [ -n "$minor" ] || return 0

    names+=(
        "python${major}${minor}"
        "libpython${version}"
        "libpython${major}"
        "lldb"
        "lldb-dap"
    )

    for name in "${names[@]}"; do
        pth_file="$bin_dir/$name._pth"

        log "creating Windows Python path config: $(basename "$pth_file")"

        {
            printf '../lib/python%s\n' "$version"
            printf '../lib/python%s/lib-dynload\n' "$version"
            printf '../lib/python%s/site-packages\n' "$version"
            printf 'import site\n'
        } > "$pth_file"
    done
}

create_windows_python_dll_aliases() {
    local bin_dir="$1"
    local dll
    local alias

    [ -d "$bin_dir" ] || return 0

    for dll in "$bin_dir"/libpython[0-9].*.dll; do
        [ -f "$dll" ] || continue

        alias="$(basename "$dll" | sed -E 's/^libpython([0-9]+)\.([0-9]+)\.dll$/python\1\2.dll/')"

        if [ -n "$alias" ] && [ "$alias" != "$(basename "$dll")" ] && [ ! -f "$bin_dir/$alias" ]; then
            cp -f "$dll" "$bin_dir/$alias"
            log "  created Python runtime alias: $alias"
        fi
    done
}

verify_windows_runtime_dlls() {
    local bin_dir="$1"
    local current
    local dll_path
    local dll_name
    local missing=0

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    if ! command -v ldd >/dev/null 2>&1; then
        die "ldd is required to verify Windows runtime DLLs"
    fi

    if [ ! -d "$bin_dir" ]; then
        return 0
    fi

    log "verifying Windows runtime DLL closure for $bin_dir"

    while IFS= read -r current; do
        [ -n "$current" ] || continue

        while IFS= read -r dll_path; do
            [ -n "$dll_path" ] || continue

            dll_name="$(basename "$dll_path")"

            if [ -f "$bin_dir/$dll_name" ]; then
                continue
            fi

            if windows_runtime_dll_is_system_path "$dll_path"; then
                continue
            fi

            if windows_runtime_dll_allowed_path "$dll_path"; then
                log "  missing packaged DLL dependency for $(basename "$current"): $dll_name from $dll_path"
                missing=1
            else
                log "  external DLL dependency not packaged for $(basename "$current"): $dll_path"
            fi
        done < <(windows_runtime_dll_extract_paths "$current")

        while IFS= read -r dll_name; do
            [ -n "$dll_name" ] || continue

            if windows_runtime_dll_name_is_system "$dll_name"; then
                continue
            fi

            if [ -f "$bin_dir/$dll_name" ]; then
                continue
            fi

            dll_path="$(find_windows_runtime_dll_by_name "$dll_name" "$bin_dir")"
            if [ -n "$dll_path" ] && [ -f "$dll_path" ]; then
                log "  PE import not copied for $(basename "$current"): $dll_name from $dll_path"
            else
                log "  unresolved PE import for $(basename "$current"): $dll_name"
            fi
            missing=1
        done < <(windows_pe_import_dll_names "$current")
    done < <(collect_windows_package_pe_files "$bin_dir" | sort -u)

    if [ "$missing" -ne 0 ]; then
        die "Windows runtime DLL verification failed"
    fi
}

create_archive() {
    local format="$1"
    local package_base="$2"
    local package_root="$3"
    local output_dir="$4"

    local output
    output="$output_dir/$package_base.$format"

    rm -f "$output"

    case "$format" in
        tar.xz)
            tar -C "$(dirname "$package_root")" -cJf "$output" "$(basename "$package_root")"
            ;;
        tar.gz)
            tar -C "$(dirname "$package_root")" -czf "$output" "$(basename "$package_root")"
            ;;
        zip)
            (cd "$(dirname "$package_root")" && zip -qr "$output" "$(basename "$package_root")")
            ;;
        *)
            die "unsupported package format: $format"
            ;;
    esac

    log "created package: $output"
}

create_packages() {
    local tool="$1"
    local version="$2"
    local host_platform="$3"
    local target_platform="$4"
    local revision="$5"
    local prefix="$6"

    local package_base
    local release_tag
    local package_root
    local format

    package_base="$(package_base_name "$tool" "$version" "$host_platform" "$target_platform" "$revision")"
    release_tag="$(release_tag_for_package "$tool" "$version" "$host_platform" "$target_platform" "$revision")"
    package_root="$CUP_WORK_DIR/package-root/$package_base"

    rm -rf "$package_root"
    mkdir -p "$(dirname "$package_root")"
    cp -a "$prefix" "$package_root"

    for format in $(package_formats_for_host "$host_platform"); do
        create_archive "$format" "$package_base" "$package_root" "$CUP_OUT_DIR"
    done

    cat > "$CUP_OUT_DIR/release.env" <<EOF_ENV
release_tag=$release_tag
package_base=$package_base
EOF_ENV
}
