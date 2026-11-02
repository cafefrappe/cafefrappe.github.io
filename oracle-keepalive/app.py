#!/usr/bin/env python3
"""Configurable workload based on the final example in 保活.docx."""
from __future__ import annotations

import os
import random
import statistics
import threading
import time
import multiprocessing
from pathlib import Path
from collections import defaultdict, deque
from datetime import datetime

import numpy as np
import requests
import yfinance as yf


DEFAULT_SYMBOLS = (
    "EWY SPY QQQ SCHD LWLG QUBT IBM NOK BB CSTM SCHW AIQ CHAT SCHG IBKR AMD INTC "
    "DRAM EUV COHR SPCX GLW AAOI CIEN NBIS AXTI AEHR BE SNDK MU AVGO LITE MRVL "
    "AAPL NVDA MSFT AMZN GOOG META TSLA TSM QCOM TXN ADI NXPI ON ARM WDC STX "
    "KLAC LRCX AMAT ASML TER PSX CDNS SNPS MPWR FORM ONTO ORCL CRM ADBE CSCO "
    "PYPL SQ SHOP NOW SNOW PLTR CRWD DDOG PANW FTNT NET ZS TEAM MDB DOCU UBER "
    "JPM BAC V MA GS MS AXP BLK BX COF VOO IWM XLK SMH SOXX XLC XLF ARKK VTI "
    "VXUS NFLX DIS CMCSA PFE LLY ABBV JNJ UNH XOM CVX"
)


def number(name: str, default: str, minimum: float = 0) -> float:
    value = float(os.getenv(name, default))
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    return value


MEMORY_TARGET_PERCENT = int(number("MEMORY_TARGET_PERCENT", "10"))
MEMORY_CAP_MB = int(number("MEMORY_CAP_MB", "1024"))
CPU_PERCENT = number("CPU_TARGET_PERCENT", "25")
HOST_CPUS = int(number("HOST_CPUS", str(os.cpu_count() or 1), 1))
DOWNLOAD_MB = int(number("DOWNLOAD_MB", "10"))
DOWNLOAD_INTERVAL = number("DOWNLOAD_INTERVAL", "1800", 30)
STOCK_INTERVAL = number("STOCK_INTERVAL", "300", 30)
WEATHER_INTERVAL = number("WEATHER_INTERVAL", "180", 30)
FX_INTERVAL = number("FX_INTERVAL", "120", 30)
CLOUD_INTERVAL = number("CLOUD_INTERVAL", "300", 30)
ANALYTICS_INTERVAL = number("ANALYTICS_INTERVAL", "60", 10)
CYCLE_MIN = int(number("CYCLE_MIN", "420", 30))
CYCLE_MAX = int(number("CYCLE_MAX", "540", 30))
REST_TIME = number("REST_TIME", "60")
SYMBOLS = [s.strip().upper() for s in (os.getenv("SYMBOLS") or DEFAULT_SYMBOLS).replace(",", " ").split()]
DOWNLOAD_URL = os.getenv("DOWNLOAD_URL", "https://speed.cloudflare.com/__down")
CONFIG_PATH = Path("/config/runtime.env")
METRICS_PATH = Path("/config/metrics.env")
CONFIG_VERSION = 0

if not 0 <= CPU_PERCENT <= 100:
    raise ValueError("CPU_PERCENT must be between 0 and 100")
if CYCLE_MIN > CYCLE_MAX:
    raise ValueError("CYCLE_MIN cannot exceed CYCLE_MAX")
if not 0 <= MEMORY_TARGET_PERCENT <= 70 or DOWNLOAD_MB > 1000:
    raise ValueError("MEMORY_TARGET_PERCENT must be 0..70 and DOWNLOAD_MB <= 1000")

active = threading.Event()
active.set()
stock_history: dict[str, deque[float]] = defaultdict(lambda: deque(maxlen=200))
counts = defaultdict(int)
memory_pool: list[bytearray] = []
lock = threading.Lock()


def log(tag: str, message: str) -> None:
    print(f"{datetime.now().astimezone().isoformat(timespec='seconds')} [{tag}] {message}", flush=True)


def wait_active() -> None:
    while not active.is_set():
        time.sleep(1)


def read_host_memory() -> tuple[int, int]:
    values = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, raw = line.split(":", 1)
        values[key] = int(raw.strip().split()[0]) // 1024
    return values["MemTotal"], values["MemAvailable"]


def read_cpu_times() -> tuple[int, int]:
    values = [int(x) for x in Path("/proc/stat").read_text().splitlines()[0].split()[1:]]
    return sum(values), values[3] + values[4]


def reload_config() -> None:
    global CONFIG_VERSION, CPU_PERCENT, MEMORY_TARGET_PERCENT, MEMORY_CAP_MB
    global DOWNLOAD_MB, DOWNLOAD_INTERVAL, STOCK_INTERVAL, WEATHER_INTERVAL
    global FX_INTERVAL, CLOUD_INTERVAL, ANALYTICS_INTERVAL, CYCLE_MIN, CYCLE_MAX, REST_TIME
    global SYMBOLS, DOWNLOAD_URL
    fields = {
        "CPU_TARGET_PERCENT": ("CPU_PERCENT", 0, 80),
        "MEMORY_TARGET_PERCENT": ("MEMORY_TARGET_PERCENT", 0, 70),
        "MEMORY_CAP_MB": ("MEMORY_CAP_MB", 0, 1000000),
        "DOWNLOAD_MB": ("DOWNLOAD_MB", 0, 1000),
        "DOWNLOAD_INTERVAL": ("DOWNLOAD_INTERVAL", 30, 86400),
        "STOCK_INTERVAL": ("STOCK_INTERVAL", 30, 86400),
        "WEATHER_INTERVAL": ("WEATHER_INTERVAL", 30, 86400),
        "FX_INTERVAL": ("FX_INTERVAL", 30, 86400),
        "CLOUD_INTERVAL": ("CLOUD_INTERVAL", 30, 86400),
        "ANALYTICS_INTERVAL": ("ANALYTICS_INTERVAL", 10, 86400),
        "CYCLE_MIN": ("CYCLE_MIN", 30, 86400),
        "CYCLE_MAX": ("CYCLE_MAX", 30, 86400),
        "REST_TIME": ("REST_TIME", 0, 3600),
    }
    try:
        entries = {}
        for line in CONFIG_PATH.read_text().splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                entries[key] = value
        parsed = {}
        for key, (name, lower, upper) in fields.items():
            value = int(entries[key])
            if not lower <= value <= upper:
                raise ValueError(f"{key} must be {lower}..{upper}")
            parsed[name] = value
        if parsed["CYCLE_MIN"] > parsed["CYCLE_MAX"]:
            raise ValueError("CYCLE_MIN exceeds CYCLE_MAX")
        symbols = entries.get("SYMBOLS", "").replace(",", " ").split() or DEFAULT_SYMBOLS.split()
        url = entries.get("DOWNLOAD_URL", DOWNLOAD_URL)
        if not url.startswith("https://"):
            raise ValueError("DOWNLOAD_URL must use HTTPS")
        if any(globals()[name] != value for name, value in parsed.items()) or SYMBOLS != symbols or DOWNLOAD_URL != url:
            globals().update(parsed)
            SYMBOLS = symbols
            DOWNLOAD_URL = url
            CONFIG_VERSION += 1
            log("CONFIG", f"loaded CPU target={CPU_PERCENT}% host, RAM target={MEMORY_TARGET_PERCENT}% host, download={DOWNLOAD_MB}MiB/{DOWNLOAD_INTERVAL}s")
    except (OSError, KeyError, ValueError) as exc:
        log("CONFIG", f"configuration not loaded: {exc}")


def reload_loop() -> None:
    while True:
        reload_config()
        time.sleep(5)


def pause_for(name: str) -> None:
    original_interval = globals()[name]
    end = time.monotonic() + original_interval
    while time.monotonic() < end:
        time.sleep(max(0, min(1, end - time.monotonic())))
        if globals()[name] != original_interval:
            return


def cycle() -> None:
    while True:
        duration = random.randint(CYCLE_MIN, CYCLE_MAX)
        active.set()
        log("CORE", f"active for {duration}s")
        time.sleep(duration)
        active.clear()
        log("CORE", f"rest for {REST_TIME}s")
        time.sleep(REST_TIME)


def cpu_worker(duty_cycle: multiprocessing.Value, worker_index: int, worker_count: int) -> None:
    # Separate processes can use multiple cores; Python threads share one interpreter lock.
    period = 0.5
    value = worker_index + 1
    time.sleep(period * worker_index / worker_count)
    while True:
        start = time.monotonic()
        busy = period * duty_cycle.value
        while time.monotonic() - start < busy:
            value = (value * 1664525 + 1013904223) & 0xFFFFFFFF
        time.sleep(max(0, period - (time.monotonic() - start)))


def cpu_controller(duty_cycle: multiprocessing.Value) -> None:
    history: deque[float] = deque(maxlen=60)
    memory_history: deque[float] = deque(maxlen=60)
    previous = read_cpu_times()
    while True:
        time.sleep(5)
        current = read_cpu_times()
        total = current[0] - previous[0]
        idle = current[1] - previous[1]
        previous = current
        if total <= 0:
            continue
        history.append(100 * (total - idle) / total)
        avg_1m = statistics.mean(list(history)[-12:])
        avg_5m = statistics.mean(history)
        correction = max(-0.05, min(0.05, (CPU_PERCENT - avg_1m) * 0.0025))
        duty_cycle.value = max(0, min(0.9, duty_cycle.value + correction))
        total_mb, available_mb = read_host_memory()
        used_percent = 100 * (total_mb - available_mb) / total_mb
        memory_history.append(used_percent)
        metrics = (f"CPU_AVG_1M={avg_1m:.1f}\nCPU_AVG_5M={avg_5m:.1f}\n"
                   f"CPU_SAMPLES={len(history)}\nMEM_USED_PERCENT={used_percent:.1f}\n"
                   f"MEM_AVG_1M={statistics.mean(list(memory_history)[-12:]):.1f}\n"
                   f"MEM_AVG_5M={statistics.mean(memory_history):.1f}\n"
                   f"CPU_WORKER_DUTY={duty_cycle.value * 100:.1f}\n")
        temp = METRICS_PATH.with_suffix(".new")
        temp.write_text(metrics)
        temp.replace(METRICS_PATH)


def memory() -> None:
    while True:
        total_mb, available_mb = read_host_memory()
        used_mb = total_mb - available_mb
        desired = round(max(0, min(MEMORY_CAP_MB,
                        len(memory_pool) + total_mb * MEMORY_TARGET_PERCENT / 100 - used_mb)))
        desired = min(desired, len(memory_pool) + max(0, available_mb - 256))
        if desired > len(memory_pool):
            for _ in range(min(desired - len(memory_pool), 16)):
                memory_pool.append(bytearray(1024 * 1024))
        elif desired < len(memory_pool):
            del memory_pool[max(desired, len(memory_pool) - 16):]
        time.sleep(1)


def download() -> None:
    while True:
        wait_active()
        if DOWNLOAD_MB:
            target = DOWNLOAD_MB * 1024 * 1024
            url = f"{DOWNLOAD_URL}?bytes={target}" if "?" not in DOWNLOAD_URL else DOWNLOAD_URL
            started = time.monotonic()
            received = 0
            try:
                with requests.get(url, stream=True, timeout=(10, 30)) as response:
                    response.raise_for_status()
                    for chunk in response.iter_content(65536):
                        if not active.is_set() or received >= target:
                            break
                        received += min(len(chunk), target - received)
                log("DOWNLOAD", f"{received / 1048576:.1f} MiB in {time.monotonic() - started:.1f}s")
            except requests.RequestException as exc:
                log("DOWNLOAD", f"error: {exc}")
        pause_for("DOWNLOAD_INTERVAL")


def stocks() -> None:
    while True:
        wait_active()
        for symbol in SYMBOLS:
            if not active.is_set():
                break
            try:
                price = float(yf.Ticker(symbol).fast_info["lastPrice"])
                with lock:
                    stock_history[symbol].append(price)
                    counts["stock"] += 1
            except Exception as exc:
                log("STOCK", f"{symbol}: {type(exc).__name__}")
        log("STOCK", f"prices collected: {counts['stock']}")
        pause_for("STOCK_INTERVAL")


def weather() -> None:
    while True:
        wait_active()
        try:
            response = requests.get("https://wttr.in/?format=3", timeout=10)
            response.raise_for_status()
            log("WEATHER", response.text.strip()[:200])
            counts["weather"] += 1
        except requests.RequestException as exc:
            log("WEATHER", f"error: {exc}")
        pause_for("WEATHER_INTERVAL")


def fx() -> None:
    while True:
        wait_active()
        try:
            response = requests.get("https://open.er-api.com/v6/latest/USD", timeout=10)
            response.raise_for_status()
            cny = response.json()["rates"]["CNY"]
            log("FX", f"USD/CNY {cny}")
            counts["fx"] += 1
        except (requests.RequestException, KeyError, ValueError) as exc:
            log("FX", f"error: {exc}")
        pause_for("FX_INTERVAL")


def cloud() -> None:
    urls = ("https://status.azure.com", "https://health.aws.amazon.com", "https://ocistatus.oraclecloud.com")
    while True:
        wait_active()
        for url in urls:
            try:
                response = requests.get(url, timeout=10)
                log("CLOUD", f"{url} HTTP {response.status_code}")
                counts["cloud"] += 1
            except requests.RequestException as exc:
                log("CLOUD", f"{url}: {exc}")
        pause_for("CLOUD_INTERVAL")


def analytics() -> None:
    while True:
        wait_active()
        with lock:
            snapshot = {key: list(values) for key, values in stock_history.items()}
        report = []
        ranking = []
        for symbol, prices in snapshot.items():
            if len(prices) < 20:
                continue
            recent = np.asarray(prices[-20:], dtype=float)
            mean = statistics.mean(prices[-200:])
            volatility = float(np.std(np.diff(recent)))
            price_volatility = float(np.std(recent) / mean * 100) if mean else 0.0
            ema20 = float(np.mean(recent))
            momentum = float(recent[-1] - recent[0])
            report.append(f"{symbol}: avg={mean:.2f} ma20={ema20:.2f} vol={price_volatility:.2f}%")
            ranking.append((abs(momentum), symbol, momentum, volatility))
        ranking.sort(reverse=True)
        if report:
            log("ANALYTICS", "; ".join(report[:5]))
            log("MARKET SCAN", "; ".join(f"{s} momentum={m:.2f} vol={v:.4f}" for _, s, m, v in ranking[:5]))
        pause_for("ANALYTICS_INTERVAL")


def status() -> None:
    while True:
        log("STATUS", f"stock={counts['stock']} weather={counts['weather']} fx={counts['fx']} cloud={counts['cloud']} memory={len(memory_pool)}MiB")
        time.sleep(30)


def main() -> None:
    reload_config()
    duty_cycle = multiprocessing.Value("d", 0.0)
    log("CONFIG", f"host_cpus={HOST_CPUS} symbols={len(SYMBOLS)} CPU target={CPU_PERCENT}% whole host, RAM target={MEMORY_TARGET_PERCENT}% whole host")
    for index in range(HOST_CPUS):
        multiprocessing.Process(target=cpu_worker, args=(duty_cycle, index, HOST_CPUS), daemon=True).start()
    for name, target in (("config-reload", reload_loop),
                         ("cpu-controller", lambda: cpu_controller(duty_cycle)),
                         ("cycle", cycle), ("memory", memory), ("download", download),
                         ("stocks", stocks), ("weather", weather), ("fx", fx), ("cloud", cloud),
                         ("analytics", analytics), ("status", status)):
        threading.Thread(name=name, target=target, daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
