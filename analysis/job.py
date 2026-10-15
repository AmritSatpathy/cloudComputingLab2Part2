"""
PySpark data-analysis job for Lab 2 Part 2 (low-memory RDD version).

Goal
----
Read the Twitter edge list (each line: "<follower> <followee>") and compute,
for every user, two numbers:

  * followers  -> how many distinct users follow this user
                  (= number of distinct edges where the user is the FOLLOWEE,
                     i.e. the SECOND column)
  * followees  -> how many distinct users this user follows
                  (= number of distinct edges where the user is the FOLLOWER,
                     i.e. the FIRST column)

The raw dataset is NOT cleaned, so it may contain duplicate edges (the same
"A B" line more than once) and possibly self-loops ("A A"). We de-duplicate
edges so a repeated edge is only ever counted once. Self-loops are kept as-is
(see FILTER_SELF_LOOPS) because the dataset treats each directed edge
independently.

Why the RDD API (not DataFrames) here
--------------------------------------
This job runs on a single free-tier EC2 t3.micro, which has only ~1 GB of RAM.
The DataFrame path (distinct + two groupBy shuffles + a full-outer join) builds
large in-memory hash tables and causes constant garbage collection on 1 GB,
so the job effectively never finishes. The RDD approach below streams the data
with a single reduceByKey and keeps the working set tiny:

  1. Parse each line to a (follower, followee) tuple.
  2. De-duplicate edges with distinct().
  3. For each unique edge emit TWO key/value records:
        (follower, (0, 1))  -> this user gains one followee
        (followee, (1, 0))  -> this user gains one follower
  4. reduceByKey sums the pairs per user in a single shuffle, giving
        userId -> (followers, followees)
     reduceByKey combines map-side first, so memory per partition stays small.

We also keep the partition count low (shuffle partitions = 8) because 200
tiny partitions on 2 cores is pure overhead on this box.

Usage
-----
    spark-submit job.py <input_path> <output_dir>

Output
------
A single JSON file (one JSON object per line) under <output_dir>:

    {"userId": "214328887", "followers": 180, "followees": 214}
"""

import json
import sys

from pyspark.sql import SparkSession

# If True, edges where follower == followee ("A A") are dropped before counting.
# Kept False by default so counts match the raw directed-edge interpretation.
FILTER_SELF_LOOPS = False

# Low partition count: this data is small and the box has 2 cores, so a handful
# of partitions avoids per-task overhead and keeps memory flat.
NUM_PARTITIONS = 8


def parse_line(line):
    """Return (follower, followee) or None for blank/malformed lines."""
    line = line.strip()
    if not line:
        return None
    tokens = line.split()
    if len(tokens) != 2:
        return None
    follower, followee = tokens[0], tokens[1]
    if FILTER_SELF_LOOPS and follower == followee:
        return None
    return (follower, followee)


def main(input_path: str, output_dir: str) -> None:
    # Local/standalone mode on EC2. The app name shows in the Spark UI.
    spark = (
        SparkSession.builder
        .appName("TwitterFollowerFolloweeCounts")
        .getOrCreate()
    )
    sc = spark.sparkContext

    # 1. Read raw text lines and parse to (follower, followee) tuples.
    edges = (
        sc.textFile(input_path, minPartitions=NUM_PARTITIONS)
        .map(parse_line)
        .filter(lambda x: x is not None)
    )

    # 2. De-duplicate edges so a repeated "A B" line counts once.
    edges = edges.distinct()

    # 3. Emit two counting records per unique edge:
    #      follower -> (followers=0, followees=1)
    #      followee -> (followers=1, followees=0)
    def to_counts(edge):
        follower, followee = edge
        return [
            (follower, (0, 1)),  # follower follows one more person
            (followee, (1, 0)),  # followee is followed by one more person
        ]

    contributions = edges.flatMap(to_counts)

    # 4. Sum per user in a single shuffle. reduceByKey combines map-side first,
    #    so each partition only holds partial sums -> low memory.
    totals = contributions.reduceByKey(
        lambda a, b: (a[0] + b[0], a[1] + b[1]),
        numPartitions=NUM_PARTITIONS,
    )

    # Shape into the JSON records the back-end expects, one object per line.
    def to_json(record):
        user_id, (followers, followees) = record
        return json.dumps(
            {"userId": user_id, "followers": followers, "followees": followees}
        )

    # One output file for the back-end to read. coalesce(1) on this small,
    # already-reduced result is cheap (the heavy work is already done).
    (
        totals.map(to_json)
        .coalesce(1)
        .saveAsTextFile(output_dir)
    )

    spark.stop()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: spark-submit job.py <input_path> <output_dir>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
