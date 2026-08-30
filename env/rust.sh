#!/bin/sh

set -eu

RUST_TOOLCHAIN=${RUST_TOOLCHAIN:-1.98.0}
CARGO_AUDIT_VERSION=${CARGO_AUDIT_VERSION:-0.22.2}
CARGO_DENY_VERSION=${CARGO_DENY_VERSION:-0.20.2}
CARGO_NEXTEST_VERSION=${CARGO_NEXTEST_VERSION:-0.9.143}
RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/rustup}
CARGO_HOME=${CARGO_HOME:-/usr/local/cargo}

export RUST_TOOLCHAIN CARGO_AUDIT_VERSION CARGO_DENY_VERSION CARGO_NEXTEST_VERSION
export RUSTUP_HOME CARGO_HOME

tmpdir=

print_defaults() {
  printf 'RUST_TOOLCHAIN=%s\n' "$RUST_TOOLCHAIN"
  printf 'CARGO_AUDIT_VERSION=%s\n' "$CARGO_AUDIT_VERSION"
  printf 'CARGO_DENY_VERSION=%s\n' "$CARGO_DENY_VERSION"
  printf 'CARGO_NEXTEST_VERSION=%s\n' "$CARGO_NEXTEST_VERSION"
  printf 'RUSTUP_HOME=%s\n' "$RUSTUP_HOME"
  printf 'CARGO_HOME=%s\n' "$CARGO_HOME"
}

install_environment() {
  : "${RUSTUP_HOME:?RUSTUP_HOME must be set}"
  : "${CARGO_HOME:?CARGO_HOME must be set}"
  : "${RUST_TOOLCHAIN:?RUST_TOOLCHAIN must be set}"
  : "${CARGO_AUDIT_VERSION:?CARGO_AUDIT_VERSION must be set}"
  : "${CARGO_DENY_VERSION:?CARGO_DENY_VERSION must be set}"
  : "${CARGO_NEXTEST_VERSION:?CARGO_NEXTEST_VERSION must be set}"

  rust_target=
  rust_arch="$(dpkg --print-architecture)"
  case "$rust_arch" in
  arm64) rust_target=aarch64-unknown-linux-gnu ;;
  amd64) rust_target=x86_64-unknown-linux-gnu ;;
  *)
    echo "unsupported architecture for rustup: $rust_arch" >&2
    exit 1
    ;;
  esac

  tmpdir=$(mktemp -d)
  rustup_url=https://static.rust-lang.org/rustup/dist/$rust_target/rustup-init
  curl -fsSLo "$tmpdir/rustup-init" "$rustup_url"
  curl -fsSLo "$tmpdir/rustup-init.sha256" "$rustup_url.sha256"
  (cd "$tmpdir" && sha256sum -c rustup-init.sha256)
  chmod 0755 "$tmpdir/rustup-init"

  if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
      "$tmpdir/rustup-init" -y --no-modify-path --profile minimal \
      --default-toolchain "$RUST_TOOLCHAIN"
  fi

  "$CARGO_HOME/bin/rustup" toolchain install "$RUST_TOOLCHAIN" --profile minimal
  "$CARGO_HOME/bin/rustup" default "$RUST_TOOLCHAIN"
  "$CARGO_HOME/bin/rustup" component add --toolchain "$RUST_TOOLCHAIN" \
    rustfmt clippy rust-analyzer
  "$CARGO_HOME/bin/rustup" target add --toolchain "$RUST_TOOLCHAIN" wasm32-wasip1

  install -d -m 0777 "$CARGO_HOME/registry" "$CARGO_HOME/git"
  install -d -m 0755 "$CARGO_HOME/bin"
  cargo install --locked --version "$CARGO_AUDIT_VERSION" cargo-audit
  cargo install --locked --version "$CARGO_DENY_VERSION" cargo-deny
  cargo install --locked --version "$CARGO_NEXTEST_VERSION" cargo-nextest
}

check_environment() {
  tmpdir=$(mktemp -d)

  rustc --version
  cargo --version
  rustfmt --version
  cargo clippy --version
  rust-analyzer --version
  cargo-audit --version
  cargo-deny --version
  cargo-nextest --version

  rust_source="$tmpdir/main.rs"
  printf '%s\n' 'fn main() { println!("rust-ok"); }' >"$rust_source"
  rustc "$rust_source" -o "$tmpdir/rust-check"
  [ "$("$tmpdir/rust-check")" = rust-ok ]
  rustc --target wasm32-wasip1 "$rust_source" -o "$tmpdir/rust-check.wasm"
  [ -s "$tmpdir/rust-check.wasm" ]
}

trap 'rm -rf -- "$tmpdir"' 0
trap 'exit 1' 1 2 3 15

case "${1:-}" in
defaults)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install|check\n' "$0" >&2
    exit 2
  }
  print_defaults
  ;;
install)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install|check\n' "$0" >&2
    exit 2
  }
  install_environment
  ;;
check)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install|check\n' "$0" >&2
    exit 2
  }
  check_environment
  ;;
*)
  printf 'usage: %s defaults|install|check\n' "$0" >&2
  exit 2
  ;;
esac
