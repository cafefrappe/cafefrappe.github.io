#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive"
INSTALL_DIR="/opt/oracle-keepalive"
MEMORY_MB=256
CPU_PERCENT=10
DOWNLOAD_MB=10
DOWNLOAD_INTERVAL=600
STOCK_INTERVAL=300
CONTAINER_CPUS=1
CONTAINER_MEM_LIMIT_MB=1024
CYCLE_MIN=420
CYCLE_MAX=540
REST_TIME=60
SYMBOLS=""
DOWNLOAD_URL="https://speed.cloudflare.com/__down"

usage() {
  cat <<'EOF'
Usage: curl -fsSL URL/install.sh | sudo bash -s -- [options]

  --memory-mb N          Memory allocation, MiB (default 256)
  --cpu-percent N        Approximate percent of one CPU core (default 10)
  --download-mb N        Data downloaded per round, MiB; 0 disables (default 10)
  --download-interval N  Seconds between downloads (default 600)
  --stock-interval N     Seconds between stock scans (default 300)
  --symbols CSV          Comma-separated stock tickers (default: list in app.py)
  --cpus N               Docker CPU limit (default 1)
  --mem-limit-mb N       Docker memory limit, MiB (default 1024)
  --cycle-min N          Minimum active time, seconds (default 420)
  --cycle-max N          Maximum active time, seconds (default 540)
  --rest-time N          Rest time, seconds (default 60)
  --download-url URL     HTTPS endpoint accepting ?bytes=N
  --help                 Show this help
EOF
}

if [[ $(id -u) -ne 0 ]]; then
  echo "Run with sudo, for example: curl ... | sudo bash -s -- [options]" >&2
  exit 1
fi

while (($#)); do
  case "$1" in
    --memory-mb) MEMORY_MB="${2:?missing value}"; shift 2 ;;
    --cpu-percent) CPU_PERCENT="${2:?missing value}"; shift 2 ;;
    --download-mb) DOWNLOAD_MB="${2:?missing value}"; shift 2 ;;
    --download-interval) DOWNLOAD_INTERVAL="${2:?missing value}"; shift 2 ;;
    --stock-interval) STOCK_INTERVAL="${2:?missing value}"; shift 2 ;;
    --symbols) SYMBOLS="${2:?missing value}"; shift 2 ;;
    --cpus) CONTAINER_CPUS="${2:?missing value}"; shift 2 ;;
    --mem-limit-mb) CONTAINER_MEM_LIMIT_MB="${2:?missing value}"; shift 2 ;;
    --cycle-min) CYCLE_MIN="${2:?missing value}"; shift 2 ;;
    --cycle-max) CYCLE_MAX="${2:?missing value}"; shift 2 ;;
    --rest-time) REST_TIME="${2:?missing value}"; shift 2 ;;
    --download-url) DOWNLOAD_URL="${2:?missing value}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for value in "$MEMORY_MB" "$DOWNLOAD_MB" "$DOWNLOAD_INTERVAL" "$STOCK_INTERVAL" "$CONTAINER_MEM_LIMIT_MB" "$CYCLE_MIN" "$CYCLE_MAX" "$REST_TIME"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "Expected a non-negative integer: $value" >&2; exit 2; }
done
[[ "$CPU_PERCENT" =~ ^[0-9]+$ ]] || { echo "Invalid --cpu-percent" >&2; exit 2; }
[[ "$CONTAINER_CPUS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid --cpus" >&2; exit 2; }
[[ "$SYMBOLS" =~ ^[A-Za-z0-9,._^-]*$ ]] || { echo "Invalid --symbols" >&2; exit 2; }
[[ "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "--download-url must be HTTPS" >&2; exit 2; }
((MEMORY_MB <= 8192 && DOWNLOAD_MB <= 1000)) || { echo "Memory/download setting is above the supported limit" >&2; exit 2; }
((CPU_PERCENT <= 100)) || { echo "--cpu-percent must be between 0 and 100" >&2; exit 2; }
((CONTAINER_MEM_LIMIT_MB >= MEMORY_MB + 512)) || { echo "--mem-limit-mb must exceed --memory-mb by at least 512" >&2; exit 2; }
((CYCLE_MIN <= CYCLE_MAX && CYCLE_MIN >= 30 && DOWNLOAD_INTERVAL >= 30 && STOCK_INTERVAL >= 30)) || { echo "Invalid interval or cycle range" >&2; exit 2; }

if ! command -v curl >/dev/null; then
  echo "curl is required" >&2
  exit 1
fi
if ! command -v docker >/dev/null; then
  echo "Installing Docker Engine using Docker's official installer..."
  curl -fsSL https://get.docker.com | sh
fi
if command -v systemctl >/dev/null; then
  systemctl enable --now docker
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is missing; trying the system package manager..."
  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y docker-compose-plugin
  elif command -v dnf >/dev/null; then
    dnf install -y docker-compose-plugin
  else
    echo "Install the Docker Compose plugin, then rerun this command" >&2
    exit 1
  fi
fi

mkdir -p "$INSTALL_DIR"
for file in app.py Dockerfile compose.yaml; do
  curl -fsSL "$BASE_URL/$file" -o "$INSTALL_DIR/$file.new"
done
for file in app.py Dockerfile compose.yaml; do
  mv "$INSTALL_DIR/$file.new" "$INSTALL_DIR/$file"
done
cat > "$INSTALL_DIR/.env.new" <<EOF
MEMORY_MB=$MEMORY_MB
CPU_PERCENT=$CPU_PERCENT
DOWNLOAD_MB=$DOWNLOAD_MB
DOWNLOAD_INTERVAL=$DOWNLOAD_INTERVAL
STOCK_INTERVAL=$STOCK_INTERVAL
CONTAINER_CPUS=$CONTAINER_CPUS
CONTAINER_MEM_LIMIT=${CONTAINER_MEM_LIMIT_MB}m
CYCLE_MIN=$CYCLE_MIN
CYCLE_MAX=$CYCLE_MAX
REST_TIME=$REST_TIME
SYMBOLS=$SYMBOLS
DOWNLOAD_URL=$DOWNLOAD_URL
EOF
mv "$INSTALL_DIR/.env.new" "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"
cd "$INSTALL_DIR"
docker compose up -d --build
echo "Installed in $INSTALL_DIR"
echo "Status: sudo docker compose -f $INSTALL_DIR/compose.yaml ps"
echo "Logs:   sudo docker compose -f $INSTALL_DIR/compose.yaml logs -f --tail=100"
echo "Stop:   sudo docker compose -f $INSTALL_DIR/compose.yaml down"
