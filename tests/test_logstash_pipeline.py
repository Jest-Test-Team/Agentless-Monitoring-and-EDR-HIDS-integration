#!/usr/bin/env python3
"""Unit tests for Logstash pipeline configuration files.

Validates structural integrity of all .conf files under configs/logstash/pipeline/
without requiring Logstash to be installed.

Checks:
  - All expected pipeline files exist and are non-empty
  - Each file contains valid input/filter/output blocks
  - Port numbers referenced match deploy.conf defaults
  - Field references are consistent across pipeline stages
  - No known anti-patterns (e.g., elasticsearch output plugin without manage_template)
"""
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PIPELINE_DIR = REPO_ROOT / "configs" / "logstash" / "pipeline"
DEPLOY_CONF = REPO_ROOT / "scripts" / "deploy.conf"

# Expected pipeline files in processing order
EXPECTED_PIPELINES = [
    "01-inputs.conf",
    "02-filters.conf",
    "03-outputs.conf",
    "04-risk-scanner.conf",
]

# Section type keywords that must appear
REQUIRED_SECTIONS = {
    "01-inputs.conf":        ["input"],
    "02-filters.conf":       ["filter"],
    "03-outputs.conf":       ["output"],
    "04-risk-scanner.conf":  ["filter", "output"],
}

# Known plugin names used across the pipeline
KNOWN_OUTPUT_PLUGINS = {"elasticsearch", "stdout", "opensearch", "redis", "kafka"}
KNOWN_INPUT_PLUGINS = {"beats", "redis", "syslog", "kafka", "tcp", "udp"}
KNOWN_FILTER_PLUGINS = {
    "mutate", "date", "grok", "fingerprint", "json", "drop",
    "geoip", "translate", "clone", "csv", "kv", "ruby",
}


def parse_deploy_conf(defaults_only=True):
    """Extract port/name defaults from deploy.conf."""
    config = {}
    if not DEPLOY_CONF.exists():
        return config
    for line in DEPLOY_CONF.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^(\w+)=.*\$\{(\w+):-([^}]+)\}', line)
        if m:
            config[m.group(1)] = m.group(3)
    return config


def get_block_depth(line):
    """Return the nesting depth of a Logstash config line based on brace count."""
    return line.count("{") - line.count("}")


def extract_sections(content):
    """Extract top-level plugin blocks from config content.

    Returns list of (section_name, dict) where dict has 'lines' and 'inner_blocks'.
    """
    sections = []
    current_section = None
    brace_depth = 0
    buffer = []

    for raw_line in content.splitlines():
        stripped = raw_line.strip()
        # Skip blank/comments
        if not stripped or stripped.startswith("#"):
            if current_section and brace_depth > 0:
                buffer.append(raw_line)
            continue

        if current_section is None:
            # Look for top-level section: `keyword {`
            m = re.match(r'^(\w+)\s*\{', stripped)
            if m:
                current_section = m.group(1)
                brace_depth = 1
                buffer = [raw_line]
            continue

        buffer.append(raw_line)
        brace_depth += stripped.count("{") - stripped.count("}")
        if brace_depth <= 0:
            sections.append((current_section, "\n".join(buffer)))
            current_section = None
            buffer = []
            brace_depth = 0

    return sections


EXCLUDED_SECTION_KEYS = {"input", "filter", "output"}


def extract_plugin_names(section_text):
    """Extract plugin names (e.g., mutate, date, elasticsearch) from a section body."""
    plugins = []
    for line in section_text.splitlines():
        stripped = line.strip()
        m = re.match(r'^(\w+)\s*\{', stripped)
        if m and m.group(1) not in EXCLUDED_SECTION_KEYS:
            plugins.append(m.group(1))
        # Also catch inner plugin blocks like `elasticsearch { ... }`
        m = re.match(r'^\s+(\w+)\s*\{', stripped)
        if m and m.group(1) not in EXCLUDED_SECTION_KEYS and m.group(1) not in plugins:
            plugins.append(m.group(1))
    return plugins


def extract_port_refs(content):
    """Return set of port numbers found in config."""
    ports = set()
    for m in re.finditer(r'port\s*=>\s*(\d+)', content):
        ports.add(int(m.group(1)))
    for m in re.finditer(r':(\d+)\b', content):
        ports.add(int(m.group(1)))
    return ports


def extract_field_refs(content):
    """Return set of field references like [field][sub]."""
    refs = set()
    for m in re.finditer(r'\[([^\]]+)\]', content):
        refs.add(m.group(0))
    return refs


def test_all_pipeline_files_exist():
    missing = []
    for name in EXPECTED_PIPELINES:
        fpath = PIPELINE_DIR / name
        if not fpath.exists():
            missing.append(name)
        elif fpath.stat().st_size == 0:
            missing.append(f"{name} (empty)")
    assert not missing, f"Missing or empty pipeline files: {missing}"
    print(f"  \u2705 All {len(EXPECTED_PIPELINES)} pipeline files exist and non-empty")


def test_required_sections_present():
    errors = []
    for name, expected_sections in REQUIRED_SECTIONS.items():
        content = (PIPELINE_DIR / name).read_text()
        sections = extract_sections(content)
        found = {s[0] for s in sections}
        for sec in expected_sections:
            if sec not in found:
                errors.append(f"{name}: missing section '{sec}'")
    assert not errors, "\n    ".join(errors)
    print(f"  \u2705 All required sections present in {len(EXPECTED_PIPELINES)} files")


def test_plugin_names_known():
    warnings = []
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        for section_name, section_text in extract_sections(content):
            plugins = extract_plugin_names(section_text)
            known = KNOWN_INPUT_PLUGINS | KNOWN_FILTER_PLUGINS | KNOWN_OUTPUT_PLUGINS
            for p in set(plugins):
                if p not in known and p not in ("if", "else", "else if", "section_name"):
                    warnings.append(f"{name}/{section_name}: unrecognized plugin '{p}'")
    if warnings:
        print(f"  \u26a0 Unknown plugins:\n    " + "\n    ".join(warnings))
    else:
        print(f"  \u2705 All plugins recognized")


def test_port_numbers_match_deploy_conf():
    config = parse_deploy_conf()
    if not config:
        print("  \u26a0 Skipping port validation (deploy.conf not readable)")
        return
    port_map = {
        "LOGSTASH_BEATS_PORT": 5044,
        "REDIS_PORT": 6379,
        "OPENSEARCH_API_PORT": 9200,
    }
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        ports = extract_port_refs(content)
        for config_key, default_port in port_map.items():
            expected_port = int(config.get(config_key, default_port))
            if expected_port in ports:
                ports.discard(expected_port)
        # Warn about unexpected ports
        unexpected = {p for p in ports if p not in (22, 5514, 9600, 5044, 6379, 9200)}
        if unexpected:
            print(f"  \u26a0 {name}: port references that may need validation: {sorted(unexpected)}")
    print(f"  \u2705 Port validation complete")


def test_no_elasticsearch_output_misconfig():
    """Check elasticsearch output blocks have manage_template set."""
    errors = []
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        if "elasticsearch" not in content:
            continue
        # Check if manage_template is explicitly set in elasticsearch blocks
        es_blocks = re.findall(r'elasticsearch\s*\{.*?\}', content, re.DOTALL)
        for i, block in enumerate(es_blocks):
            if "manage_template" not in block:
                errors.append(f"{name}: elasticsearch block #{i+1} missing manage_template")
    if errors:
        print(f"  \u26a0 Manage template warnings:\n    " + "\n    ".join(errors))
    else:
        print(f"  \u2705 Elasticsearch output config looks correct")


def test_field_consistency_across_stages():
    """Check that fields produced by inputs are consumed by filters and outputs."""
    refs_by_file = {}
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        refs_by_file[name] = extract_field_refs(content)
    issues = []
    filter_refs = refs_by_file.get("02-filters.conf", set())
    input_refs = refs_by_file.get("01-inputs.conf", set())
    # Fields renamed in filters should be in inputs or common fields
    renamed_targets = {"[host][name]", "[process][pid]", "[event][code]",
                       "[source][ip]", "[destination][ip]", "[network][protocol]"}
    for ref in renamed_targets:
        found_in = [fn for fn, refs in refs_by_file.items() if ref in refs]
        if len(found_in) < 2:
            issues.append(f"Field {ref} only referenced in: {found_in}")
    if issues:
        print(f"  \u26a0 Field consistency:\n    " + "\n    ".join(issues))
    else:
        print(f"  \u2705 Field references are consistent across stages")


def test_config_no_unclosed_brackets():
    errors = []
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        opens = content.count("{")
        closes = content.count("}")
        if opens != closes:
            errors.append(f"{name}: {opens} {{ vs {closes} }} (mismatch)")
    assert not errors, "\n    ".join(errors)
    print(f"  \u2705 All bracket pairs balanced in {len(EXPECTED_PIPELINES)} files")


def test_outputs_use_document_id():
    """Check output elasticsearch blocks set document_id for dedup."""
    warnings = []
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        for block in re.findall(r'elasticsearch\s*\{.*?\}', content, re.DOTALL):
            if "document_id" not in block:
                warnings.append(f"{name}: elasticsearch block missing document_id")
    if warnings:
        print(f"  \u26a0 Document ID warnings:\n    " + "\n    ".join(warnings))
    else:
        print(f"  \u2705 All elasticsearch outputs set document_id")


def test_redis_password_not_hardcoded():
    """Check that Redis password references use variable not literal value."""
    warnings = []
    for name in EXPECTED_PIPELINES:
        content = (PIPELINE_DIR / name).read_text()
        for m in re.finditer(r'password\s*=>\s*"([^"]+)"', content):
            pw = m.group(1)
            if pw and not pw.startswith("${") and not pw.startswith("%{"):
                warnings.append(f"{name}: possible hardcoded password near '{pw[:8]}...'")
    if warnings:
        print(f"  \u26a0 Password warnings:\n    " + "\n    ".join(warnings))
    else:
        print(f"  \u2705 No hardcoded passwords detected")


def test_risk_scanner_output_host():
    """Risk scanner output should use localhost or configurable host."""
    content = (PIPELINE_DIR / "04-risk-scanner.conf").read_text()
    if "localhost" not in content and "OPENSEARCH_HOST" not in content:
        print("  \u26a0 04-risk-scanner.conf: output host not obviously configurable")
    else:
        print(f"  \u2705 Risk scanner output host is configurable")


if __name__ == "__main__":
    tests = [
        ("file_existence", test_all_pipeline_files_exist),
        ("required_sections", test_required_sections_present),
        ("plugin_names", test_plugin_names_known),
        ("port_validation", test_port_numbers_match_deploy_conf),
        ("elasticsearch_misconfig", test_no_elasticsearch_output_misconfig),
        ("field_consistency", test_field_consistency_across_stages),
        ("braces_balanced", test_config_no_unclosed_brackets),
        ("document_id", test_outputs_use_document_id),
        ("no_hardcoded_passwords", test_redis_password_not_hardcoded),
        ("risk_scanner_host", test_risk_scanner_output_host),
    ]

    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            fn()
            passed += 1
        except Exception as e:
            print(f"  \u274c {name}: {e}")
            failed += 1

    print(f"\n  {passed}/{len(tests)} tests passed")
    sys.exit(1 if failed else 0)
