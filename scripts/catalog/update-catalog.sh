#!/usr/bin/env bash
set -euo pipefail

ROOT="${CUP_COMPONENTS_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
CATALOG="$ROOT/catalog/catalog.cfg"
CATALOG_TOOL="$ROOT/scripts/catalog/catalog.sh"
PUBLISH_TOOL="$ROOT/scripts/publish/publish-catalog.sh"

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <repository> <default-branch> <package-tag>" >&2
    exit 2
fi

repo="$1"
branch="$2"
package_tag="$3"

fail() {
    printf '[catalog-update:error] %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail 'git is required'
command -v gh >/dev/null 2>&1 || fail 'gh is required'

# Automatic updates start only after the one-time revision-0 endpoint exists.
# Failing here keeps a missed bootstrap from advancing source authority first.
gh api "repos/$repo/releases/tags/catalog" --jq '.tag_name' >/dev/null 2>&1 ||
    fail 'rolling catalog release is not initialized; publish the revision-0 catalog first'

# Each retry starts from the latest source authority. Activation is idempotent,
# so a push race can be retried without merging stale catalog bytes.
for attempt in 1 2 3; do
    git -C "$ROOT" fetch origin "$branch"
    git -C "$ROOT" reset --hard "origin/$branch"

    before="$(git -C "$ROOT" hash-object "$CATALOG")"
    bash "$CATALOG_TOOL" activate "$CATALOG" "$repo" "$package_tag"
    after="$(git -C "$ROOT" hash-object "$CATALOG")"

    if [ "$before" = "$after" ]; then
        bash "$PUBLISH_TOOL" sync "$repo" "$CATALOG"
        exit 0
    fi

    git -C "$ROOT" add catalog/catalog.cfg
    git -C "$ROOT" commit -m "catalog: activate $package_tag"
    if git -C "$ROOT" push origin "HEAD:$branch"; then
        # Publish only after the source commit succeeds; the rolling endpoint must
        # never advance ahead of repository authority.
        bash "$PUBLISH_TOOL" sync "$repo" "$CATALOG"
        exit 0
    fi

    printf '[catalog-update] push raced with branch update; retrying (%s/3)\n' "$attempt" >&2
done

fail 'catalog update could not advance the default branch after three attempts'
