# Helpers for the guide runs.
#
# capture NAME [EXPECTED_EXIT_CODE] <<'CMD' ... CMD
#   Runs the command from stdin in the current shell (cd and variables carry over), saves its
#   combined output to captures/NAME.txt, and the command, exit code and time to captures/NAME.json.
#   The guide's build refuses a capture whose recorded command differs from the command it shows.
#   An exit code other than the expected one (default 0) makes the script fail at "finish".
# finish
#   Ends a capture script: exits 1 if any capture had an unexpected exit code.
# must COMMAND...
#   A setup step that the guide does not show. The job fails if it fails.

CAP_DIR="${CAP_DIR:-$PWD/captures}"
mkdir -p "$CAP_DIR"

CAPTURE_FAILED=0

capture() {
  local name=$1 expected=${2:-0} cmd rc started
  cmd=$(cat)
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  eval "$cmd" >"$CAP_DIR/$name.txt" 2>&1 </dev/null
  rc=$?
  jq -n --arg cmd "$cmd" --argjson rc "$rc" --arg at "$started" --arg run_id "${GITHUB_RUN_ID:-local}" \
    '{cmd: $cmd, rc: $rc, at: $at, run_id: $run_id}' >"$CAP_DIR/$name.json"
  printf '::group::%s (exit %s)\n$ %s\n' "$name" "$rc" "$cmd"
  cat "$CAP_DIR/$name.txt"
  echo '::endgroup::'
  if [ "$rc" -ne "$expected" ]; then
    echo "::error::capture $name exited $rc, expected $expected"
    CAPTURE_FAILED=1
  fi
}

finish() {
  exit "$CAPTURE_FAILED"
}

must() {
  echo "+ $*"
  if ! eval "$*"; then
    echo "::error::setup step failed: $*"
    exit 1
  fi
}
