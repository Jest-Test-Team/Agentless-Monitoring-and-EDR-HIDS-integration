#!/usr/bin/env python3
"""
risk-score-engine.py — Central scoring engine for risk-scanner.

Reads raw findings from stdin/file, computes category scores and overall risk,
outputs structured JSON compatible with OpenSearch risk-scores-* index.

Usage:
    risk-score-engine.py --findings findings.json --hostname host01 --tier tier2
    cat findings.json | risk-score-engine.py --hostname host01 --tier tier2
"""
import json
import sys
import argparse
from datetime import datetime, timezone
from pathlib import Path


# ── Configuration ──

SEVERITY_WEIGHTS = {
    "critical": 1.0,
    "high": 0.6,
    "medium": 0.3,
    "low": 0.1,
}

CATEGORY_CONFIG = {
    "system_hardening": {"max_score": 150, "display_name": "System Hardening"},
    "cve_vulnerabilities": {"max_score": 100, "display_name": "CVE & Vulnerabilities"},
    "network_security": {"max_score": 80, "display_name": "Network Security"},
    "container_security": {"max_score": 60, "display_name": "Container & App Security"},
    "advanced_threats": {"max_score": 80, "display_name": "Advanced Threats"},
}

SEVERITY_THRESHOLDS = [
    (61, "critical"),
    (36, "high"),
    (16, "medium"),
    (0, "low"),
]


def compute_overall_risk(findings: list) -> dict:
    """Compute risk score from findings list."""
    categories = {k: {"findings": [], "score": 0.0} for k in CATEGORY_CONFIG}
    top_findings = []

    for f in findings:
        cat = f.get("category", "unknown")
        severity = f.get("severity", "low")
        weight = f.get("weight", 1)
        sev_weight = SEVERITY_WEIGHTS.get(severity, 0.1)
        score = weight * sev_weight * 25  # scale factor

        if cat in categories:
            categories[cat]["findings"].append(f)
            categories[cat]["score"] += score
        else:
            categories.setdefault(cat, {"findings": [], "score": 0.0})
            categories[cat]["findings"].append(f)
            categories[cat]["score"] += score

        top_findings.append({
            "severity": severity,
            "check": f.get("check_id", "UNKNOWN"),
            "description": f.get("description", ""),
            "score": round(score, 1),
            "detail": f.get("detail", ""),
            "recommendation": f.get("recommendation", ""),
        })

    # Build category results
    category_results = {}
    total_risk = 0.0
    for cat_name, config in CATEGORY_CONFIG.items():
        cat_data = categories.get(cat_name, {"findings": [], "score": 0.0})
        max_score = config["max_score"]
        raw_score = min(cat_data["score"], max_score)
        category_results[cat_name] = {
            "score": round(raw_score, 1),
            "max": max_score,
            "checks_total": len(cat_data["findings"]),
            "checks_passed": sum(
                1 for f in cat_data["findings"]
                if f.get("severity") in ("low", "none")
            ),
            "critical_findings": sum(
                1 for f in cat_data["findings"]
                if f.get("severity") == "critical"
            ),
        }
        # Normalize contribution
        total_risk += (raw_score / max_score) * 100 / len(CATEGORY_CONFIG)

    # Determine severity
    overall_risk = round(min(total_risk, 100), 1)
    severity = "low"
    for threshold, label in SEVERITY_THRESHOLDS:
        if overall_risk >= threshold:
            severity = label
            break

    # Sort top findings by score descending
    top_findings.sort(key=lambda x: x["score"], reverse=True)
    top_findings = top_findings[:10]  # top 10

    return {
        "overall_risk": overall_risk,
        "severity": severity,
        "categories": category_results,
        "top_findings": top_findings,
    }


def main():
    parser = argparse.ArgumentParser(description="Risk Score Engine")
    parser.add_argument("--findings", type=str, help="Path to findings JSON file")
    parser.add_argument("--hostname", type=str, required=True, help="Hostname")
    parser.add_argument("--tier", type=str, default="tier2", help="Tier tier1/tier2/tier3")
    args = parser.parse_args()

    # Read findings
    findings = []
    if args.findings:
        findings_path = Path(args.findings)
        if not findings_path.exists():
            print(json.dumps({"error": f"Findings file not found: {args.findings}"}))
            sys.exit(1)
        with open(findings_path) as f:
            content = f.read().strip()
            if content:
                for line in content.split("\n"):
                    line = line.strip()
                    if line:
                        try:
                            findings.append(json.loads(line))
                        except json.JSONDecodeError as e:
                            print(
                                json.dumps({"error": f"JSON parse error: {e}", "line": line[:100]}),
                                file=sys.stderr,
                            )

    # Compute
    result = compute_overall_risk(findings)

    # Build output
    output = {
        "host": args.hostname,
        "tier": args.tier,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scanner_version": "1.0.0",
        **result,
    }

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
