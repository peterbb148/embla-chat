"""Require whole-final-head CodeQL evidence and reconcile open main-branch findings."""

import json
import os
import re
import subprocess
import sys
import time

CATEGORIES = {"/language:swift", "/language:actions", "/language:python"}


def final_analyses(rows: list[dict], sha: str, ref: str) -> list[dict] | None:
    """Return all required successful latest analyses, or wait for exact-head publication."""
    selected = []
    for category in sorted(CATEGORIES):
        candidates = [row for row in rows if row.get("category") == category
                      and row.get("ref") == ref and row.get("tool", {}).get("name") == "CodeQL"]
        if not candidates:
            return None
        row = max(candidates, key=lambda item: item["id"])
        if row.get("commit_sha") != sha:
            return None
        if row.get("error") or row.get("warning") or row.get("results_count") != 0:
            raise ValueError(f"CodeQL {category} has findings or incomplete analysis")
        selected.append(row)
    return selected


def require_clean_sarif(document: dict) -> None:
    """Reject findings anywhere in the full published result, including unchanged files."""
    runs = document.get("runs")
    if document.get("version") != "2.1.0" or not isinstance(runs, list) or not runs:
        raise ValueError("Missing full SARIF analysis")
    for run in runs:
        if run.get("tool", {}).get("driver", {}).get("name") != "CodeQL":
            raise ValueError("Unexpected SARIF tool")
        if not isinstance(run.get("results"), list) or run["results"]:
            raise ValueError("Full final-head CodeQL results contain findings or are unavailable")
        for invocation in run.get("invocations", []):
            if invocation.get("executionSuccessful") is False:
                raise ValueError("CodeQL invocation failed")


def require_fixed_instance(instances: list[dict], sha: str, ref: str) -> None:
    """Require published exact-head fixed state for an alert still open on main."""
    if not any(row.get("commit_sha") == sha and row.get("ref") == ref
               and row.get("state") == "fixed" for row in instances):
        raise ValueError("Main-branch alert lacks final-head evidence that it is fixed")


class GitHub:
    """Read security evidence without printing request credentials or source snippets."""

    def __init__(self, repository: str, token: str) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Invalid repository identifier")
        self.root = f"repos/{repository}/code-scanning/"
        self.token = token

    def get(self, path: str, params: dict, accept: str = "application/vnd.github+json") -> object:
        """Fetch an authenticated response; failures propagate as failed checks."""
        command = ["gh", "api", self.root + path, "--method", "GET",
                   "-H", f"Accept: {accept}", "-H", "X-GitHub-Api-Version: 2022-11-28"]
        for key, value in params.items():
            command.extend(["-f", f"{key}={value}"])
        response = subprocess.run(
            command, capture_output=True, text=True, check=False,
            env=dict(os.environ, GH_TOKEN=self.token),
        )
        if response.returncode != 0:
            raise ValueError("GitHub CLI could not obtain required security evidence")
        return json.loads(response.stdout)

    def pages(self, path: str, params: dict) -> list[dict]:
        """Read all list pages, rejecting non-list or unavailable inventories."""
        rows = []
        page = 1
        while True:
            batch = self.get(path, dict(params, per_page=100, page=page))
            if not isinstance(batch, list) or not all(isinstance(row, dict) for row in batch):
                raise ValueError("Invalid security inventory response")
            rows.extend(batch)
            if len(batch) < 100:
                return rows
            page += 1


def main() -> None:
    """Wait for ingestion, inspect all full results, then verify current main alerts."""
    sha, ref = os.environ["GITHUB_SHA"], os.environ["GITHUB_REF"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Expected exact workflow commit")
    if not re.fullmatch(r"refs/(heads/[A-Za-z0-9._/-]+|pull/[0-9]+/merge)", ref):
        raise ValueError("Unexpected analysis ref")
    api = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"])
    deadline = time.monotonic() + 300
    while True:
        analyses = final_analyses(api.pages("analyses", {"ref": ref}), sha, ref)
        if analyses is not None:
            break
        if time.monotonic() >= deadline:
            raise ValueError("All final-head CodeQL analyses were not published in time")
        print("Waiting for all exact-head CodeQL analyses to be published.", flush=True)
        time.sleep(10)
    for analysis in analyses:
        sarif = api.get(f"analyses/{analysis['id']}", {}, "application/sarif+json")
        if not isinstance(sarif, dict):
            raise ValueError("Full SARIF results unavailable")
        require_clean_sarif(sarif)
    alerts = api.pages("alerts", {"ref": "refs/heads/main", "state": "open"})
    for alert in alerts:
        instances = api.pages(f"alerts/{alert['number']}/instances", {"ref": ref})
        require_fixed_instance(instances, sha, ref)
    print(f"All full final-head analyses are clean; {len(alerts)} main alerts reconciled.")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, TypeError, OSError, TimeoutError) as error:
        print(f"Security inventory failed: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
