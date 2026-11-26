#!/usr/bin/env bash
# Run the tests of this repo without installing anything.
#
# Usage: scripts/verify.sh
#
# Every hook suite runs on a copy of hooks/ in a temporary folder. Nothing in
# ~/.claude changes. The expected test counts are the EXPECT_ lines of
# scripts/install_hooks.sh, the same numbers that the installer checks.
#
# Suites:
#   hooks-A, hooks-B, hooks-SG   the hook suites (bash, python3)
#   scripts                      python3 -m unittest in scripts/tests
#   oturum-py                    python3 -m unittest in local-mods/oturum/bin
#   sade-lint                    the linter self test
#   rule-check                   the answer format self test (scripts/rule_check.py)
#   mod-usage-feed, mod-oturum   claude plugin test. Skipped when there is no claude CLI.
#
# The installer runs more variants: a fallback PATH without git and python3, and
# /bin/bash 3.2 on macOS. This script does not.
#
# Output: one line per suite ("<suite>: ok <count>", "FAILED" or "skipped"),
# then "verify: <n> ok, <n> failed, <n> skipped". Exit 1 when a suite failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

OK=0
FAILED=0
SKIPPED=0

expect() {
  sed -n "s/^$1=\([0-9][0-9]*\).*/\1/p" "${REPO_DIR}/scripts/install_hooks.sh" | head -n 1
}

# report <suite> <ok|failed|skipped> <detail> [log]
report() {
  case "$2" in
    ok) OK=$((OK + 1)); echo "$1: ok $3" ;;
    skipped) SKIPPED=$((SKIPPED + 1)); echo "$1: skipped ($3)" ;;
    *)
      FAILED=$((FAILED + 1))
      echo "$1: FAILED ($3)"
      if [[ -n "${4-}" && -f "$4" ]]; then tail -n 40 "$4" | sed 's/^/    /'; fi
      ;;
  esac
}

# hook_suite <label> <expected> <command ...>: the suite prints "<label>: N pass, M fail".
hook_suite() {
  local label="$1" expected="$2" log result rc=0
  shift 2
  log="${WORK}/${label}.log"
  "$@" > "${log}" 2>&1 || rc=$?
  result="$(grep -E "^${label}: [0-9]+ pass, [0-9]+ fail\$" "${log}" | tail -n 1 || true)"
  if [[ "${rc}" -eq 0 && "${result}" == "${label}: ${expected} pass, 0 fail" ]]; then
    report "${label}" ok "${expected}/${expected}"
  else
    report "${label}" failed "exit code ${rc}, expected ${expected} pass and 0 fail, got: ${result:-no result line}" "${log}"
  fi
}

# unittest_suite <label> <expected or -> <dir>: python3 -m unittest discover in dir.
unittest_suite() {
  local label="$1" expected="$2" dir="$3" log rc=0 count
  log="${WORK}/${label}.log"
  (cd "${dir}" && python3 -m unittest discover -s . -p 'test_*.py') > "${log}" 2>&1 || rc=$?
  count="$(sed -n 's/^Ran \([0-9][0-9]*\) tests* in .*/\1/p' "${log}" | tail -n 1)"
  if [[ "${rc}" -ne 0 || -z "${count}" ]] || { [[ "${expected}" != "-" ]] && [[ "${count}" != "${expected}" ]]; }; then
    report "${label}" failed "exit code ${rc}, ran ${count:-0} tests, expected ${expected}" "${log}"
  else
    report "${label}" ok "${count} tests"
  fi
}

# self_suite <label> <command ...>: exit code 0 is a pass.
self_suite() {
  local label="$1" log rc=0
  shift
  log="${WORK}/${label}.log"
  "$@" > "${log}" 2>&1 || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    report "${label}" ok "$(tail -n 1 "${log}")"
  else
    report "${label}" failed "exit code ${rc}" "${log}"
  fi
}

cp -R "${REPO_DIR}/hooks" "${WORK}/hooks"
hook_suite hooks-A "$(expect EXPECT_A)" bash "${WORK}/hooks/tests/run-tests.sh" "${WORK}/hooks" hooks-A
hook_suite hooks-B "$(expect EXPECT_B)" bash "${WORK}/hooks/tests/run-ul-tests.sh" "${WORK}/hooks" hooks-B
hook_suite hooks-SG "$(expect EXPECT_SG)" python3 "${WORK}/hooks/tests/run-sg-tests.py" "${WORK}/hooks" hooks-SG

unittest_suite scripts - "${REPO_DIR}/scripts/tests"
unittest_suite oturum-py "$(expect EXPECT_SESSIONS_PY)" "${REPO_DIR}/local-mods/oturum/bin"
self_suite sade-lint python3 "${REPO_DIR}/skills/sade-teknik-turkce/scripts/sade-lint.py" --selftest
self_suite rule-check python3 "${REPO_DIR}/scripts/rule_check.py" --selftest

for mod in usage-feed oturum; do
  if [[ "${mod}" == usage-feed ]]; then want="$(expect EXPECT_MOD)"; else want="$(expect EXPECT_MOD_OTURUM)"; fi
  if ! command -v claude > /dev/null 2>&1; then
    report "mod-${mod}" skipped "no claude CLI on PATH"
    continue
  fi
  log="${WORK}/mod-${mod}.log"
  rc=0
  (cd "${REPO_DIR}/local-mods/${mod}" && claude plugin test .) > "${log}" 2>&1 || rc=$?
  if [[ "${rc}" -eq 0 ]] && grep -q -E "^ *${want} pass\$" "${log}" && grep -q -E '^ *0 fail$' "${log}"; then
    report "mod-${mod}" ok "${want}/${want}"
  else
    report "mod-${mod}" failed "exit code ${rc}, expected ${want} pass and 0 fail" "${log}"
  fi
done

echo "verify: ${OK} ok, ${FAILED} failed, ${SKIPPED} skipped"
[[ "${FAILED}" -eq 0 ]]
