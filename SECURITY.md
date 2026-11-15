# Security

## Reporting a vulnerability

Please [report vulnerabilities privately](https://github.com/peterbb148/embla-chat/security/advisories/new)
rather than posting exploit details, credentials or private chat content in a public issue.
The repository owner coordinates assessment and fixes. Response and remediation times are
not guaranteed. Security maintenance targets the current `main` branch; there are no
separately maintained release branches.

## Merge policy

Required build and security checks apply to internal and external contributions. Known
vulnerabilities at every severity must be fixed before merging; advisory allowlists,
warning-only audits and ignored failing scans are not permitted. Passing scanners mean no
findings detected by those checks, not proof that unknown vulnerabilities cannot exist.
External PRs also require @peterbb148's approval. Internal PRs retain final-commit Copilot
review, resolution/re-review of findings and passing checks before a guarded merge.

See [repository security](docs/repository-security.md) for the enforced GitHub settings,
scanner coverage, validation evidence and limitations. No security check authorizes access
to personal iCloud data or broadens the application's folder permissions.

## Handling sensitive material

Never commit credentials, signing certificates/profiles, personal chats, iCloud bookmarks
or model weights. Use local signing configuration and keep test examples clearly synthetic.
Secret scanning and push protection complement a required history scan. If a real secret is
exposed, revoke/rotate it first; deleting text in a later commit does not revoke a credential.
