"""Publish a required exact-head secret-alert attestation using the maintainer's gh login."""

import argparse
import json
import re
import subprocess
import sys

REPOSITORY = "peterbb148/embla-chat"
OWNER = "peterbb148"
CONTEXT = "GitHub secret alerts"


def gh(*arguments: str) -> str:
    """Run GitHub CLI without exposing API bodies, credentials or secret values on failure."""
    result = subprocess.run(
        ["gh", *arguments], capture_output=True, text=True, check=False, timeout=60
    )
    if result.returncode:
        raise ValueError("GitHub CLI could not obtain or publish required security evidence")
    return result.stdout


def pull_request(number: int, sha: str) -> dict:
    """Require an open main-target PR at the exact reviewed head."""
    request = json.loads(gh("api", f"repos/{REPOSITORY}/pulls/{number}"))
    if (request.get("state") != "open" or request.get("base", {}).get("ref") != "main"
            or request.get("base", {}).get("repo", {}).get("full_name") != REPOSITORY
            or request.get("head", {}).get("sha") != sha):
        raise ValueError("PR is not open against this main branch at the requested head")
    return request


def require_owner_approval(request: dict, number: int, sha: str) -> None:
    """External contributions need Peter's latest review approving the exact head."""
    if request.get("user", {}).get("login", "").casefold() == OWNER:
        return
    pages = json.loads(gh(
        "api", "--paginate", "--slurp", f"repos/{REPOSITORY}/pulls/{number}/reviews"
    ))
    reviews = [review for page in pages for review in page
               if review.get("user", {}).get("login", "").casefold() == OWNER
               and review.get("state") in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}]
    latest = max(reviews, key=lambda item: item["id"]) if reviews else None
    if not latest or latest.get("state") != "APPROVED" or latest.get("commit_id") != sha:
        raise ValueError("External PR requires Peter's approval of the final head")


def publish(sha: str, state: str, description: str) -> None:
    """Publish the required status for this commit; this never merges a PR."""
    gh("api", f"repos/{REPOSITORY}/statuses/{sha}", "--method", "POST",
       "-f", f"state={state}", "-f", f"context={CONTEXT}",
       "-f", f"description={description}",
       "-f", f"target_url=https://github.com/{REPOSITORY}/security/secret-scanning")


def attest(number: int, sha: str) -> None:
    """Fail closed on open alerts, unavailable inventory, missing approval or head changes."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or number < 1:
        raise ValueError("An exact PR number and 40-character head SHA are required")
    login = json.loads(gh("api", "user")).get("login", "").casefold()
    if login != OWNER:
        raise ValueError("Run this trusted tool using Peter's existing maintainer gh login")
    request = pull_request(number, sha)
    publish(sha, "pending", "Maintainer is checking native GitHub secret alerts")
    try:
        require_owner_approval(request, number, sha)
        # Only counts leave gh. Native alert payloads can contain actual secret values.
        counts = gh(
            "api", "--paginate", f"repos/{REPOSITORY}/secret-scanning/alerts?state=open&per_page=100",
            "--jq", 'if type=="array" then length else error("Invalid secret inventory") end',
        ).splitlines()
        if not counts or any(not count.isdecimal() for count in counts):
            raise ValueError("Native secret-alert inventory is unavailable or malformed")
        if sum(int(count) for count in counts):
            raise ValueError("Open native GitHub secret alerts must be resolved before merge")
        # A change during the query invalidates the attestation, including external approval.
        require_owner_approval(pull_request(number, sha), number, sha)
        publish(sha, "success", "Maintainer verified zero open native GitHub secret alerts")
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
        publish(sha, "failure", "Secret-alert evidence or final-head approval is incomplete")
        raise
    print(f"PR #{number} at {sha}: required native secret-alert check passed.")


def main() -> None:
    """Accept explicit final-head arguments; credentials remain inside GitHub CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--sha", required=True)
    arguments = parser.parse_args()
    attest(arguments.pr, arguments.sha)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Secret-alert check failed: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
