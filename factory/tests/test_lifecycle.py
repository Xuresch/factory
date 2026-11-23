"""Lifecycle decisions over parsed reports and observed facts."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
from lifecycle import Effect, Facts, decide


class LifecycleTests(unittest.TestCase):
    def test_advice_and_explicit_target_share_destination_and_reason(self):
        cases = [
            ("gate", 1, Facts(gate={"verdict": "PASS", "commit": "abc"}, head="abc"),
             "review", "the gate passed"),
            ("gate", 1, Facts(gate={"verdict": "FAIL", "commit": "abc"}, head="abc"),
             "build", "round 1 of 2"),
            ("gate", 2, Facts(gate={"verdict": "FAIL", "commit": "abc"}, head="abc"),
             "needs-human", "round 2 of 2"),
            ("review", 1, Facts(reviews={"code": "PASS", "ux": "PASS"}),
             "approve", "every review passed"),
            ("review", 1, Facts(reviews={"code": "PASS", "ux": "CHANGES"}),
             "build", "round 1 of 2"),
            ("review", 2, Facts(reviews={"code": "PASS", "ux": "CHANGES"}),
             "needs-human", "round 2 of 2"),
            ("review", 1, Facts(reviews={"code": "CHANGES"}, disputes=({"key": "code F1"},)),
             "needs-human", "code F1 stayed disputed"),
        ]
        for stage, number, facts, destination, reason in cases:
            with self.subTest(stage=stage, number=number, facts=facts):
                job = {"id": "fixture", "stage": stage, "round": number, "round_limit": 2}
                advice = decide(job, facts)
                self.assertEqual((advice.action, advice.stage, advice.reason), ("advance", destination, reason))
                self.assertEqual(decide(job, facts, target=destination), advice)
                wrong = "needs-human" if destination != "needs-human" else "build"
                refusal = decide(job, facts, target=wrong)
                self.assertEqual(refusal.action, "refuse")
                self.assertIn(reason, refusal.reason)
                self.assertFalse(refusal.effects)

    def test_unusable_gate_verdicts_call_for_a_rerun_without_effects(self):
        cases = [
            ("pending", None, "run the gate first"),
            ("PASS", "old", "another commit"),
            ("FAIL", None, "another commit"),
            ("invalid", "abc", "first line"),
            ("invalid", None, "first line"),
        ]
        for verdict, commit, reason in cases:
            for number in (1, 2):
                with self.subTest(verdict=verdict, commit=commit, number=number):
                    job = {"id": "fixture", "stage": "gate", "round": number, "round_limit": 2}
                    facts = Facts(gate={"verdict": verdict, "commit": commit}, head="abc")
                    advice = decide(job, facts)
                    self.assertEqual(advice.action, "rerun-gate")
                    self.assertIsNone(advice.stage)
                    self.assertIn(reason, advice.reason)
                    self.assertFalse(advice.effects)
                    for target in ("review", "build", "needs-human"):
                        refusal = decide(job, facts, target=target)
                        self.assertEqual(refusal.action, "refuse")
                        self.assertEqual(refusal.reason, advice.reason)
                        self.assertFalse(refusal.effects)

    def test_merge_recovery_compares_the_current_round_to_the_limit(self):
        for number, destination in ((1, "build"), (2, "needs-human")):
            with self.subTest(round=number):
                job = {"id": "fixture", "stage": "merging", "round": number, "round_limit": 2}
                facts = Facts(merge_outcome="recoverable", merge_reason="The base conflicts.")
                transition = decide(job, facts)
                self.assertEqual((transition.stage, transition.reason), (destination, "The base conflicts."))
                self.assertEqual(decide(job, facts, target=destination), transition)

    def test_rewind_keeps_or_renews_the_round_allowance(self):
        for limit, expected in ((2, 5), (9, 9)):
            with self.subTest(limit=limit):
                job = {"id": "fixture", "stage": "review", "round": 2, "round_limit": limit}
                rewind = decide(job, target="build", intent="rewind", max_rounds=3)
                self.assertEqual((rewind.action, rewind.stage), ("rewind", "build"))
                self.assertIn(Effect("reset_after_feedback", (expected,)), rewind.effects)
