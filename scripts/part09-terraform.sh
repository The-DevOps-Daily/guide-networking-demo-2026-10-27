#!/usr/bin/env bash
# Part 9: fmt, validate and plan the VPC with mock credentials (nothing is created).
set -uo pipefail
cd "$(dirname "$0")/../part09/terraform"
source ../../scripts/lib.sh
export TF_IN_AUTOMATION=1 TF_CLI_ARGS_plan="-no-color" TF_CLI_ARGS_init="-no-color" TF_CLI_ARGS_validate="-no-color"
capture p9-tf-init <<'CMD'
terraform init -input=false
CMD
capture p9-tf-validate <<'CMD'
terraform fmt -check && terraform validate
CMD
capture p9-tf-plan <<'CMD'
terraform plan -input=false -out=tfplan | grep -E '^  # |^Plan:'
CMD
