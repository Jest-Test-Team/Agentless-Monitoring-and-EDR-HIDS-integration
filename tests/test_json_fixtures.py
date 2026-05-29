#!/usr/bin/env python3
"""Validate all JSON fixture files in tests/fixtures/."""
import json
import sys
from pathlib import Path

fixtures_dir = Path(__file__).parent / "fixtures"
errors = 0

for fpath in sorted(fixtures_dir.glob("*.json")):
    with open(fpath) as fp:
        for i, line in enumerate(fp, 1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                json.loads(stripped)
            except json.JSONDecodeError as e:
                print(f"  \u274c {fpath.name}:{i} \u2014 {e}")
                errors += 1
    if errors == 0:
        print(f"  \u2705 {fpath.name} \u2014 all lines valid JSON")

sys.exit(1 if errors else 0)
