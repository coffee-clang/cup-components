#!/usr/bin/env bash
set -euo pipefail

ROOT="${CUP_COMPONENTS_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../package/package-common.sh
source "$ROOT/scripts/package/package-common.sh"

CATALOG_MAX_BYTES=$((4 * 1024 * 1024))
UINT64_MAX=18446744073709551615

fail() {
    printf '[catalog:error] %s\n' "$*" >&2
    exit 1
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

uint64_is_valid() {
    local value="$1"
    [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    if [ "${#value}" -lt "${#UINT64_MAX}" ]; then
        return 0
    fi
    if [ "${#value}" -gt "${#UINT64_MAX}" ]; then
        return 1
    fi
    [[ "$value" < "$UINT64_MAX" || "$value" = "$UINT64_MAX" ]]
}

uint64_increment() {
    local value="$1" carry=1 out="" digit i sum
    uint64_is_valid "$value" || fail "invalid catalog revision: $value"
    [ "$value" != "$UINT64_MAX" ] || fail 'catalog revision overflow'
    for ((i=${#value}-1; i>=0; i--)); do
        digit=${value:i:1}
        sum=$((digit + carry))
        if [ "$sum" -ge 10 ]; then
            out="$((sum - 10))$out"
            carry=1
        else
            out="$sum$out"
            carry=0
        fi
    done
    [ "$carry" -eq 0 ] || out="1$out"
    printf '%s\n' "$out"
}

catalog_update_url() {
    local repo="$1"
    printf 'https://github.com/%s/releases/download/catalog/catalog.cfg\n' "$repo"
}

package_release_url() {
    local repo="$1" tag="$2" name="$3"
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$repo" "$tag" "$name"
}

known_package_scope() {
    local component="$1" tool="$2" host="$3" target="$4"
    [ "$(package_component_for_tool "$tool" 2>/dev/null || true)" = "$component" ] || return 1
    package_scope_is_supported "$tool" "$host" "$target"
}

catalog_header() {
    local file="$1" repo="$2" bytes expected_url
    [ -f "$file" ] || fail "catalog not found: $file"
    bytes="$(wc -c < "$file")"
    [ "$bytes" -le "$CATALOG_MAX_BYTES" ] || fail "catalog exceeds $CATALOG_MAX_BYTES bytes"
    CATALOG_FORMAT="$(single_value "$file" format)"
    CATALOG_REVISION="$(single_value "$file" revision)"
    CATALOG_UPDATE_URL="$(single_value "$file" update_url)"
    [ "$CATALOG_FORMAT" = 1 ] || fail "unsupported catalog format: $CATALOG_FORMAT"
    uint64_is_valid "$CATALOG_REVISION" || fail "invalid catalog revision: $CATALOG_REVISION"
    expected_url="$(catalog_update_url "$repo")"
    [ "$CATALOG_UPDATE_URL" = "$expected_url" ] || fail "catalog update_url must be $expected_url"
}

catalog_to_tsv() {
    local file="$1" output="$2"
    awk -F= '
        function bad(m) { print "catalog parse error: " m > "/dev/stderr"; exit 2 }
        NR <= 3 { next }
        {
            key=$1; sub(/^[^=]*=/, "", $0); value=$0
            if (key !~ /^package\.[0-9]+\./) bad("unknown field " key)
            split(key,p,"."); i=p[2]+0; seen_i[i]=1
            if (p[3] == "artifact") {
                if (p[4] !~ /^[0-9]+$/ || p[5] == "" || p[6] != "") bad("invalid artifact field " key)
                a=p[4]+0; f=p[5]
                if (f != "format" && f != "url" && f != "sha256") bad("unknown artifact field " key)
                if ((i SUBSEP a SUBSEP f) in av) bad("duplicate field " key)
                av[i,a,f]=value; seen_a[i,a]=1; next
            }
            if (p[4] != "") bad("invalid package field " key)
            f=p[3]
            if (f != "component" && f != "tool" && f != "host" && f != "target" &&
                f != "version" && f != "stable" && f != "revision_reason") bad("unknown package field " key)
            if ((i SUBSEP f) in v) bad("duplicate field " key)
            v[i,f]=value
        }
        END {
            if (NR < 3) bad("missing header")
            n=0; max=-1
            for (i in seen_i) { idx=i+0; if (idx > max) max=idx; n++ }
            if (n == 0) exit 0
            if (n != max+1) bad("package indices must be contiguous from 0")
            for (i=0; i<n; i++) {
                req[1]="component"; req[2]="tool"; req[3]="host"; req[4]="target"; req[5]="version"; req[6]="stable"
                for (r=1; r<=6; r++) if (!((i SUBSEP req[r]) in v) || v[i,req[r]] == "") bad("missing package." i "." req[r])
                for (a=0; a<3; a++) {
                    if (!((i SUBSEP a) in seen_a)) bad("missing artifact index for package " i)
                    for (r=1; r<=3; r++) { afield[r]=(r==1?"format":(r==2?"url":"sha256")); if (!((i SUBSEP a SUBSEP afield[r]) in av) || av[i,a,afield[r]] == "") bad("missing artifact field") }
                }
                for (k in seen_a) { split(k,z,SUBSEP); if (z[1]==i && z[2]>2) bad("artifact indices must be 0..2") }
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s", v[i,"component"],v[i,"tool"],v[i,"host"],v[i,"target"],v[i,"version"],v[i,"revision_reason"],v[i,"stable"]
                for (a=0; a<3; a++) printf "\t%s\t%s\t%s",av[i,a,"format"],av[i,a,"url"],av[i,a,"sha256"]
                printf "\n"
            }
        }
    ' "$file" > "$output" || fail 'catalog parse failed'
}

validate_tsv() {
    local tsv="$1" repo="$2"
    local row line=0 component tool host target version reason stable
    local f0 u0 s0 f1 u1 s1 f2 u2 s2 expected_tag expected_base key sha
    local seen fields
    seen="$(mktemp)"
    trap 'rm -f "$seen"' RETURN
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        line=$((line + 1))
        mapfile -t fields < <(printf '%s\n' "$row" | awk -F '\t' '{for(i=1;i<=16;i++) print $i}')
        [ "${#fields[@]}" -eq 16 ] || fail "invalid internal catalog row $line"
        component="${fields[0]}"; tool="${fields[1]}"; host="${fields[2]}"; target="${fields[3]}"
        version="${fields[4]}"; reason="${fields[5]}"; stable="${fields[6]}"
        f0="${fields[7]}"; u0="${fields[8]}"; s0="${fields[9]}"
        f1="${fields[10]}"; u1="${fields[11]}"; s1="${fields[12]}"
        f2="${fields[13]}"; u2="${fields[14]}"; s2="${fields[15]}"

        known_package_scope "$component" "$tool" "$host" "$target" || fail "unsupported package scope on row $line"
        package_version_is_valid "$version" || fail "invalid package version on row $line: $version"
        if package_version_has_revision "$version"; then
            package_revision_reason_is_valid "$reason" || fail "revision-bearing package lacks a valid reason on row $line"
        else
            [ -z "$reason" ] || fail "revisionless package has a revision reason on row $line"
        fi
        case "$stable" in true|false) ;; *) fail "invalid stable value on row $line" ;; esac
        [ "$f0" = tar.xz ] && [ "$f1" = tar.gz ] && [ "$f2" = zip ] || fail "artifact formats are not canonical on row $line"
        for sha in "$s0" "$s1" "$s2"; do [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "invalid artifact SHA-256 on row $line"; done
        expected_base="$tool-$version-$host-$target"
        expected_tag="pkg-$expected_base"
        [ "$u0" = "$(package_release_url "$repo" "$expected_tag" "$expected_base.tar.xz")" ] || fail "noncanonical tar.xz URL on row $line"
        [ "$u1" = "$(package_release_url "$repo" "$expected_tag" "$expected_base.tar.gz")" ] || fail "noncanonical tar.gz URL on row $line"
        [ "$u2" = "$(package_release_url "$repo" "$expected_tag" "$expected_base.zip")" ] || fail "noncanonical zip URL on row $line"
        key="$component"$'\t'"$tool"$'\t'"$host"$'\t'"$target"$'\t'"$version"
        if grep -Fx -- "$key" "$seen" >/dev/null 2>&1; then fail "duplicate package identity on row $line"; fi
        printf '%s\n' "$key" >> "$seen"
    done < "$tsv"
    rm -f "$seen"; trap - RETURN
}

canonicalize_tsv() {
    local input="$1" output="$2"
    awk -F '\t' 'BEGIN{OFS="\t"}
        function numkey(n, l) { l=length(n); return sprintf("%010d:%s",l,n) }
        function vkey(v, base,rev,n,a,i,k) {
            rev="0"; base=v
            if (match(v,/-rev[1-9][0-9]*$/)) { rev=substr(v,RSTART+4); base=substr(v,1,RSTART-1) }
            n=split(base,a,"."); k=""
            for(i=1;i<=n;i++) { if(i>1) k=k "~"; k=k numkey(a[i]) }
            return k "!" numkey(rev)
        }
        { print $1 "|" $2 "|" $3 "|" $4 "|" vkey($5), $0 }
    ' "$input" | LC_ALL=C sort -t $'\t' -k1,1 | cut -f2- > "$output.sorted"

    awk -F '\t' 'BEGIN{OFS="\t"}
        { rows[NR]=$0; scope[NR]=$1 FS $2 FS $3 FS $4 }
        END {
            for(i=1;i<=NR;i++) {
                split(rows[i],f,FS)
                f[7]=(i==NR || scope[i]!=scope[i+1]) ? "true" : "false"
                printf "%s",f[1]; for(j=2;j<=16;j++) printf OFS "%s",f[j]; printf "\n"
            }
        }
    ' "$output.sorted" > "$output"
    rm -f "$output.sorted"
}

render_catalog() {
    local revision="$1" repo="$2" rows="$3" output="$4"
    local canonical="$output.rows.$$"
    canonicalize_tsv "$rows" "$canonical"
    {
        printf 'format=1\n'
        printf 'revision=%s\n' "$revision"
        printf 'update_url=%s\n' "$(catalog_update_url "$repo")"
        awk -F '\t' 'BEGIN{OFS="="}
            {
                i=NR-1
                print "package."i".component",$1
                print "package."i".tool",$2
                print "package."i".host",$3
                print "package."i".target",$4
                print "package."i".version",$5
                if($6!="") print "package."i".revision_reason",$6
                print "package."i".stable",$7
                c=8
                for(a=0;a<3;a++) {
                    print "package."i".artifact."a".format",$c
                    print "package."i".artifact."a".url",$(c+1)
                    print "package."i".artifact."a".sha256",$(c+2)
                    c+=3
                }
            }
        ' "$canonical"
    } > "$output"
    rm -f "$canonical"
}

validate_catalog() {
    local file="$1" repo="$2" rows canonical
    catalog_header "$file" "$repo"
    rows="$(mktemp)"; canonical="$(mktemp)"
    trap 'rm -f "$rows" "$canonical"' RETURN
    catalog_to_tsv "$file" "$rows"
    validate_tsv "$rows" "$repo"
    render_catalog "$CATALOG_REVISION" "$repo" "$rows" "$canonical"
    cmp -s "$file" "$canonical" || fail 'catalog is structurally valid but not canonical'
    rm -f "$rows" "$canonical"; trap - RETURN
}

release_asset_table() {
    local repo="$1" tag="$2"
    gh api "repos/$repo/releases/tags/$tag" --jq '.assets[] | [.name,.digest] | @tsv'
}

publication_row_from_release() {
    local repo="$1" tag="$2" output="$3" temp publication
    local component tool version reason host target manifest base expected_tag
    local f0 s0 f1 s1 f2 s2 table names expected_names asset_name digest expected

    command -v gh >/dev/null 2>&1 || fail 'gh is required for catalog activation'
    [ "$(gh api "repos/$repo/releases/tags/$tag" --jq '.draft')" = false ] || fail "package release is still a draft: $tag"

    temp="$(mktemp -d)"; trap 'rm -rf "$temp"' RETURN
    gh release download "$tag" --repo "$repo" --pattern publication.txt --dir "$temp" >/dev/null
    publication="$temp/publication.txt"
    [ -f "$publication" ] || fail "package release is missing publication.txt: $tag"
    publication_descriptor_validate "$publication"
    component="$(single_value "$publication" package.component)"
    tool="$(single_value "$publication" package.tool)"
    version="$(single_value "$publication" package.version)"
    reason="$(optional_value "$publication" package.revision_reason || true)"
    host="$(single_value "$publication" platform.host)"
    target="$(single_value "$publication" platform.target)"
    manifest="$(single_value "$publication" manifest_sha256)"
    [[ "$manifest" =~ ^[0-9a-f]{64}$ ]] || fail 'publication has an invalid manifest SHA-256'
    known_package_scope "$component" "$tool" "$host" "$target" || fail 'publication has an unsupported package scope'
    package_version_is_valid "$version" || fail "publication has an invalid package version: $version"
    if package_version_has_revision "$version"; then
        package_revision_reason_is_valid "$reason" || fail 'revision-bearing publication lacks a valid reason'
    else
        [ -z "$reason" ] || fail 'revisionless publication has a revision reason'
    fi

    base="$tool-$version-$host-$target"
    expected_tag="pkg-$base"
    [ "$tag" = "$expected_tag" ] || fail "publication tag does not match structured identity: expected $expected_tag"

    f0="$(single_value "$publication" artifact.0.format)"; s0="$(single_value "$publication" artifact.0.sha256)"
    f1="$(single_value "$publication" artifact.1.format)"; s1="$(single_value "$publication" artifact.1.sha256)"
    f2="$(single_value "$publication" artifact.2.format)"; s2="$(single_value "$publication" artifact.2.sha256)"
    [ "$f0" = tar.xz ] && [ "$f1" = tar.gz ] && [ "$f2" = zip ] || fail 'publication artifact formats are not canonical'
    for expected in "$s0" "$s1" "$s2"; do [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail 'publication has an invalid artifact SHA-256'; done
    if grep -Eq '^artifact\.[3-9][0-9]*\.' "$publication"; then fail 'publication declares more than three artifacts'; fi

    expected_names="$(printf '%s\n' publication.txt "$base.tar.xz" "$base.tar.gz" "$base.zip" | LC_ALL=C sort)"
    table="$(release_asset_table "$repo" "$tag")" || fail "failed to inspect package release assets: $tag"
    names="$(printf '%s\n' "$table" | cut -f1 | LC_ALL=C sort)"
    [ "$names" = "$expected_names" ] || fail "package release has an unexpected managed asset set: $tag"

    while IFS=$'\t' read -r asset_name digest; do
        case "$asset_name" in
            publication.txt) expected="sha256:$(sha256_file "$publication")" ;;
            "$base.tar.xz") expected="sha256:$s0" ;;
            "$base.tar.gz") expected="sha256:$s1" ;;
            "$base.zip") expected="sha256:$s2" ;;
            *) fail "unexpected package release asset: $asset_name" ;;
        esac
        [ "$digest" = "$expected" ] || fail "release asset digest mismatch: $asset_name"
    done <<< "$table"

    printf '%s\t%s\t%s\t%s\t%s\t%s\tfalse\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$component" "$tool" "$host" "$target" "$version" "$reason" \
        tar.xz "$(package_release_url "$repo" "$tag" "$base.tar.xz")" "$s0" \
        tar.gz "$(package_release_url "$repo" "$tag" "$base.tar.gz")" "$s1" \
        zip "$(package_release_url "$repo" "$tag" "$base.zip")" "$s2" > "$output"

    rm -rf "$temp"; trap - RETURN
}

cmd_init() {
    local catalog="$1" repo="$2"
    [ ! -e "$catalog" ] || fail "catalog already exists: $catalog"
    mkdir -p "$(dirname "$catalog")"
    printf 'format=1\nrevision=0\nupdate_url=%s\n' "$(catalog_update_url "$repo")" > "$catalog"
    validate_catalog "$catalog" "$repo"
}

cmd_activate() {
    local catalog="$1" repo="$2" tag="$3" old new row identity existing next_revision candidate_row
    validate_catalog "$catalog" "$repo"
    old="$(mktemp)"; new="$(mktemp)"; row="$(mktemp)"
    trap 'rm -f "$old" "$new" "$row"' RETURN
    catalog_to_tsv "$catalog" "$old"
    publication_row_from_release "$repo" "$tag" "$row"
    identity="$(cut -f1-5 "$row")"
    existing="$(awk -F '\t' -v id="$identity" 'BEGIN{OFS="\t"} {cur=$1 OFS $2 OFS $3 OFS $4 OFS $5; if(cur==id){$7="false"; print; exit}}' "$old")"
    candidate_row="$(awk -F '\t' 'BEGIN{OFS="\t"}{$7="false";print}' "$row")"
    if [ -n "$existing" ]; then
        [ "$existing" = "$candidate_row" ] || fail "catalog already contains different immutable data for $identity"
        printf 'catalog unchanged at revision %s\n' "$CATALOG_REVISION"
        rm -f "$old" "$new" "$row"; trap - RETURN
        return 0
    fi
    cat "$old" "$row" > "$new"
    validate_tsv "$new" "$repo"
    next_revision="$(uint64_increment "$CATALOG_REVISION")"
    render_catalog "$next_revision" "$repo" "$new" "$catalog"
    validate_catalog "$catalog" "$repo"
    printf 'catalog revision %s\n' "$next_revision"
    rm -f "$old" "$new" "$row"; trap - RETURN
}

cmd_transition() {
    local old_catalog="$1" new_catalog="$2" repo="$3" old new identity existing normalized
    validate_catalog "$old_catalog" "$repo"
    validate_catalog "$new_catalog" "$repo"
    old="$(mktemp)"; new="$(mktemp)"; trap 'rm -f "$old" "$new"' RETURN
    catalog_to_tsv "$old_catalog" "$old"; catalog_to_tsv "$new_catalog" "$new"
    while IFS= read -r line; do
        identity="$(printf '%s\n' "$line" | cut -f1-5)"
        existing="$(awk -F '\t' -v id="$identity" 'BEGIN{OFS="\t"}{cur=$1 OFS $2 OFS $3 OFS $4 OFS $5;if(cur==id){$7="false";print;exit}}' "$new")"
        [ -n "$existing" ] || continue
        normalized="$(printf '%s\n' "$line" | awk -F '\t' 'BEGIN{OFS="\t"}{$7="false";print}')"
        [ "$existing" = "$normalized" ] || fail "catalog transition mutates immutable package identity: $identity"
    done < "$old"
    rm -f "$old" "$new"; trap - RETURN
}

usage() {
    cat >&2 <<'EOF_USAGE'
usage:
  catalog.sh init <catalog> <repository>
  catalog.sh validate <catalog> <repository>
  catalog.sh activate <catalog> <repository> <package-tag>
  catalog.sh transition <old-catalog> <new-catalog> <repository>
EOF_USAGE
    exit 2
}

[ "$#" -ge 1 ] || usage
command="$1"; shift
case "$command" in
    init) [ "$#" -eq 2 ] || usage; cmd_init "$@" ;;
    validate) [ "$#" -eq 2 ] || usage; validate_catalog "$@" ;;
    activate) [ "$#" -eq 3 ] || usage; cmd_activate "$@" ;;
    transition) [ "$#" -eq 3 ] || usage; cmd_transition "$@" ;;
    *) usage ;;
esac
