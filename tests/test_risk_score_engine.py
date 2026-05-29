#!/usr/bin/env python3
"""Unit tests for risk-score-engine.py"""
import json
import sys
import os
import importlib.util

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), 'fixtures')
SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')

# Import risk-score-engine.py (has hyphen, so use importlib)
engine_path = os.path.join(SCRIPTS_DIR, 'risk-score-engine.py')
spec = importlib.util.spec_from_file_location("risk_score_engine", engine_path)
risk_score_engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(risk_score_engine)
compute_overall_risk = risk_score_engine.compute_overall_risk

def load_fixture(name):
    path = os.path.join(FIXTURES_DIR, name)
    findings = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                findings.append(json.loads(line))
    return findings


def test_all_low_severity():
    findings = [
        {"category": "system_hardening", "severity": "low", "weight": 1, "check_id": "LOW-001"},
        {"category": "network_security", "severity": "low", "weight": 1, "check_id": "LOW-002"},
    ]
    result = compute_overall_risk(findings)
    assert result["overall_risk"] < 16, f"Expected low risk, got {result['overall_risk']}"
    assert result["severity"] == "low", f"Expected 'low', got {result['severity']}"


def test_all_critical_severity():
    findings = [
        {"category": "system_hardening", "severity": "critical", "weight": 5, "check_id": "CRIT-001"},
        {"category": "cve_vulnerabilities", "severity": "critical", "weight": 5, "check_id": "CRIT-002"},
        {"category": "advanced_threats", "severity": "critical", "weight": 5, "check_id": "CRIT-003"},
    ]
    result = compute_overall_risk(findings)
    assert result["overall_risk"] > 60, f"Expected high risk, got {result['overall_risk']}"
    assert result["severity"] in ("critical", "high"), f"Expected critical/high, got {result['severity']}"


def test_medium_severity():
    findings = [
        {"category": "system_hardening", "severity": "medium", "weight": 2, "check_id": "MED-001"},
        {"category": "network_security", "severity": "medium", "weight": 1, "check_id": "MED-002"},
    ]
    result = compute_overall_risk(findings)
    assert 15 <= result["overall_risk"] <= 36, f"Expected medium risk (15-36), got {result['overall_risk']}"
    assert result["severity"] == "medium", f"Expected 'medium', got {result['severity']}"


def test_mixed_findings():
    findings = load_fixture('sample-findings.json')
    result = compute_overall_risk(findings)
    assert 0 <= result["overall_risk"] <= 100
    assert result["severity"] in ("low", "medium", "high", "critical")
    assert len(result["categories"]) == 5
    assert len(result["top_findings"]) <= 10
    assert result["top_findings"][0]["score"] >= result["top_findings"][-1]["score"]


def test_empty_findings():
    result = compute_overall_risk([])
    assert result["overall_risk"] == 0.0
    assert result["severity"] == "low"
    assert all(v["score"] == 0 for v in result["categories"].values())


def test_unknown_category():
    findings = [{"category": "unknown_stuff", "severity": "high", "weight": 2}]
    result = compute_overall_risk(findings)
    assert "unknown_stuff" in result["categories"]
    assert result["severity"] == "low"


def test_output_structure():
    findings = load_fixture('sample-findings.json')
    result = compute_overall_risk(findings)
    expected_keys = {"overall_risk", "severity", "categories", "top_findings"}
    assert expected_keys.issubset(result.keys())
    for cat_name, cat_data in result["categories"].items():
        assert "score" in cat_data
        assert "max" in cat_data
        assert "checks_total" in cat_data
    for tf in result["top_findings"]:
        assert "severity" in tf
        assert "check" in tf
        assert "score" in tf


if __name__ == "__main__":
    tests = [
        ("all_low", test_all_low_severity),
        ("all_critical", test_all_critical_severity),
        ("medium", test_medium_severity),
        ("mixed_findings", test_mixed_findings),
        ("empty", test_empty_findings),
        ("unknown_category", test_unknown_category),
        ("output_structure", test_output_structure),
    ]
    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"  PASS  {name}")
            passed += 1
        except AssertionError as e:
            print(f"  FAIL  {name}: {e}")
            failed += 1
        except Exception as e:
            print(f"  ERROR {name}: {e}")
            failed += 1
    print(f"\n  {passed}/{passed + failed} tests passed")
    sys.exit(0 if failed == 0 else 1)
