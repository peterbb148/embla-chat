"""Verify fail-closed maintainer attestations without credentials or real alert payloads."""

import json
import unittest
from unittest.mock import patch

from check_secret_alerts import OWNER, REPOSITORY, attest

SHA = "a" * 40


class SecretAttestationTests(unittest.TestCase):
    def run_fixture(self, *, counts: str = "0\n", broken: bool = False,
                    changed: bool = False, external: bool = False, approved: bool = True,
                    review_sha: str = SHA, revoked: bool = False) -> list[str]:
        """Use explicit API fixtures and retain only status states for assertions."""
        states = []
        reads = 0
        review_reads = 0

        def cli(*args: str) -> str:
            """Return explicit API fixture data without credentials or network access."""
            nonlocal reads, review_reads
            if args == ("api", "user"):
                return json.dumps({"login": OWNER})
            if any("/statuses/" in arg for arg in args):
                states.append(next(arg.split("=", 1)[1] for arg in args
                                   if arg.startswith("state=")))
                return "{}"
            if any("/reviews" in arg for arg in args):
                review_reads += 1
                state = "APPROVED" if approved else "CHANGES_REQUESTED"
                if revoked and review_reads > 1:
                    state = "DISMISSED"
                return json.dumps([[{"id": 1, "user": {"login": OWNER},
                                     "state": state, "commit_id": review_sha}]])
            if any("secret-scanning/alerts" in arg for arg in args):
                if broken:
                    raise ValueError("Unavailable API")
                return counts
            reads += 1
            return json.dumps({"state": "open", "user": {"login": "outside" if external else OWNER},
                               "base": {"ref": "main", "repo": {"full_name": REPOSITORY}},
                               "head": {"sha": "b" * 40 if changed and reads > 1 else SHA}})

        with patch("check_secret_alerts.gh", side_effect=cli):
            try:
                attest(49, SHA)
            except ValueError:
                pass
        return states

    def test_all_pages_must_be_zero(self) -> None:
        self.assertEqual(self.run_fixture(counts="0\n0\n"), ["pending", "success"])
        self.assertEqual(self.run_fixture(counts="0\n1\n"), ["pending", "failure"])

    def test_unavailable_or_invalid_inventory_never_attests_success(self) -> None:
        self.assertEqual(self.run_fixture(broken=True), ["pending", "failure"])
        for counts in ["", "{}", "-1", "not data"]:
            self.assertEqual(self.run_fixture(counts=counts), ["pending", "failure"])

    def test_head_change_invalidates_query(self) -> None:
        self.assertEqual(self.run_fixture(changed=True), ["pending", "failure"])

    def test_external_approval_is_required(self) -> None:
        self.assertEqual(self.run_fixture(external=True, approved=False), ["pending", "failure"])
        self.assertEqual(self.run_fixture(external=True), ["pending", "success"])

    def test_approval_of_an_older_commit_is_not_enough(self) -> None:
        states = self.run_fixture(external=True, review_sha="b" * 40)
        self.assertEqual(states, ["pending", "failure"])

    def test_approval_withdrawn_during_inventory_invalidates_attestation(self) -> None:
        states = self.run_fixture(external=True, revoked=True)
        self.assertEqual(states, ["pending", "failure"])

    def test_non_owner_authentication_cannot_publish(self) -> None:
        with patch("check_secret_alerts.gh", return_value='{"login":"outside"}') as cli:
            with self.assertRaises(ValueError):
                attest(49, SHA)
            self.assertEqual(cli.call_count, 1)


if __name__ == "__main__":
    unittest.main()
