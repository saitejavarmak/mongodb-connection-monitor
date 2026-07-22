#!/usr/bin/env bash
#
# collect_client_connections.sh — Per-client MongoDB connection collector.
#
# Counts ESTABLISHED connections to MongoDB grouped by client source IP on this
# host and exposes them to PMM via the node_exporter textfile collector as:
#   mongodb_client_connections{client_ip, client_node, client_instance_id, server_name}
#
# How it works
# ------------
#   1. Lists established MongoDB sockets via:
#        ss -Htn state established '( sport = :27017 )'
#      and extracts the PEER (client) address from each socket line.
#
#   2. Normalises the peer address: strips the trailing :<port>, unwraps
#      bracketed IPv6 literals ([fe80::1] -> fe80::1), and drops any address on
#      the configurable EXCLUDE_IPS list. Surviving addresses are aggregated
#      into a per-client-IP count.
#
#   3. Stamps `server_name` from this host's primary private IP. Resolution
#      order: (1) the Node Attribution Resolver cache (same EC2 Name tag source
#      used for client_node), (2) the IP itself as a final fallback.
#
#   4. Stamps `client_node` / `client_instance_id` by READING the Node
#      Attribution Resolver cache (.client_node_cache.tsv). On a cache miss the
#      client_node falls back to the client IP so the label is ALWAYS populated.
#      The collector NEVER calls EC2 — it only reads the cache.
#
#   5. Atomically publishes the Prometheus textfile: writes a temp file then
#      mv's it into place so node_exporter never reads a half-written .prom.
#
# The collector works WITHOUT the resolver — you still get per-IP connection
# counts. The resolver is optional and only adds EC2 Name tag enrichment.
#
# Usage
# -----
#   collector/collect_client_connections.sh   # write the .prom once
#
# Intended to run on a <=60s schedule (systemd timer or cron).
#
# Environment variables (all optional, documented defaults below):
#   MONGO_PORT              MongoDB port to inspect (default: 27017)
#   TEXTFILE_COLLECTOR_DIR  node_exporter textfile-collector directory
#                           (default: /usr/local/percona/pmm/collectors/textfile-collector/low-resolution)
#   OUT_FILE                Full path of the published .prom file
#   CLIENT_NODE_CACHE       Node Attribution Resolver cache path
#   EXCLUDE_IPS             Space-separated IPs to exclude (default: "127.0.0.1 ::1")
#   SERVER_IP               Override for this host's IP (auto-detected if unset)
#   SS_CMD                  Override for the socket-listing command (testing)
#
set -euo pipefail

# --- Configurable values (env overrides with documented defaults) ---
MONGO_PORT="${MONGO_PORT:-27017}"
TEXTFILE_COLLECTOR_DIR="${TEXTFILE_COLLECTOR_DIR:-/usr/local/percona/pmm/collectors/textfile-collector/low-resolution}"
OUT_FILE="${OUT_FILE:-$TEXTFILE_COLLECTOR_DIR/mongodb_client_connections.prom}"
# The Node Attribution Resolver cache. Placed in the textfile-collector PARENT
# dir so it is never in a node_exporter *.prom scrape set.
CLIENT_NODE_CACHE="${CLIENT_NODE_CACHE:-$(dirname "$TEXTFILE_COLLECTOR_DIR")/.client_node_cache.tsv}"
# Loopback / health-check probe IPs to exclude.
EXCLUDE_IPS="${EXCLUDE_IPS:-127.0.0.1 ::1}"

log() { printf '%s collect_client_connections %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# host_primary_ip — best-effort detection of this host's primary IPv4 address.
# Overridable via $SERVER_IP.
# ---------------------------------------------------------------------------
host_primary_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  fi
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
  fi
  printf '%s' "$ip"
}

# ---------------------------------------------------------------------------
# prom_escape <value> — escape a Prometheus label value (backslash, double
# quote, newline).
# ---------------------------------------------------------------------------
prom_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# list_sockets — emit raw `ss -Htn` lines for established MongoDB sockets.
# Overridable via $SS_CMD for testing.
# ---------------------------------------------------------------------------
list_sockets() {
  if [[ -n "${SS_CMD:-}" ]]; then
    eval "$SS_CMD"
  else
    ss -Htn state established "( sport = :$MONGO_PORT )"
  fi
}

# ---------------------------------------------------------------------------
# parse_peers — stdin: `ss -Htn` output; stdout: one normalised Client_IP per
# line.
#
# Robust peer-parser: does NOT rely on a fixed column index. Scans every field
# for an <addr>:<port> token and treats the one whose port is NOT the MongoDB
# port as the peer (client) address. This handles `ss` output both with and
# without the State column.
# ---------------------------------------------------------------------------
parse_peers() {
  awk -v excl="$EXCLUDE_IPS" -v mongoport="$MONGO_PORT" '
    BEGIN { n = split(excl, a, /[ \t]+/); for (i = 1; i <= n; i++) if (a[i] != "") ex[a[i]] = 1 }
    {
      peer = ""
      for (i = 1; i <= NF; i++) {
        f = $i
        if (f ~ /:[0-9]+$/) {            # looks like <addr>:<port>
          port = f; sub(/.*:/, "", port) # text after the last colon = port
          if (port != mongoport) {       # the non-Mongo end is the client
            addr = f; sub(/:[0-9]+$/, "", addr)
            peer = addr
          }
        }
      }
      if (peer == "") next
      sub(/^\[/, "", peer)               # unwrap IPv6 [..]
      sub(/\]$/, "", peer)
      if (peer == "") next
      if (peer in ex) next               # configurable loopback/health-check exclusion
      print peer
    }
  '
}

# ---------------------------------------------------------------------------
# lookup_node <ip> — echo "<name_tag>\t<instance_id>" from the resolver cache.
# Both fields are empty when the IP is absent or the cache is missing.
# ---------------------------------------------------------------------------
lookup_node() {
  local ip="$1"
  [[ -f "$CLIENT_NODE_CACHE" ]] || { printf '\t'; return 0; }
  awk -F'\t' -v ip="$ip" '
    $1 == ip { printf "%s\t%s", $2, $3; found = 1; exit }
    END { if (!found) printf "\t" }
  ' "$CLIENT_NODE_CACHE"
}

# ---------------------------------------------------------------------------
# emit_samples — stdin: "<count> <client_ip>" lines (from `uniq -c`); stdout:
# one labeled mongodb_client_connections sample per line.
# ---------------------------------------------------------------------------
emit_samples() {
  local server_name_esc="$1"
  local count ip node_fields name_tag instance_id client_node
  while read -r count ip; do
    [[ -z "${ip:-}" ]] && continue
    node_fields="$(lookup_node "$ip")"
    name_tag="${node_fields%%$'\t'*}"
    instance_id="${node_fields#*$'\t'}"
    # client_node: cached Name tag on a hit, else the IP itself (always populated).
    if [[ -n "$name_tag" ]]; then
      client_node="$name_tag"
    else
      client_node="$ip"
    fi
    printf 'mongodb_client_connections{client_ip="%s",client_node="%s",client_instance_id="%s",server_name="%s"} %s\n' \
      "$(prom_escape "$ip")" \
      "$(prom_escape "$client_node")" \
      "$(prom_escape "$instance_id")" \
      "$server_name_esc" \
      "$count"
  done
}

main() {
  local server_ip server_name server_name_esc node_fields name_tag

  server_ip="${SERVER_IP:-$(host_primary_ip)}"

  # server_name resolution order:
  #   1. EC2 Name tag from the resolver cache (if available)
  #   2. The IP itself (fallback)
  node_fields="$(lookup_node "$server_ip")"
  name_tag="${node_fields%%$'\t'*}"
  if [[ -n "$name_tag" ]]; then
    server_name="$name_tag"
  else
    server_name="$server_ip"
  fi
  server_name_esc="$(prom_escape "$server_name")"

  # 1. Aggregate established MongoDB peers by Client_IP.
  local counts
  counts="$(list_sockets | parse_peers | sort | uniq -c)"

  # 2. Render the exposition into a temp file in the output directory.
  mkdir -p "$TEXTFILE_COLLECTOR_DIR"
  local tmp_file
  tmp_file="$(mktemp "$TEXTFILE_COLLECTOR_DIR/.mongodb_client_connections.XXXXXX")"
  trap '[[ -n "${tmp_file:-}" && -e "$tmp_file" ]] && rm -f "$tmp_file"' EXIT

  {
    printf '# HELP mongodb_client_connections Established connections to MongoDB :%s by client source IP.\n' "$MONGO_PORT"
    printf '# TYPE mongodb_client_connections gauge\n'
    if [[ -n "$counts" ]]; then
      printf '%s\n' "$counts" | emit_samples "$server_name_esc"
    fi
  } > "$tmp_file"

  # 3. Atomic publish: rename within the same directory so node_exporter never
  #    observes a half-written file.
  mv -f "$tmp_file" "$OUT_FILE"
  trap - EXIT

  log "wrote $OUT_FILE (server_name='${server_name}')"
}

main "$@"
