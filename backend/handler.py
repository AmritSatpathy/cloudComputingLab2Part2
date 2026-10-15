"""
Back-end Lambda handler for Lab 2 Part 2.

Role in the architecture
-------------------------
This is the "back-end" graded component. It is the hub between cloud storage
and the front-end: it reads the follower/followee results that the Spark job
wrote to S3 and serves them to the front-end over HTTP (via API Gateway).

Endpoints (HTTP API / API Gateway v2):
    GET /users            -> all users (optionally ?ids=214328887,107830991)
    GET /users/{id}       -> a single user's follower/followee counts

Why Lambda + API Gateway: both are free-tier eligible (1M requests/month), need
no server to keep running, and cost $0 at this scale. The results file is tiny,
so the function simply loads it from S3 and answers from memory.

Environment variables (set by deploy-backend.sh):
    DATA_BUCKET    -- S3 bucket holding the Spark output
    OUTPUT_PREFIX  -- key prefix under which Spark wrote the JSON (e.g. output/)
"""

import json
import os
from functools import lru_cache

import boto3

DATA_BUCKET = os.environ["DATA_BUCKET"]
OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "output/")

s3 = boto3.client("s3")

# CORS headers so the browser-based front-end (served from a different S3
# origin) is allowed to call this API.
CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Access-Control-Allow-Headers": "*",
    "Content-Type": "application/json",
}


@lru_cache(maxsize=1)
def load_results() -> dict:
    """
    Load and cache the Spark results from S3 into {userId: {...}}.

    Spark wrote one-JSON-object-per-line files under OUTPUT_PREFIX (there may be
    a single part-*.json plus a _SUCCESS marker). We read every .json part and
    merge them. lru_cache keeps the parsed dict warm across invocations on a
    reused Lambda container, so most requests do no S3 I/O at all.
    """
    results: dict = {}
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=DATA_BUCKET, Prefix=OUTPUT_PREFIX):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            base = key.rsplit("/", 1)[-1]
            # Spark's RDD saveAsTextFile writes files named "part-00000" (no
            # extension) plus a "_SUCCESS" marker. Read the part files, skip
            # markers and any empty "directory" keys. (Also tolerate a .json
            # suffix in case the DataFrame writer is ever used instead.)
            if not base.startswith("part-"):
                continue
            body = s3.get_object(Bucket=DATA_BUCKET, Key=key)["Body"].read().decode("utf-8")
            for line in body.splitlines():
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                results[str(rec["userId"])] = {
                    "followers": int(rec.get("followers", 0)),
                    "followees": int(rec.get("followees", 0)),
                }
    return results


def _resp(status: int, payload) -> dict:
    return {"statusCode": status, "headers": CORS, "body": json.dumps(payload)}


def handler(event, context):
    # API Gateway v2 (HTTP API) event shape.
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    if method == "OPTIONS":
        return _resp(200, {})  # CORS preflight

    raw_path = event.get("rawPath", "/")
    path_params = event.get("pathParameters") or {}
    query = event.get("queryStringParameters") or {}

    data = load_results()

    # GET /users/{id}
    if path_params.get("id"):
        uid = str(path_params["id"])
        rec = data.get(uid, {"followers": 0, "followees": 0})
        return _resp(200, {"userId": uid, **rec})

    # GET /users  (optionally filtered by ?ids=a,b,c)
    if raw_path.rstrip("/").endswith("/users"):
        ids = query.get("ids")
        if ids:
            wanted = [i.strip() for i in ids.split(",") if i.strip()]
            items = [
                {"userId": u, **data.get(u, {"followers": 0, "followees": 0})}
                for u in wanted
            ]
        else:
            items = [{"userId": u, **rec} for u, rec in data.items()]
        return _resp(200, {"count": len(items), "users": items})

    return _resp(404, {"message": "not found", "path": raw_path})
