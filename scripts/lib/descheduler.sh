# shellcheck shell=bash
# Build descheduler binaries from source, for scenarios that run the process on the
# host against a stand's kubeconfig. Sourced; needs common.sh loaded first.
#
# Built rather than pulled: a scenario has to run a tag, a fork branch and an older
# release side by side, and the official image only offers the first. The host
# process also gives the checks its exit status, CPU time and stderr directly, which
# a pod would only give through the kubelet.

# build_descheduler <repo> <ref> — prints the path of a binary built from that ref.
#
# The cache is keyed by commit, not by ref: a branch that moved gets a new binary and
# a tag that did not gets none.
build_descheduler() {
  local repo=$1 ref=$2
  require_cmd git go tar
  local cache="$REPO_ROOT/.cache/descheduler" sha bin dir
  mkdir -p "$cache/bin"
  [ -d "$cache/src/.git" ] || git init -q "$cache/src"

  git -C "$cache/src" fetch -q --depth 1 "$repo" "$ref" 2>/dev/null \
    || die "cannot fetch '$ref' from $repo"
  sha=$(git -C "$cache/src" rev-parse FETCH_HEAD)
  bin="$cache/bin/descheduler-$sha"

  if [ ! -x "$bin" ]; then
    log "building descheduler $ref (${sha:0:9})"
    dir=$(mktemp -d)
    git -C "$cache/src" archive FETCH_HEAD | tar -x -C "$dir"
    # The release is vendored, so the build needs no network.
    (cd "$dir" && CGO_ENABLED=0 go build -o "$bin" ./cmd/descheduler) \
      || { rm -rf "$dir"; die "build of $ref failed"; }
    rm -rf "$dir"
  fi
  printf '%s' "$bin"
}
