#!/usr/bin/env bash
# PoC-1 build script.
#
# NOTE: wasm32-unknown-unknown std is only installed for toolchain 1.88.0 in this
# environment, so we force it. (rustup target downloads are unusably slow here.)
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN="${WASM_TOOLCHAIN:-1.88.0}"
CRATE=poc1_wgpu_triangle

echo ">> cargo build ($TOOLCHAIN)"
rustup run "$TOOLCHAIN" cargo build --target wasm32-unknown-unknown --release

echo ">> wasm-bindgen"
rm -rf pkg
wasm-bindgen --target web --no-typescript --out-dir pkg \
  "target/wasm32-unknown-unknown/release/${CRATE}.wasm"

echo ">> done. Files:"
ls -la pkg
echo
echo "Serve with:  python3 -m http.server 8099"
echo "Then open:   http://localhost:8099/"
