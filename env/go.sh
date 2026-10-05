#!/bin/sh

set -eu

GO_VERSION=${GO_VERSION:-go1.27.1}
GOPLS_VERSION=${GOPLS_VERSION:-0.23.0}
GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION:-1.8.0}
STATICCHECK_VERSION=${STATICCHECK_VERSION:-0.8.1}
GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION:-2.14.0}
go_root=/usr/local/go

export GO_VERSION GOPLS_VERSION GOVULNCHECK_VERSION STATICCHECK_VERSION
export GOLANGCI_LINT_VERSION

tmpdir=

print_defaults() {
  printf 'GO_VERSION=%s\n' "$GO_VERSION"
  printf 'GOPLS_VERSION=%s\n' "$GOPLS_VERSION"
  printf 'GOVULNCHECK_VERSION=%s\n' "$GOVULNCHECK_VERSION"
  printf 'STATICCHECK_VERSION=%s\n' "$STATICCHECK_VERSION"
  printf 'GOLANGCI_LINT_VERSION=%s\n' "$GOLANGCI_LINT_VERSION"
}

install_sdk() {
  : "${GO_VERSION:?GO_VERSION must be set}"
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to install Go\n' >&2
    exit 1
  }

  go_arch=
  case "$(dpkg --print-architecture)" in
  arm64) go_arch=arm64 ;;
  amd64) go_arch=amd64 ;;
  *)
    echo "unsupported architecture for Go: $(dpkg --print-architecture)" >&2
    exit 1
    ;;
  esac

  tmpdir=$(mktemp -d)
  metadata="$tmpdir/go.json"
  curl -fsSLo "$metadata" "https://go.dev/dl/?mode=json"

  go_version=$GO_VERSION
  case "$go_version" in
  latest) go_version=$(jq -er 'first(.[] | select(.stable == true) | .version)' "$metadata") ;;
  go*) ;;
  [0-9]*) go_version=go$go_version ;;
  *)
    echo "invalid Go version: $GO_VERSION" >&2
    exit 1
    ;;
  esac

  archive_info=$(jq -er \
    --arg version "$go_version" --arg arch "$go_arch" \
    'first(.[] | select(.version == $version) | .files[] |
      select(.os == "linux" and .arch == $arch and .kind == "archive") |
      [.filename, .sha256] | @tsv)' "$metadata")
  IFS="$(printf '\t')" read -r archive_name archive_sha256 <<EOF
$archive_info
EOF
  [ -n "$archive_name" ] && [ -n "$archive_sha256" ]

  installed_go_version=
  need_go_install=0
  if [ -x "$go_root/bin/go" ]; then
    installed_go_version=$(XDG_CONFIG_HOME="$tmpdir/config" "$go_root/bin/go" version)
  else
    need_go_install=1
  fi
  if [ ! -x "$go_root/bin/gofmt" ]; then
    need_go_install=1
  else
    case "$installed_go_version" in
    *"go version $go_version "*) ;;
    *) need_go_install=1 ;;
    esac
  fi

  install -d -m 0755 "$(dirname "$go_root")"
  if [ "$need_go_install" -eq 1 ]; then
    archive_path="$tmpdir/$archive_name"
    curl -fsSLo "$archive_path" "https://go.dev/dl/$archive_name"
    printf '%s  %s\n' "$archive_sha256" "$archive_path" | sha256sum -c -
    rm -rf -- "$go_root"
    tar -xzf "$archive_path" -C "$(dirname "$go_root")"
    rm -f "$archive_path"
  fi
  chmod -R a-w "$go_root"
}

remove_install_path() {
  path_to_remove=$1
  if [ -L "$path_to_remove" ]; then
    rm -f -- "$path_to_remove"
  elif [ -e "$path_to_remove" ]; then
    chmod -R u+w -- "$path_to_remove"
    rm -rf -- "$path_to_remove"
  fi
}

cleanup_install_artifacts() {
  gopath=$("$go_root/bin/go" env GOPATH)
  gobin=$("$go_root/bin/go" env GOBIN)
  [ -n "$gobin" ] || gobin="$gopath/bin"
  gomodcache=$("$go_root/bin/go" env GOMODCACHE)
  gocache=$("$go_root/bin/go" env GOCACHE)
  [ "$gopath" = "$HOME/go" ] &&
    [ "$gobin" = "$gopath/bin" ] &&
    [ "$gomodcache" = "$gopath/pkg/mod" ] &&
    [ "$gocache" = "$HOME/.cache/go-build" ] || {
    printf 'Go install paths differ from the expected HOME defaults\n' >&2
    exit 1
  }

  for path in "$gopath"/* "$gopath"/.[!.]* "$gopath"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ "$path" = "$gobin" ] && continue
    remove_install_path "$path"
  done
  for path in "$HOME/.cache"/* "$HOME/.cache"/.[!.]* "$HOME/.cache"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    remove_install_path "$path"
  done
  install -d -m 0755 "$gomodcache" "$gocache"
}

assert_empty_directory() {
  empty_directory=$1
  contents=$(find "$empty_directory" -mindepth 1 -print -quit)
  [ -z "$contents" ] || {
    printf 'Go setup left unexpected content in %s: %s\n' \
      "$empty_directory" "$contents" >&2
    exit 1
  }
}



assert_go_install_layout() {
  gopath=$("$go_root/bin/go" env GOPATH)
  gobin=$("$go_root/bin/go" env GOBIN)
  [ -n "$gobin" ] || gobin="$gopath/bin"
  gomodcache=$("$go_root/bin/go" env GOMODCACHE)
  gocache=$("$go_root/bin/go" env GOCACHE)

  [ "$gopath" = "$HOME/go" ] &&
    [ "$gobin" = "$gopath/bin" ] &&
    [ "$gomodcache" = "$gopath/pkg/mod" ] &&
    [ "$gocache" = "$HOME/.cache/go-build" ] || {
    printf 'Go paths differ from the expected HOME defaults\n' >&2
    exit 1
  }

  for writable_path in \
    "$gopath" "$gobin" "$gopath/pkg" "$gomodcache" \
    "${gocache%/*}" "$gocache"; do
    [ -d "$writable_path" ] && [ -w "$writable_path" ] || {
      printf 'Go directory is missing or not writable: %s\n' "$writable_path" >&2
      exit 1
    }
  done

  unexpected_child=$(find "$gopath" -mindepth 1 -maxdepth 1 \
    ! -name bin ! -name pkg -print -quit)
  [ -z "$unexpected_child" ] || {
    printf 'Go setup left unexpected content in %s: %s\n' \
      "$gopath" "$unexpected_child" >&2
    exit 1
  }
  unexpected_child=$(find "$gopath/pkg" -mindepth 1 -maxdepth 1 \
    ! -name mod -print -quit)
  [ -z "$unexpected_child" ] || {
    printf 'Go setup left unexpected content in %s: %s\n' \
      "$gopath/pkg" "$unexpected_child" >&2
    exit 1
  }
  unexpected_child=$(find "${gocache%/*}" -mindepth 1 -maxdepth 1 \
    ! -name go-build -print -quit)
  [ -z "$unexpected_child" ] || {
    printf 'Go setup left unexpected content in %s: %s\n' \
      "${gocache%/*}" "$unexpected_child" >&2
    exit 1
  }
  assert_empty_directory "$gomodcache"
  assert_empty_directory "$gocache"
}

install_tools() {
  : "${GOPLS_VERSION:?GOPLS_VERSION must be set}"
  : "${GOVULNCHECK_VERSION:?GOVULNCHECK_VERSION must be set}"
  : "${STATICCHECK_VERSION:?STATICCHECK_VERSION must be set}"
  : "${GOLANGCI_LINT_VERSION:?GOLANGCI_LINT_VERSION must be set}"
  [ -x "$go_root/bin/go" ] || {
    printf 'Go SDK is not installed at %s\n' "$go_root" >&2
    exit 1
  }

  XDG_CONFIG_HOME="$HOME/.config"
  export XDG_CONFIG_HOME
  "$go_root/bin/go" telemetry off

  "$go_root/bin/go" install "golang.org/x/tools/gopls@v$GOPLS_VERSION"
  "$go_root/bin/go" install "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK_VERSION"
  "$go_root/bin/go" install "honnef.co/go/tools/cmd/staticcheck@v$STATICCHECK_VERSION"
  "$go_root/bin/go" install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v$GOLANGCI_LINT_VERSION"
  cleanup_install_artifacts
}

check_environment() {
  tmpdir=$(mktemp -d)

  for readonly_path in "$go_root" "$go_root/bin/go" "$go_root/bin/gofmt"; do
    [ -e "$readonly_path" ] && [ ! -w "$readonly_path" ] || {
      printf 'Go SDK path is missing or writable: %s\n' "$readonly_path" >&2
      exit 1
    }
  done
  XDG_CONFIG_HOME="$HOME/.config"
  export XDG_CONFIG_HOME
  telemetry_mode=$("$go_root/bin/go" env GOTELEMETRY)
  [ "$telemetry_mode" = off ] || {
    printf 'Go telemetry is not disabled: %s\n' "$telemetry_mode" >&2
    exit 1
  }

  assert_go_install_layout

  XDG_CACHE_HOME="$tmpdir/cache"
  GOMODCACHE="$tmpdir/go-mod-cache"
  GOCACHE="$tmpdir/go-build"
  GOPROXY=off
  export XDG_CACHE_HOME GOMODCACHE GOCACHE GOPROXY
  mkdir -p "$XDG_CACHE_HOME" "$GOMODCACHE" "$GOCACHE"
  go version
  gopls version
  govulncheck -version
  staticcheck -version
  golangci-lint --version

  go_dir="$tmpdir/go"
  mkdir "$go_dir"
  cd "$go_dir"
  go mod init example.com/ompact
  printf '%s\n' 'package main' '' 'import "fmt"' '' 'func main() { fmt.Println("go-ok") }' >main.go
  gofmt -w main.go
  go vet ./...
  go build -o "$tmpdir/go-check" .
  unset XDG_CACHE_HOME GOMODCACHE GOCACHE
  assert_go_install_layout
  [ "$("$tmpdir/go-check")" = go-ok ]
}

trap '[ -z "$tmpdir" ] || rm -rf -- "$tmpdir"' 0
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
