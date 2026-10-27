#!/usr/bin/env bash
# Part 7: check the syntax of every cloud CLI command in the guide without credentials.
# Each CLI parses and validates its arguments before it looks for credentials, so reaching the
# "no credentials" error means the command line is valid. Nothing is sent to any cloud.
set -uo pipefail
cd "$(dirname "$0")/../part07"
export VPC=vpc-0123456789abcdef0 IGW=igw-0123456789abcdef0 NAT=nat-0123456789abcdef0 \
  PUB_A=subnet-0123456789abcdef0 APP_A=subnet-0123456789abcdef1 PUB_B=subnet-0123456789abcdef2 APP_B=subnet-0123456789abcdef3 DEMO_VPC=vpc-0123456789abcdef1 PUBLIC_RT=rtb-0123456789abcdef0 \
  PRIVATE_RT=rtb-0123456789abcdef1 LB_SG=sg-0123456789abcdef0 APP_SG=sg-0123456789abcdef1 \
  DB_SG=sg-0123456789abcdef2 NACL=acl-0123456789abcdef0 AWS_REGION=us-east-1 \
  FLOW_LOGS_ROLE_ARN=arn:aws:iam::123456789012:role/flow-logs APP_INSTANCE=i-0123456789abcdef0 \
  DB_INSTANCE=i-0123456789abcdef1 PATH_ID=nip-0123456789abcdef0 \
  ANALYSIS_ID=nia-0123456789abcdef0 FLOW_LOG=fl-0123456789abcdef0 S3_ENDPOINT=vpce-0123456789abcdef0
export AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE DIGITALOCEAN_ACCESS_TOKEN
export CLOUDSDK_CONFIG="$(mktemp -d)" AZURE_CONFIG_DIR="$(mktemp -d)"

aws --version; gcloud --version 2>/dev/null | head -n 1; az version --output tsv 2>/dev/null | head -n 1; doctl version
fail=0
while IFS= read -r cmd; do
  out=$(timeout 120 bash -c "$cmd" 2>&1 </dev/null)
  case "$cmd" in
    aws*) ok='Unable to locate credentials' ;;
    gcloud*) ok='do not currently have an active account|gcloud auth login' ;;
    az*) ok="az login" ;;
    doctl*) ok='access token is required|Unable to initialize DigitalOcean API client' ;;
  esac
  if grep -q -E "$ok" <<<"$out"; then
    echo "ok    $cmd"
  else
    echo "FAIL  $cmd"
    echo "$out" | head -n 8 | sed 's/^/      /'
    fail=1
  fi
done < <(jq -r '.[]' commands.json)
exit "$fail"
