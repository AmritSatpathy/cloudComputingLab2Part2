# Lab 2 Part 2 — Twitter Follower/Followee Full-Stack App on AWS

A full-stack web application that computes and displays the number of
**followers** and **followees** for each user in the Twitter social graph
(`twitter_combined.txt`), with the analysis running on the cloud.

Required demo users:

| User | Followers | Followees |
|------|-----------|-----------|
| `214328887` | 180 | 214 |
| `107830991` | 180 | 157 |

These values are produced by the cloud Spark run and served by the API.

---

## 1. Architecture

```
twitter_combined.txt
        │  (uploaded by deploy-storage.sh)
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

**Three components:**

- **Data analysis** — PySpark job (`analysis/job.py`) running on a single
  free-tier EC2 instance. Reads the edge list from S3, de-duplicates edges,
  counts followers/followees per user, and writes JSON results back to S3.
- **Back-end** — AWS Lambda (`backend/handler.py`) behind an API Gateway HTTP
  API. Reads the results JSON from S3 and serves it over REST.
- **Front-end** — a static HTML/JS page (`frontend/index.html`) hosted on S3
  static website hosting. Calls the API and renders the counts.

---

## 2. Design rationale

**Spark on EC2 instead of EMR / Glue / EMR Serverless.**
The lab requires a cloud Spark/Hadoop framework. Every *managed* Spark service
on AWS bills compute time — none is truly free:
- EMR classic bills EC2 plus an EMR surcharge per hour.
- EMR Serverless bills per vCPU/GB-second (a few cents even for a short run).
- Glue bills per DPU-hour with a 1-minute minimum.

Running Spark directly on a **free-tier `t3.micro`** (750 hrs/month free for 12
months) keeps the analysis at **$0** while still being a genuine "Spark on AWS"
run suitable for screenshots. The dataset is small (~2.4M edges), so one node is
sufficient.

**RDD-based PySpark job.**
The job uses the RDD API (one `distinct()` to remove duplicate edges, then a
single `reduceByKey` to count) rather than the DataFrame API. On a 1 GB
`t3.micro`, the DataFrame path (distinct + two group-by shuffles + a join) builds
large in-memory hash tables and stalls on garbage collection; the RDD approach
keeps the working set small and completes in about 30 seconds.

**Lambda + API Gateway for the back-end.**
Both are free-tier eligible (1M requests/month) and need no server kept running,
so cost is $0 at this scale. The results file is tiny, so the function loads it
from S3 and answers from memory (cached across warm invocations).

**S3 static hosting for the front-end.**
Zero servers, free-tier eligible, and the simplest way to expose a single HTML
file at a public URL. No build step.

**Bash + AWS CLI instead of Terraform/CDK.**
The lab calls for minimal, transparent, easily-removable resources. Plain scripts
make it obvious exactly what gets created, and a single `teardown.sh` removes
everything so cost returns to $0.

---

## 3. Repository layout

```
.
├── analysis/
│   └── job.py                   # PySpark job (runs on the cloud)
├── backend/
│   └── handler.py               # Lambda handler (API logic)
├── frontend/
│   └── index.html               # static UI (API URL injected at deploy)
├── scripts/
│   ├── config.sh                # shared config (PROJECT_PREFIX / REGION)
│   ├── deploy-storage.sh        # S3 bucket + dataset upload
│   ├── ec2-bootstrap.sh         # EC2 user-data: installs Spark + S3 jars
│   ├── deploy-spark-ec2.sh      # launch EC2, print SSH/spark-submit steps
│   ├── deploy-backend.sh        # Lambda + API Gateway
│   ├── deploy-frontend.sh       # S3 static website
│   └── teardown.sh              # delete everything
└── README.md
```

The dataset `twitter_combined.txt` is provided by the course and is not included
in this repository. Place it in the repository root before deploying.

---

## 4. Prerequisites

- An AWS account with the **AWS CLI v2** installed and configured
  (`aws configure`); credentials are read from the local machine.
- `bash`, `curl`, and `ssh`/`scp` available (standard on Linux/WSL/macOS).
- `twitter_combined.txt` present in the repository root.

Configuration lives in `scripts/config.sh`:
- `AWS_REGION` — the deployment region (e.g. `ap-southeast-2`).
- `PROJECT_PREFIX` — a globally unique prefix (S3 bucket names are global).

---

## 5. Deployment (run in this order)

Each script prints a clearly labelled block at the end naming the exact command
to run next and the screenshot to capture.

```bash
cd scripts

./deploy-storage.sh      # create S3 + upload dataset   
./deploy-spark-ec2.sh    # launch EC2 + print SSH steps 
#   then: SSH in, run spark-submit, capture the run,
#         and take SCREENSHOT #4 of the S3 output
./deploy-backend.sh      # Lambda + API Gateway 
./deploy-frontend.sh     # S3 static website  
```

### The manual step (SSH + Spark)

`deploy-spark-ec2.sh` launches the instance and prints the exact commands. From
the local machine:

```bash
# SSH in (key path + IP are printed by the script)
ssh -i scripts/<prefix>-key.pem ec2-user@<PUBLIC_IP>

# wait for the bootstrap (which installs Spark) to finish:
ls /opt/BOOTSTRAP_COMPLETE          # or: tail -f /var/log/bootstrap.log
```

Copy the job up and run it (reads S3 input, writes S3 output):

```bash
# from the local machine, in another terminal:
scp -i scripts/<prefix>-key.pem analysis/job.py ec2-user@<PUBLIC_IP>:~/

# on the instance:
source /etc/profile.d/spark.sh
spark-submit --driver-memory 900m job.py \
  s3a://<prefix>-data/input/twitter_combined.txt \
  s3a://<prefix>-data/output/
```

The run finishes in roughly 30 seconds and writes `part-00000` and `_SUCCESS`
under `output/`. The counts can be confirmed with:

```bash
aws s3 cp --recursive s3://<prefix>-data/output/ ./out
grep -E '"214328887"|"107830991"' out/part-*
# {"userId": "214328887", "followers": 180, "followees": 214}
# {"userId": "107830991", "followers": 180, "followees": 157}
```

---


