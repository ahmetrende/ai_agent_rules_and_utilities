#!/usr/bin/env bash
# Install the subagent setup of this repo for Claude Code.
#
# Usage:
#   install_subagents.sh           Install or update. Safe to run more than once.
#   install_subagents.sh --check   Read-only. Compare the installed setup with the repo.
#                                  Exit 0 when everything is in sync, 1 when it is not.
#   install_subagents.sh --preflight  Read-only. Run the checks that must pass before
#                                  an install: repo files, tools, stop conditions.
#                                  Exit 0 when they pass.
#
# Target: $CLAUDE_CONFIG_DIR when it is set and not empty, else ~/.claude.
#   <config>/agents/        five agent files: reader, coder, reviewer,
#                           opus-worker and fable-worker (copies, mode 644)
#   <config>/settings.json  two permissions.deny rules and one env key (merged,
#                           never replaced)
#   <config>/CLAUDE.md      read only. install.sh writes the import line of
#                           rules/subagent-routing.md. This script reports its state.
#
# Install steps:
#   preflight  Check the repo files, the tools and the stop conditions.
#   agents     Copy the agent files. When a file differs: stage the new files,
#              back up the old file to <config>/backup-subagent-<stamp>/agents/
#              and move the new file in place. Other files in agents/ are never
#              touched.
#              The reader file in the repo lists the base tools only. The file
#              local/reader-tools.txt can add more tools, one tool name per line.
#              Empty lines and lines that start with "#" are skipped. A line
#              that is not a tool name is skipped with a warning. When the file
#              does not exist, the reader gets the base tools only.
#              The reader must stay read-only, so each extra tool is checked:
#              - A name with a word that changes data (create, delete, run, ...)
#                is skipped with a warning.
#              - A name with a read word (get, list, query, ...) is added.
#              - Any other name is added only when its line ends with
#                " read-only". Without that word it is skipped with a warning.
#              The script prints each added tool on its own line.
#              AI_AGENT_RULES_LOCAL_DIR changes the folder of that file.
#   settings   Merge the entries into settings.json (scripts/subagents_settings.py).
#              A deny rule that is missing is added at the end of the list.
#              env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS is set to "2" when it is
#              missing. Another value is a user setting: the script keeps it.
#              Before a change the old settings.json goes to the same backup
#              directory.
#
# When nothing differs, the script changes nothing and makes no backup.
# The script never starts the claude CLI.
#
# Works with macOS /bin/bash 3.2 and with bash 5 on Ubuntu.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_HELPER="${REPO_DIR}/scripts/subagents_settings.py"

AGENT_FILES="reader.md coder.md reviewer.md opus-worker.md fable-worker.md"
ROUTING_FILE="rules/subagent-routing.md"
# install.sh replaces the CLAUDE.md block with this name by the import line.
ROUTING_BLOCK="subagent-duzeni"

# The reader agent can get more tools from a local file that is not in git.
READER_FILE="reader.md"
LOCAL_DIR="${AI_AGENT_RULES_LOCAL_DIR:-${REPO_DIR}/local}"
READER_TOOLS_FILE="${LOCAL_DIR}/reader-tools.txt"
# A tool name: a letter, then letters, digits, "_" or "-".
# Example: mcp__plugin_name_server__tool_name.
TOOL_NAME_RE='^[A-Za-z][A-Za-z0-9_-]*$'
# Words in the last part of a tool name (after the last "__", split on "_" and
# "-"). A write word wins over a read word: "query_and_update" is a write tool.
READER_WRITE_WORDS="add apply approve assign cancel close commit create delete deploy disable drop edit enable exec execute grant insert invoke kill merge migrate modify move mutate patch pause post publish purge push put remove rename reset restart restore resume revoke rollback rotate run schedule send set start stop submit sync transfer trigger truncate unpause update upload upsert write"
READER_READ_WORDS="count describe explain fetch find get inspect labels list logs lookup metadata metrics query read search series show stats status view"
# Built-in tools that change files, run commands or start agents.
READER_WRITE_BUILTINS="Agent Bash Edit KillShell MultiEdit NotebookEdit Task TaskCreate TaskStop TaskUpdate Write"

ENV_KEY="CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"

# Tools this installer needs.
INSTALLER_TOOLS="python3 jq awk sed grep diff cmp cp mv rm mkdir chmod stat uname dirname date mktemp wc tr cut"

MODE="install"
STEP="start"
WORK=""
SETTINGS_TEMP=""
SUMMARY=""
CHANGES=0
OUT_OF_SYNC=0

# ---------------------------------------------------------------- helpers

say() { printf '%s\n' "$*"; }

die() {
  printf '\nFAILED at step "%s": %s\n' "${STEP}" "$*" >&2
  exit 1
}

# With "set -E" this trap also runs inside $(...) and ( ... ). There it only
# passes the exit code up. The main shell prints the message.
on_error() {
  local code="$1"
  if [[ "${BASH_SUBSHELL}" -gt 0 ]]; then
    exit "${code}"
  fi
  printf '\nFAILED at step "%s": unexpected error at line %s (exit code %s).\n' "${STEP}" "$2" "${code}" >&2
  exit 1
}
trap 'on_error "$?" "${LINENO}"' ERR

cleanup() {
  if [[ -n "${SETTINGS_TEMP}" && -e "${SETTINGS_TEMP}" ]]; then
    rm -f "${SETTINGS_TEMP}"
  fi
  if [[ -n "${WORK}" && -d "${WORK}" ]]; then
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

have() { type -P "$1" >/dev/null 2>&1; }

sha1_of() {
  if have sha1sum; then
    sha1sum "$1" | cut -c1-40
  else
    shasum -a 1 "$1" | cut -c1-40
  fi
}

# Print the permission bits of a file, for example 644.
mode_of() {
  if [[ "${STAT_KIND}" == "gnu" ]]; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

size_of() { wc -c < "$1" | tr -d ' '; }

# Print "missing", "same" or "differs" for an installed file.
# A symlink counts as "differs": the installed files must be copies.
file_state() {
  local source="$1" target="$2"
  if [[ -L "${target}" ]]; then
    echo "differs"
  elif [[ ! -e "${target}" ]]; then
    echo "missing"
  elif [[ ! -f "${target}" ]]; then
    die "${target} exists but is not a regular file."
  elif cmp -s "${source}" "${target}"; then
    echo "same"
  else
    echo "differs"
  fi
}

# Print the physical path of a directory, or the path itself when it does not exist.
resolve_dir() {
  if [[ -d "$1" ]]; then
    (cd "$1" && pwd -P)
  else
    printf '%s\n' "$1"
  fi
}

note() { SUMMARY="${SUMMARY}  - $*"$'\n'; }

changed() { CHANGES=$((CHANGES + 1)); note "$*"; }

out_of_sync() { OUT_OF_SYNC=$((OUT_OF_SYNC + 1)); }

# Create the backup directory of this run when the first backup needs it.
# An existing directory is never used again: the name then gets the process id.
ensure_backup_dir() {
  if [[ "${BACKUP_READY}" -eq 1 ]]; then return 0; fi
  if [[ -e "${BACKUP_DIR}" || -L "${BACKUP_DIR}" ]]; then
    BACKUP_DIR="${BACKUP_DIR}-$$"
  fi
  # mkdir without -p fails when the name exists.
  mkdir -m 700 "${BACKUP_DIR}" || die "could not create the backup directory ${BACKUP_DIR}."
  BACKUP_READY=1
}

# ---------------------------------------------------------------- setup

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
  if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
  fi
  case "${1:-}" in
    "") MODE="install" ;;
    --check) MODE="check" ;;
    --preflight) MODE="preflight" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
}

detect_stat() {
  if stat -c %a / >/dev/null 2>&1; then
    STAT_KIND="gnu"
  elif stat -f %Lp / >/dev/null 2>&1; then
    STAT_KIND="bsd"
  else
    STAT_KIND=""
  fi
}

# Set CONFIG_DIR and the paths below it.
resolve_config() {
  if [[ -z "${HOME:-}" || "${HOME}" != /* ]]; then
    die "HOME is not set to an absolute path."
  fi
  # An empty CLAUDE_CONFIG_DIR counts as not set.
  if [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]; then
    CONFIG_DIR="${HOME}/.claude"
  else
    if [[ ! -d "${CLAUDE_CONFIG_DIR}" ]]; then
      if [[ "${MODE}" == "check" ]]; then
        say "CLAUDE_CONFIG_DIR is not a directory: ${CLAUDE_CONFIG_DIR}"
        say "Result: NOT in sync. Nothing is installed there."
        exit 1
      fi
      if [[ "${MODE}" == "install" ]]; then
        mkdir -p "${CLAUDE_CONFIG_DIR}"
      fi
    fi
    # --preflight changes nothing: a directory that does not exist stays as given.
    CONFIG_DIR="$(resolve_dir "${CLAUDE_CONFIG_DIR}")"
  fi
  AGENTS_DIR="${CONFIG_DIR}/agents"
  SETTINGS="${CONFIG_DIR}/settings.json"
  CLAUDE_MD="${CONFIG_DIR}/CLAUDE.md"
  # The import line that install.sh writes. Same rule as install.sh: "~" or "~/..."
  # only when the repo is HOME or below HOME. A sibling such as /home/user2 for
  # HOME=/home/user keeps its full path.
  local home_dir="${HOME%/}" import_path
  if [[ -n "${home_dir}" && "${REPO_DIR}" == "${home_dir}" ]]; then
    import_path="~"
  elif [[ -n "${home_dir}" && "${REPO_DIR}" == "${home_dir}/"* ]]; then
    import_path="~/${REPO_DIR#"${home_dir}/"}"
  else
    import_path="${REPO_DIR}"
  fi
  IMPORT_LINE="@${import_path}/${ROUTING_FILE}"
}

# Stop when a source file of this repo is missing (an incomplete checkout).
check_repo_files() {
  STEP="repo files"
  local file missing="" count
  for file in ${AGENT_FILES}; do
    if [[ ! -f "${REPO_DIR}/agents/${file}" ]]; then missing="${missing} agents/${file}"; fi
  done
  if [[ ! -f "${REPO_DIR}/${ROUTING_FILE}" ]]; then missing="${missing} ${ROUTING_FILE}"; fi
  if [[ ! -f "${SETTINGS_HELPER}" ]]; then missing="${missing} scripts/subagents_settings.py"; fi
  if [[ -n "${missing}" ]]; then
    die "files are missing in ${REPO_DIR}:${missing}"
  fi
  # The extra tools of the reader are added to its tools line. Stop when that
  # line is not as expected.
  count="$(grep -c '^tools: ' "${REPO_DIR}/agents/${READER_FILE}" || true)"
  if [[ "${count}" != "1" ]]; then
    die "agents/${READER_FILE} must have exactly one \"tools: \" line."
  fi
}

# Print "write <word>", "read <word>" or "unknown" for one tool name.
reader_tool_class() {
  local name="$1" last word
  case " ${READER_WRITE_BUILTINS} " in
    *" ${name} "*) printf 'write %s\n' "${name}"; return 0 ;;
  esac
  last="${name##*__}"
  last="$(printf '%s' "${last}" | tr 'A-Z_-' 'a-z  ')"
  for word in ${last}; do
    case " ${READER_WRITE_WORDS} " in
      *" ${word} "*) printf 'write %s\n' "${word}"; return 0 ;;
    esac
  done
  for word in ${last}; do
    case " ${READER_READ_WORDS} " in
      *" ${word} "*) printf 'read %s\n' "${word}"; return 0 ;;
    esac
  done
  printf 'unknown\n'
}

# Read the extra tools of the reader from READER_TOOLS_FILE.
# Sets READER_EXTRA (", Tool1, Tool2" or empty), READER_EXTRA_COUNT and
# READER_EXTRA_LIST (one "<tool> (<why>)" line for each added tool).
# A tool that the repo file lists already, or a tool listed twice, is added once.
read_reader_extra_tools() {
  local line number=0 listed name marked class
  READER_EXTRA=""
  READER_EXTRA_COUNT=0
  READER_EXTRA_LIST=""
  if [[ ! -e "${READER_TOOLS_FILE}" && ! -L "${READER_TOOLS_FILE}" ]]; then
    return 0
  fi
  if [[ ! -f "${READER_TOOLS_FILE}" || ! -r "${READER_TOOLS_FILE}" ]]; then
    die "${READER_TOOLS_FILE} exists but is not a readable file."
  fi
  listed="$(grep '^tools: ' "${REPO_DIR}/agents/${READER_FILE}")"
  listed=", ${listed#tools: }, "
  while IFS= read -r line || [[ -n "${line}" ]]; do
    number=$((number + 1))
    line="${line%$'\r'}"
    # Remove the spaces at the start and at the end.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "${line}" in
      "" | "#"*) continue ;;
    esac
    name="${line}"
    marked=0
    if [[ "${line}" =~ ^([^[:space:]]+)[[:space:]]+read-only$ ]]; then
      name="${BASH_REMATCH[1]}"
      marked=1
    fi
    if [[ ! "${name}" =~ ${TOOL_NAME_RE} ]]; then
      say "  WARNING     ${READER_TOOLS_FILE} line ${number} is not a tool name. Skipped."
      note "WARNING: ${READER_TOOLS_FILE} line ${number} is not a tool name (skipped)"
      continue
    fi
    class="$(reader_tool_class "${name}")"
    case "${class}" in
      write\ *)
        say "  WARNING     ${READER_TOOLS_FILE} line ${number}: ${name} can change data (\"${class#write }\"). Skipped. The reader stays read-only."
        note "WARNING: ${READER_TOOLS_FILE} line ${number}: ${name} can change data (skipped)"
        continue ;;
      unknown)
        if [[ "${marked}" -eq 0 ]]; then
          say "  WARNING     ${READER_TOOLS_FILE} line ${number}: the name ${name} shows no read word. Skipped. If the tool only reads, write \"${name} read-only\" on that line."
          note "WARNING: ${READER_TOOLS_FILE} line ${number}: ${name} is not known to be read-only (skipped)"
          continue
        fi ;;
    esac
    case "${listed}" in
      *", ${name}, "*) continue ;;
    esac
    listed="${listed}${name}, "
    READER_EXTRA="${READER_EXTRA}, ${name}"
    READER_EXTRA_COUNT=$((READER_EXTRA_COUNT + 1))
    if [[ "${class}" == unknown ]]; then
      READER_EXTRA_LIST="${READER_EXTRA_LIST}${name} (marked read-only in the file)"$'\n'
    else
      READER_EXTRA_LIST="${READER_EXTRA_LIST}${name} (read word \"${class#read }\")"$'\n'
    fi
  done < "${READER_TOOLS_FILE}"
}

# Print each extra tool of the reader on its own line, after the given indent.
print_reader_extra_list() {
  local indent="$1" entry
  while IFS= read -r entry; do
    if [[ -n "${entry}" ]]; then say "${indent}+ ${entry}"; fi
  done <<< "${READER_EXTRA_LIST}"
}

# Build the files to install in ${WORK}/agents. Sets READER_VARIANT.
build_sources() {
  local file
  SOURCE_DIR="${WORK}/agents"
  mkdir -p "${SOURCE_DIR}"
  for file in ${AGENT_FILES}; do
    cp "${REPO_DIR}/agents/${file}" "${SOURCE_DIR}/${file}"
  done
  read_reader_extra_tools
  if [[ "${READER_EXTRA_COUNT}" -eq 0 ]]; then
    if [[ -e "${READER_TOOLS_FILE}" ]]; then
      READER_VARIANT="base tools only (${READER_TOOLS_FILE} adds no tool)"
    else
      READER_VARIANT="base tools only (${READER_TOOLS_FILE} does not exist)"
    fi
    return 0
  fi
  READER_VARIANT="base tools and ${READER_EXTRA_COUNT} extra tools from ${READER_TOOLS_FILE}"
  awk -v extra="${READER_EXTRA}" '
    /^tools: / && !done { print $0 extra; done = 1; next }
    { print }
  ' "${REPO_DIR}/agents/${READER_FILE}" > "${SOURCE_DIR}/${READER_FILE}"
  # The result must differ from the repo file in the tools line only.
  if [[ "$(diff "${REPO_DIR}/agents/${READER_FILE}" "${SOURCE_DIR}/${READER_FILE}" | grep -c '^[<>]' || true)" != "2" ]]; then
    die "could not add the extra tools to the reader file."
  fi
}

# ---------------------------------------------------------------- preflight

# The stop conditions. They change nothing in the config dir.
preflight() {
  STEP="preflight"
  local os tool missing=""
  os="$(uname -s)"
  case "${os}" in
    Linux|Darwin) ;;
    *) die "unsupported system: ${os}. Only Linux and macOS are supported." ;;
  esac
  for tool in ${INSTALLER_TOOLS}; do
    if ! have "${tool}"; then missing="${missing} ${tool}"; fi
  done
  if ! have sha1sum && ! have shasum; then missing="${missing} sha1sum-or-shasum"; fi
  if [[ -z "${STAT_KIND}" ]]; then missing="${missing} GNU-or-BSD-stat"; fi
  if [[ -n "${missing}" ]]; then
    die "missing tools:${missing}. Install them first (Ubuntu: sudo apt install <name>, macOS: brew install <name>)."
  fi
  if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    die "bash ${BASH_VERSION} is too old. bash 3.2 or newer is required."
  fi

  say "Config dir:  ${CONFIG_DIR}"

  if [[ -L "${SETTINGS}" ]]; then
    die "${SETTINGS} is a symlink. The installer does not write through a symlink. Replace it with a regular file or add the entries by hand."
  fi
  if [[ -e "${SETTINGS}" ]] && ! jq -e . "${SETTINGS}" >/dev/null 2>&1; then
    die "${SETTINGS} is not valid JSON."
  fi
  if [[ -L "${AGENTS_DIR}" ]]; then
    die "${AGENTS_DIR} is a symlink. The installer does not write through a symlink."
  fi
  if [[ -e "${AGENTS_DIR}" && ! -d "${AGENTS_DIR}" ]]; then
    die "${AGENTS_DIR} exists but is not a directory."
  fi
  local file
  for file in ${AGENT_FILES}; do
    if [[ -e "${AGENTS_DIR}/${file}" && ! -L "${AGENTS_DIR}/${file}" && ! -f "${AGENTS_DIR}/${file}" ]]; then
      die "${AGENTS_DIR}/${file} exists but is not a regular file."
    fi
  done
  # Stop before any change when the structure of settings.json is not usable.
  build_settings
  build_sources
  say "reader:      ${READER_VARIANT}"
  print_reader_extra_list "             "
  report_overrides
}

# Settings that change the model or the effort the agents really get. Report only.
report_overrides() {
  local name value
  for name in CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL; do
    value="$(printenv "${name}" || true)"
    if [[ -n "${value}" ]]; then
      say "NOTE: ${name} is set in this shell (${value}). It changes the model or effort of the agents."
    fi
    if [[ -f "${SETTINGS}" ]]; then
      value="$(jq -r --arg k "${name}" '(.env // {})[$k] // empty | tostring' "${SETTINGS}" 2>/dev/null || true)"
      if [[ -n "${value}" ]]; then
        say "NOTE: env.${name} is set in settings.json (${value}). It changes the model or effort of the agents."
      fi
    fi
  done
  if [[ -f "${SETTINGS}" ]]; then
    for name in model availableModels; do
      value="$(jq -c --arg k "${name}" '.[$k] // empty' "${SETTINGS}" 2>/dev/null || true)"
      if [[ -n "${value}" ]]; then
        say "NOTE: settings.json has the key \"${name}\" (${value}). An agent whose model is not allowed cannot run."
      fi
    done
  fi
}

# ---------------------------------------------------------------- agents

install_agents() {
  STEP="agents"
  local file state mode need_stage=0 backup
  say "Agents: ${AGENTS_DIR}"
  say "  reader: ${READER_VARIANT}"
  for file in ${AGENT_FILES}; do
    state="$(file_state "${SOURCE_DIR}/${file}" "${AGENTS_DIR}/${file}")"
    if [[ "${state}" != "same" ]]; then need_stage=1; fi
  done

  if [[ "${need_stage}" -eq 1 ]]; then
    # Stage on the same file system, then rename each file into place.
    (umask 022 && mkdir -p "${AGENTS_DIR}")
    # The process id keeps two runs in the same second apart.
    STAGING="${CONFIG_DIR}/.staging-subagents-${STAMP}-$$"
    if [[ -e "${STAGING}" || -L "${STAGING}" ]]; then
      die "the staging directory ${STAGING} exists already. Run the installer again in a moment."
    fi
    mkdir -m 700 "${STAGING}"
    for file in ${AGENT_FILES}; do
      cp "${SOURCE_DIR}/${file}" "${STAGING}/${file}"
      chmod 644 "${STAGING}/${file}"
      if ! cmp -s "${SOURCE_DIR}/${file}" "${STAGING}/${file}"; then
        die "the staged copy of ${file} is not the same as the source file."
      fi
    done
  fi

  for file in ${AGENT_FILES}; do
    state="$(file_state "${SOURCE_DIR}/${file}" "${AGENTS_DIR}/${file}")"
    if [[ "${state}" == "same" ]]; then
      mode="$(mode_of "${AGENTS_DIR}/${file}")"
      if [[ "${mode}" != "644" ]]; then
        chmod 644 "${AGENTS_DIR}/${file}"
        say "  mode fixed  agents/${file} (${mode} -> 644)"
        changed "agents/${file}: mode ${mode} -> 644"
      else
        say "  unchanged   agents/${file}"
      fi
      continue
    fi
    backup=""
    if [[ "${state}" == "differs" ]]; then
      # The file may hold the user's own edits. Keep a copy and show the difference.
      ensure_backup_dir
      backup="${BACKUP_DIR}/agents/${file}"
      mkdir -p "${BACKUP_DIR}/agents"
      if [[ -e "${backup}" || -L "${backup}" ]]; then
        die "the backup ${backup} exists already. The staging directory is kept: ${STAGING}"
      fi
      if ! cp -p "${AGENTS_DIR}/${file}" "${backup}"; then
        die "could not back up ${AGENTS_DIR}/${file}. The staging directory is kept: ${STAGING}"
      fi
      say "  Difference of agents/${file} (< installed file, > new file):"
      diff "${AGENTS_DIR}/${file}" "${STAGING}/${file}" | sed 's/^/    /' || true
    fi
    if ! mv -f "${STAGING}/${file}" "${AGENTS_DIR}/${file}"; then
      die "could not move ${file} into ${AGENTS_DIR}. The staging directory is kept: ${STAGING}"
    fi
    if [[ -n "${backup}" ]]; then
      say "  replaced    agents/${file} (backup: ${backup})"
      changed "agents/${file}: backed up and replaced (backup: ${backup})"
    else
      say "  written     agents/${file}  $(size_of "${AGENTS_DIR}/${file}") bytes  $(sha1_of "${AGENTS_DIR}/${file}" | cut -c1-16)"
      changed "agents/${file}: written"
    fi
  done

  if [[ "${need_stage}" -eq 1 ]]; then
    # Delete the staging directory. The path is checked before the delete.
    case "${STAGING}" in
      "${CONFIG_DIR}"/.staging-subagents-*) rm -rf "${STAGING}" ;;
      *) die "unexpected staging path: ${STAGING}" ;;
    esac
  fi

  mode="$(mode_of "${AGENTS_DIR}")"
  if [[ "${mode}" != "755" ]]; then
    chmod 755 "${AGENTS_DIR}"
    say "  mode fixed  agents/ (${mode} -> 755)"
    changed "agents/: mode ${mode} -> 755"
  fi
  say ""
}

# ---------------------------------------------------------------- settings.json

# Build the merged settings from a snapshot of settings.json.
# Sets SETTINGS_EXISTED, SETTINGS_SHA and SETTINGS_RESULT (unchanged, changed).
# Writes ${WORK}/settings.{in,out,report}.
build_settings() {
  rm -f "${WORK}/settings.in" "${WORK}/settings.out" "${WORK}/settings.report"
  if [[ -e "${SETTINGS}" ]]; then
    SETTINGS_EXISTED=1
    cp "${SETTINGS}" "${WORK}/settings.in"
    SETTINGS_SHA="$(sha1_of "${WORK}/settings.in")"
  else
    SETTINGS_EXISTED=0
    SETTINGS_SHA=""
  fi
  # The helper compares the parsed settings and stops when another key would change.
  python3 "${SETTINGS_HELPER}" \
    --input "${WORK}/settings.in" --output "${WORK}/settings.out" --label "${SETTINGS}" \
    > "${WORK}/settings.report" || die "could not build the merged settings (see the message above). ${SETTINGS} was not changed."
  jq -e . "${WORK}/settings.out" >/dev/null || die "the merged settings are not valid JSON. ${SETTINGS} was not changed."
  if grep -q -x 'result unchanged' "${WORK}/settings.report"; then
    SETTINGS_RESULT="unchanged"
  elif grep -q -x 'result changed' "${WORK}/settings.report"; then
    SETTINGS_RESULT="changed"
  else
    die "the settings helper did not report a result. ${SETTINGS} was not changed."
  fi
}

print_settings_report() {
  local kind status rest
  while read -r kind status rest; do
    case "${kind} ${status}" in
      "deny ok") say "  unchanged   permissions.deny: ${rest}" ;;
      "deny added") say "  added       permissions.deny: ${rest}" ;;
      "env ok") say "  unchanged   env.${ENV_KEY} = \"2\"" ;;
      "env added") say "  added       env.${ENV_KEY} = \"2\"" ;;
      "env differs")
        say "  WARNING     env.${ENV_KEY} is ${rest}, not \"2\". It is your setting: kept, not changed."
        note "WARNING: env.${ENV_KEY} is ${rest}, not \"2\" (user setting, kept)"
        ;;
    esac
  done < "${WORK}/settings.report"
}

install_settings() {
  STEP="settings"
  local attempt=0 mode backup now_sha
  say "Settings: ${SETTINGS}"
  while :; do
    attempt=$((attempt + 1))
    build_settings
    if [[ "${SETTINGS_RESULT}" == "unchanged" ]]; then
      print_settings_report
      say "  settings.json unchanged"
      say ""
      return 0
    fi

    if [[ -L "${SETTINGS}" ]]; then
      die "${SETTINGS} is a symlink. The installer does not write through a symlink."
    fi
    SETTINGS_TEMP="${SETTINGS}.new.$$"
    (umask 077 && cp "${WORK}/settings.out" "${SETTINGS_TEMP}")
    if [[ "${SETTINGS_EXISTED}" -eq 1 ]]; then
      mode="$(mode_of "${SETTINGS}")"
    else
      mode="600"
    fi
    chmod "${mode}" "${SETTINGS_TEMP}"
    jq -e . "${SETTINGS_TEMP}" >/dev/null || die "the new settings file is not valid JSON. ${SETTINGS} was not changed."

    # Another tool may have changed settings.json since the read. Then start again.
    if [[ -e "${SETTINGS}" ]]; then now_sha="$(sha1_of "${SETTINGS}")"; else now_sha=""; fi
    if [[ "${now_sha}" != "${SETTINGS_SHA}" ]]; then
      rm -f "${SETTINGS_TEMP}"
      SETTINGS_TEMP=""
      if [[ "${attempt}" -ge 3 ]]; then
        die "${SETTINGS} changed three times while the installer worked on it. It was not changed by the installer. Run the installer again."
      fi
      say "  settings.json changed during the merge. Reading it again."
      continue
    fi

    print_settings_report
    backup=""
    if [[ "${SETTINGS_EXISTED}" -eq 1 ]]; then
      ensure_backup_dir
      backup="${BACKUP_DIR}/settings.json"
      if [[ -e "${backup}" || -L "${backup}" ]]; then
        die "the backup ${backup} exists already. ${SETTINGS} was not changed."
      fi
      cp -p "${SETTINGS}" "${backup}"
    fi
    mv -f "${SETTINGS_TEMP}" "${SETTINGS}"
    SETTINGS_TEMP=""
    if [[ "${SETTINGS_EXISTED}" -eq 1 ]]; then
      say "  Difference of \"permissions\" and \"env\" (sorted keys; < before, > after):"
      jq -S '{permissions, env}' "${WORK}/settings.in" > "${WORK}/settings.in.part"
      jq -S '{permissions, env}' "${WORK}/settings.out" > "${WORK}/settings.out.part"
      diff "${WORK}/settings.in.part" "${WORK}/settings.out.part" | sed 's/^/    /' || true
      say "  All other keys and entries are the same (compared as parsed JSON)."
      say "  settings.json written (backup: ${backup})"
      changed "settings.json: subagent entries merged (backup: ${backup})"
    else
      say "  settings.json created (mode 600)"
      changed "settings.json: created with the subagent entries"
    fi
    say ""
    return 0
  done
}

# ---------------------------------------------------------------- CLAUDE.md

# Print the state of the routing rules in CLAUDE.md: "ok", "missing" (no import
# line), "old-block" (the old marked block is still there) or "no-file".
claude_md_state() {
  if [[ ! -f "${CLAUDE_MD}" ]]; then
    echo "no-file"
  elif grep -q -E "^<!-- ${ROUTING_BLOCK}:(baslangic|bitis) -->[[:space:]]*\$" "${CLAUDE_MD}"; then
    echo "old-block"
  elif grep -q -F -x -- "${IMPORT_LINE}" "${CLAUDE_MD}"; then
    echo "ok"
  else
    echo "missing"
  fi
}

# install.sh writes CLAUDE.md. This script only reports what it finds.
report_claude_md() {
  STEP="CLAUDE.md"
  local state
  say "Routing rules: ${CLAUDE_MD}"
  state="$(claude_md_state)"
  case "${state}" in
    ok)
      say "  ok          the import line ${IMPORT_LINE}"
      ;;
    old-block)
      say "  WARNING     the old marked block \"${ROUTING_BLOCK}\" is still in CLAUDE.md. Run install.sh: it replaces the block by the import line."
      note "WARNING: CLAUDE.md still has the old block \"${ROUTING_BLOCK}\". Run install.sh."
      ;;
    *)
      say "  WARNING     the import line ${IMPORT_LINE} is not in CLAUDE.md. Run install.sh: it writes the line."
      note "WARNING: CLAUDE.md does not import ${ROUTING_FILE}. Run install.sh."
      ;;
  esac
  say ""
}

# ---------------------------------------------------------------- check mode

check_mode() {
  STEP="check"
  local missing="" tool file state mode kind status rest leftover
  for tool in jq python3 cmp diff awk grep; do
    if ! have "${tool}"; then missing="${missing} ${tool}"; fi
  done
  if ! have sha1sum && ! have shasum; then missing="${missing} sha1sum-or-shasum"; fi
  if [[ -z "${STAT_KIND}" ]]; then missing="${missing} GNU-or-BSD-stat"; fi
  if [[ -n "${missing}" ]]; then
    die "missing tools:${missing}."
  fi

  say "Subagent setup. Check only. Nothing is changed."
  say "Config dir:  ${CONFIG_DIR}"
  say ""

  local settings_usable=1
  if [[ -e "${SETTINGS}" ]] && ! jq -e . "${SETTINGS}" >/dev/null 2>&1; then settings_usable=0; fi

  say "Agents: ${AGENTS_DIR}"
  if [[ -L "${AGENTS_DIR}" ]]; then
    say "  STOP      agents is a symlink (the installer stops)"
    out_of_sync
  elif [[ -e "${AGENTS_DIR}" && ! -d "${AGENTS_DIR}" ]]; then
    say "  STOP      agents exists but is not a directory (the installer stops)"
    out_of_sync
  elif [[ "${settings_usable}" -eq 0 ]]; then
    say "  STOP      settings.json is not valid JSON (the installer stops)"
    out_of_sync
  else
    build_sources
    say "  reader: ${READER_VARIANT}"
    print_reader_extra_list "          "
    for file in ${AGENT_FILES}; do
      if [[ -e "${AGENTS_DIR}/${file}" && ! -L "${AGENTS_DIR}/${file}" && ! -f "${AGENTS_DIR}/${file}" ]]; then
        say "  STOP      agents/${file} exists but is not a regular file (the installer stops)"
        out_of_sync
        continue
      fi
      state="$(file_state "${SOURCE_DIR}/${file}" "${AGENTS_DIR}/${file}")"
      if [[ "${state}" == "same" ]]; then
        mode="$(mode_of "${AGENTS_DIR}/${file}")"
        if [[ "${mode}" != "644" ]]; then
          say "  same, but mode ${mode} (want 644)  agents/${file}"
          out_of_sync
        else
          say "  same      agents/${file}"
        fi
      else
        if [[ -L "${AGENTS_DIR}/${file}" ]]; then state="differs (symlink)"; fi
        say "  ${state}  agents/${file}"
        out_of_sync
      fi
    done
    if [[ -d "${AGENTS_DIR}" ]]; then
      mode="$(mode_of "${AGENTS_DIR}")"
      if [[ "${mode}" != "755" ]]; then
        say "  mode ${mode} (want 755)  agents/"
        out_of_sync
      fi
    fi
  fi
  for leftover in "${CONFIG_DIR}"/.staging-subagents-*; do
    if [[ -e "${leftover}" ]]; then
      say "  NOTE      a leftover staging directory: ${leftover}"
    fi
  done
  say ""

  say "Settings: ${SETTINGS}"
  if [[ -L "${SETTINGS}" ]]; then
    say "  STOP      settings.json is a symlink (the installer stops)"
    out_of_sync
  fi
  if [[ "${settings_usable}" -eq 0 ]]; then
    say "  STOP      settings.json is not valid JSON"
    out_of_sync
  else
    build_settings
    while read -r kind status rest; do
      case "${kind} ${status}" in
        "deny ok") say "  ok        permissions.deny: ${rest}" ;;
        "deny added") say "  missing   permissions.deny: ${rest}" ;;
        "env ok") say "  ok        env.${ENV_KEY} = \"2\"" ;;
        "env added") say "  missing   env.${ENV_KEY}" ;;
        # The installer keeps another value, so this is not counted as out of sync.
        "env differs") say "  differs (user setting)  env.${ENV_KEY} is ${rest}, not \"2\": the installer keeps it" ;;
      esac
    done < "${WORK}/settings.report"
    if [[ "${SETTINGS_RESULT}" != "unchanged" ]]; then
      out_of_sync
    fi
    report_overrides | sed 's/^NOTE: /  NOTE      /'
  fi
  say ""

  say "Routing rules: ${CLAUDE_MD}"
  state="$(claude_md_state)"
  case "${state}" in
    ok)
      say "  ok        the import line ${IMPORT_LINE}"
      ;;
    old-block)
      say "  not correct  the old marked block \"${ROUTING_BLOCK}\" is still in CLAUDE.md (install.sh replaces it by the import line)"
      out_of_sync
      ;;
    no-file)
      say "  missing   CLAUDE.md (install.sh writes it)"
      out_of_sync
      ;;
    *)
      say "  missing   the import line ${IMPORT_LINE} (install.sh writes it)"
      out_of_sync
      ;;
  esac
  say ""

  if [[ "${OUT_OF_SYNC}" -eq 0 ]]; then
    say "Result: in sync. The installer would change nothing."
    exit 0
  fi
  say "Result: NOT in sync (${OUT_OF_SYNC} items). Run install.sh to fix it."
  exit 1
}

# ---------------------------------------------------------------- main

main() {
  parse_args "$@"
  check_repo_files
  detect_stat
  resolve_config

  # Local time, like the names of the other backups.
  STAMP="$(date +%Y%m%dT%H%M%S)"
  BACKUP_DIR="${CONFIG_DIR}/backup-subagent-${STAMP}"
  BACKUP_READY=0
  local temp_root="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${temp_root%/}/install-subagents.XXXXXX")"

  if [[ "${MODE}" == "check" ]]; then
    check_mode
  fi
  if [[ "${MODE}" == "preflight" ]]; then
    say "Subagent setup. Preflight only. Nothing is changed."
    preflight
    say ""
    say "Preflight passed."
    return 0
  fi

  say "Subagent setup"
  preflight
  say ""
  install_agents
  install_settings
  report_claude_md

  STEP="summary"
  say "Summary (subagent setup)"
  if [[ -n "${SUMMARY}" ]]; then printf '%s' "${SUMMARY}"; fi
  if [[ "${CHANGES}" -eq 0 ]]; then
    say "  Nothing changed. The installed agents and settings are the same as the repo."
  else
    say "  Changes: ${CHANGES}. Start a new Claude Code session to load the agents and the settings."
  fi
}

# One line: bash has read the "exit" before main starts, so a change of this
# file during the run (git pull) cannot make bash run new text after main.
main "$@"; exit $?
