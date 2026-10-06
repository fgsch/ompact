#!/bin/sh

set -eu

RUST_TOOLCHAIN=${RUST_TOOLCHAIN:-1.99.0}
CARGO_AUDIT_VERSION=${CARGO_AUDIT_VERSION:-0.22.2}
CARGO_DENY_VERSION=${CARGO_DENY_VERSION:-0.20.2}
CARGO_NEXTEST_VERSION=${CARGO_NEXTEST_VERSION:-0.9.146}
CARGO_LLVM_COV_VERSION=${CARGO_LLVM_COV_VERSION:-0.9.1}
RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/rustup}
CARGO_HOME=${CARGO_HOME:-/home/omp/.cargo}

export RUST_TOOLCHAIN CARGO_AUDIT_VERSION CARGO_DENY_VERSION CARGO_NEXTEST_VERSION
export CARGO_LLVM_COV_VERSION RUSTUP_HOME CARGO_HOME

print_defaults() {
  printf 'RUST_TOOLCHAIN=%s\n' "$RUST_TOOLCHAIN"
  printf 'CARGO_AUDIT_VERSION=%s\n' "$CARGO_AUDIT_VERSION"
  printf 'CARGO_DENY_VERSION=%s\n' "$CARGO_DENY_VERSION"
  printf 'CARGO_NEXTEST_VERSION=%s\n' "$CARGO_NEXTEST_VERSION"
  printf 'CARGO_LLVM_COV_VERSION=%s\n' "$CARGO_LLVM_COV_VERSION"
  printf 'RUSTUP_HOME=%s\n' "$RUSTUP_HOME"
  printf 'CARGO_HOME=%s\n' "$CARGO_HOME"
}

tmpdir=

install_sdk() {
  : "${RUSTUP_HOME:?RUSTUP_HOME must be set}"
  : "${CARGO_HOME:?CARGO_HOME must be set}"
  : "${RUST_TOOLCHAIN:?RUST_TOOLCHAIN must be set}"

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

  install -d -m 0755 "$CARGO_HOME/bin"
  if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
      "$tmpdir/rustup-init" -y --no-modify-path --profile minimal \
      --default-toolchain "$RUST_TOOLCHAIN"
  fi

  "$CARGO_HOME/bin/rustup" toolchain install "$RUST_TOOLCHAIN" --profile minimal
  "$CARGO_HOME/bin/rustup" default "$RUST_TOOLCHAIN"
  "$CARGO_HOME/bin/rustup" component add --toolchain "$RUST_TOOLCHAIN" \
    rustfmt clippy rust-analyzer llvm-tools-preview
  "$CARGO_HOME/bin/rustup" target add --toolchain "$RUST_TOOLCHAIN" wasm32-wasip1
  chmod -R a-w "$RUSTUP_HOME"
  chown -R omp:omp "$CARGO_HOME"
}

clear_cargo_registry() {
  registry_dir="$CARGO_HOME/registry"
  if [ ! -d "$registry_dir" ] || [ -L "$registry_dir" ]; then
    printf 'Cargo registry path is missing or not a directory: %s\n' \
      "$registry_dir" >&2
    exit 1
  fi
  find "$registry_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}
assert_empty_cargo_registry() {
  registry_contents=$(find "$CARGO_HOME/registry" -mindepth 1 -print -quit)
  [ -z "$registry_contents" ] || {
    printf 'Rust setup left Cargo registry content: %s\n' \
      "$registry_contents" >&2
    exit 1
  }
}

install_tools() {
  : "${CARGO_HOME:?CARGO_HOME must be set}"
  : "${RUSTUP_HOME:?RUSTUP_HOME must be set}"
  : "${CARGO_AUDIT_VERSION:?CARGO_AUDIT_VERSION must be set}"
  : "${CARGO_DENY_VERSION:?CARGO_DENY_VERSION must be set}"
  : "${CARGO_NEXTEST_VERSION:?CARGO_NEXTEST_VERSION must be set}"
  : "${CARGO_LLVM_COV_VERSION:?CARGO_LLVM_COV_VERSION must be set}"
  if [ ! -x "$CARGO_HOME/bin/rustup" ] ||
    [ ! -d "$RUSTUP_HOME/toolchains" ]; then
    printf 'Rust SDK is not installed\n' >&2
    exit 1
  fi
  install -d -m 0755 "$CARGO_HOME/registry" "$CARGO_HOME/git" "$CARGO_HOME/bin"
  cargo install --locked --version "$CARGO_AUDIT_VERSION" cargo-audit
  cargo install --locked --version "$CARGO_DENY_VERSION" cargo-deny
  cargo install --locked --version "$CARGO_NEXTEST_VERSION" cargo-nextest
  cargo install --locked --version "$CARGO_LLVM_COV_VERSION" cargo-llvm-cov
  clear_cargo_registry
}

check_environment() {
  tmpdir=$(mktemp -d)

  toolchain_sysroot=$(rustc --print sysroot)
  for toolchain_path in "$RUSTUP_HOME" "$toolchain_sysroot"; do
    if [ ! -d "$toolchain_path" ] || [ -w "$toolchain_path" ]; then
      printf 'Rust toolchain path is missing or writable: %s\n' "$toolchain_path" >&2
      exit 1
    fi
  done
  case "$toolchain_sysroot" in
  "$RUSTUP_HOME"/toolchains/*) ;;
  *)
    printf 'Rust sysroot is outside RUSTUP_HOME: %s\n' "$toolchain_sysroot" >&2
    exit 1
    ;;
  esac
  if [ ! -x "$toolchain_sysroot/bin/rustc" ] ||
    [ -w "$toolchain_sysroot/bin/rustc" ]; then
    printf 'Rust compiler is missing or writable: %s\n' "$toolchain_sysroot/bin/rustc" >&2
    exit 1
  fi

  for writable_path in "$CARGO_HOME" "$CARGO_HOME/bin" \
    "$CARGO_HOME/registry" "$CARGO_HOME/git"; do
    if [ ! -d "$writable_path" ] || [ ! -w "$writable_path" ]; then
      printf 'Cargo directory is missing or not writable: %s\n' "$writable_path" >&2
      exit 1
    fi
    probe="$writable_path/.ompact-write-test"
    touch "$probe"
    rm -f "$probe"
  done

  rustc --version
  cargo --version
  rustfmt --version
  cargo clippy --version
  rust-analyzer --version
  cargo-audit --version
  cargo-deny --version
  cargo-nextest --version
  cargo llvm-cov --version

  rust_source="$tmpdir/main.rs"
  printf '%s\n' 'fn main() { println!("rust-ok"); }' >"$rust_source"
  rustc "$rust_source" -o "$tmpdir/rust-check"
  [ "$("$tmpdir/rust-check")" = rust-ok ]
  rustc --target wasm32-wasip1 "$rust_source" -o "$tmpdir/rust-check.wasm"
  [ -s "$tmpdir/rust-check.wasm" ]

  coverage_dir="$tmpdir/coverage"
  mkdir -p "$coverage_dir/src"
  cat >"$coverage_dir/Cargo.toml" <<'EOF'
[package]
name = "ompact-coverage-check"
version = "0.1.0"
edition = "2021"
EOF
  cat >"$coverage_dir/src/lib.rs" <<'EOF'
pub fn answer() -> u32 {
    42
}

#[cfg(test)]
mod tests {
    #[test]
    fn answer_is_available() {
        assert_eq!(super::answer(), 42);
    }
}
EOF
  assert_empty_cargo_registry
  if ! (
    cd "$coverage_dir"
    CARGO_NET_OFFLINE=true cargo llvm-cov --json --summary-only \
      --output-path "$tmpdir/coverage-report.json"
  ) >"$tmpdir/coverage-output" 2>&1; then
    cat "$tmpdir/coverage-output" >&2
    exit 1
  fi
  if [ ! -s "$tmpdir/coverage-report.json" ] ||
    ! grep -F 'src/lib.rs' "$tmpdir/coverage-report.json" >/dev/null; then
    printf 'cargo llvm-cov did not report coverage for src/lib.rs\n' >&2
    cat "$tmpdir/coverage-output" >&2
    exit 1
  fi
  assert_empty_cargo_registry
}

trap 'rm -rf -- "$tmpdir"' 0
trap 'exit 1' 1 2 3 15

case "${1:-}" in
defaults)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install-sdk|install-tools|check\n' "$0" >&2
    exit 2
  }
  print_defaults
  ;;
install-sdk)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install-sdk|install-tools|check\n' "$0" >&2
    exit 2
  }
  install_sdk
  ;;
install-tools)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install-sdk|install-tools|check\n' "$0" >&2
    exit 2
  }
  install_tools
  ;;
check)
  [ "$#" -eq 1 ] || {
    printf 'usage: %s defaults|install-sdk|install-tools|check\n' "$0" >&2
    exit 2
  }
  check_environment
  ;;
*)
  printf 'usage: %s defaults|install-sdk|install-tools|check\n' "$0" >&2
  exit 2
  ;;
esac
