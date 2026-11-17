#!/usr/bin/env python3
"""Run the explicit quick-action UI fixture on one existing simulator, restoring its data."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def main() -> None:
    """Install an already-built test app, seed synthetic files, test and restore originals."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Existing simulator UDID; never creates one")
    parser.add_argument("--derived-data", required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    bundle = "dk.peterbb148.embla-chat"
    derived = args.derived_data.resolve()

    def sim(*arguments: str, check: bool = True) -> str:
        """Run simctl with structured arguments and return its output."""
        result = subprocess.run(
            ["xcrun", "simctl", *arguments], check=check, capture_output=True, text=True
        )
        return result.stdout.strip()

    def container() -> Path:
        """Look up the current container; Xcode installation can relocate it during tests."""
        return Path(sim("get_app_container", args.device, bundle, "data"))

    sim("install", args.device, str(derived / "Build/Products/Debug-iphonesimulator/EmblaChatApp.app"))
    sim("terminate", args.device, bundle, check=False)
    root = container()
    archive = Path("Library/Application Support/EmblaChat/Conversation/active-chat.json")
    actions = Path("Documents/Actions/actions.json")
    originals = {path: (root / path).read_bytes() if (root / path).exists() else None
                 for path in [archive, actions]}
    evidence = Path(tempfile.mkdtemp(prefix="action-cloud-", dir=repo / "build"))
    os.chmod(evidence, 0o700)
    for index, data in enumerate(originals.values()):
        if data is not None:
            (evidence / f"original-{index}").write_bytes(data)

    config = json.loads((repo / "examples/actions.json").read_text())
    labels = ["Explain this", "Brainstorm ideas", "Plan my day",
              "Review a longer piece of text together", "Make a list", "Find the next step"]
    for index, label in enumerate(labels):
        config["actions"].append(dict(
            id=f"fixture-{index}", label=label, order=40 + index, enabled=True,
            type="prompt", prompt=f"Synthetic action {index}"))
    config["actions"].append(dict(
        id="instant-fixture", label="Send immediately", order=99, enabled=True,
        type="prompt", prompt="Explicit synthetic send", autoSend=True))
    snapshot = dict(
        formatVersion=1, conversationID=str(uuid.uuid4()), revision=str(uuid.uuid4()),
        messages=[dict(id=str(uuid.uuid4()), role=role, text=text, reasoning="", state="complete")
                  for role, text in [("user", "Quick-action UI fixture"),
                                     ("assistant", "Saved UI fixture — not a model response.")]],
        compaction=dict(summary="", summarizedMessageCount=0))
    value = dict(sequence=1, snapshot=snapshot, draft="Fixture draft to protect", history=[],
                 projects=[], cloudEnabled=False, cloudConsentVersion=2)
    try:
        for path, contents in [(archive, value), (actions, config)]:
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(contents))
        with (evidence / "test.log").open("w") as log:
            subprocess.run([
                "xcodebuild", "test-without-building", "-project", "EmblaChat.xcodeproj",
                "-scheme", "EmblaChat", "-destination", f"platform=iOS Simulator,id={args.device}",
                "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO",
                "-only-testing:EmblaChatUITests/LaunchTests/testQuickActionCloudFromExplicitFixture",
                "-resultBundlePath", str(evidence / "Cloud.xcresult"), "CODE_SIGNING_ALLOWED=NO"
            ], cwd=repo, check=True, stdout=log, stderr=subprocess.STDOUT)
        summary = json.loads(subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
            str(evidence / "Cloud.xcresult")], text=True))
        if summary["passedTests"] != 1 or summary["skippedTests"] != 0:
            raise RuntimeError("Fixture test did not execute and pass; inspect its result bundle.")
    finally:
        sim("terminate", args.device, bundle, check=False)
        restored = container()
        for path, data in originals.items():
            target = restored / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if data is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(data)
        print(f"Original chat and actions restored. Local evidence: {evidence}", flush=True)
    for index in range(len(originals)):
        (evidence / f"original-{index}").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
