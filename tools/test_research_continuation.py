import datetime as dt
import contextlib
import io
import json
import multiprocessing
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import research_continuation as rc


def fallback_args(owner: str) -> list[str]:
    return ["claim", "--owner-thread", owner, "--branch", rc.BRANCH, "--mode", "fallback",
            "--user-paused", "false", "--ordinary-usage", "exhausted", "--spark-available", "true",
            "--primary-task-running", "false", "--evidence-at", rc.iso(rc.utc_now())]


def race_claim(state: str, owner: str, queue: multiprocessing.Queue) -> None:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        queue.put(rc.main(["--state", state, *fallback_args(owner)]))


class ResearchContinuationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name) / "coordination.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def invoke(self, *args: str) -> int:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return rc.main(["--state", str(self.state), *args])

    def test_status_is_empty_without_creating_state(self) -> None:
        self.assertEqual(self.invoke("status"), 0)
        self.assertFalse(self.state.exists())

    def test_race_allows_only_one_owner(self) -> None:
        queue: multiprocessing.Queue = multiprocessing.Queue()
        first = multiprocessing.Process(target=race_claim, args=(str(self.state), "root-a", queue))
        second = multiprocessing.Process(target=race_claim, args=(str(self.state), "root-b", queue))
        first.start(); second.start(); first.join(); second.join()
        self.assertEqual(sorted([queue.get(), queue.get()]), [0, 2])
        saved = json.loads(self.state.read_text())
        self.assertIn(saved["researchContinuation"]["activeClaim"]["ownerThread"], {"root-a", "root-b"})

    def test_ambiguous_or_low_quota_fails_closed(self) -> None:
        for quota in ("unknown", "low"):
            args = fallback_args("fallback")
            args[args.index("--ordinary-usage") + 1] = quota
            self.assertEqual(self.invoke(*args), 2)
        self.assertFalse(self.state.exists())

    def test_paused_or_running_primary_refuses_fallback(self) -> None:
        paused = fallback_args("fallback")
        paused[paused.index("--user-paused") + 1] = "true"
        self.assertEqual(self.invoke(*paused), 2)
        running = fallback_args("fallback")
        running[running.index("--primary-task-running") + 1] = "true"
        self.assertEqual(self.invoke(*running), 2)

    def test_another_owner_blocks_without_stale_timeout_takeover(self) -> None:
        self.assertEqual(self.invoke("claim", "--owner-thread", "root", "--branch", rc.BRANCH,
                                  "--mode", "explicit", "--user-paused", "false"), 0)
        denied = fallback_args("spark")
        self.assertEqual(self.invoke(*denied), 2)

    def test_wrong_owner_cannot_release_and_correct_release_allows_new_claim(self) -> None:
        self.assertEqual(self.invoke("claim", "--owner-thread", "root", "--branch", rc.BRANCH,
                                  "--mode", "explicit", "--user-paused", "false"), 0)
        self.assertEqual(self.invoke("release", "--owner-thread", "spark"), 2)
        self.assertEqual(self.invoke("release", "--owner-thread", "root"), 0)
        self.assertEqual(self.invoke(*fallback_args("spark")), 0)

    def test_abrupt_primary_exhaustion_can_handoff_only_to_the_expected_owner(self) -> None:
        self.assertEqual(self.invoke("claim", "--owner-thread", "astra", "--branch", rc.BRANCH,
                                  "--mode", "explicit", "--user-paused", "false"), 0)
        takeover = fallback_args("spark") + ["--takeover-owner-thread", "astra", "--prior-owner-running", "false"]
        self.assertEqual(self.invoke(*takeover), 0)
        saved = json.loads(self.state.read_text())
        self.assertEqual(saved["researchContinuation"]["activeClaim"]["ownerThread"], "spark")
        self.assertEqual(saved["researchContinuation"]["activeClaim"]["ownerKind"], "codex-spark")
        handoff = saved["researchContinuation"]["history"][-2]
        self.assertEqual(handoff["event"], "handoff")
        self.assertEqual(handoff["displacedClaim"]["ownerThread"], "astra")
        self.assertEqual(saved["status"], "active")
        self.assertEqual(saved["owner_thread_id"], "spark")

    def test_takeover_refuses_wrong_expected_owner_or_running_or_missing_prior_status(self) -> None:
        self.assertEqual(self.invoke("claim", "--owner-thread", "astra", "--branch", rc.BRANCH,
                                  "--mode", "explicit", "--user-paused", "false"), 0)
        wrong = fallback_args("spark") + ["--takeover-owner-thread", "other", "--prior-owner-running", "false"]
        self.assertEqual(self.invoke(*wrong), 2)
        running = fallback_args("spark") + ["--takeover-owner-thread", "astra", "--prior-owner-running", "true"]
        self.assertEqual(self.invoke(*running), 2)
        missing = fallback_args("spark") + ["--takeover-owner-thread", "astra"]
        self.assertEqual(self.invoke(*missing), 2)
        saved = json.loads(self.state.read_text())
        self.assertEqual(saved["researchContinuation"]["activeClaim"]["ownerThread"], "astra")

    def test_persisted_pause_blocks_cli_false_without_clearing_it(self) -> None:
        self.state.write_text(json.dumps({"user_paused": True, "unrelated": "keep"}))
        self.assertEqual(self.invoke("claim", "--owner-thread", "astra", "--branch", rc.BRANCH,
                                  "--mode", "explicit", "--user-paused", "false"), 2)
        self.assertEqual(self.invoke(*fallback_args("spark")), 2)
        saved = json.loads(self.state.read_text())
        self.assertTrue(saved["user_paused"])
        self.assertEqual(saved["unrelated"], "keep")

    def test_checkpoint_preserves_unrelated_state_and_requires_owner(self) -> None:
        self.state.write_text(json.dumps({"unrelated": {"keep": True}}))
        self.assertEqual(self.invoke("claim", "--owner-thread", "root", "--branch", rc.BRANCH,
                                  "--mode", "explicit", "--user-paused", "false"), 0)
        self.assertEqual(self.invoke("checkpoint", "--owner-thread", "other"), 2)
        self.assertEqual(self.invoke("checkpoint", "--owner-thread", "root", "--note", "verified"), 0)
        saved = json.loads(self.state.read_text())
        self.assertTrue(saved["unrelated"]["keep"])
        self.assertEqual(saved["status"], "active")
        self.assertEqual(saved["owner_thread_id"], "root")
        self.assertIn("updated_at", saved)

    def test_wrong_branch_and_stale_evidence_refuse(self) -> None:
        self.assertEqual(self.invoke("claim", "--owner-thread", "root", "--branch", "main",
                                  "--mode", "explicit", "--user-paused", "false"), 2)
        stale = fallback_args("spark")
        stale[stale.index("--evidence-at") + 1] = rc.iso(rc.utc_now() - dt.timedelta(seconds=301))
        self.assertEqual(self.invoke(*stale), 2)


if __name__ == "__main__":
    unittest.main()
