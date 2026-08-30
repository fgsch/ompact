# ompact

## Purpose

`ompact` packages a Linux build of oh-my-pi (`omp`) as one host-native
smolvm executable. Running the executable boots its embedded VM and uses
`/usr/local/bin/omp` as the default workload.

## Requirements and host/architecture limitation

Build on a macOS arm64 host with network access, and `mkfs.ext4`
available on `PATH`, plus the matching Homebrew `libepoxy` and
`virglrenderer` runtime libraries for the packaged smoke boot. On macOS,
install the prerequisites with `brew install e2fsprogs`, then install
`startergo/virglrenderer/virglrenderer` and its tap dependencies
(`startergo/angle`, `startergo/gn`, and `startergo/libepoxy`); add
e2fsprogs' `sbin` directory to `PATH` (for example,
`/opt/homebrew/opt/e2fsprogs/sbin`). The script requires a preinstalled
smolvm CLI; it builds a disposable Debian VM with networking. The
generated launcher is host-native; use it only on compatible hosts
supported by smolvm. The embedded guest payload is not a portable macOS
application.

## Build

```sh
./build.sh
```

The build uses the preinstalled smolvm CLI and `Smolfile`, creates the
disposable `omp-package-builder` VM, runs the Smolfile bootstrap
commands, verifies the pinned Linux `omp` binary, and emits `ompact` in
this directory.

## Repeatable rebuild/tuning variables

`Smolfile` is the source of truth for the shared guest build and
artifact configuration:

- top-level `env` - shared guest environment defaults, currently the
  executable search path
- top-level `init` - ordered guest bootstrap commands for runtime
  packages, native build prerequisites, and the omp launcher
- `image` - pinned Debian base image
  (`debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132`)
- `cpus` - builder VM CPUs (default `4`)
- `memory` - builder VM memory in MiB (default `8192`)
- `net` - default networking for machines and packed artifacts; this is
  `false` here so runtime starts offline
- `[artifact].cpus` - packaged VM CPUs (default `4`)
- `[artifact].memory` - packaged VM memory in MiB (default `8192`)
- `[artifact].entrypoint` - packaged default workload
  (`/usr/local/bin/omp`)
- `[artifact].cmd` - packaged default argument marker (`--`), which
  overrides Debian's inherited `bash` command

### Pinned build inputs

The default build pins the mutable external inputs used during
bootstrap:

- Debian package indexes use the signed `snapshot.debian.org` archive at
  `20260820T000000Z`.
- `omp` uses release `v18.0.11`; the architecture-specific Linux binaries
  are verified against SHA-256 checksums in `Smolfile`.
- A daily GitHub Actions workflow checks for newer `omp` releases, verifies
  both binaries, opens or updates a pull request, runs the repository
  `check` workflow, and enables auto-merge after it succeeds.
- `fd` `v10.5.0` and `ripgrep` `15.2.0` use pinned upstream
  Linux musl archives and are installed as `/usr/local/bin/fd` and
  `/usr/local/bin/rg`.
- `sd` `v1.1.0` and `ast-grep` `0.45.2` use pinned upstream Linux
  archives and are installed as `/usr/local/bin/sd` and
  `/usr/local/bin/sg`.
- `gh` uses release `v2.98.0`; the architecture-specific Linux archives
  are verified against SHA-256 checksums and installed as
  `/usr/local/bin/gh`.
- The base image includes Debian trixie `python3` and its `python` alias;
  `env/python.sh` adds uv `0.12.7` and its cache configuration.
- `env/go.sh` installs `golangci-lint` `v2.13.2` alongside its other
  pinned Go tools.
- Environment scripts own the versions and verification of the external
  installers and toolchain artifacts they download; downloaded artifacts
  are checked against checksums where available.

When updating one of these inputs, update its version, digest, or
checksum in the owning `Smolfile` or environment script as one change
and rerun `make check`.

The first positional argument to `build.sh` selects one or more language
environments. Run `./build.sh` with no argument for no language
environment, `./build.sh <name>` for one environment, or `./build.sh
<name>,<name>` for multiple environments. Each name resolves to
`env/<name>.sh`; adding an environment requires only adding that
executable script and passing its name. Excluding an environment omits
its compiler, language-specific tools, and dependency caches. Native
build prerequisites remain available in every variant.

The build reports the selected environment names before creating the
temporary builder, or reports `no environments selected` when none are
requested.

### Adding an environment

Add an executable `env/<name>.sh` script. It must support these commands:

- `defaults` - print one `KEY=VALUE` pair per line for build-time
  defaults.
- `install` - install the compiler, toolchain, and language-specific
  tools in the builder VM.
- `check` - verify the installed tools and compile/run a minimal probe.

`build.sh` runs `defaults` on the host to collect environment variables,
then mounts the script read-only and runs `install` and `check` inside
the guest.  The script should use `/bin/sh`, return non-zero on failure,
and keep its configuration generic enough for host overrides. Build it
with `./build.sh <name>` or `make build ENVIRONMENTS=<name>`.

Each environment script owns its defaults and may expose variables for
build-time customization. `build.sh` passes the selected script's
declared defaults and host overrides through to the builder without
prescribing variable names or semantics; environment-specific
configuration remains owned by that script.

Environment scripts in `env/` are build-time inputs. `build.sh` mounts
the `env/` directory read-only while creating and validating the
builder, runs only the selected scripts, removes that mount before
packing, and mounts it only temporarily for post-pack validation. The
scripts are not runtime dependencies of the resulting single-file
executable.

Environment-specific tools are installed by their selected scripts;
project dependencies remain project inputs.

Edit `Smolfile` to change the image, resources, bootstrap, shared
defaults, or packaged entrypoint. `build.sh` supports these host-side
variables:

- `OUTPUT` (default `$PROJECT_ROOT/ompact`, where `PROJECT_ROOT` is the
  repository root containing `build.sh`)
- `CPUS` (default `4` from `Smolfile`; when defined, overrides builder
  and packaged VM vCPU defaults)
- `MEMORY` (default `8192` MiB from `Smolfile`; when defined, overrides
  builder and packaged VM memory defaults)
- Variables declared by selected `env/<name>.sh` scripts (defaults and
  accepted override syntax are defined by those scripts)

Selected environment scripts may consume additional host variables;
unspecified values use their script-defined defaults. When defined,
`CPUS` and `MEMORY` override the builder and packaged VM resource
defaults; omitted resource values remain the corresponding `Smolfile`
defaults. Environment scripts decide whether their overrides are
reproducible or resolve rolling releases.

For example:

```sh
CPUS=8 MEMORY=16384 \
OUTPUT=/path/to/ompact ./build.sh <environment-list>
```

Rerunning the script rebuilds from scratch and replaces only its owned
regular output executable. Each invocation generates a unique builder VM
name and removes that VM on success or failure. Directories, unexpected
output sidecars, and the legacy `/tmp/ompact.smolmachine` sidecar cause
the build to abort rather than be deleted.

`Smolfile` keeps the packaged runtime offline by default. `build.sh`
adds `--net` only to the temporary builder because its bootstrap
downloads packages and toolchains. Pass `--net` to `ompact run` when the
workload needs internet access; omit it for local-only workloads. This
is a default, not a hard security policy: a caller who can launch the
artifact can still pass `--net`, so enforce a no-network guarantee
outside the artifact if required.

## Run with workspace/network/credentials

The builder's network access is enabled by `build.sh` for dependency
downloads. At runtime, `run` remains ephemeral: mount a workspace, the
complete writable omp state directory, and request network access
explicitly when the workload needs it:

```sh
cd /Users/fgsch/foss/ompact
./build.sh <environment-list>
mkdir -p "$HOME/.omp"
./ompact run -it --net \
  -v "$PWD:/workspace" \
  -v "$HOME/.omp:/home/omp/.omp" \
  -- /usr/local/bin/omp
```

For example, an artifact built with `./build.sh rust,go` can reuse these
host cache directories:

```sh
mkdir -p "$HOME/.cache/ompact"/{cargo-registry,cargo-git,go-mod,go-build}
mkdir -p "$HOME/.omp"
./ompact run \
  -v "$HOME/.cache/ompact/cargo-registry:/usr/local/cargo/registry" \
  -v "$HOME/.cache/ompact/cargo-git:/usr/local/cargo/git" \
  -v "$HOME/.cache/ompact/go-mod:/var/cache/go-mod" \
  -v "$HOME/.cache/ompact/go-build:/var/cache/go-build" \
  -v "$HOME/.omp:/home/omp/.omp" \
  -- /usr/local/bin/omp
```

The writable `$HOME/.omp` mount maps host `$HOME/.omp/agent/config.yml`
(or an existing `config.yaml`) to guest
`/home/omp/.omp/agent/config.yml` (or `config.yaml`). The `agent`,
`logs`, `run`, and other files below `$HOME/.omp` persist across
ephemeral runs. `omp config set`, `omp config reset`, and settings-panel
writes survive because they write through the host directory.

Verify the active agent directory with the same writable state mount:

```sh
./ompact run \
  -v "$HOME/.omp:/home/omp/.omp" \
  -- /usr/local/bin/omp --no-session config path
# /home/omp/.omp/agent
```

`omp config path` is authoritative if a profile or `PI_CODING_AGENT_DIR`
changes the active agent directory. A custom location must still be
mounted to a writable guest path visible to the wrapper. SmolVM `-v`
mounts directories only: the host source must exist before launch, and a
single config file cannot be mounted. Omit `:ro`; omp may initialize or
update its SQLite agent state, and a read-only mount can fail before
config commands run.

Optional dependency and build caches are environment-defined runtime
attachments. Do not mount them over installed tool paths. Consult each
selected `env/<name>.sh` script's defaults for the guest cache paths,
create matching host directories, and mount only caches for environments
selected at build time. Omit caches for unselected environments. Project
dependencies still require network access unless already cached.

Provide model credentials with `-e` or smolvm's supported secret
mechanism at launch. Add only the environment variables or secrets
required by your omp setup; credentials are not supplied by the package.

## Security note

The image/bootstrap phase runs as root for package installation and
writes to `/usr/local` and `/var/cache`; omp itself does not require
root. Normal `/usr/local/bin/omp` launches drop to the non-root `omp`
workload identity. Explicit guest commands that bypass
`/usr/local/bin/omp` are outside this runtime-user guarantee.

Mounting `$HOME/.omp` exposes every file below that directory, not only
`config.yml`, including omp authentication, session, and runtime state.
Users who want isolated state should mount a dedicated host directory
owned by a non-root host user. A root-owned `0700` source is rejected by
the wrapper.

Credentials are launch-time inputs only and are not embedded in the host
executable, guest image, or build script. Cache mounts are mutable host
state; review their contents and mount paths before launch. Selected
environment binaries remain in the paths declared by their scripts;
omitted environments are not available. Review workspace mounts,
explicit network access, and any `-e` values before launching the
package.

## Packaging format

The build uses `smolvm pack create --single-file`, producing one
executable with no `.smolmachine` sidecar. Redistribute and replace that
executable as a whole. The single-file format simplifies distribution
but does not make the package host-independent or persist runtime state.
smolvm also warns that single-file packages may require additional macOS
notarization work; use the non-single-file executable-plus-sidecar
format if that better fits the release pipeline.
