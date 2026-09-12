#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOST_PLATFORM=linux-x64
export TARGET_PLATFORM=linux-x64
export CUP_ROOT="$TMP/root"
export CUP_WORK_DIR="$TMP/work"
export PREFIX="$TMP/package"
mkdir -p "$CUP_ROOT" "$CUP_WORK_DIR" "$PREFIX"

# shellcheck source=/dev/null
source "$ROOT/scripts/package/package-common.sh"

PY_PREFIX="$TMP/python"
PY_BIN="$PY_PREFIX/bin/python3.12"
PY_CFG="$PY_PREFIX/bin/python3.12-config"
STDLIB="$PY_PREFIX/lib/python3.12"
mkdir -p \
    "$PY_PREFIX/bin" \
    "$STDLIB/config-3.12" \
    "$STDLIB/config-3.12-x86_64-linux-gnu" \
    "$STDLIB/config-3.12d-x86_64-linux-gnu" \
    "$STDLIB/site-packages/clang" \
    "$STDLIB/Tools" \
    "$STDLIB/__phello__" \
    "$STDLIB/test" \
    "$STDLIB/tests" \
    "$STDLIB/idlelib" \
    "$STDLIB/tkinter" \
    "$STDLIB/turtledemo" \
    "$STDLIB/json/__pycache__" \
    "$STDLIB/lib-dynload" \
    "$PY_PREFIX/Resources/Python.app/Contents/MacOS" \
    "$TMP/host-python-site" \
    "$PREFIX/lib/python3.12/site-packages"

cat > "$PY_BIN" <<'PYEOF'
#!/usr/bin/env sh
if [ "${1:-}" = "--version" ]; then
    echo 'Python 3.12.3'
    exit 0
fi
exit 2
PYEOF
chmod 0755 "$PY_BIN"
cat > "$PY_CFG" <<EOF2
#!/usr/bin/env sh
[ "\${1:-}" = "--prefix" ] || exit 2
printf '%s\\n' '$PY_PREFIX'
EOF2
chmod 0755 "$PY_CFG"

printf 'runtime\n' > "$STDLIB/json.py"
printf 'native-runtime\n' > "$STDLIB/_sysconfigdata_test.py"
printf 'internal-target\n' > "$STDLIB/_sysconfigdata__x86_64-linux-gnu.py"
ln -s '_sysconfigdata__x86_64-linux-gnu.py' \
    "$STDLIB/_sysconfigdata__linux_x86_64-linux-gnu.py"
printf 'host-site-customization\n' > "$TMP/host-python-site/sitecustomize.py"
ln -s "$TMP/host-python-site/sitecustomize.py" "$STDLIB/sitecustomize.py"
printf 'plain-dev-config\n' > "$STDLIB/config-3.12/Makefile"
printf 'dev-archive\n' > "$STDLIB/config-3.12-x86_64-linux-gnu/libpython3.12.a"
printf 'dev-object\n' > "$STDLIB/config-3.12d-x86_64-linux-gnu/python.o"
printf 'source-site-package\n' > "$STDLIB/site-packages/should-not-copy.py"
printf 'ambient-clang-binding\n' > "$STDLIB/site-packages/clang/__init__.py"
printf 'ambient-libxml2-binding\n' > "$STDLIB/site-packages/libxml2.py"
printf 'builder-tool\n' > "$STDLIB/Tools/helper.py"
printf 'hello-test-package\n' > "$STDLIB/__phello__/__init__.py"
printf 'preserved-lldb-module\n' > "$PREFIX/lib/python3.12/site-packages/lldb.py"
printf 'test-only\n' > "$STDLIB/test/test_runtime.py"
printf 'tests-only\n' > "$STDLIB/tests/test_runtime.py"
printf 'idle\n' > "$STDLIB/idlelib/idle.py"
printf 'tk\n' > "$STDLIB/tkinter/__init__.py"
printf 'turtle\n' > "$STDLIB/turtledemo/demo.py"
printf 'cached\n' > "$STDLIB/json/__pycache__/json.cpython-312.pyc"
for test_module in _ctypes_test _testcapi _testinternalcapi _xxtestfuzz xxlimited xxsubtype; do
    printf 'test-extension\n' > "$STDLIB/lib-dynload/${test_module}.cpython-312-x86_64-linux-gnu.so"
done
printf 'runtime-extension\n' > "$STDLIB/lib-dynload/_ssl.cpython-312-x86_64-linux-gnu.so"
printf '#!/bin/sh\nexit 0\n' > "$PY_PREFIX/Resources/Python.app/Contents/MacOS/Python"
chmod 0755 "$PY_PREFIX/Resources/Python.app/Contents/MacOS/Python"

copy_posix_python_runtime "$PY_BIN" true "bin/python3.12"

[ "$PACKAGED_PYTHON_RUNTIME_VERSION" = 3.12.3 ] || {
    echo "packaged Python runtime provenance is wrong: $PACKAGED_PYTHON_RUNTIME_VERSION" >&2
    exit 1
}

[ -f "$PREFIX/lib/python3.12/json.py" ] || {
    echo 'missing runtime stdlib entry' >&2
    exit 1
}
[ -f "$PREFIX/lib/python3.12/_sysconfigdata_test.py" ] || {
    echo 'missing runtime sysconfig data' >&2
    exit 1
}
[ -L "$PREFIX/lib/python3.12/_sysconfigdata__linux_x86_64-linux-gnu.py" ] || {
    echo 'package-internal Python alias was not preserved as a symlink' >&2
    exit 1
}
[ "$(readlink "$PREFIX/lib/python3.12/_sysconfigdata__linux_x86_64-linux-gnu.py")" = \
    '_sysconfigdata__x86_64-linux-gnu.py' ] || {
    echo 'package-internal Python alias target changed' >&2
    exit 1
}
[ -f "$PREFIX/lib/python3.12/_sysconfigdata__linux_x86_64-linux-gnu.py" ] || {
    echo 'package-internal Python alias does not resolve to its copied target' >&2
    exit 1
}
[ ! -e "$PREFIX/lib/python3.12/sitecustomize.py" ] && \
    [ ! -L "$PREFIX/lib/python3.12/sitecustomize.py" ] || {
    echo 'host sitecustomize leaked into package runtime' >&2
    exit 1
}
[ -f "$PREFIX/lib/python3.12/site-packages/lldb.py" ] || {
    echo 'pre-existing package module was not preserved' >&2
    exit 1
}
[ ! -e "$PREFIX/lib/python3.12/site-packages/should-not-copy.py" ] && \
    [ ! -e "$PREFIX/lib/python3.12/site-packages/clang" ] && \
    [ ! -e "$PREFIX/lib/python3.12/site-packages/libxml2.py" ] || {
    echo 'source site-packages leaked into package runtime' >&2
    exit 1
}
[ ! -e "$PREFIX/lib/python3.12/config-3.12" ] || {
    echo 'plain CPython development config directory leaked into package runtime' >&2
    exit 1
}
[ ! -e "$PREFIX/lib/python3.12/config-3.12-x86_64-linux-gnu" ] || {
    echo 'CPython development config directory leaked into package runtime' >&2
    exit 1
}
[ ! -e "$PREFIX/lib/python3.12/config-3.12d-x86_64-linux-gnu" ] || {
    echo 'debug-CPython development config directory leaked into package runtime' >&2
    exit 1
}
for excluded in test tests idlelib tkinter turtledemo Tools __phello__; do
    [ ! -e "$PREFIX/lib/python3.12/$excluded" ] || {
        echo "non-runtime Python payload leaked into package: $excluded" >&2
        exit 1
    }
done
if find "$PREFIX/lib/python3.12" -type d -name __pycache__ -print -quit | grep -q .; then
    echo 'Python __pycache__ payload leaked into package runtime' >&2
    exit 1
fi
for test_module in _ctypes_test _testcapi _testinternalcapi _xxtestfuzz xxlimited xxsubtype; do
    if find "$PREFIX/lib/python3.12/lib-dynload" -maxdepth 1 -type f -name "${test_module}*.so" -print -quit | grep -q .; then
        echo "CPython test-only extension leaked into package runtime: $test_module" >&2
        exit 1
    fi
done
[ -f "$PREFIX/lib/python3.12/lib-dynload/_ssl.cpython-312-x86_64-linux-gnu.so" ] || {
    echo 'ordinary CPython runtime extension was pruned with test modules' >&2
    exit 1
}
[ -x "$PREFIX/bin/python3.12" ] || {
    echo 'requested package-owned Python executable was not copied' >&2
    exit 1
}

package_verify_staging_links "$PREFIX" "$HOST_PLATFORM" >/dev/null || {
    echo 'corrected Python runtime failed staging-link verification' >&2
    exit 1
}

# Framework Python on macOS has a companion app executable below Resources.
# The package relocates the framework dylib under lib/, so preserve the exact
# companion topology the launcher resolves relative to that dylib.
MAC_PREFIX="$TMP/macos-package"
PREFIX="$MAC_PREFIX"
HOST_PLATFORM=macos-x64
mkdir -p "$PREFIX"
copy_posix_python_runtime "$PY_BIN" true "libexec/python3"
[ -x "$PREFIX/lib/Resources/Python.app/Contents/MacOS/Python" ] || {
    echo 'macOS Python framework companion app was not preserved' >&2
    exit 1
}
[ ! -e "$PREFIX/lib/python3.12/test" ] || {
    echo 'macOS Python runtime retained test payload' >&2
    exit 1
}

# A load-bearing enumeration failure must not be hidden by a process substitution.
HOST_PLATFORM=linux-x64
PREFIX="$TMP/enumeration-package"
mkdir -p "$PREFIX"
if (
    find() { return 37; }
    copy_posix_python_runtime "$PY_BIN"
); then
    echo 'Python runtime enumeration failure was incorrectly accepted' >&2
    exit 1
fi

echo 'PYTHON_RUNTIME_VERSION_PROVENANCE=PASS'
echo 'PYTHON_RUNTIME_DEVELOPMENT_EXCLUSION=PASS'
echo 'PYTHON_RUNTIME_SITECUSTOMIZE_EXCLUSION=PASS'
echo 'PYTHON_RUNTIME_INTERNAL_ALIAS_PRESERVATION=PASS'
echo 'PYTHON_RUNTIME_STAGING_LINK_VERIFY=PASS'
echo 'PYTHON_RUNTIME_NON_RUNTIME_PAYLOAD_PRUNING=PASS'
echo 'PYTHON_RUNTIME_MACOS_FRAMEWORK_COMPANION=PASS'
echo 'PYTHON_RUNTIME_ENUMERATION_FAILURE_PROPAGATION=PASS'
