#!/usr/bin/env python3
"""Regression tests for the release workflow's static command gate."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()
GATE = (ROOT / "Tests/scripts/check-release-workflow.py").read_text()


class ReleaseWorkflowGateTests(unittest.TestCase):
    def check_workflow(self, workflow):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(workflow)
            script = root / "Tests/scripts/check-release-workflow.py"
            script.parent.mkdir(parents=True)
            script.write_text(GATE)
            return subprocess.run(["python3", str(script)], capture_output=True, text=True)

    def replaced_run(self, original, replacement):
        self.assertEqual(WORKFLOW.count(original), 1)
        return WORKFLOW.replace(original, replacement)

    def test_real_workflow_passes(self):
        result = self.check_workflow(WORKFLOW)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_echo_swift_test_is_not_execution(self):
        result = self.check_workflow(self.replaced_run("run: swift test", "run: echo swift test"))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_echo_verify_release_is_not_execution(self):
        result = self.check_workflow(self.replaced_run(
            "run: bash scripts/verify-release.sh", "run: echo bash scripts/verify-release.sh"))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_comment_does_not_count_as_command(self):
        result = self.check_workflow(self.replaced_run(
            "run: swift test", "run: |\n          # swift test\n          echo skipped"))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_string_literal_does_not_count_as_command(self):
        result = self.check_workflow(self.replaced_run(
            "run: swift test", 'run: printf "swift test\\n"'))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_echo_checksum_is_not_execution(self):
        result = self.check_workflow(self.replaced_run(
            "          shasum -a 256 dist/MacResourceMonitor.dmg \\\n",
            "          echo shasum -a 256 dist/MacResourceMonitor.dmg \\\n"))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_echo_release_is_not_execution(self):
        result = self.check_workflow(self.replaced_run(
            '          gh release create "$GITHUB_REF_NAME" \\\n',
            '          echo gh release create "$GITHUB_REF_NAME" \\\n'))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_reordered_steps_are_rejected(self):
        workflow = self.replaced_run("- name: Run tests", "- name: Run tests renamed")
        result = self.check_workflow(workflow)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_failure_suppression_is_rejected(self):
        result = self.check_workflow(self.replaced_run("run: swift test", "run: swift test || true"))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_verify_step_custom_shell_cannot_skip_run(self):
        workflow = self.replaced_run(
            "        run: bash scripts/verify-release.sh",
            '        shell: bash -c "echo bypassed" -- {0}\n        run: bash scripts/verify-release.sh')
        result = self.check_workflow(workflow)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_job_custom_shell_is_rejected(self):
        workflow = self.replaced_run(
            "    runs-on: macos-15", "    runs-on: macos-15\n    defaults:\n      run:\n        shell: bash -c 'echo bypassed' -- {0}")
        result = self.check_workflow(workflow)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_workflow_defaults_shell_is_rejected(self):
        workflow = self.replaced_run(
            "jobs:\n", "defaults:\n  run:\n    shell: bash -c 'echo bypassed' -- {0}\n\njobs:\n")
        result = self.check_workflow(workflow)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_workflow_inline_defaults_are_rejected(self):
        workflow = self.replaced_run(
            "jobs:\n", "defaults: {run: {shell: bash}}\n\njobs:\n")
        result = self.check_workflow(workflow)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_extra_job_is_rejected(self):
        result = self.check_workflow(WORKFLOW + "\n  bypass:\n    runs-on: macos-15\n")
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
