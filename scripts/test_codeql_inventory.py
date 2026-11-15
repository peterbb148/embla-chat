"""Regression checks for whole-head coverage and existing-alert reconciliation."""

import unittest

from check_codeql_inventory import final_analyses, require_clean_sarif, require_fixed_instance

SHA = "1" * 40
REF = "refs/pull/49/merge"


def analyses() -> list[dict]:
    """Return explicit fixture metadata for the three required successful analyses."""
    return [{"id": i, "category": f"/language:{language}", "commit_sha": SHA, "ref": REF,
             "tool": {"name": "CodeQL"}, "error": "", "warning": "", "results_count": 0}
            for i, language in enumerate(["swift", "actions", "python"], 1)]


class InventoryTests(unittest.TestCase):
    def test_all_exact_head_languages_required(self) -> None:
        self.assertEqual(len(final_analyses(analyses(), SHA, REF)), 3)
        self.assertIsNone(final_analyses(analyses()[:1], SHA, REF))
        self.assertIsNone(final_analyses(analyses(), "2" * 40, REF))

    def test_failed_zero_result_analysis_is_not_clean(self) -> None:
        rows = analyses()
        rows[0]["error"] = "extraction failed"
        with self.assertRaises(ValueError):
            final_analyses(rows, SHA, REF)

    def test_unchanged_file_finding_blocks_even_if_pr_diff_is_clean(self) -> None:
        sarif = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "CodeQL"}},
                 "results": [{"ruleId": "fixture-unchanged-file-vulnerability"}]}]}
        with self.assertRaises(ValueError):
            require_clean_sarif(sarif)
        sarif["runs"][0]["results"] = []
        require_clean_sarif(sarif)

    def test_missing_full_results_fail_closed(self) -> None:
        for sarif in [{}, {"version": "2.1.0", "runs": []},
                      {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "CodeQL"}}}]}]:
            with self.assertRaises(ValueError):
                require_clean_sarif(sarif)

    def test_existing_main_alert_needs_actual_fixed_instance_at_final_head(self) -> None:
        for instances in [[], [{"commit_sha": SHA, "ref": REF, "state": "open"}],
                          [{"commit_sha": "2" * 40, "ref": REF, "state": "fixed"}]]:
            with self.assertRaises(ValueError):
                require_fixed_instance(instances, SHA, REF)
        require_fixed_instance([{"commit_sha": SHA, "ref": REF, "state": "fixed"}], SHA, REF)


if __name__ == "__main__":
    unittest.main()
