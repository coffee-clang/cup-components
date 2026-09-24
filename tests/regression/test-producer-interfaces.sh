#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Builders reject unsupported package scopes. The workflow normally prevents these
# inputs, but the builder contract must still not produce an unsupported package.
assert_build_matrix_rejected() {
    local name="$1"
    shift
    local isolated="$TMP/matrix-$name"

    if CUP_ROOT="$isolated" "$@" >/dev/null 2>&1; then
        echo "unsupported producer matrix was accepted: $name" >&2
        exit 1
    fi
}

assert_build_matrix_rejected gcc-macos \
    "$ROOT/scripts/build/build-gcc.sh" default macos-x64 macos-x64
assert_build_matrix_rejected gcc-unsupported-cross \
    "$ROOT/scripts/build/build-gcc.sh" default linux-arm64 windows-x64
assert_build_matrix_rejected ld-macos \
    "$ROOT/scripts/build/build-ld.sh" default macos-x64 macos-x64
assert_build_matrix_rejected ld-unsupported-cross \
    "$ROOT/scripts/build/build-ld.sh" default linux-arm64 windows-x64
assert_build_matrix_rejected gdb-macos \
    "$ROOT/scripts/build/build-gdb.sh" default macos-x64
assert_build_matrix_rejected llvm-unknown-platform \
    "$ROOT/scripts/build/build-llvm-tool.sh" clang default solaris-x64
printf 'producer input rejection tests passed\n'

# The MSYS2 setup entry point must resolve its package list from its own location,
# not from the operator's current working directory.
msys_fixture="$TMP/msys2-cwd"
mkdir -p "$msys_fixture/bin" "$msys_fixture/cwd"
cat > "$msys_fixture/bin/pacman" <<'EOF_PACMAN'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$PACMAN_FIXTURE_LOG"
EOF_PACMAN
chmod 0755 "$msys_fixture/bin/pacman"
(
    cd "$msys_fixture/cwd"
    PACMAN_FIXTURE_LOG="$msys_fixture/pacman.log" PATH="$msys_fixture/bin:$PATH" \
        bash "$ROOT/scripts/setup/setup-windows-msys2.sh" ucrt64
)
grep -Fx -- '-S' "$msys_fixture/pacman.log" >/dev/null || { echo 'MSYS2 setup did not reach pacman from external cwd' >&2; exit 1; }
first_ucrt_package="$(grep -v '^[[:space:]]*$' "$ROOT/scripts/setup/msys2-ucrt64-packages.txt" | grep -v '^[[:space:]]*#' | head -n 1)"
grep -Fx -- "$first_ucrt_package" "$msys_fixture/pacman.log" >/dev/null || { echo 'MSYS2 setup did not load its repository-relative package list' >&2; exit 1; }
printf 'MSYS2 arbitrary-cwd setup test passed\n'



# Build records preserve phase results and package provenance independently of
# package payload.
records_root="$TMP/records-fixture"
mkdir -p "$records_root/dist" "$records_root/.cup-build/package-root/tool-1.0-linux-x64-linux-x64"
printf 'package.tool=tool\n' > "$records_root/.cup-build/package-root/tool-1.0-linux-x64-linux-x64/info.txt"
printf 'format=2\n' > "$records_root/.cup-build/package-root/tool-1.0-linux-x64-linux-x64/manifest.txt"
printf 'release_tag=pkg-tool-1.0-linux-x64-linux-x64\npackage_base=tool-1.0-linux-x64-linux-x64\n' > "$records_root/dist/release.env"
printf 'format=1\npackage.component=compiler\npackage.tool=tool\npackage.version=1.0\nplatform.host=linux-x64\nplatform.target=linux-x64\nmanifest_sha256=0000000000000000000000000000000000000000000000000000000000000000\nartifact.0.format=tar.xz\nartifact.0.sha256=1111111111111111111111111111111111111111111111111111111111111111\nartifact.1.format=tar.gz\nartifact.1.sha256=2222222222222222222222222222222222222222222222222222222222222222\nartifact.2.format=zip\nartifact.2.sha256=3333333333333333333333333333333333333333333333333333333333333333\n' > "$records_root/dist/publication.txt"
printf 'digest fixture\n' > "$records_root/dist/path\\fixture.txt"
records_digest="$(sha256sum < "$records_root/dist/path\\fixture.txt" | awk '{print $1}')"
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
grep -F "$records_digest"$'\t' "$records_root/.cup-build/build-records/outputs.txt" | grep -F $'\tpath\\fixture.txt' >/dev/null || {
    echo 'build-record output digest depends on filename escaping' >&2
    exit 1
}
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
    CUP_PACKAGE_REVISION=7 \
    CUP_PACKAGE_REVISION_REASON='Fixture revision' \
    bash "$ROOT/scripts/workflow/build-records.sh" init gcc 9.8.7 linux-x64 windows-x64
gcc_run="$gcc_records_root/.cup-build/build-records/run.txt"
grep -Fx 'gcc.binutils.version.requested=8.7.6' "$gcc_run" >/dev/null || { echo 'requested GCC Binutils version missing from build records' >&2; exit 1; }
grep -Fx 'gcc.binutils.source.sha256.requested=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$gcc_run" >/dev/null || { echo 'requested GCC Binutils digest missing from build records' >&2; exit 1; }
grep -Fx 'gcc.mingw-w64.version.requested=5.4.3' "$gcc_run" >/dev/null || { echo 'requested GCC MinGW-w64 version missing from build records' >&2; exit 1; }
grep -Fx 'gcc.mingw-w64.source.sha256.requested=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$gcc_run" >/dev/null || { echo 'requested GCC MinGW-w64 digest missing from build records' >&2; exit 1; }
grep -Fx 'package.revision.requested=7' "$gcc_run" >/dev/null || { echo 'requested package revision missing from build records' >&2; exit 1; }
grep -Fx 'package.revision_reason.requested=Fixture revision' "$gcc_run" >/dev/null || { echo 'requested package revision reason missing from build records' >&2; exit 1; }
printf 'PRODUCER_INTERFACES=PASS\n'
