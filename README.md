# ompact

`ompact` packages a Linux build of `oh-my-pi` (`omp`) as a host-native
`smolvm` single-file executable. It boots the embedded VM and runs
`/usr/local/bin/omp` by default.

## Requirements

| Phase | Requirements |
| --- | --- |
| Build | macOS arm64, network access, a preinstalled `smolvm` CLI, and `mkfs.ext4` on `PATH`. |
| macOS graphics | Homebrew `libepoxy` and `virglrenderer` runtime libraries. Install `e2fsprogs`, `startergo/virglrenderer/virglrenderer`, and its tap dependencies (`startergo/angle`, `startergo/gn`, and `startergo/libepoxy`). Add e2fsprogs' `sbin` directory to `PATH`. |
| Runtime | A host supported by `smolvm`; the artifact is not a portable macOS application. |

## Build

```sh
make build
make build ENVIRONMENTS=rust,go
```

The build creates a disposable builder VM, runs the selected environment
scripts and `Smolfile` bootstrap, verifies the guest inputs, and writes
`ompact` in the repository root. `make check` runs the repository checks;
`make smoke` builds the artifact and runs its runtime test.

## Configuration

`Smolfile` is the source of truth for the guest and packaged artifact:

| Setting | Purpose |
| --- | --- |
| `env` | Shared guest environment defaults. |
| `init` | Ordered bootstrap commands for packages, tools, and the `omp` launcher. |
| `image` | Debian base image pin. |
| `cpus`, `memory` | Default builder and packaged VM resources. |
| `net` | Default networking; disabled for packaged runtime by default. |
| `[artifact]` | Packaged VM resources, entrypoint, and command marker. |

Mutable versions, checksums, and installer details live in `Smolfile` and
the selected `env/*.sh` scripts. The base bootstrap includes `omp`, `jj`,
`fd`, `rg`, `sd`, `ast-grep`, and `gh`; environment scripts own
language-specific tools and caches. The daily `update-omp` workflow opens
or updates a pull request for newer `omp` releases, runs `Check`, and
enables auto-merge after it succeeds.

Update an input in its owning file, then run `make check`.

## Environments

The first `build.sh` argument selects comma-separated environment names.
`make build ENVIRONMENTS=rust,go` passes the same list to the script.

| Script command | Responsibility |
| --- | --- |
| `defaults` | Print build-time `KEY=VALUE` defaults. |
| `install` | Install the compiler and environment tools. |
| `check` | Verify the tools and run a minimal probe. |

Add an executable `env/<name>.sh` implementing those commands. Selected
scripts are mounted read-only into the builder, where they install their
tools; omitted environments do not provide their compiler, tools, or caches.
The scripts are not runtime dependencies of the packaged executable.

## Build overrides

| Variable | Effect |
| --- | --- |
| `OUTPUT` | Output path; defaults to `ompact` in the repository root. |
| `CPUS` | Overrides builder and packaged VM vCPU defaults. |
| `MEMORY` | Overrides builder and packaged VM memory defaults. |
| `ENVIRONMENTS` | Makefile-only comma-separated environment list. |

Environment scripts may define additional variables. Their defaults and
override syntax remain script-specific.

```sh
CPUS=8 MEMORY=16384 OUTPUT=/path/to/ompact ./build.sh rust,go
```

Each build starts from scratch, removes its disposable builder, and replaces
only its owned regular output file. Existing directories, sidecars, and
unexpected output files cause the build to abort.

## Run

Runtime networking is disabled by default. Mount a workspace and writable
OMP state directory; add `--net` only when the workload needs network access:

```sh
mkdir -p "$HOME/.omp"
./ompact run -it --net \
  -v "$PWD:/workspace" \
  -v "$HOME/.omp:/home/omp/.omp" \
  -- /usr/local/bin/omp
```

Model credentials are launch-time inputs supplied with `-e` or smolvm's
secret mechanism. They are not embedded in the artifact.

The active agent directory can be checked with the same state mount:

```sh
./ompact run \
  -v "$HOME/.omp:/home/omp/.omp" \
  -- /usr/local/bin/omp --no-session config path
```

`omp config path` is authoritative when a profile or
`PI_CODING_AGENT_DIR` changes the location. Mount the directory, not an
individual config file, and keep it writable. Mount only dependency caches
declared by selected environment scripts; project dependencies still need
network access unless cached.

## Security

| Concern | Behavior |
| --- | --- |
| Runtime identity | The wrapper runs workloads as the non-root `omp` user. Explicit guest commands that bypass the wrapper are outside this guarantee. |
| State mounts | `$HOME/.omp` exposes authentication, sessions, and runtime state. Use a dedicated writable directory owned by a non-root host user; root-owned `0700` sources are rejected. |
| Network | `build.sh` enables networking only for the temporary builder. Runtime callers opt in with `--net`; this is not an external no-network guarantee. |
| Credentials | Credentials and secrets are supplied at launch and are not stored in the host executable, image, or build script. |

## Packaging

The build uses `smolvm pack create --single-file` and produces one executable
without a `.smolmachine` sidecar. Redistribute and replace that executable
as a whole. The format does not make the package host-independent or persist
runtime state; macOS may also require additional notarization work.

The artifact bundles third-party software (Debian packages, `omp`, `jj`,
`fd`, `rg`, `gh`, `sd`, `ast-grep`, uv, and toolchain components) governed
by their own upstream licenses; this repository's MIT license covers only
the packaging code in this repository.
