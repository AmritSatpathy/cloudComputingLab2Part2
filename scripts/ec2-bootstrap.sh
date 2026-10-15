#!/bin/bash
#
# EC2 user-data bootstrap: runs automatically ONCE when the instance first
# boots. It installs everything needed to run the PySpark job against S3, so
# that when you SSH in you only have to run a single spark-submit command.
#
# Target AMI: Amazon Linux 2023 (dnf, Java available as Amazon Corretto).
#
# What it installs:
#   * Java 17 (Corretto)  -- Spark needs a JVM.
#   * Python 3 + pip      -- for PySpark.
#   * Spark 3.5.x (prebuilt "hadoop3" tarball) -- the Spark runtime.
#   * hadoop-aws + aws-java-sdk jars -- so Spark can read/write s3a:// URIs.
#
# All output is logged to /var/log/bootstrap.log so you can inspect progress
# (useful if the spark-submit later complains something is missing).

set -euxo pipefail
exec > /var/log/bootstrap.log 2>&1

SPARK_VERSION="3.5.1"
HADOOP_PROFILE="hadoop3"
SPARK_PKG="spark-${SPARK_VERSION}-bin-${HADOOP_PROFILE}"
# hadoop-aws must match the Hadoop version Spark was built against (3.3.x for
# the hadoop3 build). aws-java-sdk-bundle is its required companion.
HADOOP_AWS_VERSION="3.3.4"
AWS_SDK_BUNDLE_VERSION="1.12.262"

# --- base packages ---------------------------------------------------------
dnf -y update
dnf -y install java-17-amazon-corretto-headless python3 python3-pip tar gzip wget

export JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
echo "export JAVA_HOME=${JAVA_HOME}" >> /etc/profile.d/spark.sh

# --- Spark -----------------------------------------------------------------
cd /opt
wget -q "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_PKG}.tgz"
tar xzf "${SPARK_PKG}.tgz"
rm -f "${SPARK_PKG}.tgz"
ln -sfn "/opt/${SPARK_PKG}" /opt/spark

# --- S3 connector jars -----------------------------------------------------
# Drop the hadoop-aws + aws-java-sdk-bundle jars into Spark's jars/ dir so
# s3a:// just works without extra --packages downloads at submit time.
cd /opt/spark/jars
wget -q "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar"
wget -q "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_BUNDLE_VERSION}/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar"

# --- environment for the ec2-user -----------------------------------------
cat >> /etc/profile.d/spark.sh <<'EOF'
export SPARK_HOME=/opt/spark
export PATH=$PATH:/opt/spark/bin
# Use the instance IAM role for S3 credentials (no keys on disk).
export PYSPARK_PYTHON=python3
EOF
chmod +x /etc/profile.d/spark.sh

# Signal completion for anyone tailing the log / checking readiness.
touch /opt/BOOTSTRAP_COMPLETE
echo "BOOTSTRAP COMPLETE"
