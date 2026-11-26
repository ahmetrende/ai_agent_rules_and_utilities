#!/usr/bin/env bash
# Ask for the personal files in local/ when they are missing.
#
# Usage:
#   local_info.sh          Ask for each missing file. Only when stdin is a terminal.
#   local_info.sh --check  Read-only. Print the state of each file. Exit 0.
#
# Folder: $AI_AGENT_RULES_LOCAL_DIR when it is set and not empty (for tests),
# else <repo>/local. git does not track this folder.
#   ben.md            Sector, job, work and systems. AGENTS.md imports this file.
#   reader-tools.txt  Extra tools of the reader agent, one tool name per line.
#                     scripts/install_subagents.sh reads this file.
#
# Every answer is optional. An empty answer writes no line. When all answers
# for a file are empty, the file is not written. The setup works without these
# files.
# The script asks for a file only once. The file .install-asked in the same
# folder records each file that was asked for and left empty. Remove a name
# from .install-asked to be asked again.
# Without a terminal on stdin the script asks nothing and prints a note.
#
# Works with macOS /bin/bash 3.2 and with bash 5 on Ubuntu.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="${AI_AGENT_RULES_LOCAL_DIR:-${REPO_DIR}/local}"
ASKED_FILE="${LOCAL_DIR}/.install-asked"
# A tool name: a letter, then letters, digits, "_" or "-".
# Same rule as scripts/install_subagents.sh.
TOOL_NAME_RE='^[A-Za-z][A-Za-z0-9_-]*$'

TEMP_FILE=""
cleanup() {
  if [[ -n "${TEMP_FILE}" && -e "${TEMP_FILE}" ]]; then
    rm -f "${TEMP_FILE}"
  fi
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

die() {
  printf 'local_info.sh: %s\n' "$*" >&2
  exit 1
}

# Print "yes" when the name is in .install-asked, else "no".
was_asked() {
  if [[ -f "${ASKED_FILE}" ]] && grep -q -x -F -- "$1" "${ASKED_FILE}"; then
    echo "yes"
  else
    echo "no"
  fi
}

mark_asked() {
  if [[ "$(was_asked "$1")" == "no" ]]; then
    if [[ ! -e "${ASKED_FILE}" ]]; then
      (umask 077 && printf '%s\n' "# Files that ./install.sh asked for and that were left empty. Remove a line to be asked again." > "${ASKED_FILE}")
    fi
    printf '%s\n' "$1" >> "${ASKED_FILE}"
  fi
}

# Ask one question. Print the answer without control characters and without
# spaces at the start and at the end. An end of input gives an empty answer.
ask() {
  local answer=""
  printf '%s' "$1" >&2
  IFS= read -r answer || true
  answer="${answer//[[:cntrl:]]/}"
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  printf '%s' "${answer}"
}

# Write the content of the file TEMP_FILE to $1 (mode 600). Never replace a file.
install_file() {
  local target="$1"
  if [[ -e "${target}" || -L "${target}" ]]; then
    die "${target} exists already. It was not changed."
  fi
  chmod 600 "${TEMP_FILE}"
  mv "${TEMP_FILE}" "${target}"
  TEMP_FILE=""
}

new_temp_file() {
  TEMP_FILE="$(mktemp "${LOCAL_DIR}/.local-info.XXXXXX")"
}

ask_ben() {
  local target="${LOCAL_DIR}/ben.md" sector job work systems
  say ""
  say "local/ben.md: information about you. Claude reads it in every session."
  say "Every answer is optional. Press Enter to skip a question."
  sector="$(ask "  Your sector (example: technology): ")"
  job="$(ask "  Your job (example: DBA, backend developer): ")"
  work="$(ask "  Your work in one sentence (example: software and database work): ")"
  systems="$(ask "  Systems you use (cloud, db, monitoring. Example: AWS, PostgreSQL, Grafana): ")"
  if [[ -z "${sector}${job}${work}${systems}" ]]; then
    mark_asked "ben.md"
    say "  All answers are empty. local/ben.md was not written."
    return 0
  fi
  new_temp_file
  {
    if [[ -n "${sector}" ]]; then printf -- '- Sektörüm: %s\n' "${sector}"; fi
    if [[ -n "${job}" ]]; then printf -- '- Mesleğim: %s\n' "${job}"; fi
    if [[ -n "${work}" ]]; then printf -- '- Yaptığım işler: %s\n' "${work}"; fi
    if [[ -n "${systems}" ]]; then printf -- '- Kullandığım sistemler: %s\n' "${systems}"; fi
  } > "${TEMP_FILE}"
  install_file "${target}"
  say "  written     ${target}"
}

ask_reader_tools() {
  local target="${LOCAL_DIR}/reader-tools.txt" answer tool tools="" count=0 old_ifs
  say ""
  say "local/reader-tools.txt: extra tools of the reader agent, for example the read-only"
  say "tools of an MCP server. The reader always gets Read, Grep, Glob and ToolSearch."
  answer="$(ask "  Extra tool names, separated by commas (example: mcp__server__tool). Empty: none: ")"
  old_ifs="${IFS}"
  IFS=", "
  # No glob expansion while the answer is split into words.
  set -f
  for tool in ${answer}; do
    if [[ -z "${tool}" ]]; then continue; fi
    if [[ ! "${tool}" =~ ${TOOL_NAME_RE} ]]; then
      say "  WARNING     \"${tool}\" is not a tool name. Skipped."
      continue
    fi
    tools="${tools}${tool}"$'\n'
    count=$((count + 1))
  done
  set +f
  IFS="${old_ifs}"
  if [[ "${count}" -eq 0 ]]; then
    mark_asked "reader-tools.txt"
    say "  No extra tool. local/reader-tools.txt was not written."
    return 0
  fi
  new_temp_file
  {
    printf '%s\n' "# Extra tools of the reader agent. One tool name per line."
    printf '%s\n' "# scripts/install_subagents.sh adds them to the tools line of agents/reader.md."
    printf '%s' "${tools}"
  } > "${TEMP_FILE}"
  install_file "${target}"
  say "  written     ${target} (${count} tools)"
}

# Print the state of one file for --check.
check_file() {
  local name="$1" example="$2"
  if [[ -e "${LOCAL_DIR}/${name}" ]]; then
    say "  ok        local/${name}"
  elif [[ "$(was_asked "${name}")" == "yes" ]]; then
    say "  skipped   local/${name} (left empty at install. Remove \"${name}\" from local/.install-asked to be asked again)"
  else
    say "  missing   local/${name} (optional. ${example})"
  fi
}

check_mode() {
  say "Local files: ${LOCAL_DIR}"
  check_file "ben.md" "./install.sh asks for it in a terminal. Example: local.example/ben.md"
  check_file "reader-tools.txt" "./install.sh asks for it in a terminal. Example: local.example/reader-tools.txt"
  say "  These files are optional. The setup works without them."
}

main() {
  if [[ $# -gt 1 ]]; then
    say "usage: local_info.sh [--check]" >&2
    exit 2
  fi
  case "${1:-}" in
    "") ;;
    --check) check_mode; exit 0 ;;
    *) say "usage: local_info.sh [--check]" >&2; exit 2 ;;
  esac

  local need_ben=0 need_tools=0
  if [[ ! -e "${LOCAL_DIR}/ben.md" && "$(was_asked "ben.md")" == "no" ]]; then need_ben=1; fi
  if [[ ! -e "${LOCAL_DIR}/reader-tools.txt" && "$(was_asked "reader-tools.txt")" == "no" ]]; then need_tools=1; fi
  if [[ "${need_ben}" -eq 0 && "${need_tools}" -eq 0 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    say "Local files: not asked (no terminal). The setup works without them."
    if [[ "${need_ben}" -eq 1 ]]; then say "  missing   local/ben.md (example: local.example/ben.md)"; fi
    if [[ "${need_tools}" -eq 1 ]]; then say "  missing   local/reader-tools.txt (example: local.example/reader-tools.txt)"; fi
    return 0
  fi
  if [[ -L "${LOCAL_DIR}" ]]; then
    die "${LOCAL_DIR} is a symlink. Nothing was written."
  fi
  (umask 077 && mkdir -p "${LOCAL_DIR}")
  if [[ "${need_ben}" -eq 1 ]]; then ask_ben; fi
  if [[ "${need_tools}" -eq 1 ]]; then ask_reader_tools; fi
  say ""
}

main "$@"; exit $?
