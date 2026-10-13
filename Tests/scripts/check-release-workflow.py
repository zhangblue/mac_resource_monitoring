#!/usr/bin/env python3
"""Fail closed on release steps that bypass universal artifact verification."""

from pathlib import Path
import re

workflow = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
text = workflow.read_text()
lines = text.splitlines()


def require(condition, message):
    if not condition:
        raise SystemExit(f"release workflow gate: {message}")


# A deliberately narrow parser: fail rather than silently accept an unrecognized
# workflow layout. Do not add a YAML package dependency just for this gate.
require(re.search(r'^    runs-on: macos-15$', text, re.M), "expected macos-15 runner")
jobs = text.split("\njobs:\n", 1)
require(len(jobs) == 2, "expected jobs section")
require(re.findall(r'^  [\w-]+:\s*$', jobs[1], re.M) == ["  build-and-release:"], "expected one release job")
require(not re.search(r'^\s+(?:if|continue-on-error):', text, re.M), "conditional or nonfatal steps are not permitted")
require(not re.search(r'^\s+(?:needs|strategy):', text, re.M), "unexpected job topology")

steps = []
for line in lines:
    match = re.match(r'^      - name: (.+)$', line)
    if match:
        steps.append({"name": match.group(1), "lines": []})
    elif steps:
        steps[-1]["lines"].append(line)

require(steps, "no steps parsed")
expected = [
    ("Checkout source", r"actions/checkout@v6"),
    ("Check release workflow", r"python3 Tests/scripts/check-release-workflow.py"),
    ("Run tests", r"swift test"),
    ("Build arm64 release", r"swift build -c release --arch arm64"),
    ("Build x86_64 release", r"swift build -c release --arch x86_64"),
    ("Build application", r"bash scripts/build-app.sh"),
    ("Build DMG", r"bash scripts/build-dmg.sh"),
    ("Verify release", r"bash scripts/verify-release.sh"),
    ("Generate checksum", r"shasum -a 256 dist/MacResourceMonitor.dmg"),
    ("Create GitHub Release", r'gh release create'),
]
require([s["name"] for s in steps] == [name for name, _ in expected], "missing, extra, or reordered release step")
for step, (name, command) in zip(steps, expected):
    body = "\n".join(step["lines"])
    if name == "Checkout source":
        require("uses: actions/checkout@v6" in body, "checkout action changed")
        continue
    require(re.search(r'^        run: (?:\||.+)$', body, re.M), f"{name} lacks run")
    require(command in body, f"{name} lacks {command}")
    require("||" not in body and not re.search(r'\b(?:true|exit 0)\b', body), f"{name} suppresses errors")

checksum = "\n".join(steps[-2]["lines"])
release = "\n".join(steps[-1]["lines"])
require("> dist/MacResourceMonitor.dmg.sha256" in checksum, "checksum output path changed")
require("dist/MacResourceMonitor.dmg.sha256" in release and "dist/MacResourceMonitor.dmg" in release, "release assets changed")
require("--verify-tag" in release, "release must verify tag")
print("PASS: tests, both builds, app, DMG, verify, checksum, release in fail-closed order")
