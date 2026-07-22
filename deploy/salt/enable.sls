# =============================================================================
# mongodb_conn_monitor.enable
#
# Enables and starts systemd timers. Idempotent — safe to re-apply.
# =============================================================================

# --- Collector timer (every 60s) ---

mongodb-client-connections-collector.timer:
  service.running:
    - enable: True
    - watch:
      - file: /etc/systemd/system/mongodb-client-connections-collector.service
      - file: /etc/systemd/system/mongodb-client-connections-collector.timer

# --- Resolver timer (every 5m, optional — only if you use AWS EC2 resolution) ---

node-attribution-resolver.timer:
  service.running:
    - enable: True
    - watch:
      - file: /etc/systemd/system/node-attribution-resolver.service
      - file: /etc/systemd/system/node-attribution-resolver.timer
