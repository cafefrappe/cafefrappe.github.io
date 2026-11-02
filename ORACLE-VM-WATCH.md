# Oracle VM health check

A small Python 3 script for periodic HTTP health checks from an Oracle Cloud VM or another machine. It is portable and needs no Docker or third-party packages.

It checks real endpoints at a controlled interval. It does not manufacture CPU, memory, or network load, and cannot guarantee that a cloud provider will retain an instance.

## One-line run

Requires `curl` and Python 3 on the machine:

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/scripts/oracle-vm-watch.py | python3 - --url https://ocistatus.oraclecloud.com --interval 300
```

Add `--url URL` again to check more endpoints. The process stays in the foreground; press Ctrl+C to stop.

## Parameters

- `--url` (required, repeatable): endpoint to request with HTTP GET.
- `--interval`: seconds between rounds; minimum 30, default 300.
- `--timeout`: per-request timeout in seconds, default 10.
- `--user-agent`: request User-Agent value.
- `--once`: perform one round and exit.

Example with several endpoints:

```sh
curl -fsSL https://raw.githubusercontent.com/cafefrappe/cafefrappe.github.io/main/scripts/oracle-vm-watch.py | python3 - --url https://ocistatus.oraclecloud.com --url https://example.com/health --interval 600 --timeout 10
```

The script reports each response with a timestamp. HTTP 2xx and 3xx responses are reported as OK; other HTTP statuses and connection errors are reported as FAIL.
