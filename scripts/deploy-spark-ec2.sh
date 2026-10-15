#!/usr/bin/env bash
#
# Task 3: launch a free-tier EC2 instance that can run the PySpark job on S3.
#
# Creates the minimal set of resources needed and NOTHING more:
#   * an SSH key pair (private key saved locally so you can SSH in)
#   * a security group allowing SSH (port 22) from YOUR current public IP only
#   * an IAM role + instance profile granting the box read/write to the data
#     bucket (so Spark uses the role for S3 creds -- no keys on the instance)
#   * one t3.micro instance (free-tier eligible) running the bootstrap that
#     installs Spark + the S3 connector jars
#
# Why t3.micro + self-managed Spark: it is free-tier eligible (750 hrs/month),
# so the analysis costs $0, while still being a genuine Spark-on-AWS run we can
# screenshot. Managed Spark (EMR/Glue) would bill compute time.
#
# After this script you SSH in and run spark-submit yourself (so the run is
# live and screenshot-able). The script prints the exact commands.
#
#     ./deploy-spark-ec2.sh

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ACCOUNT_ID="$(aws_account_id)"
echo "Account: $ACCOUNT_ID  Region: $AWS_REGION"

# --- 1. Key pair -----------------------------------------------------------
KEY_FILE="${SCRIPT_DIR}/${EC2_KEY_NAME}.pem"
if aws ec2 describe-key-pairs --key-names "$EC2_KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Key pair already exists: $EC2_KEY_NAME (reusing)"
else
  echo "Creating key pair: $EC2_KEY_NAME"
  aws ec2 create-key-pair --key-name "$EC2_KEY_NAME" --region "$AWS_REGION" \
    --query 'KeyMaterial' --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "Private key saved to $KEY_FILE"
fi
save_state EC2_KEY_FILE "$KEY_FILE"

# --- 2. Security group (SSH from your IP only) -----------------------------
MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '\n')"
echo "Your public IP: $MY_IP"
SG_ID="$(aws ec2 describe-security-groups --group-names "$EC2_SG_NAME" \
          --region "$AWS_REGION" --query 'SecurityGroups[0].GroupId' \
          --output text 2>/dev/null || true)"
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$EC2_SG_NAME" \
            --description "Lab2 Spark SSH access" --region "$AWS_REGION" \
            --query 'GroupId' --output text)"
  echo "Created security group: $SG_ID"
fi
# Allow SSH from your IP (ignore error if the rule already exists).
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" --region "$AWS_REGION" 2>/dev/null || true
save_state EC2_SG_ID "$SG_ID"

# --- 3. IAM role + instance profile for S3 access --------------------------
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EC2_ROLE_NAME" \
    --assume-role-policy-document "$TRUST" >/dev/null
  echo "Created IAM role: $EC2_ROLE_NAME"
fi
# Least-privilege: only this data bucket, only what Spark needs.
S3_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],"Resource":["arn:aws:s3:::'"$DATA_BUCKET"'","arn:aws:s3:::'"$DATA_BUCKET"'/*"]}]}'
aws iam put-role-policy --role-name "$EC2_ROLE_NAME" \
  --policy-name "${PROJECT_PREFIX}-ec2-s3" --policy-document "$S3_POLICY"
if ! aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" \
    --role-name "$EC2_ROLE_NAME"
  echo "Created instance profile: $EC2_INSTANCE_PROFILE"
  echo "Waiting for instance profile to propagate..."
  sleep 15
fi
save_state EC2_ROLE_NAME "$EC2_ROLE_NAME"
save_state EC2_INSTANCE_PROFILE "$EC2_INSTANCE_PROFILE"

# --- 4. Latest Amazon Linux 2023 AMI --------------------------------------
AMI_ID="$(aws ssm get-parameters --region "$AWS_REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)"
echo "AMI: $AMI_ID"

# --- 5. Launch the instance ------------------------------------------------
echo "Launching t3.micro..."
INSTANCE_ID="$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$EC2_KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile Name="$EC2_INSTANCE_PROFILE" \
  --user-data "file://${SCRIPT_DIR}/ec2-bootstrap.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${EC2_TAG}}]" \
  --region "$AWS_REGION" \
  --query 'Instances[0].InstanceId' --output text)"
save_state EC2_INSTANCE_ID "$INSTANCE_ID"
echo "Instance: $INSTANCE_ID"

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
save_state EC2_PUBLIC_IP "$PUBLIC_IP"

# Copy the PySpark job to the box so you can spark-submit it. (We wait a bit;
# SSH may not be ready the instant the instance is "running".)
echo "Public IP: $PUBLIC_IP"

banner "YOUR TURN  --  EC2 / SPARK MANUAL STEPS"
cat <<EOF
1) SCREENSHOT #1 (AWS console): EC2 > Instances. Show instance
   $INSTANCE_ID as t3.micro, state 'running', region $AWS_REGION.

2) The instance runs a bootstrap that installs Spark. It takes ~3-5 minutes.
   Wait a few minutes, then SSH in FROM YOUR LOCAL MACHINE:

     ssh -i "$KEY_FILE" ec2-user@$PUBLIC_IP

   Confirm the bootstrap finished (file appears when done):
     ls /opt/BOOTSTRAP_COMPLETE        # if missing, 'tail -f /var/log/bootstrap.log'

3) Copy the PySpark job onto the instance (run this locally, new terminal):

     scp -i "$KEY_FILE" "$REPO_ROOT/analysis/job.py" ec2-user@$PUBLIC_IP:~/

4) ON THE INSTANCE, run the job against S3 (reads input, writes output):

     source /etc/profile.d/spark.sh
     spark-submit job.py "$INPUT_S3A" "$OUTPUT_S3A"

   SCREENSHOT #2: the SSH terminal showing the spark-submit command and
                  Spark's stage/progress logs.
   SCREENSHOT #3: the completion lines (job finished, no errors).

5) OPTIONAL SCREENSHOT #5 (Spark UI): while the job runs, from your local
   machine open an SSH tunnel, then browse http://localhost:4040 :

     ssh -i "$KEY_FILE" -L 4040:localhost:4040 ec2-user@$PUBLIC_IP

6) SCREENSHOT #4 (AWS console): S3 > $DATA_BUCKET > output/ showing the
   results JSON part file written by Spark.

7) Sanity check the two target users match the local reference values:
       214328887  -> followers 180, followees 214
       107830991  -> followers 180, followees 157
   (From the instance you can inspect the output with:
       aws s3 cp "$INPUT_URI" - >/dev/null  # creds work via the role
       aws s3 cp --recursive "s3://$DATA_BUCKET/output/" ./out && grep -E '214328887|107830991' out/part-*.json )

When screenshots are captured, continue with:  ./deploy-backend.sh
EOF
