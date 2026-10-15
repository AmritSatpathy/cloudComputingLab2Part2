#!/usr/bin/env bash
#
# Task 2: create S3 storage and upload the dataset.
#
# Creates the DATA bucket (holds input/ dataset + output/ Spark results) and
# uploads twitter_combined.txt. The SITE bucket is created later by
# deploy-frontend.sh (kept separate so storage can exist without a website).
#
# Why S3: it is the cheapest, free-tier-eligible object store on AWS and is the
# natural "dataset location in cloud storage" the lab asks for. The ~44 MB file
# sits well inside the 5 GB free tier.
#
# Run from the scripts/ directory (or anywhere) with AWS CLI configured:
#     ./deploy-storage.sh

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Path to the dataset relative to the repo root (scripts/ is one level down).
DATASET_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/twitter_combined.txt"

if [ ! -f "$DATASET_PATH" ]; then
  echo "ERROR: dataset not found at $DATASET_PATH" >&2
  exit 1
fi

echo "Region        : $AWS_REGION"
echo "Data bucket   : $DATA_BUCKET"
echo "Dataset       : $DATASET_PATH"

# Create the data bucket. us-east-1 is special: it must NOT get a
# LocationConstraint, every other region must. We branch accordingly.
create_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "Bucket already exists: $bucket"
    return
  fi
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  echo "Created bucket: $bucket"
}

create_bucket "$DATA_BUCKET"

# Upload the dataset to input/.
echo "Uploading dataset..."
aws s3 cp "$DATASET_PATH" "$INPUT_URI"

# Record what we created for teardown.
save_state DATA_BUCKET "$DATA_BUCKET"

# Verify: list the object and its size.
echo ""
echo "Verification (object should be listed with a non-zero size):"
aws s3 ls "$INPUT_URI" --human-readable

banner "YOUR TURN  --  SCREENSHOT #6
Open the S3 console in region $AWS_REGION, open bucket:
    $DATA_BUCKET  ->  input/twitter_combined.txt
Take a screenshot showing the dataset uploaded to cloud storage.
Then continue with:  ./deploy-spark-ec2.sh"
