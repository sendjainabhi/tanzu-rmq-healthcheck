# Tanzu RabbitMQ Health Check

A lightweight, read-only diagnostic tool for RabbitMQ clusters running on Tanzu Platform. It connects to the RabbitMQ Management API from a jump host, runs a structured set of health checks across 18 operational categories, and produces a self-contained HTML report with evidence logs — all packaged into a ZIP for sharing with Broadcom Support.

No software is installed on the customer cluster. The script performs HTTP GET requests only and never modifies configuration, publishes messages, or collects credentials or message payloads.

---

## Key Operational Focus Areas

- **Tile & Service Instance Health** — Tanzu RabbitMQ tile status and individual service instance state.
- **Broker & Cluster Availability** — Node operational status, running node count, and cluster availability.
- **Runtime & Host Resources** — Memory allocation, CPU load, disk usage, and Erlang runtime execution parameters.
- **Traffic & Queue Performance** — Queue backlogs, consumer connectivity, channel utilization, and throughput performance.
- **High Availability & Recovery** — Quorum queue quorum consensus, leader distribution, and replica resilience.
- **Operational Limits & Baseline** — RabbitMQ cluster policies, TTL, Dead Letter Exchanges, and limits.
- **Security & Transport** — Certificate lifecycles, TLS configuration listeners, and permissions.
- **Platform Infrastructure** — Underlying BOSH infrastructure and VM host parameters supporting RabbitMQ.
- **Telemetry & Operational Readiness** — Metrics collection freshness, alerting configurations, and monitoring readiness.

---

## Requirements

| Tool | Required | Purpose |
|------|----------|---------|
| `bash` 4+ | Yes | Script runtime |
| `curl` | Yes | Management API calls |
| `jq` | Yes | JSON parsing |
| `openssl` | Optional | TLS certificate expiry check |
| `zip` | Optional | ZIP archive packaging |
| `bosh` CLI | Optional | BOSH VM inventory check |
| `cf` CLI | Optional | CF service plan check |

A RabbitMQ user with at least the **`monitoring`** tag is required for most checks. The **`administrator`** tag is additionally required for user security checks (`/api/users`).

---

## Quick Start

### 1. Create a config file

The easiest way is to run the setup wizard — it asks questions and writes the file for you:

```bash
bash tanzu_rmq_healthcheck.sh --init
```

Or copy the sample and fill in your values manually:

```bash
cp script/rmq.conf.sample rmq.conf
```

**Minimum config:**

```ini
customer=Acme-Corp
url=https://rmq-abc123.sys.example.internal
username=monitor-user
password=S3cur3P@ss
```

**Full config with all options:**

```ini
# ------------------------------------------------------------------
# Tanzu RabbitMQ Health Check — Sample Config
# ------------------------------------------------------------------

# Customer or organisation short name. Required.
# Allowed characters: letters, numbers, hyphen, dot, underscore
customer=Acme-Corp

# RabbitMQ Management API base URL. Required.
# HTTPS only — no path, no credentials, no trailing slash.
url=https://rmq-abc123.sys.example.internal

# RabbitMQ user ID and password
username=monitor-user
password=S3cur3P@ss

# Cluster short name used in filenames and HTML header.
# Auto-derived from the URL hostname if omitted.
# cluster=rmq-prod-01

# Expected number of cluster nodes.
# Auto-detected from /api/nodes if omitted.
# expected_nodes=3

# Output directory. Default: reports/ next to the script.
# output=/home/ubuntu/rmq/reports

# ------------------------------------------------------------------
# BOSH Director access — optional, enables VM inventory check
# All five fields are required together if BOSH checks are needed.
# Values here are only used if the BOSH_* environment variables
# are not already exported in the shell.
# ------------------------------------------------------------------
# bosh_deployment=service-instance_<guid>   BOSH deployment name
# bosh_environment=192.168.100.10           BOSH Director IP or hostname
# bosh_client=ops_manager                   BOSH client / username
# bosh_client_secret=<secret>               BOSH client secret
# bosh_ca_cert=/home/ubuntu/rmq/bosh_ca_cert  Path to Director CA cert
```

---

### 3. Run the script

```bash
chmod +x tanzu_rmq_healthcheck.sh
./tanzu_rmq_healthcheck.sh --config /home/ubuntu/rmq/rmq.conf
```

The script prints live progress to the terminal and writes the report path and ZIP location on completion.

---

## Command-Line Options

All options override values from the config file.

```
Usage: tanzu_rmq_healthcheck.sh [OPTIONS]

  --config FILE            Path to config file
  --customer NAME          Customer/org short name
  --cluster NAME           Cluster short name (default: derived from URL)
  --url URL                RabbitMQ cluster URL (HTTPS, no path)
  --username NAME          RabbitMQ user ID
  --password PASS          RabbitMQ password
  --expected-nodes N       Expected node count
  --output DIR             Report output directory
  --bosh-deployment NAME   BOSH deployment name for VM inventory
  --init                   Run interactive setup wizard to create config file
  --check-config           Validate config and test connectivity only (no checks)
  --insecure               Skip TLS certificate verification (lab/dev only)
  -h, --help               Show this help
```

---

## Output

Each run creates a timestamped directory and ZIP:

```
reports/
└── Acme-Corp_rmq-prod-01_healthcheck_20261113_013122/
    ├── rmq-prod-01_rmq_health_report_20261113_013122.html   ← open in browser
    ├── execution.log
    └── errors.log
Acme-Corp_rmq-prod-01_healthcheck_20261113_013122.zip
```

Open the HTML file in any browser — no internet connection required.

---

## Check Status Reference

| Status | Meaning |
|--------|---------|
| `PASS` | Observed value meets the baseline |
| `WARNING` | Observed value exceeds a soft threshold — investigate |
| `CRITICAL` | Observed value exceeds a hard threshold — act immediately |
| `REVIEW` | Requires customer workload or architecture judgment; not a failure |
| `NOT VERIFIED` | Evidence unavailable — missing API access, permissions, or tooling |

**Exit codes:** `0` all clear · `1` warnings · `2` critical · `3` incomplete (NOT VERIFIED) · `4` argument or output error

---

## RabbitMQ User Permissions

The script uses HTTP GET only — no publish, no purge, no config changes.

| API Endpoint | Required Role |
|---|---|
| `/api/overview`, `/api/queues`, `/api/connections`, `/api/channels`, `/api/policies`, `/api/feature-flags`, `/api/health/checks/*` | `monitoring` |
| `/api/nodes`, `/api/shovels`, `/api/consumers`, `/api/bindings`, `/api/exchanges` | `monitoring` |
| `/api/users` | `administrator` |

If an endpoint returns HTTP 401, the affected checks are marked `NOT VERIFIED` with a note in the evidence log explaining which role to grant.

---

## Security and Privacy

- **No credentials are written to any report or log file.**
- Credentials are written to a temporary file for the duration of the run and deleted on completion — never written to any report or log.
- Shovel source/destination URIs are not collected.
- Message bodies are not collected.
- Usernames are not collected — only counts.
- Queue names and vhost names appear in reports (may reveal business domain — review before sharing).
- Nothing is installed on the customer cluster. No SSH. No config changes.

Always open the HTML report and verify its contents before sharing with Broadcom Support.

---

## Limitations

- Checks are point-in-time snapshots, not continuous monitoring.
- Historical throughput, DR readiness, and backup status require customer-provided evidence.
- Quorum queue replica majority (`HA-02`) requires per-queue API calls and may be incomplete on very large clusters.
- BOSH VM inventory requires an authenticated `bosh` CLI session on the jump host.
- TLS certificate check covers the presented leaf certificate only; full chain trust is validated by `curl`.
