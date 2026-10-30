#!/usr/bin/env bash
# Regenerate every pin from an upstream DuckDB release, computing all hashes
# here rather than copying them from anywhere:
#
#   pkgs/duckdb/versions.json            DuckDB itself: version, commit, hash
#   pkgs/duckdb/extensions/pins.json     each extension (and the submodules it
#                                        needs) at the commit that release pins
#                                        in .github/config/extensions/*.cmake
#
#   scripts/update.sh [tag]     # default: the latest DuckDB release
#
# Needs: gh, jq, nix. Submodules other than extension-ci-tools (which only CI
# uses) are pinned too, since GitHub tarballs do not include submodules.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions="$root/pkgs/duckdb/versions.json"
out="$root/pkgs/duckdb/extensions/pins.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

raw() { gh api -H "Accept: application/vnd.github.raw" "$1"; }
prefetch() { nix flake prefetch "github:$1/$2" --json | jq -r .hash; }

tag="${1:-$(gh release list -R duckdb/duckdb --exclude-pre-releases --limit 1 --json tagName --jq '.[].tagName')}"

# DuckDB itself. An annotated tag points at a tag object, not the commit.
read -r type sha < <(gh api "repos/duckdb/duckdb/git/ref/tags/$tag" --jq '"\(.object.type) \(.object.sha)"')
if [ "$type" = tag ]; then
  sha="$(gh api "repos/duckdb/duckdb/git/tags/$sha" --jq .object.sha)"
fi
jq -n --arg version "${tag#v}" --arg rev "$sha" --arg hash "$(prefetch duckdb/duckdb "$tag")" \
  '{version: $version, rev: $rev, hash: $hash}' >"$versions"
echo "wrote $versions (duckdb $tag @ ${sha:0:10})" >&2

pin_one() {
  local file="$1" cfg name url sha subm incl patches repo owner_repo
  cfg="$(raw "repos/duckdb/duckdb/contents/.github/config/extensions/$file?ref=$tag")"
  name="$(sed -n 's/^[[:space:]]*duckdb_extension_load([[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' <<<"$cfg" | head -1)"
  url="$(awk '$1=="GIT_URL"{print $2; exit}' <<<"$cfg")"
  sha="$(awk '$1=="GIT_TAG"{print $2; exit}' <<<"$cfg")"
  [ -n "$name" ] && [ -n "$url" ] && [ -n "$sha" ] || { echo "skip $file (no git source)" >&2; return 0; }
  subm="$(awk '$1=="SUBMODULES"{print $2; exit}' <<<"$cfg" | tr -d '"')"
  incl="$(awk '$1=="INCLUDE_DIR"{print $2; exit}' <<<"$cfg")"
  patches=false
  grep -q APPLY_PATCHES <<<"$cfg" && patches=true
  repo="${url#https://github.com/}"
  repo="${repo%.git}"

  local hash
  hash="$(prefetch "$repo" "$sha")"

  # submodules the build needs, resolved to the commit the pin records
  local subs='{}' path gm_url sub_sha sub_repo
  if [ -n "$subm" ] && [ "$subm" != extension-ci-tools ]; then
    for path in $subm; do
      [ "$path" = extension-ci-tools ] && continue
      gm_url="$(raw "repos/$repo/contents/.gitmodules?ref=$sha" |
        awk -v p="$path" '$1=="path"{cur=$3} $1=="url" && cur==p {print $3}')"
      sub_repo="${gm_url#https://github.com/}"
      sub_repo="${sub_repo%.git}"
      sub_sha="$(gh api "repos/$repo/git/trees/$sha?recursive=1" \
        --jq ".tree[]|select(.mode==\"160000\" and .path==\"$path\")|.sha")"
      subs="$(jq -c --arg p "$path" --arg o "${sub_repo%%/*}" --arg r "${sub_repo##*/}" \
        --arg v "$sub_sha" --arg h "$(prefetch "$sub_repo" "$sub_sha")" \
        '. + {($p): {owner:$o, repo:$r, rev:$v, hash:$h}}' <<<"$subs")"
    done
  fi

  jq -n --arg name "$name" --arg o "${repo%%/*}" --arg r "${repo##*/}" --arg rev "$sha" \
    --arg hash "$hash" --arg incl "$incl" --argjson patches "$patches" --argjson subs "$subs" \
    '{($name): ({owner:$o, repo:$r, rev:$rev, hash:$hash, patches:$patches}
      + (if $incl == "" then {} else {include:$incl} end)
      + (if $subs == {} then {} else {submodules:$subs} end))}' >"$work/$name.json"
  echo "pinned $name" >&2
}

export -f pin_one raw prefetch
export tag work

# test-utils is an internal backwards-compatibility test extension
gh api "repos/duckdb/duckdb/contents/.github/config/extensions?ref=$tag" --jq '.[].name' |
  grep -v '^test-utils' |
  xargs -P 8 -I{} bash -c 'pin_one {}'

jq -S -s 'add' "$work"/*.json >"$out"
echo "wrote $out ($(jq 'length' "$out") extensions, duckdb $tag)" >&2
