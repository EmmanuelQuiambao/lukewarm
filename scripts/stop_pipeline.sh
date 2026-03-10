#!/usr/bin/env bash
# stop_pipeline.sh — tear down the Lukewarm local dev stack
#
# Usage:
#   ./scripts/stop_pipeline.sh           # stop processes, leave docker running
#   ./scripts/stop_pipeline.sh --docker  # also stop docker compose services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$PROJECT_ROOT/infra"
LOG_DIR="$PROJECT_ROOT/.logs"
STOP_DOCKER=false

for arg in "$@"; do
  [[ "$arg" == "--docker" ]] && STOP_DOCKER=true
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

# ── 1. Binance Producer ───────────────────────────────────────────────────────
PID_FILE="$LOG_DIR/producer.pid"
if [[ -f "$PID_FILE" ]]; then
  PRODUCER_PID=$(cat "$PID_FILE")
  if kill -0 "$PRODUCER_PID" 2>/dev/null; then
    info "Stopping Binance producer (PID $PRODUCER_PID)..."
    kill "$PRODUCER_PID"
  else
    warn "Producer PID $PRODUCER_PID not running (already dead)."
  fi
  rm -f "$PID_FILE"
else
  # Fallback: find by process name in case PID file is missing
  PIDS=$(pgrep -f "binance_ticker.py" 2>/dev/null || true)
  if [[ -n "$PIDS" ]]; then
    info "Stopping Binance producer (found by name)..."
    echo "$PIDS" | xargs kill 2>/dev/null || true
  else
    warn "No Binance producer process found."
  fi
fi

# ── 2. Spark Streaming Job ────────────────────────────────────────────────────
info "Stopping Spark streaming job inside container..."
if docker inspect lukewarm-spark-master &>/dev/null && \
   [[ "$(docker inspect --format='{{.State.Status}}' lukewarm-spark-master)" == "running" ]]; then
  docker exec lukewarm-spark-master bash -c \
    "pkill -f 'ticker_to_iceberg.py' 2>/dev/null || true; pkill -f SparkSubmit 2>/dev/null || true"
  info "Spark job stopped."
else
  warn "Spark container not running — skipping."
fi

# Kill the local log-tail background process if still running
pkill -f "tail -f /tmp/ticker_job.log" 2>/dev/null || true

# ── 3. Docker Compose ─────────────────────────────────────────────────────────
if [[ "$STOP_DOCKER" == "true" ]]; then
  info "Stopping docker compose services..."
  cd "$INFRA_DIR"
  docker compose stop
  info "Docker services stopped."
else
  warn "Docker services left running. Use --docker to stop them too."
fi

info "Done."
