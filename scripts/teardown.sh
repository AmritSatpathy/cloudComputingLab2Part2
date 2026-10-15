#!/usr/bin/env bash
#
# Task 6: remove EVERYTHING this project created, so ongoing cost returns to $0.
#
# Deletes in dependency-safe order:
#   1. EC2 instance (stop billing compute immediately)
#   2. API Gateway HTTP API
#   3. Lambda function
#   4. IAM: instance profile, roles, inline/attached policies
#   5. EC2 key pair (+ local .pem) and security group
#   6. S3 buckets (emptied first, then deleted) -- data + site
#
# It is idempotent: anything already gone is skipped. At the end it prints a
# verification summary so you can confirm nothing is left running.
#
#     ./teardown.sh
#
# NOTE: run this ONLY after you have captured all screenshots and written the
# required descriptions -- it is destructive and irreversible.

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
ACCOUNT_ID="$(aws_account_id 2>/dev/null || echo '')"

banner "TEARDOWN  --  this deletes all Lab 2 Part 2 AWS resources"
read -r -p "Type 'yes' to proceed: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }

# --- 1. EC2 instance -------------------------------------------------------
INSTANCE_ID="$(read_state EC2_INSTANCE_ID)"
if [ -n "$INSTANCE_ID" ]; then
  echo "Terminating EC2 instance $INSTANCE_ID..."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" 2>/dev/null || true
fi

# --- 2. API Gateway --------------------------------------------------------
API_ID="$(read_state API_ID)"
if [ -n "$API_ID" ]; then
  echo "Deleting HTTP API $API_ID..."
  aws apigatewayv2 delete-api --api-id "$API_ID" --region "$AWS_REGION" 2>/dev/null || true
fi

# --- 3. Lambda -------------------------------------------------------------
if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Deleting Lambda $LAMBDA_NAME..."
  aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" 2>/dev/null || true
fi

# --- 4. IAM cleanup --------------------------------------------------------
# Instance profile: detach role, then delete profile.
if aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null 2>&1; then
  echo "Removing instance profile $EC2_INSTANCE_PROFILE..."
  aws iam remove-role-from-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" \
    --role-name "$EC2_ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" 2>/dev/null || true
fi

# EC2 role: delete inline policy, then role.
if aws iam get-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1; then
  echo "Deleting role $EC2_ROLE_NAME..."
  aws iam delete-role-policy --role-name "$EC2_ROLE_NAME" \
    --policy-name "${PROJECT_PREFIX}-ec2-s3" 2>/dev/null || true
  aws iam delete-role --role-name "$EC2_ROLE_NAME" 2>/dev/null || true
fi

# Lambda role: detach managed policy + inline policy, then role.
if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  echo "Deleting role $LAMBDA_ROLE_NAME..."
  aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
  aws iam delete-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "${PROJECT_PREFIX}-lambda-s3-read" 2>/dev/null || true
  aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" 2>/dev/null || true
fi

# --- 5. Key pair + security group -----------------------------------------
KEY_FILE="$(read_state EC2_KEY_FILE)"
if aws ec2 describe-key-pairs --key-names "$EC2_KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Deleting key pair $EC2_KEY_NAME..."
  aws ec2 delete-key-pair --key-name "$EC2_KEY_NAME" --region "$AWS_REGION" 2>/dev/null || true
fi
[ -n "$KEY_FILE" ] && rm -f "$KEY_FILE" 2>/dev/null || true

# Security group may take a moment to be deletable after instance termination.
SG_ID="$(read_state EC2_SG_ID)"
if [ -n "$SG_ID" ]; then
  echo "Deleting security group $SG_ID..."
  for _ in 1 2 3 4 5; do
    if aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null; then
      break
    fi
    sleep 10  # wait for the ENI from the terminated instance to detach
  done
fi

# --- 6. S3 buckets (empty, then delete) -----------------------------------
for BUCKET in "$DATA_BUCKET" "$SITE_BUCKET"; do
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "Emptying + deleting bucket $BUCKET..."
    aws s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION" 2>/dev/null || true
  fi
done

# Clear local state so a fresh deploy starts clean.
rm -f "$STATE_FILE" 2>/dev/null || true

# --- Verification ----------------------------------------------------------
banner "VERIFICATION  --  these lists should be EMPTY / show no project resources"
echo "EC2 instances tagged ${EC2_TAG} (should be terminated/empty):"
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${EC2_TAG}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true

echo "Lambda (should error / not found):"
aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
  && echo "  STILL EXISTS: $LAMBDA_NAME" || echo "  gone"

echo "Buckets (should be gone):"
for BUCKET in "$DATA_BUCKET" "$SITE_BUCKET"; do
  aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null \
    && echo "  STILL EXISTS: $BUCKET" || echo "  gone: $BUCKET"
done

echo ""
echo "Teardown complete. Review the lists above to confirm everything is removed."
