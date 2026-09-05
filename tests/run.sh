#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for test_file in "$ROOT"/tests/regression/test-*.sh; do
    [ -f "$test_file" ] || continue
    printf '==> %s\n' "${test_file#"$ROOT/"}"
    bash "$test_file"
done
