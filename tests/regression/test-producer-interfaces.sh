#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Repository-level producer interfaces are tested separately from the common
# package contract, which is validated once in each workflow's Ubuntu select job
# before any host-specific build job is dispatched.
# The build scripts are producer authorities too; they must reject unsupported
# identities before creating work directories or attempting source downloads.
assert_build_matrix_rejected() {
    local name="$1"
    shift
    local isolated="$TMP/matrix-$name"

    if CUP_ROOT="$isolated" "$@" >/dev/null 2>&1; then
        echo "unsupported producer matrix was accepted: $name" >&2
        exit 1
    fi
    [ ! -e "$isolated/.cup-build" ] || {
        echo "unsupported producer matrix was rejected too late: $name" >&2
        exit 1
    }
}

assert_build_matrix_rejected gcc-macos \
    "$ROOT/scripts/build/build-gcc.sh" stable macos-x64 macos-x64
assert_build_matrix_rejected gcc-unsupported-cross \
    "$ROOT/scripts/build/build-gcc.sh" stable linux-arm64 windows-x64
assert_build_matrix_rejected ld-macos \
    "$ROOT/scripts/build/build-ld.sh" stable macos-x64 macos-x64
assert_build_matrix_rejected ld-unsupported-cross \
    "$ROOT/scripts/build/build-ld.sh" stable linux-arm64 windows-x64
assert_build_matrix_rejected gdb-macos \
    "$ROOT/scripts/build/build-gdb.sh" stable macos-x64
assert_build_matrix_rejected llvm-unknown-platform \
    "$ROOT/scripts/build/build-llvm-tool.sh" clang stable solaris-x64
printf 'producer platform-matrix tests passed\n'

workflow_inputs() {
    awk '
        /^    inputs:/ { in_inputs=1; next }
        in_inputs && /^[^[:space:]]/ { exit }
        in_inputs { print }
    ' "$1"
}

# Native-only producers expose one platform input so an invalid host/target
# combination cannot be selected. GCC and standalone GNU ld retain separate
# host/target inputs because their deliberate matrix includes Linux->Windows.
gcc_workflow="$ROOT/.github/workflows/build-gcc.yml"
ld_workflow="$ROOT/.github/workflows/build-ld.yml"
for workflow in \
    "$ROOT/.github/workflows/build-gdb.yml" \
    "$ROOT/.github/workflows/build-llvm.yml" \
    "$ROOT/.github/workflows/build-valgrind.yml"; do
    inputs="$(workflow_inputs "$workflow")"
    printf '%s\n' "$inputs" | grep -Eq '^[[:space:]]+platform:' || {
        echo "native-only workflow is missing the single platform input: $workflow" >&2
        exit 1
    }
    if printf '%s\n' "$inputs" | grep -Eq '^[[:space:]]+(host_platform|target_platform):'; then
        echo "native-only workflow still exposes independent host/target inputs: $workflow" >&2
        exit 1
    fi
done
for workflow in "$gcc_workflow" "$ld_workflow"; do
    inputs="$(workflow_inputs "$workflow")"
    printf '%s\n' "$inputs" | grep -Eq '^[[:space:]]+host_platform:' || { echo "cross-capable workflow lost host input: $workflow" >&2; exit 1; }
    printf '%s\n' "$inputs" | grep -Eq '^[[:space:]]+target_platform:' || { echo "cross-capable workflow lost target input: $workflow" >&2; exit 1; }
done

# The abstract package contract has one workflow owner: the Ubuntu select job.
# Host-specific jobs test real packages instead of recreating synthetic POSIX
# filesystem fixtures on Windows or macOS.
for workflow in "$ROOT"/.github/workflows/build-*.yml; do
    count="$(grep -Fc 'bash scripts/test/test-package-contract.sh' "$workflow")"
    [ "$count" -eq 1 ] || {
        echo "common package contract must run exactly once per workflow: $workflow ($count)" >&2
        exit 1
    }
    select_line="$(grep -n '^  select:' "$workflow" | cut -d: -f1)"
    contract_line="$(grep -nF 'bash scripts/test/test-package-contract.sh' "$workflow" | cut -d: -f1)"
    build_line="$(grep -n '^  build:' "$workflow" | cut -d: -f1)"
    [ -n "$select_line" ] && [ -n "$contract_line" ] && [ -n "$build_line" ] &&
        [ "$select_line" -lt "$contract_line" ] && [ "$contract_line" -lt "$build_line" ] || {
        echo "common package contract is not owned by the select job: $workflow" >&2
        exit 1
    }
done

# GCC composition is an operator selection. The revision identifies that
# selected composition but does not encode or choose component versions.
inputs="$(workflow_inputs "$gcc_workflow")"
for input in binutils_version binutils_source_sha256 mingw_version mingw_source_sha256 revision; do
    printf '%s\n' "$inputs" | grep -Eq "^[[:space:]]+$input:" || {
        echo "GCC workflow is missing composition input '$input'" >&2
        exit 1
    }
done
for workflow in "$ROOT"/.github/workflows/build-*.yml; do
    [ "$workflow" = "$gcc_workflow" ] && continue
    inputs="$(workflow_inputs "$workflow")"
    if printf '%s\n' "$inputs" | grep -Eq '^[[:space:]]+(binutils_version|binutils_source_sha256|mingw_version|mingw_source_sha256|revision):'; then
        echo "non-GCC workflow exposes GCC composition inputs: $workflow" >&2
        exit 1
    fi
done
if grep -F 'set_gcc_composition' "$ROOT/scripts/build/build-gcc.sh" >/dev/null; then
    echo 'GCC builder still contains a GCC-version-to-composition mapping' >&2
    exit 1
fi
for variable in CUP_GCC_BINUTILS_VERSION CUP_GCC_MINGW_VERSION CUP_GCC_REVISION; do
    grep -F "$variable" "$ROOT/scripts/build/build-gcc.sh" >/dev/null || {
        echo "GCC builder does not consume composition selection: $variable" >&2
        exit 1
    }
done
grep -F 'package.revision=$REVISION' "$ROOT/scripts/build/build-gcc.sh" >/dev/null || {
    echo 'GCC builder lost package.revision metadata' >&2
    exit 1
}

# Builder CLIs mirror the public semantics.
grep -F 'if [ "$#" -ne 3 ]; then' "$ROOT/scripts/build/build-gcc.sh" >/dev/null || { echo 'GCC build CLI is not version+host+target' >&2; exit 1; }
grep -F 'if [ "$#" -ne 3 ]; then' "$ROOT/scripts/build/build-ld.sh" >/dev/null || { echo 'GNU ld build CLI is not version+host+target' >&2; exit 1; }
grep -F 'if [ "$#" -ne 2 ]; then' "$ROOT/scripts/build/build-gdb.sh" >/dev/null || { echo 'GDB build CLI is not version+platform' >&2; exit 1; }
grep -F 'if [ "$#" -ne 3 ]; then' "$ROOT/scripts/build/build-llvm-tool.sh" >/dev/null || { echo 'LLVM build CLI is not tool+version+platform' >&2; exit 1; }
grep -F 'if [ "$#" -ne 2 ]; then' "$ROOT/scripts/build/build-valgrind.sh" >/dev/null || { echo 'Valgrind build CLI is not version+platform' >&2; exit 1; }

for builder in build-ld.sh build-gdb.sh build-llvm-tool.sh build-valgrind.sh; do
    if grep -F 'package.revision=' "$ROOT/scripts/build/$builder" >/dev/null; then
        echo "revisionless builder still writes package.revision: $builder" >&2
        exit 1
    fi
done

publication_extract_script() {
    local workflow="$1"
    local output="$2"

    awk '
        index($0, "tag=\"${{ steps.release.outputs.tag }}\"") { capture = 1 }
        capture {
            line = $0
            sub(/^          /, "", line)
            print line
        }
        capture && index($0, "--notes \"Automated cup component build for $tag\"") { exit }
    ' "$workflow" |
        sed 's|^tag=.*|tag="fixture-tag"|; s|^repo=.*|repo="owner/repo"|' > "$output"
}

publication_run_fixture() {
    local workflow="$1"
    local release_state="$2"
    local tag_state="$3"
    local name="$4"
    local fixture="$TMP/publication-$name"

    rm -rf "$fixture"
    mkdir -p "$fixture/bin"
    publication_extract_script "$workflow" "$fixture/publication.sh"

    cat > "$fixture/bin/gh" <<'EOF_GH_STUB'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$PUBLICATION_CALL_LOG"
if [ "$1" = api ]; then
    case "$PUBLICATION_RELEASE_STATE" in
        FOUND) printf 'HTTP/2.0 200 OK\n\n{}\n'; exit 0 ;;
        NOT_FOUND) printf 'HTTP/2.0 404 Not Found\n\n{}\n'; exit 1 ;;
        ERROR) printf 'HTTP/2.0 503 Service Unavailable\n\n{}\n'; exit 1 ;;
        *) exit 64 ;;
    esac
fi
if [ "$1 $2" = 'release view' ]; then
    case "$PUBLICATION_RELEASE_STATE" in
        FOUND) exit 0 ;;
        NOT_FOUND) exit 1 ;;
        ERROR) exit 4 ;;
        *) exit 64 ;;
    esac
fi
exit 0
EOF_GH_STUB

    cat > "$fixture/bin/git" <<'EOF_GIT_STUB'
#!/bin/sh
printf 'git %s\n' "$*" >> "$PUBLICATION_CALL_LOG"
if [ "$1" = ls-remote ]; then
    case "$PUBLICATION_TAG_STATE" in
        FOUND) exit 0 ;;
        NOT_FOUND) exit 2 ;;
        ERROR) exit 128 ;;
        *) exit 64 ;;
    esac
fi
exit 0
EOF_GIT_STUB
    chmod +x "$fixture/bin/gh" "$fixture/bin/git"
    : > "$fixture/calls"

    set +e
    PATH="$fixture/bin:$PATH" \
        PUBLICATION_CALL_LOG="$fixture/calls" \
        PUBLICATION_RELEASE_STATE="$release_state" \
        PUBLICATION_TAG_STATE="$tag_state" \
        GITHUB_SHA=0123456789abcdef \
        bash -e "$fixture/publication.sh" >"$fixture/stdout" 2>"$fixture/stderr"
    PUBLICATION_FIXTURE_STATUS=$?
    set -e
    PUBLICATION_FIXTURE_CALLS="$fixture/calls"
}

assert_publication_not_called() {
    local pattern="$1"
    if grep -F "$pattern" "$PUBLICATION_FIXTURE_CALLS" >/dev/null; then
        echo "unexpected publication operation reached: $pattern" >&2
        cat "$PUBLICATION_FIXTURE_CALLS" >&2
        exit 1
    fi
}

for workflow in "$ROOT"/.github/workflows/build-*.yml; do
    grep -F 'Initialize build records' "$workflow" >/dev/null || { echo "build records is not initialized: $workflow" >&2; exit 1; }
    grep -F 'scripts/workflow/build-records.sh finalize' "$workflow" >/dev/null || { echo "build records is not finalized: $workflow" >&2; exit 1; }
    if [ "$(basename "$workflow")" = build-llvm.yml ]; then
        grep -F 'name: build-records-${{ matrix.tool }}-${{ inputs.version }}-${{ matrix.host_platform }}-${{ matrix.target_platform }}-${{ github.run_id }}-${{ github.run_attempt }}' "$workflow" >/dev/null || { echo "LLVM matrix build-records artifact identity is missing: $workflow" >&2; exit 1; }
    else
        grep -F 'name: build-records-${{ github.run_id }}-${{ github.run_attempt }}' "$workflow" >/dev/null || { echo "build records artifact identity is missing: $workflow" >&2; exit 1; }
    fi
    [ "$(grep -Fc 'if: ${{ always() }}' "$workflow")" -ge 2 ] || { echo "build records is not preserved on workflow failure: $workflow" >&2; exit 1; }
    grep -F 'path: .cup-build/build-records' "$workflow" >/dev/null || { echo "build records artifact path is missing: $workflow" >&2; exit 1; }
    grep -F 'if: ${{ inputs.publish }}' "$workflow" >/dev/null || { echo "publish=true gate missing: $workflow" >&2; exit 1; }
    grep -F 'if: ${{ !inputs.publish }}' "$workflow" >/dev/null || { echo "publish=false artifact gate missing: $workflow" >&2; exit 1; }
    grep -F 'gh api --include "repos/$repo/releases/tags/$tag"' "$workflow" >/dev/null || { echo "fail-closed release lookup missing: $workflow" >&2; exit 1; }
    grep -F 'if [ "$http_status" != 404 ]; then' "$workflow" >/dev/null || { echo "release lookup does not distinguish 404 from errors: $workflow" >&2; exit 1; }
    grep -F 'git ls-remote --exit-code --tags origin "refs/tags/$tag"' "$workflow" >/dev/null || { echo "remote tag lookup missing: $workflow" >&2; exit 1; }
    grep -F '2) ;;' "$workflow" >/dev/null || { echo "tag not-found status is not distinguished: $workflow" >&2; exit 1; }
    grep -F 'failed to determine remote tag state' "$workflow" >/dev/null || { echo "tag lookup errors are not fail-closed: $workflow" >&2; exit 1; }
    grep -F 'gh release delete "$tag" --repo "$repo" --cleanup-tag --yes' "$workflow" >/dev/null || { echo "same-identity replacement path missing: $workflow" >&2; exit 1; }
    grep -F 'git push origin ":refs/tags/$tag"' "$workflow" >/dev/null || { echo "stale standalone tag replacement path missing: $workflow" >&2; exit 1; }
    grep -F -- '--target "$GITHUB_SHA"' "$workflow" >/dev/null || { echo "release tag is not bound to current source SHA: $workflow" >&2; exit 1; }
    grep -F 'gh release create "$tag" dist/*.tar.xz dist/*.tar.gz dist/*.zip dist/SHA256SUMS' "$workflow" >/dev/null || { echo "publication asset set is incomplete: $workflow" >&2; exit 1; }
    if grep -Eqi 'increment package revision|immutable assets|never replaced' "$workflow"; then
        echo "stale immutable/revision-collision policy remains: $workflow" >&2
        exit 1
    fi

    stem="$(basename "$workflow" .yml)"

    publication_run_fixture "$workflow" FOUND NOT_FOUND "$stem-found"
    [ "$PUBLICATION_FIXTURE_STATUS" -eq 0 ] || { echo "existing release replacement failed: $workflow" >&2; exit 1; }
    grep -F 'gh release delete fixture-tag --repo owner/repo --cleanup-tag --yes' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "existing release was not replaced: $workflow" >&2; exit 1; }
    grep -F 'gh release create fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "replacement release was not recreated: $workflow" >&2; exit 1; }
    assert_publication_not_called 'git ls-remote'

    publication_run_fixture "$workflow" NOT_FOUND FOUND "$stem-stale-tag"
    [ "$PUBLICATION_FIXTURE_STATUS" -eq 0 ] || { echo "stale tag publication failed: $workflow" >&2; exit 1; }
    grep -F 'git push origin :refs/tags/fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "stale standalone tag was not removed: $workflow" >&2; exit 1; }
    grep -F 'gh release create fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "release was not created after stale tag removal: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'

    publication_run_fixture "$workflow" NOT_FOUND NOT_FOUND "$stem-new"
    [ "$PUBLICATION_FIXTURE_STATUS" -eq 0 ] || { echo "new publication path failed: $workflow" >&2; exit 1; }
    grep -F 'gh release create fixture-tag' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "new release was not created: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'
    assert_publication_not_called 'git push'

    publication_run_fixture "$workflow" ERROR FOUND "$stem-release-error"
    [ "$PUBLICATION_FIXTURE_STATUS" -ne 0 ] || { echo "release lookup operational error was accepted: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'
    assert_publication_not_called 'git ls-remote'
    assert_publication_not_called 'git push'
    assert_publication_not_called 'gh release create'

    publication_run_fixture "$workflow" NOT_FOUND ERROR "$stem-tag-error"
    [ "$PUBLICATION_FIXTURE_STATUS" -ne 0 ] || { echo "tag lookup operational error was accepted: $workflow" >&2; exit 1; }
    grep -F 'git ls-remote' "$PUBLICATION_FIXTURE_CALLS" >/dev/null || { echo "tag lookup was not exercised: $workflow" >&2; exit 1; }
    assert_publication_not_called 'gh release delete'
    assert_publication_not_called 'git push'
    assert_publication_not_called 'gh release create'
done
printf 'workflow input/publication contract tests passed\n'

llvm_builder="$ROOT/scripts/build/build-llvm-tool.sh"
llvm_workflow="$ROOT/.github/workflows/build-llvm.yml"
llvm_inputs="$(workflow_inputs "$llvm_workflow")"
printf '%s\n' "$llvm_inputs" | grep -Eq '^[[:space:]]+full_matrix:' || { echo 'LLVM workflow is missing full_matrix input' >&2; exit 1; }
grep -F 'default: false' "$llvm_workflow" >/dev/null || { echo 'LLVM full matrix is not opt-in' >&2; exit 1; }
[ "$(grep -Fc '          - select' "$llvm_workflow")" -eq 2 ] || { echo 'LLVM single-cell selectors do not expose select sentinels' >&2; exit 1; }
grep -F 'tool and platform must be selected when full_matrix is disabled' "$llvm_workflow" >/dev/null || { echo 'LLVM single-cell validation is missing' >&2; exit 1; }
grep -F 'for tool in clang lld lldb clangd clang-format clang-tidy; do' "$llvm_workflow" >/dev/null || { echo 'LLVM full matrix tool set is incomplete' >&2; exit 1; }
grep -F 'for platform in linux-x64 linux-arm64 windows-x64 macos-x64 macos-arm64; do' "$llvm_workflow" >/dev/null || { echo 'LLVM full matrix platform set is incomplete' >&2; exit 1; }
grep -F 'fail-fast: false' "$llvm_workflow" >/dev/null || { echo 'LLVM matrix does not preserve independent cell evidence' >&2; exit 1; }
grep -F 'matrix: ${{ fromJSON(needs.select.outputs.matrix) }}' "$llvm_workflow" >/dev/null || { echo 'LLVM build job does not consume the selected matrix' >&2; exit 1; }
grep -F '\"host_platform\":\"$platform\",\"target_platform\":\"$platform\"' "$llvm_workflow" >/dev/null || { echo 'LLVM matrix lost native host/target identity' >&2; exit 1; }
grep -F 'macos-x64) runner="macos-15-intel"' "$llvm_workflow" >/dev/null || { echo 'macOS x64 workflow path is missing' >&2; exit 1; }
grep -F 'macos-arm64) runner="macos-15"' "$llvm_workflow" >/dev/null || { echo 'macOS arm64 workflow path is missing' >&2; exit 1; }
grep -F "printf '%s\\n' '15.0'" "$llvm_builder" >/dev/null || {
    echo 'macOS deployment target owner is not 15.0' >&2
    exit 1
}
[ "$(grep -Fc 'CMAKE_OSX_DEPLOYMENT_TARGET="$(macos_deployment_target)"' "$llvm_builder")" -eq 2 ] || {
    echo 'macOS deployment target is not applied to both LLVM build paths' >&2
    exit 1
}
printf 'macOS 15.0 source contract tests passed\n'

printf 'PRODUCER_INTERFACES=PASS\n'

# Build records are workflow output, not package content. They must
# survive both successful and failed phases and retain final package metadata.
records_root="$TMP/records-fixture"
mkdir -p "$records_root/dist" "$records_root/.cup-build/package-root/tool-1.0-linux-x64-linux-x64"
printf 'package.tool=tool\n' > "$records_root/.cup-build/package-root/tool-1.0-linux-x64-linux-x64/info.txt"
printf 'format=2\n' > "$records_root/.cup-build/package-root/tool-1.0-linux-x64-linux-x64/manifest.txt"
printf 'release_tag=tool-1.0-linux-x64-linux-x64\npackage_base=tool-1.0-linux-x64-linux-x64\n' > "$records_root/dist/release.env"
printf 'fixture\n' > "$records_root/dist/SHA256SUMS"
CUP_ROOT="$records_root" CUP_COMPONENTS_ROOT="$ROOT" \
    bash "$ROOT/scripts/workflow/build-records.sh" init tool 1.0 linux-x64 linux-x64
CUP_ROOT="$records_root" CUP_COMPONENTS_ROOT="$ROOT" \
    bash "$ROOT/scripts/workflow/build-records.sh" run smoke bash -c 'printf "records-smoke\\n"'
set +e
CUP_ROOT="$records_root" CUP_COMPONENTS_ROOT="$ROOT" \
    bash "$ROOT/scripts/workflow/build-records.sh" run expected-failure bash -c 'printf "expected-failure\\n"; exit 7'
records_status=$?
set -e
[ "$records_status" -eq 7 ] || { echo 'build records did not preserve a failing phase exit code' >&2; exit 1; }
CUP_ROOT="$records_root" CUP_COMPONENTS_ROOT="$ROOT" CUP_WORKFLOW_STATUS=failure \
    bash "$ROOT/scripts/workflow/build-records.sh" finalize
grep -Fx 'phase.smoke=0' "$records_root/.cup-build/build-records/phases.txt" >/dev/null || { echo 'successful phase status missing from build records' >&2; exit 1; }
grep -Fx 'phase.expected-failure=7' "$records_root/.cup-build/build-records/phases.txt" >/dev/null || { echo 'failed phase status missing from build records' >&2; exit 1; }
grep -Fx 'workflow.status=failure' "$records_root/.cup-build/build-records/run.txt" >/dev/null || { echo 'workflow result missing from build records' >&2; exit 1; }
grep -F 'records-smoke' "$records_root/.cup-build/build-records/smoke.log" >/dev/null || { echo 'phase output missing from build records' >&2; exit 1; }
grep -Fx 'repository.tree=unknown' "$records_root/.cup-build/build-records/run.txt" >/dev/null || { echo 'non-git build-record fixture did not record an explicit unknown repository tree' >&2; exit 1; }

records_git="$TMP/build-records-git-fixture"
mkdir -p "$records_git"
git -C "$records_git" init -q
git -C "$records_git" config user.email cup-components@example.invalid
git -C "$records_git" config user.name cup-components
printf 'tree fixture\n' > "$records_git/fixture.txt"
git -C "$records_git" add fixture.txt
git -C "$records_git" commit -q -m fixture
records_commit="$(git -C "$records_git" rev-parse HEAD)"
records_tree="$(git -C "$records_git" rev-parse HEAD^{tree})"
CUP_ROOT="$records_git" CUP_COMPONENTS_ROOT="$records_git" GITHUB_SHA="$records_commit" \
    bash "$ROOT/scripts/workflow/build-records.sh" init tool 1.0 linux-x64 linux-x64
grep -Fx "repository.commit=$records_commit" "$records_git/.cup-build/build-records/run.txt" >/dev/null || { echo 'repository commit missing from git-backed build records' >&2; exit 1; }
grep -Fx "repository.tree=$records_tree" "$records_git/.cup-build/build-records/run.txt" >/dev/null || { echo 'repository tree missing from git-backed build records' >&2; exit 1; }
[ -f "$records_root/.cup-build/build-records/package/tool-1.0-linux-x64-linux-x64/info.txt" ] || { echo 'package info missing from build records' >&2; exit 1; }
[ -f "$records_root/.cup-build/build-records/package/tool-1.0-linux-x64-linux-x64/manifest.txt" ] || { echo 'package manifest missing from build records' >&2; exit 1; }

gcc_records_root="$TMP/gcc-records-fixture"
mkdir -p "$gcc_records_root"
CUP_ROOT="$gcc_records_root" CUP_COMPONENTS_ROOT="$ROOT" \
    CUP_GCC_BINUTILS_VERSION=8.7.6 \
    CUP_BINUTILS_SOURCE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    CUP_GCC_MINGW_VERSION=5.4.3 \
    CUP_MINGW_SOURCE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    CUP_GCC_REVISION=7 \
    bash "$ROOT/scripts/workflow/build-records.sh" init gcc 9.8.7 linux-x64 windows-x64
gcc_run="$gcc_records_root/.cup-build/build-records/run.txt"
grep -Fx 'gcc.binutils.version.requested=8.7.6' "$gcc_run" >/dev/null || { echo 'requested GCC Binutils version missing from build records' >&2; exit 1; }
grep -Fx 'gcc.binutils.source.sha256.requested=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$gcc_run" >/dev/null || { echo 'requested GCC Binutils digest missing from build records' >&2; exit 1; }
grep -Fx 'gcc.mingw-w64.version.requested=5.4.3' "$gcc_run" >/dev/null || { echo 'requested GCC MinGW-w64 version missing from build records' >&2; exit 1; }
grep -Fx 'gcc.mingw-w64.source.sha256.requested=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$gcc_run" >/dev/null || { echo 'requested GCC MinGW-w64 digest missing from build records' >&2; exit 1; }
grep -Fx 'gcc.revision.requested=7' "$gcc_run" >/dev/null || { echo 'requested GCC revision missing from build records' >&2; exit 1; }
printf 'workflow build-records tests passed\n'
