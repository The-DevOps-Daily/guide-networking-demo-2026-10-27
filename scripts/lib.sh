# Helpers for the guide runs.
#
# capture NAME <<'CMD' ... CMD
#   Runs the command from stdin in the current shell (cd and variables carry over), saves its
#   combined output to captures/NAME.txt, and the command, exit code and time to captures/NAME.json.
#   The guide's build refuses a capture whose recorded command differs from the command it shows.
# must COMMAND...
#   A setup step that the guide does not show. The job fails if it fails.

CAP_DIR="${CAP_DIR:-$PWD/captures}"
mkdir -p "$CAP_DIR"

capture() {
  local name=$1 cmd rc started
  cmd=$(cat)
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  eval "$cmd" >"$CAP_DIR/$name.txt" 2>&1 </dev/null
  rc=$?
  jq -n --arg cmd "$cmd" --argjson rc "$rc" --arg at "$started" --arg run_id "${GITHUB_RUN_ID:-local}" \
    '{cmd: $cmd, rc: $rc, at: $at, run_id: $run_id}' >"$CAP_DIR/$name.json"
  printf '::group::%s (exit %s)\n$ %s\n' "$name" "$rc" "$cmd"
  cat "$CAP_DIR/$name.txt"
  echo '::endgroup::'
}

must() {
  echo "+ $*"
  if ! eval "$*"; then
    echo "::error::setup step failed: $*"
    exit 1
  fi
}
