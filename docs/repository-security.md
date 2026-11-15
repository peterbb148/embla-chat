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
A separate fail-closed guard rejects remaining snapshot warnings, malformed/empty data and
missing application lockfile snapshots after the action retries. That same completed response
also rejects any remaining vulnerability, so a newly complete graph cannot escape the earlier
advisory check. The intentionally README-only
base has an empty graph, not an ignored unavailable-snapshot warning. This also permits a PR
to fix a vulnerable default-branch dependency instead of deadlocking
on an alert that can close only after the fix merges.

`Secret scan` uses a checksummed, pinned Gitleaks binary against full fetched Git history,
with per-parent merge diffs (`--all -m`) and findings redacted. A disposable synthetic-history
smoke check proves a clean history
passes and a credential removed from the latest tree is still rejected without exposing
its value. No real credential is used in the fixture.

The explicit CodeQL workflow analyzes **Swift, GitHub Actions and the security helpers’ Python** with extended queries.
Diff-informed PR queries are explicitly disabled (`CODEQL_ACTION_DIFF_INFORMED_QUERIES=false`)
so full results include unchanged code. Swift extraction builds the actual iPhone application with the locked Xcode toolchain;
Actions uses its supported buildless mode. All three jobs are required separately, as well as
native all-severity CodeQL merge protection. Required `Security inventory` reads all three full
published final-head SARIF results, rejects every finding (including unchanged files), requires
successful exact-head analyses, and reconciles open main alerts against exact-head fixed
instances. Missing/failed evidence blocks the check. Actual main/PR results are verified, not
inferred from a settings request succeeding.
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

The deliberate dependency fixture on draft PR #49 was rejected by required `Dependency
audit` in [run 43761897906](https://github.com/peterbb148/embla-chat/actions/runs/43761897906).
It reported two high and two moderate advisories for the non-executed lodash 4.17.20
manifest. That manifest was then removed. The initial secret smoke fixture was ignored by
the scanner's built-in alphabet stopword; a shuffled synthetic value now exercises the
actual detector. Local smoke checks pass, including redaction and historical detection;
the full local history scan reports zero findings across 78 commits at this checkpoint.

Verified API settings: main integrity/security ruleset **27331567** has no bypass actors,
requires `ios`, `Dependency audit`, `Secret scan`, `CodeQL (swift)`, `CodeQL (actions)`, `CodeQL (python)` and
`Security inventory` from GitHub Actions (app 15368), requires
the branch to be up to date, blocks deletion/force-push and requires resolved conversations.
Its CodeQL thresholds are both `all`, including low-severity security findings. Separate
owner-review ruleset **27331553** requires one code-owner approval with stale approvals
dismissed; its sole admin-role bypass is PR-only and does not bypass integrity/security.

Default CodeQL setup was rejected as insufficient: its overall setup run succeeded after
autobuild failed and silently reduced coverage to Actions. Swift's failed analysis is not
a pass. The checked-in manual build replaces that configuration; a temporary, genuine
scan of the exact existing main seeds the required baseline and is removed before merge.

Copilot review regressions additionally cover incomplete snapshot data after retry timeout,
including rejecting unavailable-base warnings rather than treating them as intentional
emptiness. Seven standard-library tests pass, and the guard also succeeds against the exact
live PR comparison. A real disposable merge fixture proves ordinary history diffs miss a
merge-only synthetic credential while `-m` rejects it with redacted output. The full local
merge-aware history scan reports zero findings. These are detector/metadata fixtures, not
real credentials, model output or personal-data access.

The whole-result inventory is separate from native PR-diff protection: result ingestion alone
does not mean zero findings. Five regression cases cover missing language/head evidence,
failed zero-result extraction, findings in unchanged files, unavailable full SARIF and stale/
unfixed main alert instances. A baseline finding may be fixed by a PR only when the complete
final-head result is clean and GitHub publishes its exact-head fixed instance; absence of
that evidence is a failure rather than a reason to ignore the baseline.

The initial main compile/extraction baseline completed in [run 43762455410](https://github.com/peterbb148/embla-chat/actions/runs/43762455410).
Both existing languages published empty result files with empty error/warning metadata at
`4ea2e7bd8814fd4ca7082e757ca5b3082337afc2`; the inventory helper read those files and zero open main alerts.
Later review exposed the default PR query filtering: those empty files are setup evidence,
not proof of whole-codebase cleanliness. Acceptance requires the explicit full-query final
head and post-merge main scans; the initial result is not relabelled as that proof. The one-time bootstrap workflow was then removed.
Python is additionally required on the final head because this change introduces Python
security helpers; the earlier main had no Python source to analyze.
