#!/usr/bin/env bash
set -euo pipefail

CUP_ROOT="${CUP_ROOT:-$(pwd)}"
CUP_WORK_DIR="${CUP_WORK_DIR:-$CUP_ROOT/.cup-build}"
CUP_SRC_DIR="${CUP_SRC_DIR:-$CUP_WORK_DIR/src}"
CUP_BUILD_DIR="${CUP_BUILD_DIR:-$CUP_WORK_DIR/build}"
CUP_STAGE_DIR="${CUP_STAGE_DIR:-$CUP_WORK_DIR/stage}"
CUP_OUT_DIR="${CUP_OUT_DIR:-$CUP_ROOT/dist}"
CUP_COMPONENTS_ROOT="${CUP_COMPONENTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

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

DEFAULT_GCC_VERSION="16.2.0"
# The default GCC package composition is independent of the standalone GNU ld
# default. Change the component version(s) and revision together when the
# default GCC composition changes without changing the GCC release itself.
DEFAULT_GCC_BINUTILS_VERSION="2.47"
DEFAULT_GCC_MINGW_VERSION="14.0.0"
DEFAULT_GCC_REVISION="1"
DEFAULT_GDB_VERSION="17.2"
DEFAULT_BINUTILS_VERSION="2.47"
DEFAULT_LLVM_VERSION="23.1.0"
DEFAULT_VALGRIND_VERSION="3.27.1"

# Payload provenance set by the Python runtime copy helpers.
PACKAGED_PYTHON_RUNTIME_VERSION=""

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

numeric_version_is_valid() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)*$ ]]
}

package_revision_is_valid() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

package_revision_is_applicable() {
    [ "$1" = gcc ]
}

resolve_version() {
    local tool="$1"
    local requested="$2"
    local resolved

    if [ "$requested" != "stable" ]; then
        [ "$requested" != "latest" ] ||
            die "unsupported symbolic version: latest; use stable or an explicit numeric version"
        numeric_version_is_valid "$requested" ||
            die "invalid explicit version: $requested; expected a numeric dotted version"
        printf '%s\n' "$requested"
        return 0
    fi

    case "$tool" in
        gcc) resolved="$DEFAULT_GCC_VERSION" ;;
        gdb) resolved="$DEFAULT_GDB_VERSION" ;;
        binutils|ld) resolved="$DEFAULT_BINUTILS_VERSION" ;;
        mingw|mingw-w64) resolved="$DEFAULT_GCC_MINGW_VERSION" ;;
        clang|lld|lldb|clangd|clang-format|clang-tidy|llvm) resolved="$DEFAULT_LLVM_VERSION" ;;
        valgrind) resolved="$DEFAULT_VALGRIND_VERSION" ;;
        *) die "cannot resolve default version for tool: $tool" ;;
    esac

    numeric_version_is_valid "$resolved" ||
        die "invalid configured stable version for $tool: $resolved"
    printf '%s\n' "$resolved"
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

is_cross_build() {
    [ "$1" != "$2" ]
}

package_version_name() {
    local tool="$1"
    local version="$2"
    local host_platform="$3"
    local target_platform="$4"
    local revision="$5"

    : "$host_platform" "$target_platform"
    numeric_version_is_valid "$version" || die "invalid package version: $version"
    if package_revision_is_applicable "$tool"; then
        package_revision_is_valid "$revision" || die "invalid package revision: $revision"
        printf '%s-rev%s\n' "$version" "$revision"
    else
        [ -z "$revision" ] || die "package revision is not applicable to tool: $tool"
        printf '%s\n' "$version"
    fi
}

package_component_for_tool() {
    case "$1" in
        gcc|clang) printf '%s\n' compiler ;;
        gdb|lldb) printf '%s\n' debugger ;;
        lld|ld) printf '%s\n' linker ;;
        clang-format) printf '%s\n' formatter ;;
        clang-tidy) printf '%s\n' linter ;;
        clangd) printf '%s\n' language-server ;;
        valgrind) printf '%s\n' analyzer ;;
        *) return 1 ;;
    esac
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

sha256_file() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        die "sha256sum or shasum is required for source authentication"
    fi
}

known_source_sha256() {
    case "$1:$2" in
        gcc:16.1.0) printf '%s\n' 50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79 ;;
        gcc:16.2.0) printf '%s\n' e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e ;;
        binutils:2.46.0) printf '%s\n' d75a94f4d73e7a4086f7513e67e439e8fcdcbb726ffe63f4661744e6256b2cf2 ;;
        binutils:2.47) printf '%s\n' 154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff ;;
        mingw:14.0.0) printf '%s\n' 6eaf921d9eb987d3820b364ea9775bc19b965ec81490b6fdd716526c28e1995c ;;
        gdb:17.1) printf '%s\n' 14996f5f74c9f68f5a543fdc45bca7800207f91f92aeea6c2e791822c7c6d876 ;;
        gdb:17.2) printf '%s\n' 1c036c0d72e4b3d1fb5c94c88632add6f9d76f4d7c4d2ea793c12a9f19a3228c ;;
        llvm:22.1.5) printf '%s\n' 7972b87b705a003ce70ab55f9f0fb495d156887cba0eb296d284731139118e2c ;;
        llvm:23.1.0) printf '%s\n' ab1f0e3ec52448c33e8782eaf0422504b87c7b016b22514653ee0d8fcee479ff ;;
        valgrind:3.27.0) printf '%s\n' 5b5937de8257ee8f51698ea71b9711adce98061aa07daa4a685efc3af9215bef ;;
        valgrind:3.27.1) printf '%s\n' 5d589152eb8071c02feab8ce6ab719e431a1fbc3e2b1700f5432632a8b9264dc ;;
        *) return 1 ;;
    esac
}

source_archive_path() {
    local url="$1"
    local fallback="$2"
    printf '%s/%s\n' "$CUP_SRC_DIR" "$(archive_name_from_url "$url" "$fallback")"
}

source_archive_sha256() {
    local archive
    archive="$(source_archive_path "$1" "$2")"
    [ -f "$archive" ] || die "source archive is not available: $archive"
    sha256_file "$archive"
}

record_source_archive() {
    local source_id="$1"
    local version="$2"
    local url="$3"
    local filename="$4"
    local expected_sha="$5"
    local actual_sha="$6"
    local status="$7"
    local records_dir="${CUP_BUILD_RECORDS_DIR:-$CUP_WORK_DIR/build-records}"
    local output="$records_dir/sources.tsv"

    mkdir -p "$records_dir"
    if [ ! -f "$output" ]; then
        printf 'source_id\tversion\tfilename\texpected_sha256\tactual_sha256\tstatus\turl\n' > "$output"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$source_id" "$version" "$filename" "${expected_sha:--}" "${actual_sha:--}" "$status" "$url" >> "$output"
}

prepare_source_tree() {
    local source_id="$1"
    local version="$2"
    local url="$3"
    local fallback_archive="$4"
    local expected_sha="${5:-}"
    local filename archive source_dir actual_sha status

    filename="$(archive_name_from_url "$url" "$fallback_archive")"
    archive="$CUP_SRC_DIR/$filename"
    source_dir="$CUP_SRC_DIR/$source_id-$version"

    if [ -z "$expected_sha" ]; then
        expected_sha="$(known_source_sha256 "$source_id" "$version" 2>/dev/null || true)"
    fi

    if ! fetch "$url" "$archive"; then
        record_source_archive "$source_id" "$version" "$url" "$filename" "$expected_sha" - download-failed
        return 1
    fi

    actual_sha="$(sha256_file "$archive")"
    if [ -n "$expected_sha" ] && [ "$actual_sha" != "$expected_sha" ]; then
        record_source_archive "$source_id" "$version" "$url" "$filename" "$expected_sha" "$actual_sha" sha256-mismatch
        die "source archive SHA-256 mismatch for $filename: expected $expected_sha, got $actual_sha"
    fi

    status=ready-unverified
    [ -z "$expected_sha" ] || status=ready-verified
    if ! extract_archive "$archive" "$source_dir"; then
        record_source_archive "$source_id" "$version" "$url" "$filename" "$expected_sha" "$actual_sha" extraction-failed
        return 1
    fi
    record_source_archive "$source_id" "$version" "$url" "$filename" "$expected_sha" "$actual_sha" "$status"
    printf '%s\n' "$source_dir"
}

llvm_source_excludes() {
    local archive="$1"

    case "$(basename "$archive")" in
        llvm-project-*.src.tar.*)
            printf '%s\n' \
                '--exclude=*/clang/test/*' \
                '--exclude=*/clang-tools-extra/test/*' \
                '--exclude=*/compiler-rt/test/*' \
                '--exclude=*/libcxx/test/*' \
                '--exclude=*/libcxxabi/test/*' \
                '--exclude=*/libunwind/test/*' \
                '--exclude=*/lld/test/*' \
                '--exclude=*/lldb/test/*' \
                '--exclude=*/llvm/test/*'
            ;;
    esac
}

extract_archive() {
    local archive="$1"
    local destination="$2"
    local tar_excludes=()
    local exclude_arg
    local tar_mode=""

    rm -rf "$destination"
    mkdir -p "$destination"

    while IFS= read -r exclude_arg; do
        [ -n "$exclude_arg" ] && tar_excludes+=("$exclude_arg")
    done < <(llvm_source_excludes "$archive")

    case "$archive" in
        *.tar.xz) tar_mode=-xJf ;;
        *.tar.gz|*.tgz) tar_mode=-xzf ;;
        *.tar.bz2|*.tbz2) tar_mode=-xjf ;;
        *.zip)
            unzip -q "$archive" -d "$destination"
            return
            ;;
        *) die "unsupported archive format: $archive" ;;
    esac

    if tar "$tar_mode" "$archive" -C "$destination" --strip-components=1 "${tar_excludes[@]}"; then
        return 0
    fi

    # MSYS2's default winsymlinks:deepcopy mode requires a symlink target to
    # exist before the link entry is unpacked. A first pass can therefore fail
    # only because an archive lists a link before its target, while still
    # materializing that later target. Retrying into the same destination is
    # the documented MSYS2 workaround and remains fail-closed for every other
    # tar error because the second pass must itself succeed.
    if is_windows_platform "${HOST_PLATFORM:-}"; then
        log "retrying tar source extraction after the Windows first pass failed"
        tar "$tar_mode" "$archive" -C "$destination" --strip-components=1 "${tar_excludes[@]}"
        return
    fi

    return 1
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
        if is_windows_platform "$HOST_PLATFORM"; then
            # Native Windows command identity is extension-based; POSIX mode
            # bits in the MSYS2 staging tree are not part of that contract.
            package_bin_exact_file_exists "$prefix" "$candidate" && return 0
        elif [ -x "$prefix/bin/$candidate" ]; then
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

    [ -e "$prefix/bin/$candidate" ] || [ -L "$prefix/bin/$candidate" ]
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


linux_runtime_library_name_is_base() {
    local name
    name="$(basename "$1")"

    case "$name" in
        linux-vdso.so.*|ld-linux-*.so.*|ld64.so.*|\
        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|\
        libutil.so.*|libresolv.so.*|libanl.so.*|libBrokenLocale.so.*|\
        libthread_db.so.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

linux_is_dynamic_elf() {
    local path="$1"
    readelf -d "$path" 2>/dev/null | grep -Fq 'Dynamic section'
}

linux_dynamic_elf_files() {
    local prefix="$1"
    local path

    while IFS= read -r -d '' path; do
        if linux_is_dynamic_elf "$path"; then
            printf '%s\n' "$path"
        fi
    done < <(find "$prefix" -type f -print0)
}

python_runtime_version() {
    local python_executable="$1"
    local output

    output="$($python_executable --version 2>&1)"
    printf '%s\n' "$output" | sed -nE 's/^Python ([0-9]+\.[0-9]+)(\..*)?$/\1/p'
}

python_runtime_full_version() {
    local python_executable="$1"
    local output

    output="$($python_executable --version 2>&1)"
    printf '%s\n' "$output" | sed -nE 's/^Python ([^[:space:]]+).*$/\1/p'
}

python_runtime_prefix() {
    local python_executable="$1"
    local config
    local base

    base="$(basename "$python_executable")"
    for config in "${python_executable}-config" "$(dirname "$python_executable")/${base}-config" "${base}-config" python3-config; do
        if [ -x "$config" ]; then
            "$config" --prefix
            return 0
        fi
        if command -v "$config" >/dev/null 2>&1; then
            "$config" --prefix
            return 0
        fi
    done

    return 1
}

prune_python_runtime_nonruntime_payload() {
    local destination="$1"

    # CPython's caches, regression suites, GUI/demo modules and test-only
    # extension modules are not runtime responsibility of packaged debugger or
    # helper Python. Keep the ordinary stdlib intact for user scripting.
    find "$destination" -type d -name __pycache__ -prune -exec rm -rf {} +
    find "$destination" -type d \
        \( -name test -o -name tests -o -name idlelib -o -name tkinter -o -name turtledemo \
           -o -name Tools -o -name __phello__ \) \
        -prune -exec rm -rf {} +
    find "$destination" -type f \
        \( -name '_ctypes_test*.so' -o -name '_ctypes_test*.pyd' \
           -o -name '_test*.so' -o -name '_test*.pyd' \
           -o -name '_xxtestfuzz*.so' -o -name '_xxtestfuzz*.pyd' \
           -o -name 'xxlimited*.so' -o -name 'xxlimited*.pyd' \
           -o -name 'xxsubtype*.so' -o -name 'xxsubtype*.pyd' \) -delete
}

copy_python_stdlib_runtime_entries() {
    local stdlib="$1"
    local destination="$2"
    local version="$3"
    local entries_file
    local entry
    local base
    local status

    [ -d "$stdlib" ] || die "Python standard library was not found: $stdlib"
    mkdir -p "$destination"

    # Materialize the top-level enumeration before copying so a find failure is
    # not hidden by process-substitution semantics. An incomplete stdlib copy is
    # not an acceptable package runtime.
    entries_file="$(mktemp)" || die "could not allocate Python stdlib enumeration file"
    if find "$stdlib" -mindepth 1 -maxdepth 1 -print0 > "$entries_file"; then
        :
    else
        status=$?
        rm -f "$entries_file"
        return "$status"
    fi

    # Preserve package-owned site-packages already installed by LLDB and copy
    # only interpreter runtime entries from the builder Python. Source-side
    # third-party packages and CPython development metadata are not part of the
    # CUP Python runtime contract.
    while IFS= read -r -d '' entry; do
        base="$(basename "$entry")"
        case "$base" in
            site-packages|dist-packages|sitecustomize.py|Tools|__phello__|\
            "config-$version"|"config-$version-"*|"config-${version}d"|"config-${version}d-"*)
                continue
                ;;
        esac
        if cp -RPp "$entry" "$destination/"; then
            :
        else
            status=$?
            rm -f "$entries_file"
            return "$status"
        fi
    done < "$entries_file"
    rm -f "$entries_file"
}

copy_posix_python_runtime() {
    local python_executable="$1"
    local copy_executable="${2:-false}"
    local executable_relative="${3:-libexec/python3}"
    local version
    local full_version
    local python_prefix
    local stdlib
    local destination
    local framework_app

    if ! is_linux_platform "$HOST_PLATFORM" && ! is_macos_platform "$HOST_PLATFORM"; then
        return 0
    fi

    if [[ "$python_executable" != */* ]]; then
        python_executable="$(command -v "$python_executable" 2>/dev/null || true)"
    fi
    [ -x "$python_executable" ] || die "Python executable was not found: $python_executable"

    version="$(python_runtime_version "$python_executable")"
    [ -n "$version" ] || die "could not determine Python major/minor version: $python_executable"
    full_version="$(python_runtime_full_version "$python_executable")"
    [ -n "$full_version" ] || die "could not determine Python runtime version: $python_executable"

    python_prefix="$(python_runtime_prefix "$python_executable" || true)"
    [ -n "$python_prefix" ] || die "could not determine Python prefix: $python_executable"

    stdlib="$python_prefix/lib/python$version"
    [ -d "$stdlib" ] || die "Python standard library was not found: $stdlib"

    destination="$PREFIX/lib/python$version"
    copy_python_stdlib_runtime_entries "$stdlib" "$destination" "$version" || return $?

    # Match the Windows Python package policy: interpreter caches, CPython's
    # own regression suites and GUI/demo modules are not runtime responsibility
    # for CUP's debugger/helper use cases. Keeping them also preserves builder
    # paths in bytecode and needlessly inflates every Python-carrying package.
    prune_python_runtime_nonruntime_payload "$destination"

    if [ "$copy_executable" = true ]; then
        package_relative_path_is_safe "$executable_relative" ||
            die "unsafe packaged Python executable path: $executable_relative"
        mkdir -p "$PREFIX/$(dirname "$executable_relative")"
        cp -pL "$python_executable" "$PREFIX/$executable_relative"
        chmod 0755 "$PREFIX/$executable_relative"

        if is_macos_platform "$HOST_PLATFORM"; then
            # Homebrew/framework Python's command-line launcher loads the
            # framework dylib and then spawns this companion executable. Once
            # the dylib is relocated to <package>/lib/Python, CPython resolves
            # the companion at <package>/lib/Resources/Python.app. Preserve
            # that framework topology instead of depending on the host prefix.
            framework_app="$python_prefix/Resources/Python.app"
            if [ -d "$framework_app" ]; then
                mkdir -p "$PREFIX/lib/Resources"
                rm -rf "$PREFIX/lib/Resources/Python.app"
                cp -RPp "$framework_app" "$PREFIX/lib/Resources/Python.app"
            fi
        fi
    fi

    PACKAGED_PYTHON_RUNTIME_VERSION="$full_version"
    log "copied Python $full_version runtime into package"
}

linux_elf_needed_names() {
    local file="$1"
    local output

    if ! output="$(LC_ALL=C readelf -dW "$file" 2>&1)"; then
        log "readelf -dW failed for $file"
        [ -z "$output" ] || printf '%s\n' "$output" >&2
        return 1
    fi

    printf '%s\n' "$output" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
}

linux_ldd_dependencies() {
    local file="$1"
    local needed
    local output
    local name
    local record

    # DT_NEEDED defines the dependency graph. ldd is used only to resolve
    # those names; loader diagnostics are never interpreted as dependencies.
    if ! needed="$(linux_elf_needed_names "$file")"; then
        return 1
    fi
    [ -n "$needed" ] || return 0

    # Producer closure must not depend on an ambient LD_LIBRARY_PATH from the
    # builder. Only the explicit staging search path may influence resolution.
    if ! output="$(env LC_ALL=C LD_LIBRARY_PATH="${LINUX_RUNTIME_SEARCH_PATH:-}" \
        ldd "$file" 2>&1)"; then
        log "ldd failed for $file"
        [ -z "$output" ] || printf '%s\n' "$output" >&2
        return 1
    fi

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        record="$(printf '%s\n' "$output" | awk -v wanted="$name" '
            {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                arrow=index(line, " => ")
                if (arrow <= 0) next
                candidate=substr(line, 1, arrow - 1)
                if (candidate != wanted) next
                value=substr(line, arrow + 4)
                if (value ~ /^not found([[:space:]]|$)/) {
                    print "!NOT_FOUND!"
                    exit
                }
                sub(/[[:space:]]+\(0x[0-9A-Fa-f]+\)[[:space:]]*$/, "", value)
                print value
                exit
            }
        ')"
        if [ -z "$record" ]; then
            printf '%s\t!NOT_FOUND!\n' "$name"
        else
            printf '%s\t%s\n' "$name" "$record"
        fi
    done <<< "$needed"
}

linux_runtime_library_name_is_safe() {
    local name="$1"

    [ -n "$name" ] || return 1
    [ "$name" = "$(basename "$name")" ] || return 1
    package_relative_path_is_safe "lib/$name"
}

linux_copy_resolved_runtime_libraries() {
    local prefix="$1"
    local copied
    local file
    local name
    local resolved
    local destination
    local dependencies
    local search_path="$prefix/lib:$prefix/lib64"

    mkdir -p "$prefix/lib"

    while :; do
        copied=0

        while IFS= read -r file; do
            if ! dependencies="$(LINUX_RUNTIME_SEARCH_PATH="$search_path" linux_ldd_dependencies "$file")"; then
                die "failed to inspect Linux runtime dependencies for $(basename "$file")"
            fi
            while IFS=$'\t' read -r name resolved; do
                [ -n "$name" ] || continue

                linux_runtime_library_name_is_safe "$name" ||
                    die "unsafe Linux runtime dependency name for $(basename "$file"): $name"

                if [ "$resolved" = "!NOT_FOUND!" ]; then
                    linux_runtime_library_name_is_base "$name" && continue
                    die "unresolved Linux runtime dependency for $(basename "$file"): $name"
                fi

                linux_runtime_library_name_is_base "$name" && continue
                [ -n "$resolved" ] && [ -f "$resolved" ] ||
                    die "invalid Linux runtime dependency resolution for $(basename "$file"): $name -> $resolved"

                # A dependency already supplied by the package keeps its upstream
                # layout. The rewrite phase will make that directory reachable
                # through a package-relative RUNPATH.
                case "$resolved" in
                    "$prefix"/*) continue ;;
                esac

                destination="$prefix/lib/$name"
                if [ -e "$destination" ]; then
                    cmp -s "$resolved" "$destination" ||
                        die "conflicting Linux runtime libraries for $name"
                    continue
                fi

                cp -L "$resolved" "$destination"
                chmod --reference="$resolved" "$destination" 2>/dev/null || true
                copied=$((copied + 1))
                log "  copied ELF dependency: $name"
            done <<< "$dependencies"
        done < <(linux_dynamic_elf_files "$prefix")

        [ "$copied" -gt 0 ] || return 0
    done
}

linux_materialize_hardlinked_path_for_rewrite() {
    local file="$1"
    local links
    local temporary

    links="$(stat -c %h "$file")" || return 1
    [ "$links" -gt 1 ] || return 0

    temporary="$file.cup-cow.$$"
    cp -p "$file" "$temporary" || return 1
    mv -f "$temporary" "$file" || {
        rm -f "$temporary"
        return 1
    }
}

linux_runtime_directory_for_dependency() {
    local prefix="$1"
    local name="$2"
    local resolved="$3"
    local copied="$prefix/lib/$name"
    local canonical_prefix
    local canonical_resolved
    local canonical_directory

    canonical_prefix="$(realpath -m "$prefix")" || return 1
    canonical_resolved="$(realpath -m "$resolved")" || return 1
    canonical_directory="$(realpath -m "$(dirname "$resolved")")" || return 1

    case "$canonical_resolved" in
        "$canonical_prefix"/*)
            # Preserve the directory through which the loader resolved the
            # dependency name. The final file may itself be a symlink.
            case "$canonical_directory" in
                "$canonical_prefix"/*|"$canonical_prefix")
                    printf '%s\n' "$canonical_directory"
                    return 0
                    ;;
            esac
            return 1
            ;;
    esac

    # External non-base libraries are copied by the closure phase into lib/.
    # An upstream DT_RPATH can still make ldd report the original path, so use
    # the package copy when it is byte-identical to that resolution.
    if [ -f "$copied" ] && cmp -s "$resolved" "$copied"; then
        printf '%s\n' "$canonical_prefix/lib"
        return 0
    fi

    return 1
}

linux_runpath_for_file() {
    local prefix="$1"
    local file="$2"
    local load_path="${3:-$file}"
    local dependencies
    local name
    local resolved
    local runtime_dir
    local relative
    local entry
    local runpath=""
    local seen=""
    local search_path="$prefix/lib:$prefix/lib64"
    local canonical_prefix

    canonical_prefix="$(realpath -m "$prefix")" || return 1

    if ! dependencies="$(LINUX_RUNTIME_SEARCH_PATH="$search_path" linux_ldd_dependencies "$file")"; then
        return 1
    fi

    while IFS=$'\t' read -r name resolved; do
        [ -n "$name" ] || continue
        linux_runtime_library_name_is_safe "$name" || return 1

        if [ "$resolved" = "!NOT_FOUND!" ]; then
            linux_runtime_library_name_is_base "$name" && continue
            return 1
        fi
        linux_runtime_library_name_is_base "$name" && continue

        runtime_dir="$(linux_runtime_directory_for_dependency "$prefix" "$name" "$resolved")" || return 1
        case "$runtime_dir" in
            "$canonical_prefix"/*|"$canonical_prefix") ;;
            *) return 1 ;;
        esac

        case $'\n'"$seen"$'\n' in
            *$'\n'"$runtime_dir"$'\n'*) continue ;;
        esac
        seen="${seen:+$seen$'\n'}$runtime_dir"

        relative="$(realpath --relative-to="$(dirname "$load_path")" "$runtime_dir")" || return 1
        if [ "$relative" = "." ]; then
            entry='$ORIGIN'
        else
            entry="\$ORIGIN/$relative"
        fi
        runpath="${runpath:+$runpath:}$entry"
    done <<< "$dependencies"

    printf '%s\n' "$runpath"
}

linux_patch_runtime_search_paths() {
    local prefix="$1"
    local file
    local alias
    local alias_target
    local alias_runpath
    local entry
    local runpath
    local canonical_prefix
    local canonical_file
    declare -A elf_aliases=()

    command -v patchelf >/dev/null 2>&1 ||
        die "patchelf is required to make Linux component packages relocatable"

    canonical_prefix="$(realpath -m "$prefix")" ||
        die "failed to canonicalize Linux package prefix before RUNPATH rewrite"

    # A shared object may be loaded through a package-internal symlink from a
    # different directory (LLDB's Python _lldb module is one real example).
    # $ORIGIN is evaluated from that load pathname, so retain every internal
    # ELF alias as an additional pathname when deriving the target RUNPATH.
    while IFS= read -r -d '' alias; do
        alias_target="$(realpath -e "$alias" 2>/dev/null || true)"
        [ -n "$alias_target" ] || continue
        case "$alias_target" in
            "$canonical_prefix"/*) ;;
            *) continue ;;
        esac
        [ -f "$alias_target" ] || continue
        linux_is_dynamic_elf "$alias_target" || continue
        elf_aliases["$alias_target"]="${elf_aliases["$alias_target"]:+${elf_aliases["$alias_target"]}$'\n'}$alias"
    done < <(find "$prefix" -type l -print0)

    # A pathname-specific RUNPATH requires independent bytes. Break only ELF
    # hardlinks that are about to be rewritten; hardlink identity itself is not
    # part of the logical package contract.
    while IFS= read -r file; do
        linux_materialize_hardlinked_path_for_rewrite "$file" ||
            die "failed to materialize hardlinked ELF before RUNPATH rewrite: $file"
    done < <(linux_dynamic_elf_files "$prefix")

    while IFS= read -r file; do
        runpath="$(linux_runpath_for_file "$prefix" "$file" "$file")" ||
            die "failed to derive package-relative Linux RUNPATH for $(basename "$file")"
        canonical_file="$(realpath -e "$file")" ||
            die "failed to canonicalize Linux ELF before RUNPATH rewrite: $file"

        while IFS= read -r alias; do
            [ -n "$alias" ] || continue
            alias_runpath="$(linux_runpath_for_file "$prefix" "$file" "$alias")" ||
                die "failed to derive package-relative Linux RUNPATH for ELF alias: ${alias#"$prefix"/}"
            IFS=':' read -r -a alias_entries <<< "$alias_runpath"
            for entry in "${alias_entries[@]}"; do
                [ -n "$entry" ] || continue
                case ":$runpath:" in
                    *":$entry:"*) ;;
                    *) runpath="${runpath:+$runpath:}$entry" ;;
                esac
            done
        done <<< "${elf_aliases["$canonical_file"]:-}"

        patchelf --set-rpath "$runpath" "$file"
    done < <(linux_dynamic_elf_files "$prefix")
}

verify_linux_runtime_libraries() {
    local prefix="$1"
    local file
    local name
    local resolved
    local dependencies

    while IFS= read -r file; do
        if ! dependencies="$(LD_LIBRARY_PATH='' LINUX_RUNTIME_SEARCH_PATH='' linux_ldd_dependencies "$file")"; then
            die "failed to verify Linux runtime dependencies for $(basename "$file")"
        fi
        while IFS=$'\t' read -r name resolved; do
            [ -n "$name" ] || continue


            linux_runtime_library_name_is_safe "$name" ||
                die "unsafe Linux runtime dependency name after packaging for $(basename "$file"): $name"

            linux_runtime_library_name_is_base "$name" && continue

            if [ "$resolved" = "!NOT_FOUND!" ]; then
                die "unresolved Linux runtime dependency after packaging for $(basename "$file"): $name"
            fi

            case "$resolved" in
                "$prefix"/*) ;;
                *) die "Linux package still resolves external runtime dependency for $(basename "$file"): $name -> $resolved" ;;
            esac
        done <<< "$dependencies"
    done < <(linux_dynamic_elf_files "$prefix")
}

prepare_linux_runtime_closure() {
    local prefix="$1"
    local host_platform="$2"

    is_linux_platform "$host_platform" || return 0
    command -v readelf >/dev/null 2>&1 || die "readelf is required to package Linux runtime dependencies"
    command -v ldd >/dev/null 2>&1 || die "ldd is required to package Linux runtime dependencies"
    command -v realpath >/dev/null 2>&1 || die "realpath is required to package Linux runtime dependencies"

    if ! linux_dynamic_elf_files "$prefix" | grep . >/dev/null; then
        return 0
    fi

    log "closing Linux host runtime dependencies"
    linux_copy_resolved_runtime_libraries "$prefix"
    linux_patch_runtime_search_paths "$prefix"
    verify_linux_runtime_libraries "$prefix"
}

macos_runtime_library_is_base() {
    local dependency="$1"

    case "$dependency" in
        /usr/lib/*|/System/Library/*) return 0 ;;
        *) return 1 ;;
    esac
}

macos_is_runtime_macho() {
    local path="$1"
    local description

    [ -f "$path" ] || return 1

    # Keep raw bytes out of shell variables. The first probe recognizes a
    # normal ar archive; the textual `file` description also catches fat
    # Mach-O containers whose slices are static archives.
    if LC_ALL=C head -c 8 "$path" 2>/dev/null | grep -Fqx '!<arch>'; then
        return 1
    fi

    description="$(LC_ALL=C file -b "$path" 2>/dev/null || true)"
    case "$description" in
        *archive*) return 1 ;;
        *Mach-O*) return 0 ;;
        *) return 1 ;;
    esac
}
macos_macho_files() {
    local prefix="$1"
    local path

    while IFS= read -r -d '' path; do
        if macos_is_runtime_macho "$path"; then
            printf '%s\n' "$path"
        fi
    done < <(find "$prefix" -type f -print0)
}

macos_macho_dependencies() {
    local path="$1"
    local id=""
    local dependency
    local output

    # For a dylib, otool -L reports its install-name before its dependencies.
    # That install-name is metadata, not a dependency edge.
    id="$(otool -D "$path" 2>/dev/null | tail -n +2 | head -n 1 || true)"
    if ! output="$(otool -L "$path" 2>&1)"; then
        log "otool -L failed for $path"
        [ -z "$output" ] || printf '%s\n' "$output" >&2
        return 1
    fi
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        [ -n "$id" ] && [ "$dependency" = "$id" ] && continue
        printf '%s\n' "$dependency"
    done < <(printf '%s\n' "$output" | tail -n +2 | awk '{print $1}')
}

macos_loader_relative_lib_dir() {
    local file="$1"
    local prefix="$2"
    local relative
    local directory
    local component
    local result=""

    case "$file" in
        "$prefix"/*) relative="${file#"$prefix"/}" ;;
        *) die "Mach-O path is outside package prefix: $file" ;;
    esac

    directory="${relative%/*}"
    if [ "$directory" = "$relative" ] || [ -z "$directory" ]; then
        printf '%s\n' lib
        return 0
    fi

    while [ -n "$directory" ]; do
        component="${directory%%/*}"
        [ -n "$component" ] && [ "$component" != "." ] && result="../$result"
        if [ "$directory" = "$component" ]; then
            break
        fi
        directory="${directory#*/}"
    done

    printf '%slib\n' "$result"
}

macos_copy_and_rewrite_runtime_libraries() {
    local prefix="$1"
    local copied
    local file
    local dependency
    local dependency_output
    local destination
    local dependency_relative
    local relative
    local replacement
    local source_sha
    local existing
    declare -A original_runtime_sha=()

    mkdir -p "$prefix/lib"

    # Runtime objects are rewritten in place as the closure converges. Preserve
    # their original content identity so a later reference to the same external
    # library is not misclassified as a basename collision merely because the
    # packaged copy has already had its install-name/dependencies rewritten.
    for existing in "$prefix"/lib/*; do
        [ -f "$existing" ] || continue
        original_runtime_sha["$existing"]="$(sha256_file "$existing")"
    done

    while :; do
        copied=0

        while IFS= read -r file; do
            if ! dependency_output="$(macos_macho_dependencies "$file")"; then
                die "failed to inspect macOS runtime dependencies for $(basename "$file")"
            fi
            while IFS= read -r dependency; do
                [ -n "$dependency" ] || continue
                macos_runtime_library_is_base "$dependency" && continue

                case "$dependency" in
                    @rpath/*)
                        dependency_relative="${dependency#@rpath/}"
                        package_relative_path_is_safe "lib/$dependency_relative" ||
                            die "unsafe packaged @rpath dependency for $(basename "$file"): $dependency"
                        destination="$prefix/lib/$dependency_relative"
                        [ -e "$destination" ] ||
                            die "unresolved packaged @rpath dependency for $(basename "$file"): $dependency"
                        relative="$(macos_loader_relative_lib_dir "$file" "$prefix")"
                        replacement="@loader_path/$relative/$dependency_relative"
                        install_name_tool -change "$dependency" "$replacement" "$file"
                        ;;
                    @loader_path/*|@executable_path/*)
                        continue
                        ;;
                    /*)
                        [ -f "$dependency" ] ||
                            die "unresolved macOS runtime dependency for $(basename "$file"): $dependency"
                        destination="$prefix/lib/$(basename "$dependency")"
                        source_sha="$(sha256_file "$dependency")"
                        if [ -e "$destination" ]; then
                            [ -n "${original_runtime_sha[$destination]+x}" ] ||
                                original_runtime_sha["$destination"]="$(sha256_file "$destination")"
                            [ "$source_sha" = "${original_runtime_sha[$destination]}" ] ||
                                die "conflicting macOS runtime libraries for $(basename "$dependency")"
                        else
                            cp -pL "$dependency" "$destination"
                            original_runtime_sha["$destination"]="$source_sha"
                            if [ -n "$(otool -D "$destination" 2>/dev/null | tail -n +2 | head -n 1 || true)" ]; then
                                install_name_tool -id "@rpath/$(basename "$destination")" "$destination"
                            fi
                            copied=$((copied + 1))
                            log "  copied Mach-O dependency: $(basename "$dependency")"
                        fi

                        relative="$(macos_loader_relative_lib_dir "$file" "$prefix")"
                        replacement="@loader_path/$relative/$(basename "$dependency")"
                        install_name_tool -change "$dependency" "$replacement" "$file"
                        ;;
                    *)
                        die "unsupported macOS runtime dependency form for $(basename "$file"): $dependency"
                        ;;
                esac
            done <<< "$dependency_output"
        done < <(macos_macho_files "$prefix")

        [ "$copied" -gt 0 ] || return 0
    done
}

macos_sign_packaged_binaries() {
    local prefix="$1"
    local file

    # install_name_tool invalidates existing signatures. Ad-hoc signing is sufficient
    # for relocatable command-line packages and is required for modified arm64 Mach-O files.
    while IFS= read -r file; do
        codesign --force --sign - "$file" >/dev/null 2>&1 ||
            die "failed to ad-hoc sign packaged Mach-O file: ${file#"$prefix"/}"
    done < <(macos_macho_files "$prefix")
}

verify_macos_runtime_libraries() {
    local prefix="$1"
    local file
    local dependency
    local dependency_output
    local target

    while IFS= read -r file; do
        if ! dependency_output="$(macos_macho_dependencies "$file")"; then
            die "failed to inspect macOS runtime dependencies for $(basename "$file")"
        fi
        while IFS= read -r dependency; do
            [ -n "$dependency" ] || continue
            macos_runtime_library_is_base "$dependency" && continue

            case "$dependency" in
                @rpath/*)
                    target="$prefix/lib/${dependency#@rpath/}"
                    [ -e "$target" ] ||
                        die "packaged @rpath dependency is missing for $(basename "$file"): $dependency"
                    ;;
                @loader_path/*)
                    target="$(dirname "$file")/${dependency#@loader_path/}"
                    target="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")" ||
                        die "invalid @loader_path dependency for $(basename "$file"): $dependency"
                    case "$target" in
                        "$prefix"/*) ;;
                        *) die "@loader_path dependency escapes package for $(basename "$file"): $dependency" ;;
                    esac
                    [ -e "$target" ] ||
                        die "packaged @loader_path dependency is missing for $(basename "$file"): $dependency"
                    ;;
                @executable_path/*)
                    # Current producer output does not require this form. Rejecting it keeps
                    # package validation deterministic rather than guessing the main executable.
                    die "unsupported @executable_path dependency in package: $(basename "$file"): $dependency"
                    ;;
                /*)
                    die "macOS package still contains non-system absolute runtime dependency for $(basename "$file"): $dependency"
                    ;;
                *)
                    die "unsupported macOS runtime dependency form for $(basename "$file"): $dependency"
                    ;;
            esac
        done <<< "$dependency_output"
    done < <(macos_macho_files "$prefix")
}

prepare_macos_runtime_closure() {
    local prefix="$1"
    local host_platform="$2"

    is_macos_platform "$host_platform" || return 0
    command -v file >/dev/null 2>&1 || die "file is required to package macOS runtime dependencies"
    command -v otool >/dev/null 2>&1 || die "otool is required to package macOS runtime dependencies"
    command -v install_name_tool >/dev/null 2>&1 || die "install_name_tool is required to package macOS runtime dependencies"

    if ! macos_macho_files "$prefix" | grep . >/dev/null; then
        return 0
    fi
    need codesign

    log "closing macOS host runtime dependencies"
    macos_copy_and_rewrite_runtime_libraries "$prefix"
    macos_sign_packaged_binaries "$prefix"
    verify_macos_runtime_libraries "$prefix"
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
        *)
            return 1
            ;;
    esac
}

windows_runtime_dll_name_is_safe() {
    local name="$1"
    local lower

    [ -n "$name" ] || return 1
    [ "$name" = "$(basename "$name")" ] || return 1
    package_relative_path_is_safe "bin/$name" || return 1
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *.dll) return 0 ;;
        *) return 1 ;;
    esac
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

    if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ]; then
        find "$PREFIX" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.pyd' \)
        return 0
    fi

    if [ -d "$bin_dir" ]; then
        find "$bin_dir" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.pyd' \)
    fi
}

windows_pe_import_tool() {
    if command -v llvm-objdump >/dev/null 2>&1; then
        printf '%s\n' llvm-objdump
    elif command -v objdump >/dev/null 2>&1; then
        printf '%s\n' objdump
    fi
}

windows_pe_import_dll_names() {
    local file="$1"
    local objdump_cmd
    local output

    objdump_cmd="$(windows_pe_import_tool)"
    [ -n "$objdump_cmd" ] || return 1

    if ! output="$(LC_ALL=C "$objdump_cmd" -p "$file" 2>&1)"; then
        log "$objdump_cmd -p failed for $file"
        [ -z "$output" ] || printf '%s\n' "$output" >&2
        return 1
    fi

    printf '%s\n' "$output" | \
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
    local imports
    local dll_path
    local dll_name
    local processed=0
    local max_processed=10000

    if ! is_windows_platform "$HOST_PLATFORM"; then
        return 0
    fi

    if [ ! -d "$bin_dir" ]; then
        return 0
    fi

    if [ -z "$(windows_pe_import_tool)" ]; then
        die "llvm-objdump or objdump is required to collect Windows runtime DLLs"
    fi

    log "copying Windows runtime DLL closure for binaries in $bin_dir"

    queue_file="$(mktemp)"
    seen_file="$(mktemp)"

    collect_windows_package_pe_files "$bin_dir" | sort -u > "$queue_file"
    : > "$seen_file"

    while [ -s "$queue_file" ]; do
        processed=$((processed + 1))
        if [ "$processed" -gt "$max_processed" ]; then
            rm -f "$queue_file" "$queue_file.next" "$seen_file"
            die "Windows runtime DLL dependency traversal exceeded $max_processed files"
        fi

        current="$(head -n 1 "$queue_file")"
        tail -n +2 "$queue_file" > "$queue_file.next"
        mv "$queue_file.next" "$queue_file"

        if grep -Fx -- "$current" "$seen_file" >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$current" >> "$seen_file"

        if ! imports="$(windows_pe_import_dll_names "$current")"; then
            die "failed to inspect Windows PE imports for $(basename "$current")"
        fi
        while IFS= read -r dll_name; do
            [ -n "$dll_name" ] || continue

            windows_runtime_dll_name_is_safe "$dll_name" ||
                die "unsafe Windows runtime DLL import name for $(basename "$current"): $dll_name"

            if windows_runtime_dll_name_is_system "$dll_name"; then
                continue
            fi

            if [ -f "$bin_dir/$dll_name" ]; then
                continue
            fi

            dll_path="$(find_windows_runtime_dll_by_name "$dll_name" "$bin_dir")"
            if [ -z "$dll_path" ] || [ ! -f "$dll_path" ]; then
                die "unresolved Windows runtime DLL import for $(basename "$current"): $dll_name"
            fi

            windows_runtime_dll_allowed_path "$dll_path" ||
                die "Windows runtime DLL import resolves outside package providers for $(basename "$current"): $dll_name -> $dll_path"

            dll_name="$(basename "$dll_path")"
            cp -f "$dll_path" "$bin_dir/$dll_name"
            log "  copied PE import: $dll_name"
            printf '%s\n' "$bin_dir/$dll_name" >> "$queue_file"
        done <<< "$imports"
    done

    rm -f "$queue_file" "$queue_file.next" "$seen_file"
}

copy_windows_python_runtime() {
    local cmake_cache="${1:-}"
    local copy_executable="${2:-false}"
    local include_lldb="${3:-false}"
    local python_executable=""
    local python_library=""
    local version
    local full_version
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
    full_version="$($python_executable - <<'PYSCRIPT'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
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

    if [ -z "$version" ] || [ -z "$full_version" ] || [ -z "$stdlib" ] || [ ! -d "$stdlib" ]; then
        die "could not locate Python standard library for Windows package"
    fi

    dst="$PREFIX/lib/python$version"

    log "copying Python standard library: $stdlib -> $dst"

    copy_python_stdlib_runtime_entries "$stdlib" "$dst" "$version" || return $?

    if [ "$include_lldb" = true ]; then
        if [ -d "$dst/site-packages/lldb" ]; then
            log "preserved LLDB Python package: $dst/site-packages/lldb"
            "$python_executable" -m compileall -q "$dst/site-packages/lldb" || true
            "$python_executable" -O -m compileall -q "$dst/site-packages/lldb" || true
        else
            log "warning: LLDB Python package was not found under $dst/site-packages/lldb"
        fi
    fi

    prune_python_runtime_nonruntime_payload "$dst"
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
    create_windows_python_path_config "$PREFIX/bin" "$version" "$include_lldb"

    if [ "$copy_executable" = true ]; then
        cp -f "$python_executable" "$PREFIX/bin/cup-python3.exe"
        cat > "$PREFIX/bin/cup-python3._pth" <<EOF_PYTHON_PATH
../lib/python$version
../lib/python$version/lib-dynload
../lib/python$version/site-packages
import site
EOF_PYTHON_PATH
        log "copied private Windows Python interpreter for packaged helper scripts"
    fi

    PACKAGED_PYTHON_RUNTIME_VERSION="$full_version"
}


create_windows_python_path_config() {
    local bin_dir="$1"
    local version="$2"
    local include_lldb="${3:-false}"
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
    )
    if [ "$include_lldb" = true ]; then
        names+=(lldb lldb-dap)
    fi

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

package_relative_path_is_safe() {
    local relative="$1"
    local segment
    local base
    local lower
    local old_ifs
    local -a _package_path_segments

    case "$relative" in
        ""|/*|*/|\\*|*\\*|*:*) return 1 ;;
    esac
    # `read` below is line-oriented. Reject embedded newlines before splitting
    # so a malformed path can never be truncated into an apparently safe one.
    [ "$relative" = "${relative//$'\n'/}" ] || return 1

    old_ifs="$IFS"
    IFS=/
    read -r -a _package_path_segments <<< "$relative"
    IFS="$old_ifs"

    for segment in "${_package_path_segments[@]}"; do
        [ -n "$segment" ] || return 1
        [ "$segment" != "." ] && [ "$segment" != ".." ] || return 1
        LC_ALL=C printf '%s' "$segment" | grep -Eq '^[!-~]+$' || return 1
        case "$segment" in
            *[\\/:*?\"\<\>\|]*|*.) return 1 ;;
        esac
        base="${segment%%.*}"
        lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
        case "$lower" in
            con|prn|aux|nul|com[1-9]|lpt[1-9]) return 1 ;;
        esac
    done

    return 0
}

package_file_digest() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        die "sha256sum or shasum is required to generate package manifests"
    fi
}

package_text_digest() {
    local text="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$text" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
    else
        die "sha256sum or shasum is required to generate package manifests"
    fi
}

package_file_mode_class() {
    local path="$1"
    local host_platform="$2"
    local base

    if is_windows_platform "$host_platform"; then
        base="$(basename "$path" | tr '[:upper:]' '[:lower:]')"
        case "$base" in
            *.exe|*.com|*.bat|*.cmd|*.dll|*.pyd)
                printf '%s\n' 0755
                return 0
                ;;
        esac

        # MSYS2 also reports shebang scripts as executable even when chmod
        # cannot carry a meaningful native-Windows execute permission. Mirror
        # that archive semantics so manifest.txt and the emitted tar/ZIP modes
        # describe the same logical package.
        if [ -f "$path" ] &&
           LC_ALL=C head -c 2 "$path" 2>/dev/null | grep -q '^#!'; then
            printf '%s\n' 0755
        else
            printf '%s\n' 0644
        fi
    elif [ -x "$path" ]; then
        printf '%s\n' 0755
    else
        printf '%s\n' 0644
    fi
}

package_write_path_list() {
    local package_root="$1"
    local output="$2"
    local folded
    local duplicate
    local path
    local relative

    : > "$output"
    while IFS= read -r -d '' path; do
        relative="${path#"$package_root"/}"
        [ "$relative" != "manifest.txt" ] || continue
        [ "$relative" != ".manifest.paths" ] || continue
        package_relative_path_is_safe "$relative" ||
            die "package contains a path outside the CUP package grammar: $relative"
        [ "${#relative}" -lt 1024 ] || die "package path exceeds CUP path limit: $relative"
        printf '%s\n' "$relative" >> "$output"
    done < <(find "$package_root" ! -path "$package_root" -print0)

    LC_ALL=C sort -o "$output" "$output"
    folded="$(mktemp)"
    LC_ALL=C tr 'A-Z' 'a-z' < "$output" | LC_ALL=C sort > "$folded"
    duplicate="$(uniq -d "$folded" | sed -n '1p')"
    rm -f "$folded"
    [ -z "$duplicate" ] || die "package contains a case-fold path collision: $duplicate"
}

package_verify_tree() {
    local package_root="$1"
    local host_platform="$2"
    local path
    local relative

    while IFS= read -r -d '' path; do
        relative="${path#"$package_root"/}"
        if [ -L "$path" ]; then
            if is_windows_platform "$host_platform"; then
                die "Windows package root contains a symbolic link: $relative"
            fi
            package_resolve_staging_link "$package_root" "$relative" >/dev/null ||
                die "final package root contains an unsafe symbolic link: $relative"
            continue
        fi
        if [ -d "$path" ] || [ -f "$path" ]; then
            continue
        fi
        die "final package root contains an unsupported object: $relative"
    done < <(find "$package_root" ! -path "$package_root" -print0)

}

package_write_manifest() {
    local package_root="$1"
    local host_platform="$2"
    local output="$3"
    local path_list="$package_root/.manifest.paths"
    local relative
    local path
    local mode
    local digest
    local target

    package_write_path_list "$package_root" "$path_list"
    {
        printf 'format=2\n'
        while IFS= read -r relative; do
            [ -n "$relative" ] || continue
            path="$package_root/$relative"
            if [ -L "$path" ]; then
                if is_windows_platform "$host_platform"; then
                    rm -f "$path_list"
                    die "Windows package contains a symbolic link while generating manifest: $relative"
                fi
                target="$(package_read_link_target "$path")" || {
                    rm -f "$path_list"
                    die "cannot authenticate invalid symbolic-link target: $relative"
                }
                digest="$(package_text_digest "$target")"
                printf 'l\t-\t%s\t%s\n' "$digest" "$relative"
            elif [ -d "$path" ]; then
                printf 'd\t0755\t-\t%s\n' "$relative"
            elif [ -f "$path" ]; then
                mode="$(package_file_mode_class "$path" "$host_platform")"
                digest="$(package_file_digest "$path")"
                printf 'f\t%s\t%s\t%s\n' "$mode" "$digest" "$relative"
            else
                rm -f "$path_list"
                die "unsupported object while generating manifest: $relative"
            fi
        done < "$path_list"
    } > "$output"
    rm -f "$path_list"
}

package_generate_manifest() {
    local package_root="$1"
    local host_platform="$2"
    local manifest="$package_root/manifest.txt"

    rm -f "$manifest"
    package_verify_tree "$package_root" "$host_platform"
    package_write_manifest "$package_root" "$host_platform" "$manifest"
    chmod 0644 "$manifest"
}

package_info_value() {
    local info="$1"
    local key="$2"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found=1 } END { if (!found) exit 1 }' "$info"
}

package_verify_info_structure() {
    local info="$1"
    local seen
    local line
    local key
    local value
    local bytes

    [ -f "$info" ] || die "final package is missing info.txt"
    bytes="$(wc -c < "$info" | tr -d '[:space:]')"
    [ "$bytes" -le 4194304 ] || die "info.txt exceeds CUP metadata size limit"
    [ "$bytes" -gt 0 ] || die "info.txt is empty"
    [ "$(tail -c 1 "$info" | wc -l | tr -d '[:space:]')" = 1 ] ||
        die "info.txt must end with a newline"

    seen="$(mktemp)"
    : > "$seen"
    while IFS= read -r line; do
        [ "${#line}" -lt 512 ] || {
            rm -f "$seen"
            die "info.txt line exceeds CUP metadata line limit"
        }
        case "$line" in
            *=*) ;;
            *)
                rm -f "$seen"
                die "info.txt contains a line without '='"
                ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        if ! info_key_is_valid "$key" || [ -z "$value" ] ||
            [ "${#key}" -ge 128 ] || [ "${#value}" -ge 384 ]; then
            rm -f "$seen"
            die "info.txt contains an invalid or oversized key/value field: $key"
        fi
        if LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'; then
            rm -f "$seen"
            die "info.txt contains a control character in field: $key"
        fi
        case "$key" in
            features.*|requires.*)
                case "$value" in
                    true|false) ;;
                    *)
                        rm -f "$seen"
                        die "info.txt boolean field must be true or false: $key=$value"
                        ;;
                esac
                ;;
        esac
        if grep -Fx -- "$key" "$seen" >/dev/null 2>&1; then
            rm -f "$seen"
            die "info.txt contains a duplicate field: $key"
        fi
        printf '%s\n' "$key" >> "$seen"
    done < "$info"
    rm -f "$seen"
}

package_verify_info_contract() {
    local package_root="$1"
    local tool="$2"
    local version="$3"
    local host_platform="$4"
    local target_platform="$5"
    local revision="$6"
    local info="$package_root/info.txt"
    local package_version
    local expected_source_name
    local python_runtime_state
    local python_runtime_metadata_version
    local key
    local value
    local entry_count=0

    package_version="$(package_version_name "$tool" "$version" "$host_platform" "$target_platform" "$revision")"
    package_verify_info_structure "$info"

    for key in \
        package.component package.tool package.version package.mode package.formats \
        platform.host platform.target platform.host_triple platform.target_triple \
        platform.family platform.runtime platform.thread_model \
        build.environment build.source_policy \
        source.primary.name source.primary.version source.primary.url source.primary.sha256; do
        package_info_value "$info" "$key" >/dev/null || die "info.txt is missing required field: $key"
    done

    [ "$(package_info_value "$info" package.component)" = "$(package_component_for_tool "$tool")" ] ||
        die "info.txt package.component does not match package identity"
    [ "$(package_info_value "$info" package.tool)" = "$tool" ] ||
        die "info.txt package.tool does not match package identity"
    [ "$(package_info_value "$info" package.version)" = "$package_version" ] ||
        die "info.txt package.version does not match package identity"
    if package_revision_is_applicable "$tool"; then
        package_info_value "$info" package.revision >/dev/null ||
            die "info.txt is missing required field: package.revision"
        [ "$(package_info_value "$info" package.revision)" = "$revision" ] ||
            die "info.txt package.revision does not match package identity"
    elif package_info_value "$info" package.revision >/dev/null 2>&1; then
        die "info.txt package.revision is not valid for a revisionless package"
    fi
    [[ "$(package_info_value "$info" source.primary.sha256)" =~ ^[0-9a-f]{64}$ ]] ||
        die "info.txt source.primary.sha256 is not a lowercase SHA-256"

    case "$tool" in
        gcc) expected_source_name=gcc ;;
        gdb) expected_source_name=gdb ;;
        ld) expected_source_name=binutils ;;
        clang|lld|lldb|clangd|clang-format|clang-tidy) expected_source_name=llvm-project ;;
        valgrind) expected_source_name=valgrind ;;
        *) die "cannot derive primary source identity for tool: $tool" ;;
    esac
    [ "$(package_info_value "$info" source.primary.name)" = "$expected_source_name" ] ||
        die "info.txt source.primary.name does not match package tool"
    [ "$(package_info_value "$info" source.primary.version)" = "$version" ] ||
        die "info.txt source.primary.version does not match selected package version"

    python_runtime_state="$(package_info_value "$info" contents.python_runtime 2>/dev/null || true)"
    python_runtime_metadata_version="$(package_info_value "$info" contents.python_runtime.version 2>/dev/null || true)"
    if [ "$python_runtime_state" = packaged ]; then
        [ -n "$python_runtime_metadata_version" ] ||
            die "info.txt packaged Python runtime is missing contents.python_runtime.version"
        numeric_version_is_valid "$python_runtime_metadata_version" ||
            die "info.txt contents.python_runtime.version is not a numeric dotted version"
    elif [ -n "$python_runtime_metadata_version" ]; then
        die "info.txt contains Python runtime version metadata without a packaged Python runtime"
    fi

    if [ "$tool" = gcc ]; then
        for key in bundle.components bundle.binutils.version bundle.binutils.url bundle.binutils.sha256; do
            package_info_value "$info" "$key" >/dev/null ||
                die "info.txt is missing required GCC composition field: $key"
        done
        numeric_version_is_valid "$(package_info_value "$info" bundle.binutils.version)" ||
            die "info.txt bundle.binutils.version is not a numeric dotted version"
        [[ "$(package_info_value "$info" bundle.binutils.sha256)" =~ ^[0-9a-f]{64}$ ]] ||
            die "info.txt bundle.binutils.sha256 is not a lowercase SHA-256"

        if is_windows_platform "$target_platform"; then
            [ "$(package_info_value "$info" bundle.components)" = "binutils,mingw-w64" ] ||
                die "info.txt bundle.components does not match Windows-target GCC composition"
            for key in bundle.mingw-w64.version bundle.mingw-w64.url bundle.mingw-w64.sha256; do
                package_info_value "$info" "$key" >/dev/null ||
                    die "info.txt is missing required Windows-target GCC composition field: $key"
            done
            numeric_version_is_valid "$(package_info_value "$info" bundle.mingw-w64.version)" ||
                die "info.txt bundle.mingw-w64.version is not a numeric dotted version"
            [[ "$(package_info_value "$info" bundle.mingw-w64.sha256)" =~ ^[0-9a-f]{64}$ ]] ||
                die "info.txt bundle.mingw-w64.sha256 is not a lowercase SHA-256"
        else
            [ "$(package_info_value "$info" bundle.components)" = "binutils" ] ||
                die "info.txt bundle.components does not match native GCC composition"
            if package_info_value "$info" bundle.mingw-w64.version >/dev/null 2>&1 ||
                package_info_value "$info" bundle.mingw-w64.url >/dev/null 2>&1 ||
                package_info_value "$info" bundle.mingw-w64.sha256 >/dev/null 2>&1; then
                die "info.txt contains MinGW-w64 composition metadata for a non-Windows GCC target"
            fi
        fi
    fi

    [ "$(package_info_value "$info" package.mode)" = "self-contained" ] ||
        die "info.txt package.mode must be self-contained"
    [ "$(package_info_value "$info" package.formats)" = "$(package_formats_csv "$host_platform")" ] ||
        die "info.txt package.formats does not match host package formats"
    [ "$(package_info_value "$info" platform.host)" = "$host_platform" ] ||
        die "info.txt platform.host does not match package identity"
    [ "$(package_info_value "$info" platform.target)" = "$target_platform" ] ||
        die "info.txt platform.target does not match package identity"
    [ "$(package_info_value "$info" platform.host_triple)" = "$(platform_triple "$host_platform")" ] ||
        die "info.txt platform.host_triple does not match package identity"
    [ "$(package_info_value "$info" platform.target_triple)" = "$(platform_triple "$target_platform")" ] ||
        die "info.txt platform.target_triple does not match package identity"
    [ "$(package_info_value "$info" platform.family)" = "$(platform_family "$target_platform")" ] ||
        die "info.txt platform.family does not match package identity"
    [ "$(package_info_value "$info" platform.runtime)" = "$(platform_runtime "$target_platform")" ] ||
        die "info.txt platform.runtime does not match package identity"
    [ "$(package_info_value "$info" platform.thread_model)" = "$(platform_thread_model "$target_platform")" ] ||
        die "info.txt platform.thread_model does not match package identity"

    while IFS='=' read -r key value; do
        case "$key" in
            entry.*)
                package_relative_path_is_safe "$value" || die "invalid entry path in info.txt: $key=$value"
                if [ -L "$package_root/$value" ]; then
                    if is_windows_platform "$host_platform" ||
                        ! package_resolve_staging_link "$package_root" "$value" >/dev/null; then
                        die "info.txt entry is not a safe package command: $key=$value"
                    fi
                elif [ ! -f "$package_root/$value" ]; then
                    die "info.txt entry is not a regular file or safe symbolic-link alias: $key=$value"
                fi
                if ! is_windows_platform "$host_platform" && [ ! -x "$package_root/$value" ]; then
                    die "info.txt entry is not executable: $key=$value"
                fi
                entry_count=$((entry_count + 1))
                ;;
        esac
    done < "$info"

    [ "$entry_count" -gt 0 ] || die "info.txt does not declare any entry.* command"
}

package_read_link_target() {
    local link="$1"
    local line_count

    # readlink writes one record terminator of its own. More than one output line
    # therefore means the stored link target itself contains a newline. Command
    # substitution would otherwise truncate trailing newlines and `read` would
    # silently ignore everything after the first embedded newline. Such targets
    # are outside the CUP package path grammar and must never be normalized.
    line_count="$(readlink "$link" | wc -l | tr -d '[:space:]')" || return 1
    [ "$line_count" = 1 ] || return 1
    readlink "$link"
}

package_lexical_relative_target() {
    local link_relative="$1"
    local target="$2"
    local parent
    local combined
    local segment
    local old_ifs
    local -a input_segments
    local -a output_segments=()

    case "$target" in
        ""|/*|\\*|*\\*|*:*) return 1 ;;
    esac

    parent="${link_relative%/*}"
    [ "$parent" != "$link_relative" ] || parent=""
    if [ -n "$parent" ]; then
        combined="$parent/$target"
    else
        combined="$target"
    fi
    [ "$combined" = "${combined//$'\n'/}" ] || return 1

    old_ifs="$IFS"
    IFS=/
    read -r -a input_segments <<< "$combined"
    IFS="$old_ifs"

    for segment in "${input_segments[@]}"; do
        case "$segment" in
            ""|.) continue ;;
            ..)
                [ "${#output_segments[@]}" -gt 0 ] || return 1
                unset 'output_segments[${#output_segments[@]}-1]'
                ;;
            *) output_segments+=("$segment") ;;
        esac
    done

    [ "${#output_segments[@]}" -gt 0 ] || return 1
    (IFS=/; printf '%s\n' "${output_segments[*]}")
}

package_resolve_staging_link() {
    local prefix="$1"
    local start_relative="$2"
    local current="$start_relative"
    local target
    local next
    local seen='|'

    while [ -L "$prefix/$current" ]; do
        case "$seen" in
            *"|$current|"*) return 1 ;;
        esac
        seen="$seen$current|"

        target="$(package_read_link_target "$prefix/$current")" || return 1
        next="$(package_lexical_relative_target "$current" "$target")" || return 1
        package_relative_path_is_safe "$next" || return 1
        current="$next"
    done

    [ -f "$prefix/$current" ] && [ ! -L "$prefix/$current" ] || return 1
    printf '%s\n' "$current"
}

package_verify_staging_objects() {
    local prefix="$1"
    local path

    while IFS= read -r -d '' path; do
        if [ -L "$path" ] || [ -d "$path" ] || [ -f "$path" ]; then
            continue
        fi
        die "staging package contains an unsupported object: ${path#"$prefix"/}"
    done < <(find "$prefix" ! -path "$prefix" -print0)
}

package_verify_staging_paths() {
    local prefix="$1"
    local path
    local relative

    while IFS= read -r -d '' path; do
        relative="${path#"$prefix"/}"
        package_relative_path_is_safe "$relative" ||
            die "staging package contains a path outside the CUP path grammar: $relative"
        [ "${#relative}" -lt 1024 ] ||
            die "staging package path exceeds CUP path limit: $relative"
    done < <(find "$prefix" ! -path "$prefix" -print0)
}

package_verify_staging_links() {
    local prefix="$1"
    local host_platform="$2"
    local link
    local relative
    local target
    local resolved

    while IFS= read -r -d '' link; do
        relative="${link#"$prefix"/}"
        if is_windows_platform "$host_platform"; then
            die "Windows staging package contains a symbolic link: $relative"
        fi
        package_relative_path_is_safe "$relative" ||
            die "staging package contains an unsafe symbolic-link path: $relative"
        target="$(package_read_link_target "$link")" ||
            die "staging symbolic-link target is outside the CUP path grammar: $relative"
        resolved="$(package_resolve_staging_link "$prefix" "$relative")" ||
            die "staging symbolic link is external, dangling, cyclic or not a regular-file alias: $relative -> $target"
        log "preserving package symlink: $relative -> $target (resolves to $resolved)"
    done < <(find "$prefix" -type l -print0)
}

package_normalize_modes() {
    local package_root="$1"
    local host_platform="$2"
    local path
    local mode

    chmod 0755 "$package_root"
    while IFS= read -r -d '' path; do
        [ -L "$path" ] && continue
        if [ -d "$path" ]; then
            chmod 0755 "$path"
        elif [ -f "$path" ]; then
            mode="$(package_file_mode_class "$path" "$host_platform")"
            chmod "$mode" "$path"
        fi
    done < <(find "$package_root" ! -path "$package_root" -print0)
}

package_normalize_root() {
    local prefix="$1"
    local package_root="$2"
    local host_platform="$3"

    package_verify_staging_objects "$prefix"
    package_verify_staging_links "$prefix" "$host_platform"
    rm -rf "$package_root"
    mkdir -p "$package_root"

    # Preserve admitted symbolic links. Hardlink inode identity is not part of the
    # logical package contract; this ordinary copy may materialize hardlinked paths.
    cp -RPp "$prefix"/. "$package_root"/
    package_normalize_modes "$package_root" "$host_platform"
    package_verify_tree "$package_root" "$host_platform"
}

package_reproducible_archives_enabled() {
    [ "${CUP_REPRODUCIBLE_ARCHIVES:-false}" = true ]
}

package_reproducible_epoch() {
    local epoch="${SOURCE_DATE_EPOCH:-946684800}"
    [[ "$epoch" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be a non-negative integer"
    [ "$epoch" -ge 315532800 ] || die "SOURCE_DATE_EPOCH must be 1980-01-01 or later for ZIP portability"
    printf '%s\n' "$epoch"
}

package_normalize_timestamps() {
    local package_root="$1"
    local epoch
    local path

    package_reproducible_archives_enabled || return 0
    epoch="$(package_reproducible_epoch)"
    while IFS= read -r -d '' path; do
        touch -h -d "@$epoch" "$path"
    done < <(find "$package_root" -print0)
}

create_reproducible_archive() {
    local format="$1"
    local package_base="$2"
    local package_root="$3"
    local output="$4"
    local host_platform="$5"
    local parent="$(dirname "$package_root")"
    local base="$(basename "$package_root")"
    local epoch

    is_linux_platform "$host_platform" ||
        die "reproducible archive mode is currently supported only for Linux packages"
    epoch="$(package_reproducible_epoch)"

    case "$format" in
        tar.xz)
            need xz
            tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
                -C "$parent" -cf - "$base" | xz -T1 -9 -c > "$output"
            ;;
        tar.gz)
            need gzip
            tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
                -C "$parent" -cf - "$base" | gzip -n -9 > "$output"
            ;;
        zip)
            (
                cd "$parent"
                find "$base" -print | LC_ALL=C sort | zip -X -q -y "$output" -@
            )
            ;;
        *) die "unsupported package format: $format" ;;
    esac
}

create_archive() {
    local format="$1"
    local package_base="$2"
    local package_root="$3"
    local output_dir="$4"
    local host_platform="$5"

    local output
    output="$output_dir/$package_base.$format"

    rm -f "$output"

    if package_reproducible_archives_enabled; then
        create_reproducible_archive "$format" "$package_base" "$package_root" "$output" "$host_platform"
        log "created reproducible package: $output"
        return 0
    fi

    case "$format" in
        tar.xz)
            tar -C "$(dirname "$package_root")" -cJf "$output" "$(basename "$package_root")"
            ;;
        tar.gz)
            tar -C "$(dirname "$package_root")" -czf "$output" "$(basename "$package_root")"
            ;;
        zip)
            if is_windows_platform "$host_platform"; then
                (cd "$(dirname "$package_root")" && zip -qr "$output" "$(basename "$package_root")")
            else
                (cd "$(dirname "$package_root")" && zip -qry "$output" "$(basename "$package_root")")
            fi
            ;;
        *)
            die "unsupported package format: $format"
            ;;
    esac

    log "created package: $output"
}

package_unzip_allow_warnings() {
    local status=0

    unzip "$@" || status=$?
    case "$status" in
        0) return 0 ;;
        1)
            # Info-ZIP status 1 means processing completed with warnings. The
            # semantic verifier still validates extraction, manifest identity
            # and the complete logical tree.
            log "warning: unzip completed with warnings: $*"
            return 0
            ;;
        *) die "unzip failed with status $status: $*" ;;
    esac
}

package_verify_archive() (
    local format="$1"
    local package_base="$2"
    local package_root="$3"
    local output_dir="$4"
    local host_platform="$5"
    local archive="$output_dir/$package_base.$format"
    local tmp
    local extracted
    local recomputed
    local extract_dir

    [ -f "$archive" ] || die "missing package archive for semantic verification: $archive"
    tmp="$(mktemp -d "$CUP_WORK_DIR/archive-verify.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    recomputed="$tmp/recomputed-manifest.txt"
    extract_dir="$tmp/extract"
    mkdir -p "$extract_dir"

    case "$format" in
        tar.xz) tar -xJf "$archive" -C "$extract_dir" ;;
        tar.gz) tar -xzf "$archive" -C "$extract_dir" ;;
        zip) package_unzip_allow_warnings -q "$archive" -d "$extract_dir" ;;
    esac

    extracted="$extract_dir/$package_base"
    [ -d "$extracted" ] || die "package archive has the wrong top-level root: $(basename "$archive")"
    if find "$extract_dir" -mindepth 1 -maxdepth 1 ! -name "$package_base" -print -quit | grep -q .; then
        die "package archive contains an unexpected top-level entry: $(basename "$archive")"
    fi
    [ -f "$extracted/manifest.txt" ] || die "package archive is missing manifest.txt: $(basename "$archive")"
    cmp -s "$package_root/manifest.txt" "$extracted/manifest.txt" ||
        die "package archive carries a different manifest.txt: $(basename "$archive")"

    package_verify_tree "$extracted" "$host_platform"
    package_write_manifest "$extracted" "$host_platform" "$recomputed"
    cmp -s "$package_root/manifest.txt" "$recomputed" || {
        diff -u "$package_root/manifest.txt" "$recomputed" >&2 || true
        die "package archive logical graph differs from finalized package tree: $(basename "$archive")"
    }

    log "verified package archive semantics: $archive"
)

verify_package_archives() {
    local package_base="$1"
    local package_root="$2"
    local output_dir="$3"
    local host_platform="$4"
    local format

    for format in $(package_formats_for_host "$host_platform"); do
        package_verify_archive "$format" "$package_base" "$package_root" "$output_dir" "$host_platform"
    done
}

generate_package_checksums() {
    local package_base="$1"
    local output_dir="$2"
    local checksum_file="$output_dir/SHA256SUMS"
    local temporary="$checksum_file.tmp.$$"
    local digest
    local file
    local format

    : > "$temporary"
    for format in tar.xz tar.gz zip; do
        file="$output_dir/$package_base.$format"
        [ -f "$file" ] || die "missing package archive for checksum: $file"
        if command -v sha256sum >/dev/null 2>&1; then
            (cd "$output_dir" && sha256sum "$package_base.$format") >> "$temporary"
        elif command -v shasum >/dev/null 2>&1; then
            digest="$(shasum -a 256 "$file" | awk '{print $1}')"
            printf '%s  %s\n' "$digest" "$package_base.$format" >> "$temporary"
        else
            rm -f "$temporary"
            die "sha256sum or shasum is required to package checksums"
        fi
    done
    LC_ALL=C sort -k2,2 "$temporary" > "$checksum_file"
    rm -f "$temporary"
    log "created checksums: $checksum_file"
}

verify_package_checksums() {
    local package_base="$1"
    local output_dir="$2"
    local checksum_file="$output_dir/SHA256SUMS"
    local expected_count=3
    local actual
    local actual_count
    local digest
    local format
    local name

    [ -f "$checksum_file" ] || die "missing checksum file: $checksum_file"
    actual_count="$(wc -l < "$checksum_file" | tr -d '[:space:]')"
    [ "$actual_count" -eq "$expected_count" ] ||
        die "SHA256SUMS must contain exactly $expected_count records"

    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$output_dir" && sha256sum -c SHA256SUMS) ||
            die "package checksum verification failed"
    else
        while read -r digest name; do
            name="${name#\*}"
            actual="$(shasum -a 256 "$output_dir/$name" | awk '{print $1}')"
            [ "$actual" = "$digest" ] || die "checksum mismatch: $name"
        done < "$checksum_file"
    fi

    for format in tar.xz tar.gz zip; do
        grep -Eq "^[0-9a-f]{64} [ *]${package_base//./\\.}\\.${format//./\\.}$" \
            "$checksum_file" || die "missing checksum entry for $package_base.$format"
    done
}

package_prune_nonrelocatable_libtool_archives() {
    local prefix="$1"
    local path

    while IFS= read -r -d '' path; do
        if grep -F "$CUP_WORK_DIR/" "$path" >/dev/null 2>&1 ||
           grep -F "$prefix/" "$path" >/dev/null 2>&1; then
            log "removing non-relocatable libtool metadata: ${path#"$prefix"/}"
            rm -f "$path"
        fi
    done < <(find "$prefix" -type f -name '*.la' -print0)
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

    mkdir -p "$(dirname "$package_root")"
    # Reject malformed staging paths/objects before runtime-closure code parses
    # filenames or derives copy destinations from the staging tree.
    package_verify_staging_objects "$prefix"
    package_verify_staging_paths "$prefix"
    package_prune_nonrelocatable_libtool_archives "$prefix"
    prepare_linux_runtime_closure "$prefix" "$host_platform"
    prepare_macos_runtime_closure "$prefix" "$host_platform"
    package_normalize_root "$prefix" "$package_root" "$host_platform"
    if declare -F package_verify_final_tool_policy >/dev/null 2>&1; then
        package_verify_final_tool_policy "$package_root" "$host_platform"
    fi
    package_verify_info_contract \
        "$package_root" "$tool" "$version" "$host_platform" "$target_platform" "$revision"
    package_generate_manifest "$package_root" "$host_platform"
    package_normalize_timestamps "$package_root"

    for format in $(package_formats_for_host "$host_platform"); do
        create_archive "$format" "$package_base" "$package_root" "$CUP_OUT_DIR" "$host_platform"
    done
    verify_package_archives "$package_base" "$package_root" "$CUP_OUT_DIR" "$host_platform"
    generate_package_checksums "$package_base" "$CUP_OUT_DIR"

    cat > "$CUP_OUT_DIR/release.env" <<EOF_ENV
release_tag=$release_tag
package_base=$package_base
EOF_ENV
}
