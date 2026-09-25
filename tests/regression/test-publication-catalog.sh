#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PUBLISH_PACKAGE="$ROOT/scripts/publish/publish-package.sh"
CATALOG_TOOL="$ROOT/scripts/catalog/catalog.sh"
PUBLISH_CATALOG="$ROOT/scripts/publish/publish-catalog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REMOTE="$TMP/remote"
BIN="$TMP/bin"
REPO=owner/repo
TARGET_SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$REMOTE/releases" "$BIN"

cat > "$BIN/git" <<'EOF_GIT'
#!/usr/bin/env bash
if [ "${1:-}" = ls-remote ]; then
    exit 2
fi
exec /usr/bin/git "$@"
EOF_GIT
chmod 0755 "$BIN/git"

cat > "$BIN/gh" <<'EOF_GH'
#!/usr/bin/env bash
set -euo pipefail
remote="${GH_FIXTURE_REMOTE:?}"
sha_file() { sha256sum < "$1" | awk '{print $1}'; }
release_dir() { printf '%s/releases/%s\n' "$remote" "$1"; }
release_by_id() {
    local wanted="$1" dir
    for dir in "$remote"/releases/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/id" ] || continue
        [ "$(cat "$dir/id")" = "$wanted" ] && { printf '%s\n' "$dir"; return 0; }
    done
    return 1
}
asset_table() {
    local dir="$1" mode="$2" name digest
    [ -d "$dir/assets" ] || return 0
    while IFS= read -r -d '' file; do
        name="${file##*/}"
        digest="sha256:$(sha_file "$file")"
        if [ "$mode" = with-id ]; then printf '%s\t%s\t%s\n' "$name" "$name" "$digest"
        else printf '%s\t%s\n' "$name" "$digest"
        fi
    done < <(find "$dir/assets" -maxdepth 1 -type f -print0 | sort -z)
}
next_release_id() {
    local max=0 dir id
    for dir in "$remote"/releases/*; do
        [ -f "$dir/id" ] || continue
        id="$(cat "$dir/id")"
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [ "$id" -gt "$max" ] && max="$id"
    done
    printf '%s\n' $((max + 1))
}

case "${1:-}" in
api)
    shift
    method=GET
    include=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --include) include=1; shift ;;
            --paginate) shift ;;
            --method) method="$2"; shift 2 ;;
            --*) break ;;
            *) break ;;
        esac
    done
    endpoint="${1:-}"; shift || true
    jq_expr=""
    new_name=""
    draft_value=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --jq) jq_expr="$2"; shift 2 ;;
            -f|-F)
                case "$2" in
                    name=*) new_name="${2#name=}" ;;
                    draft=*) draft_value="${2#draft=}" ;;
                esac
                shift 2
                ;;
            *) shift ;;
        esac
    done

    if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/releases\?per_page=100$ ]]; then
        wanted=""
        if [[ "$jq_expr" =~ select\(\.tag_name\ ==\ \"([^\"]+)\"\) ]]; then
            wanted="${BASH_REMATCH[1]}"
        fi
        [ -n "$wanted" ] || { echo "unsupported release-list jq: $jq_expr" >&2; exit 64; }
        dir="$(release_dir "$wanted")"
        if [ -d "$dir" ]; then
            printf '%s\t%s\t%s\n' "$(cat "$dir/id")" "$(cat "$dir/draft")" "$(cat "$dir/target")"
        fi
        exit 0
    fi

    if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/releases/tags/(.+)$ ]]; then
        tag="${BASH_REMATCH[1]}"; dir="$(release_dir "$tag")"
        # GitHub's release-by-tag endpoint exposes published releases, not drafts.
        if [ ! -d "$dir" ] || [ "$(cat "$dir/draft")" = true ]; then
            [ "$include" -eq 0 ] || printf 'HTTP/2.0 404 Not Found\n\n{}\n'
            exit 1
        fi
        if [ "$include" -eq 1 ]; then printf 'HTTP/2.0 200 OK\n\n{}\n'; exit 0; fi
        case "$jq_expr" in
            .draft) cat "$dir/draft" ;;
            .target_commitish) cat "$dir/target" ;;
            '.assets[] | [.name,.digest] | @tsv') asset_table "$dir" no-id ;;
            '.assets[] | [.name,(.id|tostring),.digest] | @tsv') asset_table "$dir" with-id ;;
            '') printf '{}\n' ;;
            *) echo "unsupported gh fixture jq: $jq_expr" >&2; exit 64 ;;
        esac
        exit 0
    fi

    if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/releases/([0-9]+)$ ]]; then
        id="${BASH_REMATCH[1]}"
        dir="$(release_by_id "$id" || true)"
        [ -n "$dir" ] || exit 1
        case "$method" in
            GET)
                case "$jq_expr" in
                    '.assets[] | [.name,.digest] | @tsv') asset_table "$dir" no-id ;;
                    '') printf '{}\n' ;;
                    *) echo "unsupported release-id jq: $jq_expr" >&2; exit 64 ;;
                esac
                ;;
            PATCH)
                [ -z "$draft_value" ] || printf '%s\n' "$draft_value" > "$dir/draft"
                ;;
            DELETE) rm -rf "$dir" ;;
            *) exit 64 ;;
        esac
        exit 0
    fi

    if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/releases/assets/(.+)$ ]]; then
        id="${BASH_REMATCH[1]}"
        found=""
        while IFS= read -r -d '' file; do
            [ "${file##*/}" = "$id" ] && { found="$file"; break; }
        done < <(find "$remote/releases" -path '*/assets/*' -type f -print0)
        [ -n "$found" ] || exit 1
        case "$method" in
            DELETE) rm -f "$found" ;;
            PATCH) [ -n "$new_name" ] || exit 64; mv "$found" "$(dirname "$found")/$new_name" ;;
            *) exit 64 ;;
        esac
        exit 0
    fi
    echo "unsupported gh fixture api endpoint: $endpoint" >&2
    exit 64
    ;;
release)
    action="${2:-}"; tag="${3:-}"; shift 3
    dir="$(release_dir "$tag")"
    case "$action" in
        create)
            mkdir -p "$dir/assets"
            [ -f "$dir/id" ] || next_release_id > "$dir/id"
            draft=false; target=""
            assets=()
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --repo|--title|--notes) shift 2 ;;
                    --target) target="$2"; shift 2 ;;
                    --draft) draft=true; shift ;;
                    --latest=false) shift ;;
                    --*) echo "unsupported release create option: $1" >&2; exit 64 ;;
                    *) assets+=("$1"); shift ;;
                esac
            done
            printf '%s\n' "$draft" > "$dir/draft"
            printf '%s\n' "$target" > "$dir/target"
            for file in "${assets[@]}"; do cp "$file" "$dir/assets/$(basename "$file")"; done
            ;;
        edit)
            [ -d "$dir" ] || exit 1
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --repo) shift 2 ;;
                    --draft=false) printf 'false\n' > "$dir/draft"; shift ;;
                    --latest=false) shift ;;
                    *) shift ;;
                esac
            done
            ;;
        delete) rm -rf "$dir" ;;
        download)
            [ -d "$dir" ] || exit 1
            pattern=""; out=""
            while [ "$#" -gt 0 ]; do
                case "$1" in --repo) shift 2;; --pattern) pattern="$2"; shift 2;; --dir) out="$2"; shift 2;; *) shift;; esac
            done
            mkdir -p "$out"; cp "$dir/assets/$pattern" "$out/$pattern"
            ;;
        upload)
            [ -d "$dir" ] || exit 1
            file="$1"; shift
            cp "$file" "$dir/assets/$(basename "$file")"
            ;;
        *) echo "unsupported gh fixture release action: $action" >&2; exit 64 ;;
    esac
    ;;
*) echo "unsupported gh fixture command: $*" >&2; exit 64 ;;
esac
EOF_GH
chmod 0755 "$BIN/gh"

export GH_FIXTURE_REMOTE="$REMOTE"
export PATH="$BIN:$PATH"

make_dist() {
    local version="$1" reason="$2" seed="$3"
    local dir="$TMP/dist-$seed"
    local base="clang-$version-linux-x64-linux-x64" format sha i=0
    mkdir -p "$dir"
    for format in tar.xz tar.gz zip; do
        printf '%s-%s\n' "$seed" "$format" > "$dir/$base.$format"
    done
    {
        printf 'format=1\n'
        printf 'package.component=compiler\n'
        printf 'package.tool=clang\n'
        printf 'package.version=%s\n' "$version"
        [ -z "$reason" ] || printf 'package.revision_reason=%s\n' "$reason"
        printf 'platform.host=linux-x64\n'
        printf 'platform.target=linux-x64\n'
        printf 'manifest_sha256=%064d\n' 0
        for format in tar.xz tar.gz zip; do
            sha="$(sha256sum < "$dir/$base.$format" | awk '{print $1}')"
            printf 'artifact.%s.format=%s\n' "$i" "$format"
            printf 'artifact.%s.sha256=%s\n' "$i" "$sha"
            i=$((i + 1))
        done
    } > "$dir/publication.txt"
    printf '%s\n' "$dir"
}

catalog="$TMP/catalog.cfg"
bash "$CATALOG_TOOL" init "$catalog" "$REPO"
bash "$PUBLISH_CATALOG" bootstrap "$REPO" "$catalog"
[ -f "$REMOTE/releases/catalog/assets/catalog.cfg" ] || { echo 'catalog bootstrap did not publish catalog.cfg' >&2; exit 1; }
cmp -s "$catalog" "$REMOTE/releases/catalog/assets/catalog.cfg" || { echo 'catalog bootstrap changed source bytes' >&2; exit 1; }

versions=(1.2-rev99 1.2.0 9.10 10.0 10.0-rev9 10.0-rev10 10.1 10.2 10.3 10.4 10.5)
reasons=('Packaging revision ninety-nine' '' '' '' 'Packaging revision nine' 'Packaging revision ten' '' '' '' '' '')
for i in "${!versions[@]}"; do
    version="${versions[$i]}"; reason="${reasons[$i]}"
    seed="v$i"
    # A backslash in the working path reproduces the GNU sha256sum output form
    # encountered by Git Bash for Windows paths. Package digests must depend only
    # on file bytes, never on how the path is rendered.
    [ "$i" -ne 0 ] || seed='v0\windows-path'
    dist="$(make_dist "$version" "$reason" "$seed")"
    tag="pkg-clang-$version-linux-x64-linux-x64"
    if [ "$i" -eq 0 ]; then
        # A failed previous run can leave an unpublished draft targeting an older
        # commit. Retry must discard that draft before publishing this identity.
        gh release create "$tag" --repo "$REPO" \
            --target 1111111111111111111111111111111111111111 \
            --title "$tag" --notes 'stale draft fixture' --draft --latest=false >/dev/null
    fi
    bash "$PUBLISH_PACKAGE" "$REPO" "$TARGET_SHA" "$dist"
    if [ "$i" -eq 0 ]; then
        bash "$PUBLISH_PACKAGE" "$REPO" "$TARGET_SHA" "$dist" >/dev/null
    fi
    bash "$CATALOG_TOOL" activate "$catalog" "$REPO" "$tag"
done

[ "$(awk -F= '$1=="revision"{print $2}' "$catalog")" = 11 ] || { echo 'catalog revision did not advance once per semantic activation' >&2; exit 1; }
mapfile -t ordered < <(awk -F= '/^package\.[0-9]+\.version=/{print $2}' "$catalog")
expected=(1.2-rev99 1.2.0 9.10 10.0 10.0-rev9 10.0-rev10 10.1 10.2 10.3 10.4 10.5)
[ "${ordered[*]}" = "${expected[*]}" ] || { printf 'semantic catalog order is wrong: %s\n' "${ordered[*]}" >&2; exit 1; }
[ "$(grep -c '=true$' "$catalog")" -eq 1 ] || { echo 'catalog does not have exactly one stable record for the scope' >&2; exit 1; }
grep -A5 -F 'package.10.version=10.5' "$catalog" | grep -Fx 'package.10.stable=true' >/dev/null || { echo 'semantic maximum is not stable' >&2; exit 1; }
grep -F 'package.0.revision_reason=Packaging revision ninety-nine' "$catalog" >/dev/null || { echo 'revision reason was not propagated into catalog' >&2; exit 1; }

# Re-activating an identical immutable package is a no-op.
before="$(sha256sum "$catalog" | awk '{print $1}')"
bash "$CATALOG_TOOL" activate "$catalog" "$REPO" pkg-clang-10.5-linux-x64-linux-x64
after="$(sha256sum "$catalog" | awk '{print $1}')"
[ "$before" = "$after" ] || { echo 'idempotent activation changed catalog bytes' >&2; exit 1; }

# The release target is original publication provenance, not package identity.
# Exact published bytes remain reusable from a later repository commit.
identity_tag=pkg-clang-10.5-linux-x64-linux-x64
printf '%s\n' 1111111111111111111111111111111111111111 > "$REMOTE/releases/$identity_tag/target"
identity_dist="$(make_dist 10.5 '' v10)"
bash "$PUBLISH_PACKAGE" "$REPO" "$TARGET_SHA" "$identity_dist" >/dev/null
[ "$(cat "$REMOTE/releases/$identity_tag/target")" = 1111111111111111111111111111111111111111 ] || {
    echo 'idempotent publication rewrote original release provenance' >&2
    exit 1
}

# A published package identity cannot be replaced with different bytes.
conflict="$(make_dist 10.5 '' conflict)"
printf 'changed\n' > "$conflict/clang-10.5-linux-x64-linux-x64.zip"
zip_sha="$(sha256sum < "$conflict/clang-10.5-linux-x64-linux-x64.zip" | awk '{print $1}')"
sed -i "s/^artifact.2.sha256=.*/artifact.2.sha256=$zip_sha/" "$conflict/publication.txt"
if bash "$PUBLISH_PACKAGE" "$REPO" "$TARGET_SHA" "$conflict" >/dev/null 2>&1; then
    echo 'same package identity with different immutable data was accepted' >&2
    exit 1
fi

bash "$PUBLISH_CATALOG" sync "$REPO" "$catalog"
cmp -s "$catalog" "$REMOTE/releases/catalog/assets/catalog.cfg" || { echo 'rolling catalog does not match source authority' >&2; exit 1; }

# Lower published revisions are never restored over a newer rolling snapshot.
initial="$TMP/initial.cfg"
printf 'format=1\nrevision=0\nupdate_url=https://github.com/%s/releases/download/catalog/catalog.cfg\n' "$REPO" > "$initial"
if bash "$PUBLISH_CATALOG" sync "$REPO" "$initial" >/dev/null 2>&1; then
    echo 'catalog rollback was accepted' >&2
    exit 1
fi

# Recover the post-delete/pre-rename window from the verified next asset.
mv "$REMOTE/releases/catalog/assets/catalog.cfg" "$REMOTE/releases/catalog/assets/catalog.cfg.next"
bash "$PUBLISH_CATALOG" sync "$REPO" "$catalog"
[ -f "$REMOTE/releases/catalog/assets/catalog.cfg" ] && [ ! -e "$REMOTE/releases/catalog/assets/catalog.cfg.next" ] || {
    echo 'rolling catalog interrupted-rename recovery failed' >&2
    exit 1
}
cmp -s "$catalog" "$REMOTE/releases/catalog/assets/catalog.cfg" || { echo 'recovered rolling catalog bytes differ from source' >&2; exit 1; }

# Manual sync is also the recovery path when the rolling release itself was
# removed. Recreate it from current source authority without rolling back to r0.
rm -rf "$REMOTE/releases/catalog"
bash "$PUBLISH_CATALOG" sync "$REPO" "$catalog"
[ -f "$REMOTE/releases/catalog/assets/catalog.cfg" ] || { echo 'missing catalog release was not recreated' >&2; exit 1; }
cmp -s "$catalog" "$REMOTE/releases/catalog/assets/catalog.cfg" || { echo 'recreated rolling catalog bytes differ from source' >&2; exit 1; }

printf 'PUBLICATION_CATALOG=PASS\n'
