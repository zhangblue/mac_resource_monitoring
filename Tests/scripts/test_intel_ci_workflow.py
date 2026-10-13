#!/usr/bin/env python3
"""Fail-closed contract for the isolated, read-only Intel validation workflow."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/intel-ci.yml"

# Deliberately pin the whole narrow workflow: unknown triggers, permissions,
# actions, job topology, shell overrides, or publishing steps must not slip in.
EXPECTED = '''name: Intel validation

on:
  push:
    branches: [ci/intel-validation]

permissions:
  contents: read

jobs:
  intel-validation:
    runs-on: macos-15-intel
    steps:
      - name: Checkout source
        uses: actions/checkout@v6
      - name: Verify commit and Intel host
        run: |
          set -euo pipefail
          printf 'github.sha=%s\\n' "$GITHUB_SHA"
          test "$GITHUB_SHA" = "$(git rev-parse HEAD)"
          uname -m
          test "$(uname -m)" = x86_64
          sw_vers
          swift --version
      - name: Check workflow safety
        run: python3 -m unittest discover -s Tests/scripts -p 'test_*workflow.py'
      - name: Run tests on Intel
        run: swift test
      - name: Build thin Intel release
        run: swift build -c release --arch x86_64
      - name: Verify thin Intel executable
        run: |
          set -euo pipefail
          binary="$(swift build -c release --arch x86_64 --show-bin-path)/MacResourceMonitor"
          test -x "$binary"
          test "$(lipo -archs "$binary")" = x86_64
'''


def validate(text):
    """Accept only the reviewed, minimal CI workflow (not arbitrary YAML)."""
    if text != EXPECTED:
        raise AssertionError("Intel workflow differs from the approved read-only contract")


class IntelCIWorkflowTests(unittest.TestCase):
    def test_real_workflow_matches_contract(self):
        self.assertTrue(WORKFLOW.is_file(), "Intel CI workflow is missing")
        validate(WORKFLOW.read_text())

    def test_feature_branch_cannot_replace_validation_branch(self):
        with self.assertRaises(AssertionError):
            validate(EXPECTED.replace("ci/intel-validation", "feature/intel-support"))

    def test_tag_or_manual_trigger_cannot_be_added(self):
        for addition in ("    tags: ['v*']\n", "  workflow_dispatch:\n", "  pull_request:\n"):
            with self.subTest(addition=addition), self.assertRaises(AssertionError):
                validate(EXPECTED.replace("permissions:\n", addition + "\npermissions:\n"))

    def test_runner_and_permissions_cannot_change(self):
        for original, replacement in (("macos-15-intel", "macos-15"),
                                      ("contents: read", "contents: write")):
            with self.subTest(replacement=replacement), self.assertRaises(AssertionError):
                validate(EXPECTED.replace(original, replacement))

    def test_upload_and_publish_steps_cannot_be_added(self):
        for command in ("actions/upload-artifact@v4", "gh release create", "bash scripts/build-dmg.sh"):
            with self.subTest(command=command), self.assertRaises(AssertionError):
                validate(EXPECTED + "      - name: Publish\n        run: " + command + "\n")

    def test_provenance_architecture_and_test_commands_cannot_be_skipped(self):
        for command in ('test "$GITHUB_SHA" = "$(git rev-parse HEAD)"',
                        'test "$(uname -m)" = x86_64', 'run: swift test',
                        'run: swift build -c release --arch x86_64',
                        'test "$(lipo -archs "$binary")" = x86_64'):
            with self.subTest(command=command), self.assertRaises(AssertionError):
                validate(EXPECTED.replace(command, "echo skipped"))


if __name__ == "__main__":
    unittest.main()
