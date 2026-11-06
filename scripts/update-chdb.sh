#!/usr/bin/env bash
# Pin chDB, the in-process ClickHouse. pkgs/chdb/pin.json gets, for one release of
# chdb-io/chdb-core, the prebuilt libchdb (the shared library and its header) and the
# chdb-core wheel of each system, and the pure-Python chdb wheel that goes with them,
# each with its hash:
#
#   scripts/update-chdb.sh [chdb-core tag] [chdb tag]   # default: the latest release of each
#
# Every hash is computed here, from the file itself. The upstream publishes a SHA256SUMS
# file with each release of chdb-core, and a digest for each asset of chdb; the run fails
# if the hash it computed is not the one published, or if an asset is not listed.
# Nothing the upstream publishes is signed or attested, so that is all this proves: that
# the file is the one the release lists.
#
# Needs: gh, jq, nix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

core=chdb-io/chdb-core
wrapper=chdb-io/chdb

latest() { gh release list -R "$1" --exclude-pre-releases --limit 1 --json tagName --jq '.[].tagName'; }
core_tag="${1:-$(latest "$core")}"
wrapper_tag="${2:-$(latest "$wrapper")}"

gh release download "$core_tag" -R "$core" -p SHA256SUMS -D "$work"
core_assets="$(gh release view "$core_tag" -R "$core" --json assets --jq '.assets[].name')"
wrapper_assets="$(gh release view "$wrapper_tag" -R "$wrapper" --json assets)"

# pin <name> <url> <sha256 in hex that the upstream published>: {url, hash}
pin() {
  local sri hex
  sri="$(nix store prefetch-file --json "$2" | jq -r .hash)"
  hex="$(nix hash convert --hash-algo sha256 --to base16 "$sri")"
  if [ "$hex" != "$3" ]; then
    echo "$1: the file hashes to $hex, the release publishes $3" >&2
    exit 1
  fi
  jq -n --arg url "$2" --arg hash "$sri" '{url: $url, hash: $hash}'
}

# the asset of chdb-core that matches a pattern, which must be exactly one
core_asset() {
  local found
  found="$(grep -E "$1" <<<"$core_assets" || true)"
  if [ "$(wc -l <<<"$found")" != 1 ] || [ -z "$found" ]; then
    echo "chdb-core $core_tag: expected one asset matching $1, found: ${found:-none}" >&2
    exit 1
  fi
  echo "$found"
}

# one entry per system the upstream builds for Linux; the macOS builds are not pinned
systems=""
for pair in x86_64-linux:x86_64 aarch64-linux:aarch64; do
  system="${pair%%:*}"
  arch="${pair##*:}"
  lib="$(core_asset "^linux-${arch}-libchdb\.tar\.gz$")"
  whl="$(core_asset "^chdb_core-.*manylinux.*_${arch}\.whl$")"
  base="https://github.com/$core/releases/download/$core_tag"
  libchdb="$(pin "$lib" "$base/$lib" "$(awk -v n="$lib" '$2 == n {print $1}' "$work/SHA256SUMS")")"
  corewheel="$(pin "$whl" "$base/$whl" "$(awk -v n="$whl" '$2 == n {print $1}' "$work/SHA256SUMS")")"
  systems="$systems$(jq -n --arg s "$system" --argjson l "$libchdb" --argjson w "$corewheel" '{($s): {libchdb: $l, coreWheel: $w}}')"
done

wheel="$(jq -r '[.assets[] | select(.name | test("^chdb-.*-py3-none-any\\.whl$"))] | if length == 1 then .[0].name else error("expected one wheel") end' <<<"$wrapper_assets")"
digest="$(jq -r --arg n "$wheel" '.assets[] | select(.name == $n) | .digest | sub("^sha256:"; "")' <<<"$wrapper_assets")"
wrapperwheel="$(pin "$wheel" "https://github.com/$wrapper/releases/download/$wrapper_tag/$wheel" "$digest")"

tmp="$work/pin.json"
jq -S -n \
  --arg version "${core_tag#v}" \
  --arg coreTag "$core_tag" \
  --arg wrapperVersion "${wrapper_tag#v}" \
  --arg wrapperTag "$wrapper_tag" \
  --argjson wrapperWheel "$wrapperwheel" \
  --argjson systems "$(jq -s 'add' <<<"$systems")" \
  '{version: $version, tag: $coreTag, repo: "chdb-io/chdb-core",
    wrapper: {version: $wrapperVersion, tag: $wrapperTag, repo: "chdb-io/chdb", wheel: $wrapperWheel},
    systems: $systems}' >"$tmp"

mkdir -p "$root/pkgs/chdb"
mv "$tmp" "$root/pkgs/chdb/pin.json"
echo "pinned chdb-core $core_tag and chdb $wrapper_tag in pkgs/chdb/pin.json"
