#!/usr/bin/env bash
# Lock the Rust example of chDB (examples/chdb-rust-consumer), which is built with a
# choice of TLS stack (nix/chdb/rust.nix):
#
#   Cargo.lock         for the build with OpenSSL, as cargo resolves the crate chdb-rust
#   Cargo.rustls.lock  for the build with rustls, resolved with chdb-rust patched so that
#                      the reqwest of its build script uses rustls
#
#   scripts/update-chdb-rust.sh    # the versions crates.io has now; keeps them if CARGO_KEEP=1
#
# The second starts from the first, so the two agree on every crate they share.
#
# Needs: cargo and rustc, nix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
example="$root/examples/chdb-rust-consumer"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$example"
if [ "${CARGO_KEEP:-0}" != 1 ]; then
  rm -f Cargo.lock
fi
cargo generate-lockfile

# the patched crate is made from the lock file just written
patched="$(nix build --no-link --print-out-paths "$root#dev-chdb-rust-rustls-crate")"

cp -r "$example/." "$work/"
chmod -R u+w "$work"
cat >>"$work/Cargo.toml" <<EOF

[patch.crates-io]
chdb-rust = { path = "$patched" }
EOF
(cd "$work" && cargo metadata --format-version 1 >/dev/null)
cp "$work/Cargo.lock" "$example/Cargo.rustls.lock"

echo "locked: $(grep -c '^name = ' Cargo.lock) crates with OpenSSL, $(grep -c '^name = ' Cargo.rustls.lock) with rustls"
if grep -q 'name = "openssl-sys"' Cargo.rustls.lock; then
  echo "Cargo.rustls.lock still has openssl-sys" >&2
  exit 1
fi
