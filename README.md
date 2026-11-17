# Tanzu RabbitMQ Health Check

A lightweight, read-only diagnostic tool for RabbitMQ 4.x clusters running on Tanzu Platform 10+. It connects to the RabbitMQ Management API from a jump host, runs structured health checks across **18 operational categories**, and produces a self-contained HTML report with evidence logs — packaged into a ZIP for sharing with Broadcom Support.

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

## Health Check Categories

| # | Category | Key Checks |
|---|----------|------------|
| 1 | Tile & Service Instance | Runtime version, management plugin match |
| 2 | BOSH Infrastructure | VM process state via BOSH CLI |
| 3 | Cluster & Node Health | Node availability, partition detection, memory/disk alarms |
| 4 | Memory Management | Per-node memory usage and watermark thresholds |
| 5 | Erlang Runtime | Process count, scheduler utilization, GC pressure |
| 6 | Disk & Persistence | Disk free vs watermark thresholds |
| 7 | Queue Health | Queue states, backlog depth, unacknowledged messages |
| 8 | Messaging Performance | Publish/deliver rates, slow consumers, top queues |
| 9 | High Availability & Quorum | Quorum queue leader balance, deprecated HA policies |
| 10 | Connections & Channels | Active connections, blocked connections, channel count |
| 11 | RabbitMQ Configuration | Policies, feature flags, Khepri metadata store |
| 12 | Security & TLS | TLS certificate expiry, guest user, admin count |
| 13 | RabbitMQ 4.x Features | Version check, queue type inventory, Khepri state |
| 14 | Monitoring & Alerting | Stats collection mode, monitoring integration |
| 15 | Recovery & Operational Readiness | Shovel status, federation links, DR readiness |
| 16 | Stream Queues | Stream queue state, replica health, unattended streams |
| 17 | Classic Queues | Classic queue backlog, CQv2 migration posture |
| 18 | Application Health | DLQ depth, auto-ack consumers, prefetch limits, client libraries, redelivery rates, exchange topology |

---

## Application Health Checks (APP-01 to APP-07)

These checks analyse application-level patterns using existing read-only API data — no additional cluster access required beyond the `monitoring` tag.

| Check ID | Title | What It Detects |
|----------|-------|-----------------|
| APP-01 | Dead letter queue depth | DLQs accumulating messages — indicates application processing failures |
| APP-02 | Consumer auto-acknowledgement | Consumers using auto-ack — risk of silent message loss on crash |
| APP-03 | Queues with no exchange bindings | Queues reachable only via default exchange — topology fragility |
| APP-04 | Consumer channels without prefetch limit | Unlimited prefetch (prefetch_count=0) — risk of consumer crash under load |
| APP-05 | Client library versions | Inventory of AMQP client products and versions in use |
| APP-06 | High redelivery rate per queue | Queues with sustained redelivery >10% of deliver rate — poison messages or consumer failures |
| APP-07 | Exchange topology gaps | User-defined exchanges with no queue bindings — silent message loss |

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

A RabbitMQ user with the **`monitoring`** tag is required for most checks. The **`administrator`** tag is additionally required for user security checks.

---

## Quick Start

### 1. Run the setup wizard (recommended)

The wizard prompts for all required fields and writes the config file:

```bash
bash tanzu_rmq_healthcheck.sh --init
```

Or copy the sample config and fill in manually:

```bash
cp script/rmq.conf.sample rmq.conf
```

**Minimum config (3 required fields):**

```ini
customer=Acme-Corp
url=https://rmq-abc123.sys.example.internal
username=monitor-user
password=S3cur3P@ss
```

**Full config with all options:**

```ini
customer=Acme-Corp
url=https://rmq-abc123.sys.example.internal
username=monitor-user
password=S3cur3P@ss

# Optional — auto-derived from URL if omitted
# cluster=rmq-prod-01

# Optional — auto-detected from /api/nodes if omitted
# expected_nodes=3

# Optional — default: reports/ next to the script
# output=/home/ubuntu/rmq/reports

# BOSH Director access — all five required together for BOSH checks
# bosh_deployment=service-instance_<guid>
# bosh_environment=192.168.100.10
# bosh_client=ops_manager
# bosh_client_secret=<secret>
# bosh_ca_cert=/home/ubuntu/rmq/bosh_ca_cert
```

### 2. Validate connectivity (optional)

Tests API access and permissions without running any health checks:

```bash
bash tanzu_rmq_healthcheck.sh --config rmq.conf --check-config
```

### 3. Run the health check

```bash
bash tanzu_rmq_healthcheck.sh --config rmq.conf
```

The script prints live progress, runs a pre-scan showing what is and isn't accessible, then executes all checks. Typical run: 15–45 seconds.

---

## Command-Line Options

All options override the equivalent config file values.

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
└── Acme-Corp_healthcheck_20261113_013122/
    ├── rmq-host_rmq_health_report_20261113_013122.html   ← open in browser
    ├── execution.log                                      ← timestamped audit trail
    └── errors.log                                         ← failed API calls, curl errors
Acme-Corp_healthcheck_20261113_013122.zip                 ← share with Broadcom Support
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

**Exit codes:** `0` all clear · `1` warnings · `2` critical · `3` incomplete (NOT VERIFIED) · `4` argument or config error

---

## RabbitMQ User Permissions

The script uses HTTP GET only — no publish, no purge, no config changes.

| API Endpoints | Required Tag |
|---|---|
| `/api/overview`, `/api/queues`, `/api/connections`, `/api/channels` | `monitoring` |
| `/api/policies`, `/api/feature-flags`, `/api/health/checks/*` | `monitoring` |
| `/api/nodes`, `/api/shovels`, `/api/federation-links` | `monitoring` |
| `/api/consumers`, `/api/bindings`, `/api/exchanges` | `monitoring` |
| `/api/users` | `administrator` |

If an endpoint returns HTTP 401, the affected checks are marked `NOT VERIFIED` with a note in the evidence log explaining which tag to grant.

---

## Security and Privacy

- **No credentials are written to any report or log file.**
- Credentials are held in memory for the duration of the run only.
- Shovel source/destination URIs are not collected.
- Message bodies are not collected.
- Usernames are not collected — only counts are recorded.
- Queue names and vhost names appear in reports — review before sharing as they may reveal business domain.
- Nothing is installed on the customer cluster. No SSH. No config changes.

Always open the HTML report and verify its contents before sharing with Broadcom Support.

---

## Limitations

- Checks are point-in-time snapshots, not continuous monitoring.
- Historical throughput, DR readiness, and backup status require customer-provided evidence.
- Quorum queue replica majority (`HA-02`) requires per-queue API calls and may be incomplete on very large clusters.
- BOSH VM inventory requires an authenticated `bosh` CLI session on the jump host.
- TLS certificate check covers the presented leaf certificate only; full chain trust is validated by `curl`.
- Application health checks (APP-04, APP-05) reflect state at scan time — re-run during active workload for meaningful results.
