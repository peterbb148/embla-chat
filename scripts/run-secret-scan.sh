#!/bin/bash
# Required policy: repository files and inline comments cannot suppress findings.
set -euo pipefail
scanner="$1"
repository="$2"
# This Gitleaks version always loads source/.gitleaksignore, even with an explicit path.
if [[ -e "$repository/.gitleaksignore" || -L "$repository/.gitleaksignore" ]]; then
  echo 'Repository fingerprint ignores are not permitted by the required secret policy.' >&2
  exit 1
fi
policy=$(mktemp -d)
trap 'rm -rf "$policy"' EXIT
cat > "$policy/config.toml" <<'POLICY'
title = "Required Embla secret scan"
[extend]
useDefault = true
POLICY
: > "$policy/.gitleaksignore"
"$scanner" git --config "$policy/config.toml" \
  --gitleaks-ignore-path "$policy/.gitleaksignore" --ignore-gitleaks-allow \
  --baseline-path '' --redact=100 --no-banner --exit-code=1 \
  --log-opts='--all -m --text --no-ext-diff --no-textconv' "$repository"
