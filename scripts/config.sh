#!/usr/bin/env bash
#
# Shared configuration for all deploy/teardown scripts.
# Everything the stack needs is derived from these few variables, so you only
# edit values in ONE place. Each deploy script sources this file.
#
# Why a plain config file (not Terraform/CDK): the lab wants minimal, fully
# transparent, easily-removable resources. Bash + AWS CLI driven by this config
# is the least-magic way to see exactly what gets created and torn down.

set -euo pipefail

# ----------------------------------------------------------------------------
# EDIT THESE
# ----------------------------------------------------------------------------

# AWS region. Pick one close to you. All resources live here.
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"

# A short, globally-unique project prefix. S3 bucket names are global, so this
# must be unique across all of AWS. Change "amrit" to something of your own.
export PROJECT_PREFIX="${PROJECT_PREFIX:-lab2-twitter-amrit}"

# The two user IDs the lab asks us to display. Used by the front-end to
# highlight them and by verification steps.
export TARGET_USERS=("214328887" "107830991")

# ----------------------------------------------------------------------------
# DERIVED (usually no need to edit)
# ----------------------------------------------------------------------------

# One bucket holds the dataset (input/) and the Spark results (output/).
export DATA_BUCKET="${PROJECT_PREFIX}-data"
# A second bucket hosts the static front-end website.
export SITE_BUCKET="${PROJECT_PREFIX}-site"

# S3 keys / URIs used across scripts.
export INPUT_KEY="input/twitter_combined.txt"
export OUTPUT_PREFIX="output/"
export INPUT_URI="s3://${DATA_BUCKET}/${INPUT_KEY}"
export INPUT_S3A="s3a://${DATA_BUCKET}/${INPUT_KEY}"
export OUTPUT_S3A="s3a://${DATA_BUCKET}/${OUTPUT_PREFIX}"

# Names for the compute + API resources.
export EC2_KEY_NAME="${PROJECT_PREFIX}-key"
export EC2_SG_NAME="${PROJECT_PREFIX}-sg"
export EC2_ROLE_NAME="${PROJECT_PREFIX}-ec2-role"
export EC2_INSTANCE_PROFILE="${PROJECT_PREFIX}-ec2-profile"
export EC2_TAG="${PROJECT_PREFIX}-spark"

export LAMBDA_NAME="${PROJECT_PREFIX}-api"
export LAMBDA_ROLE_NAME="${PROJECT_PREFIX}-lambda-role"
export API_NAME="${PROJECT_PREFIX}-http-api"

# Local file used to persist IDs created at runtime (instance id, api id, ...)
# so later scripts and teardown can find them. Human-readable KEY=VALUE lines.
export STATE_FILE="${STATE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.stack-state}"

# ----------------------------------------------------------------------------
# Small helpers reused by the scripts.
# ----------------------------------------------------------------------------

# Save a KEY=VALUE pair into the state file (replacing any previous value).
save_state() {
  local key="$1" val="$2"
  touch "$STATE_FILE"
  # Remove existing line for this key, then append the new one.
  grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "${key}=${val}" >> "$STATE_FILE"
}

# Read a KEY from the state file (empty string if absent).
read_state() {
  local key="$1"
  [ -f "$STATE_FILE" ] || { echo ""; return; }
  grep "^${key}=" "$STATE_FILE" | tail -n1 | cut -d= -f2- || echo ""
}

# AWS account id (used to build ARNs).
aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

# A loud banner so the "YOUR TURN" manual steps are impossible to miss.
banner() {
  echo ""
  echo "=================================================================="
  echo "$1"
  echo "=================================================================="
  echo ""
}
