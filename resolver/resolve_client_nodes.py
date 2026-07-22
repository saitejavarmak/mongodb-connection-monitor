#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Node Attribution Resolver — AWS EC2 Client IP to Instance Name resolution.

This script is OPTIONAL. It is only needed if you want to resolve client IPs to
their owning EC2 instance Name tags. Without it, the collector still works and
reports per-IP connection counts — you just see raw IPs instead of instance names.

Non-AWS users can skip this entirely.

What it does
------------
Runs alongside the collector on each MongoDB EC2 host. On each invocation it
queries the EC2 describe APIs (using the host's IAM role) and builds a cache:

    Client_IP  ->  {name_tag (EC2 "Name" tag), instance_id}

covering BOTH the primary and secondary private IPs of every ENI in the
account/region. Because EKS assigns pod IPs as secondary private addresses on a
worker node's ENI, every such Client_IP resolves back to its owning EC2 instance.

The cache is then read (never written) by the collector, which stamps the
`client_node` / `client_instance_id` labels on each sample.

This script is intended to run on a 5-minute schedule (not every collection
cycle) to avoid EC2 API throttling.

Prerequisites
-------------
- Python 3.6+
- boto3 (pip install boto3)
- IAM role with ec2:DescribeInstances and ec2:DescribeNetworkInterfaces

Usage
-----
    resolve_client_nodes.py                 # refresh the cache file once
    resolve_client_nodes.py --stdout        # print the map, do not touch cache
    resolve_client_nodes.py --cache-file X  # override the cache path

Environment variables:
    AWS_REGION / AWS_DEFAULT_REGION   Region to target. Auto-detects from IMDS if unset.
    ATTRIBUTION_REFRESH_INTERVAL      Refresh cadence (default "5m", for documentation).
    CLIENT_NODE_CACHE                 Cache file path.
    NODE_ATTRIBUTION_VPC_ID           Optional VPC id to scope ENI lookup.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import tempfile
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# Configurable values (env vars with documented defaults).
# ---------------------------------------------------------------------------

# AWS Region. Resolution order at runtime:
#   1. AWS_REGION / AWS_DEFAULT_REGION env (or --region flag)
#   2. IMDS (this host's own region — works automatically in any region)
#   3. us-east-1 as a final fallback
AWS_REGION_DEFAULT = "us-east-1"
AWS_REGION_ENV = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")

# Attribution refresh interval (default 5m). This script runs once per
# invocation; the interval is enforced by the scheduler (systemd timer/cron).
ATTRIBUTION_REFRESH_INTERVAL_DEFAULT = "5m"
ATTRIBUTION_REFRESH_INTERVAL = os.environ.get(
    "ATTRIBUTION_REFRESH_INTERVAL", ATTRIBUTION_REFRESH_INTERVAL_DEFAULT
)

# On-disk cache the collector reads.
DEFAULT_CACHE_FILE = "/usr/local/percona/pmm/collectors/textfile-collector/.client_node_cache.tsv"
CACHE_FILE = os.environ.get("CLIENT_NODE_CACHE", DEFAULT_CACHE_FILE)

# Optional: restrict the ENI lookup to one VPC.
VPC_ID = os.environ.get("NODE_ATTRIBUTION_VPC_ID", "").strip()

LOG = logging.getLogger("resolve_client_nodes")


# ---------------------------------------------------------------------------
# IMDSv2 region auto-detection.
# ---------------------------------------------------------------------------
def detect_region_from_imds(timeout: float = 1.0) -> str | None:
    """Return this host's AWS region from IMDSv2, or None if unavailable.

    Uses the token-based IMDSv2 flow. A short timeout keeps non-EC2 hosts from
    blocking.
    """
    base = "http://169.254.169.254/latest"
    try:
        token_req = urllib.request.Request(
            f"{base}/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        )
        with urllib.request.urlopen(token_req, timeout=timeout) as resp:
            token = resp.read().decode("utf-8").strip()
        region_req = urllib.request.Request(
            f"{base}/meta-data/placement/region",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(region_req, timeout=timeout) as resp:
            region = resp.read().decode("utf-8").strip()
        return region or None
    except (urllib.error.URLError, OSError, ValueError) as exc:
        LOG.debug("IMDS region detection failed: %s", exc)
        return None


def resolve_region(cli_region: str | None) -> str:
    """Resolve the AWS region to target, in priority order."""
    if cli_region:
        return cli_region
    if AWS_REGION_ENV:
        return AWS_REGION_ENV
    imds_region = detect_region_from_imds()
    if imds_region:
        LOG.info("Region auto-detected from IMDS: %s", imds_region)
        return imds_region
    LOG.info("Falling back to default region: %s", AWS_REGION_DEFAULT)
    return AWS_REGION_DEFAULT


def _sanitize(value: str) -> str:
    """Strip TAB/newline so a value can never break the TSV row layout."""
    if not value:
        return ""
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def build_ip_to_node_map(ec2_client):
    """Build {client_ip: (name_tag, instance_id)} from EC2 describe APIs.

    Covers every ENI's primary AND secondary private IPv4 addresses (plus IPv6)
    so both pod secondary IPs and SNAT'd node primary IPs resolve to the owning
    instance. Credentials come from the instance IAM role via the boto3 default
    chain — no static keys.
    """
    # 1. instance_id -> Name tag
    name_by_instance: dict[str, str] = {}
    instance_paginator = ec2_client.get_paginator("describe_instances")
    for page in instance_paginator.paginate():
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                instance_id = instance.get("InstanceId")
                if not instance_id:
                    continue
                name_tag = ""
                for tag in instance.get("Tags", []) or []:
                    if tag.get("Key") == "Name":
                        name_tag = _sanitize(tag.get("Value", ""))
                        break
                name_by_instance[instance_id] = name_tag

    # 2. For every ENI, map each IP to the owning instance.
    eni_paginator = ec2_client.get_paginator("describe_network_interfaces")
    paginate_kwargs = {}
    if VPC_ID:
        paginate_kwargs["Filters"] = [{"Name": "vpc-id", "Values": [VPC_ID]}]

    ip_to_node: dict[str, tuple[str, str]] = {}
    for page in eni_paginator.paginate(**paginate_kwargs):
        for eni in page.get("NetworkInterfaces", []):
            attachment = eni.get("Attachment") or {}
            instance_id = attachment.get("InstanceId", "") or ""
            if not instance_id:
                continue
            name_tag = name_by_instance.get(instance_id, "")

            # Primary + secondary private IPv4 addresses
            for addr in eni.get("PrivateIpAddresses", []) or []:
                ip = addr.get("PrivateIpAddress")
                if ip:
                    ip_to_node[ip] = (name_tag, instance_id)

            # IPv6 addresses
            for addr in eni.get("Ipv6Addresses", []) or []:
                ip = addr.get("Ipv6Address")
                if ip:
                    ip_to_node[ip] = (name_tag, instance_id)

    return ip_to_node


def render_cache(ip_to_node: dict[str, tuple[str, str]]) -> str:
    """Render the map as `client_ip<TAB>name_tag<TAB>instance_id` per line."""
    lines = []
    for ip in sorted(ip_to_node):
        name_tag, instance_id = ip_to_node[ip]
        lines.append(f"{ip}\t{_sanitize(name_tag)}\t{_sanitize(instance_id)}")
    return ("\n".join(lines) + "\n") if lines else ""


def atomic_write_cache(path: str, content: str) -> None:
    """Publish the cache atomically: temp file then os.replace.

    Writing into the same directory guarantees the rename is atomic (same
    filesystem), so the collector never observes a half-written cache.
    """
    out_dir = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(out_dir, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(
        prefix=".client_node_cache.", suffix=".tmp", dir=out_dir
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp:
            tmp.write(content)
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Refresh the Client_IP -> {name_tag, instance_id} attribution cache."
    )
    parser.add_argument(
        "--cache-file",
        default=CACHE_FILE,
        help=f"Path to the cache file (default: {CACHE_FILE}).",
    )
    parser.add_argument(
        "--region",
        default=None,
        help="AWS region to target. Default: auto-detect from IMDS.",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print the rendered cache to stdout; do NOT touch the cache file.",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Enable debug logging."
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s resolve_client_nodes %(levelname)s %(message)s",
    )

    LOG.info(
        "Node Attribution Resolver: single refresh "
        "(scheduled cadence=%s, default=%s)",
        ATTRIBUTION_REFRESH_INTERVAL,
        ATTRIBUTION_REFRESH_INTERVAL_DEFAULT,
    )

    # boto3 is a runtime dependency. Import lazily so the failure message is
    # clear when the SDK is absent.
    try:
        import boto3
        from botocore.exceptions import BotoCoreError, ClientError, NoRegionError
    except ImportError as exc:
        LOG.warning(
            "boto3 is not installed (%s); leaving the existing cache in place. "
            "Install boto3 to enable EC2 name resolution. The collector will "
            "fall back to showing raw IPs.",
            exc,
        )
        return 0

    region = resolve_region(args.region)
    try:
        session = boto3.session.Session(region_name=region)
        ec2_client = session.client("ec2")
    except (BotoCoreError, NoRegionError) as exc:
        LOG.warning(
            "Could not initialise EC2 client for region '%s' (%s); leaving "
            "existing cache in place.",
            region,
            exc,
        )
        return 0

    try:
        ip_to_node = build_ip_to_node_map(ec2_client)
    except (ClientError, BotoCoreError) as exc:
        LOG.warning(
            "EC2 API error (%s); leaving existing cache in place. "
            "Collector will use the previous cache or fall back to IPs.",
            exc,
        )
        return 0

    content = render_cache(ip_to_node)
    LOG.info("Resolved %d Client_IP -> node entries.", len(ip_to_node))

    if args.stdout:
        sys.stdout.write(content)
        return 0

    # Don't overwrite a good cache with an empty result (likely transient error).
    if not ip_to_node and os.path.exists(args.cache_file):
        LOG.warning(
            "EC2 returned zero IPs; keeping existing cache at %s.",
            args.cache_file,
        )
        return 0

    atomic_write_cache(args.cache_file, content)
    LOG.info("Wrote attribution cache to %s.", args.cache_file)

    # Size guard: warn if cache exceeds 5 MB.
    try:
        cache_size = os.path.getsize(args.cache_file)
        if cache_size > 5 * 1024 * 1024:
            LOG.warning(
                "Cache is %.1f MB (> 5 MB). Consider setting "
                "NODE_ATTRIBUTION_VPC_ID to scope the ENI lookup.",
                cache_size / (1024 * 1024),
            )
        else:
            LOG.info("Cache size: %.1f KB.", cache_size / 1024)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
