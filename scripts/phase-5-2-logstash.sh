#!/bin/bash
# Phase 5.2: Logstash Pipeline Configuration (Central Server)
set -euo pipefail

OPENSEARCH_HOST="${1:-10.0.0.10:9200}"

echo "[*] Phase 5.2: Logstash Pipeline Setup"
echo "  OpenSearch target: $OPENSEARCH_HOST"
echo "========================================"

dnf install -y logstash

mkdir -p /etc/logstash/conf.d

# Inputs
cat > /etc/logstash/conf.d/01-inputs.conf << 'INPUT'
input {
  beats {
    port => 5044
    client_inactivity_timeout => 300
  }
  redis {
    data_type => "list"
    key => "drakvuf-queue"
    host => "10.0.0.40"
    port => 6379
    batch_count => 500
    codec => json
    threads => 4
  }
}
INPUT

# Filters - ECS normalization
cat > /etc/logstash/conf.d/02-filters.conf << 'FILTER'
filter {
  # ---- DRAKVUF VMI events ----
  if [log_type] == "drakvuf" {
    mutate {
      rename => {
        "TimeStamp" => "@timestamp"
        "VMName" => "[host][name]"
        "ProcessId" => "[process][pid]"
        "ParentProcessId" => "[process][parent][pid]"
        "Image" => "[process][executable]"
        "CommandLine" => "[process][command_line]"
        "EventId" => "[event][code]"
      }
    }

    if [event][code] == 1 {
      mutate { add_field => { "[event][category]" => "process" "[event][type]" => "start" } }
    } else if [event][code] == 8 {
      mutate { add_field => { "[event][category]" => "process" "[event][type]" => "info" } }
    } else if [event][code] == 11 {
      mutate { add_field => { "[event][category]" => "file" "[event][type]" => "creation" } }
    }

    # Sanitize PII
    mutate {
      gsub => [
        "[process][command_line]", "(-p\\s+|password=)\\S+", "\\1[REDACTED]"
      ]
      remove_field => ["[process][environment]"]
    }

    date { match => ["@timestamp", "ISO8601"] }
  }

  # ---- Suricata NIDS events ----
  if [log_type] == "suricata" {
    mutate {
      rename => {
        "[src_ip]" => "[source][ip]"
        "[src_port]" => "[source][port]"
        "[dest_ip]" => "[destination][ip]"
        "[dest_port]" => "[destination][port]"
        "[proto]" => "[network][protocol]"
        "[alert][signature]" => "[event][reason]"
        "[alert][severity]" => "[event][severity]"
      }
      add_field => { "[event][category]" => "network" }
    }
  }

  # ---- Wazuh alerts ----
  if [log_type] == "wazuh" {
    mutate {
      rename => {
        "[agent][name]" => "[host][name]"
        "[rule][id]" => "[event][code]"
        "[rule][description]" => "[event][reason]"
        "[rule][level]" => "[event][severity]"
      }
    }
  }

  # ---- Common enrichment ----
  # Tier classification
  if [host][name] {
    if [host][name] =~ /^prd-/ {
      mutate { add_field => { "[labels][tier]" => "tier0" } }
    } else if [host][name] =~ /^srv-/ {
      mutate { add_field => { "[labels][tier]" => "tier1" } }
    } else if [host][name] =~ /^bm-/ {
      mutate { add_field => { "[labels][tier]" => "tier2" } }
    } else {
      mutate { add_field => { "[labels][tier]" => "tier3" } }
    }
  }

  # Correlation hash
  fingerprint {
    source => ["[host][name]", "[process][pid]", "@timestamp"]
    target => "[event][hash]"
    method => "SHA256"
  }
}
FILTER

# Outputs
cat > /etc/logstash/conf.d/03-outputs.conf << 'OUTPUT'
output {
  elasticsearch {
    hosts => ["OPENSEARCH_HOST_PLACEHOLDER"]
    index => "security-events-%{+YYYY.MM.dd}"
    document_id => "%{[event][hash]}"
    action => "index"
    manage_template => false
    template_overwrite => false
  }
}
OUTPUT
sed -i "s/OPENSEARCH_HOST_PLACEHOLDER/$OPENSEARCH_HOST/" /etc/logstash/conf.d/03-outputs.conf

systemctl enable logstash
systemctl restart logstash

echo "[+] Logstash pipeline deployed"
echo "    Verify: journalctl -u logstash -n 50 --no-pager"
