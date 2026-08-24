#!/bin/sh

set -eu

GO_VERSION=${GO_VERSION:-go1.27.0}
GOPLS_VERSION=${GOPLS_VERSION:-0.23.0}
GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION:-1.7.0}
STATICCHECK_VERSION=${STATICCHECK_VERSION:-0.8.1}
GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION:-2.13.2}
GOBIN=${GOBIN:-/usr/local/bin}
GOMODCACHE=${GOMODCACHE:-/var/cache/go-mod}
GOCACHE=${GOCACHE:-/var/cache/go-build}

export GO_VERSION GOPLS_VERSION GOVULNCHECK_VERSION STATICCHECK_VERSION
export GOLANGCI_LINT_VERSION GOBIN GOMODCACHE GOCACHE

tmpdir=

print_defaults() {
  printf 'GO_VERSION=%s\n' "$GO_VERSION"
  printf 'GOPLS_VERSION=%s\n' "$GOPLS_VERSION"
  printf 'GOVULNCHECK_VERSION=%s\n' "$GOVULNCHECK_VERSION"
  printf 'STATICCHECK_VERSION=%s\n' "$STATICCHECK_VERSION"
  printf 'GOLANGCI_LINT_VERSION=%s\n' "$GOLANGCI_LINT_VERSION"
  printf 'GOBIN=%s\n' "$GOBIN"
  printf 'GOMODCACHE=%s\n' "$GOMODCACHE"
  printf 'GOCACHE=%s\n' "$GOCACHE"
}

install_environment() {
  : "${GO_VERSION:?GO_VERSION must be set}"
  : "${GOBIN:?GOBIN must be set}"
  : "${GOPLS_VERSION:?GOPLS_VERSION must be set}"
  : "${GOVULNCHECK_VERSION:?GOVULNCHECK_VERSION must be set}"
  : "${STATICCHECK_VERSION:?STATICCHECK_VERSION must be set}"
  : "${GOLANGCI_LINT_VERSION:?GOLANGCI_LINT_VERSION must be set}"
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
  if [ -x /usr/local/go/bin/go ]; then
    installed_go_version=$(/usr/local/go/bin/go version)
  else
    need_go_install=1
  fi
  if [ ! -x /usr/local/go/bin/gofmt ]; then
    need_go_install=1
  else
    case "$installed_go_version" in
    *"go version $go_version "*) ;;
    *) need_go_install=1 ;;
    esac
  fi
  if [ "$need_go_install" -eq 1 ]; then
    archive_path="$tmpdir/$archive_name"
    curl -fsSLo "$archive_path" "https://go.dev/dl/$archive_name"
    printf '%s  %s\n' "$archive_sha256" "$archive_path" | sha256sum -c -
    rm -rf /usr/local/go
    tar -xzf "$archive_path" -C /usr/local
    rm -f "$archive_path"
  fi

  install -d -m 0755 "$GOBIN"
  GOBIN="$GOBIN" go install "golang.org/x/tools/gopls@v$GOPLS_VERSION"
  GOBIN="$GOBIN" go install "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK_VERSION"
  GOBIN="$GOBIN" go install "honnef.co/go/tools/cmd/staticcheck@v$STATICCHECK_VERSION"
  GOBIN="$GOBIN" go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v$GOLANGCI_LINT_VERSION"
  install -d -m 0777 "$GOMODCACHE" "$GOCACHE"
}

check_environment() {
  tmpdir=$(mktemp -d)

  go version
  gopls version
  govulncheck -version
  staticcheck -version
  golangci-lint --version

  go_dir="$tmpdir/go"
  mkdir "$go_dir"
  cd "$go_dir"
  export GOPROXY=off
  go mod init example.com/ompact
  printf '%s\n' 'package main' '' 'import "fmt"' '' 'func main() { fmt.Println("go-ok") }' >main.go
  gofmt -w main.go
  go vet ./...
  go build -o "$tmpdir/go-check" .
  [ "$("$tmpdir/go-check")" = go-ok ]
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
