#!/usr/bin/env bash
set -euo pipefail

DIR=/opt/oracle-keepalive
if [[ $(id -u) -ne 0 ]]; then echo "Run with sudo" >&2; exit 1; fi
for file in runtime.env defaults-load.env defaults-absolute.env .env; do
  [[ -f "$DIR/$file" ]] || { echo "Missing $DIR/$file; rerun the installer first" >&2; exit 1; }
done

declare -A cfg
read_values() {
  local file="$1" key value
  while IFS='=' read -r key value; do
    case "$key" in
      HOST_CPUS|CPU_TARGET_PERCENT|MEMORY_TARGET_PERCENT|MEMORY_CAP_MB|DOWNLOAD_MB|DOWNLOAD_INTERVAL|STOCK_INTERVAL|WEATHER_INTERVAL|FX_INTERVAL|CLOUD_INTERVAL|ANALYTICS_INTERVAL|CYCLE_MIN|CYCLE_MAX|REST_TIME|SYMBOLS|DOWNLOAD_URL)
        cfg["$key"]="$value" ;;
    esac
  done < "$file"
}
read_values "$DIR/runtime.env"
show_only=false
if (($# == 0)); then show_only=true; fi
while (($#)); do
  case "$1" in
    --reset-load) read_values "$DIR/defaults-load.env"; shift ;;
    --reset-absolute) read_values "$DIR/defaults-absolute.env"; shift ;;
    --reset-all) read_values "$DIR/defaults-load.env"; read_values "$DIR/defaults-absolute.env"; shift ;;
    --cpu-target) cfg[CPU_TARGET_PERCENT]="${2:?missing value}"; shift 2 ;;
    --memory-target) cfg[MEMORY_TARGET_PERCENT]="${2:?missing value}"; shift 2 ;;
    --memory-cap-mb) cfg[MEMORY_CAP_MB]="${2:?missing value}"; shift 2 ;;
    --download-mb) cfg[DOWNLOAD_MB]="${2:?missing value}"; shift 2 ;;
    --download-interval) cfg[DOWNLOAD_INTERVAL]="${2:?missing value}"; shift 2 ;;
    --stock-interval) cfg[STOCK_INTERVAL]="${2:?missing value}"; shift 2 ;;
    --weather-interval) cfg[WEATHER_INTERVAL]="${2:?missing value}"; shift 2 ;;
    --fx-interval) cfg[FX_INTERVAL]="${2:?missing value}"; shift 2 ;;
    --cloud-interval) cfg[CLOUD_INTERVAL]="${2:?missing value}"; shift 2 ;;
    --analytics-interval) cfg[ANALYTICS_INTERVAL]="${2:?missing value}"; shift 2 ;;
    --cycle-min) cfg[CYCLE_MIN]="${2:?missing value}"; shift 2 ;;
    --cycle-max) cfg[CYCLE_MAX]="${2:?missing value}"; shift 2 ;;
    --rest-time) cfg[REST_TIME]="${2:?missing value}"; shift 2 ;;
    --symbols) cfg[SYMBOLS]="${2:?missing value}"; shift 2 ;;
    --download-url) cfg[DOWNLOAD_URL]="${2:?missing value}"; shift 2 ;;
    --show) show_only=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

validate_int() {
  local key="$1" min="$2" max="$3" value="${cfg[$1]:-}"
  [[ "$value" =~ ^[0-9]+$ ]] && ((value >= min && value <= max)) || {
    echo "$key must be $min..$max" >&2; exit 2;
  }
}
validate_int HOST_CPUS 1 256
validate_int CPU_TARGET_PERCENT 0 80
validate_int MEMORY_TARGET_PERCENT 0 70
validate_int MEMORY_CAP_MB 0 1000000
validate_int DOWNLOAD_MB 0 1000
validate_int DOWNLOAD_INTERVAL 30 86400
validate_int STOCK_INTERVAL 30 86400
validate_int WEATHER_INTERVAL 30 86400
validate_int FX_INTERVAL 30 86400
validate_int CLOUD_INTERVAL 30 86400
validate_int ANALYTICS_INTERVAL 10 86400
validate_int CYCLE_MIN 30 86400
validate_int CYCLE_MAX 30 86400
validate_int REST_TIME 0 3600
((cfg[CYCLE_MIN] <= cfg[CYCLE_MAX])) || { echo "Cycle minimum exceeds maximum" >&2; exit 2; }
[[ "${cfg[SYMBOLS]:-}" =~ ^[A-Za-z0-9,._^-]*$ ]] || { echo "Invalid symbols" >&2; exit 2; }
[[ "${cfg[DOWNLOAD_URL]:-}" =~ ^https://[^[:space:]]+$ ]] || { echo "Download URL must be HTTPS" >&2; exit 2; }
docker_cpus="$(awk -F= '$1=="CONTAINER_CPUS" {print $2}' "$DIR/.env")"
memory_limit="$(awk -F= '$1=="CONTAINER_MEM_LIMIT" {gsub(/m/, "", $2); print $2}' "$DIR/.env")"
awk -v cap="$docker_cpus" -v cores="${cfg[HOST_CPUS]}" -v target="${cfg[CPU_TARGET_PERCENT]}" 'BEGIN {exit !(cap >= cores * target / 100 + 0.2)}' || {
  echo "Docker CPU limit is too low for this target; rerun installer with a higher --cpus" >&2; exit 2;
}
((cfg[MEMORY_CAP_MB] <= memory_limit - 256)) || {
  echo "Memory cap exceeds Docker limit; rerun installer with a higher --mem-limit-mb" >&2; exit 2;
}

if [[ "$show_only" == true ]]; then
  printf 'VPS: %s vCPUs\nCPU target: %s%% of whole VPS\nRAM target: %s%% of whole VPS (max extra %s MiB)\n' \
    "${cfg[HOST_CPUS]}" "${cfg[CPU_TARGET_PERCENT]}" "${cfg[MEMORY_TARGET_PERCENT]}" "${cfg[MEMORY_CAP_MB]}"
  printf 'Download: %s MiB every %s seconds; stock scan: every %s seconds\n' \
    "${cfg[DOWNLOAD_MB]}" "${cfg[DOWNLOAD_INTERVAL]}" "${cfg[STOCK_INTERVAL]}"
  exit 0
fi

temp="$(mktemp "$DIR/runtime.env.XXXXXX")"
for key in HOST_CPUS CPU_TARGET_PERCENT MEMORY_TARGET_PERCENT MEMORY_CAP_MB DOWNLOAD_MB DOWNLOAD_INTERVAL \
  STOCK_INTERVAL WEATHER_INTERVAL FX_INTERVAL CLOUD_INTERVAL ANALYTICS_INTERVAL CYCLE_MIN CYCLE_MAX REST_TIME \
  SYMBOLS DOWNLOAD_URL; do
  printf '%s=%s\n' "$key" "${cfg[$key]:-}" >> "$temp"
done
chmod 600 "$temp"
mv "$temp" "$DIR/runtime.env"
echo "Updated running targets; container reloads them within about 5 seconds."
