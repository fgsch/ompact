#!/bin/sh

set -eu

UV_VERSION=${UV_VERSION:-0.12.7}
UV_CACHE_DIR=${UV_CACHE_DIR:-/var/cache/uv}
UV_INSTALLER_SHA256=92e8554321e2bde08c9b1445dae47a65360f885274f31df51cdc2f9faa84e001

export UV_VERSION UV_CACHE_DIR

tmpdir=

print_defaults() {
  printf 'UV_VERSION=%s\n' "$UV_VERSION"
  printf 'UV_CACHE_DIR=%s\n' "$UV_CACHE_DIR"
}

install_environment() {
  : "${UV_VERSION:?UV_VERSION must be set}"
  : "${UV_CACHE_DIR:?UV_CACHE_DIR must be set}"

  tmpdir=$(mktemp -d)
  uv_install_script="$tmpdir/uv-install.sh"
  curl -fsSL -o "$uv_install_script" "https://astral.sh/uv/$UV_VERSION/install.sh"
  printf '%s  %s\n' "$UV_INSTALLER_SHA256" "$uv_install_script" | sha256sum -c -
  UV_NO_MODIFY_PATH=1 UV_UNMANAGED_INSTALL=/usr/local/bin \
    sh "$uv_install_script"

  install -d -m 0777 "$UV_CACHE_DIR"
}

check_environment() {
  uv --version
  python --version
  python3 --version
  [ "$(python -c 'print("python-ok")')" = python-ok ]
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
