#!/usr/bin/env bash
set -euo pipefail

ROOT="${CUP_COMPONENTS_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
CUP_ROOT="${CUP_ROOT:-$ROOT}"
CUP_WORK_DIR="${CUP_WORK_DIR:-$CUP_ROOT/.cup-build}"
CUP_BUILD_DIR="${CUP_BUILD_DIR:-$CUP_WORK_DIR/build}"
CUP_STAGE_DIR="${CUP_STAGE_DIR:-$CUP_WORK_DIR/stage}"
CUP_OUT_DIR="${CUP_OUT_DIR:-$CUP_ROOT/dist}"
RECORDS_DIR="${CUP_BUILD_RECORDS_DIR:-$CUP_WORK_DIR/build-records}"

usage() {
    cat >&2 <<'USAGE'
Usage:
  build-records.sh init <tool> <requested_version> <host_platform> <target_platform>
  build-records.sh run <phase> <command> [args...]
  build-records.sh finalize
USAGE
    exit 2
}

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

phase_is_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf '%s\n' '-'
    fi
}

command_first_line() {
    local command="$1"
    shift
    if command -v "$command" >/dev/null 2>&1; then
        "$command" "$@" 2>&1 | sed -n '1p' || true
    fi
}

write_environment() {
    local name="$1"
    local output="$RECORDS_DIR/environment-$name.txt"
    local value

    {
        printf 'captured_at=%s\n' "$(utc_now)"
        printf 'runner_os=%s\n' "${RUNNER_OS:-unknown}"
        printf 'runner_arch=%s\n' "${RUNNER_ARCH:-unknown}"
        printf 'build_environment=%s\n' "${CUP_BUILD_ENVIRONMENT:-unknown}"
        printf 'shell=%s\n' "${SHELL:-unknown}"
        value="$(uname -a 2>/dev/null || true)"; printf 'uname=%s\n' "${value:-unavailable}"
        value="$(command_first_line bash --version)"; printf 'bash=%s\n' "${value:-unavailable}"
        value="$(command_first_line make --version)"; printf 'make=%s\n' "${value:-unavailable}"
        value="$(command_first_line cmake --version)"; printf 'cmake=%s\n' "${value:-unavailable}"
        value="$(command_first_line ninja --version)"; printf 'ninja=%s\n' "${value:-unavailable}"
        value="$(command_first_line gcc --version)"; printf 'gcc=%s\n' "${value:-unavailable}"
        value="$(command_first_line clang --version)"; printf 'clang=%s\n' "${value:-unavailable}"
        value="$(command_first_line ld --version)"; printf 'ld=%s\n' "${value:-unavailable}"
        value="$(command_first_line python3 --version)"; printf 'python3=%s\n' "${value:-unavailable}"
        value="$(command_first_line pwsh --version)"; printf 'pwsh=%s\n' "${value:-unavailable}"
    } > "$output"
}

init_records() {
    [ "$#" -eq 4 ] || usage
    local tool="$1"
    local requested_version="$2"
    local host_platform="$3"
    local target_platform="$4"
    local commit="${GITHUB_SHA:-}"

    rm -rf "$RECORDS_DIR"
    mkdir -p "$RECORDS_DIR"
    if [ -z "$commit" ] && command -v git >/dev/null 2>&1; then
        commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
    fi

    {
        printf 'format=1\n'
        printf 'tool=%s\n' "$tool"
        printf 'version.requested=%s\n' "$requested_version"
        printf 'platform.host=%s\n' "$host_platform"
        printf 'platform.target=%s\n' "$target_platform"
        printf 'source.sha256.requested=%s\n' "${CUP_SOURCE_SHA256:-}"
        if [ "$tool" = gcc ]; then
            printf 'gcc.binutils.version.requested=%s\n' "${CUP_GCC_BINUTILS_VERSION:-stable}"
            printf 'gcc.binutils.source.sha256.requested=%s\n' "${CUP_BINUTILS_SOURCE_SHA256:-}"
            printf 'gcc.mingw-w64.version.requested=%s\n' "${CUP_GCC_MINGW_VERSION:-stable}"
            printf 'gcc.mingw-w64.source.sha256.requested=%s\n' "${CUP_MINGW_SOURCE_SHA256:-}"
            printf 'gcc.revision.requested=%s\n' "${CUP_GCC_REVISION:-stable}"
        fi
        printf 'repository.commit=%s\n' "${commit:-unknown}"
        printf 'github.workflow=%s\n' "${GITHUB_WORKFLOW:-local}"
        printf 'github.run_id=%s\n' "${GITHUB_RUN_ID:-local}"
        printf 'github.run_attempt=%s\n' "${GITHUB_RUN_ATTEMPT:-1}"
        printf 'github.ref=%s\n' "${GITHUB_REF:-local}"
        printf 'started_at=%s\n' "$(utc_now)"
    } > "$RECORDS_DIR/run.txt"
    : > "$RECORDS_DIR/phases.txt"
    write_environment host
}

run_phase() {
    [ "$#" -ge 2 ] || usage
    local phase="$1"
    shift
    phase_is_valid "$phase" || { echo "invalid build record phase: $phase" >&2; exit 2; }
    mkdir -p "$RECORDS_DIR"
    write_environment "$phase"

    {
        printf 'phase=%s\n' "$phase"
        printf 'started_at=%s\n' "$(utc_now)"
        printf 'command='
        printf '%q ' "$@"
        printf '\n'
    } > "$RECORDS_DIR/$phase.meta"

    set +e
    "$@" 2>&1 | tee "$RECORDS_DIR/$phase.log"
    local status="${PIPESTATUS[0]}"
    set -e

    {
        printf 'exit_code=%s\n' "$status"
        printf 'finished_at=%s\n' "$(utc_now)"
    } >> "$RECORDS_DIR/$phase.meta"
    printf 'phase.%s=%s\n' "$phase" "$status" >> "$RECORDS_DIR/phases.txt"
    return "$status"
}

copy_if_present() {
    local source="$1"
    local destination="$2"
    [ -f "$source" ] || return 0
    mkdir -p "$(dirname "$destination")"
    cp "$source" "$destination"
}

collect_package_metadata() {
    local root="$CUP_WORK_DIR/package-root"
    local info package package_dir
    [ -d "$root" ] || return 0

    while IFS= read -r -d '' info; do
        package_dir="$(dirname "$info")"
        package="$(basename "$package_dir")"
        copy_if_present "$info" "$RECORDS_DIR/package/$package/info.txt"
        copy_if_present "$package_dir/manifest.txt" "$RECORDS_DIR/package/$package/manifest.txt"
    done < <(find "$root" -type f -name info.txt -print0)
}

collect_build_diagnostics() {
    local file relative destination
    [ -d "$CUP_BUILD_DIR" ] || return 0

    while IFS= read -r -d '' file; do
        relative="${file#"$CUP_WORK_DIR"/}"
        destination="$RECORDS_DIR/diagnostics/$relative"
        mkdir -p "$(dirname "$destination")"
        cp "$file" "$destination"
    done < <(find "$CUP_BUILD_DIR" -type f \( \
        -name config.log -o \
        -name CMakeCache.txt -o \
        -name CMakeConfigureLog.yaml -o \
        -name CMakeError.log -o \
        -name CMakeOutput.log \
    \) -print0)
}

write_output_inventory() {
    local file relative digest bytes
    : > "$RECORDS_DIR/outputs.txt"
    [ -d "$CUP_OUT_DIR" ] || return 0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        relative="${file#"$CUP_OUT_DIR"/}"
        digest="$(file_sha256 "$file")"
        bytes="$(wc -c < "$file" | tr -d '[:space:]')"
        printf '%s\t%s\t%s\n' "$digest" "$bytes" "$relative" >> "$RECORDS_DIR/outputs.txt"
    done < <(find "$CUP_OUT_DIR" -type f -print | LC_ALL=C sort)
}

write_staging_inventory() {
    [ -d "$CUP_STAGE_DIR" ] || return 0
    find "$CUP_STAGE_DIR" -mindepth 1 -print | LC_ALL=C sort > "$RECORDS_DIR/staging-paths.txt"
}

finalize_records() {
    mkdir -p "$RECORDS_DIR"
    {
        printf 'workflow.status=%s\n' "${CUP_WORKFLOW_STATUS:-unknown}"
        printf 'finished_at=%s\n' "$(utc_now)"
    } >> "$RECORDS_DIR/run.txt"

    copy_if_present "$CUP_OUT_DIR/release.env" "$RECORDS_DIR/release.env"
    copy_if_present "$CUP_OUT_DIR/SHA256SUMS" "$RECORDS_DIR/SHA256SUMS"
    collect_package_metadata
    collect_build_diagnostics
    write_output_inventory
    write_staging_inventory
}

[ "$#" -ge 1 ] || usage
command_name="$1"
shift
case "$command_name" in
    init) init_records "$@" ;;
    run) run_phase "$@" ;;
    finalize) [ "$#" -eq 0 ] || usage; finalize_records ;;
    *) usage ;;
esac
