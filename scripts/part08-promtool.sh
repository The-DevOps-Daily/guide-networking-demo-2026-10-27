#!/usr/bin/env bash
# Part 8: validate the alert rules with promtool.
set -uo pipefail
cd "$(dirname "$0")/../part08"
source ../scripts/lib.sh
capture p8-promtool <<'CMD'
promtool check rules network-alerts.yml
CMD
finish
