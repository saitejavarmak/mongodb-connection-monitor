# =============================================================================
# mongodb_conn_monitor.install
#
# Creates directories, deploys scripts, installs packages.
# =============================================================================

{% from "mongodb_conn_monitor/defaults.sls" import mongodb_conn_monitor with context %}
{% set base_dir = mongodb_conn_monitor.base_dir %}
{% set user = mongodb_conn_monitor.user %}
{% set group = mongodb_conn_monitor.group %}

# --- Directories ---

{{ base_dir }}:
  file.directory:
    - makedirs: True
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755

{{ base_dir }}/collector:
  file.directory:
    - makedirs: True
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755
    - require:
      - file: {{ base_dir }}

{{ base_dir }}/resolver:
  file.directory:
    - makedirs: True
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755
    - require:
      - file: {{ base_dir }}

{{ base_dir }}/config:
  file.directory:
    - makedirs: True
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755
    - require:
      - file: {{ base_dir }}

# --- Scripts ---

{{ base_dir }}/collector/collect_client_connections.sh:
  file.managed:
    - source: salt://mongodb_conn_monitor/files/collect_client_connections.sh
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755
    - require:
      - file: {{ base_dir }}/collector

{{ base_dir }}/resolver/resolve_client_nodes.py:
  file.managed:
    - source: salt://mongodb_conn_monitor/files/resolve_client_nodes.py
    - user: {{ user }}
    - group: {{ group }}
    - mode: 755
    - require:
      - file: {{ base_dir }}/resolver

# --- Packages (only needed for the optional resolver) ---

python3-pip:
  pkg.installed

python3-boto3:
  pkg.installed

install-pip-boto3:
  cmd.run:
    - name: python3 -m pip install boto3
    - unless: python3 -c "import boto3"
    - require:
      - pkg: python3-pip
      - pkg: python3-boto3
