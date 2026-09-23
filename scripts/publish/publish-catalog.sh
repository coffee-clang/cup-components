#!/usr/bin/env bash
set -euo pipefail

ROOT="${CUP_COMPONENTS_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
CATALOG_TOOL="$ROOT/scripts/catalog/catalog.sh"

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <bootstrap|sync> <repository> <catalog>" >&2
    exit 2
fi

mode="$1"
repo="$2"
catalog="$3"
tag=catalog

fail() {
    printf '[catalog-publish:error] %s\n' "$*" >&2
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
    local file="$1" key="$2"
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

decimal_compare() {
    local a="$1" b="$2"
    if [ "${#a}" -lt "${#b}" ]; then printf '%s\n' -1; return; fi
    if [ "${#a}" -gt "${#b}" ]; then printf '%s\n' 1; return; fi
    if [[ "$a" < "$b" ]]; then printf '%s\n' -1
    elif [[ "$a" > "$b" ]]; then printf '%s\n' 1
    else printf '%s\n' 0
    fi
}

release_exists() {
    gh api "repos/$repo/releases/tags/$tag" >/dev/null 2>&1
}

asset_table() {
    gh api "repos/$repo/releases/tags/$tag" --jq '.assets[] | [.name,(.id|tostring),.digest] | @tsv'
}

asset_field() {
    local name="$1" field="$2"
    case "$field" in
        id) asset_table | awk -F '\t' -v n="$name" '$1==n {print $2; exit}' ;;
        digest) asset_table | awk -F '\t' -v n="$name" '$1==n {print $3; exit}' ;;
        *) fail "unknown asset field: $field" ;;
    esac
}

verify_asset_digest() {
    local name="$1" file="$2" remote expected
    remote="$(asset_field "$name" digest)"
    [ -n "$remote" ] || fail "release asset is missing: $name"
    expected="sha256:$(sha256_file "$file")"
    [ "$remote" = "$expected" ] || fail "release asset digest mismatch: $name"
}

delete_asset() {
    local name="$1" id
    id="$(asset_field "$name" id)"
    [ -n "$id" ] || return 0
    gh api --method DELETE "repos/$repo/releases/assets/$id" >/dev/null
}

rename_asset() {
    local old="$1" new="$2" id
    id="$(asset_field "$old" id)"
    [ -n "$id" ] || fail "release asset is missing: $old"
    gh api --method PATCH "repos/$repo/releases/assets/$id" -f "name=$new" >/dev/null
}

download_asset() {
    local name="$1" dir="$2"
    gh release download "$tag" --repo "$repo" --pattern "$name" --dir "$dir" >/dev/null
    [ -f "$dir/$name" ] || fail "failed to download release asset: $name"
}

validate_catalog() {
    bash "$CATALOG_TOOL" validate "$1" "$repo"
}

command -v gh >/dev/null 2>&1 || fail 'gh is required'
[ -f "$catalog" ] || fail "catalog not found: $catalog"
validate_catalog "$catalog"

case "$mode" in
    bootstrap)
        [ "$(single_value "$catalog" revision)" = 0 ] || fail 'bootstrap requires catalog revision 0'
        ! grep -q '^package\.' "$catalog" || fail 'bootstrap requires an empty catalog'
        if release_exists; then
            [ "$(asset_table | wc -l)" -eq 1 ] || fail 'existing catalog release has an unexpected asset set'
            verify_asset_digest catalog.cfg "$catalog"
            printf 'catalog bootstrap already complete\n'
            exit 0
        fi
        gh release create "$tag" "$catalog" \
            --repo "$repo" \
            --title 'cup package catalog' \
            --notes 'Rolling cup package catalog delivery endpoint.' \
            --latest=false
        verify_asset_digest catalog.cfg "$catalog"
        printf 'published initial catalog revision 0\n'
        ;;

    sync)
        release_exists || fail 'catalog release does not exist; bootstrap revision 0 manually first'
        temp="$(mktemp -d)"
        trap 'rm -rf "$temp"' EXIT

        canonical_id="$(asset_field catalog.cfg id)"
        next_id="$(asset_field catalog.cfg.next id)"
        if [ -n "$canonical_id" ] && [ -n "$next_id" ]; then
            # The canonical asset is still the committed public snapshot; a leftover
            # next asset is only unpublished staging and can be discarded.
            delete_asset catalog.cfg.next
            next_id=""
        elif [ -z "$canonical_id" ] && [ -n "$next_id" ]; then
            # Canonical deletion already crossed the commit window. Finish the
            # previously verified rename before considering a newer candidate.
            download_asset catalog.cfg.next "$temp"
            validate_catalog "$temp/catalog.cfg.next"
            verify_asset_digest catalog.cfg.next "$temp/catalog.cfg.next"
            rename_asset catalog.cfg.next catalog.cfg
            canonical_id="$(asset_field catalog.cfg id)"
            [ -n "$canonical_id" ] || fail 'failed to recover canonical catalog asset'
        elif [ -z "$canonical_id" ]; then
            fail 'catalog release has neither catalog.cfg nor recoverable catalog.cfg.next'
        fi

        rm -f "$temp/catalog.cfg"
        download_asset catalog.cfg "$temp"
        validate_catalog "$temp/catalog.cfg"
        verify_asset_digest catalog.cfg "$temp/catalog.cfg"

        published_revision="$(single_value "$temp/catalog.cfg" revision)"
        candidate_revision="$(single_value "$catalog" revision)"
        cmp_revision="$(decimal_compare "$candidate_revision" "$published_revision")"
        case "$cmp_revision" in
            -1) fail "catalog rollback refused: published=$published_revision candidate=$candidate_revision" ;;
            0)
                cmp -s "$catalog" "$temp/catalog.cfg" || fail 'same catalog revision has different bytes'
                printf 'catalog release already matches revision %s\n' "$candidate_revision"
                exit 0
                ;;
            1) ;;
            *) fail 'internal revision comparison failure' ;;
        esac

        bash "$CATALOG_TOOL" transition "$temp/catalog.cfg" "$catalog" "$repo"

        cp "$catalog" "$temp/catalog.cfg.next"
        delete_asset catalog.cfg.next
        gh release upload "$tag" "$temp/catalog.cfg.next" --repo "$repo"
        verify_asset_digest catalog.cfg.next "$temp/catalog.cfg.next"
        delete_asset catalog.cfg
        rename_asset catalog.cfg.next catalog.cfg
        verify_asset_digest catalog.cfg "$catalog"
        printf 'published catalog revision %s\n' "$candidate_revision"
        ;;

    *) fail "unknown mode: $mode" ;;
esac
