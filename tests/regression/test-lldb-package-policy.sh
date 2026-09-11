#!/usr/bin/env bash
set -euo pipefail

ROOT="${CUP_LLDB_PACKAGE_POLICY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BUILD="$ROOT/scripts/build/build-llvm-tool.sh"
POSIX="$ROOT/scripts/test/test-llvm-tool.sh"
WINDOWS="$ROOT/scripts/test/test-llvm-tool-windows.ps1"

need() {
    local file="$1" marker="$2" message="$3"
    grep -F -- "$marker" "$file" >/dev/null || {
        echo "LLDB package policy failed: $message" >&2
        exit 1
    }
}

reject() {
    local file="$1" marker="$2" message="$3"
    if grep -F -- "$marker" "$file" >/dev/null; then
        echo "LLDB package policy failed: $message" >&2
        exit 1
    fi
}

# Build scope is explicit: CUP owns Python/local debugging, DAP and Linux/Windows
# platform-server remote debugging, not incidental upstream tools/protocols.
for option in \
    '-DLLDB_INCLUDE_TESTS=OFF' \
    '-DLLDB_ENABLE_LIBCXX_TESTS=OFF' \
    '-DLLDB_ENABLE_PYTHON=ON' \
    '-DLLDB_ENABLE_LUA=OFF' \
    '-DLLDB_ENABLE_TREESITTER=OFF' \
    '-DLLDB_ENABLE_PROTOCOL_SERVERS=OFF' \
    '-DLLDB_ENABLE_GITHUB_BUG_REPORTER=OFF' \
    '-DLLDB_BUILD_INTEL_MPX=OFF' \
    '-DLLDB_TOOL_LLDB_DAP_BUILD=ON' \
    '-DLLDB_TOOL_LLDB_INSTR_BUILD=OFF' \
    '-DLLDB_TOOL_LLDB_MCP_BUILD=OFF' \
    '-DLLDB_TOOL_YAML2MACHO_CORE_BUILD=OFF'; do
    need "$BUILD" "$option" "missing explicit build-scope option: $option"
done
need "$BUILD" '-DLLDB_TOOL_LLDB_SERVER_BUILD=ON' 'Linux/Windows server build is not explicit'
need "$BUILD" '-DLLDB_TOOL_LLDB_SERVER_BUILD=OFF' 'macOS server build is not explicitly disabled'
need "$BUILD" '-DLLDB_TOOL_DARWIN_DEBUG_BUILD=OFF' 'macOS external Terminal.app helper is still built'
need "$BUILD" '-DLLDB_ENABLE_DYNAMIC_SCRIPTINTERPRETERS=ON' 'macOS Python dynamic-interpreter policy is not explicit'
need "$BUILD" '-DLLDB_ENABLE_DYNAMIC_SCRIPTINTERPRETERS=OFF' 'non-Darwin dynamic-interpreter policy is not explicit'
need "$BUILD" '-DLLDB_USE_SYSTEM_DEBUGSERVER=ON' 'macOS system-debugserver build policy is missing'
need "$BUILD" '-DCLANG_ENABLE_STATIC_ANALYZER=OFF' 'LLDB still builds the unrelated Clang static analyzer'

# Linux final package seed carries only deliberate LLDB roots/data. Darwin keeps
# lldb-argdumper as a private runtime helper because the native normal `run` path
# requires it; Linux/Windows do not promote or retain it.
need "$BUILD" 'llvm_copy_path_into_seed bin/lldb' 'Linux seed lost lldb'
need "$BUILD" 'llvm_copy_path_into_seed bin/lldb-dap' 'Linux seed lost lldb-dap'
need "$BUILD" 'llvm_copy_path_into_seed bin/lldb-server' 'Linux seed lost lldb-server'
reject "$BUILD" 'llvm_copy_path_into_seed bin/lldb-argdumper' 'Linux seed still carries lldb-argdumper'
need "$BUILD" 'rm -f "$python_packages_dir/lldb-argdumper"' 'Python-side argdumper companion is not pruned'
need "$POSIX" 'require_executable "$root/bin/lldb-argdumper"' 'macOS process launch prerequisite does not require private lldb-argdumper'
reject "$WINDOWS" 'LLDB process-launch capability is missing lldb-argdumper.exe' 'Windows process launch still requires lldb-argdumper'

# Final package layout is checked after all payload mutations and after the Linux
# seed is materialized, not on an intermediate staging tree.
need "$BUILD" 'prepare_lldb_package_seed' 'LLDB package seed owner is missing'
need "$BUILD" 'validate_llvm_package_layout "$PACKAGE_PREFIX"' 'final package layout is not validated'
need "$BUILD" 'macOS LLDB package retained lldb-server outside its declared remote-debugging scope' 'macOS lldb-server exclusion is not validated'
need "$BUILD" 'macOS LLDB package is missing its private lldb-argdumper runtime helper' 'macOS argdumper requirement is not validated'
need "$BUILD" 'Linux/Windows LLDB package retained unused lldb-argdumper helper' 'non-Darwin argdumper exclusion is not validated'

# Metadata separates payload/public entry/behavior. There is no redundant
# features.lldb_server alias; remote debugging is the real behavioral claim.
need "$BUILD" 'contents.lldb_server=$has_lldb_server' 'lldb-server payload inventory is missing'
need "$BUILD" 'info_required_entry entry.lldb_server' 'Linux/Windows lldb-server public entry is missing'
need "$BUILD" 'features.remote_debugging=$lldb_remote_debugging' 'remote-debugging feature metadata is missing'
reject "$BUILD" 'features.lldb_server=' 'redundant lldb-server behavioral feature remains'
need "$BUILD" 'requires.system_debugserver=true' 'macOS system-debugserver prerequisite is missing'
# Apple developer tools remain a Clang prerequisite, but must not be duplicated
# inside the LLDB case. Inspect only the LLDB metadata block.
if sed -n '/^[[:space:]]*lldb)/,/^[[:space:]]*clangd)/p' "$BUILD" | grep -F 'requires.apple_developer_tools=true' >/dev/null; then
    echo 'LLDB package policy failed: macOS LLDB still declares broad Apple developer-tools prerequisite' >&2
    exit 1
fi

# DAP uses its own launch field for ASLR and the framed protocol reader preserves
# out-of-order events/responses instead of discarding them.
need "$POSIX" '\"disableASLR\":false' 'POSIX DAP launch does not explicitly leave ASLR enabled'
reject "$POSIX" 'preRunCommands":["settings set target.disable-aslr false"]' 'POSIX DAP still uses the wrong preRunCommands ASLR owner'
need "$POSIX" 'FRAMED_PENDING+=("$FRAMED_MESSAGE")' 'POSIX framed waiter still drops unmatched messages'
need "$WINDOWS" 'disableASLR=$false' 'Windows DAP launch does not explicitly leave ASLR enabled'
need "$WINDOWS" '$script:FramedPending.Add($item)' 'Windows framed waiter still drops unmatched messages'

# Required LLDB capabilities must fail closed rather than becoming optional
# test branches when metadata accidentally changes to false.
need "$POSIX" 'for required_feature in' 'POSIX LLDB required feature contract is not fail-closed'
need "$POSIX" 'features.python features.target_create features.breakpoints' 'POSIX LLDB core required features are not asserted'
need "$POSIX" 'info_bool features.remote_debugging || {' 'Linux LLDB remote capability can still be silently skipped'
need "$POSIX" 'macOS LLDB must not declare package-owned remote debugging' 'macOS LLDB negative remote contract is not asserted'
need "$POSIX" 'macOS LLDB does not declare its private lldb-argdumper runtime helper' 'macOS argdumper contents are not fail-closed'
need "$POSIX" 'Linux LLDB package unexpectedly contains lldb-argdumper' 'Linux argdumper exclusion is not asserted'
need "$WINDOWS" 'foreach ($requiredFeature in @(' 'Windows LLDB required feature contract is not fail-closed'
need "$WINDOWS" "'features.remote_debugging'" 'Windows LLDB remote feature is not mandatory in product qualification'
need "$WINDOWS" 'Windows LLDB package unexpectedly contains non-public lldb-argdumper.exe' 'Windows published-package argdumper exclusion is not asserted'

# macOS system-debugserver is qualified by the real local launch, not by a
# non-equivalent xcrun lookup. Local launch is repeated after relocation C.
reject "$POSIX" 'xcrun --find debugserver' 'macOS test still uses xcrun lookup as debugserver oracle'
need "$POSIX" 'lldb_local_launch_probe "$root" A' 'LLDB original-root local launch oracle is missing'
need "$POSIX" 'lldb_local_launch_probe "$reloc_c" C' 'LLDB relocated local launch oracle is missing'
need "$POSIX" 'PYTHONDONTWRITEBYTECODE=1 "$candidate/bin/lldb"' 'LLDB product test may write Python cache into the package copy'

# Platform-mode remote debugging remains the deliberate Linux/Windows model.
need "$POSIX" '"$candidate/bin/lldb-server" platform --server' 'Linux remote qualification lost packaged platform-server mode'
need "$POSIX" 'platform select remote-linux' 'Linux remote qualification lost remote-linux platform'
need "$POSIX" 'platform connect connect://127.0.0.1:$port' 'Linux remote qualification lost platform connection'
reject "$POSIX" 'gdb-remote 127.0.0.1:$port' 'obsolete direct gdb-remote orchestration returned'
need "$WINDOWS" 'platform select remote-windows' 'Windows remote qualification lost remote-windows platform'
reject "$WINDOWS" "Test-InfoBool 'features.lldb_server'" 'Windows remote test still depends on removed duplicate lldb-server feature'

# Python/Clang resource identity is package-relative on both test implementations.
need "$POSIX" 'SBHostOS.GetLLDBPath(lldb.ePathTypeClangDir)' 'POSIX LLDB Clang-resource oracle is missing'
need "$WINDOWS" 'SBHostOS.GetLLDBPath(lldb.ePathTypeClangDir)' 'Windows LLDB Clang-resource oracle is missing'
need "$WINDOWS" 'LLDB Clang resource directory escaped the package' 'Windows Clang-resource containment is not fail-closed'

# Preserve previously closed Windows command semantics and generic relocation.
need "$WINDOWS" "'thread backtrace'" 'Windows LLDB lost canonical thread backtrace'
reject "$WINDOWS" "'-o', 'backtrace'" 'Windows LLDB contains invalid bare backtrace command'
need "$POSIX" 'if [[ "$(info_value platform.host)" == linux-* || "$(info_value platform.host)" == macos-* ]]; then' 'POSIX relocation no longer covers Linux and macOS'
reject "$POSIX" 'feature_enabled ' 'LLDB product test references undefined feature_enabled helper'

# Exercise the exact POSIX framing functions with a legal interleaving: a later
# event arrives before the response currently awaited. The first wait must queue
# the event and the second wait must recover it without reading another frame.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
extract_function() {
    local file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ ("^" function_name "\\(\\) \\{") { in_function=1; depth=0 }
        in_function {
            print
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}
functions="$TMP/framed-functions.sh"
extract_function "$POSIX" framed_read > "$functions"
extract_function "$POSIX" framed_wait >> "$functions"
# shellcheck source=/dev/null
source "$functions"
FRAMED_PENDING=()
FRAMED_MESSAGE=""
frame_a='{"type":"event","event":"stopped"}'
frame_b='{"type":"response","request_seq":2,"success":true}'
stream="$TMP/frames"
printf 'Content-Length: %d\r\n\r\n%sContent-Length: %d\r\n\r\n%s' \
    "${#frame_a}" "$frame_a" "${#frame_b}" "$frame_b" > "$stream"
exec {frame_fd}<"$stream"
framed_wait "$frame_fd" "$TMP/framed.log" '"request_seq"[[:space:]]*:[[:space:]]*2' 2 || {
    echo 'LLDB package policy failed: POSIX framed waiter could not pass interleaved response' >&2
    exit 1
}
[ "${#FRAMED_PENDING[@]}" -eq 1 ] || {
    echo 'LLDB package policy failed: POSIX framed waiter did not retain unmatched event' >&2
    exit 1
}
framed_wait "$frame_fd" "$TMP/framed.log" '"event"[[:space:]]*:[[:space:]]*"stopped"' 1 || {
    echo 'LLDB package policy failed: POSIX framed waiter could not recover queued event' >&2
    exit 1
}
[ "${#FRAMED_PENDING[@]}" -eq 0 ] || {
    echo 'LLDB package policy failed: POSIX framed waiter left recovered event queued' >&2
    exit 1
}
exec {frame_fd}<&-

echo LLDB_PACKAGE_POLICY=PASS
