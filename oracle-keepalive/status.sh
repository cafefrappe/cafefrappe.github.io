#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/oracle-keepalive"
NAME="keeporaclealive"

cpu_times() {
  awk 'NR==1 {idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; printf "%.0f %.0f\n", total, idle}' /proc/stat
}
default_interface="$(ip route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
if [[ -z "$default_interface" ]]; then
  default_interface="$(awk '$2=="00000000" {print $1; exit}' /proc/net/route)"
fi
net_bytes() {
  if [[ -z "$default_interface" ]]; then echo '0 0'; return; fi
  awk -F: -v iface="$default_interface" '$1 ~ "^[[:space:]]*" iface "[[:space:]]*$" {gsub(/^[[:space:]]+/, "", $2); split($2,a,/[[:space:]]+/); print a[1],a[9]}' /proc/net/dev
}

echo "=== 整机配置 ==="
printf 'vCPU: %s\n' "$(nproc)"
awk '/^MemTotal:/ {printf "物理内存: %.1f GiB\n", $2/1048576}' /proc/meminfo
echo "已挂载的磁盘文件系统："
df -hT -x tmpfs -x devtmpfs
if command -v lsblk >/dev/null; then
  echo "物理/虚拟磁盘："
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
fi
echo "本项目数据所在磁盘："
df -h /opt
if [[ -d "$INSTALL_DIR/data" ]]; then
  printf '本项目数据目录: '
  du -sh "$INSTALL_DIR/data" | awk '{print $1}'
fi

read -r total_before idle_before < <(cpu_times)
read -r rx_before tx_before < <(net_bytes)
sleep 5
read -r total_after idle_after < <(cpu_times)
read -r rx_after tx_after < <(net_bytes)
cpu_now="$(awk -v t1="$total_before" -v t2="$total_after" -v i1="$idle_before" -v i2="$idle_after" 'BEGIN {dt=t2-t1; if(dt>0) printf "%.1f", 100*(dt-(i2-i1))/dt; else print "?"}')"
printf '\n=== 整机负载 ===\nCPU（5 秒采样）: %s%%\n' "$cpu_now"
if [[ -f "$INSTALL_DIR/metrics.env" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$INSTALL_DIR/metrics.env") ))
  if ((age <= 30)); then
    awk -F= '/^CPU_AVG_1M=/ {one=$2} /^CPU_AVG_5M=/ {five=$2} /^MEM_AVG_1M=/ {mem_one=$2} /^MEM_AVG_5M=/ {mem_five=$2} /^CPU_SAMPLES=/ {count=$2} END {printf "CPU（最近约 1 分钟）: %s%%\nCPU（最近约 5 分钟）: %s%%\n内存（最近约 1 分钟）: %s%%\n内存（最近约 5 分钟）: %s%%\n累计采样: %s 次，每 5 秒一次\n", one, five, mem_one, mem_five, count}' "$INSTALL_DIR/metrics.env"
  else
    echo "长期 CPU 采样数据已过期；检查容器是否运行"
  fi
fi
awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2} END {printf "内存: 已用 %.1f / %.1f GiB (%.1f%%)\n", (total-available)/1048576, total/1048576, 100*(total-available)/total}' /proc/meminfo
if [[ "$rx_before" =~ ^[0-9]+$ && "$rx_after" =~ ^[0-9]+$ ]]; then
  awk -v iface="$default_interface" -v rx1="$rx_before" -v rx2="$rx_after" -v tx1="$tx_before" -v tx2="$tx_after" 'BEGIN {printf "网络 %s（5 秒平均）: 下载 %.2f MiB/s，上传 %.2f MiB/s\n", iface, (rx2-rx1)/5/1048576, (tx2-tx1)/5/1048576}'
fi
uptime

if command -v docker >/dev/null && docker info >/dev/null 2>&1 && docker inspect "$NAME" >/dev/null 2>&1; then
  echo
  echo "=== 保活容器（辅助信息） ==="
  docker inspect --format '状态: {{.State.Status}}，重启次数: {{.RestartCount}}，启动时间: {{.State.StartedAt}}' "$NAME"
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' "$NAME"
else
  echo "保活容器未运行"
fi
if [[ -f "$INSTALL_DIR/runtime.env" ]]; then
  echo
  echo "=== 当前目标 ==="
  grep -E '^(CPU_TARGET_PERCENT|MEMORY_TARGET_PERCENT|DISK_TARGET_PERCENT|MEMORY_CAP_MB|DISK_CAP_MB|DOWNLOAD_MB|DOWNLOAD_INTERVAL|STOCK_INTERVAL|DAILY_PAUSE_MINUTES)=' "$INSTALL_DIR/runtime.env" || true
fi
