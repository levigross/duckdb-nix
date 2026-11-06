#!/usr/bin/env bash
# Pin NeuG, the embedded graph database of Alibaba's GraphScope team:
# pkgs/neug/pin.json gets a release of alibaba/neug and the hash of its sources with every
# submodule, the nested ones too (zvec brings Arrow and RocksDB along), as fetchFromGitHub
# with fetchSubmodules fetches them:
#
#   scripts/update-neug.sh [tag]    # default: the latest release
#
# The hash is computed here, with the same program the fetcher runs (nix-prefetch-git), from
# the sources themselves. The release has no asset to check it against.
#
# Needs: gh, jq, nix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo=alibaba/neug
tag="${1:-$(gh release list -R "$repo" --exclude-pre-releases --limit 1 --json tagName --jq '.[].tagName')}"

# an annotated tag points at a tag object, not at the commit
rev="$(gh api "repos/$repo/commits/$tag" --jq .sha)"

nix run nixpkgs#nix-prefetch-git -- \
  --url "https://github.com/$repo" --rev "$rev" --fetch-submodules --quiet >"$work/prefetch.json"
hash="$(nix hash convert --hash-algo sha256 --to sri "$(jq -r .sha256 "$work/prefetch.json")")"

# node-addon-api, which the Node.js addon is built against: the version the lock file of the
# addon names, fetched from the registry, and the run fails unless its hash is the one the lock
# records
lock="$(gh api "repos/$repo/contents/tools/nodejs_bind/package-lock.json?ref=$rev" -H 'Accept: application/vnd.github.raw')"
addon="$(jq '.packages["node_modules/node-addon-api"]' <<<"$lock")"
addon_url="$(jq -r .resolved <<<"$addon")"
addon_hash="$(nix store prefetch-file --hash-type sha512 --json "$addon_url" | jq -r .hash)"
if [ "$addon_hash" != "$(jq -r .integrity <<<"$addon")" ]; then
  echo "node-addon-api: $addon_url hashes to $addon_hash, its lock file says $(jq -r .integrity <<<"$addon")" >&2
  exit 1
fi

# googletest, which the tests of NeuG fetch when CMake configures them: the tag its CMake names
gtest_tag="$(gh api "repos/$repo/contents/third_party/gtest/CMakeLists.txt?ref=$rev" -H 'Accept: application/vnd.github.raw' | awk '/GIT_TAG/ {print $2}')"
gtest_hash="$(nix flake prefetch "github:google/googletest/$gtest_tag" --json | jq -r .hash)"

mkdir -p "$root/pkgs/neug"
jq -S -n \
  --arg version "${tag#v}" \
  --arg tag "$tag" \
  --arg rev "$rev" \
  --arg hash "$hash" \
  --arg addonVersion "$(jq -r .version <<<"$addon")" \
  --arg addonUrl "$addon_url" \
  --arg addonHash "$addon_hash" \
  --arg gtestTag "$gtest_tag" \
  --arg gtestHash "$gtest_hash" \
  '{version: $version, tag: $tag, rev: $rev, hash: $hash,
    nodeAddonApi: {version: $addonVersion, url: $addonUrl, hash: $addonHash},
    googletest: {tag: $gtestTag, hash: $gtestHash}}' >"$work/pin.json"
mv "$work/pin.json" "$root/pkgs/neug/pin.json"
echo "pinned $repo $tag ($rev) in pkgs/neug/pin.json"
