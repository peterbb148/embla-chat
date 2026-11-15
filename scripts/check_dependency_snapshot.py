"""Reject incomplete GitHub dependency comparisons after the advisory audit finishes."""

import base64
import json
import os
import re
import subprocess
import sys
from email.parser import Parser

BASE = "240ad61445b4d7f9c39a354ec6661d036cc315a8"
REQUIRED_MANIFESTS = {
    "Package.resolved",
    "EmblaChat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
}


def validate_page(warning_header: str, changes: object) -> set[str]:
    """Reject warnings and malformed pages; return manifests present in proposed head."""
    if warning_header:
        warning = base64.b64decode(warning_header, validate=True).decode("utf-8").strip()
        if warning:
            raise ValueError("Dependency snapshot warnings remain; completeness is not established")
    if not isinstance(changes, list):
        raise ValueError("Dependency comparison must be an array")
    manifests = set()
    for change in changes:
        if not isinstance(change, dict) or not isinstance(change.get("manifest"), str):
            raise ValueError("Malformed dependency comparison entry")
        if not isinstance(change.get("vulnerabilities"), list):
            raise ValueError("Missing dependency advisory data")
        if change.get("change_type") == "added":
            if change["vulnerabilities"]:
                raise ValueError("Vulnerabilities remain in the proposed dependency snapshot")
            manifests.add(change["manifest"])
    return manifests


def require_manifests(manifests: set[str]) -> None:
    """Require both application lockfiles rather than accepting an empty comparison."""
    if not REQUIRED_MANIFESTS.issubset(manifests):
        raise ValueError("Dependency comparison is missing required Swift lockfile snapshots")


def main() -> None:
    """Check every API page using the exact revision audited by the preceding action."""
    repository = os.environ["GITHUB_REPOSITORY"]
    head = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository identifier")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("Expected an exact head commit")
    manifests = set()
    page = 1
    while True:
        endpoint = f"repos/{repository}/dependency-graph/compare/{BASE}...{head}"
        response = subprocess.run(
            ["gh", "api", endpoint, "--method", "GET", "--include",
             "-f", "per_page=100", "-f", f"page={page}",
             "-H", "Accept: application/vnd.github+json",
             "-H", "X-GitHub-Api-Version: 2022-11-28"],
            capture_output=True, text=True, check=False,
        )
        if response.returncode != 0:
            raise ValueError("GitHub CLI could not obtain dependency snapshot evidence")
        header_block, separator, body = response.stdout.partition("\n\n")
        if not separator or not header_block.startswith("HTTP/"):
            raise ValueError("GitHub CLI returned an invalid dependency response")
        headers = Parser().parsestr(header_block.split("\n", 1)[1])
        changes = json.loads(body)
        manifests.update(validate_page(
            headers.get("x-github-dependency-graph-snapshot-warnings", ""), changes
        ))
        if len(changes) < 100:
            break
        page += 1
    require_manifests(manifests)
    print("Dependency snapshot completeness verified; no snapshot warnings remain.")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, TimeoutError) as error:
        # Do not print request headers or any credential-bearing request representation.
        message = f"Dependency completeness check failed: {type(error).__name__}: {error}"
        print(message, file=sys.stderr)
        sys.exit(1)
