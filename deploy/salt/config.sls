# =============================================================================
# mongodb_conn_monitor.config
#
# Renders env files, systemd units, daemon-reload.
# =============================================================================

{% from "mongodb_conn_monitor/defaults.sls" import mongodb_conn_monitor with context %}
{% set base_dir = mongodb_conn_monitor.base_dir %}
{% set config_dir = mongodb_conn_monitor.config_dir %}
{% set user = mongodb_conn_monitor.user %}
{% set group = mongodb_conn_monitor.group %}
{% set collector = mongodb_conn_monitor.collector %}
{% set resolver = mongodb_conn_monitor.resolver %}

# --- Config directory ---

{{ config_dir }}:
  file.directory:
    - makedirs: True
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755

# --- Systemd units: collector ---

/etc/systemd/system/mongodb-client-connections-collector.service:
  file.managed:
    - source: salt://mongodb_conn_monitor/files/mongodb-client-connections-collector.service
    - mode: 644

/etc/systemd/system/mongodb-client-connections-collector.timer:
  file.managed:
    - source: salt://mongodb_conn_monitor/files/mongodb-client-connections-collector.timer
    - mode: 644

# --- Systemd units: resolver ---

/etc/systemd/system/node-attribution-resolver.service:
  file.managed:
    - source: salt://mongodb_conn_monitor/files/node-attribution-resolver.service
    - mode: 644

/etc/systemd/system/node-attribution-resolver.timer:
  file.managed:
    - source: salt://mongodb_conn_monitor/files/node-attribution-resolver.timer
    - mode: 644

# --- Daemon reload (only when unit files change) ---

systemd-reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: /etc/systemd/system/mongodb-client-connections-collector.service
      - file: /etc/systemd/system/mongodb-client-connections-collector.timer
      - file: /etc/systemd/system/node-attribution-resolver.service
      - file: /etc/systemd/system/node-attribution-resolver.timer
