#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  $0 <host_platform> <target_platform>

Examples:
  $0 linux-x64 linux-x64
  $0 linux-x64 windows-x64
USAGE
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 2
fi

HOST_PLATFORM="$1"
TARGET_PLATFORM="$2"

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
host_path="$PATH"
tmpdir="$(mktemp -d /tmp/cup-gcc-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

require_executable() {
    local path="$1"

    if [ ! -x "$path" ]; then
        echo "missing executable: $path" >&2
        exit 1
    fi
}

require_pe_file() {
    local file_path="$1"

    test -s "$file_path"
    file "$file_path" | grep -i "PE"
}

info_value() {
    local key="$1"
    local info_file="$root/info.txt"

    if [ ! -f "$info_file" ]; then
        printf '\n'
        return 0
    fi

    awk -F= -v key="$key" '$1 == key { print $2; found=1 } END { if (!found) print "" }' "$info_file"
}

feature_enabled() {
    local key="$1"
    [ "$(info_value "$key")" = "true" ]
}

require_package_owned_program() {
    local package_root="$1"
    local compiler="$2"
    local program="$3"
    local reported
    local resolved
    local canonical_root

    reported="$("$compiler" -print-prog-name="$program")"
    [ -n "$reported" ] || {
        echo "GCC did not report a program path for: $program" >&2
        exit 1
    }
    case "$reported" in
        /*) ;;
        *)
            echo "GCC program is not package-anchored: $program -> $reported" >&2
            exit 1
            ;;
    esac

    resolved="$(realpath -e "$reported" 2>/dev/null || true)"
    canonical_root="$(realpath -e "$package_root")"
    case "$resolved" in
        "$canonical_root"/*) ;;
        *)
            echo "GCC program resolved outside package: $program -> $reported -> $resolved" >&2
            exit 1
            ;;
    esac
    printf 'package-owned program: %s -> %s\n' "$program" "${resolved#"$canonical_root"/}"
}

require_package_owned_file() {
    local package_root="$1"
    local compiler="$2"
    local name="$3"
    local reported
    local resolved
    local canonical_root

    reported="$("$compiler" -print-file-name="$name")"
    [ -n "$reported" ] && [ "$reported" != "$name" ] || {
        echo "GCC did not resolve package file: $name" >&2
        exit 1
    }
    resolved="$(realpath -e "$reported" 2>/dev/null || true)"
    canonical_root="$(realpath -e "$package_root")"
    case "$resolved" in
        "$canonical_root"/*) ;;
        *)
            echo "GCC file resolved outside package: $name -> $reported -> $resolved" >&2
            exit 1
            ;;
    esac
    printf 'package-owned file: %s -> %s\n' "$name" "${resolved#"$canonical_root"/}"
}

prepare_host_tool_poison() {
    local poison="$1"
    local tool

    mkdir -p "$poison"
    for tool in as ld; do
        cat > "$poison/$tool" <<'POISON_EOF'
#!/usr/bin/env sh
echo "unexpected host Binutils fallback: $(basename "$0")" >&2
exit 97
POISON_EOF
        chmod 0755 "$poison/$tool"
    done
}

verify_native_linux_tool_ownership() {
    local package_root="$1"

    require_package_owned_program "$package_root" "$package_root/bin/gcc" cc1
    require_package_owned_program "$package_root" "$package_root/bin/g++" cc1plus
    require_package_owned_program "$package_root" "$package_root/bin/gcc" collect2
    require_package_owned_program "$package_root" "$package_root/bin/gcc" lto-wrapper
    require_package_owned_program "$package_root" "$package_root/bin/gcc" as
    require_package_owned_program "$package_root" "$package_root/bin/gcc" ld

    require_package_owned_file "$package_root" "$package_root/bin/gcc" libgcc.a
    require_package_owned_file "$package_root" "$package_root/bin/g++" libstdc++.so
    require_package_owned_file "$package_root" "$package_root/bin/gcc" libgomp.so
    require_package_owned_file "$package_root" "$package_root/bin/gcc" liblto_plugin.so
    require_package_owned_file "$package_root" "$package_root/bin/gcc" libubsan.so
}

run_native_linux_poison_compile() {
    local package_root="$1"
    local poison="$2"
    local suffix="$3"
    local clean_home="$tmpdir/home-$suffix"

    mkdir -p "$clean_home"
    env -i \
        HOME="$clean_home" \
        PATH="$poison:/usr/bin:/bin" \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        TZ=UTC \
        "$package_root/bin/gcc" "$tmpdir/c-test.c" -o "$tmpdir/c-test-$suffix"
    "$tmpdir/c-test-$suffix" | grep -F "hello gcc c"

    env -i \
        HOME="$clean_home" \
        PATH="$poison:/usr/bin:/bin" \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        TZ=UTC \
        "$package_root/bin/g++" "$tmpdir/cpp-test.cpp" -o "$tmpdir/cpp-test-$suffix"
    "$tmpdir/cpp-test-$suffix" | grep -F "42"

    env -i \
        HOME="$clean_home" \
        PATH="$poison:/usr/bin:/bin" \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        TZ=UTC \
        "$package_root/bin/gcc" -flto "$tmpdir/lto-test.c" -o "$tmpdir/lto-test-$suffix"
    "$tmpdir/lto-test-$suffix"
}

require_no_redundant_native_linux_target_layouts() {
    case "$TARGET_PLATFORM" in
        linux-x64)
            primary="x86_64-pc-linux-gnu"
            redundant="x86_64-linux-gnu"
            ;;
        linux-arm64)
            primary="aarch64-unknown-linux-gnu"
            redundant="aarch64-linux-gnu"
            ;;
        *)
            return 0
            ;;
    esac

    if [ -d "$root/$redundant" ]; then
        echo "redundant GCC target-layout directory present: $redundant" >&2
        echo "expected GCC canonical target-layout directory: $primary" >&2
        exit 1
    fi

    if [ ! -d "$root/$primary" ]; then
        echo "missing GCC canonical target-layout directory: $primary" >&2
        exit 1
    fi
}

log_optional_feature() {
    local name="$1"
    local key="$2"

    if feature_enabled "$key"; then
        echo "optional feature enabled: $name"
        return 0
    fi

    echo "optional feature not enabled: $name"
    return 1
}

bash scripts/test/package-capabilities.sh "$root" gcc

if [ "$HOST_PLATFORM" = "$TARGET_PLATFORM" ] && [ "${HOST_PLATFORM#linux-}" != "$HOST_PLATFORM" ]; then
    export PATH="$root/bin:$PATH"

    require_no_redundant_native_linux_target_layouts

    require_executable "$root/bin/gcc"
    require_executable "$root/bin/g++"
    require_executable "$root/bin/as"
    require_executable "$root/bin/ld"

    "$root/bin/gcc" --version
    "$root/bin/g++" --version
    "$root/bin/as" --version
    "$root/bin/ld" --version
    "$root/bin/gcc" -print-libgcc-file-name
    "$root/bin/gcc" -print-prog-name=cc1
    verify_native_linux_tool_ownership "$root"

    cat > "$tmpdir/c-test.c" <<'C_EOF'
#include <stdio.h>

int main(void) {
    printf("hello gcc c\n");
    return 0;
}
C_EOF
    "$root/bin/gcc" "$tmpdir/c-test.c" -o "$tmpdir/c-test"
    "$tmpdir/c-test" | grep -F "hello gcc c"

    cat > "$tmpdir/cpp-test.cpp" <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
    "$root/bin/g++" "$tmpdir/cpp-test.cpp" -o "$tmpdir/cpp-test"
    "$tmpdir/cpp-test" | grep -F "42"

    cat > "$tmpdir/pthread-test.c" <<'PTHREAD_EOF'
#include <pthread.h>
#include <stdio.h>

static void *worker(void *arg) {
    return arg;
}

int main(void) {
    pthread_t thread;
    void *result = 0;

    if (pthread_create(&thread, 0, worker, (void *)42) != 0) {
        return 1;
    }

    if (pthread_join(thread, &result) != 0) {
        return 1;
    }

    printf("pthread %ld\n", (long)result);
    return result == (void *)42 ? 0 : 1;
}
PTHREAD_EOF
    "$root/bin/gcc" "$tmpdir/pthread-test.c" -o "$tmpdir/pthread-test" -pthread
    "$tmpdir/pthread-test" | grep -F "pthread 42"

    cat > "$tmpdir/lto-test.c" <<'LTO_EOF'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
LTO_EOF
    "$root/bin/gcc" -flto "$tmpdir/lto-test.c" -o "$tmpdir/lto-test"
    "$tmpdir/lto-test"

    if ! feature_enabled "features.openmp"; then
        echo "required GCC OpenMP capability is not declared" >&2
        exit 1
    fi
    cat > "$tmpdir/openmp-test.c" <<'OMP_EOF'
#include <omp.h>
#include <stdio.h>

int main(void) {
    int n = 0;
#pragma omp parallel reduction(+:n)
    n += 1;
    printf("openmp %d\n", n);
    return n > 0 ? 0 : 1;
}
OMP_EOF
    "$root/bin/gcc" -fopenmp "$tmpdir/openmp-test.c" -o "$tmpdir/openmp-test"
    "$tmpdir/openmp-test" | grep -F "openmp"

    if ! feature_enabled "features.sanitizers"; then
        echo "required native Linux GCC sanitizer capability is not declared" >&2
        exit 1
    fi
    cat > "$tmpdir/sanitizer-test.c" <<'SAN_EOF'
#include <stdio.h>

int main(void) {
    int x = 1;
    printf("sanitizer %d\n", x);
    return 0;
}
SAN_EOF
    "$root/bin/gcc" -fsanitize=undefined "$tmpdir/sanitizer-test.c" -o "$tmpdir/sanitizer-test"
    "$tmpdir/sanitizer-test" | grep -F "sanitizer 1"

    poison="$tmpdir/host-binutils-poison"
    prepare_host_tool_poison "$poison"
    run_native_linux_poison_compile "$root" "$poison" canonical
elif [ "$TARGET_PLATFORM" = "windows-x64" ]; then
    target_prefix="x86_64-w64-mingw32"

    require_executable "$root/bin/$target_prefix-gcc"
    require_executable "$root/bin/$target_prefix-g++"
    require_executable "$root/bin/$target_prefix-as"
    require_executable "$root/bin/$target_prefix-ld"

    "$root/bin/$target_prefix-gcc" --version
    "$root/bin/$target_prefix-g++" --version
    "$root/bin/$target_prefix-as" --version
    "$root/bin/$target_prefix-ld" --version

    cat > "$tmpdir/windows-c-test.c" <<'C_EOF'
int main(void) {
    return 0;
}
C_EOF
    "$root/bin/$target_prefix-gcc" "$tmpdir/windows-c-test.c" -o "$tmpdir/windows-c-test.exe"
    require_pe_file "$tmpdir/windows-c-test.exe"

    cat > "$tmpdir/windows-cpp-test.cpp" <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
    "$root/bin/$target_prefix-g++" "$tmpdir/windows-cpp-test.cpp" -o "$tmpdir/windows-cpp-test.exe"
    require_pe_file "$tmpdir/windows-cpp-test.exe"

    cat > "$tmpdir/windows-pthread-test.c" <<'PTHREAD_EOF'
#include <pthread.h>

static void *worker(void *arg) {
    return arg;
}

int main(void) {
    pthread_t thread;
    pthread_create(&thread, 0, worker, 0);
    pthread_join(thread, 0);
    return 0;
}
PTHREAD_EOF
    "$root/bin/$target_prefix-gcc" "$tmpdir/windows-pthread-test.c" -o "$tmpdir/windows-pthread-test.exe" -pthread
    require_pe_file "$tmpdir/windows-pthread-test.exe"

    cat > "$tmpdir/windows-lto-test.c" <<'LTO_EOF'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
LTO_EOF
    "$root/bin/$target_prefix-gcc" -flto "$tmpdir/windows-lto-test.c" -o "$tmpdir/windows-lto-test.exe"
    require_pe_file "$tmpdir/windows-lto-test.exe"

    if ! feature_enabled "features.openmp"; then
        echo "required GCC OpenMP capability is not declared for the Windows target" >&2
        exit 1
    fi
    cat > "$tmpdir/windows-openmp-test.c" <<'OMP_EOF'
#include <omp.h>

int main(void) {
    int n = 0;
#pragma omp parallel reduction(+:n)
    n += 1;
    return n > 0 ? 0 : 1;
}
OMP_EOF
    "$root/bin/$target_prefix-gcc" -fopenmp "$tmpdir/windows-openmp-test.c" -o "$tmpdir/windows-openmp-test.exe"
    require_pe_file "$tmpdir/windows-openmp-test.exe"

    if log_optional_feature "sanitizers" "features.sanitizers"; then
        cat > "$tmpdir/windows-sanitizer-test.c" <<'SAN_EOF'
int main(void) {
    int x = 1;
    return x == 1 ? 0 : 1;
}
SAN_EOF
        "$root/bin/$target_prefix-gcc" -fsanitize=undefined "$tmpdir/windows-sanitizer-test.c" -o "$tmpdir/windows-sanitizer-test.exe"
        require_pe_file "$tmpdir/windows-sanitizer-test.exe"
    fi
else
    echo "unsupported target platform: $TARGET_PLATFORM" >&2
    exit 2
fi

# Physical relocation: A must be unavailable before B, and A/B unavailable before C.
if [ "$HOST_PLATFORM" = "$TARGET_PLATFORM" ] && [ "${HOST_PLATFORM#linux-}" != "$HOST_PLATFORM" ]; then
    reloc_b="$tmpdir/relocation-b"
    reloc_c_parent="$tmpdir/relocation c with spaces"
    reloc_c="$reloc_c_parent/gcc-package"

    cp -RPp "$root" "$reloc_b"
    rm -rf "$root"
    [ ! -e "$root" ] || { echo "previous GCC root A is still available" >&2; exit 1; }
    verify_native_linux_tool_ownership "$reloc_b"
    run_native_linux_poison_compile "$reloc_b" "$poison" relocation-b

    mkdir -p "$reloc_c_parent"
    mv "$reloc_b" "$reloc_c"
    [ ! -e "$root" ] || { echo "previous GCC root A reappeared" >&2; exit 1; }
    [ ! -e "$reloc_b" ] || { echo "previous GCC root B is still available" >&2; exit 1; }
    verify_native_linux_tool_ownership "$reloc_c"
    run_native_linux_poison_compile "$reloc_c" "$poison" relocation-c
elif [ "$TARGET_PLATFORM" = "windows-x64" ]; then
    reloc_root="$tmpdir/relocated-gcc"
    cp -RPp "$root" "$reloc_root"
    export PATH="$reloc_root/bin:$host_path"
    target_prefix="x86_64-w64-mingw32"
    "$reloc_root/bin/$target_prefix-gcc" "$tmpdir/windows-c-test.c" -o "$tmpdir/windows-c-test-relocated.exe"
    require_pe_file "$tmpdir/windows-c-test-relocated.exe"
fi
