# =============================================================================
# Salt state: mongodb_conn_monitor
#
# Full deploy: install → config → enable.
#   salt 'mongo*' state.apply mongodb_conn_monitor
#
# Individual stages:
#   salt 'mongo*' state.apply mongodb_conn_monitor.install
#   salt 'mongo*' state.apply mongodb_conn_monitor.config
#   salt 'mongo*' state.apply mongodb_conn_monitor.enable
# =============================================================================

include:
  - mongodb_conn_monitor.install
  - mongodb_conn_monitor.config
  - mongodb_conn_monitor.enable
