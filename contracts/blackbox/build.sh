#!/usr/bin/env bash
# Builds dist/blackbox.wasm. Same recipe as contracts/guard/build.sh: rustc 1.86, then binaryen v119 wasm-opt so
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
  --strip-debug --strip-producers "$target/wasm32-unknown-unknown/release/hermit_blackbox.wasm" -o "$OUT/blackbox.wasm"
if command -v wasm-tools >/dev/null; then wasm-tools validate --features=mvp "$OUT/blackbox.wasm" && echo "valid MVP wasm"; fi
echo "blackbox.wasm  $(stat -c %s "$OUT/blackbox.wasm") bytes  sha256 $(sha256sum "$OUT/blackbox.wasm" | cut -d' ' -f1)"
