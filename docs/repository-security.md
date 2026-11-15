# Repository security and open-source readiness (#48)

## Ownership and licensing

Original project code is MIT licensed. Upstream runtime/model notices remain in
`third-party`; downloaded weights are separate. `.github/CODEOWNERS` assigns all paths,
including workflows and ownership policy, to @peterbb148. [Contributing](../CONTRIBUTING.md)
and [private security reporting](../SECURITY.md) describe the public contribution process.
The README is a durable landing page; changing validation results belong in dedicated docs.

## Required checks and security coverage

The existing `ios` check builds the unsigned device app and runs package/UI tests.
`Dependency audit` uses GitHub dependency review at severity **low**, covering runtime,
development and unknown scopes without advisory exceptions or warning-only mode. Its base
is the repository's initial README-only commit `240ad61445b4d7f9c39a354ec6661d036cc315a8`,
so it reviews the full proposed dependency graph rather than only newly changed packages.
This also permits a PR to fix a vulnerable default-branch dependency instead of deadlocking
on an alert that can close only after the fix merges.

`Secret scan` uses a checksummed, pinned Gitleaks binary against full fetched Git history,
with findings redacted. A disposable synthetic-history smoke check proves a clean history
passes and a credential removed from the latest tree is still rejected without exposing
its value. No real credential is used in the fixture.

GitHub CodeQL default setup analyzes **Swift and GitHub Actions** with extended queries.
Its generated workflows are managed by GitHub; the configuration and actual main/PR scan
results must be verified through the API, not inferred from a settings request succeeding.
Dependabot alerts/security updates, secret scanning, push protection and private
vulnerability reporting are enabled. Weekly version-update configuration covers Swift and
GitHub Actions. Updating the pinned runtime must still respect functional compatibility;
there is no automatic dependency merge.

GitHub's dependency graph currently represents the pinned Swift Git revision as `>= 0`.
An advisory inventory is therefore not a complete audit of every line of an upstream Git
commit. Both lockfiles retain the exact reviewed runtime pin. Scanners report detectable
findings; zero reported findings is not a guarantee against unknown vulnerabilities.

## Protection and approvals

Main requires a PR, resolved conversations, current required build/security checks and
CodeQL merge protection for all alert severities. CI/security enforcement must include
internal owner-authored PRs; no bypass of those requirements is intended.

External contributions require the code owner's approval. Peter and the coding agent are
internal: an internal owner-authored PR uses final-head Copilot review, fixes/re-review,
passing checks and a SHA-pinned merge. A separate owner-review rule can permit the owner
through its PR-only bypass to avoid self-approval deadlock. That exception must apply only
to the review rule, never build/security rules. Before merging an external PR, verify
Peter's approval of the final commit rather than using the internal exception. GitHub
cannot restrict an owner-only review bypass by PR author, and repository owners can alter
settings; the documented owner workflow remains part of this trust boundary.

## Validation record

Initial inventory found no main protection or project license. Secret scanning and push
protection were already on; Dependabot alerts were disabled, which was an unavailable
inventory rather than evidence of zero findings. After enabling alerts, the first actual
Dependabot inventory returned zero open alerts. Secret-scanning inventory also returned
zero open alerts without printing secret values.

Enforcement settings, negative dependency-gate results, final scan inventories and final-head
review/build evidence are recorded here when verified. Temporary deliberately vulnerable
manifest fixtures are never executed and must be removed before merge. A failed, skipped
or unavailable required check is not a passing result. Post-merge main scans and alert
inventories must be checked again after asynchronous GitHub analysis completes.
