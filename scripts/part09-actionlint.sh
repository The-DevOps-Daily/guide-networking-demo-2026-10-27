#!/usr/bin/env bash
# Part 9: lint the example workflow.
set -uo pipefail
cd "$(dirname "$0")/../part09"
source ../scripts/lib.sh
capture p9-actionlint <<'CMD'
actionlint network.yml && echo "network.yml: no problems found"
CMD
