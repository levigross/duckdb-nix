#!/usr/bin/env bash
# Pin zvec, Alibaba's embedded vector search library: pkgs/zvec/pin.json gets a commit of
# alibaba/zvec and the hash of its sources with every submodule, the nested ones too (Arrow
# and RocksDB are among them), as fetchFromGitHub with fetchSubmodules fetches them:
#
#   scripts/update-zvec.sh [commit]    # default: the commit NeuG has as its submodule
#
# By default it is the commit that the release of NeuG in pkgs/neug/pin.json has as
# third_party/zvec, because the vector_search extension of NeuG is compiled against the
# headers of exactly that commit (the NeuG derivation checks that they are the ones of this
# package). The hash is computed here with the program the fetcher runs (nix-prefetch-git).
#
# Needs: gh, jq, nix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo=alibaba/zvec
rev="${1:-$(gh api "repos/alibaba/neug/contents/third_party/zvec?ref=$(jq -r .rev "$root/pkgs/neug/pin.json")" --jq .sha)}"
date="$(gh api "repos/$repo/commits/$rev" --jq '.commit.committer.date[0:10]')"

nix run nixpkgs#nix-prefetch-git -- \
  --url "https://github.com/$repo" --rev "$rev" --fetch-submodules --quiet >"$work/prefetch.json"
hash="$(nix hash convert --hash-algo sha256 --to sri "$(jq -r .sha256 "$work/prefetch.json")")"

mkdir -p "$root/pkgs/zvec"
jq -S -n --arg version "0-unstable-$date" --arg rev "$rev" --arg hash "$hash" \
  '{version: $version, rev: $rev, hash: $hash}' >"$work/pin.json"
mv "$work/pin.json" "$root/pkgs/zvec/pin.json"
echo "pinned $repo $rev ($date) in pkgs/zvec/pin.json"
