"""Exercise publication gates without changing remote release state."""

import argparse
import json
import os
import unittest
from unittest.mock import patch

import release


COMMIT = "1" * 40


class GateTest(unittest.TestCase):
    def setUp(self):
        self.version = "0.1.0"
        self.latest = {"headSha": COMMIT, "status": "completed", "conclusion": "success", "databaseId": 42}
        self.jobs = [
            {"name": "Binary size and instantiations", "conclusion": "success"},
            {"name": "Test (ubuntu-latest)", "steps": [
                {"name": "Validate assembled fixture bundles", "conclusion": "success"},
            ]},
        ]
        self.open_gates = []
        self.role = "maintain"
        self.args = argparse.Namespace(tag="v0.1.0", repo="zig-utils/zig-routing", approve_1_0=False)
        for name, effect in (("metadata", self.metadata), ("output", self.command), ("run", lambda *_: None)):
            stub = patch.object(release, name, side_effect=effect)
            stub.start()
            self.addCleanup(stub.stop)

    def metadata(self):
        return self.version, "zig", COMMIT

    def command(self, *args):
        if args[:2] == ("git", "rev-parse"):
            return COMMIT
        if args[:2] == ("gh", "api"):
            return self.role
        if args[:3] == ("gh", "run", "list"):
            self.assertIn(COMMIT, args)
            return json.dumps([self.latest])
        if args[:3] == ("gh", "run", "view"):
            return json.dumps({"jobs": self.jobs})
        if args[:3] == ("gh", "issue", "list"):
            self.assertIn("type:gate", args)
            return json.dumps(self.open_gates)
        self.fail(f"Unexpected command {args}")

    def test_current_commit_passes_all_gates(self):
        release.gate(self.args)

    def test_unfinished_ci_blocks_publication(self):
        self.latest["status"] = "in_progress"
        with self.assertRaisesRegex(SystemExit, "successful main CI"):
            release.gate(self.args)

    def test_latest_ci_must_match_commit(self):
        self.latest["headSha"] = "2" * 40
        with self.assertRaisesRegex(SystemExit, "tagged commit"):
            release.gate(self.args)

    def test_regional_budget_must_run(self):
        self.jobs[1]["steps"][0]["conclusion"] = "skipped"
        with self.assertRaisesRegex(SystemExit, "performance checks"):
            release.gate(self.args)

    def test_open_full_engine_gate_blocks_publication(self):
        self.open_gates = [{"number": 228}]
        with self.assertRaisesRegex(SystemExit, "#228"):
            release.gate(self.args)

    def test_one_point_zero_needs_explicit_maintainer_dispatch(self):
        self.version = "1.0.0"
        self.args.tag = "v1.0.0"
        with patch.dict(os.environ, GITHUB_EVENT_NAME="push", GITHUB_ACTOR="example"):
            with self.assertRaisesRegex(SystemExit, "explicit maintainer dispatch"):
                release.gate(self.args)
        with patch.dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR="example"):
            self.args.approve_1_0 = True
            self.role = "write"
            with self.assertRaisesRegex(SystemExit, "maintainer or admin"):
                release.gate(self.args)
            self.role = "maintain"
            release.gate(self.args)


if __name__ == "__main__":
    unittest.main()
