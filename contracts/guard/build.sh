#!/usr/bin/env bash
# Builds guard.wasm (the contract) and test_ft.wasm (the token used by the sandbox tests) into ./dist.
#
#   CARGO=cargo WASM_OPT=wasm-opt ./build.sh [outdir]
#
# Why the wasm-opt step: rustc 1.82+ links std with "reference types" call_indirect encodings that nearcore refuses
# (PrepareError: Deserialization). wasm-opt (binaryen v119) rewrites the module, lowers sign-extension ops, and the result
# is plain MVP wasm. If `wasm-tools` is installed the result is validated as MVP-only.
set -euo pipefail
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
WASM_OPT=${WASM_OPT:-wasm-opt}
OUT=${1:-dist}
# keep build-machine paths out of the wasm (panic messages embed them), so the same source gives the same bytes anywhere
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$PWD=/src"
mkdir -p "$OUT"
build_one() { # crate dir, wasm file name, output name
  local dir=$1 file=$2 name=$3
  local target=${CARGO_TARGET_DIR:-$PWD/$dir/target}
  (cd "$dir" && CARGO_TARGET_DIR="$target" $CARGO build --release --target wasm32-unknown-unknown --locked)
  "$WASM_OPT" -Oz --enable-sign-ext --enable-mutable-globals --enable-reference-types --signext-lowering \
    --strip-debug --strip-producers "$target/wasm32-unknown-unknown/release/$file" -o "$OUT/$name"
  if command -v wasm-tools >/dev/null; then
    wasm-tools validate --features=mvp "$OUT/$name" && echo "$name: valid MVP wasm"
  fi
}
build_one . hermit_guard.wasm guard.wasm
build_one test-ft test_ft.wasm test_ft.wasm
for f in guard.wasm test_ft.wasm; do
  echo "$f  $(stat -c %s "$OUT/$f") bytes  sha256 $(sha256sum "$OUT/$f" | cut -d' ' -f1)"
done
