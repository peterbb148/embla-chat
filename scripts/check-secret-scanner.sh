#!/bin/bash
# Exercise the required scanner against disposable synthetic history, never real secrets.
set -euo pipefail
scanner="$1"
policy_runner="$(cd "$(dirname "$0")" && pwd)/run-secret-scan.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

git -C "$fixture" init -q -b main
git -C "$fixture" config user.name 'Security fixture'
git -C "$fixture" config user.email 'fixture@example.invalid'
printf 'Synthetic detector test\n' > "$fixture/README.md"
git -C "$fixture" add README.md
git -C "$fixture" commit -qm clean
bash "$policy_runner" "$scanner" "$fixture"

# Construct a recognizably shaped but deliberately fake token only in temporary data.
suffix=$(python3 - <<'PYTHON'
import random
import string

chars = list(string.ascii_lowercase + string.digits)
random.Random(48).shuffle(chars)
print("".join(chars))
PYTHON
)
synthetic="gh"'p_'"$suffix"
printf 'token = "%s"\n' "$synthetic" > "$fixture/fixture.txt"
git -C "$fixture" add fixture.txt
git -C "$fixture" commit -qm 'synthetic detector fixture'
git -C "$fixture" rm -q fixture.txt
git -C "$fixture" commit -qm 'remove fixture from current tree'
set +e
bash "$policy_runner" "$scanner" "$fixture" > "$fixture/scan.log" 2>&1
scan_status=$?
set -e
if [[ "$scan_status" != 1 ]]; then
  echo 'Secret scanner failed to reject synthetic historical credential.' >&2
  exit 1
fi
if grep -Fq "$synthetic" "$fixture/scan.log"; then
  echo 'Secret scanner exposed synthetic credential despite redaction.' >&2
  exit 1
fi
echo 'Secret scanner accepts clean history and rejects redacted synthetic historical secrets.'

# A merge-only introduction is absent from ordinary git-log diffs; exercise that case.
merge_fixture="$fixture/merge-case"
mkdir "$merge_fixture"
git -C "$merge_fixture" init -q -b main
git -C "$merge_fixture" config user.name 'Security fixture'
git -C "$merge_fixture" config user.email 'fixture@example.invalid'
printf 'base\n' > "$merge_fixture/conflict.txt"
git -C "$merge_fixture" add conflict.txt
git -C "$merge_fixture" commit -qm base
base_commit=$(git -C "$merge_fixture" rev-parse HEAD)
git -C "$merge_fixture" switch -qc left
printf 'left\n' > "$merge_fixture/conflict.txt"
git -C "$merge_fixture" commit -qam left
git -C "$merge_fixture" switch -qc right "$base_commit"
printf 'right\n' > "$merge_fixture/conflict.txt"
git -C "$merge_fixture" commit -qam right
if git -C "$merge_fixture" merge left > /dev/null 2>&1; then
  echo 'Synthetic merge fixture unexpectedly had no conflict.' >&2
  exit 1
fi
printf 'token = "%s"\n' "$synthetic" > "$merge_fixture/conflict.txt"
git -C "$merge_fixture" add conflict.txt
git -C "$merge_fixture" commit -qm 'synthetic merge resolution'
"$scanner" git --redact=100 --no-banner --log-opts="--all" "$merge_fixture" \
  > "$fixture/ordinary-merge-scan.log" 2>&1
set +e
bash "$policy_runner" "$scanner" "$merge_fixture" \
  > "$fixture/merge-scan.log" 2>&1
merge_status=$?
set -e
if [[ "$merge_status" != 1 ]]; then
  echo 'Secret scanner failed to reject a synthetic merge-only credential.' >&2
  exit 1
fi
if grep -Fq "$synthetic" "$fixture/merge-scan.log"; then
  echo 'Merge scan exposed synthetic credential despite redaction.' >&2
  exit 1
fi
echo 'Per-parent merge diffs reject a synthetic credential missed by ordinary history diffs.'

# Each repository-controlled suppression passes ordinary Gitleaks but must fail policy.
for suppression in inline config fingerprint; do
  sample="$fixture/$suppression"
  mkdir "$sample"
  git -C "$sample" init -q -b main
  git -C "$sample" config user.name 'Security fixture'
  git -C "$sample" config user.email 'fixture@example.invalid'
  printf 'token = "%s"' "$synthetic" > "$sample/fixture.txt"
  if [[ "$suppression" == inline ]]; then
    printf ' # gitleaks:allow' >> "$sample/fixture.txt"
  fi
  printf '\n' >> "$sample/fixture.txt"
  git -C "$sample" add fixture.txt
  git -C "$sample" commit -qm 'synthetic suppression fixture'
  if [[ "$suppression" == config ]]; then
    cat > "$sample/.gitleaks.toml" <<'CONFIG'
[extend]
useDefault = true
[allowlist]
description = "Synthetic suppression fixture"
paths = ["fixture.txt"]
CONFIG
    git -C "$sample" add .gitleaks.toml
    git -C "$sample" commit -qm 'synthetic configuration suppression'
  elif [[ "$suppression" == fingerprint ]]; then
    finding_commit=$(git -C "$sample" rev-parse HEAD)
    printf '%s:fixture.txt:github-pat:1\n' "$finding_commit" > "$sample/.gitleaksignore"
    git -C "$sample" add .gitleaksignore
    git -C "$sample" commit -qm 'synthetic fingerprint suppression'
  fi
  (cd "$sample"; "$scanner" git --redact=100 --no-banner .) \
    > "$fixture/$suppression-ordinary.log" 2>&1
  set +e
  bash "$policy_runner" "$scanner" "$sample" > "$fixture/$suppression-strict.log" 2>&1
  strict_status=$?
  set -e
  if [[ "$strict_status" != 1 ]]; then
    echo "Required secret policy accepted a $suppression suppression." >&2
    exit 1
  fi
  if grep -Fq "$synthetic" "$fixture/$suppression-strict.log"; then
    echo 'Required policy exposed a synthetic credential despite redaction.' >&2
    exit 1
  fi
done
echo 'Repository config, fingerprint ignores and inline allow comments cannot bypass policy.'
