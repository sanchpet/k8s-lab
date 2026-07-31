# shellcheck shell=bash
# Resolution of the three axes. Sourced by the tasks in mise-tasks/.
#
# A scenario declares which envs it runs on; an env declares its method. Every verb
# resolves through those declarations instead of naming a method itself — otherwise
# the axes quietly collapse into a tree, where each scenario owns one blessed cluster
# and swapping the method means editing the scenario.

# shellcheck source-path=SCRIPTDIR source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DEFAULT_ENV=onprem-kubeadm

env_method() {
  local env_name=$1 conf="$REPO_ROOT/envs/$1/env.conf"
  [ -f "$conf" ] || die "env '$env_name' has no env.conf — it declares no method"
  # shellcheck source=/dev/null
  ( . "$conf"; printf '%s' "${METHOD:?env.conf of $env_name sets no METHOD}" )
}

scenario_envs() {
  local name=$1 conf="$REPO_ROOT/scenarios/$1/scenario.conf"
  [ -f "$conf" ] || die "scenario '$name' has no scenario.conf — it declares no env"
  # shellcheck source=/dev/null
  ( . "$conf"; printf '%s' "${ENVS:?scenario.conf of $name sets no ENVS}" )
}

# Fidelity is a precondition, not a preference: running a scenario on an env it
# never claimed yields a green result that means nothing.
assert_supported() {
  local name=$1 env_name=$2 e
  for e in $(scenario_envs "$name"); do
    [ "$e" != "$env_name" ] || return 0
  done
  die "scenario '$name' does not declare env '$env_name' (declares: $(scenario_envs "$name"))"
}

method_verb() {
  local verb=$1 env_name=${2:-$DEFAULT_ENV} method script
  [ -d "$REPO_ROOT/envs/$env_name" ] || die "unknown env: $env_name (see $REPO_ROOT/envs/)"
  method=$(env_method "$env_name")
  script="$REPO_ROOT/methods/$method/$verb.sh"
  [ -x "$script" ] || die "method '$method' does not implement '$verb' ($script)"
  "$script" "$env_name"
}

# Scenario scripts receive a kubeconfig, the env's parameters and a way to side-load
# images — and nothing else. They must never learn which method built the cluster.
scenario_context() {
  local name=$1 env_name=${2:-} method
  [ -d "$REPO_ROOT/scenarios/$name" ] || die "unknown scenario: $name (see $REPO_ROOT/scenarios/)"
  [ -n "$env_name" ] || env_name=$(scenario_envs "$name" | awk '{print $1}')
  assert_supported "$name" "$env_name"

  load_env
  : "${CLUSTER_NAME:?CLUSTER_NAME must be set}"
  local kubeconfig="$REPO_ROOT/kubeconfig-$CLUSTER_NAME"
  [ -f "$kubeconfig" ] || die "no kubeconfig for '$CLUSTER_NAME' — run: mise run up $env_name"

  method=$(env_method "$env_name")
  export KUBECONFIG="$kubeconfig" LAB_ENV="$env_name" LAB_SCENARIO_DIR="$REPO_ROOT/scenarios/$name"
  if [ -x "$REPO_ROOT/methods/$method/load-image.sh" ]; then
    export LAB_LOAD_IMAGE="$REPO_ROOT/methods/$method/load-image.sh"
  fi
  printf '%s' "$env_name"
}
