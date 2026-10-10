#!/usr/bin/env bash
# PoC-2 build script.
#
# Same toolchain note as PoC-1: wasm32 std is installed for 1.88.0 in this env.
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN="${WASM_TOOLCHAIN:-1.88.0}"
CRATE=poc2_veloren_glsl_wasm

echo ">> cargo build ($TOOLCHAIN)"
rustup run "$TOOLCHAIN" cargo build --target wasm32-unknown-unknown --release

echo ">> wasm-bindgen"
rm -rf pkg
wasm-bindgen --target web --no-typescript --out-dir pkg \
  "target/wasm32-unknown-unknown/release/${CRATE}.wasm"

echo ">> done. Files:"
ls -la pkg
