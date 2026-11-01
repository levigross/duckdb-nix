#!/usr/bin/env bash
# Regenerate every pin from an upstream DuckDB release, computing all hashes
# here rather than copying them from anywhere:
#
#   pkgs/duckdb/versions.json            DuckDB itself: version, commit, hash
#   pkgs/duckdb/extensions/pins.json     each extension (and the submodules it
#                                        needs) at the commit that release pins
#                                        in .github/config/extensions/*.cmake,
#                                        and the community ones named below
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

# Community extensions are not in DuckDB's own config. Their descriptors in
# duckdb/community-extensions name the commit to build. DuckDB's own pins are
# for exactly this release; a community one is only known to fit it if the
# DuckDB it was developed against, which is a submodule, is this release.
community=(duckpgq)
community_rev="$(gh api repos/duckdb/community-extensions/commits/main --jq .sha)"
duckdb_rev="$(jq -r .rev "$versions")"
for name in "${community[@]}"; do
  descriptor="https://raw.githubusercontent.com/duckdb/community-extensions/$community_rev/extensions/$name/description.yml"
  repo="$(curl -fsSL "$descriptor" | awk '/^repo:/ {in_repo = 1; next} in_repo && $1 == "github:" {print $2; exit}')"
  sha="$(curl -fsSL "$descriptor" | awk '/^repo:/ {in_repo = 1; next} in_repo && $1 == "ref:" {print $2; exit}')"
  [ -n "$repo" ] && [ -n "$sha" ] || { echo "$name: no repository and ref in $descriptor" >&2; exit 1; }
  built_with="$(gh api "repos/$repo/git/trees/$sha" --jq '.tree[] | select(.path == "duckdb") | .sha')"
  if [ "$built_with" != "$duckdb_rev" ]; then
    echo "$name: $repo@${sha:0:10} is developed against DuckDB ${built_with:0:10}, not $tag (${duckdb_rev:0:10})" >&2
    exit 1
  fi
  jq -n --arg name "$name" --arg o "${repo%%/*}" --arg r "${repo##*/}" --arg rev "$sha" \
    --arg hash "$(prefetch "$repo" "$sha")" --arg crev "$community_rev" \
    --arg dhash "$(nix store prefetch-file --json "$descriptor" | jq -r .hash)" \
    '{($name): {owner: $o, repo: $r, rev: $rev, hash: $hash, patches: false,
                community: {rev: $crev, descriptorHash: $dhash}}}' >"$work/$name.json"
  echo "pinned $name (community)" >&2
done

# The delta extension clones delta-kernel-rs and builds it with cargo. Pin the
# repository and tag its own CMake names, so Nix can build it instead.
delta_rev="$(jq -r .delta.rev "$work/delta.json")"
kernel_cmake="$(raw "repos/duckdb/duckdb-delta/contents/CMakeLists.txt?ref=$delta_rev")"
kernel_repo="$(awk '$1=="GIT_REPOSITORY"{gsub(/"/,"",$2); print $2; exit}' <<<"$kernel_cmake")"
kernel_repo="${kernel_repo#https://github.com/}"
kernel_tag="$(awk '$1=="GIT_TAG"{print $2; exit}' <<<"$kernel_cmake")"
[ -n "$kernel_repo" ] && [ -n "$kernel_tag" ] || { echo "no delta-kernel-rs in duckdb-delta's CMake" >&2; exit 1; }
jq --arg o "${kernel_repo%%/*}" --arg r "${kernel_repo##*/}" --arg t "$kernel_tag" \
  --arg h "$(prefetch "$kernel_repo" "$kernel_tag")" \
  '.delta.kernel = {owner: $o, repo: $r, rev: $t, hash: $h}' "$work/delta.json" >"$work/delta.json.new"
mv "$work/delta.json.new" "$work/delta.json"
echo "pinned delta-kernel-rs $kernel_tag" >&2

jq -S -s 'add' "$work"/*.json >"$out"
echo "wrote $out ($(jq 'length' "$out") extensions, duckdb $tag)" >&2

# Rust extensions build offline from their Cargo.lock. It is copied in here so
# that evaluating the flake needs no network and no import from derivation.
locks="$root/pkgs/duckdb/extensions/rust"
mkdir -p "$locks"
vendor_lock() { # name  jq path of its source in pins.json  Cargo.lock path in that repo
  local repo rev
  repo="$(jq -r "$2 | \"\(.owner)/\(.repo)\"" "$out")"
  rev="$(jq -r "$2.rev" "$out")"
  raw "repos/$repo/contents/$3?ref=$rev" >"$locks/$1.Cargo.lock"
  echo "vendored $1.Cargo.lock ($(grep -c '^\[\[package\]\]' "$locks/$1.Cargo.lock") crates)" >&2
}
vendor_lock lance .lance Cargo.lock
vendor_lock delta .delta.kernel Cargo.lock
# The Cargo.lock that duckdb-vortex commits does not match its own Cargo.toml: it
# pins an older vortex revision than the manifest asks for. Upstream never
# notices, since its CMake runs a plain `cargo build`, which re-resolves online.
# Do that here, touching only vortex-duckdb and what depends on it, so the
# offline Nix build can use --locked.
relock_vortex() {
  local repo rev dir f
  repo="$(jq -r '.vortex | "\(.owner)/\(.repo)"' "$out")"
  rev="$(jq -r '.vortex.rev' "$out")"
  dir="$work/vortex-relock/vortex-extension"
  mkdir -p "$dir/src"
  for f in Cargo.toml Cargo.lock; do
    raw "repos/$repo/contents/vortex-extension/$f?ref=$rev" >"$dir/$f"
  done
  for f in $(gh api "repos/$repo/contents/vortex-extension/src?ref=$rev" --jq '.[].name'); do
    raw "repos/$repo/contents/vortex-extension/src/$f?ref=$rev" >"$dir/src/$f"
  done
  (cd "$dir" && nix shell nixpkgs#cargo nixpkgs#rustc -c cargo update -p vortex-duckdb >&2)
  cp "$dir/Cargo.lock" "$locks/vortex.Cargo.lock"
  echo "vendored vortex.Cargo.lock, re-resolved ($(grep -c '^\[\[package\]\]' "$locks/vortex.Cargo.lock") crates)" >&2
}
relock_vortex

# Some of vortex's Rust dependencies come from git. Crane wants a hash for each
# `source` string in the lock, fetched the way it fetches them. One prefetch per
# repository and commit, shared by every crate from it.
git_hashes() { # Cargo.lock -> JSON object of lock source string to hash
  local lock="$1" source url rev key json='{}'
  declare -A hashes=()
  while IFS= read -r source; do
    url="${source#git+}"
    url="${url%%\?*}"
    url="${url%%#*}"
    rev="${source##*#}"
    key="$url $rev"
    if [ -z "${hashes[$key]:-}" ]; then
      hashes[$key]="$(nix run nixpkgs#nix-prefetch-git -- --quiet --url "$url" --rev "$rev" \
        --fetch-submodules --fetch-lfs | jq -r .hash)"
      echo "prefetched $url @ ${rev:0:10}" >&2
    fi
    json="$(jq -c --arg s "$source" --arg h "${hashes[$key]}" '. + {($s): $h}' <<<"$json")"
  done < <(grep -o 'source = "git+[^"]*"' "$lock" | sed 's/^source = "//; s/"$//' | sort -u)
  echo "$json"
}
jq -S --argjson hashes "$(git_hashes "$locks/vortex.Cargo.lock")" '.vortex.gitHashes = $hashes' "$out" >"$work/pins.json"
mv "$work/pins.json" "$out"
