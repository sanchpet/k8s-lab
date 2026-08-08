# shellcheck shell=bash
# Sourced by every method wrapper. Not executable on its own.
# Kept bash 3.2 compatible: macOS ships /bin/bash 3.2 and the wrappers may run under it.

set -euo pipefail

# Anchor on this file, not on the caller's cwd or $0.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export REPO_ROOT

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# .env carries the site-specific values; .env.example is generic and safe to fall
# back to, so a fresh clone still boots — loudly, so nobody mistakes it for real config.
load_env() {
  local env_file="$REPO_ROOT/.env"
  if [ ! -f "$env_file" ]; then
    env_file="$REPO_ROOT/.env.example"
    log "WARNING: no .env found, falling back to .env.example — values are placeholders"
  fi
  [ -f "$env_file" ] || die "neither .env nor .env.example exists in $REPO_ROOT"

  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a

  # A mirror is one env's construction, not a property of every stand, so its
  # parameters are read when present and not demanded when absent. Requiring them
  # here would make every future env carry a registry mirror it does not have.
  # containerd addresses the mirror by ip:port; templates only ever see the pair.
  if [ -n "${MIRROR_CLUSTER_IP:-}" ] && [ -n "${MIRROR_PORT:-}" ]; then
    export MIRROR_ENDPOINT="${MIRROR_CLUSTER_IP}:${MIRROR_PORT}"
  fi
}

# render <template> <output>
# envsubst substitutes an unset variable with an empty string and exits 0, which
# yields a valid-looking manifest with a hole in it. Pre-check every ${VAR} the
# template mentions, and restrict envsubst to exactly those names.
render() {
  local tmpl=$1 out=$2
  [ -f "$tmpl" ] || die "template not found: $tmpl"

  local names name missing="" shell_format=""
  names=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tmpl" | tr -d '{}$' | sort -u)
  [ -n "$names" ] || die "no \${VAR} placeholders in $tmpl — is it really a template?"

  for name in $names; do
    if [ -z "${!name:-}" ]; then
      missing="$missing $name"
    fi
    shell_format="$shell_format\${$name}"
  done
  [ -z "$missing" ] || die "unset variables required by $tmpl:$missing"

  envsubst "$shell_format" <"$tmpl" >"$out"

  # Belt and braces: catches placeholder spellings the pre-check does not model.
  if grep -qF "\${" "$out"; then
    die "unsubstituted placeholders left in $out"
  fi
  log "rendered $(basename "$tmpl") -> $out"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "$cmd not found in PATH"
  done
}
