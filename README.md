# Lab 2 Part 2 — Twitter Follower/Followee Full-Stack App on AWS

A full-stack web application that computes and displays the number of
**followers** and **followees** for each user in the Twitter social graph
(`twitter_combined.txt`), with the analysis running on the cloud.

Required demo users:

| User | Followers | Followees |
|------|-----------|-----------|
| `214328887` | 180 | 214 |
| `107830991` | 180 | 157 |

(These values are produced by the cloud Spark run and served by the API.)

---

## 1. Architecture

```
twitter_combined.txt
        │  (deploy-storage.sh uploads)
        ▼
   ┌───────────┐     spark-submit      ┌──────────────┐
   │  S3 input │ ───────────────────▶  │ EC2 t3.micro │
   └───────────┘                       │   PySpark    │
        ▲                              └──────┬───────┘
        │                                     │ writes JSON
        │                                     ▼
        │                              ┌───────────┐
        │                              │ S3 output │
        │                              └─────┬─────┘
        │                                    │ reads
        │                              ┌──────▼──────┐
        │                              │   Lambda    │
        │                              └──────┬──────┘
        │                                     │
        │                              ┌──────▼──────────┐
        │                              │ API Gateway     │
        │                              │ (HTTP API v2)   │
        │                              └──────┬──────────┘
        │                                     │ fetch()
   ┌────┴────────────┐              ┌─────────▼─────────┐
   │ S3 static site  │ ◀── user ──▶ │  Browser (UI)     │
   └─────────────────┘              └───────────────────┘
```

**Three graded components:**

- **Data analysis** — PySpark job (`analysis/job.py`) running on a single
  free-tier EC2 instance. Reads the edge list from S3, de-duplicates edges,
  counts followers/followees per user, writes JSON results back to S3.
- **Back-end** — AWS Lambda (`backend/handler.py`) behind an API Gateway HTTP
  API. Reads the results JSON from S3 and serves it over REST.
- **Front-end** — a static HTML/JS page (`frontend/index.html`) hosted on S3
  static website hosting. Calls the API and renders the counts.

---

## 2. Why these choices (rationale)

**Why run Spark on EC2 instead of EMR / Glue / EMR Serverless?**
The lab requires a cloud Spark/Hadoop framework. Every *managed* Spark service
on AWS bills compute time — none is truly free:
- EMR classic bills EC2 + an EMR surcharge per hour.
- EMR Serverless bills per vCPU/GB-second (a few cents even for a short run).
- Glue bills per DPU-hour with a 1-minute minimum.

Running Spark ourselves on a **free-tier `t3.micro`** (750 hrs/month free for 12
months) keeps the analysis at **$0** while still being a genuine "Spark on AWS"
run we can screenshot. The dataset is small (~2.4M edges), so one node is plenty.

**Why PySpark (not Hadoop MapReduce)?**
Far less code — de-duplication is one `.distinct()` call and the counts are two
`groupBy().count()` calls. Less to install and configure on the box, and it
still satisfies the lab's "frameworks like Spark".

**Why Lambda + API Gateway for the back-end?**
Both are free-tier eligible (1M requests/month). No server to keep running, so
cost is $0 at this scale. The results file is tiny, so the function just loads
it from S3 and answers from memory (cached across warm invocations).

**Why S3 static hosting for the front-end?**
Zero servers, free-tier eligible, and the simplest way to expose a single HTML
file at a public URL. No build step.

**Why bash + AWS CLI (not Terraform/CDK)?**
The lab wants minimal, transparent, easily-removable resources. Plain scripts
make it obvious exactly what gets created, and a single `teardown.sh` removes
everything so cost returns to $0.

---

## 3. Repository layout

```
.
├── twitter_combined.txt         # the dataset (input)
├── analysis/
│   └── job.py                   # PySpark job (runs on the cloud)
├── backend/
│   └── handler.py               # Lambda handler (API logic)
├── frontend/
│   └── index.html               # static UI (API URL injected at deploy)
├── scripts/
│   ├── config.sh                # shared config (EDIT PROJECT_PREFIX/REGION)
│   ├── deploy-storage.sh        # S3 bucket + dataset upload
│   ├── ec2-bootstrap.sh         # EC2 user-data: installs Spark + S3 jars
│   ├── deploy-spark-ec2.sh      # launch EC2, print SSH/spark-submit steps
│   ├── deploy-backend.sh        # Lambda + API Gateway
│   ├── deploy-frontend.sh       # S3 static website
│   └── teardown.sh              # delete everything
└── README.md
```

---

## 4. Prerequisites

- An AWS account with the **AWS CLI v2** installed and configured
  (`aws configure`) — credentials are read from your local machine.
- `bash`, `curl`, and `ssh`/`scp` available (standard on Linux/WSL/macOS).

Before anything else, open `scripts/config.sh` and set:
- `AWS_REGION` (e.g. `ap-southeast-2`)
- `PROJECT_PREFIX` to something globally unique (S3 bucket names are global).

---

## 5. Deploy (run in this order)

Each script ends with a clearly-labelled **"YOUR TURN"** block telling you the
exact command to run and the screenshot to take.

```bash
cd scripts

./deploy-storage.sh      # create S3 + upload dataset   -> SCREENSHOT #6
./deploy-spark-ec2.sh    # launch EC2 + print SSH steps  -> SCREENSHOTS #1–#5
#   ...follow its instructions: SSH in, run spark-submit, screenshot the run,
#      then take SCREENSHOT #4 of the S3 output...
./deploy-backend.sh      # Lambda + API Gateway          -> SCREENSHOT #7
./deploy-frontend.sh     # S3 static website             -> SCREENSHOT #8
```

### The manual step (SSH + Spark) in detail

`deploy-spark-ec2.sh` launches the instance and the exact commands you need.
From **your local machine**:

```bash
# SSH in (key path + IP are printed by the script)
ssh -i scripts/<prefix>-key.pem ec2-user@<PUBLIC_IP>

# wait for the bootstrap (installs Spark) to finish:
ls /opt/BOOTSTRAP_COMPLETE          # or: tail -f /var/log/bootstrap.log
```

Copy the job up and run it (reads S3 input, writes S3 output):

```bash
# from your local machine, in another terminal:
scp -i scripts/<prefix>-key.pem analysis/job.py ec2-user@<PUBLIC_IP>:~/

# on the instance:
source /etc/profile.d/spark.sh
spark-submit job.py \
  s3a://<prefix>-data/input/twitter_combined.txt \
  s3a://<prefix>-data/output/
```

---

## 6. Screenshots to capture (for submission)

The lab wants proof the analysis actually ran on the cloud. Capture these:

| # | What | When / where |
|---|------|--------------|
| 1 | **EC2 instance running** (t3.micro, state `running`, region) | AWS console, after `deploy-spark-ec2.sh` |
| 2 | **SSH terminal running `spark-submit`** with Spark stage logs | on the instance, during the run |
| 3 | **Spark job completion** (finished, no errors) | same terminal, at the end |
| 4 | **S3 output** JSON part file in `output/` | AWS console, after the job |
| 5 | *(optional)* **Spark UI** (`http://localhost:4040` via SSH tunnel) | browser, during the run |
| 6 | **S3 input** dataset uploaded | AWS console, after `deploy-storage.sh` |
| 7 | **Live API** JSON for both users (`curl .../users/<id>`) | your terminal, after `deploy-backend.sh` |
| 8 | **Front-end page** showing the two required users | browser, after `deploy-frontend.sh` |

Essential ones for the "ran on cloud" requirement: **#1, #2, #3, #4**.

---

## 7. Teardown (return cost to $0)

Run this **only after** all screenshots are captured and both descriptions are
written — it is destructive.

```bash
cd scripts
./teardown.sh            # type 'yes' to confirm
```

It terminates the EC2 instance, deletes the API, Lambda, IAM roles/profile, key
pair (and local `.pem`), security group, and both S3 buckets, then prints a
verification summary that should show everything gone.

---

## 8. Required short descriptions (for the report)

**Front-end (≤50 words):**

> A single static HTML page (vanilla HTML/CSS/JavaScript, no framework) hosted
> on Amazon S3 static website hosting. It uses the browser `fetch` API to call
> the back-end REST endpoints on API Gateway and renders each user's follower
> and followee counts, highlighting users 214328887 and 107830991.

**Back-end (≤100 words):**

> The back-end is an AWS Lambda function (Python) exposed through an API Gateway
> HTTP API, providing `GET /users` and `GET /users/{id}`. The data analysis
> runs separately as a PySpark job on a free-tier EC2 instance: it reads the
> Twitter edge list from Amazon S3, de-duplicates edges, computes follower and
> followee counts per user, and writes the results back to S3 as JSON. Lambda
> loads that results file from S3 (cached across invocations) and serves it to
> the front-end over HTTP with CORS enabled. S3 is the shared storage layer tying
> the components together; everything stays within the AWS free tier.
```
