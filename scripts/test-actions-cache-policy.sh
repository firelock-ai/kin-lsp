#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Firelock, LLC

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="${root}/scripts/check-actions-cache-policy.sh"
fixtures="$(mktemp -d)"
trap 'rm -rf "${fixtures}"' EXIT

make_case() {
  local name="$1"
  local case_root="${fixtures}/${name}"
  local workflow_root="${case_root}/.github/workflows"
  local action_root="${case_root}/.github/actions"
  mkdir -p "${workflow_root}" "${action_root}"
  cp "${root}"/.github/workflows/*.yml "${workflow_root}/"
  cp -R "${root}/.github/actions/." "${action_root}/"
  printf '%s\n' "${workflow_root}"
}

expect_rejection() {
  local name="$1"
  local workflow_root="$2"
  local expected="$3"
  local output
  if output="$("${check}" "${workflow_root}" 2>&1)"; then
    echo "FAIL: ${name} falsifier was accepted" >&2
    exit 1
  fi
  if ! grep -Fq "${expected}" <<<"${output}"; then
    echo "FAIL: ${name} failed for the wrong reason" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  echo "OK: ${name} rejected"
}

"${check}" "${root}/.github/workflows"

case_root="$(make_case target-output)"
perl -0pi -e 's#(~/.cargo/git\n)#$1            target\n#' "${case_root}/ci.yml"
expect_rejection target-output "${case_root}" "target output is forbidden"

case_root="$(make_case dynamic-key)"
perl -0pi -e 's/cargo-sources-v1/cargo-sources-\$\{\{ github.sha \}\}/' "${case_root}/ci.yml"
expect_rejection dynamic-key "${case_root}" "cache keys must not expand"

case_root="$(make_case non-main-save)"
perl -0pi -e "s/if: github.ref == 'refs\/heads\/main' && steps.cargo-sources.outputs.cache-hit != 'true'/if: always()/" "${case_root}/cache-seed.yml"
expect_rejection non-main-save "${case_root}" "cache save must be restricted to a main cache miss"

case_root="$(make_case writer-trigger)"
perl -0pi -e 's/(on:\n)/$1  pull_request:\n    branches: [main]\n/' "${case_root}/cache-seed.yml"
expect_rejection writer-trigger "${case_root}" "cache writer workflow must trigger only on pushes to main"

case_root="$(make_case monolithic-action)"
perl -0pi -e 's#actions/cache/restore\@v4#actions/cache\@v4#' "${case_root}/ci.yml"
expect_rejection monolithic-action "${case_root}" "use actions/cache/restore@v4 or actions/cache/save@v4"

case_root="$(make_case version-drift)"
perl -0pi -e 's#actions/cache/restore\@v4#actions/cache/restore\@v3#' "${case_root}/ci.yml"
expect_rejection version-drift "${case_root}" "use actions/cache/restore@v4 or actions/cache/save@v4"

case_root="$(make_case conditional-restore)"
perl -0pi -e "s/(      - name: Restore cargo sources\n)/\$1        if: github.event_name == 'pull_request'\n/" "${case_root}/ci.yml"
expect_rejection conditional-restore "${case_root}" "cache restore must run on every workflow ref"

case_root="$(make_case conditional-job)"
perl -0pi -e "s/(  check:\n)/\$1    if: github.event_name == 'workflow_dispatch'\n/" "${case_root}/ci.yml"
expect_rejection conditional-job "${case_root}" "check job must run unconditionally"

case_root="$(make_case narrowed-matrix)"
perl -0pi -e 's/os: \[ubuntu-latest, macos-latest\]/os: [ubuntu-latest]/' "${case_root}/ci.yml"
expect_rejection narrowed-matrix "${case_root}" "exact Linux/macOS matrix"

case_root="$(make_case narrowed-trigger)"
perl -0pi -e 's/  merge_group:\n//' "${case_root}/ci.yml"
expect_rejection narrowed-trigger "${case_root}" "must run exactly on pull requests to main and merge groups"

case_root="$(make_case late-restore)"
perl -0pi -e 's#(      - name: Restore cargo sources\n)#      - name: Cargo work before restore\n        run: cargo fetch\n\n$1#' "${case_root}/ci.yml"
expect_rejection late-restore "${case_root}" "cache restore must precede every run step"

case_root="$(make_case late-save)"
perl -0pi -e 's#\z#\n      - name: Later step\n        run: echo later\n#' "${case_root}/cache-seed.yml"
expect_rejection late-save "${case_root}" "cache save must be the last declared job step"

case_root="$(make_case wrong-save-key)"
perl -0pi -e 's/steps\.cargo-sources\.outputs\.cache-primary-key/runner.os }}-cargo-sources-wrong/' "${case_root}/cache-seed.yml"
expect_rejection wrong-save-key "${case_root}" "save key must come from the restore primary key"

case_root="$(make_case duplicate-condition-key)"
perl -0pi -e "s/(      - name: Restore cargo sources\n)/\$1        if: true\n        if: false\n/" "${case_root}/ci.yml"
expect_rejection duplicate-condition-key "${case_root}" "duplicate YAML mapping key"

case_root="$(make_case composite-cache-action)"
perl -0pi -e 's!\z!\n    - name: Hidden target cache\n      uses: Actions/cache\@v4\n      with:\n        path: target\n        key: hidden-target\n!' "${case_root}/../actions/rust-toolchain/action.yml"
expect_rejection composite-cache-action "${case_root}" "repo-local composite actions must not invoke actions/cache"

case_root="$(make_case unexpected-workflow)"
cp "${case_root}/ci.yml" "${case_root}/shadow.yml"
expect_rejection unexpected-workflow "${case_root}" "shadow.yml: unexpected cache action"

case_root="$(make_case reusable-pin-drift)"
perl -0pi -e 's/cargo-registry-release\.yml\@v0\.1\.32/cargo-registry-release.yml\@v0.1.99/' "${case_root}/registry-publish.yml"
expect_rejection reusable-pin-drift "${case_root}" "until its external cache behavior is re-audited"

echo "OK: all Actions cache policy falsifiers were rejected."
