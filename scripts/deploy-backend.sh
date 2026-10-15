#!/usr/bin/env bash
#
# Task 4: deploy the back-end (AWS Lambda + API Gateway HTTP API).
#
# Creates the minimal set of resources:
#   * an IAM role letting Lambda read the data bucket + write logs
#   * the Lambda function (code = backend/handler.py, zipped)
#   * an HTTP API (API Gateway v2) with routes GET /users and GET /users/{id}
#   * permission + integration wiring, with CORS enabled
#
# Why HTTP API (v2) rather than REST API (v1): cheaper, less config, built-in
# CORS, and more than enough for two GET routes. Lambda + HTTP API are both in
# the always-free / 12-month free tier at this request volume -> $0.
#
#     ./deploy-backend.sh

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ACCOUNT_ID="$(aws_account_id)"

# --- 1. IAM role for Lambda ------------------------------------------------
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$LAMBDA_TRUST" >/dev/null
  echo "Created IAM role: $LAMBDA_ROLE_NAME"
fi
# Basic execution (CloudWatch logs).
aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
# Read-only access to the results in the data bucket (least privilege).
READ_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::'"$DATA_BUCKET"'","arn:aws:s3:::'"$DATA_BUCKET"'/*"]}]}'
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "${PROJECT_PREFIX}-lambda-s3-read" --policy-document "$READ_POLICY"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
save_state LAMBDA_ROLE_NAME "$LAMBDA_ROLE_NAME"
echo "Waiting for role to propagate..."
sleep 10

# --- 2. Package + deploy the Lambda ---------------------------------------
# boto3 is already present in the Lambda runtime, so the zip is just handler.py.
BUILD_DIR="$(mktemp -d)"
cp "$REPO_ROOT/backend/handler.py" "$BUILD_DIR/"
# Build the deployment zip with Python's zipfile (avoids a dependency on the
# `zip` CLI, which may not be installed). boto3 is already in the Lambda
# runtime, so the archive only needs handler.py.
python3 -c "import zipfile, os; z = zipfile.ZipFile(os.path.join('$BUILD_DIR', 'function.zip'), 'w', zipfile.ZIP_DEFLATED); z.write(os.path.join('$BUILD_DIR', 'handler.py'), 'handler.py'); z.close()"

if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Updating existing Lambda code..."
  aws lambda update-function-code --function-name "$LAMBDA_NAME" \
    --zip-file "fileb://$BUILD_DIR/function.zip" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
  aws lambda update-function-configuration --function-name "$LAMBDA_NAME" \
    --environment "Variables={DATA_BUCKET=$DATA_BUCKET,OUTPUT_PREFIX=$OUTPUT_PREFIX}" \
    --region "$AWS_REGION" >/dev/null
else
  echo "Creating Lambda function..."
  aws lambda create-function --function-name "$LAMBDA_NAME" \
    --runtime python3.12 --handler handler.handler \
    --role "$LAMBDA_ROLE_ARN" \
    --timeout 30 --memory-size 256 \
    --environment "Variables={DATA_BUCKET=$DATA_BUCKET,OUTPUT_PREFIX=$OUTPUT_PREFIX}" \
    --zip-file "fileb://$BUILD_DIR/function.zip" \
    --region "$AWS_REGION" >/dev/null
  aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
fi
rm -rf "$BUILD_DIR"
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}"
save_state LAMBDA_NAME "$LAMBDA_NAME"

# --- 3. HTTP API (API Gateway v2) -----------------------------------------
# Create the API with a Lambda-proxy integration and CORS wide open (fine for
# this lab; the data is public). AutoDeploy via the $default stage.
API_ID="$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
          --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration AllowOrigins='*',AllowMethods='GET,OPTIONS',AllowHeaders='*' \
    --target "$LAMBDA_ARN" \
    --region "$AWS_REGION" --query 'ApiId' --output text)"
  echo "Created HTTP API: $API_ID"
fi
save_state API_ID "$API_ID"

# The --target shortcut above creates a $default route/integration/stage. Add
# explicit routes so /users and /users/{id} both reach the function.
INTEGRATION_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" \
  --region "$AWS_REGION" --query 'Items[0].IntegrationId' --output text)"
for ROUTE in "GET /users" "GET /users/{id}"; do
  if ! aws apigatewayv2 get-routes --api-id "$API_ID" --region "$AWS_REGION" \
        --query 'Items[].RouteKey' --output text | grep -qF "$ROUTE"; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$ROUTE" \
      --target "integrations/${INTEGRATION_ID}" --region "$AWS_REGION" >/dev/null
    echo "Added route: $ROUTE"
  fi
done

# Allow API Gateway to invoke the Lambda.
aws lambda add-permission --function-name "$LAMBDA_NAME" \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$AWS_REGION" 2>/dev/null || true

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
save_state API_URL "$API_URL"

echo ""
echo "Back-end deployed. API base URL:"
echo "  $API_URL"
echo ""
echo "Verification (requires the Spark output to already exist in S3):"
echo "  curl \"$API_URL/users/214328887\""
echo "  curl \"$API_URL/users/107830991\""

banner "YOUR TURN  --  SCREENSHOT #7
From your local machine, call the live API and capture the JSON response:

    curl \"$API_URL/users/214328887\"
    curl \"$API_URL/users/107830991\"

Expected (matches the Spark/reference counts):
    {\"userId\": \"214328887\", \"followers\": 180, \"followees\": 214}
    {\"userId\": \"107830991\", \"followers\": 180, \"followees\": 157}

Then continue with:  ./deploy-frontend.sh"
