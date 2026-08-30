#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${OUTPUT:-$PROJECT_ROOT/ompact}"
VM_NAME="omp-package-builder-$(date +%s)-$$"

OPTIONAL_RESOURCE_ARGS=()
for optional_name in CPUS MEMORY; do
  if [[ ${!optional_name+x} ]]; then
    case "$optional_name" in
    CPUS) OPTIONAL_RESOURCE_ARGS+=(--cpus "${!optional_name}") ;;
    MEMORY) OPTIONAL_RESOURCE_ARGS+=(--mem "${!optional_name}") ;;
    esac
  fi
done
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

export PATH="$HOME/.local/bin:$PATH"
command -v smolvm >/dev/null 2>&1 || die "smolvm is unavailable"
[[ -f "$PROJECT_ROOT/Smolfile" ]] || die "Smolfile is unavailable: $PROJECT_ROOT/Smolfile"
MACHINE_CREATE_STARTED=0
cleanup_machine() {
  if ((MACHINE_CREATE_STARTED)); then
    smolvm machine stop --name "$VM_NAME" >/dev/null 2>&1 || true
    smolvm machine delete --name "$VM_NAME" --force >/dev/null 2>&1 || true
  fi
}
trap cleanup_machine EXIT
trap 'cleanup_machine; exit 130' INT
trap 'cleanup_machine; exit 143' TERM

if [[ -L "$OUTPUT" || (-e "$OUTPUT" && ! -f "$OUTPUT") ]]; then
  die "output exists and is not a regular file: $OUTPUT"
fi
if [[ -e "$OUTPUT.smolmachine" || -L "$OUTPUT.smolmachine" ]]; then
  die "unexpected sidecar exists: $OUTPUT.smolmachine"
fi
if [[ -e /tmp/ompact.smolmachine || -L /tmp/ompact.smolmachine ]]; then
  die "unexpected legacy sidecar exists: /tmp/ompact.smolmachine"
fi

if (($# > 1)); then
  die "usage: $0 [environment[,environment...]]"
fi
ENVIRONMENTS="${1:-}"
SELECTED_ENVIRONMENTS=()
ENVIRONMENT_ARGS=()
ENVIRONMENT_KEYS=()
if [[ -n "$ENVIRONMENTS" ]]; then
  case "$ENVIRONMENTS" in
  ,* | *, | *,,*) die "environment selection contains an empty name" ;;
  esac
  IFS=',' read -r -a requested_environments <<<"$ENVIRONMENTS"
  for environment_name in "${requested_environments[@]}"; do
    [[ -n "$environment_name" ]] || die "environment selection contains an empty name"
    case "$environment_name" in
    */* | *\\*) die "environment name contains a path separator: $environment_name" ;;
    esac
    if ((${#SELECTED_ENVIRONMENTS[@]})); then
      for selected_environment in "${SELECTED_ENVIRONMENTS[@]}"; do
        [[ "$selected_environment" != "$environment_name" ]] ||
          die "environment selection contains a duplicate: $environment_name"
      done
    fi
    environment_script="$PROJECT_ROOT/env/$environment_name.sh"
    [[ -f "$environment_script" && ! -L "$environment_script" && -x "$environment_script" ]] ||
      die "unknown environment: $environment_name"
    defaults_output="$("$environment_script" defaults)"
    while IFS='=' read -r environment_key environment_value; do
      [[ "$environment_key" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
        die "invalid default variable from $environment_script: $environment_key"
      if ((${#ENVIRONMENT_KEYS[@]})); then
        for existing_key in "${ENVIRONMENT_KEYS[@]}"; do
          [[ "$existing_key" != "$environment_key" ]] ||
            die "environment defaults define a duplicate variable: $environment_key"
        done
      fi
      ENVIRONMENT_KEYS+=("$environment_key")
      ENVIRONMENT_ARGS+=(--env "$environment_key=$environment_value")
    done <<<"$defaults_output"
    SELECTED_ENVIRONMENTS+=("$environment_name")
  done
  printf 'environments selected: %s\n' "${SELECTED_ENVIRONMENTS[*]}"
else
  printf 'no environments selected\n'
fi
rm -f "$OUTPUT"
ENV_VOLUME_SPEC="$PROJECT_ROOT/env:/opt/ompact-env"
ENV_VOLUME_CREATE="$ENV_VOLUME_SPEC:ro"

MACHINE_CREATE_ARGS=(
  machine
  create
  --name "$VM_NAME"
  --smolfile "$PROJECT_ROOT/Smolfile"
  --net
)
if ((${#OPTIONAL_RESOURCE_ARGS[@]})); then
  MACHINE_CREATE_ARGS+=("${OPTIONAL_RESOURCE_ARGS[@]}")
fi
if ((${#ENVIRONMENT_ARGS[@]})); then
  MACHINE_CREATE_ARGS+=("${ENVIRONMENT_ARGS[@]}")
fi
if ((${#SELECTED_ENVIRONMENTS[@]})); then
  MACHINE_CREATE_ARGS+=(--volume "$ENV_VOLUME_CREATE")
fi
MACHINE_CREATE_STARTED=1
smolvm "${MACHINE_CREATE_ARGS[@]}"
smolvm machine start --name "$VM_NAME"
smolvm machine exec --name "$VM_NAME" -- /usr/local/bin/omp --version

if ((${#SELECTED_ENVIRONMENTS[@]})); then
  for environment_name in "${SELECTED_ENVIRONMENTS[@]}"; do
    smolvm machine exec --name "$VM_NAME" -- \
      /bin/sh "/opt/ompact-env/$environment_name.sh" install
    smolvm machine exec --name "$VM_NAME" -- \
      /bin/sh "/opt/ompact-env/$environment_name.sh" check
  done
fi

smolvm machine stop --name "$VM_NAME"
if ((${#SELECTED_ENVIRONMENTS[@]})); then
  smolvm machine update --name "$VM_NAME" --remove-volume "$ENV_VOLUME_SPEC"
fi

PACK_CREATE_ARGS=(
  pack
  create
  --from-vm "$VM_NAME"
  --smolfile "$PROJECT_ROOT/Smolfile"
)
if ((${#OPTIONAL_RESOURCE_ARGS[@]})); then
  PACK_CREATE_ARGS+=("${OPTIONAL_RESOURCE_ARGS[@]}")
fi
PACK_CREATE_ARGS+=(
  --single-file
  --output "$OUTPUT"
)
smolvm "${PACK_CREATE_ARGS[@]}"
test -x "$OUTPUT"
[[ ! -e "$OUTPUT.smolmachine" && ! -L "$OUTPUT.smolmachine" ]]
[[ ! -e /tmp/ompact.smolmachine && ! -L /tmp/ompact.smolmachine ]]
if ((${#SELECTED_ENVIRONMENTS[@]})); then
  for environment_name in "${SELECTED_ENVIRONMENTS[@]}"; do
    "$OUTPUT" run -v "$ENV_VOLUME_CREATE" -- \
      /bin/sh "/opt/ompact-env/$environment_name.sh" check
  done
fi
"$OUTPUT" run -- /usr/local/bin/omp --version
printf 'created %s\n' "$OUTPUT"
