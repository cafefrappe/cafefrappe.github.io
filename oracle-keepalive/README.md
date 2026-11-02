# Oracle VPS 一键部署保活工作负载

按《保活.docx》最后一版整理：股票行情及统计、天气、美元兑人民币汇率、云平台状态、可控内存占用、周期性 CPU 工作和定量下载。运行时通过 Docker Compose 自动重启，并限制容器资源与日志大小。适用于 Linux x86_64 / ARM64 VPS；机器需要能访问 GitHub、Docker 镜像源和相关数据网站。

## 一行安装

在 VPS 上执行（Ubuntu/Debian；其他已安装 Docker Engine 和 Compose 的 Linux 也可）：

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/oracle-keepalive/install.sh | sudo bash -s -- --memory-mb 2500 --mem-limit-mb 6144 --cpus 1 --cpu-percent 10 --download-mb 100 --download-interval 120
```

这组参数接近文档最后的 2.5 GB 内存、100 MB/2 分钟下载配置。**100 MB/2 分钟约为 72 GB/天**，会产生明显流量。无需指定参数时，默认使用 256 MiB 内存、一个核心的约 10% CPU、10 MiB/10 分钟下载。安装脚本会检测 Docker；缺失时运行 Docker 官方安装脚本，再构建容器并在后台启动。

重新运行同一命令可更新文件和配置。若不想使用默认股票列表，可加 `--symbols SPY,QQQ,AAPL`。用 `--download-mb 0` 禁用大文件下载。

## 常用参数

| 参数 | 默认 | 作用 |
|---|---:|---|
| `--memory-mb` | 256 | 容器内额外占用的内存 MiB |
| `--mem-limit-mb` | 1024 | Docker 容器内存上限 MiB，至少比上述值多 512 |
| `--cpus` | 1 | Docker CPU 核数上限 |
| `--cpu-percent` | 10 | 约占一个核心的百分比，受 `--cpus` 上限约束 |
| `--download-mb` | 10 | 每轮最多下载的 MiB，0 为关闭 |
| `--download-interval` | 600 | 两轮下载之间秒数 |
| `--stock-interval` | 300 | 两轮股票扫描之间秒数 |
| `--symbols` | 文档股票列表 | 英文逗号分隔的代码 |
| `--cycle-min` / `--cycle-max` | 420 / 540 | 运行阶段随机时长范围（秒） |
| `--rest-time` | 60 | 休息时长（秒） |
| `--download-url` | Cloudflare 下载接口 | 自选 HTTPS 下载接口，支持 `?bytes=N` |

行情、天气、汇率及云平台接口可能失败或限流，失败会记录在日志中并等待下一轮。文档中的超高频股票请求已调整为每 300 秒扫描一次，防止对外部服务发出大量请求。内存占用是额外分配量，容器实际用量还包含 Python 和依赖库。

## 管理

```sh
sudo docker compose -f /opt/oracle-keepalive/compose.yaml ps
sudo docker compose -f /opt/oracle-keepalive/compose.yaml logs -f --tail=100
sudo docker stats keeporaclealive
sudo docker compose -f /opt/oracle-keepalive/compose.yaml down
```

这只是运行工作负载的工具；Oracle 是否保留免费实例取决于其当时的政策和实际使用情况，脚本无法保证结果。
