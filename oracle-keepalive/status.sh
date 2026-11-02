#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/oracle-keepalive"
NAME="keeporaclealive"

if ! command -v docker >/dev/null; then
  echo "Docker is not installed; keepalive is not running."
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but its service is not running or cannot be accessed." >&2
  exit 1
fi
if ! docker inspect "$NAME" >/dev/null 2>&1; then
  echo "Keepalive container is not installed or has been removed."
  exit 0
fi

echo "=== 容器状态 ==="
docker inspect --format '名称: {{.Name}}
状态: {{.State.Status}}
启动时间: {{.State.StartedAt}}
重启次数: {{.RestartCount}}
PID: {{.State.Pid}}' "$NAME"

echo
echo "=== 容器实时资源（网络/磁盘 I/O 为启动以来累计值） ==="
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' "$NAME"

if [[ -f "$INSTALL_DIR/.env" ]]; then
  echo
  echo "=== 配置目标 ==="
  grep -E '^(MEMORY_MB|CPU_PERCENT|DOWNLOAD_MB|DOWNLOAD_INTERVAL|STOCK_INTERVAL|CONTAINER_CPUS|CONTAINER_MEM_LIMIT)=' "$INSTALL_DIR/.env" || true
fi

echo
echo "=== 主机负载 ==="
uptime
if command -v free >/dev/null; then free -h; fi
df -h /

echo
echo "=== 最近状态日志 ==="
docker logs --tail 100 "$NAME" 2>&1 | grep '\[STATUS\]' | tail -n 3 || true
