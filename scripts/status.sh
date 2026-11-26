#!/usr/bin/env bash
# Show the state of the ai_agent_rules setup on one screen. Changes nothing.
#
# Usage:
#   scripts/status.sh              This machine.
#   scripts/status.sh --all        This machine and each machine in local/machines.md (SSH).
#   scripts/status.sh --porcelain  This machine as "key<TAB>value" lines. --all runs
#                                  this mode on the other machines.
# "./install.sh --status [--all]" runs this script.
#
# The rows come from the read-only checks: install.sh --check-rules,
# install_hooks.sh --check, install_subagents.sh --check, term_profile.py --check
# and local_info.sh --check. This script reads their exit codes and their
# "Result: NOT in sync (<n> items)" and "Warnings: <n>" lines.
# "./install.sh --check" shows the full report.
#
# Exit 0 when nothing needs a look, 1 when something does, 2 on a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
MACHINES_FILE="${REPO_DIR}/local/machines.md"
# Raise it when the porcelain keys change. An older remote repo then shows up.
FORMAT_VERSION=1
# Türkiye time is UTC+3 all year.
TR_OFFSET=10800

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# ---------------------------------------------------------------- porcelain

# Print "ok", the number of items out of sync, "differs" or "error" for one check.
result_of() {
  local rc="$1" output="$2" count
  if [[ "${rc}" -eq 0 ]]; then
    echo "ok"
    return
  fi
  if [[ "${rc}" -ne 1 ]]; then
    echo "error"
    return
  fi
  count="$(printf '%s\n' "${output}" | sed -n 's/^Result: NOT in sync (\([0-9][0-9]*\) items).*/\1/p' | tail -n 1)"
  echo "${count:-differs}"
}

# Print the version number in the path of a claude binary, or nothing. Same rule
# as claude_version_by_name in install_hooks.sh: follow the symlinks, then read
# the <n>.<n>.<n> after "claude-code/", "versions/" or "ccd-cli/". Nothing is started.
version_by_name() {
  local path="$1" target count=0
  while [[ -L "${path}" && "${count}" -lt 10 ]]; do
    target="$(readlink "${path}")" || break
    case "${target}" in
      /*) path="${target}" ;;
      *) path="$(dirname "${path}")/${target}" ;;
    esac
    count=$((count + 1))
  done
  (printf '%s\n' "${path}" | grep -o -E '/(claude-code|versions|ccd-cli)/[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 \
    | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+$') || true
}

# Print 0 when version $1 is the same as or newer than version $2 (<n>.<n>.<n>).
version_at_least() {
  local IFS=.
  local -a a b
  local k
  a=($1)
  b=($2)
  for k in 0 1 2; do
    if (( ${a[k]:-0} > ${b[k]:-0} )); then return 0; fi
    if (( ${a[k]:-0} < ${b[k]:-0} )); then return 1; fi
  done
  return 0
}

# Print "ccd-cli <version>" for the newest CLI that Claude Desktop installs for
# SSH sessions (~/.claude/remote/ccd-cli/<version>-<id>), or "none".
ccd_cli_version() {
  local file version best=""
  for file in "${HOME}/.claude/remote/ccd-cli"/*; do
    if [[ ! -f "${file}" || ! -x "${file}" ]]; then continue; fi
    version="$(version_by_name "${file}")"
    if [[ -n "${version}" ]] && { [[ -z "${best}" ]] || ! version_at_least "${best}" "${version}"; }; then
      best="${version}"
    fi
  done
  if [[ -n "${best}" ]]; then echo "ccd-cli ${best}"; else echo "none"; fi
}

# Print the version of the claude CLI, "unknown", or the ccd-cli version when
# there is no CLI. The CLI on PATH comes first. An SSH command often has a short
# PATH, so ~/.local/bin/claude comes second.
claude_cli_version() {
  local bin version
  bin="$(type -P claude 2>/dev/null || true)"
  if [[ -z "${bin}" && -x "${HOME}/.local/bin/claude" ]]; then
    bin="${HOME}/.local/bin/claude"
  fi
  if [[ -z "${bin}" ]]; then
    ccd_cli_version
    return
  fi
  version="$(version_by_name "${bin}")"
  if [[ -z "${version}" ]]; then
    version="$("${bin}" --version </dev/null 2>/dev/null | head -n 1 \
      | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')" || true
  fi
  echo "${version:-unknown}"
}

# Print the modification time of a path in seconds since 1970, or nothing.
mtime_of() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

# Print the time of the last install.sh run, or "-". install.sh makes one backup
# folder per run: ~/.claude/backups/ai_agent_rules-<date>-<id>.
last_install() {
  local claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}" dir time newest=0
  for dir in "${claude_dir}/backups"/ai_agent_rules-*; do
    if [[ ! -d "${dir}" ]]; then continue; fi
    time="$(mtime_of "${dir}")"
    if [[ "${time}" =~ ^[0-9]+$ && "${time}" -gt "${newest}" ]]; then
      newest="${time}"
    fi
  done
  if [[ "${newest}" -gt 0 ]]; then echo "${newest}"; else echo "-"; fi
}

# Print the number of lines of a text that match an extended regex.
count_lines() {
  printf '%s\n' "$2" | grep -c -E "$1" || true
}

porcelain() {
  local output rc counts ahead="-" behind="-" commit="-" changes="-"
  printf 'format\t%s\n' "${FORMAT_VERSION}"

  if git -C "${REPO_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    commit="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "-")"
    # GIT_OPTIONAL_LOCKS=0: "git status" does not write the index.
    changes="$(GIT_OPTIONAL_LOCKS=0 git -C "${REPO_DIR}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    # The upstream as this clone saw it at its last fetch. Nothing is fetched.
    counts="$(git -C "${REPO_DIR}" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null || true)"
    if [[ "${counts}" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
      ahead="${BASH_REMATCH[1]}"
      behind="${BASH_REMATCH[2]}"
    fi
  fi
  printf 'commit\t%s\n' "${commit}"
  printf 'changes\t%s\n' "${changes}"
  printf 'ahead\t%s\n' "${ahead}"
  printf 'behind\t%s\n' "${behind}"
  printf 'claude\t%s\n' "$(claude_cli_version)"
  printf 'installed\t%s\n' "$(last_install)"

  rc=0
  output="$("${REPO_DIR}/install.sh" --check-rules 2>&1)" || rc=$?
  printf 'rules\t%s\n' "$(result_of "${rc}" "${output}")"

  rc=0
  output="$("${SCRIPT_DIR}/install_hooks.sh" --check 2>&1)" || rc=$?
  printf 'hooks\t%s\n' "$(result_of "${rc}" "${output}")"
  counts="$(printf '%s\n' "${output}" | sed -n 's/^Warnings: \([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  printf 'hooks_warnings\t%s\n' "${counts:-0}"

  rc=0
  output="$("${SCRIPT_DIR}/install_subagents.sh" --check 2>&1)" || rc=$?
  printf 'subagents\t%s\n' "$(result_of "${rc}" "${output}")"

  rc=0
  output="$(python3 "${SCRIPT_DIR}/term_profile.py" --check 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    printf 'profile\tok\n'
  else
    printf 'profile\tproblem\n'
  fi
  counts="$(printf '%s\n' "${output}" | sed -n 's/^  ok        messages.json: \([0-9][0-9]*\) messages.*/\1/p' | tail -n 1)"
  printf 'profile_messages\t%s\n' "${counts:--}"

  rc=0
  output="$("${SCRIPT_DIR}/local_info.sh" --check 2>&1)" || rc=$?
  printf 'local_ok\t%s\n' "$(count_lines '^  ok +local/' "${output}")"
  printf 'local_total\t%s\n' "$(count_lines '^  (ok|missing|skipped) +local/' "${output}")"
}

# ---------------------------------------------------------------- table

# Print the value of a key in a porcelain file, or nothing.
value_of() {
  awk -F '\t' -v key="$2" '$1 == key { print $2; exit }' "$1"
}

# Print a time in seconds since 1970 as "MM-DD HH:MM" in Türkiye time.
tr_time() {
  python3 -c 'import sys, datetime
t = datetime.datetime.fromtimestamp(int(sys.argv[1]) + int(sys.argv[2]), datetime.timezone.utc)
print(t.strftime("%m-%d %H:%M"))' "$1" "${TR_OFFSET}"
}

# The text for one check result in the table.
result_cell() {
  case "$1" in
    ok) echo "ok" ;;
    differs | error | "") echo "${1:-?}" ;;
    *) echo "$1 differ" ;;
  esac
}

# Read local/machines.md. A machine line looks like this:
#   - <name>: `ssh <ssh arguments>`, repo yolu `<repo path>`
# Fill NAMES, SSH_PARTS and PATHS. Warn about other lines that start with "- ".
read_machines() {
  local line pattern='^- (.+): `ssh ([^`]+)`, repo yolu `([^`]+)`'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ${pattern} ]]; then
      NAMES+=("${BASH_REMATCH[1]}")
      SSH_PARTS+=("${BASH_REMATCH[2]}")
      PATHS+=("${BASH_REMATCH[3]}")
    elif [[ "${line}" == "- "* ]]; then
      NOTES+=("local/machines.md: this line is not a machine line: ${line}")
    fi
  done < "${MACHINES_FILE}"
}

# Print the "cd" target for a remote shell. "~/x" becomes "$HOME"/x.
remote_cd_path() {
  local path="$1"
  case "${path}" in
    "~") printf '%s' '"$HOME"' ;;
    "~/"*) printf '"$HOME"/%q' "${path#"~/"}" ;;
    *) printf '%q' "${path}" ;;
  esac
}

main() {
  local mode="local" i n ssh_args pids=() rcs=() files=() errs=()
  case "$#:${1-}" in
    0:) ;;
    1:--all) mode="all" ;;
    1:--porcelain) porcelain; return 0 ;;
    *) usage ;;
  esac

  NAMES=("this machine")
  SSH_PARTS=("")
  PATHS=("")
  NOTES=()
  if [[ "${mode}" == "all" ]]; then
    if [[ -f "${MACHINES_FILE}" ]]; then
      read_machines
    else
      NOTES+=("local/machines.md does not exist, so only this machine is shown. Example: local.example/machines.md")
    fi
  fi

  local temp_root="${TMPDIR:-/tmp}"
  # Global: the EXIT trap runs after main returns.
  WORK_DIR="$(mktemp -d "${temp_root%/}/status.XXXXXX")"
  trap 'rm -rf "${WORK_DIR}"' EXIT

  echo "ai_agent_rules status. Check only. Nothing is changed."
  echo "Repo: ${REPO_DIR}"
  echo ""

  # Collect all machines at the same time.
  n="${#NAMES[@]}"
  for ((i = 0; i < n; i++)); do
    files[i]="${WORK_DIR}/${i}.out"
    errs[i]="${WORK_DIR}/${i}.err"
    if [[ "${i}" -eq 0 ]]; then
      "${SCRIPT_DIR}/status.sh" --porcelain >"${files[i]}" 2>"${errs[i]}" </dev/null &
    else
      read -r -a ssh_args <<<"${SSH_PARTS[i]}"
      # BatchMode: no password prompt. -n: ssh does not read stdin.
      ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${ssh_args[@]}" \
        "cd $(remote_cd_path "${PATHS[i]}") && ./scripts/status.sh --porcelain" \
        >"${files[i]}" 2>"${errs[i]}" &
    fi
    pids[i]=$!
  done
  for ((i = 0; i < n; i++)); do
    rcs[i]=0
    wait "${pids[i]}" || rcs[i]=$?
  done

  # Build the table: one row per item, one column per machine.
  local labels=("state" "commit" "repo" "claude CLI" "last install (TR)" "rules" "hooks" "subagents" "term profile" "local files")
  local rows="${#labels[@]}" cells=() reasons=() file value text reason base_commit attention=0
  local r col_width widths=() line first_error
  base_commit="$(value_of "${files[0]}" commit 2>/dev/null || true)"
  for ((i = 0; i < n; i++)); do
    file="${files[i]}"
    reason=""
    if [[ "$(value_of "${file}" format 2>/dev/null || true)" != "${FORMAT_VERSION}" ]]; then
      first_error="$(grep -v '^[[:space:]]*$' "${errs[i]}" | head -n 1 || true)"
      if [[ "${rcs[i]}" -eq 255 ]]; then
        text="ssh failed"
      elif [[ "${rcs[i]}" -eq 127 ]]; then
        text="old repo"
        first_error="scripts/status.sh is not there. Run git pull there."
      elif [[ -s "${file}" ]]; then
        text="old repo"
        first_error="the repo there has another status format. Run git pull there."
      else
        text="error"
      fi
      cells[i]="${text}"
      for ((r = 1; r < rows; r++)); do cells[r * n + i]="-"; done
      reasons[i]="${text}${first_error:+: ${first_error}}"
      attention=1
      continue
    fi

    cells[1 * n + i]="$(value_of "${file}" commit)"
    if [[ -n "${base_commit}" && "${base_commit}" != "-" && "${cells[1 * n + i]}" != "${base_commit}" ]]; then
      reason="${reason}, commit differs from this machine"
    fi

    value="$(value_of "${file}" changes)"
    text="clean"
    if [[ "${value}" == "-" ]]; then
      text="no git"
    elif [[ "${value}" -gt 0 ]]; then
      text="${value} changed"
      reason="${reason}, uncommitted files: ${value}"
    fi
    value="$(value_of "${file}" behind)"
    if [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]]; then
      text="${text}, ${value} behind"
      reason="${reason}, behind upstream: ${value}"
    fi
    value="$(value_of "${file}" ahead)"
    if [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]]; then
      text="${text}, ${value} ahead"
      reason="${reason}, not pushed: ${value}"
    fi
    cells[2 * n + i]="${text}"

    cells[3 * n + i]="$(value_of "${file}" claude)"

    value="$(value_of "${file}" installed)"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
      cells[4 * n + i]="$(tr_time "${value}")"
    else
      cells[4 * n + i]="-"
    fi

    value="$(value_of "${file}" rules)"
    cells[5 * n + i]="$(result_cell "${value}")"
    if [[ "${value}" != "ok" ]]; then reason="${reason}, rules: ${cells[5 * n + i]}"; fi

    value="$(value_of "${file}" hooks)"
    text="$(result_cell "${value}")"
    if [[ "${value}" != "ok" ]]; then reason="${reason}, hooks: ${text}"; fi
    value="$(value_of "${file}" hooks_warnings)"
    if [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]]; then
      text="${text}, ${value} warn"
      reason="${reason}, hook warnings: ${value}"
    fi
    cells[6 * n + i]="${text}"

    value="$(value_of "${file}" subagents)"
    cells[7 * n + i]="$(result_cell "${value}")"
    if [[ "${value}" != "ok" ]]; then reason="${reason}, subagents: ${cells[7 * n + i]}"; fi

    value="$(value_of "${file}" profile)"
    text="${value}"
    if [[ "$(value_of "${file}" profile_messages)" =~ ^[0-9]+$ ]]; then
      text="${text}, $(value_of "${file}" profile_messages) msg"
    fi
    cells[8 * n + i]="${text}"
    if [[ "${value}" != "ok" ]]; then reason="${reason}, term profile: problem"; fi

    cells[9 * n + i]="$(value_of "${file}" local_ok) of $(value_of "${file}" local_total)"

    reason="${reason#, }"
    if [[ -n "${reason}" ]]; then
      cells[i]="needs a look"
      reasons[i]="${reason}"
      attention=1
    else
      cells[i]="ok"
      reasons[i]=""
    fi
  done

  # Column widths: the longest text in each column, plus two spaces.
  widths[0]=0
  for ((r = 0; r < rows; r++)); do
    if [[ "${#labels[r]}" -gt "${widths[0]}" ]]; then widths[0]="${#labels[r]}"; fi
  done
  for ((i = 0; i < n; i++)); do
    col_width="${#NAMES[i]}"
    for ((r = 0; r < rows; r++)); do
      text="${cells[r * n + i]}"
      if [[ "${#text}" -gt "${col_width}" ]]; then col_width="${#text}"; fi
    done
    widths[i + 1]="${col_width}"
  done

  line="$(printf '%-*s' "$((widths[0] + 2))" "")"
  for ((i = 0; i < n; i++)); do
    line="${line}$(printf '%-*s' "$((widths[i + 1] + 2))" "${NAMES[i]}")"
  done
  echo "${line%"${line##*[! ]}"}"
  for ((r = 0; r < rows; r++)); do
    line="$(printf '%-*s' "$((widths[0] + 2))" "${labels[r]}")"
    for ((i = 0; i < n; i++)); do
      line="${line}$(printf '%-*s' "$((widths[i + 1] + 2))" "${cells[r * n + i]}")"
    done
    echo "${line%"${line##*[! ]}"}"
  done
  echo ""

  for line in "${NOTES[@]+"${NOTES[@]}"}"; do
    echo "NOTE: ${line}"
  done
  if [[ "${attention}" -eq 0 ]]; then
    echo "Result: ok. Nothing needs a look."
    return 0
  fi
  echo "Result: these machines need a look:"
  for ((i = 0; i < n; i++)); do
    if [[ -n "${reasons[i]}" ]]; then
      echo "  ${NAMES[i]}: ${reasons[i]}"
    fi
  done
  echo "Details: run ./install.sh --check on that machine."
  return 1
}

main "$@"
