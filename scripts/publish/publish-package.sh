#!/usr/bin/env bash
set -euo pipefail

ROOT="${CUP_COMPONENTS_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../package/package-common.sh
source "$ROOT/scripts/package/package-common.sh"

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <repository> <target-sha> <dist-dir>" >&2
    exit 2
fi

repo="$1"
target_sha="$2"
dist_dir="$3"
publication="$dist_dir/publication.txt"

fail() {
    printf '[publish:error] %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail 'sha256sum or shasum is required'
    fi
}

single_value() {
    local file="$1" key="$2" count value
    count="$(awk -F= -v key="$key" '$1 == key {n++} END {print n+0}' "$file")"
    [ "$count" -eq 1 ] || fail "$file must contain exactly one '$key' field"
    value="$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file")"
    [ -n "$value" ] || fail "$file contains an empty '$key' field"
    printf '%s\n' "$value"
}

optional_value() {
    local file="$1" key="$2" count
    count="$(awk -F= -v key="$key" '$1 == key {n++} END {print n+0}' "$file")"
    [ "$count" -le 1 ] || fail "$file contains duplicate '$key' fields"
    [ "$count" -eq 1 ] || return 1
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

verify_local_publication() {
    [ -f "$publication" ] || fail 'publication.txt is missing'
    publication_descriptor_validate "$publication"

    component="$(single_value "$publication" package.component)"
    tool="$(single_value "$publication" package.tool)"
    version="$(single_value "$publication" package.version)"
    host="$(single_value "$publication" platform.host)"
    target="$(single_value "$publication" platform.target)"
    manifest_sha="$(single_value "$publication" manifest_sha256)"
    [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid publication manifest SHA-256'

    package_base="$tool-$version-$host-$target"
    tag="pkg-$package_base"
    revision_reason="$(optional_value "$publication" package.revision_reason || true)"

    assets=("$publication")
    managed_names=(publication.txt)
    local expected_format actual_format expected_sha archive actual_sha
    local index=0
    for expected_format in tar.xz tar.gz zip; do
        actual_format="$(single_value "$publication" "artifact.$index.format")"
        [ "$actual_format" = "$expected_format" ] ||
            fail "publication artifact $index must be $expected_format"
        expected_sha="$(single_value "$publication" "artifact.$index.sha256")"
        [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
            fail "invalid SHA-256 for publication artifact $index"
        archive="$dist_dir/$package_base.$expected_format"
        [ -f "$archive" ] || fail "publication artifact is missing: $archive"
        actual_sha="$(sha256_file "$archive")"
        [ "$actual_sha" = "$expected_sha" ] ||
            fail "publication artifact digest mismatch: ${archive##*/}"
        assets+=("$archive")
        managed_names+=("${archive##*/}")
        index=$((index + 1))
    done

    if awk -F= '/^artifact\.[3-9][0-9]*\./ {found=1} END {exit !found}' "$publication"; then
        fail 'publication descriptor declares more than three artifacts'
    fi
}

release_field() {
    local field="$1"
    gh api "repos/$repo/releases/tags/$tag" --jq "$field"
}

verify_remote_release() {
    local table expected_names actual_names name digest expected
    table="$(gh api "repos/$repo/releases/tags/$tag" --jq '.assets[] | [.name,.digest] | @tsv')"
    expected_names="$(printf '%s\n' "${managed_names[@]}" | LC_ALL=C sort)"
    actual_names="$(printf '%s\n' "$table" | cut -f1 | LC_ALL=C sort)"
    [ "$actual_names" = "$expected_names" ] || fail "published release has an unexpected managed asset set: $tag"

    while IFS=$'\t' read -r name digest; do
        [ -n "$name" ] || continue
        case "$name" in
            publication.txt) expected="sha256:$(sha256_file "$publication")" ;;
            *) expected="sha256:$(sha256_file "$dist_dir/$name")" ;;
        esac
        [ "$digest" = "$expected" ] || fail "published asset digest mismatch: $name"
    done <<< "$table"
}

[ -n "$repo" ] || fail 'repository is empty'
[[ "$target_sha" =~ ^[0-9a-fA-F]{40}$ ]] || fail "invalid target commit: $target_sha"
command -v gh >/dev/null 2>&1 || fail 'gh is required'

verify_local_publication

lookup="$(mktemp)"
trap 'rm -f "$lookup"' EXIT
status=0
gh api --include "repos/$repo/releases/tags/$tag" >"$lookup" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then
    draft="$(release_field '.draft')"
    target_commitish="$(release_field '.target_commitish')"
    if [ "$draft" = false ]; then
        # Published identities are immutable: only exact remote data is accepted
        # as idempotent success; mismatches are never repaired in place.
        [ "$target_commitish" = "$target_sha" ] || fail "published release targets a different commit: $tag"
        verify_remote_release
        printf 'package publication already complete: %s\n' "$tag"
        exit 0
    fi

    [ "$target_commitish" = "$target_sha" ] ||
        fail "existing draft targets a different commit: $tag"
    gh release delete "$tag" --repo "$repo" --cleanup-tag --yes
else
    http_status="$(sed -n 's#^HTTP/[^ ]* \([0-9][0-9][0-9]\).*#\1#p' "$lookup" | head -n 1)"
    [ "$http_status" = 404 ] || { cat "$lookup" >&2; exit "$status"; }

    tag_status=0
    git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 || tag_status=$?
    case "$tag_status" in
        0) fail "publication tag exists without a release: $tag" ;;
        2) ;;
        *) fail "failed to determine remote tag state for '$tag'" ;;
    esac
fi

notes="Immutable CUP component package $tool@$version for $host -> $target."
if [ -n "$revision_reason" ]; then
    notes="$notes Revision: $revision_reason"
fi

gh release create "$tag" "${assets[@]}" \
    --repo "$repo" \
    --target "$target_sha" \
    --title "$tag" \
    --notes "$notes" \
    --draft \
    --latest=false

verify_remote_release
gh release edit "$tag" --repo "$repo" --draft=false --latest=false >/dev/null
verify_remote_release
printf 'published package: %s\n' "$tag"
