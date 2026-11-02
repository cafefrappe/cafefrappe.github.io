# Oracle VPS 一键部署与动态调节

按《保活.docx》整理股票行情与统计、天气、汇率、云平台状态、CPU/内存/磁盘目标占用和定量下载。安装器先读取 VPS 的 vCPU、物理内存及 `/opt` 所在磁盘容量，再部署 Docker Compose。运行中可调整目标，无需重建容器。

## 安装或升级

在 Ubuntu/Debian VPS 上运行；其他已安装 Docker Engine 和 Compose 的 Linux 也可运行：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/install.sh | sudo bash
```

**已安装旧版的 VPS 也需重新运行一次**，使容器获得磁盘数据目录和动态配置。安装器会显示检测到的实际配置。默认目标为整机 CPU **30%**、整机内存 **35%**、`/opt` 所在磁盘已用空间 **35%**。CPU 控制器每 5 秒采样、参考约 1 分钟平均值调节；内存与磁盘控制器按整机当前使用量补足。其他服务已经超过目标时，本程序不会降低它们的占用。目标是近似值，不保证每时每刻达到。

默认下载 10 MiB/30 分钟，约 480 MiB/天；下载内容流式读取后立即丢弃，不保存文件。用于磁盘目标的文件只写入 `/opt/oracle-keepalive/data/managed`。默认项目磁盘上限按该磁盘总量的 35% 计算；写入时预留至少 20% 磁盘空间及 1 GiB 空闲，若空闲空间跌到预留线附近，会清理本项目数据文件。可用 `--disk-cap-mb` 降低上限。大容量磁盘达到目标可能耗时较长。容器日志采用大小轮转。

安装时可指定目标和参数，例如：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/install.sh | sudo bash -s -- --cpu-target 30 --memory-target 35 --disk-target 35 --download-mb 5 --download-interval 3600
```

其他参数：`--memory-cap-mb` 限制额外分配内存，`--cpus` 和 `--mem-limit-mb` 覆盖自动计算的 Docker 上限，`--symbols SPY,QQQ,AAPL` 指定股票代码，`--download-mb 0` 关闭大文件下载，`--daily-pause-minutes 5` 指定每日维护暂停时长。

## 运行中调整

容器每约 5 秒读取一次配置。可随时更改负载目标与查询间隔：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/control.sh | sudo bash -s -- --cpu-target 32 --memory-target 36 --disk-target 36 --download-mb 5 --download-interval 3600 --stock-interval 600
```

恢复**默认负载参数**（CPU 30%、内存 35%、磁盘 35%及分配上限）：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/control.sh | sudo bash -s -- --reset-load
```

恢复**默认绝对参数**（下载量与间隔、各数据源查询间隔、运行/休息时长、每日暂停时长和股票列表）：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/control.sh | sudo bash -s -- --reset-absolute
```

全部恢复用 `--reset-all`，查看当前目标用 `--show`。其他可调参数见 [control.sh](control.sh)；绝对间隔单位为秒，磁盘/内存上限单位为 MiB。CPU 目标范围 0–80%，内存和磁盘目标范围 0–55%。

## 每日维护

容器每运行约 24 小时，会暂停工作负载，释放本项目分配的内存，删除 `/opt/oracle-keepalive/data/managed` 中本程序创建的全部 `block-*.bin` 文件，默认等待 5 分钟后退出，由 Docker 自动重启全新进程。**不会删除 VPS 系统文件、其他程序文件或 Docker 的其他镜像/卷。** 如需禁用磁盘填充，可运行 `control.sh --disk-target 0`。

## 查询整机状态

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/status.sh | sudo bash
```

报告整机 vCPU、物理内存、磁盘使用率、5 秒 CPU/网络速率、约 1 分钟和 5 分钟的整机 CPU/内存平均值，以及容器资源作为辅助信息。首次安装后要运行约 5 分钟，5 分钟平均值才覆盖完整窗口。云平台网站采样周期和计算口径可能不同，数值不一定完全一致。

## 删除

保留 Docker：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/uninstall.sh | sudo bash -s -- --keep-docker
```

同时卸载 Docker 软件包：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/uninstall.sh | sudo bash -s -- --remove-docker
```

卸载 Docker 前会检查是否有其他容器。Docker 旧数据目录默认保留。[Docker 官方文档](https://docs.docker.com/engine/install/ubuntu/#uninstall-docker-engine)也将软件包与数据的删除分开处理。

查看日志：`sudo docker compose -f /opt/oracle-keepalive/compose.yaml logs -f --tail=100`。

外部行情、天气和汇率接口可能失败或限流；失败会记入日志并在下一轮重试。脚本无法保证云平台保留免费实例。
