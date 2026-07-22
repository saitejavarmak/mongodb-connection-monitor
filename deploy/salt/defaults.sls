# =============================================================================
# mongodb_conn_monitor/defaults.sls
#
# All configurable values live here. Edit this single file to customize.
# No pillar needed — just change values and re-apply.
# =============================================================================

{% set mongodb_conn_monitor = {
  'base_dir': '/opt/mongodb-connection-monitor',
  'config_dir': '/opt/mongodb-connection-monitor/config',
  'user': 'root',
  'group': 'root',

  'collector': {
    'mongo_port': 27017,
    'textfile_collector_dir': '/usr/local/percona/pmm/collectors/textfile-collector/low-resolution',
    'client_node_cache': '/usr/local/percona/pmm/collectors/textfile-collector/.client_node_cache.tsv',
    'exclude_ips': '127.0.0.1 ::1',
    'server_ip': '',
  },

  'resolver': {
    'aws_region': '',
    'attribution_refresh_interval': '5m',
    'client_node_cache': '/usr/local/percona/pmm/collectors/textfile-collector/.client_node_cache.tsv',
    'vpc_id': '',
  },
} %}
