#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive"
INSTALL_DIR="/opt/oracle-keepalive"
MEMORY_CAP_MB=""
CPU_TARGET_PERCENT=25
MEMORY_TARGET_PERCENT=10
DOWNLOAD_MB=10
DOWNLOAD_INTERVAL=1800
STOCK_INTERVAL=300
CONTAINER_CPUS=""
CONTAINER_MEM_LIMIT_MB=""
CYCLE_MIN=420
CYCLE_MAX=540
REST_TIME=60
SYMBOLS=""
DOWNLOAD_URL="https://speed.cloudflare.com/__down"

usage() {
  cat <<'EOF'
Usage: curl -fsSL URL/install.sh | sudo bash -s -- [options]

  --cpu-target N         Target percent of whole VPS CPU (default 25)
  --memory-target N      Target percent of whole VPS RAM (default 10)
  --memory-cap-mb N      Maximum extra RAM allocation (default: half of VPS RAM)
  --download-mb N        Data downloaded per round, MiB; 0 disables (default 10)
  --download-interval N  Seconds between downloads (default 1800)
  --stock-interval N     Seconds between stock scans (default 300)
  --symbols CSV          Comma-separated stock tickers (default: list in app.py)
  --cpus N               Docker CPU limit (default: detected VPS vCPUs)
  --mem-limit-mb N       Docker memory limit, MiB (default: 70% of VPS RAM)
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
    --cpu-target|--cpu-percent) CPU_TARGET_PERCENT="${2:?missing value}"; shift 2 ;;
    --memory-target) MEMORY_TARGET_PERCENT="${2:?missing value}"; shift 2 ;;
    --memory-cap-mb|--memory-mb) MEMORY_CAP_MB="${2:?missing value}"; shift 2 ;;
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

for value in "$CPU_TARGET_PERCENT" "$MEMORY_TARGET_PERCENT" "$DOWNLOAD_MB" "$DOWNLOAD_INTERVAL" "$STOCK_INTERVAL" "$CYCLE_MIN" "$CYCLE_MAX" "$REST_TIME"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "Expected a non-negative integer: $value" >&2; exit 2; }
done
for value in "$MEMORY_CAP_MB" "$CONTAINER_MEM_LIMIT_MB"; do
  [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] || { echo "Expected an integer: $value" >&2; exit 2; }
done
[[ -z "$CONTAINER_CPUS" || "$CONTAINER_CPUS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid --cpus" >&2; exit 2; }
[[ "$SYMBOLS" =~ ^[A-Za-z0-9,._^-]*$ ]] || { echo "Invalid --symbols" >&2; exit 2; }
[[ "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "--download-url must be HTTPS" >&2; exit 2; }
((CPU_TARGET_PERCENT <= 80 && MEMORY_TARGET_PERCENT <= 70 && DOWNLOAD_MB <= 1000)) || { echo "Target or download amount exceeds supported range" >&2; exit 2; }
((CYCLE_MIN <= CYCLE_MAX && CYCLE_MIN >= 30 && DOWNLOAD_INTERVAL >= 30 && STOCK_INTERVAL >= 30)) || { echo "Invalid interval or cycle range" >&2; exit 2; }

HOST_CPUS="$(nproc)"
HOST_MEMORY_MB="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
DISK_PATH=/
[[ -d /var/lib/docker ]] && DISK_PATH=/var/lib/docker
read -r DISK_TOTAL_MB DISK_FREE_MB < <(df -Pm "$DISK_PATH" | awk 'NR==2 {print $2, $4}')
echo "Detected VPS: ${HOST_CPUS} vCPUs, ${HOST_MEMORY_MB} MiB RAM, ${DISK_TOTAL_MB} MiB disk (${DISK_FREE_MB} MiB free on $DISK_PATH)"
((HOST_CPUS >= 1 && HOST_MEMORY_MB >= 1024)) || { echo "At least one vCPU and 1 GiB RAM are required" >&2; exit 1; }
((DISK_FREE_MB >= 1024)) || { echo "Less than 1 GiB disk free; refusing Docker build" >&2; exit 1; }
[[ -n "$CONTAINER_CPUS" ]] || CONTAINER_CPUS="$HOST_CPUS"
[[ -n "$CONTAINER_MEM_LIMIT_MB" ]] || CONTAINER_MEM_LIMIT_MB=$((HOST_MEMORY_MB * 70 / 100))
((CONTAINER_MEM_LIMIT_MB >= 512 && CONTAINER_MEM_LIMIT_MB <= HOST_MEMORY_MB)) || { echo "Invalid container memory limit for this VPS" >&2; exit 2; }
AUTO_MEMORY_CAP_MB=$((HOST_MEMORY_MB / 2))
((AUTO_MEMORY_CAP_MB <= CONTAINER_MEM_LIMIT_MB - 256)) || AUTO_MEMORY_CAP_MB=$((CONTAINER_MEM_LIMIT_MB - 256))
[[ -n "$MEMORY_CAP_MB" ]] || MEMORY_CAP_MB="$AUTO_MEMORY_CAP_MB"
((MEMORY_CAP_MB <= CONTAINER_MEM_LIMIT_MB - 256)) || { echo "Memory cap must leave at least 256 MiB inside the container" >&2; exit 2; }
awk -v cap="$CONTAINER_CPUS" -v cores="$HOST_CPUS" -v target="$CPU_TARGET_PERCENT" 'BEGIN {exit !(cap >= cores * target / 100 + 0.2)}' || { echo "--cpus is too low for the requested whole-VPS CPU target" >&2; exit 2; }

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
CONTAINER_CPUS=$CONTAINER_CPUS
CONTAINER_MEM_LIMIT=${CONTAINER_MEM_LIMIT_MB}m
HOST_CPUS=$HOST_CPUS
EOF
cat > "$INSTALL_DIR/defaults-load.env" <<EOF
CPU_TARGET_PERCENT=25
MEMORY_TARGET_PERCENT=10
MEMORY_CAP_MB=$AUTO_MEMORY_CAP_MB
EOF
cat > "$INSTALL_DIR/defaults-absolute.env" <<EOF
DOWNLOAD_MB=10
DOWNLOAD_INTERVAL=1800
STOCK_INTERVAL=300
WEATHER_INTERVAL=180
FX_INTERVAL=120
CLOUD_INTERVAL=300
ANALYTICS_INTERVAL=60
CYCLE_MIN=420
CYCLE_MAX=540
REST_TIME=60
SYMBOLS=
DOWNLOAD_URL=https://speed.cloudflare.com/__down
EOF
cat > "$INSTALL_DIR/runtime.env.new" <<EOF
HOST_CPUS=$HOST_CPUS
CPU_TARGET_PERCENT=$CPU_TARGET_PERCENT
MEMORY_TARGET_PERCENT=$MEMORY_TARGET_PERCENT
MEMORY_CAP_MB=$MEMORY_CAP_MB
DOWNLOAD_MB=$DOWNLOAD_MB
DOWNLOAD_INTERVAL=$DOWNLOAD_INTERVAL
STOCK_INTERVAL=$STOCK_INTERVAL
WEATHER_INTERVAL=180
FX_INTERVAL=120
CLOUD_INTERVAL=300
ANALYTICS_INTERVAL=60
CYCLE_MIN=$CYCLE_MIN
CYCLE_MAX=$CYCLE_MAX
REST_TIME=$REST_TIME
SYMBOLS=$SYMBOLS
DOWNLOAD_URL=$DOWNLOAD_URL
EOF
mv "$INSTALL_DIR/.env.new" "$INSTALL_DIR/.env"
mv "$INSTALL_DIR/runtime.env.new" "$INSTALL_DIR/runtime.env"
chmod 600 "$INSTALL_DIR/.env" "$INSTALL_DIR/runtime.env" "$INSTALL_DIR/defaults-load.env" "$INSTALL_DIR/defaults-absolute.env"
cd "$INSTALL_DIR"
docker compose up -d --build
echo "Installed in $INSTALL_DIR"
echo "Status: sudo docker compose -f $INSTALL_DIR/compose.yaml ps"
echo "Logs:   sudo docker compose -f $INSTALL_DIR/compose.yaml logs -f --tail=100"
echo "Stop:   sudo docker compose -f $INSTALL_DIR/compose.yaml down"
echo "Runtime targets can be changed with control.sh; see README.md"
