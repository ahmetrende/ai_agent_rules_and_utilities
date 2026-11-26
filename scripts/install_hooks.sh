#!/usr/bin/env bash
# Install the Claude Code hooks and the usage-feed mod of this repo.
#
# Usage:
#   install_hooks.sh           Install or update. Safe to run more than once.
#   install_hooks.sh --check   Read-only. Compare the installed files with the repo.
#                              Exit 0 when everything is in sync, 1 when it is not.
#                              It never starts the claude CLI.
#   install_hooks.sh --preflight  Read-only. Run the checks that must pass before an
#                              install: repo files, tools, stop conditions.
#                              Exit 0 when they pass. It never starts the claude CLI.
#
# Target: $CLAUDE_CONFIG_DIR when it is set and not empty, else ~/.claude.
#   <config>/hooks/       four hook scripts, secret-guard.py and its Codex adapter,
#                         usage-limit.conf and the three test suites
#   <config>/local-mods/  the local marketplace with the usage-feed mod
#   <config>/settings.json  ten hook registrations (merged, never replaced)
#
# Install steps:
#   preflight   Check the tools, the claude CLI and the stop conditions.
#               Without a claude CLI 2.1.308 or newer, only the usage-feed step
#               is skipped. The rest is installed.
#               It also shows the secret-guard local rule file and the version of
#               the claude on PATH (warnings only; --check shows them too).
#   hooks       Copy the hook files. When a file differs: stage the new files,
#               run the test suites against the staging directory, back up the
#               old files (<name>.bak-<YYYYMMDD>) and move the new files in place.
#               A failed test leaves every installed file as it is.
#   conf        Write usage-limit.conf when it is missing. An existing file is a
#               user setting: the script shows the difference and keeps the file.
#   settings    Merge the registrations into settings.json (scripts/hooks_settings.py).
#   usage-feed  Copy the mod files. When a file differs: stage, run
#               "claude plugin validate" and "claude plugin test", then move the
#               files in place. Register the marketplace and the plugin when they
#               are missing.
#
# The files are copied, not linked. The repo path is never written to settings.json.
# When nothing differs, the script changes nothing and runs no tests.
#
# Works with macOS /bin/bash 3.2 and with bash 5 on Ubuntu.
#
# Environment:
#   CLAUDE_BIN  Path of the claude CLI to use. Default: the newest one found.
#               The installer stops when this file is missing, not executable or
#               older than 2.1.308.
#
# When you change a test suite, update the EXPECT_ numbers below in the same commit.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_HELPER="${REPO_DIR}/scripts/hooks_settings.py"

# Group A files, group B files, the shared test shims, then the secret guard (group C).
HOOK_FILES="context-pressure.sh session-end-mark.sh handoff-load.sh tests/run-tests.sh usage-limit.sh tests/run-ul-tests.sh tests/shims/stat tests/shims/tail secret-guard.py secret-guard-codex.py tests/run-sg-tests.py handoff-dump.py"
CONF_FILE="usage-limit.conf"
MOD_FILES=".claude-plugin/marketplace.json usage-feed/.claude-plugin/plugin.json usage-feed/hooks/hooks.json usage-feed/hooks/register.ts usage-feed/hooks/register.test.ts usage-feed/README.md oturum/.claude-plugin/plugin.json oturum/README.md oturum/bin/sessions.py oturum/bin/test_sessions.py oturum/hooks/hooks.json oturum/hooks/register.test.tsx oturum/hooks/register.tsx oturum/types/index.d.ts"

MARKETPLACE="local-mods"
PLUGIN_ID="usage-feed@local-mods"
PLUGIN_NAME="usage-feed"
# The mods of the local-mods marketplace. Each is validated, tested and registered.
MOD_PLUGINS="usage-feed oturum"
MIN_CLAUDE_VERSION="2.1.308"
# secret-guard.py is registered with "onFailure": "block". Claude Code reads that field
# from 2.1.295 on (https://code.claude.com/docs/en/hooks, command hook fields). An older
# claude runs the tool call also when secret-guard cannot run.
MIN_ONFAILURE_VERSION="2.1.295"

# Expected number of passed tests in each run.
EXPECT_A=588           # tests/run-tests.sh, normal PATH
EXPECT_A_FALLBACK=525  # tests/run-tests.sh, fallback PATH (no git, no python3: their tests are skipped)
EXPECT_B=397           # tests/run-ul-tests.sh, normal PATH
EXPECT_B_FALLBACK=388  # tests/run-ul-tests.sh, fallback PATH (no python3: the dump tests are skipped)
EXPECT_SG=354          # tests/run-sg-tests.py, each python3
EXPECT_MOD=34          # claude plugin test, usage-feed
EXPECT_MOD_OTURUM=41   # claude plugin test, oturum
EXPECT_SESSIONS_PY=40  # python3 -m unittest, local-mods/oturum/bin

# Directories the installer manages, below <config>/hooks and <config>/local-mods.
# "." is the directory itself. Their mode is 755. hooks/state is 700.
HOOK_DIRS=". tests tests/shims"
MOD_DIRS=". .claude-plugin usage-feed usage-feed/.claude-plugin usage-feed/hooks oturum oturum/.claude-plugin oturum/bin oturum/hooks oturum/types"

# The claude plugin commands run with this setting, so "claude plugin install"
# does not start the SessionEnd hook that the installer has just registered.
NO_HOOKS_SETTINGS='{"disableAllHooks":true}'

# Tools the hooks need (prerequisite list of the hooks).
HOOK_TOOLS="bash jq iconv awk sed find sort head tail wc cut tr mktemp date grep"
# Tools this installer needs in addition.
INSTALLER_TOOLS="python3 diff cmp cp mv rm mkdir chmod stat uname dirname ln cat"
# Tools of the fallback test PATH. tac, sha1sum and git are left out on purpose.
FALLBACK_TOOLS="bash env jq iconv awk sed find sort head tail wc cut tr mktemp date shasum cat rm mv mkdir chmod cp touch sleep dirname basename rmdir grep ls seq id od ln cmp diff true false"

MODE="install"
STEP="start"
WORK=""
SETTINGS_TEMP=""
SUMMARY=""
CHANGES=0
OUT_OF_SYNC=0
WARNINGS=0  # problems the installer does not fix (secret-guard local file, old claude on PATH)

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

# Print the permission bits of a file, for example 755.
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

# Print a backup path that does not exist yet: <path>.bak-<YYYYMMDD>,
# or <path>.bak-<YYYYMMDDTHHMMSS> when the first name is taken.
backup_name() {
  local path="$1" name
  name="${path}.bak-${DAY}"
  if [[ -e "${name}" || -L "${name}" ]]; then
    name="${path}.bak-${STAMP}"
  fi
  if [[ -e "${name}" || -L "${name}" ]]; then
    die "the backup ${name} exists already. Run the installer again in a moment."
  fi
  echo "${name}"
}

# version_ge A B: true when version A is the same as B or newer.
version_ge() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<EOF
$1
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$2
EOF
  # 10# = always decimal, also with a leading zero.
  a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
  b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
  if (( a1 != b1 )); then (( a1 > b1 )); return; fi
  if (( a2 != b2 )); then (( a2 > b2 )); return; fi
  (( a3 >= b3 ))
}

# Print the first 16 hex characters of the SHA-1 of a text.
sha1_16_of_text() {
  if have sha1sum; then
    printf '%s' "$1" | sha1sum | cut -c1-16
  else
    printf '%s' "$1" | shasum -a 1 | cut -c1-16
  fi
}

# Print the version number of a claude binary, or nothing.
# stdin is closed. With "timeout" on PATH the call ends after 20 seconds.
claude_version_of() {
  local output
  if have timeout; then
    output="$(timeout 20 "$1" --version </dev/null 2>/dev/null | head -n 1)" || true
  else
    output="$("$1" --version </dev/null 2>/dev/null | head -n 1)" || true
  fi
  printf '%s\n' "${output}" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# Print the version number in the path of a claude binary, or nothing.
# It follows symlinks and reads the last <n>.<n>.<n> that comes right after a
# "claude-code/", "versions/" or "ccd-cli/" path part. Nothing is started.
# Examples: .../claude-code/2.1.325/<id>/claude.app/..., .../versions/2.1.283,
# .../ccd-cli/2.1.308-3f6ee6c72f6a. Other numbers are not versions of claude:
# ~/.nvm/versions/node/v20.11.0/bin/claude gives nothing.
claude_version_by_name() {
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

# Print the physical path of a directory, or the path itself when it does not exist.
resolve_dir() {
  if [[ -d "$1" ]]; then
    (cd "$1" && pwd -P)
  else
    printf '%s\n' "$1"
  fi
}

same_dir() {
  [[ "$1" == "$2" || "$(resolve_dir "$1")" == "$(resolve_dir "$2")" ]]
}

note() { SUMMARY="${SUMMARY}  - $*"$'\n'; }

changed() { CHANGES=$((CHANGES + 1)); note "$*"; }

out_of_sync() { OUT_OF_SYNC=$((OUT_OF_SYNC + 1)); }

# Run the claude CLI in an empty directory, so no project settings apply.
# The exit code of claude is the exit code of this function.
run_claude() {
  (
    trap - ERR
    cd "${WORK}/cwd" || exit 1
    exec "${CLAUDE_BIN_USED}" "$@"
  )
}

# Run a claude plugin command that changes state. Hooks are off when the CLI
# accepts the setting (checked in preflight).
run_claude_change() {
  if [[ "${HOOKS_OFF}" -eq 1 ]]; then
    run_claude --settings "${NO_HOOKS_SETTINGS}" "$@"
  else
    run_claude "$@"
  fi
}

# ---------------------------------------------------------------- setup

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Set CONFIG_DIR and the forms of the hook command directory.
resolve_config() {
  if [[ -z "${HOME:-}" || "${HOME}" != /* ]]; then
    die "HOME is not set to an absolute path."
  fi
  HOME_REAL="$(resolve_dir "${HOME}")"
  # An empty CLAUDE_CONFIG_DIR counts as not set, also for the commands started here.
  if [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]; then
    unset CLAUDE_CONFIG_DIR
    CONFIG_DIR="${HOME}/.claude"
    COMMAND_DIR="~/.claude"
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
    if [[ "${CONFIG_DIR}" == "$(resolve_dir "${HOME}/.claude")" ]]; then
      # The same place as ~/.claude: keep the "~" form, so the command does not
      # change when CLAUDE_CONFIG_DIR is set in one run and not set in the next.
      COMMAND_DIR="~/.claude"
    else
      # Another config dir: the hook command is the absolute path.
      COMMAND_DIR="${CONFIG_DIR}"
    fi
  fi
  HOOKS_DIR="${CONFIG_DIR}/hooks"
  MODS_DIR="${CONFIG_DIR}/local-mods"
  SETTINGS="${CONFIG_DIR}/settings.json"
}

# Print the claude binaries to look at, one path in each line.
claude_candidates() {
  local candidate engine_root file
  candidate="$(type -P claude 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then printf '%s\n' "${candidate}"; fi
  printf '%s\n' "${HOME}/.local/bin/claude"
  # macOS: the Desktop app keeps its own engine, often newer than the CLI on PATH.
  engine_root="${HOME}/Library/Application Support/Claude/claude-code"
  if [[ -d "${engine_root}" ]]; then
    for file in "${engine_root}"/*/*/claude.app/Contents/MacOS/claude; do
      if [[ -x "${file}" ]]; then printf '%s\n' "${file}"; fi
    done
  fi
  # Linux: the CLI that Claude Desktop installs for SSH sessions. Not on PATH.
  # The files are named like 2.1.308-3f6ee6c72f6a.
  for file in "${HOME}/.claude/remote/ccd-cli"/*; do
    if [[ -f "${file}" && -x "${file}" ]]; then printf '%s\n' "${file}"; fi
  done
}

# Stop when CLAUDE_BIN is set but is not an executable file. Nothing is started.
check_claude_bin_file() {
  if [[ -z "${CLAUDE_BIN:-}" ]]; then return 0; fi
  if [[ ! -e "${CLAUDE_BIN}" ]]; then
    die "CLAUDE_BIN is set, but the file does not exist: ${CLAUDE_BIN}"
  fi
  if [[ ! -f "${CLAUDE_BIN}" || ! -x "${CLAUDE_BIN}" ]]; then
    die "CLAUDE_BIN is set, but it is not an executable file: ${CLAUDE_BIN}"
  fi
}

# Find the newest usable claude CLI. Sets CLAUDE_BIN_USED and CLAUDE_VERSION_USED.
# They stay empty when no binary is new enough. A CLAUDE_BIN that cannot be used
# stops the installer: it is never skipped silently.
find_claude() {
  local candidate version best="" best_version=""
  CLAUDE_BIN_USED=""
  CLAUDE_VERSION_USED=""
  CLAUDE_SEEN=""
  if [[ -n "${CLAUDE_BIN:-}" ]]; then
    check_claude_bin_file
    version="$(claude_version_of "${CLAUDE_BIN}")"
    if [[ -z "${version}" ]]; then
      die "CLAUDE_BIN is set, but \"${CLAUDE_BIN} --version\" did not print a version."
    fi
    if ! version_ge "${version}" "${MIN_CLAUDE_VERSION}"; then
      die "CLAUDE_BIN is set, but ${CLAUDE_BIN} is version ${version}. Version ${MIN_CLAUDE_VERSION} or newer is required."
    fi
    CLAUDE_BIN_USED="${CLAUDE_BIN}"
    CLAUDE_VERSION_USED="${version}"
    return 0
  fi
  while IFS= read -r candidate; do
    if [[ -z "${candidate}" || ! -x "${candidate}" ]]; then continue; fi
    version="$(claude_version_of "${candidate}")"
    if [[ -z "${version}" ]]; then continue; fi
    CLAUDE_SEEN="${CLAUDE_SEEN}    ${version}  ${candidate}"$'\n'
    if [[ -z "${best}" ]] || ! version_ge "${best_version}" "${version}"; then
      best="${candidate}"
      best_version="${version}"
    fi
  done <<EOF
$(claude_candidates)
EOF
  if [[ -n "${best}" ]] && version_ge "${best_version}" "${MIN_CLAUDE_VERSION}"; then
    CLAUDE_BIN_USED="${best}"
    CLAUDE_VERSION_USED="${best_version}"
  fi
}

# Without starting anything: can a claude CLI 2.1.308 or newer be on this machine?
# The version comes from the path of each binary. A binary whose path has no
# version counts as usable. Prints "yes" or "no".
claude_usable_by_name() {
  local candidate version list
  if [[ -n "${CLAUDE_BIN:-}" ]]; then
    list="${CLAUDE_BIN}"
  else
    list="$(claude_candidates)"
  fi
  while IFS= read -r candidate; do
    if [[ -z "${candidate}" || ! -f "${candidate}" || ! -x "${candidate}" ]]; then continue; fi
    version="$(claude_version_by_name "${candidate}")"
    if [[ -z "${version}" ]] || version_ge "${version}" "${MIN_CLAUDE_VERSION}"; then
      echo "yes"
      return 0
    fi
  done <<EOF
${list}
EOF
  echo "no"
}

# Show the secret-guard state that the hook files do not show. Nothing is started and
# nothing is changed. A problem adds to WARNINGS: --check does not count it as out of
# sync, because the installer cannot fix it.
#   - The local rule file: the hook skips a broken file or entry (only a log line).
#     The check uses the repo copy of secret-guard.py.
#   - The claude on PATH: "onFailure": "block" needs MIN_ONFAILURE_VERSION. The version
#     comes from the path of the binary, like claude_usable_by_name.
report_secret_guard() {
  local output rc=0 path_claude version
  say "secret-guard: local rules and claude version"
  output="$(python3 "${REPO_DIR}/hooks/secret-guard.py" --check-local "${HOOKS_DIR}/secret-guard.local.json" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    say "  ${output}"
  else
    say "  WARNING   the local rule file has a problem. secret-guard skips the broken parts:"
    printf '%s\n' "${output}" | sed 's/^/    /'
    WARNINGS=$((WARNINGS + 1))
  fi
  path_claude="$(type -P claude 2>/dev/null || true)"
  if [[ -z "${path_claude}" ]]; then
    say "  NOTE      no claude on PATH. The version of other claude binaries is not checked here."
    return 0
  fi
  version="$(claude_version_by_name "${path_claude}")"
  if [[ -z "${version}" ]]; then
    say "  NOTE      the version of ${path_claude} is not in its path. \"onFailure\": \"block\" needs ${MIN_ONFAILURE_VERSION} or newer. Check it with: claude --version"
  elif version_ge "${version}" "${MIN_ONFAILURE_VERSION}"; then
    say "  ok        claude on PATH: ${version} (\"onFailure\": \"block\" needs ${MIN_ONFAILURE_VERSION} or newer)"
  else
    say "  WARNING   claude on PATH: ${version} (${path_claude}). \"onFailure\": \"block\" needs ${MIN_ONFAILURE_VERSION} or newer."
    say "            In its sessions a tool call goes ahead when secret-guard cannot run. Update it: claude update"
    WARNINGS=$((WARNINGS + 1))
  fi
}

# Stop when a source file of this repo is missing (an incomplete checkout).
check_repo_files() {
  STEP="repo files"
  local file missing=""
  for file in ${HOOK_FILES} ${CONF_FILE}; do
    if [[ ! -f "${REPO_DIR}/hooks/${file}" ]]; then missing="${missing} hooks/${file}"; fi
  done
  for file in ${MOD_FILES}; do
    if [[ ! -f "${REPO_DIR}/local-mods/${file}" ]]; then missing="${missing} local-mods/${file}"; fi
  done
  if [[ ! -f "${SETTINGS_HELPER}" ]]; then missing="${missing} scripts/hooks_settings.py"; fi
  if [[ -n "${missing}" ]]; then
    die "files are missing in ${REPO_DIR}:${missing}"
  fi
}

# ---------------------------------------------------------------- preflight

# The checks that need no claude CLI and change nothing. --preflight runs only these.
preflight_basic() {
  STEP="preflight"
  local os tool missing="" bash_path
  os="$(uname -s)"
  case "${os}" in
    Linux|Darwin) ;;
    *) die "unsupported system: ${os}. Only Linux and macOS are supported." ;;
  esac

  for tool in ${HOOK_TOOLS} ${INSTALLER_TOOLS}; do
    if ! have "${tool}"; then missing="${missing} ${tool}"; fi
  done
  if ! have sha1sum && ! have shasum; then missing="${missing} sha1sum-or-shasum"; fi
  local reverse=""
  if have tac; then
    reverse="tac"
  elif [[ "$( (printf 'a\nb\n' | tail -r 2>/dev/null | head -n 1) || true)" == "b" ]]; then
    reverse="tail -r"
  else
    missing="${missing} tac-or-tail-r"
  fi
  if [[ -z "${STAT_KIND}" ]]; then missing="${missing} GNU-or-BSD-stat"; fi
  if [[ -n "${missing}" ]]; then
    die "missing tools:${missing}. Install them first (Ubuntu: sudo apt install <name>, macOS: brew install <name>)."
  fi
  if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    die "bash ${BASH_VERSION} is too old. bash 3.2 or newer is required."
  fi

  bash_path="$(type -P bash)"
  say "System:      ${os}, installer bash ${BASH_VERSION}, PATH bash ${bash_path}"
  if have sha1sum; then say "Tools:       sha1sum, ${reverse}, ${STAT_KIND} stat"; else say "Tools:       shasum, ${reverse}, ${STAT_KIND} stat"; fi
  say "Config dir:  ${CONFIG_DIR}"
  say "Hook path:   ${COMMAND_DIR}/hooks/<name>"

  # An unfinished live check of usage-limit.sh must be restored by hand first.
  local livecheck found=""
  for livecheck in "${HOOKS_DIR}/${CONF_FILE}".livecheck-*; do
    if [[ -e "${livecheck}" || -L "${livecheck}" ]]; then found="${found} ${livecheck}"; fi
  done
  if [[ -n "${found}" ]]; then
    die "an earlier live check of usage-limit.sh did not finish:${found}. Compare that file with ${HOOKS_DIR}/${CONF_FILE}, restore your settings, delete the livecheck file, and run the installer again."
  fi

  if [[ -L "${SETTINGS}" ]]; then
    die "${SETTINGS} is a symlink. The installer does not write through a symlink. Replace it with a regular file or register the hooks by hand."
  fi
  if [[ -e "${SETTINGS}" ]] && ! jq -e . "${SETTINGS}" >/dev/null 2>&1; then
    die "${SETTINGS} is not valid JSON."
  fi
  check_claude_bin_file
  say ""
  report_secret_guard
}

# The checks that start the claude CLI. Install mode only.
preflight_claude() {
  STEP="preflight"
  HOOKS_OFF=0
  ENDED_FILE=""
  ENDED_BEFORE=0
  # The claude CLI validates, tests and registers the mod.
  find_claude
  if [[ -z "${CLAUDE_BIN_USED}" ]]; then
    if [[ -n "${CLAUDE_SEEN}" ]]; then
      say "claude CLIs found (all older than ${MIN_CLAUDE_VERSION}):"
      printf '%s' "${CLAUDE_SEEN}"
    fi
    say "WARNING: no claude CLI ${MIN_CLAUDE_VERSION} or newer was found. The usage-feed step is skipped."
    say "         Hooks, usage-limit.conf and the registrations are still installed."
    say "         Install or update Claude Code (https://code.claude.com/docs/en/setup), or set CLAUDE_BIN, and run the installer again."
    say ""
    return 0
  fi
  say "claude CLI:  ${CLAUDE_VERSION_USED}  ${CLAUDE_BIN_USED}"

  # Does this CLI take the setting that turns hooks off? Ask with a read-only command.
  local probe
  if probe="$(run_claude --settings "${NO_HOOKS_SETTINGS}" plugin list --json 2>/dev/null)" \
    && jq -e 'type == "array"' >/dev/null 2>&1 <<EOF
${probe}
EOF
  then
    HOOKS_OFF=1
  else
    say "NOTE: this claude CLI does not take --settings for plugin commands. They run with hooks on."
  fi

  # Stop before any change when the marketplace or a plugin name is taken.
  local plugin
  for plugin in ${MOD_PLUGINS}; do
    use_plugin "${plugin}"
    read_plugin_state
    if [[ "${MARKET_STATE}" == "conflict" ]]; then
      die "a marketplace named ${MARKETPLACE} exists but does not point to ${MODS_DIR} (${MARKET_DETAIL}). Remove or rename it first."
    fi
    if [[ -n "${PLUGIN_OTHER}" ]]; then
      die "a plugin named ${PLUGIN_NAME} is installed from another marketplace: ${PLUGIN_OTHER}. Remove it first."
    fi
  done
  local live_market="${MODS_DIR}/.claude-plugin/marketplace.json"
  if [[ -f "${live_market}" ]] && ! cmp -s "${REPO_DIR}/local-mods/.claude-plugin/marketplace.json" "${live_market}"; then
    local others
    others="$(jq -r --arg mine " ${MOD_PLUGINS} " '[.plugins[]?.name | select(. as $n | ($mine | contains(" " + $n + " ")) | not)] | join(", ")' "${live_market}" 2>/dev/null || echo "?")"
    if [[ -n "${others}" ]]; then
      die "${live_market} lists other plugins (${others}). The installer does not replace it. Merge the file by hand."
    fi
  fi
  warn_second_copies
  say ""
}

# The test count that "claude plugin test" must report for one mod.
mod_expect() {
  case "$1" in
    usage-feed) echo "${EXPECT_MOD}" ;;
    oturum) echo "${EXPECT_MOD_OTURUM}" ;;
    *) echo "-1" ;;
  esac
}

# Set PLUGIN_NAME and PLUGIN_ID for one mod of MOD_PLUGINS.
use_plugin() {
  PLUGIN_NAME="$1"
  PLUGIN_ID="$1@${MARKETPLACE}"
}

# Read the marketplace and plugin lists of the claude CLI.
# Sets MARKET_STATE (ok, missing, conflict), MARKET_DETAIL, and for the mod that
# use_plugin chose: PLUGIN_STATE (enabled, disabled, missing), PLUGIN_FOLDER and PLUGIN_OTHER.
read_plugin_state() {
  local markets plugins source path
  if ! markets="$(run_claude plugin marketplace list --json 2>"${WORK}/claude.err")"; then
    sed 's/^/    /' "${WORK}/claude.err" >&2
    die "\"claude plugin marketplace list --json\" failed."
  fi
  if ! plugins="$(run_claude plugin list --json 2>"${WORK}/claude.err")"; then
    sed 's/^/    /' "${WORK}/claude.err" >&2
    die "\"claude plugin list --json\" failed."
  fi
  if ! printf '%s' "${markets}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die "\"claude plugin marketplace list --json\" did not print a JSON array."
  fi
  if ! printf '%s' "${plugins}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die "\"claude plugin list --json\" did not print a JSON array."
  fi

  MARKET_STATE="missing"
  MARKET_DETAIL=""
  if printf '%s' "${markets}" | jq -e --arg n "${MARKETPLACE}" 'any(.[]; .name == $n)' >/dev/null; then
    source="$(printf '%s' "${markets}" | jq -r --arg n "${MARKETPLACE}" '[.[] | select(.name == $n)][0].source // ""')"
    path="$(printf '%s' "${markets}" | jq -r --arg n "${MARKETPLACE}" '[.[] | select(.name == $n)][0] | (.path // .installLocation // "")')"
    if [[ "${source}" == "directory" ]] && same_dir "${path}" "${MODS_DIR}"; then
      MARKET_STATE="ok"
    else
      MARKET_STATE="conflict"
      MARKET_DETAIL="source ${source}, path ${path}"
    fi
  fi

  PLUGIN_OTHER="$(printf '%s' "${plugins}" | jq -r --arg id "${PLUGIN_ID}" --arg n "${PLUGIN_NAME}@" '[.[] | select((.id // "") | startswith($n)) | select(.id != $id) | .id] | unique | join(", ")')"
  PLUGIN_STATE="missing"
  PLUGIN_FOLDER=""
  if printf '%s' "${plugins}" | jq -e --arg id "${PLUGIN_ID}" 'any(.[]; .id == $id and .scope == "user")' >/dev/null; then
    if printf '%s' "${plugins}" | jq -e --arg id "${PLUGIN_ID}" 'any(.[]; .id == $id and .scope == "user" and .enabled == true)' >/dev/null; then
      PLUGIN_STATE="enabled"
    else
      PLUGIN_STATE="disabled"
    fi
    PLUGIN_FOLDER="$(printf '%s' "${plugins}" | jq -r --arg id "${PLUGIN_ID}" '[.[] | select(.id == $id and .scope == "user")][0].readFromFolder // ""')"
  fi
}

# Two loaded copies of the mod overwrite each other's history file. Only report them.
warn_second_copies() {
  local manifest name dirs dir
  if [[ -d "${CONFIG_DIR}/dev-mods" ]]; then
    while IFS= read -r manifest; do
      if [[ -z "${manifest}" ]]; then continue; fi
      name="$(jq -r '.name // ""' "${manifest}" 2>/dev/null || true)"
      if [[ -n "${name}" && " ${MOD_PLUGINS} " == *" ${name} "* ]]; then
        say "WARNING: a second copy of the ${name} mod: ${manifest}"
        note "WARNING: second copy of the ${name} mod: ${manifest}"
      fi
    done <<EOF
$(find "${CONFIG_DIR}/dev-mods" -maxdepth 6 -type f -path '*/.claude-plugin/plugin.json' 2>/dev/null || true)
EOF
  fi
  dirs="${CLAUDE_CODE_PLUGIN_DIRS:-}"
  if [[ -f "${SETTINGS}" ]]; then
    dirs="${dirs}:$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // ""' "${SETTINGS}" 2>/dev/null || true)"
  fi
  while IFS= read -r dir; do
    if [[ -z "${dir}" ]]; then continue; fi
    for manifest in "${dir}/.claude-plugin/plugin.json" "${dir}"/*/.claude-plugin/plugin.json; do
      if [[ ! -f "${manifest}" ]]; then continue; fi
      name="$(jq -r '.name // ""' "${manifest}" 2>/dev/null || true)"
      if [[ -z "${name}" ]] || same_dir "$(dirname "$(dirname "${manifest}")")" "${MODS_DIR}/${name}"; then continue; fi
      if [[ " ${MOD_PLUGINS} " == *" ${name} "* ]]; then
        say "WARNING: a second copy of the ${name} mod (CLAUDE_CODE_PLUGIN_DIRS): ${manifest}"
        note "WARNING: second copy of the ${name} mod: ${manifest}"
      fi
    done
  done <<EOF
$(printf '%s' "${dirs}" | tr ':' '\n')
EOF
}

# ---------------------------------------------------------------- hooks

# Run one test suite and check its result line "<label>: <n> pass, <m> fail".
# run_suite LABEL EXPECTED COMMAND...
run_suite() {
  local label="$1" expected="$2" log result pass fail rc=0
  shift 2
  log="${WORK}/suite-${label}.log"
  say "  running ${label} ..."
  "$@" > "${log}" 2>&1 || rc=$?
  result="$(grep -E "^${label}: [0-9]+ pass, [0-9]+ fail\$" "${log}" | tail -n 1 || true)"
  pass="$(printf '%s' "${result}" | sed -n 's/^.*: \([0-9][0-9]*\) pass, \([0-9][0-9]*\) fail$/\1/p')"
  fail="$(printf '%s' "${result}" | sed -n 's/^.*: \([0-9][0-9]*\) pass, \([0-9][0-9]*\) fail$/\2/p')"
  if [[ "${rc}" -ne 0 || -z "${result}" || "${fail}" != "0" || "${pass}" != "${expected}" ]]; then
    say "  ${label}: FAILED (exit code ${rc}, expected ${expected} pass and 0 fail). Last lines:"
    tail -n 70 "${log}" | sed 's/^/    /'
    SUITE_FAILED=1
    return 0
  fi
  say "  ${label}: ${pass}/${expected} pass"
  TEST_RESULTS="${TEST_RESULTS} ${label} ${pass}/${expected};"
}

# Build the fallback tool directory: symlinks to the listed tools only.
build_fallback_path() {
  local rbin="$1" tool path os
  os="$(uname -s)"
  mkdir -p "${rbin}"
  for tool in ${FALLBACK_TOOLS}; do
    # Take the system binary first, not a Homebrew or user copy.
    path="$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" type -P "${tool}" || true)"
    if [[ -z "${path}" ]]; then path="$(type -P "${tool}" || true)"; fi
    if [[ -z "${path}" ]]; then
      die "the fallback test run needs \"${tool}\", but it was not found."
    fi
    ln -s "${path}" "${rbin}/${tool}"
  done
  if [[ "${os}" == "Linux" ]]; then
    # GNU stat never takes the BSD branch and GNU tail has no -r: use the shims.
    rm -f "${rbin}/tail"
    cp "${STAGING}/tests/shims/stat" "${rbin}/stat"
    cp "${STAGING}/tests/shims/tail" "${rbin}/tail"
    chmod 755 "${rbin}/stat" "${rbin}/tail"
  else
    # macOS: BSD stat and tail -r are native. No shims.
    ln -s /usr/bin/stat "${rbin}/stat"
  fi
}

# Count the test lines in the real hook logs: the log of the config dir and,
# when it is another file, the log in ~/.claude.
count_test_lines() {
  local log count total=0 logs
  logs="${HOOKS_DIR}/context-pressure.log"
  if ! same_dir "${HOOKS_DIR}" "${HOME}/.claude/hooks"; then
    logs="${logs}"$'\n'"${HOME}/.claude/hooks/context-pressure.log"
  fi
  while IFS= read -r log; do
    if [[ -n "${log}" && -f "${log}" ]]; then
      count="$(grep -c -E 'hooktest|ultest' "${log}" || true)"
      total=$((total + count))
    fi
  done <<EOF
${logs}
EOF
  echo "${total}"
}

run_hook_tests() {
  local rbin bash32 path_version system_version before after
  SUITE_FAILED=0
  TEST_RESULTS=""
  before="$(count_test_lines)"

  say "Tests against the staging directory (several minutes):"
  run_suite normal-A "${EXPECT_A}" bash "${STAGING}/tests/run-tests.sh" "${STAGING}" normal-A
  run_suite normal-B "${EXPECT_B}" bash "${STAGING}/tests/run-ul-tests.sh" "${STAGING}" normal-B
  run_suite normal-SG "${EXPECT_SG}" python3 "${STAGING}/tests/run-sg-tests.py" "${STAGING}" normal-SG
  # secret-guard.py starts with "#!/usr/bin/env python3". When the python3 on PATH is not
  # /usr/bin/python3, test the system one too: another PATH can start the hook with it.
  if [[ -x /usr/bin/python3 && "$(type -P python3)" != "/usr/bin/python3" ]]; then
    run_suite system-SG "${EXPECT_SG}" /usr/bin/python3 "${STAGING}/tests/run-sg-tests.py" "${STAGING}" system-SG
  fi

  rbin="${WORK}/rbin"
  build_fallback_path "${rbin}"
  run_suite fallback-A "${EXPECT_A_FALLBACK}" env -i HOME="${HOME}" TMPDIR="${TMPDIR:-/tmp}" PATH="${rbin}" "${rbin}/bash" "${STAGING}/tests/run-tests.sh" "${STAGING}" fallback-A
  run_suite fallback-B "${EXPECT_B_FALLBACK}" env -i HOME="${HOME}" TMPDIR="${TMPDIR:-/tmp}" PATH="${rbin}" "${rbin}/bash" "${STAGING}/tests/run-ul-tests.sh" "${STAGING}" fallback-B

  if [[ "$(uname -s)" == "Darwin" ]]; then
    # The hooks start with "#!/usr/bin/env bash", so they run with the bash on PATH.
    path_version="$(bash -c 'echo "${BASH_VERSION}"')"
    system_version="$(/bin/bash -c 'echo "${BASH_VERSION}"')"
    if [[ "${path_version}" == "${system_version}" ]]; then
      say "  The bash on PATH is /bin/bash ${system_version}: the normal run is the bash 3.2 run."
    else
      bash32="${WORK}/bash32"
      mkdir -p "${bash32}"
      ln -s /bin/bash "${bash32}/bash"
      say "  The bash on PATH is ${path_version}. One more run with /bin/bash ${system_version} first on PATH:"
      run_suite bash32-A "${EXPECT_A}" env PATH="${bash32}:${PATH}" bash "${STAGING}/tests/run-tests.sh" "${STAGING}" bash32-A
      run_suite bash32-B "${EXPECT_B}" env PATH="${bash32}:${PATH}" bash "${STAGING}/tests/run-ul-tests.sh" "${STAGING}" bash32-B
    fi
  fi

  if [[ "${SUITE_FAILED}" -ne 0 ]]; then
    die "a test run failed. No installed file was changed. The staging directory is kept: ${STAGING}"
  fi
  after="$(count_test_lines)"
  if [[ "${after}" != "${before}" ]]; then
    die "the tests wrote to a real hook log (context-pressure.log in ${HOOKS_DIR} or ${HOME}/.claude/hooks: ${before} test lines before, ${after} after). No installed file was changed. The staging directory is kept: ${STAGING}"
  fi
  if [[ "${after}" != "0" ]]; then
    say "  WARNING: the real hook log held ${after} test lines before this run."
    note "WARNING: the real hook log holds ${after} old test lines (hooktest/ultest)"
  else
    say "  The real hook logs have no test lines."
  fi
}

# Set mode 755 on the managed directories that exist.
# fix_dir_modes LABEL BASE "DIRS"
fix_dir_modes() {
  local label="$1" base="$2" dirs="$3" dir path mode name
  for dir in ${dirs}; do
    if [[ "${dir}" == "." ]]; then path="${base}"; name="${label}"; else path="${base}/${dir}"; name="${label}/${dir}"; fi
    if [[ ! -d "${path}" || -L "${path}" ]]; then continue; fi
    mode="$(mode_of "${path}")"
    if [[ "${mode}" != "755" ]]; then
      chmod 755 "${path}"
      say "  mode fixed  ${name}/ (${mode} -> 755)"
      changed "${name}/: mode ${mode} -> 755"
    fi
  done
}

# Report the managed directories whose mode is not 755. Check mode.
check_dir_modes() {
  local label="$1" base="$2" dirs="$3" dir path mode name
  for dir in ${dirs}; do
    if [[ "${dir}" == "." ]]; then path="${base}"; name="${label}"; else path="${base}/${dir}"; name="${label}/${dir}"; fi
    if [[ ! -d "${path}" || -L "${path}" ]]; then continue; fi
    mode="$(mode_of "${path}")"
    if [[ "${mode}" != "755" ]]; then
      say "  mode ${mode} (want 755)  ${name}/"
      out_of_sync
    fi
  done
}

# Put the old files back after a failed move.
roll_back_hooks() {
  local entry file backup
  say "Restoring the files that were already replaced:"
  while IFS= read -r entry; do
    if [[ -z "${entry}" ]]; then continue; fi
    file="${entry%%|*}"
    backup="${entry#*|}"
    if [[ -n "${backup}" ]]; then
      if cp -p "${backup}" "${HOOKS_DIR}/${file}.restore.$$" && mv -f "${HOOKS_DIR}/${file}.restore.$$" "${HOOKS_DIR}/${file}"; then
        say "  restored    hooks/${file} from ${backup}"
      else
        say "  NOT RESTORED hooks/${file}. Its backup is ${backup}"
      fi
    else
      if rm -f "${HOOKS_DIR}/${file}"; then
        say "  removed     hooks/${file} (it did not exist before)"
      else
        say "  NOT REMOVED hooks/${file} (it did not exist before)"
      fi
    fi
  done <<EOF
${REPLACED}
EOF
}

install_hooks() {
  STEP="hooks"
  local file state mode need_stage=0 backup
  say "Hooks: ${HOOKS_DIR}"
  for file in ${HOOK_FILES}; do
    state="$(file_state "${REPO_DIR}/hooks/${file}" "${HOOKS_DIR}/${file}")"
    if [[ "${state}" != "same" ]]; then need_stage=1; fi
  done

  if [[ "${need_stage}" -eq 0 ]]; then
    for file in ${HOOK_FILES}; do
      mode="$(mode_of "${HOOKS_DIR}/${file}")"
      if [[ "${mode}" != "755" ]]; then
        chmod 755 "${HOOKS_DIR}/${file}"
        say "  mode fixed  hooks/${file} (${mode} -> 755)"
        changed "hooks/${file}: mode ${mode} -> 755"
      else
        say "  unchanged   hooks/${file}"
      fi
    done
  else
    # Running sessions call the installed scripts. Test the new files in a
    # staging directory on the same file system, then rename them into place.
    (umask 022 && mkdir -p "${HOOKS_DIR}")
    STAGING="${HOOKS_DIR}/.staging-${STAMP}"
    if [[ -e "${STAGING}" ]]; then
      die "the staging directory ${STAGING} exists already. Run the installer again in a moment."
    fi
    mkdir -m 700 "${STAGING}"
    mkdir -p "${STAGING}/tests/shims"
    say "  Staging directory: ${STAGING}"
    for file in ${HOOK_FILES}; do
      cp "${REPO_DIR}/hooks/${file}" "${STAGING}/${file}"
      chmod 755 "${STAGING}/${file}"
      if ! cmp -s "${REPO_DIR}/hooks/${file}" "${STAGING}/${file}"; then
        die "the staged copy of ${file} is not the same as the repo file."
      fi
      state="$(file_state "${REPO_DIR}/hooks/${file}" "${HOOKS_DIR}/${file}")"
      case "${state}" in
        same) state="unchanged" ;;
        missing) state="new" ;;
        differs) state="different" ;;
      esac
      printf '  staged      %-26s %6s bytes  %s  %s\n' "${file}" "$(size_of "${STAGING}/${file}")" "$(sha1_of "${STAGING}/${file}" | cut -c1-16)" "${state}"
    done

    run_hook_tests

    # Install. Every test run passed.
    (umask 022 && mkdir -p "${HOOKS_DIR}/tests/shims")
    # Check every backup name before the first file changes.
    for file in ${HOOK_FILES}; do
      state="$(file_state "${REPO_DIR}/hooks/${file}" "${HOOKS_DIR}/${file}")"
      if [[ "${state}" == "differs" ]]; then
        backup="$(backup_name "${HOOKS_DIR}/${file}")"
      fi
    done
    REPLACED=""
    for file in ${HOOK_FILES}; do
      state="$(file_state "${REPO_DIR}/hooks/${file}" "${HOOKS_DIR}/${file}")"
      if [[ "${state}" == "same" ]]; then
        mode="$(mode_of "${HOOKS_DIR}/${file}")"
        if [[ "${mode}" != "755" ]]; then
          chmod 755 "${HOOKS_DIR}/${file}"
          say "  mode fixed  hooks/${file} (${mode} -> 755)"
          changed "hooks/${file}: mode ${mode} -> 755"
        else
          say "  unchanged   hooks/${file}"
        fi
        continue
      fi
      backup=""
      if [[ "${state}" == "differs" ]]; then
        if ! backup="$(backup_name "${HOOKS_DIR}/${file}")" || ! cp -p "${HOOKS_DIR}/${file}" "${backup}"; then
          roll_back_hooks
          die "could not back up ${HOOKS_DIR}/${file}. The staging directory is kept: ${STAGING}"
        fi
      fi
      if ! mv -f "${STAGING}/${file}" "${HOOKS_DIR}/${file}"; then
        roll_back_hooks
        die "could not move ${file} into ${HOOKS_DIR}. The staging directory is kept: ${STAGING}"
      fi
      REPLACED="${REPLACED}${file}|${backup}"$'\n'
      if [[ -n "${backup}" ]]; then
        say "  replaced    hooks/${file} (backup: ${backup})"
        changed "hooks/${file}: backed up and replaced"
      else
        say "  written     hooks/${file}"
        changed "hooks/${file}: written"
      fi
    done
    # Delete the staging directory. The path is checked before the delete.
    case "${STAGING}" in
      "${HOOKS_DIR}"/.staging-*) rm -rf "${STAGING}" ;;
      *) die "unexpected staging path: ${STAGING}" ;;
    esac
    note "hook tests:${TEST_RESULTS}"
  fi

  fix_dir_modes "hooks" "${HOOKS_DIR}" "${HOOK_DIRS}"

  # The hooks keep their state here. Only the user may read it.
  if [[ ! -d "${HOOKS_DIR}/state" ]]; then
    mkdir -m 700 "${HOOKS_DIR}/state"
    say "  created     hooks/state (mode 700)"
    changed "hooks/state: created (mode 700)"
  else
    mode="$(mode_of "${HOOKS_DIR}/state")"
    if [[ "${mode}" != "700" ]]; then
      chmod 700 "${HOOKS_DIR}/state"
      say "  mode fixed  hooks/state (${mode} -> 700)"
      changed "hooks/state: mode ${mode} -> 700"
    fi
  fi
  say ""
}

# ---------------------------------------------------------------- usage-limit.conf

warn_old_conf_keys() {
  if grep -q -E '^(LIMIT_5H_PCT|LIMIT_WEEKLY_PCT)=' "$1"; then
    say "  WARNING: ${1} uses the old keys LIMIT_5H_PCT / LIMIT_WEEKLY_PCT."
    say "           usage-limit.sh reads STOP1_PCT and STOP2_PCT only. Replace the file by hand."
    note "WARNING: usage-limit.conf uses old keys (LIMIT_5H_PCT / LIMIT_WEEKLY_PCT)"
  fi
}

install_conf() {
  STEP="conf"
  local source="${REPO_DIR}/hooks/${CONF_FILE}" target="${HOOKS_DIR}/${CONF_FILE}" state mode temp
  say "Settings file of usage-limit.sh: ${target}"
  state="$(file_state "${source}" "${target}")"
  if [[ -L "${target}" ]]; then
    die "${target} is a symlink. The installer does not change it. Replace it with a regular file."
  fi
  case "${state}" in
    missing)
      temp="${HOOKS_DIR}/.${CONF_FILE}.new.$$"
      cp "${source}" "${temp}"
      chmod 600 "${temp}"
      mv -f "${temp}" "${target}"
      say "  written     hooks/${CONF_FILE} (mode 600)"
      changed "hooks/${CONF_FILE}: written"
      ;;
    same)
      say "  unchanged   hooks/${CONF_FILE}"
      ;;
    differs)
      # The file holds the user's own values. Never overwrite it.
      say "  kept        hooks/${CONF_FILE} (your settings differ from the repo default; not overwritten)"
      say "  Difference (< installed file, > repo default):"
      diff "${target}" "${source}" | sed 's/^/    /' || true
      warn_old_conf_keys "${target}"
      note "hooks/${CONF_FILE}: kept (differs from the repo default; user setting)"
      ;;
  esac
  mode="$(mode_of "${target}")"
  if [[ "${mode}" != "600" ]]; then
    chmod 600 "${target}"
    say "  mode fixed  hooks/${CONF_FILE} (${mode} -> 600)"
    changed "hooks/${CONF_FILE}: mode ${mode} -> 600"
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
  # Our commands: the current form, the "~" form and the absolute forms.
  # The helper compares the parsed settings and stops when a key outside
  # "hooks" would change.
  python3 "${SETTINGS_HELPER}" \
    --input "${WORK}/settings.in" --output "${WORK}/settings.out" --label "${SETTINGS}" \
    --current-dir "${COMMAND_DIR}" \
    --known-dir "~/.claude" --known-dir "${HOME}/.claude" --known-dir "${HOME_REAL}/.claude" --known-dir "${CONFIG_DIR}" \
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
  local status event script
  while read -r status event script; do
    if [[ -z "${status}" ]]; then continue; fi
    case "${status}" in
      ok) say "  unchanged   ${event}: ${script}" ;;
      added) say "  added       ${event}: ${script}" ;;
      normalized) say "  normalized  ${event}: ${script} (wrong form, wrong matcher, shared group or duplicate)" ;;
      extra)
        say "  NOTE        ${event}: ${script} is registered in an event the installer does not manage. Not changed."
        note "NOTE: ${script} is also registered under ${event} (not managed, not changed)"
        ;;
    esac
  done < "${WORK}/settings.report"
}

install_settings() {
  STEP="settings"
  local attempt=0 mode backup now_sha
  say "Registrations: ${SETTINGS}"
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
      mode="644"
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
      backup="$(backup_name "${SETTINGS}")"
      cp -p "${SETTINGS}" "${backup}"
    fi
    mv -f "${SETTINGS_TEMP}" "${SETTINGS}"
    SETTINGS_TEMP=""
    if [[ "${SETTINGS_EXISTED}" -eq 1 ]]; then
      say "  Difference of the \"hooks\" block (sorted keys; < before, > after):"
      jq -S '.hooks // {}' "${WORK}/settings.in" > "${WORK}/settings.in.hooks"
      jq -S '.hooks // {}' "${WORK}/settings.out" > "${WORK}/settings.out.hooks"
      diff "${WORK}/settings.in.hooks" "${WORK}/settings.out.hooks" | sed 's/^/    /' || true
      say "  All other keys are the same (compared as parsed JSON)."
    fi
    if [[ -n "${backup}" ]]; then
      say "  settings.json written (backup: ${backup})"
      changed "settings.json: hook registrations merged (backup: ${backup})"
    else
      say "  settings.json created"
      changed "settings.json: created with the hook registrations"
    fi
    say ""
    return 0
  done
}

# ---------------------------------------------------------------- usage-feed

# Copy the registration files to the backup directory before the first change.
backup_registration() {
  local file
  if [[ "${REG_BACKED_UP}" -eq 1 ]]; then return 0; fi
  if [[ ! -d "${MOD_BACKUP}" ]]; then mkdir -m 700 "${MOD_BACKUP}"; fi
  for file in "${SETTINGS}" "${CONFIG_DIR}/plugins/known_marketplaces.json" "${CONFIG_DIR}/plugins/installed_plugins.json"; do
    if [[ -f "${file}" ]]; then
      cp -p "${file}" "${MOD_BACKUP}/$(basename "${file}")"
    fi
  done
  REG_BACKED_UP=1
  say "  Backup of settings.json and the plugin lists: ${MOD_BACKUP}"
}

install_mod_files() {
  local file state mode need_stage=0 rc verdict
  for file in ${MOD_FILES}; do
    state="$(file_state "${REPO_DIR}/local-mods/${file}" "${MODS_DIR}/${file}")"
    if [[ "${state}" != "same" ]]; then need_stage=1; fi
  done

  if [[ "${need_stage}" -eq 0 ]]; then
    for file in ${MOD_FILES}; do
      mode="$(mode_of "${MODS_DIR}/${file}")"
      if [[ "${mode}" != "644" ]]; then
        chmod 644 "${MODS_DIR}/${file}"
        say "  mode fixed  local-mods/${file} (${mode} -> 644)"
        changed "local-mods/${file}: mode ${mode} -> 644"
      else
        say "  unchanged   local-mods/${file}"
      fi
    done
    return 0
  fi

  # Stage on the same file system, check the staged mod, then rename into place.
  MOD_STAGING="${CONFIG_DIR}/.staging-usage-feed-${STAMP}"
  if [[ -e "${MOD_STAGING}" ]]; then
    die "the staging directory ${MOD_STAGING} exists already. Run the installer again in a moment."
  fi
  mkdir -m 700 "${MOD_STAGING}"
  say "  Staging directory: ${MOD_STAGING}"
  for file in ${MOD_FILES}; do
    (umask 022 && mkdir -p "$(dirname "${MOD_STAGING}/${file}")")
    cp "${REPO_DIR}/local-mods/${file}" "${MOD_STAGING}/${file}"
    chmod 644 "${MOD_STAGING}/${file}"
    if ! cmp -s "${REPO_DIR}/local-mods/${file}" "${MOD_STAGING}/${file}"; then
      die "the staged copy of ${file} is not the same as the repo file."
    fi
    state="$(file_state "${REPO_DIR}/local-mods/${file}" "${MODS_DIR}/${file}")"
    case "${state}" in
      same) state="unchanged" ;;
      missing) state="new" ;;
      differs) state="different" ;;
    esac
    printf '  staged      %-40s %6s bytes  %s  %s\n' "${file}" "$(size_of "${MOD_STAGING}/${file}")" "$(sha1_of "${MOD_STAGING}/${file}" | cut -c1-16)" "${state}"
  done

  local plugin expect
  for plugin in ${MOD_PLUGINS}; do
    expect="$(mod_expect "${plugin}")"
    say "  running claude plugin validate (${plugin}) ..."
    rc=0
    run_claude plugin validate "${MOD_STAGING}/${plugin}" > "${WORK}/mod-validate-${plugin}.log" 2>&1 || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      sed 's/^/    /' "${WORK}/mod-validate-${plugin}.log"
      die "claude plugin validate failed for ${plugin} (exit code ${rc}). No installed file was changed. The staging directory is kept: ${MOD_STAGING}"
    fi
    verdict="$( (grep -E 'Validation passed' "${WORK}/mod-validate-${plugin}.log" | tail -n 1 | sed 's/^[^A-Za-z]*//') || true)"
    say "  validate (${plugin}): no errors (${verdict:-exit code 0})"

    say "  running claude plugin test (${plugin}) ..."
    rc=0
    run_claude plugin test "${MOD_STAGING}/${plugin}" > "${WORK}/mod-test-${plugin}.log" 2>&1 || rc=$?
    if [[ "${rc}" -ne 0 ]] \
      || ! grep -q -E "^ *${expect} pass\$" "${WORK}/mod-test-${plugin}.log" \
      || ! grep -q -E '^ *0 fail$' "${WORK}/mod-test-${plugin}.log"; then
      tail -n 60 "${WORK}/mod-test-${plugin}.log" | sed 's/^/    /'
      die "claude plugin test failed for ${plugin} (exit code ${rc}, expected ${expect} pass and 0 fail). No installed file was changed. The staging directory is kept: ${MOD_STAGING}"
    fi
    say "  test (${plugin}): ${expect}/${expect} pass"
    note "${plugin} checks: validate passed, test ${expect}/${expect}"
  done

  # The oturum mod runs bin/sessions.py with python3. Its own tests are Python unittest.
  say "  running python3 -m unittest (oturum/bin) ..."
  rc=0
  (cd "${MOD_STAGING}/oturum/bin" && python3 -B -m unittest discover -s . -p 'test_*.py') > "${WORK}/mod-unittest.log" 2>&1 || rc=$?
  if [[ "${rc}" -ne 0 ]] || ! grep -q -E "^Ran ${EXPECT_SESSIONS_PY} tests" "${WORK}/mod-unittest.log" \
    || ! grep -q -E '^OK' "${WORK}/mod-unittest.log"; then
    tail -n 40 "${WORK}/mod-unittest.log" | sed 's/^/    /'
    die "the oturum Python tests failed (exit code ${rc}, expected ${EXPECT_SESSIONS_PY} tests and OK). No installed file was changed. The staging directory is kept: ${MOD_STAGING}"
  fi
  say "  unittest (oturum): ${EXPECT_SESSIONS_PY}/${EXPECT_SESSIONS_PY} OK"

  # Install. Backups go to a directory outside the plugin folder: a stray file
  # inside the plugin folder would become part of the plugin.
  for file in ${MOD_FILES}; do
    state="$(file_state "${REPO_DIR}/local-mods/${file}" "${MODS_DIR}/${file}")"
    if [[ "${state}" == "same" ]]; then
      mode="$(mode_of "${MODS_DIR}/${file}")"
      if [[ "${mode}" != "644" ]]; then
        chmod 644 "${MODS_DIR}/${file}"
        say "  mode fixed  local-mods/${file} (${mode} -> 644)"
        changed "local-mods/${file}: mode ${mode} -> 644"
      else
        say "  unchanged   local-mods/${file}"
      fi
      continue
    fi
    if [[ "${state}" == "differs" ]]; then
      if [[ ! -d "${MOD_BACKUP}" ]]; then mkdir -m 700 "${MOD_BACKUP}"; fi
      mkdir -p "$(dirname "${MOD_BACKUP}/local-mods/${file}")"
      if [[ -e "${MOD_BACKUP}/local-mods/${file}" ]]; then
        die "the backup ${MOD_BACKUP}/local-mods/${file} exists already."
      fi
      cp -p "${MODS_DIR}/${file}" "${MOD_BACKUP}/local-mods/${file}"
    fi
    (umask 022 && mkdir -p "$(dirname "${MODS_DIR}/${file}")")
    if ! mv -f "${MOD_STAGING}/${file}" "${MODS_DIR}/${file}"; then
      die "could not move ${file} into ${MODS_DIR}. Files replaced before this one are new. Old copies are in ${MOD_BACKUP}. The staging directory is kept: ${MOD_STAGING}"
    fi
    if [[ "${state}" == "differs" ]]; then
      say "  replaced    local-mods/${file} (backup: ${MOD_BACKUP}/local-mods/${file})"
      changed "local-mods/${file}: backed up and replaced"
    else
      say "  written     local-mods/${file}"
      changed "local-mods/${file}: written"
    fi
  done
  case "${MOD_STAGING}" in
    "${CONFIG_DIR}"/.staging-usage-feed-*) rm -rf "${MOD_STAGING}" ;;
    *) die "unexpected staging path: ${MOD_STAGING}" ;;
  esac
}

# Fallback for a claude CLI that runs the plugin commands with hooks on:
# "claude plugin install" then starts the SessionEnd hook once, for the empty
# directory the installer works in. Remove only the state entry of that
# directory, and only when this run created it.
remove_own_session_end() {
  if [[ "${HOOKS_OFF}" -eq 1 || -z "${ENDED_FILE}" || "${ENDED_BEFORE}" -eq 1 ]]; then return 0; fi
  if [[ -f "${ENDED_FILE}" && ! -L "${ENDED_FILE}" ]]; then
    rm -f "${ENDED_FILE}"
    say "  NOTE: the SessionEnd hook ran once for the installer's own directory. Its state entry was removed."
    say "        One \"session-end\" line for ${WORK_REAL}/cwd stays in ${HOOKS_DIR}/context-pressure.log."
  fi
}

register_mod() {
  local did=0
  ENDED_FILE=""
  ENDED_BEFORE=0
  if [[ "${HOOKS_OFF}" -ne 1 ]]; then
    # session-end-mark.sh names the entry after the SHA-1 of the project path.
    ENDED_FILE="${HOOKS_DIR}/state/ended/$(sha1_16_of_text "${WORK_REAL}/cwd")"
    if [[ -e "${ENDED_FILE}" ]]; then ENDED_BEFORE=1; fi
  fi
  read_plugin_state
  if [[ "${MARKET_STATE}" == "conflict" ]]; then
    die "a marketplace named ${MARKETPLACE} does not point to ${MODS_DIR} (${MARKET_DETAIL})."
  fi

  if [[ "${MARKET_STATE}" == "missing" ]]; then
    backup_registration
    run_claude_change plugin marketplace add "${MODS_DIR}" || die "\"claude plugin marketplace add\" failed."
    remove_own_session_end
    say "  added       marketplace ${MARKETPLACE} -> ${MODS_DIR}"
    changed "marketplace ${MARKETPLACE}: added"
    did=1
  else
    say "  unchanged   marketplace ${MARKETPLACE}"
  fi

  local plugin
  for plugin in ${MOD_PLUGINS}; do
    use_plugin "${plugin}"
    read_plugin_state
    if [[ -n "${PLUGIN_OTHER}" ]]; then
      die "a plugin named ${PLUGIN_NAME} is installed from another marketplace: ${PLUGIN_OTHER}."
    fi
    if [[ "${PLUGIN_STATE}" == "missing" ]]; then
      backup_registration
      run_claude_change plugin install "${PLUGIN_ID}" --scope user || die "\"claude plugin install ${PLUGIN_ID}\" failed."
      remove_own_session_end
      say "  installed   plugin ${PLUGIN_ID} (scope user)"
      changed "plugin ${PLUGIN_ID}: installed (scope user)"
      did=1
    elif [[ "${PLUGIN_STATE}" == "disabled" ]]; then
      backup_registration
      run_claude_change plugin enable "${PLUGIN_ID}" || die "\"claude plugin enable ${PLUGIN_ID}\" failed."
      remove_own_session_end
      say "  enabled     plugin ${PLUGIN_ID}"
      changed "plugin ${PLUGIN_ID}: enabled"
      did=1
    else
      say "  unchanged   plugin ${PLUGIN_ID} (scope user, enabled)"
    fi
  done

  if [[ "${did}" -eq 0 ]]; then
    say "  marketplace and plugins unchanged"
  else
    # The claude commands may change only the keys of the mods and the marketplace.
    if ! python3 "${SETTINGS_HELPER}" --compare-plugins "${MOD_BACKUP}/settings.json" "${SETTINGS}"; then
      die "the claude plugin commands changed other keys of ${SETTINGS}. Compare it with ${MOD_BACKUP}/settings.json."
    fi
    say "  settings.json: only enabledPlugins of the mods and extraKnownMarketplaces.\"${MARKETPLACE}\" changed."
  fi
  # Check the result with the claude CLI, not with installed_plugins.json.
  for plugin in ${MOD_PLUGINS}; do
    use_plugin "${plugin}"
    read_plugin_state
    if [[ "${MARKET_STATE}" != "ok" || "${PLUGIN_STATE}" != "enabled" ]]; then
      die "after the registration, claude reports marketplace \"${MARKET_STATE}\" and plugin ${PLUGIN_ID} \"${PLUGIN_STATE}\". Expected \"ok\" and \"enabled\"."
    fi
    if [[ -n "${PLUGIN_FOLDER}" ]] && ! same_dir "${PLUGIN_FOLDER}" "${MODS_DIR}/${plugin}"; then
      die "claude reads the plugin ${PLUGIN_ID} from ${PLUGIN_FOLDER}, not from ${MODS_DIR}/${plugin}."
    fi
    if [[ -n "${PLUGIN_FOLDER}" ]]; then
      say "  claude reads ${PLUGIN_ID} from: ${PLUGIN_FOLDER}"
    fi
  done
}

install_usage_feed() {
  STEP="usage-feed"
  local before="${CHANGES}"
  if [[ -z "${CLAUDE_BIN_USED}" ]]; then
    # The claude CLI validates, tests and registers the mod. Without it, do nothing here.
    say "local mods (${MOD_PLUGINS}): skipped (no claude >= ${MIN_CLAUDE_VERSION})"
    say ""
    note "usage-feed: skipped (no claude >= ${MIN_CLAUDE_VERSION})"
    return 0
  fi
  MOD_BACKUP="${CONFIG_DIR}/backup-usage-feed-${STAMP}"
  REG_BACKED_UP=0
  say "local mods (${MOD_PLUGINS}): ${MODS_DIR}"
  if [[ -e "${MOD_BACKUP}" ]]; then
    die "the backup directory ${MOD_BACKUP} exists already. Run the installer again in a moment."
  fi
  install_mod_files
  fix_dir_modes "local-mods" "${MODS_DIR}" "${MOD_DIRS}"
  register_mod
  if [[ "${CHANGES}" -ne "${before}" ]]; then
    say "  Open sessions load the mod after /reload-plugins or a restart."
    note "usage-feed: open sessions load the mod after /reload-plugins or a restart"
  fi
  say ""
}

# ---------------------------------------------------------------- check mode

check_files() {
  local label="$1" source_dir="$2" target_dir="$3" want_mode="$4" files="$5" file state mode
  for file in ${files}; do
    state="$(file_state "${source_dir}/${file}" "${target_dir}/${file}")"
    if [[ "${state}" == "same" ]]; then
      mode="$(mode_of "${target_dir}/${file}")"
      if [[ "${mode}" != "${want_mode}" ]]; then
        say "  same, but mode ${mode} (want ${want_mode})  ${label}/${file}"
        out_of_sync
      else
        say "  same      ${label}/${file}"
      fi
    else
      if [[ -L "${target_dir}/${file}" ]]; then state="differs (symlink)"; fi
      say "  ${state}  ${label}/${file}"
      out_of_sync
    fi
  done
}

check_mode() {
  STEP="check"
  local missing="" tool state mode livecheck status event script
  for tool in jq python3 cmp diff; do
    if ! have "${tool}"; then missing="${missing} ${tool}"; fi
  done
  if ! have sha1sum && ! have shasum; then missing="${missing} sha1sum-or-shasum"; fi
  if [[ -z "${STAT_KIND}" ]]; then missing="${missing} GNU-or-BSD-stat"; fi
  if [[ -n "${missing}" ]]; then
    die "missing tools:${missing}."
  fi

  say "Check only. Nothing is changed."
  say "Config dir:  ${CONFIG_DIR}"
  say "Hook path:   ${COMMAND_DIR}/hooks/<name>"
  say ""

  say "Hooks: ${HOOKS_DIR}"
  check_files "hooks" "${REPO_DIR}/hooks" "${HOOKS_DIR}" 755 "${HOOK_FILES}"
  check_dir_modes "hooks" "${HOOKS_DIR}" "${HOOK_DIRS}"
  if [[ ! -d "${HOOKS_DIR}/state" ]]; then
    say "  missing   hooks/state (directory, mode 700)"
    out_of_sync
  else
    mode="$(mode_of "${HOOKS_DIR}/state")"
    if [[ "${mode}" != "700" ]]; then
      say "  mode ${mode} (want 700)  hooks/state"
      out_of_sync
    fi
  fi
  for livecheck in "${HOOKS_DIR}/${CONF_FILE}".livecheck-*; do
    if [[ -e "${livecheck}" || -L "${livecheck}" ]]; then
      say "  STOP      an unfinished live check: ${livecheck} (the installer stops until it is restored)"
      out_of_sync
    fi
  done
  for livecheck in "${HOOKS_DIR}"/.staging-*; do
    if [[ -e "${livecheck}" ]]; then
      say "  NOTE      a leftover staging directory: ${livecheck}"
    fi
  done
  say ""

  say "Settings file of usage-limit.sh: ${HOOKS_DIR}/${CONF_FILE}"
  state="$(file_state "${REPO_DIR}/hooks/${CONF_FILE}" "${HOOKS_DIR}/${CONF_FILE}")"
  case "${state}" in
    missing)
      say "  missing   hooks/${CONF_FILE}"
      out_of_sync
      ;;
    same)
      say "  same      hooks/${CONF_FILE}"
      ;;
    differs)
      # The installer keeps a different file, so this is not counted as out of sync.
      say "  differs   hooks/${CONF_FILE} (a user setting: the installer keeps it)"
      say "  Difference (< installed file, > repo default):"
      diff "${HOOKS_DIR}/${CONF_FILE}" "${REPO_DIR}/hooks/${CONF_FILE}" | sed 's/^/    /' || true
      ;;
  esac
  if [[ -L "${HOOKS_DIR}/${CONF_FILE}" ]]; then
    say "  STOP      hooks/${CONF_FILE} is a symlink (the installer stops)"
    out_of_sync
  elif [[ "${state}" != "missing" ]]; then
    mode="$(mode_of "${HOOKS_DIR}/${CONF_FILE}")"
    if [[ "${mode}" != "600" ]]; then
      say "  mode ${mode} (want 600)  hooks/${CONF_FILE}"
      out_of_sync
    fi
  fi
  say ""

  say "Registrations: ${SETTINGS}"
  if [[ -L "${SETTINGS}" ]]; then
    say "  STOP      settings.json is a symlink (the installer stops)"
    out_of_sync
  fi
  if [[ -e "${SETTINGS}" ]] && ! jq -e . "${SETTINGS}" >/dev/null 2>&1; then
    say "  STOP      settings.json is not valid JSON"
    out_of_sync
  else
    build_settings
    while read -r status event script; do
      case "${status}" in
        ok) say "  ok (exactly once)   ${event}: ${script}" ;;
        added) say "  missing             ${event}: ${script}" ;;
        normalized) say "  not correct         ${event}: ${script} (wrong form, wrong matcher, shared group or duplicate)" ;;
        extra) say "  NOTE                ${event}: ${script} is registered in an event the installer does not manage" ;;
      esac
    done < "${WORK}/settings.report"
    if [[ "${SETTINGS_RESULT}" != "unchanged" ]]; then
      out_of_sync
    fi
  fi
  say ""

  report_secret_guard
  say ""

  # --check never starts the claude CLI: a logged-in claude refreshes its own
  # cache files in the config dir. Whether a usable CLI exists is read from the
  # paths of the binaries. The registration is read from the files.
  local usable mod_present=0 file extra known leftover
  usable="$(claude_usable_by_name)"
  for file in ${MOD_FILES}; do
    if [[ -e "${MODS_DIR}/${file}" || -L "${MODS_DIR}/${file}" ]]; then mod_present=1; fi
  done
  if [[ -e "${MODS_DIR}/usage-feed" || -L "${MODS_DIR}/usage-feed" ]]; then mod_present=1; fi
  if [[ -n "${CLAUDE_BIN:-}" ]] && [[ ! -f "${CLAUDE_BIN}" || ! -x "${CLAUDE_BIN}" ]]; then
    say "local mods (${MOD_PLUGINS}): ${MODS_DIR}"
    say "  STOP      CLAUDE_BIN is set, but it is not an executable file: ${CLAUDE_BIN} (the installer stops)"
    out_of_sync
  elif [[ "${usable}" == "no" && "${mod_present}" -eq 0 ]]; then
    # The installer skips the mod on this machine, so a missing mod is not out of sync.
    say "local mods (${MOD_PLUGINS}): skipped (no claude >= ${MIN_CLAUDE_VERSION})"
    say "  NOTE      The mod is not installed. The installer skips it until a claude CLI ${MIN_CLAUDE_VERSION} or newer exists."
  else
    say "local mods (${MOD_PLUGINS}): ${MODS_DIR}"
    check_files "local-mods" "${REPO_DIR}/local-mods" "${MODS_DIR}" 644 "${MOD_FILES}"
    check_dir_modes "local-mods" "${MODS_DIR}" "${MOD_DIRS}"
    local reg_ok=1 market_path plugin
    for plugin in ${MOD_PLUGINS}; do
      use_plugin "${plugin}"
      if [[ -f "${SETTINGS}" ]] && jq -e --arg id "${PLUGIN_ID}" '.enabledPlugins[$id] == true' "${SETTINGS}" >/dev/null 2>&1; then
        say "  ok        settings.json: enabledPlugins.\"${PLUGIN_ID}\" is true"
      else
        say "  missing   settings.json: enabledPlugins.\"${PLUGIN_ID}\" is not true"
        reg_ok=0
      fi
    done
    market_path=""
    if [[ -f "${SETTINGS}" ]]; then
      market_path="$(jq -r --arg m "${MARKETPLACE}" '.extraKnownMarketplaces[$m].source | select(.source == "directory") | .path // ""' "${SETTINGS}" 2>/dev/null || true)"
    fi
    if [[ -z "${market_path}" ]]; then
      say "  missing   settings.json: extraKnownMarketplaces.\"${MARKETPLACE}\" (a directory source)"
      reg_ok=0
    elif same_dir "${market_path}" "${MODS_DIR}"; then
      say "  ok        settings.json: marketplace ${MARKETPLACE} -> ${market_path}"
    else
      say "  STOP      settings.json: marketplace ${MARKETPLACE} points to another place: ${market_path}"
      reg_ok=0
    fi
    for plugin in ${MOD_PLUGINS}; do
      use_plugin "${plugin}"
      if [[ -f "${CONFIG_DIR}/plugins/installed_plugins.json" ]] && jq -e --arg id "${PLUGIN_ID}" '.plugins[$id] // [] | any(.[]; .scope == "user")' "${CONFIG_DIR}/plugins/installed_plugins.json" >/dev/null 2>&1; then
        say "  ok        plugins/installed_plugins.json: ${PLUGIN_ID} (scope user)"
      else
        say "  missing   plugins/installed_plugins.json: ${PLUGIN_ID} (scope user)"
        reg_ok=0
      fi
    done
    if [[ "${reg_ok}" -eq 0 ]]; then out_of_sync; fi
    say "  NOTE      The registration is read from files. The installer confirms it with \"claude plugin list\"."
    if [[ "${usable}" == "no" ]]; then
      say "  NOTE      No claude CLI ${MIN_CLAUDE_VERSION} or newer was found by its path. The installer would skip this step."
    fi
  fi
  # Notes only. --check and the installer never delete these.
  known=""
  for file in ${MOD_FILES}; do known="${known}${MODS_DIR}/${file}"$'\n'; done
  local mod_name
  for mod_name in ${MOD_PLUGINS}; do
    if [[ ! -d "${MODS_DIR}/${mod_name}" ]]; then continue; fi
    while IFS= read -r extra; do
      if [[ -z "${extra}" ]]; then continue; fi
      if ! grep -q -F -x -- "${extra}" <<EOF
${known}
EOF
      then
        say "  NOTE      an extra file in the plugin folder (claude loads the whole folder): ${extra}"
      fi
    done <<EOF
$(find "${MODS_DIR}/${mod_name}" \( -type f -o -type l \) 2>/dev/null | sort || true)
EOF
  done
  for leftover in "${CONFIG_DIR}"/.staging-usage-feed-*; do
    if [[ -e "${leftover}" ]]; then
      say "  NOTE      a leftover staging directory: ${leftover}"
    fi
  done
  for leftover in "${CONFIG_DIR}"/backup-usage-feed-*; do
    if [[ -d "${leftover}" && -z "$(ls -A "${leftover}" 2>/dev/null || true)" ]]; then
      say "  NOTE      an empty backup directory: ${leftover}"
    fi
  done
  say ""

  if [[ "${WARNINGS}" -gt 0 ]]; then
    say "Warnings: ${WARNINGS} (see above). The installer does not fix them."
  fi
  if [[ "${OUT_OF_SYNC}" -eq 0 ]]; then
    say "Result: in sync. The installer would change nothing."
    exit 0
  fi
  say "Result: NOT in sync (${OUT_OF_SYNC} items). Run scripts/install_hooks.sh to fix it."
  exit 1
}

# ---------------------------------------------------------------- main

main() {
  parse_args "$@"
  check_repo_files
  detect_stat
  resolve_config
  if [[ "${MODE}" == "preflight" ]]; then
    say "Preflight only. Nothing is changed. The claude CLI is not started."
    preflight_basic
    say ""
    say "Preflight passed."
    return 0
  fi

  # Local time, like the names of the earlier backups (<name>.bak-20261113).
  STAMP="$(date +%Y%m%dT%H%M%S)"
  DAY="${STAMP%%T*}"
  local temp_root="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${temp_root%/}/install-hooks.XXXXXX")"
  WORK_REAL="$(resolve_dir "${WORK}")"
  # The claude commands run in an empty directory, so no project settings apply.
  mkdir "${WORK}/cwd"

  if [[ "${MODE}" == "check" ]]; then
    check_mode
  fi

  preflight_basic
  preflight_claude
  install_hooks
  install_conf
  install_settings
  install_usage_feed

  STEP="summary"
  say "Summary"
  if [[ -n "${SUMMARY}" ]]; then printf '%s' "${SUMMARY}"; fi
  if [[ "${CHANGES}" -eq 0 ]]; then
    if [[ -z "${CLAUDE_BIN_USED}" ]]; then
      say "  Nothing changed. The installed hooks are the same as the repo. The usage-feed mod was not checked."
    else
      say "  Nothing changed. The installed hooks and the usage-feed mod are the same as the repo."
    fi
  else
    say "  Changes: ${CHANGES}. Running sessions use changed hooks at their next tool batch."
  fi
  if [[ "${WARNINGS}" -gt 0 ]]; then
    say "  Warnings: ${WARNINGS}. See the secret-guard part of the preflight above. The installer does not fix them."
  fi
  say "  Note: context-pressure.sh warns at 300000 tokens (CTX_PRESSURE_THRESHOLD). That fits a 1M context window."
}

# One line: bash has read the "exit" before main starts, so a change of this
# file during the run (git pull) cannot make bash run new text after main.
main "$@"; exit $?
