#!/usr/bin/env bash
# Builds dist/insurance.wasm. Same recipe as contracts/guard/build.sh: rustc 1.86, then binaryen v119 wasm-opt so
# nearcore accepts the module (plain cargo output fails with PrepareError: Deserialization).
#
#   CARGO=cargo WASM_OPT=wasm-opt ./build.sh [outdir]
set -euo pipefail
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
WASM_OPT=${WASM_OPT:-wasm-opt}
OUT=${1:-dist}
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$PWD=/src"
mkdir -p "$OUT"
target=${CARGO_TARGET_DIR:-$PWD/target}
CARGO_TARGET_DIR="$target" $CARGO build --release --target wasm32-unknown-unknown --locked
"$WASM_OPT" -Oz --enable-sign-ext --enable-mutable-globals --enable-reference-types --signext-lowering \
  --strip-debug --strip-producers "$target/wasm32-unknown-unknown/release/hermit_insurance.wasm" -o "$OUT/insurance.wasm"
if command -v wasm-tools >/dev/null; then wasm-tools validate --features=mvp "$OUT/insurance.wasm" && echo "valid MVP wasm"; fi
echo "insurance.wasm  $(stat -c %s "$OUT/insurance.wasm") bytes  sha256 $(sha256sum "$OUT/insurance.wasm" | cut -d' ' -f1)"
