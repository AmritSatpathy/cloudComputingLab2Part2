#!/usr/bin/env bash
#
# Task 5: deploy the front-end as an S3 static website.
#
# Creates the SITE bucket, enables static website hosting, makes the objects
# publicly readable (a static site must be), injects the API base URL into
# index.html, and uploads it.
#
# Why S3 static hosting: zero servers, free-tier eligible, and the simplest way
# to put a public URL in front of a single HTML file. No build step needed.
#
# Must run AFTER deploy-backend.sh (it reads the API URL from the state file).
#
#     ./deploy-frontend.sh

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

API_URL="$(read_state API_URL)"
if [ -z "$API_URL" ]; then
  echo "ERROR: API_URL not found in state. Run ./deploy-backend.sh first." >&2
  exit 1
fi
echo "Using API: $API_URL"
echo "Site bucket: $SITE_BUCKET"

# --- 1. Create the site bucket --------------------------------------------
if ! aws s3api head-bucket --bucket "$SITE_BUCKET" 2>/dev/null; then
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$SITE_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$SITE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  echo "Created bucket: $SITE_BUCKET"
fi
save_state SITE_BUCKET "$SITE_BUCKET"

# --- 2. Allow public read (required for a static website) ------------------
# Disable the account/bucket "block public access" guard for THIS bucket only,
# then attach a read-only bucket policy. (Public read is expected for a site.)
aws s3api put-public-access-block --bucket "$SITE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

PUBLIC_POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"PublicReadGetObject","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::'"$SITE_BUCKET"'/*"}]}'
aws s3api put-bucket-policy --bucket "$SITE_BUCKET" --policy "$PUBLIC_POLICY"

# --- 3. Enable website hosting --------------------------------------------
aws s3 website "s3://${SITE_BUCKET}/" --index-document index.html

# --- 4. Inject API URL and upload -----------------------------------------
BUILD_DIR="$(mktemp -d)"
# Replace the placeholder with the real API base URL.
sed "s#__API_BASE__#${API_URL}#g" "$REPO_ROOT/frontend/index.html" > "$BUILD_DIR/index.html"
aws s3 cp "$BUILD_DIR/index.html" "s3://${SITE_BUCKET}/index.html" \
  --content-type "text/html"
rm -rf "$BUILD_DIR"

# Website endpoint URL (region-specific format).
if [ "$AWS_REGION" = "us-east-1" ]; then
  SITE_URL="http://${SITE_BUCKET}.s3-website-us-east-1.amazonaws.com"
else
  SITE_URL="http://${SITE_BUCKET}.s3-website.${AWS_REGION}.amazonaws.com"
fi
save_state SITE_URL "$SITE_URL"

echo ""
echo "Front-end deployed:"
echo "  $SITE_URL"

banner "YOUR TURN  --  SCREENSHOT #8
Open the front-end in your browser:

    $SITE_URL

Confirm it shows the required users at the top:
    214328887 has 180 followers / 214 followees
    107830991 has 180 followers / 157 followees

Take a screenshot of the page. That completes the deploy.
When all screenshots are captured and descriptions written, tear down with:
    ./teardown.sh"
