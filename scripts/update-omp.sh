#!/usr/bin/env bash

set -Eeuo pipefail

if (($# != 3 && $# != 4)); then
  printf 'usage: %s VERSION ARM64_SHA AMD64_SHA [ROOT]\n' "$0" >&2
  exit 2
fi

version="$1"
arm64_sha="$2"
amd64_sha="$3"
root="${4:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'update-omp: invalid version: %s\n' "$version" >&2
  exit 1
fi

for checksum in "$arm64_sha" "$amd64_sha"; do
  if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'update-omp: invalid checksum: %s\n' "$checksum" >&2
    exit 1
  fi
done

python3 - "$root" "$version" "$arm64_sha" "$amd64_sha" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
arm64_sha = sys.argv[3]
amd64_sha = sys.argv[4]

contents = {}
for relative_path in ("Smolfile", "README.md", "tests/build.sh.test"):
    path = root / relative_path
    contents[path] = path.read_text()


def replace_once(path, text, pattern, replacement):
    matches = list(re.finditer(pattern, text, re.MULTILINE))
    if len(matches) != 1:
        raise SystemExit(
            f"update-omp: expected one match for {pattern!r} in {path}, found {len(matches)}"
        )
    match = matches[0]
    return text[: match.start()] + match.expand(replacement) + text[match.end() :]

smolfile = root / "Smolfile"
contents[smolfile] = replace_once(
    smolfile,
    contents[smolfile],
    r"omp_version=v[0-9]+\.[0-9]+\.[0-9]+",
    f"omp_version={version}",
)
contents[smolfile] = replace_once(
    smolfile,
    contents[smolfile],
    r"(^arm64\)\n  omp_binary=omp-linux-arm64\n  omp_sha256=)[0-9a-f]{64}$",
    rf"\g<1>{arm64_sha}",
)
contents[smolfile] = replace_once(
    smolfile,
    contents[smolfile],
    r"(^amd64\)\n  omp_binary=omp-linux-x64\n  omp_sha256=)[0-9a-f]{64}$",
    rf"\g<1>{amd64_sha}",
)

readme = root / "README.md"
contents[readme] = replace_once(
    readme,
    contents[readme],
    r"`omp` uses release `v[0-9]+\.[0-9]+\.[0-9]+`;",
    f"`omp` uses release `{version}`;",
)

test_file = root / "tests/build.sh.test"
test_text = contents[test_file]
sha_matches = list(re.finditer(r"omp_sha256=[0-9a-f]{64}", test_text))
if len(sha_matches) != 2:
    raise SystemExit(
        f"update-omp: expected two omp checksum assertions in {test_file}, found {len(sha_matches)}"
    )
replacements = iter((f"omp_sha256={arm64_sha}", f"omp_sha256={amd64_sha}"))
contents[test_file] = re.sub(
    r"omp_sha256=[0-9a-f]{64}",
    lambda _: next(replacements),
    test_text,
)
contents[test_file] = replace_once(
    test_file,
    contents[test_file],
    r"'omp_version=v[0-9]+\.[0-9]+\.[0-9]+'",
    f"'omp_version={version}'",
)

for path, text in contents.items():
    path.write_text(text)
PY
