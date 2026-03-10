#!/usr/bin/env bash
# start_pipeline.sh — bring up the full Lukewarm local dev stack
#
# Usage:
#   ./scripts/start_pipeline.sh            # start everything
#   ./scripts/start_pipeline.sh --no-producer  # skip the Binance producer (useful if markets are closed)
#
# What this does:
#   1. Starts docker compose services (idempotent)
#   2. Waits for each service to become healthy
#   3. Creates the crypto schema + ticker table in Iceberg if not already present
#   4. Submits the Spark Structured Streaming job (ticker_to_iceberg)
#   5. Starts the Binance WebSocket producer in the background

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$PROJECT_ROOT/infra"
LOG_DIR="$PROJECT_ROOT/.logs"
START_PRODUCER=true

for arg in "$@"; do
  [[ "$arg" == "--no-producer" ]] && START_PRODUCER=false
done

mkdir -p "$LOG_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
err()     { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_healthy() {
  local name="$1"
  local retries="${2:-30}"
  info "Waiting for $name to be healthy..."
  for i in $(seq 1 "$retries"); do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "missing")
    if [[ "$status" == "healthy" ]]; then
      info "$name is healthy."
      return 0
    fi
    sleep 5
  done
  err "$name did not become healthy after $((retries * 5))s"
}

wait_running() {
  local name="$1"
  local retries="${2:-12}"
  info "Waiting for $name to be running..."
  for i in $(seq 1 "$retries"); do
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    if [[ "$status" == "running" ]]; then
      info "$name is running."
      return 0
    fi
    sleep 5
  done
  err "$name did not start after $((retries * 5))s"
}

# ── 1. Docker Compose ─────────────────────────────────────────────────────────
info "Starting docker compose services..."
cd "$INFRA_DIR"
docker compose up -d

wait_healthy  lukewarm-minio        24
wait_healthy  lukewarm-iceberg-rest 24
wait_healthy  lukewarm-trino        24
wait_healthy  lukewarm-kafka        36
wait_healthy  lukewarm-spark-master 24
wait_running  lukewarm-spark-worker

# ── 2. Init Iceberg schema ────────────────────────────────────────────────────
info "Initialising iceberg.crypto schema and ticker table..."
docker exec lukewarm-trino trino \
  --file /etc/trino/scripts/init_crypto_schema.sql \
  2>/dev/null \
  && info "Schema ready." \
  || warn "Schema init returned non-zero (table may already exist — continuing)."

# ── 3. Spark Streaming Job ────────────────────────────────────────────────────
info "Writing Spark submit script into container..."
docker exec lukewarm-spark-master bash -c "cat > /tmp/submit.sh << 'SCRIPT'
#!/bin/bash
/opt/spark/bin/spark-submit \
  --master spark://spark-master:7077 \
  --conf spark.executorEnv.AWS_REGION=us-east-1 \
  --conf spark.yarn.appMasterEnv.AWS_REGION=us-east-1 \
  --conf spark.executor.extraJavaOptions=-Daws.region=us-east-1 \
  --conf spark.driver.extraJavaOptions=-Daws.region=us-east-1 \
  --packages 'org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.2,org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.1,org.apache.iceberg:iceberg-aws-bundle:1.5.2,org.apache.hadoop:hadoop-aws:3.3.4' \
  /opt/spark/jobs/ticker_to_iceberg.py \
  >> /tmp/ticker_job.log 2>&1
SCRIPT
chmod +x /tmp/submit.sh"

info "Submitting Spark streaming job (logs: $LOG_DIR/ticker_job.log)..."
docker exec -d lukewarm-spark-master /tmp/submit.sh

# Stream the container log to a local file for easy tailing
docker exec lukewarm-spark-master bash -c "tail -f /tmp/ticker_job.log" \
  >> "$LOG_DIR/ticker_job.log" 2>/dev/null &

# Give Spark a moment to start and sanity-check it appeared
sleep 10
if docker exec lukewarm-spark-master bash -c "ps aux | grep -v grep | grep SparkSubmit" > /dev/null 2>&1; then
  info "Spark job is running."
else
  warn "Spark job process not found — check $LOG_DIR/ticker_job.log for errors."
fi

# ── 4. Binance Producer ───────────────────────────────────────────────────────
if [[ "$START_PRODUCER" == "true" ]]; then
  VENV="$PROJECT_ROOT/.venv"
  if [[ ! -f "$VENV/bin/python" ]]; then
    err "virtualenv not found at $VENV. Run: python -m venv .venv && pip install -e '.[streaming]'"
  fi

  info "Starting Binance ticker producer (logs: $LOG_DIR/producer.log)..."
  nohup "$VENV/bin/python" "$PROJECT_ROOT/producers/binance_ticker.py" \
    >> "$LOG_DIR/producer.log" 2>&1 &
  PRODUCER_PID=$!
  echo "$PRODUCER_PID" > "$LOG_DIR/producer.pid"

  sleep 4
  if kill -0 "$PRODUCER_PID" 2>/dev/null; then
    info "Producer running (PID $PRODUCER_PID)."
  else
    warn "Producer exited early — check $LOG_DIR/producer.log"
  fi
else
  warn "Skipping producer (--no-producer flag set)."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "Stack is up. Quick reference:"
echo "  Trino UI:       http://localhost:8080"
echo "  Spark UI:       http://localhost:8082"
echo "  Kafka UI:       http://localhost:8090"
echo "  Airflow UI:     http://localhost:8081  (admin / admin)"
echo "  MinIO console:  http://localhost:9001  (minioadmin / minioadmin)"
echo ""
echo "  Spark job log:  tail -f $LOG_DIR/ticker_job.log"
echo "  Producer log:   tail -f $LOG_DIR/producer.log"
echo ""
echo "  Verify data:    docker exec lukewarm-trino trino --execute \"SELECT COUNT(*) FROM iceberg.crypto.ticker\""
