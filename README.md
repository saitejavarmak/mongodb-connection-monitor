# MongoDB Connection Monitor

<!-- Badges placeholder -->
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)
![Python](https://img.shields.io/badge/Python-3.6%2B-blue.svg)

Per-client-IP connection monitoring for MongoDB with PMM (Percona Monitoring and Management). This tool fills a gap in PMM's built-in mongodb_exporter, which reports **total** connection counts per instance but does **not** break them down by client source IP. With this collector, you can identify which application nodes are consuming connection pool headroom, set per-client guardrails, and catch runaway clients before they exhaust the server's connection limit.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  MongoDB Host                                                           │
│                                                                         │
│  ┌──────────────────────┐        ┌───────────────────────────────────┐  │
│  │  ss (socket stats)   │───────▶│  collect_client_connections.sh    │  │
│  └──────────────────────┘        │  (runs every 60s via systemd)     │  │
│                                  │                                   │  │
│  ┌──────────────────────┐        │  Reads cache (optional):         │  │
│  │  .client_node_cache  │◀───────│  stamps client_node labels       │  │
│  │  .tsv                │        └───────────────┬───────────────────┘  │
│  └──────────┬───────────┘                        │                      │
│             │                                    ▼                      │
│  ┌──────────┴───────────┐        ┌───────────────────────────────────┐  │
│  │  resolve_client_     │        │  mongodb_client_connections.prom  │  │
│  │  nodes.py (optional) │        │  (textfile-collector dir)         │  │
│  │  (runs every 5m)     │        └───────────────┬───────────────────┘  │
│  │                      │                        │                      │
│  │  EC2 DescribeAPIs    │                        ▼                      │
│  └──────────────────────┘        ┌───────────────────────────────────┐  │
│                                  │  PMM node_exporter                │  │
│                                  │  (textfile collector scrapes .prom)│  │
│                                  └───────────────┬───────────────────┘  │
└──────────────────────────────────────────────────┼──────────────────────┘
                                                   │
                                                   ▼
                                  ┌───────────────────────────────────┐
                                  │  PMM Server (VictoriaMetrics)     │
                                  │  ┌─────────────────────────────┐  │
                                  │  │  Grafana Dashboard           │  │
                                  │  │  + Alert Rules               │  │
                                  │  └─────────────────────────────┘  │
                                  └───────────────────────────────────┘
```

---

## Features

- **Per-client-IP connection counts** — see exactly which IPs are consuming connections on each MongoDB instance
- **EC2 Name tag enrichment** (optional) — resolve IPs to human-readable instance names (EKS worker nodes, app servers, etc.)
- **Atomic file writes** — node_exporter never reads a half-written `.prom` file
- **Robust peer parser** — port-based extraction (not column-position-based), works with all `ss` output formats
- **Pluggable architecture** — collector works standalone; resolver is opt-in for AWS environments
- **PMM-native** — uses the textfile collector already bundled with PMM's node_exporter
- **Alert templates** — per-client guardrail and total-connections-per-instance alerts ready to import into PMM
- **Grafana dashboard** — connection utilization, per-instance breakdown, and top-sources table
- **Systemd timers** — production-ready scheduling with light security hardening
- **Salt states** (optional) — fleet-wide deployment via SaltStack

---

## Prerequisites

| Component | Requires | Notes |
|-----------|----------|-------|
| Collector | Bash, `ss` command (iproute2) | No extra packages — `ss` is pre-installed on all modern Linux |
| Resolver (optional) | Python 3.6+, `boto3` | Only needed for AWS EC2 name resolution |
| Dashboard | PMM 3.x / Grafana 10+ | Import the JSON into PMM's Grafana |
| Alerts | PMM 3.x alerting | Import the YAML template via PMM UI |

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/your-username/mongodb-connection-monitor.git
cd mongodb-connection-monitor
```

### 2. Deploy the collector

```bash
# Copy to target host
sudo mkdir -p /opt/mongodb-connection-monitor
sudo cp -r collector/ config/ /opt/mongodb-connection-monitor/

# Make the script executable
sudo chmod +x /opt/mongodb-connection-monitor/collector/collect_client_connections.sh

# Test it manually
sudo /opt/mongodb-connection-monitor/collector/collect_client_connections.sh
cat /usr/local/percona/pmm/collectors/textfile-collector/low-resolution/mongodb_client_connections.prom
```

### 3. Install systemd timers

```bash
sudo cp systemd/mongodb-client-connections-collector.service /etc/systemd/system/
sudo cp systemd/mongodb-client-connections-collector.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now mongodb-client-connections-collector.timer
```

### 4. (Optional) Deploy the resolver for AWS EC2 name resolution

```bash
sudo cp -r resolver/ /opt/mongodb-connection-monitor/
sudo pip3 install boto3

sudo cp systemd/node-attribution-resolver.service /etc/systemd/system/
sudo cp systemd/node-attribution-resolver.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now node-attribution-resolver.timer
```

### 5. Import the dashboard

In PMM → Grafana → Dashboards → Import → upload `dashboards/mongodb_connections.json`.

### 6. Import alert templates

In PMM → Alerting → Alert Rule Templates → upload `alerting/mongodb_connection_alerts.yml`.

---

## Configuration Reference

### Collector (`config/collector.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGO_PORT` | `27017` | MongoDB port to monitor |
| `TEXTFILE_COLLECTOR_DIR` | `/usr/local/percona/pmm/collectors/textfile-collector/low-resolution` | Directory where the `.prom` file is written |
| `OUT_FILE` | `$TEXTFILE_COLLECTOR_DIR/mongodb_client_connections.prom` | Full path of the published metrics file |
| `CLIENT_NODE_CACHE` | `$TEXTFILE_COLLECTOR_DIR/../.client_node_cache.tsv` | Path to the resolver's cache (read-only) |
| `EXCLUDE_IPS` | `127.0.0.1 ::1` | Space-separated IPs to exclude (loopback, health checks) |
| `SERVER_IP` | *(auto-detected)* | Override for this host's IP used in `server_name` label |

### Resolver (`config/node_attribution.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | *(auto-detect from IMDS)* | AWS region for EC2 API calls |
| `ATTRIBUTION_REFRESH_INTERVAL` | `5m` | How often the cache is refreshed |
| `CLIENT_NODE_CACHE` | `/usr/local/percona/pmm/collectors/textfile-collector/.client_node_cache.tsv` | Where the cache is written |
| `NODE_ATTRIBUTION_VPC_ID` | *(empty = all ENIs)* | Optional VPC ID to scope the ENI lookup |

---

## How It Works

### Collector Flow

1. **Socket enumeration** — `ss -Htn state established '( sport = :27017 )'` lists all established connections to MongoDB, kernel-filtered for efficiency.
2. **Peer extraction** — A robust AWK parser scans each field for `<addr>:<port>` tokens and identifies the client (peer) by finding the address whose port is NOT the MongoDB port. This works regardless of whether `ss` includes the State column.
3. **Aggregation** — Client IPs are sorted and counted with `uniq -c`.
4. **Label enrichment** — For each client IP, the collector reads the resolver's cache file. On a hit, it stamps the EC2 Name tag as `client_node`; on a miss, the IP itself is used (so `client_node` is always populated).
5. **Atomic publish** — The `.prom` file is written to a temp file and `mv`'d into place so node_exporter never reads a partial file.

### Why `ss` instead of `netstat`?

- `ss` is the modern replacement for `netstat` (part of iproute2)
- Kernel-space filtering (`state established`, sport filter) means only matching sockets are returned — much faster on hosts with thousands of connections
- Available on all modern Linux distributions by default

### Resolver Flow (optional)

1. **Region detection** — checks `AWS_REGION` env → IMDS (this host's region) → `us-east-1` fallback
2. **EC2 DescribeInstances** — builds `instance_id → Name tag` map
3. **EC2 DescribeNetworkInterfaces** — maps every private IP (primary + secondary) and IPv6 address to its owning instance
4. **Atomic cache write** — writes to a temp file then `os.replace()`s it into place
5. **Safety guards** — never clobbers an existing cache with empty results; logs warnings and exits cleanly on any API error

### Dashboard

The Grafana dashboard provides:
- **Overview row** — current connections, connection limit, and utilization % across all instances
- **Top Sources table** — top 20 client IPs with their connection counts, EC2 Name tags, and instance IDs
- **Per-instance panels** — current vs limit, utilization gauge, and stat panel (repeating row per service_name)

### Alerts

Two PMM alert rule templates:
1. **Per-client guardrail** — fires when any single client IP exceeds the threshold (default: 3000 connections)
2. **Total connections** — fires when an instance's total connections exceed the threshold (default: 12000)

---

## Deployment Options

### Manual

Follow the [Quick Start](#quick-start) section above.

### Systemd (recommended for production)

The `systemd/` directory contains production-ready unit files:
- `mongodb-client-connections-collector.timer` — fires every 60s
- `mongodb-client-connections-collector.service` — oneshot that runs the collector
- `node-attribution-resolver.timer` — fires every 5m
- `node-attribution-resolver.service` — oneshot that runs the resolver

All services include light hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true`).

### Salt (fleet deployment)

The `deploy/salt/` directory provides SaltStack states for fleet-wide deployment:

```bash
# Full deploy
salt 'mongo*' state.apply mongodb_conn_monitor

# Individual stages
salt 'mongo*' state.apply mongodb_conn_monitor.install
salt 'mongo*' state.apply mongodb_conn_monitor.config
salt 'mongo*' state.apply mongodb_conn_monitor.enable
```

Edit `deploy/salt/defaults.sls` to customize paths and settings for your environment.

---

## Alert Setup in PMM

PMM uses a template-based alerting system. The templates in `alerting/mongodb_connection_alerts.yml` use PMM's template format:

```yaml
templates:
  - name: mongodb_per_client_connection_guardrail
    expr: |
      mongodb_client_connections > [[ .threshold ]]
    params:
      - name: threshold
        value: 3000    # default, adjustable per rule
    for: 1m
    severity: critical
```

**To import:**

1. Navigate to PMM → Alerting → Alert Rule Templates
2. Click "Upload" and select `alerting/mongodb_connection_alerts.yml`
3. Create alert rules from the imported templates
4. Adjust the `threshold` parameter per rule to match your environment

**Important:** The annotations use `{{ $labels.client_node }}` and `{{ $labels.node_name }}` — NOT `$value`, which would dump the entire label blob in PMM notifications.

---

## Dashboard Import

1. In PMM, navigate to Grafana → Dashboards → Import
2. Upload `dashboards/mongodb_connections.json`
3. Select your Prometheus data source
4. The dashboard auto-discovers MongoDB instances via the `service_name` label

The dashboard requires:
- `mongodb_ss_connections` metric (provided by PMM's mongodb_exporter)
- `mongodb_client_connections` metric (provided by this collector)

---

## AWS Node Attribution (Optional)

The resolver (`resolver/resolve_client_nodes.py`) is **completely optional**. It enriches the per-IP connection data with human-readable EC2 instance names.

**Without the resolver:** You still get per-IP connection counts and alerts. The `client_node` label simply shows the IP address.

**With the resolver:** The `client_node` label shows the EC2 Name tag (e.g., `eks-worker-prod-1a-abc123`), making it easy to identify which application nodes are consuming connections.

### How it works

The resolver queries `ec2:DescribeInstances` and `ec2:DescribeNetworkInterfaces` to build a mapping of every private IP (primary + secondary on every ENI) to its owning EC2 instance's Name tag. This covers:
- EC2 instance primary IPs
- EKS pod IPs (assigned as secondary IPs on worker node ENIs)
- SNAT'd traffic (resolves back to the NAT source node)

### IAM Requirements

The host's IAM role needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces"
      ],
      "Resource": "*"
    }
  ]
}
```

### Non-AWS environments

If you're not on AWS, simply don't deploy the resolver. The collector works standalone with no changes needed. For other cloud providers, you could write your own resolver that produces the same TSV cache format:

```
<client_ip>\t<name>\t<instance_id>
```

---

## Troubleshooting

### Collector produces an empty .prom file

- Verify MongoDB is running: `ss -tln | grep :27017`
- Check that the collector can see connections: `ss -Htn state established '( sport = :27017 )'`
- Ensure the user running the collector can read `/proc/net/tcp` (it's world-readable by default)

### client_node shows IPs instead of names

- The resolver is optional. If not deployed, this is expected behavior.
- If the resolver is deployed, check its logs: `journalctl -u node-attribution-resolver.service`
- Verify boto3 is installed: `python3 -c "import boto3"`
- Check IAM permissions: the host role needs `ec2:DescribeInstances` and `ec2:DescribeNetworkInterfaces`

### Metrics don't appear in PMM

- Verify the `.prom` file is in the correct textfile-collector directory: `ls /usr/local/percona/pmm/collectors/textfile-collector/low-resolution/*.prom`
- Check that the file is valid Prometheus exposition format: `promtool check metrics < mongodb_client_connections.prom`
- Ensure the timer is running: `systemctl status mongodb-client-connections-collector.timer`

### Resolver fails with region errors

- On EC2: region is auto-detected from IMDS. Ensure the instance has IMDS access (IMDSv2 is used).
- Set `AWS_REGION` explicitly in `config/node_attribution.env` if auto-detection doesn't work.

### High cache file size warning

- The resolver maps ALL ENIs in the region. If your account has many ENIs, set `NODE_ATTRIBUTION_VPC_ID` in `config/node_attribution.env` to scope to a single VPC.

---

## Tested On

| Platform | Version |
|----------|---------|
| PMM | 3.x |
| Amazon Linux | 2 |
| Debian | 12 (Bookworm) |
| Ubuntu | 22.04 LTS |
| Grafana | 10.x (bundled with PMM) |

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test on a real PMM + MongoDB setup if possible
5. Submit a pull request

### Development notes

- The collector is intentionally pure Bash with no external dependencies beyond `ss`
- The resolver uses only the Python standard library + `boto3`
- Keep the atomic-write contract: never leave a half-written file where node_exporter can read it
- The `client_node` label must ALWAYS be populated (IP fallback on cache miss)

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Copyright (c) 2024-2026 Sai Teja Varma Kantam

---

## Screenshots

> Add screenshots after deploying to your environment. Place them in the `screenshots/` directory.

<!-- Uncomment and update paths after adding screenshots:
### Dashboard Overview
![Dashboard Overview](screenshots/dashboard-overview.png)

### Top Connection Sources
![Top Sources](screenshots/dashboard-top-sources.png)

### Per-Instance Detail
![Per Instance](screenshots/dashboard-per-instance.png)
-->
