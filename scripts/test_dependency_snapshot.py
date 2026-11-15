"""Failure-path regressions for the required dependency-completeness guard."""

import base64
import unittest

from check_dependency_snapshot import REQUIRED_MANIFESTS, require_manifests, validate_page


class SnapshotTests(unittest.TestCase):
    def test_complete_empty_base_and_present_head_manifests(self) -> None:
        changes = [
            {"manifest": name, "change_type": "added", "vulnerabilities": []}
            for name in REQUIRED_MANIFESTS
        ]
        require_manifests(validate_page("", changes))

    def test_unavailable_snapshot_never_passes_after_audit_retry_timeout(self) -> None:
        warning = base64.b64encode(b"Head dependency snapshot unavailable").decode()
        with self.assertRaises(ValueError):
            validate_page(warning, [])

    def test_base_warning_is_not_silently_treated_as_intentionally_empty(self) -> None:
        warning = base64.b64encode(b"Base dependency snapshot unavailable").decode()
        with self.assertRaises(ValueError):
            validate_page(warning, [])

    def test_empty_or_partial_head_does_not_count_as_zero_vulnerabilities(self) -> None:
        with self.assertRaises(ValueError):
            require_manifests(set())
        with self.assertRaises(ValueError):
            require_manifests({"Package.resolved"})

    def test_completed_snapshot_with_a_low_vulnerability_still_fails(self) -> None:
        with self.assertRaises(ValueError):
            validate_page("", [{
                "manifest": "Package.resolved", "change_type": "added",
                "vulnerabilities": [{"severity": "low"}],
            }])

    def test_removed_vulnerable_dependency_is_not_present_in_proposed_head(self) -> None:
        manifests = validate_page("", [{
            "manifest": "old-manifest", "change_type": "removed",
            "vulnerabilities": [{"severity": "high"}],
        }])
        self.assertEqual(manifests, set())

    def test_bad_headers_and_payloads_fail(self) -> None:
        for warning, changes in [("!bad!", []), ("", {}), ("", [{"manifest": "x"}])]:
            with self.assertRaises(ValueError):
                validate_page(warning, changes)


if __name__ == "__main__":
    unittest.main()
