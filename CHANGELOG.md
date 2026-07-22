# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-07-03

### Added
- Per-client-IP connection collector (`collector/collect_client_connections.sh`)
  - Robust port-based peer parser (works with all `ss` output formats)
  - Atomic `.prom` file writes for safe node_exporter scraping
  - Configurable loopback/health-check IP exclusion
- AWS EC2 Node Attribution Resolver (`resolver/resolve_client_nodes.py`)
  - Optional — collector works standalone without it
  - IMDSv2 region auto-detection (works in any AWS region without config)
  - Atomic cache writes with stale-cache preservation on errors
  - 5 MB size guard with VPC-scoping recommendation
- PMM alert rule templates (`alerting/mongodb_connection_alerts.yml`)
  - Per-client IP guardrail (default threshold: 3000 connections)
  - Total connections per instance (default threshold: 12000 connections)
  - Clean annotations (no label-blob dump in PMM notifications)
- Grafana/PMM dashboard (`dashboards/mongodb_connections.json`)
  - Connection utilization overview (all instances)
  - Per-instance breakdown (repeating row)
  - Top Connection Sources table with EC2 Name tag enrichment
  - Deduplication via groupBy transformation
- Systemd units for production scheduling
  - Collector: 60s timer with randomized delay
  - Resolver: 5m timer with catch-up on missed runs
- SaltStack deployment states (`deploy/salt/`)
- Configuration templates with documented defaults

### Tested on
- PMM 3.x
- Amazon Linux 2
- Debian 12 (Bookworm)
- Ubuntu 22.04 LTS
