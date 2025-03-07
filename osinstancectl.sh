#!/bin/bash

# Manage dockerized OpenSlides instances
#
# -------------------------------------------------------------------
# Copyright (C) 2019 by Intevation GmbH
# Author(s):
# Gernot Schulz <gernot@intevation.de>
# Adrian Richter <adrian@intevation.de>
#
# This program is distributed under the MIT license, as described
# in the LICENSE file included with the distribution.
# SPDX-License-Identifier: MIT
# -------------------------------------------------------------------

set -eu
set -o noclobber
set -o pipefail

# Defaults (override in $CONFIG)
INSTANCES="/srv/openslides/os4-instances"
COMPOSE_TEMPLATE=
CONFIG_YML_TEMPLATE="/etc/osinstancectl.d/config.yml.template"
HOOKS_DIR=
MANAGEMENT_TOOL_BINDIR="/usr/local/lib/openslides-manage/versions"
HAPROXYCFG="/etc/haproxy/haproxy.cfg"

# Legacy instances path
OS3_INSTANCES="/srv/openslides/docker-instances"

# constants
CONFIG="/etc/osinstancectl.d/os4instancectlrc"
ME=$(basename -s .sh "${BASH_SOURCE[0]}")
PIDFILE="/tmp/osinstancectl.pid"
MARKER=".osinstancectl-marker"
LOCKFILE=".osinstancectl-locks"
DEFAULT_MANAGEMENT_VERSION=latest
MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${DEFAULT_MANAGEMENT_VERSION}"
ADMIN_SECRETS_FILE="superadmin"
USER_SECRETS_FILE="user.yml"
DB_SECRETS_FILE="postgres_password"
MANAGEMENT_BACKEND=backendManage
MIGRATIONS_STATUS_NOT_REQ=no_migration_required
MIGRATIONS_STATUS_REQ=migration_required
MIGRATIONS_STATUS_FIN_REQ=finalization_required
MIGRATIONS_STATUS_RUN=migration_running
CURL_OPTS=(--max-time 1 --retry 2 --retry-delay 1 --retry-max-time 3)
ALLOWED_LOCK_ACTIONS="autoscale clone erase remove start stop update"

# global variables
PROJECT_NAME=
PROJECT_DIR=
PROJECT_STACK_NAME=
PORT=
DEPLOYMENT_MODE=
MODE=
USAGE=
DOCKER_IMAGE_TAG_OPENSLIDES=
OPT_MIGRATIONS_FINALIZE=
OPT_MIGRATIONS_ASK=1
OPT_ADD_ACCOUNT=1
OPT_DRY_RUN=
OPT_FAST=
OPT_FORCE=
OPT_JSON=
OPT_LOCALONLY=
OPT_LOCK_ACTION=()
OPT_LOG=${OPT_LOG:-1}
OPT_LONGLIST=
OPT_MANAGEMENT_TOOL=
OPT_METADATA=
OPT_METADATA_SEARCH=
OPT_PATIENT=
OPT_PIDFILE=1
OPT_SECRETS=
OPT_SERVICES=
OPT_STATS=
OPT_USE_PARALLEL="${OPT_USE_PARALLEL:-1}"
OPT_VERBOSE=0
FILTER_RUNNING_STATE=
FILTER_LOCKED_STATE=
FILTER_VERSION=
CLONE_FROM=
LEGAL_NOTICE_FILE=
PRIVACY_POLICY_FILE=
OPENSLIDES_USER_FIRSTNAME=
OPENSLIDES_USER_LASTNAME=
OPENSLIDES_USER_EMAIL=
OPENSLIDES_USER_PASSWORD=
OPT_PRECISE_PROJECT_NAME=
HAS_DOCKER_ACCESS=
HAS_MANAGEMENT_ACCESS=

# Scale related
declare -A SCALE_FROM=()
declare -A SCALE_TO=()
declare -A SCALE_RUNNING=()
MEETINGS_TODAY=
ACCOUNTS_TODAY=
ACCOUNTS=
AUTOSCALE_ACCOUNTS_OVER=
AUTOSCALE_RESET_ACCOUNTS_OVER=

# Color and formatting settings
OPT_COLOR=auto
NCOLORS=
COL_NORMAL=""
COL_RED=""
COL_YELLOW=""
COL_GREEN=""
BULLET='●'
SYM_NORMAL="OK"
SYM_ERROR="XX"
SYM_UNKNOWN="??"
SYM_STOPPED="__"
JQ="jq --monochrome-output"

DEPS=(
  docker
  gawk
  jq
  nc
  yq
)

enable_color() {
  NCOLORS=$(tput colors) # no. of colors
  if [[ -n "$NCOLORS" ]] && [[ "$NCOLORS" -ge 8 ]]; then
    COL_NORMAL="$(tput sgr0)"
    COL_RED="$(tput setaf 1)"
    COL_YELLOW="$(tput setaf 3)"
    COL_GREEN="$(tput setaf 2)"
    COL_GRAY="$(tput bold; tput setaf 0)"
    JQ="jq --color-output"
  fi
}

usage() {
cat <<EOF
Usage: $ME [options] <action> <instance|pattern>

Manage OpenSlides Docker instances.

Actions:
  ls                   List instances and their status.  <pattern> is
                       a grep ERE search pattern in this case.  For details on
                       the output format, see below.
  add                  Add a new instance for the given domain (requires FQDN)
  rm                   Remove <instance> (requires FQDN)
  start                Start, i.e., (re)deploy an existing instance
  stop                 Stop a running instance
  update               Update OpenSlides services to a new version
  erase                Execute the mid-erase hook without otherwise removing
                       the instance.
  lock                 Put a lock on the instance which prohibits one or more
                       actions from being executed for the instance.
  unlock               Remove locks from an instance.
  autoscale            Scale relevant services of an instance based on it's
                       meetings dates and users. Will only scale down if there
                       no meeting scheduled for today.
                       (adjust values in CONFIG file)
  manage               Call the openslides-manage tool on an instance.
                       See the tool's help message for details on its usage.
                       All args ond opts that are to be passed to the tool
                       should be stated after a '--'.
                       If the management command is more than one word it must be
                       quoted, e.g. 'migrations stats'.
  setup                Run basic setup steps for $ME interactively.
  help <action>        Print detailed usage information for the given action.

Options:
  -d,
  --project-dir=DIR    Directly specify the project directory
  --compose-template=FILE  Specify the docker-compose YAML template
  --config-template=FILE   Specify the config.yml template
  --force              Disable various safety checks
  --color=WHEN         Enable/disable color output.  WHEN is never, always, or
                       auto.
  --verbose            Increase output verbosity (may be repeated)
  --help               Display this help message and exit

EOF
case "${HELP_TOPIC:-}" in
  list)
    cat << EOF

  for ls:
    -a, --all          Equivalent to --long --secrets --metadata --services
                       --stats
    -l, --long         Include more information in extended listing format
    -s, --secrets      Include sensitive information such as login credentials
    -m, --metadata     Include metadata in instance list
    --services         Include list of services in instance list
    --stats            Include addtional information from running instances,
                       e.g., meetings details
    -n, --online       Show only online instances
    -f, --offline      Show only stopped instances
    -e, --error        Show only running but unreachable instances
    --locked           Show only locked instances (see \`lock\`/\`unlock\` modes)
    --unlocked         Show only unlocked instances (see \`lock\`/\`unlock\` modes)
    -M,
    --search-metadata  Include metadata
    --fast             Include less information to increase listing speed
    --patient          Increase timeouts
    --version=REGEXP   Filter results based on the version reported by
                       \`$ME ls\` (not --long; implies --online).
    -j, --json         Enable JSON output format

The ls output:

  The columnar output lists each instance's status, name, version(s) and
  an optional comment.

  Colored status indicators:
    green              The instance appears to be fully functional
    red                The instance is running but is unreachable
    yellow             The instance's status can not be determined
    gray               The instance has been stopped

  Version information in ls mode:
    Both the instances own version string (simple) as well as the container
    image versions (complex) can be displayed.  The available information
    depends on the user's access permissions to Docker.

    - Complex: This version is based on the Docker image versions actually in
      use.  Normally, this is a single tag; however, in case there is more than
      one tag in use, the display format is extended to include more detail.
      It lists each tag with the number of containers running this tag,
      separated by slashes, as well as a final sum of the number of different
      registries and tags in square brackets, e.g., "[1:2]".  In the --long
      output format this version is listed as "Version".  If available, it
      takes precedence over the simple version string and is used for the
      compact ls output.
    - Simple:  This version simply reports the version string that has been
      built into the image.  It is available under most circumstances.  In the
      --long output format, it is listed as "Version (image)" (and also as
      "Version" if the complex version string is unavailable).

  Stats in ls mode:
    - Meetings:         active/max. number of meetings
    - List of meetings: ID, name, dates, Jitsi configuration of each meeting
    - Users:            active/total/max. number of users
EOF
;;
  start)
    cat << EOF

  for start:
    -O, --management-tool=[PATH|NAME|*|-]
                       Specify the 'openslides' executable to use.  The program
                       must be available in the management tool's versions
                       directory [${MANAGEMENT_TOOL_BINDIR}/].
                       If only a file NAME is given, it is assumed to be
                       relative to that directory.
                       The special string "*" indicates that no version is to
                       be recorded which will always cause the latest version
                       to be selected.  The special string "-" indicates that
                       the version is to remain unchanged.
                       [Default: ${DEFAULT_MANAGEMENT_VERSION}]
    --migrations-finalize  Immediately finalize required migrations and do the
                       full instance update as soon as possible.
    --migrations-no-ask  Do not ask for confirmations when handling migrations.
EOF
;;
  create | update)
    cat << EOF

  for add & update:
    -t, --tag=TAG      Specify the default image tag for all OpenSlides
                       components (defaults.tag).
    -O, --management-tool=[PATH|NAME|*|-]
                       Specify the 'openslides' executable to use.  The program
                       must be available in the management tool's versions
                       directory [${MANAGEMENT_TOOL_BINDIR}/].
                       If only a file NAME is given, it is assumed to be
                       relative to that directory.
                       The special string "*" indicates that no version is to
                       be recorded which will always cause the latest version
                       to be selected.  The special string "-" indicates that
                       the version is to remain unchanged.
                       [Default: ${DEFAULT_MANAGEMENT_VERSION}]
    --local-only       Create an instance without setting up HAProxy and Let's
                       Encrypt certificates.  Such an instance is only
                       accessible on localhost, e.g., http://127.0.0.1:61000.
    --migrations-finalize  Immediately finalize required migrations and do the
                       full instance update as soon as possible.
    --migrations-no-ask  Do not ask for confirmations when handling migrations.
    --no-add-account   Do not add an additional, customized local admin account.
    --clone-from       Create the new instance based on the specified existing
                       instance.
EOF
;;
  autoscale)
    cat << EOF

  for autoscale:
    --accounts=NUM     Specify the number of accounts to scale for overriding
                       read from metadata.txt
    --dry-run          Print out actions instead of actually performing them
EOF
;;
  lock | unlock)
    cat << EOF
  for lock & unlock:
    --action=ACTION    Specify a specific action to lock instead of all
                       actions.  Available actions are:
                       ${ALLOWED_LOCK_ACTIONS}
EOF
;;
  *)
    cat << EOF
Use $ME help <action> for details.
EOF
;;
esac
}

fatal() {
  echo 1>&2 "${COL_RED}ERROR${COL_NORMAL}: $*"
  exit 23
}

warn() {
  echo 1>&2 "${COL_RED}WARN${COL_NORMAL}: $*"
}

info() {
  echo 1>&2 "${COL_GREEN}INFO${COL_NORMAL}: $*"
}

verbose() {
  local lvl=$1
  shift
  [[ "$OPT_VERBOSE" -ge 1 ]] || return 0
  [[ "$lvl" -le "$OPT_VERBOSE" ]] || return 0
  echo 1>&2 "${COL_GREEN}DEBUG${lvl}${COL_NORMAL}: $*"
}

tag_output() {
  local prefix=${1:-EXT}
  stdbuf -oL sed "s/^/${COL_YELLOW}${prefix}${COL_NORMAL}: /"
}

clean_up() {
  # Clean up the PID file (only if it is this process' own PID file)
  local pid logname email
  if [[ -f "$PIDFILE" ]] && read -r pid logname email < "$PIDFILE" && [[ $pid -eq $$ ]]
  then
    # Truncate file; should always work (has mode 666)
    >| "$PIDFILE"
    # Delete file; may fail if it is a stale file created by another user
    rm -f "$PIDFILE" >/dev/null 2>&1 || true
  fi
}

create_and_check_pid_file() {
  # Create PID file in /tmp/, so all users may create them without requiring
  # any additional measures, e.g., for /var/run/.  The sticky bit commonly set
  # on /tmp/ requires the PID file mechanism to handle circumstances in which
  # even a stale file can not be removed.
  local pid logname email by message
  if [[ -f "$PIDFILE" ]]; then
    read -r pid logname email < "$PIDFILE"
    by=$logname
    [[ -z "$email" ]] || by="${logname} [${email}]"
    message="$ME is already being executed by ${by} (PID: ${pid}, PID file: ${PIDFILE})"
    if ps p "$pid" >/dev/null 2>&1; then
      if [[ -n "$OPT_PIDFILE" ]]; then
        fatal "$message"
      else
        warn "$message"
        warn "continuing anyways (--no-pid-file)"
      fi
    else
      warn "Stale PID file detected."
      if [[ -n "$OPT_PIDFILE" ]]; then
        warn "overwriting"
      else
        warn "ignoring (--no-pid-file)"
      fi
    fi
  elif [[ -z "$OPT_PIDFILE" ]]; then
    return 0
  else
    # Create the file and allow other users to update it
    touch "$PIDFILE"
    chmod 666 "$PIDFILE"
  fi
  echo "$$ ${LOGNAME:-"unknown"} ${EMAIL:-}" >| "$PIDFILE"
}

check_for_dependency () {
    [[ -n "$1" ]] || return 0
    command -v "$1" > /dev/null
}

arg_check() {
  case "$MODE" in
    # Mode-dependent dependency check
    "setup") :;;
    *)
      for i in "${DEPS[@]}"; do
          check_for_dependency "$i" || fatal "Dependency not found: $i"
      done
      ;;
  esac
  [[ -d "$INSTANCES" ]] || { fatal "$INSTANCES not found!"; }
  # Commands that work without a specific instance argument
  case "$MODE" in
    "list") :;;
    *)
      [[ -n "$PROJECT_NAME" ]] || { fatal "Please specify a project name"; return 2; }
      ;;
  esac
  case "$MODE" in
    "start" | "stop" | "remove" | "erase" | "update" | "autoscale" | "create")
      [[ "$HAS_DOCKER_ACCESS" ]] ||
        fatal "User $USER does not have access to the Docker daemon.  See \`docker info\`."
      ;;
  esac
  case "$MODE" in
    "start" | "stop" | "remove" | "erase" | "update" | "autoscale" | "manage" | "lock" | "unlock")
      [[ -d "$PROJECT_DIR" ]] || {
        fatal "Instance '${PROJECT_NAME}' not found."
      }
      [[ -f "${DCCONFIG}" ]] || {
        fatal "Not a ${DEPLOYMENT_MODE} instance."
      }
      ;;
  esac
  case "$MODE" in
    "create" | "clone")
      [[ ! -d "$PROJECT_DIR" ]] || {
        fatal "Instance '${PROJECT_NAME}' already exists."
      }
      [[ ! -d "${OS3_INSTANCES}/${PROJECT_NAME}" ]] || {
        fatal "Instance '${PROJECT_NAME}' already exists as an OpenSlides 3 instance."
      }
      ;;
  esac
  case "$MODE" in
    "clone")
      [[ -d "$CLONE_FROM_DIR" ]] || {
        fatal "$CLONE_FROM_DIR does not exist."
      }
      ;;
  esac
  case "$MODE" in
    "lock" | "unlock")
      for i in "${OPT_LOCK_ACTION[@]}"; do
        grep -qw "$i" <<< "$ALLOWED_LOCK_ACTIONS" ||
          fatal "Unknown action: ${i}."
      done
  esac
}

log_output() {
  dir=$1
  if [[ "$OPT_LOG" -eq 1 ]]; then
    mkdir -p "${dir}/log"
    tee "${dir}/log/${MODE}-$(date "+%F.%s").log"
  else
    cat -
  fi
}

marker_check() {
  [[ -f "${1}/${MARKER}" ]] || {
    fatal "The instance was not created with $ME."
    return 1
  }
}

self_setup() {
  local setup_with_errors=0
  local n=0
  check_ok() {
    echo "    ${COL_GREEN}✓${COL_NORMAL} $*"
  }
  check_fail() {
    echo "    ${COL_RED}✗${COL_NORMAL} $*"
    setup_with_errors=1
  }
  printf "\n——— $ME setup assistant ———\n\n"
  cat << EOF | tr '\n' ' ' | fold -s
This command assists you in creating the basic setup required for OpenSlides 4
deployments with $ME.  Please note, however, that this is not a fully automated
setup procedure and that additional steps will be required.
EOF
printf '\n\n'
  [[ ! -f "$CONFIG" ]] || {
    info "Applying settings from $CONFIG."
    echo
  }
  echo " $((++n)). Checking dependencies"
  for i in "${DEPS[@]}"; do
    if check_for_dependency "$i"; then
      check_ok "Found:     $i"
    else
      check_fail "Not found: $i"
  fi
  done
  #
  printf "\n $((++n)). Checking permissions\n"
  [[ "$LOGNAME" = root ]] ||
    check_fail "Not running as root.  root privileges are usually required."
  if [[ "$HAS_DOCKER_ACCESS" ]]; then
    check_ok "Docker access succeeded."
    # Check if Swarm has been set up
    if docker node inspect self >/dev/null 2>&1; then
      check_ok "Docker Swarm is set up."
    else
      check_fail "Docker Swarm is not set up which is required for $ME."
    fi
  else
    check_fail "You don't have access to docker."
  fi
  #
  printf "\n $((++n)). Checking directories\n"
  if [[ -d "$INSTANCES" ]]; then
    check_ok "The instance directory ${INSTANCES}/ exists."
  else
    check_fail "The instance directory '${INSTANCES}/' does not exist."
    read -p "    → Create it now? [y/N] "
    case "$REPLY" in
      Y|y|Yes|yes|YES) mkdir -pm 750 "$INSTANCES";;
    esac
  fi
  #
  printf "\n $((++n)). Checking $ME configuration\n"
  if [[ -f "$CONFIG_YML_TEMPLATE" ]]; then
    check_ok "Found configuration template file $CONFIG_YML_TEMPLATE."
  else
    check_fail "Configuration template $CONFIG_YML_TEMPLATE not found."
    read -p "    → Create a minimal template now? [y/N] "
    case "$REPLY" in
      Y|y|Yes|yes|YES)
        create_config_template || setup_with_errors=1 ;;
    esac
  fi
  #
  printf "\n $((++n)). Checking external OpenSlides management tool\n"
  if [[ -x "$MANAGEMENT_TOOL" ]]; then
    check_ok "The 'openslides' management tool is installed ($MANAGEMENT_TOOL)."
  else
    check_fail "The management tool is not installed."
    local bin_installer=openslides-bin-installer
    # If openslides-bin-installer is installed or available next to $ME
    if command -v $bin_installer >/dev/null || {
        bin_installer="$(dirname "${BASH_SOURCE[0]}")/${bin_installer}.sh"
        [[ -x "$bin_installer" ]]
      }
    then
      echo
      echo "    → Install the managment tool now?  $bin_installer will download" \
           "the compiled program from GitHub."
      echo "      Hint: See \`$bin_installer --help\` for the download URL and" \
            "other methods of installing 'openslides'."
      read -p "      Continue? [y/N] "
      case "$REPLY" in
        Y|y|Yes|yes|YES)
          echo
          "$bin_installer" --quiet |& tag_output "install" && setup_with_errors=0
          ;;
      esac
    else
      check_fail "Could not find openslides-bin-installer to automatically install the 'openslides' tool."
      echo
      echo "    → Hint: Please install openslides-bin-installer and use it to install the 'openslides' binary."
    fi
  fi
  #
  printf "\n $((++n)). Checking HAProxy setup\n"
  if [[ -w "$HAPROXYCFG" ]]; then
    check_ok "Found writable ${HAPROXYCFG}."
    if grep -qF -- "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----" "$HAPROXYCFG" &&
      grep -qF -- "-----END AUTOMATIC OPENSLIDES CONFIG-----" "$HAPROXYCFG"
    then
      check_ok "${HAPROXYCFG} has been set up for $ME."
    else
      check_fail "${HAPROXYCFG} has not been set up for $ME yet."
      echo
      echo "    → Hint: See haproxy.cfg.example in the repository for an example configuration."
    fi
  else
      check_fail "${HAPROXYCFG} not found or writeable."
      echo
      echo "    → Hint: See haproxy.cfg.example in the repository for an example configuration."
      echo "      Alternatively, you may create instances with the --local-only option."
  fi
  #
  printf "\n——— RESULT ———\n"
  if [[ "$setup_with_errors" -eq 0 ]]; then
    echo "Congratulations, your system meets the basic prerequisites!"
  else
    echo "Unfortunately, not all prerequisites have been met. " \
      "Running $ME without resolving the issues may fail."
  fi
  echo
}

hash_management_tool() {
  # Return the SHA256 hash of the selected "openslides" tool.  For lack of
  # proper versioning, the hash is used to track compatibility with individual
  # instances by adding it to each config.yml.
  sha256sum "$MANAGEMENT_TOOL" 2>/dev/null | gawk '{ print $1 }' ||
    fatal "$MANAGEMENT_TOOL not found."
}

select_management_tool() {
  # Read the required management tool version from the instance's config file
  # or use the version provided on the command line.
  local pdir
  # Find/configure the correct instance directory
  if [[ $# -eq 0 ]]; then
    pdir=$PROJECT_DIR
  elif [[ $# -eq 1 ]]; then
    pdir=$1
  else
    fatal "Wrong number of argumnts for select_management_tool()"
  fi
  MANAGEMENT_TOOL_HASH=
  if [[ -n "$OPT_MANAGEMENT_TOOL" ]]; then
    verbose 2 "Selecting management tool based on option: ${OPT_MANAGEMENT_TOOL}."
    # The given argument is the special string "-", indicating that the version
    # should remain unchanged
    if [[ "$OPT_MANAGEMENT_TOOL" = '-' ]]; then
      MANAGEMENT_TOOL_HASH=$(value_from_config_yml "$pdir" '.managementToolHash')
      # Resolve the '*' to latest
      [[ "$MANAGEMENT_TOOL_HASH" != '*' ]] ||
        MANAGEMENT_TOOL_HASH="$DEFAULT_MANAGEMENT_VERSION"
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${MANAGEMENT_TOOL_HASH}"
    # The given argument is the special string "*", indicating that the latest
    # version should be followed
    elif [[ "$OPT_MANAGEMENT_TOOL" = '*' ]]; then
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${DEFAULT_MANAGEMENT_VERSION}"
    elif [[ "$OPT_MANAGEMENT_TOOL" =~ \/ ]]; then
      # The given argument is a path
      MANAGEMENT_TOOL=$(realpath "$OPT_MANAGEMENT_TOOL")
    else
      # The given argument is only a filename; prepend path here
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${OPT_MANAGEMENT_TOOL}"
    fi
  # Reading tool version from instance configuration
  elif MANAGEMENT_TOOL_HASH=$(value_from_config_yml "$pdir" '.managementToolHash'); then
    verbose 2 "Selecting management tool based on instance configuration:" \
              "${MANAGEMENT_TOOL_HASH}."
    # Version is set to simply follow latest
    if [[ "$MANAGEMENT_TOOL_HASH" = '*' ]]; then
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/latest"
    # Version is configured to a specific hash
    else
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${MANAGEMENT_TOOL_HASH}"
    fi
  fi
  MANAGEMENT_TOOL_HASH=$(hash_management_tool)
  [[ -x "$MANAGEMENT_TOOL" ]] || fatal "$MANAGEMENT_TOOL not found."
  verbose 1 "Using management tool ${MANAGEMENT_TOOL}."
}

call_manage_tool() {
  [[ "$#" -ge 1 ]] ||
    fatal "Insufficient parameters to call management tool."
  [[ "$#" -ge 2 ]] ||
    fatal "Missing command for management tool."
  local opts=
  local dir="$1"
  local cmd="$2"
  shift 2
  local args="$@"

  case "$cmd" in
    # non-applicable commands, call without default opts
    config-create-default | help )
      break
      ;;
    # management commands that don't connect to the 'manage' service and,
    # instead, operate in PROJECT_DIR
    setup | config )
      local template= config= localconfig=
      [[ ! -r "$COMPOSE_TEMPLATE" ]] ||
        template="--template=${COMPOSE_TEMPLATE}"
      [[ ! -r "$CONFIG_YML_TEMPLATE" ]] ||
        config="--config=${CONFIG_YML_TEMPLATE}"
      [[ ! -r "${PROJECT_DIR}/config.yml" ]] ||
        localconfig="--config=${PROJECT_DIR}/config.yml"
      opts="$template $config $localconfig $dir"
      ;;
    # all other commands are assumed to connect to the 'manage' service
    *)
      local port=$(value_from_config_yml "$dir" '.port')
      local secret="${dir}/secrets/manage_auth_password"
      # The manage tool can't connect to the 'manage' service without access to
      # the secret.
      [[ -r "$secret" ]] || return 1
      opts="-a 127.0.0.1:${port} --password-file $secret --no-ssl"
      ;;
  esac

  verbose 2 "Executing $MANAGEMENT_TOOL $cmd $opts $args"
  $MANAGEMENT_TOOL $cmd $opts $args || return $?
}

next_free_port() {
  # Select new port
  #
  # This parses existing instances' YAML files to discover used ports and to
  # select the next one.  Other methods may be more suitable and robust but
  # have other downsides.  For example, `docker-compose port client 80` is
  # only available for running services.
  local HIGHEST_PORT_IN_USE
  local PORT
  HIGHEST_PORT_IN_USE=$(
    {
      # OS3 instance ports
      if [[ -d "${OS3_INSTANCES}" ]]; then
        find "${OS3_INSTANCES}" -type f -name ".env" -print0 |
        xargs -0 --no-run-if-empty grep -h "EXTERNAL_HTTP_PORT" |
        cut -d= -f2 | tr -d \"\'
      fi
      # OS4 instance ports
      find "${INSTANCES}" -type f -name "config.yml" -print0 |
      xargs -0 --no-run-if-empty yq --no-doc eval '.port'
    } | sort -rn | head -1
  )
  [[ -n "$HIGHEST_PORT_IN_USE" ]] || HIGHEST_PORT_IN_USE=61000
  PORT=$((HIGHEST_PORT_IN_USE + 1))

  # Check if port is actually free
  #  try to find the next free port (this situation can occur if there are test
  #  instances outside of the regular instances directory)
  n=0
  while ! ss -tnHl | gawk -v port="$PORT" '$4 ~ port { exit 2 }'; do
    [[ $n -le 25 ]] || { fatal "Could not find free port"; }
    ((PORT+=1))
    [[ $PORT -le 65535 ]] || { fatal "Ran out of ports"; }
    ((n+=1))
  done
  echo "$PORT"
}

value_from_config_yml() {
  local instance target result
  instance="$1"
  target="$2"
  result=null
  if [[ -f "${instance}/config.yml" ]]; then
    result=$(yq eval $target "${instance}/config.yml")
  fi
  if [[ "$result" == "null" ]]; then
    if [[ -f "${CONFIG_YML_TEMPLATE}" ]]; then
      result=$(yq eval $target "${CONFIG_YML_TEMPLATE}")
    fi
  fi
  [[ "$result" != "null" ]] || return 1
  echo "$result"
}

update_config_yml() {
  local file=$1
  local expr=$2
  [[ -f "$file" ]] || touch "$file"
  yq eval -i "$expr" "$file"
}

recreate_compose_yml() {
  call_manage_tool "$PROJECT_DIR" config |&
    tag_output manage
}

gen_pw() {
  local len="${1:-15}"
  read -r -n "$len" PW < <(LC_ALL=C tr -dc "[:alnum:]" < /dev/urandom)
  echo "$PW"
}

update_config_instance_specifics() {
  # Configure instance specifics in config.yml
  touch "${PROJECT_DIR}/config.yml"
  update_config_yml "${PROJECT_DIR}/config.yml" ".port = $PORT"

  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".stackName = \"$PROJECT_STACK_NAME\""
  if [[ -n "$DOCKER_IMAGE_TAG_OPENSLIDES" ]]; then
    update_config_yml "${PROJECT_DIR}/config.yml" ".defaults.tag = \"$DOCKER_IMAGE_TAG_OPENSLIDES\""
  fi
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".services.proxy.environment.ALLOWED_HOSTS = \"127.0.0.1:$PORT $PROJECT_NAME\""
}

update_config_services_db_connect_params() {
  # Write DB-connection credentials to config
  # for datastore
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.DATASTORE_DATABASE_NAME = \"${PROJECT_NAME}\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.DATASTORE_DATABASE_USER = \"${PROJECT_NAME}_user\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.DATASTORE_DATABASE_PASSWORD_FILE = \"/run/secrets/postgres_password\""
  # for media
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.MEDIA_DATABASE_NAME = \"${PROJECT_NAME}\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.MEDIA_DATABASE_USER = \"${PROJECT_NAME}_user\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.MEDIA_DATABASE_PASSWORD_FILE = \"/run/secrets/postgres_password\""
  # for vote
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.VOTE_DATABASE_NAME = \"${PROJECT_NAME}\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.VOTE_DATABASE_USER = \"${PROJECT_NAME}_user\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.VOTE_DATABASE_PASSWORD_FILE = \"/run/secrets/postgres_password\""
}

create_admin_secrets_file() {
  echo "Generating superadmin password..."
  local admin_secret="${PROJECT_DIR}/secrets/${ADMIN_SECRETS_FILE}"
  rm "$admin_secret"
  touch "$admin_secret"
  chmod 600 "$admin_secret"
  gen_pw | tr -d '\n' >> "$admin_secret"
}

query_user_account_name() {
  if [[ -n "$OPT_ADD_ACCOUNT" ]]; then
    echo "Create local admin account for:"
    while [[ -z "$OPENSLIDES_USER_FIRSTNAME" ]] || \
          [[ -z "$OPENSLIDES_USER_LASTNAME" ]]
    do
      read -rp "First & last name: " \
        OPENSLIDES_USER_FIRSTNAME OPENSLIDES_USER_LASTNAME
      read -rp "Email (optional): " OPENSLIDES_USER_EMAIL
    done
  fi
}

create_organization_setup_file() {
  # LEGAL_NOTICE_FILE and PRIVACY_POLICY_FILE can be set in
  # osinstancectl config file ($CONFIG)
  local setup_file="$PROJECT_DIR/setup/organization.yml.setup"
  touch "$setup_file"
  yq eval -i ".[0].id = 1" "$setup_file"
  [[ ! -f "$LEGAL_NOTICE_FILE" ]] ||
    text="$(cat "$LEGAL_NOTICE_FILE")" \
      yq eval -i ".[0].legal_notice = strenv(text)" "$setup_file"
  [[ ! -f "$PRIVACY_POLICY_FILE" ]] ||
    text="$(cat "$PRIVACY_POLICY_FILE")" \
      yq eval -i ".[0].privacy_policy = strenv(text)" "$setup_file"
}

create_user_setup_file() {
  if [[ -n "$OPT_ADD_ACCOUNT" ]]; then
    local first_name
    local last_name
    local email # optional
    local PW
    echo "Generating user credentials..."
    first_name=$1
    last_name=$2
    email=$3
    PW=$(gen_pw)
    local setup_file="${PROJECT_DIR}/setup/${USER_SECRETS_FILE}.setup"
    touch "$setup_file"
    chmod 600 "$setup_file"
    cat << EOF >> "$setup_file"
---
first_name: "$first_name"
last_name: "$last_name"
username: "$first_name$last_name"
email: "$email"
default_password: "$PW"
is_active: true
organization_management_level: can_manage_organization
EOF
  fi
}

create_config_template() {
  if [[ -f "$CONFIG_YML_TEMPLATE" ]]; then
    return 2
  fi
  mkdir -p "$(dirname "$CONFIG_YML_TEMPLATE")"
  cat > "$CONFIG_YML_TEMPLATE" << EOF
---
filename: "$DCCONFIG_FILENAME"
host: 0.0.0.0
disablePostgres: true
disableDependsOn: true
enableLocalHTTPS: false

defaultEnvironment:
  DATASTORE_DATABASE_HOST: localhost
  DATASTORE_DATABASE_PORT: 5432
  MEDIA_DATABASE_HOST: localhost
  MEDIA_DATABASE_PORT: 5432
  VOTE_DATABASE_HOST: localhost
  VOTE_DATABASE_PORT: 5432
EOF
}

create_instance_dir() {
  local template= config=

  if [[ ! -f "$CONFIG_YML_TEMPLATE" ]]; then
    warn "Configuration template $CONFIG_YML_TEMPLATE does not exist."
    local REPLY
    read -p "Create a mininmal template now? [Y/n] "
    case "$REPLY" in
      Y|y|Yes|yes|YES|"")
        create_config_template
        ;;
      *)
        # Refuse to continue without a template.  It would be easy to
        # transparently continue with a temporary file; however, at least for
        # now, encouraging the use of a central configuration file that can
        # also be used with the management tool directly is the simpler and
        # clearer behavior.
        fatal "Cannot continue without suitable configuration template."
        ;;
    esac
  fi

  [[ -z "$COMPOSE_TEMPLATE" ]] ||
    template="--template=${COMPOSE_TEMPLATE}"

  call_manage_tool "$PROJECT_DIR" setup |& tag_output manage ||
    fatal "Error during \`"${MANAGEMENT_TOOL}" setup\`"
  touch "${PROJECT_DIR}/${MARKER}"

  # Restrict access to secrets b/c the management tool sets very open access
  # permissions
  chmod -R 600 "${PROJECT_DIR}/secrets/"
  chmod 700 "${PROJECT_DIR}/secrets"

  # create setup directory for payload files used by `openslides set`
  mkdir "${PROJECT_DIR}/setup/"

  # Note which version of the openslides tool is compatible with the instance,
  # unless special string "*" is given
  if [[ "$OPT_MANAGEMENT_TOOL" = '*' ]]; then
    update_config_yml "${PROJECT_DIR}/config.yml" ".managementToolHash = \"$OPT_MANAGEMENT_TOOL\""
  else
    update_config_yml "${PROJECT_DIR}/config.yml" ".managementToolHash = \"$MANAGEMENT_TOOL_HASH\""
  fi

  # Due to a bug in "openslides", the db-data directory is created even if the
  # stack's Postgres service that would require it is disabled.
  # XXX: This is going to be fixed in the near future.  For now, remain
  # backwards-compatible.
  if [[ -d "${PROJECT_DIR}/db-data" ]] && [[ $(value_from_config_yml "$PROJECT_DIR" '.disablePostgres') == "true" ]]
  then
    rmdir "${PROJECT_DIR}/db-data"
  fi
}

add_to_haproxy_cfg() {
  [[ -z "$OPT_LOCALONLY" ]] || return 0
  cp -f "${HAPROXYCFG}" "${HAPROXYCFG}.osbak" &&
    gawk -v target="${PROJECT_NAME}" -v port="${PORT}" '
    BEGIN {
      begin_block = "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----"
      end_block   = "-----END AUTOMATIC OPENSLIDES CONFIG-----"
      use_server_tmpl = "\tuse-server %s if { hdr_reg(Host) -i ^%s$ }"
      server_tmpl = "\tserver     %s 127.0.0.1:%d  weight 0 check"
    }
    $0 ~ begin_block { b = 1 }
    $0 ~ end_block   { e = 1 }
    !e
    b && e {
      printf(use_server_tmpl "\n", target, target)
      printf(server_tmpl "\n", target, port)
      print
      e = 0
    }
  ' "${HAPROXYCFG}.osbak" >| "${HAPROXYCFG}" &&
    systemctl reload haproxy
}

rm_from_haproxy_cfg() {
  cp -f "${HAPROXYCFG}" "${HAPROXYCFG}.osbak" &&
  gawk -v target="${PROJECT_NAME}" -v port="${PORT}" '
    BEGIN {
      begin_block = "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----"
      end_block   = "-----END AUTOMATIC OPENSLIDES CONFIG-----"
    }
    $0 ~ begin_block { b = 1 }
    $0 ~ end_block   { e = 1 }
    b && !e && $2 == target { next }
    1
  ' "${HAPROXYCFG}.osbak" >| "${HAPROXYCFG}" &&
    systemctl reload haproxy
}

remove() {
  local PROJECT_NAME="$1"
  [[ -d "$PROJECT_DIR" ]] || {
    fatal "$PROJECT_DIR does not exist."
  }
  echo "Stopping and removing containers..."
  instance_erase
  echo "Removing instance repo dir..."
  rm -rf "${PROJECT_DIR}"
  echo "remove HAProxy config..."
  rm_from_haproxy_cfg
}

ping_instance_simple() {
  # Check if the instance's reverse proxy is listening
  #
  # This is used as an indicator as to whether the instance is supposed to be
  # running or not.  The reason for this check is that it is fast and that the
  # reverse proxy container rarely fails itself, so it is always running when
  # an instance has been started.  Errors usually happen in the backend
  # container which is checked with instance_health_status.
  nc -z 127.0.0.1 "$1" || return 1
}

instance_health_status() {
  # Check instance's health through its provided HTTP resources
  #
  # backend
  local port="${1:-$(value_from_config_yml "$PROJECT_DIR" '.port')}"
  LC_ALL=C curl -s "${CURL_OPTS[@]}" "http://127.0.0.1:${port}/system/action/health" |
    jq -r '.status' 2>/dev/null | grep -q 'running'
}

instance_has_services_running() {
  # Check if the instance has been deployed.
  #
  # This is used as an indicator as to whether the instance is *supposed* to be
  # running or not.
  local instance="$1"
  case "$DEPLOYMENT_MODE" in
    "stack")
      docker stack ls --format '{{ .Name }}' | grep -qw "^$instance\$" || return 1
      ;;
  esac
}

instance_has_manage_service_running() {
  # Check if the 'manage' service is ready to execute commands by running its
  # check-server command, verifying that the management client, management
  # service, and backend are all operational.
  local instance="${1:-$PROJECT_DIR}" output= ec=
  case "$DEPLOYMENT_MODE" in
    "stack")
      output=$(call_manage_tool "$instance" check-server -t 1s)
      ec=$?
      verbose 2 "management tool exit code: $ec; output: $output"
      return $ec
      ;;
  esac
}

fetch_instance_builtin_version() {
  # Connect to OpenSlides and parse its version string
  #
  # This is a simple method to test the availability of the app.  The function
  # deliberately does not use the management tool's `version` command because
  # that requires access to the management secret.  The method chosen here can
  # provide even less privileged users with the same version information.
  LC_ALL=C curl -s --fail "${CURL_OPTS[@]}" "http://127.0.0.1:${1}/assets/version.txt" ||
    {
      echo 'unavailable'
      return 1
    }
}

currently_running_version() {
  # Retrieve the OpenSlides image tags actually in use.
  case "$DEPLOYMENT_MODE" in
    "stack")
      [[ "$HAS_DOCKER_ACCESS" ]] || return 1
      docker stack services --format '{{ .Image }}' "${PROJECT_STACK_NAME}" |
      gawk -F: '# Skip expected non-OpenSlides images
        $1 == "redis" { next }
        1
        '
      ;;
  esac |
  gawk -F: '
    {
      # Extract only the registry address from the image name (remove the
      # last element)
      sub(/\/[^\/]+$/, "", $1)
      reg[$1]++
      img[$2]++
    }
    END {
      # List image tags
      n = asorti(img, sorted, "@val_num_desc")
      for (i = 1; i <= n; i++) {
        if (n == 1) {
          printf("%s", sorted[i])
        } else {
          # If more than one image tag is in use, list them all with a count
          printf("%s(%d)", sorted[i], img[sorted[i]])
          if (i < length(img)) printf("/")
        }
      }
      # Add number of registries and tags if there are more than 1
      if (length(reg) > 1 || n > 1) printf("[%d:%d]", length(reg), n)
    }
  '
}

highlight_match() {
  # Highlight search term match in string
  # By default, the PROJECT_NAME is matched but a custom sed-compatible search
  # term can be given as an optional second argument.

  # Return string as is if colors are disabled.
  if [[ -z "$NCOLORS" ]]; then
    echo "$1"
    return 0
  fi

  local string filter
  string=$1
  filter=${2:-PROJECT_NAME}
  sed -e "s/${filter}/$(tput smso)&$(tput rmso)/g" <<< "$string"
}

treefmt() {
  # Tree formatting function, for ls_instance()

  # Initialize treefmt first, if necessary
  if [[ -z "${treefmt_var_initialized:-}" ]]; then
    treefmt_var_initialized=1
    treefmt_var_default_tree_drawing_char=" "
    treefmt_var_default_tree_paddding_char=" "
    treefmt_var_draw_cont="├"
    treefmt_var_draw_close="└"
    treefmt_var_draw_body="┆"
    treefmt_var_padding=2
    treefmt_var_base_indent="   "
    treefmt_var_indentation_steps=$((treefmt_var_padding + 1)) # 1 is length of $tree_drawing_char
    treefmt_var_drawing_detail="${OPT_TREEFMT_DRAWING_DETAIL:-1}"
    treefmt reset

    treefmt_indentation() {
      local higher_lvl=$((lvl - 1))
      if [[ ${treefmt_var_drawing_detail} -eq 1 ]]; then
        for node_level in $(seq 1 "$higher_lvl"); do
          local tree_drawing_char=$treefmt_var_default_tree_drawing_char
          # Draw branch if there will be more nodes of the same level
          if [[ ${treefmt_var_node_count_per_lvl[$node_level]:-0} -gt 0 ]]; then
            tree_drawing_char="│"
          fi
          # But do not draw the branch if the parent node was the last of this
          # particular branch, i.e., is listed as a breaking node
          if echo "${treefmt_var_breaking_nodes[$node_level]:-}" |
              grep -qw "${last_node_in_lvl[$node_level]}"; then
            tree_drawing_char=$treefmt_var_default_tree_drawing_char
          fi
          printf "%s%s%${treefmt_var_padding}s" \
            "$indent" "$tree_drawing_char" "$treefmt_var_default_tree_paddding_char"
        done
      else
        # fast mode: simply print spaces for indentation
        [[ $higher_lvl -lt 1 ]] || printf "%$((higher_lvl * treefmt_var_indentation_steps))s" " "
      fi
    }

    treefmt_format() {
      for i in $(seq $treefmt_var_n); do
        local drawing_char=$treefmt_var_draw_close
        local lvl=${treefmt_var_level_array[$i]}
        # +1 for space after colon:
        local align=$((treefmt_var_max_align - lvl * treefmt_var_indentation_steps + 1))
        local indent=
        case "${treefmt_var_type_array[$i]}" in
          node)
            if [[ ${treefmt_var_drawing_detail} -eq 1 ]]; then
              local next_node=$((i+1))
              local next_node_level
              local last_node_in_lvl[$lvl]=$i
              next_node_level=${treefmt_var_level_array[$next_node]:-0}
              treefmt_var_node_count_per_lvl[$lvl]=$((treefmt_var_node_count_per_lvl[$lvl] - 1))
              if [[ "$next_node_level" -lt "$lvl" ]]; then
                # if the next node is of a higher level, this node must be;
                # closed.  any other nodes of the same level must be part of
                # a new subtree.
                drawing_char=$treefmt_var_draw_close
              elif echo "${treefmt_var_breaking_nodes[$lvl]:-}" | grep -qw "$i" ; then
                # if the current node has been recorded as the last node of
                # a certain level before a break.  This means there may be more
                # nodes of this level but the tree is broken up by higher-level
                # nodes in between.
                drawing_char=$treefmt_var_draw_close
              elif [[ "${treefmt_var_node_count_per_lvl[$lvl]}" -ge 1 ]]; then
                # if there are more nodes of the same level, draw continuation character
                drawing_char=$treefmt_var_draw_cont
              fi
              indent="${treefmt_var_base_indent}$(treefmt_indentation)"
            else
              drawing_char=$treefmt_var_draw_cont
              indent="${treefmt_var_base_indent}$(treefmt_indentation)"
            fi
            # If the node has a value, add a colon to the node key/header
            # local colon=
            if [[ -n "${treefmt_var_content_array[$i]}" ]]; then
              colon=:
            else
              colon=
            fi
            printf "%s%s%s%-${align}s %s\n" \
              "$indent" \
              "$drawing_char" \
              "$treefmt_var_default_tree_paddding_char" \
              "${header_array[$i]}${colon}" \
              "${treefmt_var_content_array[$i]}"
            ;;
          body)
            drawing_char="$treefmt_var_draw_body"
            indent="${treefmt_var_base_indent}$(treefmt_indentation)"
            printf "%s\n" "${treefmt_var_content_array[$i]}" | sed "s/^/$indent$drawing_char /"
            ;;
        esac
      done
    }
  fi

  case $1 in
    reset)
      treefmt_var_type_array=()
      treefmt_var_level_array=()
      treefmt_var_node_count_per_lvl=()
      treefmt_var_content_array=()
      treefmt_var_n=0
      treefmt_var_node_level=1
      treefmt_var_max_lvl=$treefmt_var_node_level
      treefmt_var_max_align=0
      declare -A treefmt_var_last_node_per_lvl=()
      declare -A treefmt_var_breaking_nodes=()
      ;;
    node)
      [[ -n $2 ]] || fatal "ProgrammingError: treefmt node name must not be empty"
      treefmt_var_n=$((treefmt_var_n + 1))
      treefmt_var_level_array[$treefmt_var_n]=$treefmt_var_node_level
      treefmt_var_node_count_per_lvl[$treefmt_var_node_level]=$((
        treefmt_var_node_count_per_lvl[$treefmt_var_node_level] + 1
      ))
      [[ $treefmt_var_node_level -lt $treefmt_var_max_lvl ]] ||
        treefmt_var_max_lvl=$treefmt_var_node_level
      treefmt_var_last_node_per_lvl[$treefmt_var_node_level]=$treefmt_var_n
      treefmt_var_type_array[$treefmt_var_n]=$1
      header_array[$treefmt_var_n]=$2
      # record longest node header
      node_header_length=$((treefmt_var_node_level * treefmt_var_indentation_steps + ${#2}))
      [[ $treefmt_var_max_align -gt $node_header_length ]] ||
        treefmt_var_max_align=$node_header_length
      unset node_header_length
      shift 2
      treefmt_var_content_array[$treefmt_var_n]="$*"
      ;;
    body)
      treefmt_var_n=$((treefmt_var_n + 1))
      treefmt_var_level_array[$treefmt_var_n]=$((treefmt_var_node_level + 1))
      treefmt_var_type_array[$treefmt_var_n]=$1
      shift 1
      treefmt_var_content_array[$treefmt_var_n]="$*"
      ;;
    branch)
      case $2 in
        create) ((treefmt_var_node_level++)) ;;
        close)
          # Strings containing all nodes of a given level that are the last in
          # their (sub)branch
          [[ -z ${treefmt_var_last_node_per_lvl[$treefmt_var_node_level]:-} ]] ||
            treefmt_var_breaking_nodes[$treefmt_var_node_level]+="${treefmt_var_last_node_per_lvl[$treefmt_var_node_level]} "
          ((treefmt_var_node_level--))
          ;;
      esac
      ;;
    print)
      treefmt_format
      treefmt reset
      ;;
  esac
}

ls_instance() {
  local instance="$1"
  local shortname
  local normalized_shortname=
  local ls_is_extended=

  shortname=$(basename "$instance")

  local user_name=
  local OPENSLIDES_ADMIN_PASSWORD="—"

  [[ -f "${instance}/${DCCONFIG_FILENAME}" ]] && [[ -f "${instance}/config.yml" ]] ||
    fatal "$shortname is not a $DEPLOYMENT_MODE instance."

  #  For stacks, get the normalized shortname
  PROJECT_STACK_NAME="$(value_from_config_yml "$instance" '.stackName')"
  [[ -z "${PROJECT_STACK_NAME}" ]] ||
    local normalized_shortname="${PROJECT_STACK_NAME}"

  # Determine instance state
  local port
  local instance_is_running=
  local sym="$SYM_UNKNOWN"
  local version=
  port="$(value_from_config_yml "$instance" '.port')"
  [[ -n "$port" ]]

  # Check instance deployment state and health
  if ping_instance_simple "$port"; then
    # If we can open a connection to the reverse proxy, the instance has been
    # deployed.
    sym="$SYM_NORMAL"
    instance_is_running=1
    version="[skipped]"
    version_from_image=$version
    if [[ -z "$OPT_FAST" ]]; then
      if instance_health_status "$port"; then
        if [[ "$HAS_DOCKER_ACCESS" ]]; then
          version=$(currently_running_version)
          if [[ "$OPT_LONGLIST" ]] || [[ "$OPT_JSON" ]]; then
            # Additionally fetch the images own version string if needed;
            # otherwise, avoid to reduce requests.
            version_from_image=$(fetch_instance_builtin_version "$port") || true
          fi
        else
          version_from_image=$(fetch_instance_builtin_version "$port") || true
          version=$version_from_image
        fi
      else
        sym=$SYM_ERROR
      fi
    fi
    # Check if access to the openslides management tool/service is available.  If
    # not, some functions must be skipped.
    select_management_tool "$instance" # Configure the correct version for this instance
    HAS_MANAGEMENT_ACCESS=1
    # Run a test query
    call_manage_tool "$instance" get user --fields id 2>&1 >/dev/null ||
      HAS_MANAGEMENT_ACCESS=
  else
    # If we can not connect to the reverse proxy, the instance may have been
    # stopped on purpose or there is a problem
    version=
    version_from_image=
    sym="$SYM_STOPPED"
    instance_is_running=0
    if [[ "$HAS_DOCKER_ACCESS" ]] && [[ -z "$OPT_FAST" ]] &&
        instance_has_services_running "$normalized_shortname"; then
      # The instance has been deployed but it is unreachable
      version=
      sym="$SYM_ERROR"
    fi
  fi

  # Filter online/offline instances
  case "$FILTER_RUNNING_STATE" in
    online)
      [[ "$sym" = "$SYM_NORMAL" ]] || return 1 ;;
    stopped)
      [[ "$sym" = "$SYM_STOPPED" ]] || return 1 ;;
    error)
      [[ "$sym" = "$SYM_ERROR" ]] || [[ "$sym" = "$SYM_UNKNOWN" ]] || return 1 ;;
    *) ;;
  esac

  # Filter based on comparison with the currently running version (as reported
  # by currently_running_version())
  [[ -z "$FILTER_VERSION" ]] ||
    { grep -E -q "$FILTER_VERSION" <<< "$version" || return 1; }

  # Fetch lock state and optionally filter based on it
  local has_locks=false
  local lockfile="${instance}/${LOCKFILE}"
  if instance_has_locks "$shortname"; then
    has_locks=true
  fi
  case "$FILTER_LOCKED_STATE" in
    locked)
      [[ "$has_locks" = true ]] || return 1
      ;;
    unlocked)
      [[ "$has_locks" = false ]] || return 1
      ;;
    *) ;;
  esac

  # Parse metadata for first line (used in overview)
  local first_metadatum=
  if [[ -r "${instance}/metadata.txt" ]]; then
    first_metadatum=$(head -1 "${instance}/metadata.txt")
    # Shorten if necessary.  This string will be printed as a column of the
    # general output, so it should not cause linebreaks.  Since the same
    # information will additionally be displayed in the extended output,
    # we can just cut it off here.
    # Ideally, we'd dynamically adjust to how much space is available.
    [[ "${#first_metadatum}" -lt 31 ]] ||
      first_metadatum="${first_metadatum:0:30}…"
    # Tasks for color support
    if [[ -n "$NCOLORS" ]]; then
      # Colors are enabled.  Since metadata.txt may include escape sequences,
      # reset them at the end
      if grep -Fq $'\e' <<< "$first_metadatum"; then
        first_metadatum+="[0m"
      fi
    else
      # Remove all escapes from comment.  This is the simplest method and will
      # leave behind the disabled escape codes.
      first_metadatum="$(echo "$first_metadatum" | tr -d $'\e')"
    fi
  fi

  # Extended parsing
  # ----------------
  # --services
  if [[ -n "$OPT_SERVICES" ]] || [[ -n "$OPT_JSON" ]]; then
    # Parse currently configured versions from docker-compose.yml
    declare -A service_versions
    while read -r service s_version; do
      service_versions[$service]=$s_version
    done < <(yq eval '.services.*.image | {(path | join(".")): .}' \
        "${instance}/${DCCONFIG_FILENAME}" |
      gawk -F': ' '{ split($1, a, /\./); print a[2], $2}')
    unset service s_version
    # Add management tool version to list of services.  This is not actually
    # a service running inside the stack but a version relevant to the stack
    # nonetheless.
    service_versions[management-tool]=$(value_from_config_yml "$instance" '.managementToolHash') || true

    # Get service scalings
    if [[ -z "$OPT_FAST" ]] || [[ -n "$OPT_JSON" ]] && [[ "$instance_is_running" -eq 1 ]] &&
        [[ "$HAS_DOCKER_ACCESS" ]] && [[ "$HAS_MANAGEMENT_ACCESS" ]]
    then
      autoscale_gather "$instance" || true
    fi
  fi

  # --secrets
  if [[ -n "$OPT_SECRETS" ]] || [[ -n "$OPT_JSON" ]]; then
    # Parse admin credentials file
    if [[ -r "${instance}/secrets/${ADMIN_SECRETS_FILE}" ]]; then
      read -r OPENSLIDES_ADMIN_PASSWORD \
        < "${instance}/secrets/${ADMIN_SECRETS_FILE}"
    fi
    # Parse user credentials file
    if [[ -r "${instance}/setup/${USER_SECRETS_FILE}" ]]; then
      local user_secrets="${instance}/setup/${USER_SECRETS_FILE}"
      local OPENSLIDES_USER_FIRSTNAME=$(yq eval .first_name "${user_secrets}")
      local OPENSLIDES_USER_LASTNAME=$(yq eval .last_name "${user_secrets}")
      local OPENSLIDES_USER_PASSWORD=$(yq eval .default_password "${user_secrets}")
      local OPENSLIDES_USER_EMAIL=$(yq eval .email "${user_secrets}")
      user_name=$(yq eval .username "${user_secrets}")
    fi
  fi

  # --metadata
  local metadata=()
  if [[ -n "$OPT_METADATA" ]] || [[ -n "$OPT_JSON" ]]; then
    if [[ -r "${instance}/metadata.txt" ]]; then
      # Parse metadata file for use in long output
      readarray -t metadata < <(grep -v '^\s*#' "${instance}/metadata.txt")
    fi
  fi

  # --stats
  if [[ -n "$OPT_STATS" || -n "$OPT_JSON" ]] &&
      [[ "$HAS_MANAGEMENT_ACCESS" ]] && [[ "$instance_is_running" -eq 1 ]]
  then
    # Organization
    IFS=$'\t' read -r \
        stats_limit_of_users \
        stats_limit_of_meetings \
        stats_active_meetings \
        stats_feature_evoting \
        stats_feature_chat \
      < <(call_manage_tool "$instance" get organization | jq -r '
          .[] | [
            .limit_of_users,
            .limit_of_meetings,
            (.active_meeting_ids | length),
            .enable_electronic_voting,
            .enable_chat
          ] | @tsv')
    #
    # User
    stats_total_users=$(call_manage_tool "$instance" get user --fields id | jq -r '. | length')
    stats_active_users=$(call_manage_tool "$instance" get user --fields id --filter=is_active=true  | jq -r '. | length')
    #
    # Meetings
    if [[ "$OPT_STATS" ]]; then
      # Meeting info for regular output format
      declare -A stat_meeting_name=()
      declare -A stat_meeting_start_date=()
      declare -A stat_meeting_end_date=()
      declare -A stat_meeting_jitsi_domain=()
      declare -A stat_meeting_jitsi_room_name=()
      declare -A stat_meeting_jitsi_room_password=()
      declare -A stat_meeting_features=()
      while IFS=$'\t' read -r \
        id \
        name \
        start \
        end \
        jitsi_domain \
        jitsi_room_name \
        jitsi_room_password
      do
        stat_meeting_name[$id]=$name
        stat_meeting_start_date[$id]=$start
        stat_meeting_end_date[$id]=$end
        stat_meeting_jitsi_domain[$id]=$jitsi_domain
        stat_meeting_jitsi_room_name[$id]=$jitsi_room_name
        stat_meeting_jitsi_room_password[$id]=$jitsi_room_password
      done < <(call_manage_tool "$instance" get meeting \
        --fields=id,name,start_time,end_time,jitsi_domain,jitsi_room_name,jitsi_room_password |
        jq -cr '.[] | flatten | @tsv')
    fi
    if [[ "$OPT_JSON" ]]; then
      # Meeting info in JSON format for --json
      stats_meetings_json=$(call_manage_tool "$instance" get meeting \
        --fields=id,name,start_time,end_time,jitsi_domain,jitsi_room_name,jitsi_room_password |
        jq '{ meetings: [.[]] }')
    fi
  fi

  # JSON ouput
  # ----------
  if [[ -n "$OPT_JSON" ]]; then
    local jq_image_version_args=$(
      for s in "${!service_versions[@]}"; do
        v=${service_versions[$s]}
        s=$(echo "$s" | tr - _)
        printf -- '--arg %s %s\n' "$s" "$v"
      done
    )
    local jq_service_scaling_args=$(
      for s in "${!service_versions[@]}"; do
        v_current=${SCALE_RUNNING[$s]:=null}
        v_target=${SCALE_TO[$s]:=null}
        s=$(echo "$s" | tr - _)
        printf -- '--arg %s_scale_current %s\n' "$s" "$v_current"
        printf -- '--argjson %s_scale_target %s\n' "$s" "$v_target"
      done
    )
    if [[ -f "$lockfile" ]] && grep -q '^update	' "$lockfile"; then
      local update_is_locked=true
    else
      local update_is_locked=false
    fi

    # Create a custom JSON object and merge it with the meetings information
    {
      jq -n \
        --arg     "shortname"       "$shortname"                        \
        --arg     "stackname"       "$normalized_shortname"             \
        --arg     "directory"       "$instance"                         \
        --arg     "version"         "$version"                          \
        --arg     "version_image"   "$version_from_image"               \
        --arg     "instance"        "$instance"                         \
        --arg     "status"          "$sym"                              \
        --argjson "lock_status"     "$has_locks"                        \
        --argjson "update_locked"   "$update_is_locked"                 \
        --argjson "port"            "$port"                             \
        --arg     "superadmin"      "$OPENSLIDES_ADMIN_PASSWORD"        \
        --arg     "user_name"       "$user_name"                        \
        --arg     "user_password"   "$OPENSLIDES_USER_PASSWORD"         \
        --arg     "user_email"      "$OPENSLIDES_USER_EMAIL"            \
        --argjson "meetings_active" "${stats_active_meetings:-null}"    \
        --argjson "meetings_limit"  "${stats_limit_of_meetings:-null}"  \
        --argjson "active_users"    "${stats_active_users:-null}"       \
        --argjson "total_users"     "${stats_total_users:-null}"        \
        --argjson "limit_users"     "${stats_limit_of_users:-null}"     \
        --argjson "feature_chat"    "${stats_feature_chat:-null}"       \
        --argjson "feature_evoting" "${stats_feature_evoting:-null}"    \
        --arg      "misc_today"     "$(date +%F)"                       \
        --argjson  "misc_meetings_today" "${MEETINGS_TODAY:-null}"      \
        --argjson  "misc_accounts_today" "${ACCOUNTS_TODAY:-null}"      \
        --arg     "metadata"        "$(printf "%s\n" "${metadata[@]}")" \
        $jq_image_version_args \
        $jq_service_scaling_args \
        "{
          name:          \$shortname,
          stackname:     \$stackname,
          directory:     \$instance,
          version:       \$version,
          version_image: \$version_image,
          status:        \$status,
          lock_status: {
            has_locks: \$lock_status,
            update_is_locked: \$update_locked
          },
          port:          \$port,
          superadmin:    \$superadmin,
          user: {
            user_name:    \$user_name,
            user_password: \$user_password,
            user_email: \$user_email
          },
          metadata:   \$metadata,
          services: {
            versions: {
              # Iterate over all known services; their values get defined by jq
              # --arg options.
              $(for s in ${!service_versions[@]}; do
                printf '"%s": $%s,\n' $s ${s} |
                tr - _ # dashes not allowed in keys
              done | sort)
            },
            scaling: {
              misc: {
                today: \$misc_today,
                meetings_today: \$misc_meetings_today,
                accounts_today: \$misc_accounts_today,
              },
              current: {
                $(for s in "${!service_versions[@]}"; do
                  printf '"%s": $%s_scale_current,\n' $s $s |
                  tr - _ # dashes not allowed in keys
                done | sort)
              },
              target: {
                $(for s in "${!service_versions[@]}"; do
                  printf '"%s": $%s_scale_target,\n' $s $s |
                  tr - _ # dashes not allowed in keys
                done | sort)
              }
            }
          },
          stats: {
            meetings_active: \$meetings_active,
            meetings_limit: \$meetings_limit,
            users_active: \$active_users,
            users_total: \$total_users,
            users_limit: \$limit_users,
            feature_chat: \$feature_chat,
            feature_evoting: \$feature_evoting
          }
        }"
      # List of meetings
      echo "${stats_meetings_json:-}"
    } |
      jq -s '.[0] + .[1]' # merge into a single object
    return
  fi

  # Prepare tree output
  # -------------------

  # --long
  if [[ -n "$OPT_LONGLIST" ]]; then
    ls_is_extended=1
    treefmt node "Directory" "$instance"
    if [[ -n "$normalized_shortname" ]]; then
      treefmt node "Stack name" "$normalized_shortname"
    fi
    treefmt node "Local port" "$port"
    treefmt node "Versions"
    treefmt branch create
      treefmt node "Images" "$version"
      treefmt node "Built-in" "$version_from_image"
    treefmt branch close
    if [[ "$has_locks" = true ]]; then
      local lock_action lock_time lock_name lock_email lock_reason
      treefmt node "Lock status" "locked"
      treefmt branch create
        while IFS=$'\t' read -r lock_action lock_time lock_name lock_email lock_reason; do
          lock_time=$(date -d "@$lock_time" -I)
          treefmt node "$lock_action" "$lock_reason ($lock_name, $lock_email on $lock_time)"
        done < "$lockfile"
      treefmt branch close
    else
      treefmt node "Lock status" "unlocked"
    fi
  fi

  # --services
  if [[ -n "$OPT_SERVICES" ]]; then
    ls_is_extended=1
    treefmt node "Services"
    treefmt branch create
      treefmt node "Versions (configured)"
        treefmt branch create
          for service in $(printf "%s\n" "${!service_versions[@]}" | sort); do
            treefmt node "${service}" "$(highlight_match "${service_versions[$service]}" "$FILTER_VERSION")"
          done
        treefmt branch close
      if [[ -z "$OPT_FAST" ]] && [[ "$instance_is_running" -eq 1 ]] &&
            [[ "$HAS_DOCKER_ACCESS" ]]
      then
        if [[ "$HAS_MANAGEMENT_ACCESS" ]]; then
          treefmt node "Scaling" "(meetings on $(date +%F): ${MEETINGS_TODAY:-N/A} -" \
                "users in active meetings: ${ACCOUNTS_TODAY:-N/A})"
            treefmt branch create
              for service in "${!SCALE_RUNNING[@]}"; do
                arrow="→"
                vstr=
                if [[ "${SCALE_FROM[$service]}" -lt "${SCALE_TO[$service]}" ]]; then
                  arrow="↗"
                  vstr="!"
                elif [[ "${SCALE_FROM[$service]}" -gt "${SCALE_TO[$service]}" ]]; then
                  arrow="↘"
                fi
                vstr="${SCALE_RUNNING[$service]} ${arrow} ${SCALE_TO[$service]} ${vstr}"
                treefmt node "${service}" "$vstr"
              done
              unset vstr
              unset arrow
            treefmt branch close
          else
            treefmt node "Scaling" "${COL_RED}[Access denied]${COL_NORMAL}"
          fi
      fi
    treefmt branch close
  fi

  # --secrets
  if [[ -n "$OPT_SECRETS" ]]; then
    ls_is_extended=1
    treefmt node "Secrets"
    treefmt branch create
    treefmt node "superadmin" "$OPENSLIDES_ADMIN_PASSWORD"
    # Include secondary account credentials if available
    [[ -n "$user_name" ]] &&
      treefmt node "\"$user_name\"" "$OPENSLIDES_USER_PASSWORD"
    [[ -n "$OPENSLIDES_USER_EMAIL" ]] &&
      treefmt node "Contact" "$OPENSLIDES_USER_EMAIL"
    treefmt branch close
  fi

  # --stats
  if [[ -n "$OPT_STATS" ]] && [[ "$instance_is_running" -eq 1 ]]; then
    ls_is_extended=1
    if [[ "$HAS_MANAGEMENT_ACCESS" ]]; then
      local this_meeting_name
      local meeting_node_header
      local meeting_node_body
      local start
      local end
      local duration
      local features_enabled=()
      [[ "${stats_feature_chat:-false}" = false ]] || features_enabled+=(chat)
      [[ "${stats_feature_evoting:-false}" = false ]] || features_enabled+=(evoting)
      treefmt node "Stats"
        treefmt branch create
        treefmt node "Meetings" "${stats_active_meetings:-}/${stats_limit_of_meetings:-}"
          treefmt branch create
          # Meetings: iterate over sorted array keys
          for i in $(printf "%s\n" "${!stat_meeting_name[@]}" | sort -n); do
            this_meeting_name="${stat_meeting_name[$i]}"
            # Abbreviate long meeting titles and set node name
            [[ "${#this_meeting_name}" -le 15 ]] || this_meeting_name="${this_meeting_name:0:15}."
            printf -v meeting_node_header "%02d: %s" "$i" "${this_meeting_name}"
            #
            # Format the meeting date/duration string
            meeting_node_body=
            start=
            end=
            duration=
            start="${stat_meeting_start_date[$i]:-0}"
            end="${stat_meeting_end_date[$i]:-0}"
            if [[ "$start" -gt 0 ]] && [[ "$end" -gt 0 ]]; then
              duration=$(( (end - start) / 60/60/24 + 1)) # in days
              if [[ "$start" -eq "$end" ]]; then
                printf -v meeting_node_body "%s (%s)" "$(date -I -d "@$start")" "${duration}d"
              else
                printf -v meeting_node_body "%s – %s (%s)" \
                  "$(date -I -d "@$start")" "$(date -I -d "@$end")" "${duration}d"
              fi
            fi
            #
            # Append Jitsi info if available
            if [[ -n "${stat_meeting_jitsi_domain[$i]:-}" ]] && [[ -n "${stat_meeting_jitsi_room_name[$i]:-}" ]]
            then
              printf -v meeting_node_body "%s: %s/%s" "${meeting_node_body}" \
                "${stat_meeting_jitsi_domain[$i]}" "${stat_meeting_jitsi_room_name[$i]}"
              [[ -z "${stat_meeting_jitsi_room_password[$i]:-}" ]] ||
                printf -v meeting_node_body "%s: (%s)" "${meeting_node_body}" \
                  "${stat_meeting_jitsi_room_password[$i]}"
            fi
            #
            treefmt node "$meeting_node_header" "${meeting_node_body}"
          done
          treefmt branch close
        treefmt node "Users" "${stats_active_users:-}/${stats_total_users:-}/${stats_limit_of_users:-}"
        treefmt node "Features" "${features_enabled[*]:-"—"}"
      treefmt branch close
    else
      treefmt node "Stats" "${COL_RED}[Access denied]${COL_NORMAL}"
    fi
  fi

  # --metadata
  if [[ ${#metadata[@]} -ge 1 ]]; then
    ls_is_extended=1
    treefmt node "Metadata"
    for m in "${metadata[@]}"; do
      m=$(highlight_match "$m") # Colorize match in metadata
      treefmt body "${m}${COL_NORMAL}"
    done
  fi

  # Print instance
  # --------------
  if [[ "$ls_is_extended" ]]; then
    # Hide details if a long output format has been selected
    printf "%s %-30s\n" "$sym" "$shortname"
  else
    # Print a single line per instance
    printf "%s %-30s\t%-10s\t%s\n" "$sym" "$shortname" \
      "$(highlight_match "$version" "$FILTER_VERSION")" "$first_metadatum"
  fi
  # Formatted tree
  treefmt print
}

colorize_ls() {
  # Colorize the status indicators
  if [[ -n "$NCOLORS" ]] && [[ -z "$OPT_JSON" ]]; then
    # XXX: 2>/dev/null is used here to hide warnings such as
    # gawk: warning: escape sequence `\.' treated as plain `.'
    gawk 2>/dev/null \
      -v m="$PROJECT_NAME" \
      -v hlstart="$(tput smso)" \
      -v hlstop="$(tput rmso)" \
      -v bullet="${BULLET}" \
      -v normal="${COL_NORMAL}" \
      -v green="${COL_GREEN}" \
      -v yellow="${COL_YELLOW}" \
      -v gray="${COL_GRAY}" \
      -v red="${COL_RED}" \
    'BEGIN {
      FPAT = "([[:space:]]*[^[:space:]]+)"
      OFS = ""
      IGNORECASE = 1
    }
    # highlight matches in instance name
    /^[^ ]/ { gsub(m, hlstart "&" hlstop, $2) }
    # highlight matches in metadata
    $1 ~ /[[:space:]]+┆/ { gsub(m, hlstart "&" hlstop, $0) }
    # bullets
    /^OK/   { $1 = " " green  bullet normal }
    /^\?\?/ { $1 = " " yellow bullet normal }
    /^XX/   { $1 = " " red    bullet normal }
    /^__/   { $1 = " " gray   bullet normal }
    1'
  else
    cat -
  fi
}

list_instances() {
  # Find instances and filter based on search term.
  # PROJECT_NAME is used as a grep -E search pattern here.
  local i=()
  local j=()
  readarray -d '' i < <(
    find "${INSTANCES}" -mindepth 1 -maxdepth 1 -type d -print0 |
    sort -z
  )
  for instance in "${i[@]}"; do
    # skip directories that aren't instances
    [[ -f "${instance}/${DCCONFIG_FILENAME}" ]] && [[ -f "${instance}/config.yml" ]] || continue

    # Filter instances
    # 1. instance name/project dir matches (case-insensitive)
    if grep -i -E -q "$PROJECT_NAME" <<< "$(basename "$instance")"; then :
    # 2. metadata matches (case-insensitive)
    elif [[ -n "$OPT_METADATA_SEARCH" ]] && [[ -f "${instance}/metadata.txt" ]] &&
      grep -i -E -q "$PROJECT_NAME" "${instance}/metadata.txt"; then :
    else
      continue
    fi

    j+=("$instance")
  done

  # return here if no matches
  [[ "${#j[@]}" -ge 1 ]] || return

  merge_if_json() {
    if [[ -n "$OPT_JSON" ]]; then
      $JQ -s '{ instances: . }'
    else
      cat -
    fi
  }

  # list instances, either one by one or in parallel
  if [[ $OPT_USE_PARALLEL -ne 0 ]]; then
    env_parallel --no-notice --keep-order ls_instance ::: "${j[@]}"
  else
    for instance in "${j[@]}"; do
      ls_instance "$instance" || continue
    done
  fi | colorize_ls | column -ts $'\t' | merge_if_json
}

clone_instance_dir() {
  marker_check "$CLONE_FROM_DIR"
  cp -av "${CLONE_FROM_DIR}/config.yml" "${PROJECT_DIR}/"
  cp -av "${CLONE_FROM_DIR}/secrets/${ADMIN_SECRETS_FILE}" "${PROJECT_DIR}/secrets/"
  cp -av "${CLONE_FROM_DIR}/setup/" "${PROJECT_DIR}/"
}

append_metadata() {
  local m="${1}/metadata.txt"
  touch "$m"
  shift
  printf "%s\n" "$*" >> "$m"
}

ask_start() {
  local start=
  read -rp "Start the instance? [Y/n] " start
  case "$start" in
    Y|y|Yes|yes|YES|"")
      instance_start ;;
    *)
      echo "Not starting instance."
      return 2
      ;;
  esac
}

wait_for() {
  local max_progress_length=30
  local wait_count=0
  verbose 2 "wait_for $@"
  until "$@"; do
    wait_count=$((wait_count + 1))
    sleep 5
    # Append periods unless the line is getting too long.
    if [[ $wait_count -lt $max_progress_length ]]; then
      printf .
    elif [[ $wait_count -eq $max_progress_length ]]; then
      printf ' [truncated]'
    fi
  done
  printf ' done.\n'
}

instance_initialdata() {
  # Run setup steps that require the instance to be running
  verbose 2 "instance_initialdata()"
  {
    call_manage_tool "$PROJECT_DIR" initial-data |&
      tag_output manage
    local ec=$?
  } || true
  [[ $ec -eq 0 ]] || [[ $ec -eq 2 ]] || {
    # 0: initial-data was successful; expected during initial setup
    # 2: command refused to run because the database already contains data;
    #    expected during instance_start() after the initial setup
    warn "Setting initial-data failed."
  }
}

instance_setup_user() {
  # Add a user if the setup secrets file exists.  After the user has been
  # created, the file is renamed.
  verbose 2 "instance_setup_user()"
  local userfile="${PROJECT_DIR}/setup/${USER_SECRETS_FILE}"
  if [[ -r "${userfile}.setup" ]]; then
    call_manage_tool "$PROJECT_DIR" create-user \
      -f "${userfile}.setup" |& tag_output manage
    mv "${userfile}.setup" "$userfile"
  fi
}

instance_setup_organization() {
  # Set fields of organization if the setup file exists. After the organization
  # has been updated, the file is renamed.
  verbose 2 "instance_setup_organization()"
  local file="${PROJECT_DIR}/setup/organization.yml"
  if [[ -r "${file}.setup" ]]; then
    # XXX: The syntax of `openslides set` might change in the future
    call_manage_tool "$PROJECT_DIR" set organization \
      -f "${file}.setup" |& tag_output manage
    mv "${file}.setup" "$file"
  fi
}

migration_stats_filtered() {
  # XXX: This function only works within the update context.  Before using it
  # outside of this context, e.g., for ls, $PROJECT_DIR et al. must be accepted
  # as arguments.
  local filter="${1:-}"
  instance_has_services_running "$PROJECT_STACK_NAME" || {
    verbose 1 "${PROJECT_NAME} is not running; cannot retrieve migration stats."
    return 1
  }
  call_manage_tool "$PROJECT_DIR" "migrations stats" | yq eval "$filter" - ||
    fatal "migrations stats command failed."
}

# Calls appropriate migration command on the manage service depending on present
# cirumstances. Returns 1 if the status afterwards is unexpected.
instance_handle_migrations() {
  ask() {
    [[ -n "$OPT_MIGRATIONS_ASK" ]] ||
      return 0

    local REPLY
    read -p "$* [Y/n]"
    case "$REPLY" in
      Y|y|Yes|yes|YES|"")
        return 0
      ;;
      *)
        return 1
      ;;
    esac
  }
  local backend_versions="$(docker stack services "$PROJECT_STACK_NAME" --format '{{ .Image }}' |
    gawk -F: '$1 ~ /backend/ {a[$2]++} END {print length(a)}')"

  info "Current status of migrations:"
  migration_stats_filtered |& tag_output manage

  ec=0
  case "$(migration_stats_filtered .status)" in
    "$MIGRATIONS_STATUS_NOT_REQ")
      info "No migration required."
      [[ "$(migration_stats_filtered .status)" == "$MIGRATIONS_STATUS_NOT_REQ" ]] || ec=$?; return $ec
    ;;
    "$MIGRATIONS_STATUS_REQ")
      # This is done to ensure the migration index gets updated when it's -1.
      # This is the case for a fresh instance and leads to problems when the
      # first required migration gets skipped because of it.
      if [[ "$(migration_stats_filtered .current_migration_index)" -lt 0 ]]; then
        echo "Negative migration index found. Finalizing in any case to ensure consistency ..."
        call_manage_tool "$PROJECT_DIR" 'migrations finalize' |& tag_output manage
        [[ "$(migration_stats_filtered .status)" == "$MIGRATIONS_STATUS_NOT_REQ" ]] || ec=$?; return $ec
      fi
      # do finalize if switch provided and all backend are on the same (i.e. updated) version
      if [[ -n "$OPT_MIGRATIONS_FINALIZE" ]] && [[ "$backend_versions" -eq 1 ]]; then
        ask "Start migrations and finalize?" || return 1
        echo "Finalizing..."
        call_manage_tool "$PROJECT_DIR" 'migrations finalize' |& tag_output manage
        [[ "$(migration_stats_filtered .status)" == "$MIGRATIONS_STATUS_NOT_REQ" ]] || ec=$?; return $ec
      else
        [[ "$MODE" != start ]] || {
          warn "Finalization of migrations will still be required."
          warn "Call with --migrations-finalize to do it immediately."
        }
        ask "Start migrations now without finalizing?" || return 1
        echo "Migrating..."
        call_manage_tool "$PROJECT_DIR" 'migrations migrate' |& tag_output manage
        [[ "$(migration_stats_filtered .status)" == "$MIGRATIONS_STATUS_FIN_REQ" ]] || ec=$?; return $ec
      fi
    ;;
    "$MIGRATIONS_STATUS_FIN_REQ")
      if [[ -n "$OPT_MIGRATIONS_FINALIZE" ]]; then
        [[ "$MODE" != start ]] || {
          warn "Before finalizing migrations, be sure the whole stack is updated to the new version."
          warn "I.e. you called \`$ME update\`"
        }
        ask "Finalize pending migrations?" || return 1
        echo "Finalizing..."
        call_manage_tool "$PROJECT_DIR" 'migrations finalize' |& tag_output manage
        [[ "$(migration_stats_filtered .status)" == "$MIGRATIONS_STATUS_NOT_REQ" ]] || ec=$?; return $ec
      else
        warn "Migrations have finished but still need to be finilized. Call update with --migrations-finalize"
      fi
    ;;
  esac
}

instance_start() {
  # Re-generate docker-compose.yml/docker-stack.yml
  recreate_compose_yml
  case "$DEPLOYMENT_MODE" in
    "stack")
      PROJECT_STACK_NAME="$(value_from_config_yml "$PROJECT_DIR" '.stackName')"
      docker stack deploy -c "$DCCONFIG" "$PROJECT_STACK_NAME" |&
        tag_output "$DEPLOYMENT_MODE"
      ;;
  esac

  printf "Waiting for instance to become ready."
  wait_for instance_health_status
  printf "Waiting for 'manage' service to become ready."
  wait_for instance_has_manage_service_running

  [[ "$MODE" == "update" ]] || {
    instance_initialdata
    instance_setup_organization
    instance_setup_user
  }
  instance_handle_migrations ||
    fatal "Error during migrations. Aborting."
}

instance_stop() {
  case "$DEPLOYMENT_MODE" in
    "stack")
      PROJECT_STACK_NAME="$(value_from_config_yml "$PROJECT_DIR" '.stackName')"
      docker stack rm "$PROJECT_STACK_NAME" |& tag_output "$DEPLOYMENT_MODE"
    ;;
esac
}

instance_erase() {
  case "$DEPLOYMENT_MODE" in
    "stack")
      instance_stop || true
      info "The database will not be deleted automatically for Swarm deployments." \
        "You must set up a mid-erase hook to perform the deletion."
      ;;
  esac
  run_hook mid-erase
}

instance_update() {
  # Update instance to a new version.
  #
  # This function does two things: 1) it updates the instance's config.yml; 2)
  # for running instances, it updates the containers while minimizing service
  # disruptions.
  # ↓ This is lie at the moment
  # In particular, it ensures that user sessions are not lost.
  # TODO: Implement updating only relvant services (i.e. all exept redis)

  # Check if the instance's configuration is suitable for the automatic update.
  #
  # The update function only sets the default tag (.defaults.tag).  More
  # complex configurations, e.g., service-specific tag overrides, can not be
  # updated automatically.  In these cases, require --force.
  #
  if yq eval --exit-status '.services.*.tag' \
      "${PROJECT_DIR}/config.yml" >/dev/null 2>&1 && [[ "$OPT_FORCE" -ne 1 ]]
  then
    fatal "Custom service tags found which cannot be updated automatically! " \
      "Refusing update.  (Use --force to update the default tag anyway.)"
  fi
  # Equally, it would be a concern if there were images from more than one
  # registry in use.  For simplicity's sake, consider any explicitly configured
  # registries a problem.
  if yq eval --exit-status '.services.*.containerRegistry' \
      "${PROJECT_DIR}/config.yml" >/dev/null 2>&1 && [[ "$OPT_FORCE" -ne 1 ]]
  then
    fatal "Custom service containerRegistry found. " \
      "Refusing update.  (Use --force to update the default tag anyway.)"
  fi

  # Update management tool hash if requested
  if [[ "$OPT_MANAGEMENT_TOOL" = '-' ]]; then
    verbose 1 "Not updating management tool."
  else
    local cfg_hash=$MANAGEMENT_TOOL_HASH
    if [[ "$OPT_MANAGEMENT_TOOL" = '*' ]]; then
      cfg_hash='*'
    fi
    verbose 1 "Updating management tool to $cfg_hash."
    local metadata_string="$(date +"%F %H:%M"): Updated management tool to $cfg_hash"
    update_config_yml "${PROJECT_DIR}/config.yml" \
      ".managementToolHash = \"$cfg_hash\""
    [[ "$cfg_hash" == "$MANAGEMENT_TOOL_HASH" ]] ||
      metadata_string+=" ($MANAGEMENT_TOOL_HASH)"
    append_metadata "$PROJECT_DIR" "$metadata_string"
  fi

  if instance_has_services_running "$PROJECT_STACK_NAME"; then
    verbose 1 "Instance is running; continuing with migrations."
    # For online instances, start database migrations
    instance_update_step_1
    # Continue to update step 2 if --migrations-finalize is set or if there are
    # no migrations required anyway.  Step 2 includes updating the instance
    # configuration files, updating the running containers, and finalizing the
    # database migrations.
    if [[ -n "$OPT_MIGRATIONS_FINALIZE" ]] ||
        [[ "$(migration_stats_filtered .status)" = "$MIGRATIONS_STATUS_NOT_REQ" ]]
    then
      instance_update_step_2
    fi
  else
    # For offline instances, no database migrations can be started.  Instead,
    # simply update the configuration files to the requested version.
    verbose 1 "Instance is not running; skipping migrations."
    instance_update_step_2
  fi
}

instance_update_step_1() {
  local registry=$(value_from_config_yml "$PROJECT_DIR" '.defaults.containerRegistry')
  [[ -n "$registry" ]] || fatal "Could not determine image registry."
  local old_tag=$(value_from_config_yml "$PROJECT_DIR" '.defaults.tag')

  echo "Updating service ${MANAGEMENT_BACKEND} to new version for data migration"
  docker service update -q "${PROJECT_STACK_NAME}_${MANAGEMENT_BACKEND}" \
    --image "$registry/openslides-backend:$DOCKER_IMAGE_TAG_OPENSLIDES" |&
      tag_output "$DEPLOYMENT_MODE"
  printf "Waiting for management service to become ready."
  wait_for instance_has_manage_service_running
  # do step 1 migrations
  instance_handle_migrations || {
    warn "Reverting service ${MANAGEMENT_BACKEND} to old version for management commands to keep working"
    docker service update -q "${PROJECT_STACK_NAME}_${MANAGEMENT_BACKEND}" \
      --image "$registry/openslides-backend:$old_tag" |&
        tag_output "$DEPLOYMENT_MODE"
    fatal "Error during migrations. Aborting."
  }
}

instance_update_step_2() {
  echo "Updating instance configuration."
  # Update values in config.yml
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaults.tag = \"$DOCKER_IMAGE_TAG_OPENSLIDES\""
  update_config_services_db_connect_params
  recreate_compose_yml
  append_metadata "$PROJECT_DIR" "$(date +"%F %H:%M"): Updated all services to" "${DOCKER_IMAGE_TAG_OPENSLIDES}"

  instance_has_services_running "$PROJECT_STACK_NAME" || {
    info "${PROJECT_NAME} is not running."
    echo "      The configuration has been updated and the instance will be upgraded upon its next start."
    echo "      Note that the next start might take a long time due to pending migrations."
    echo "      Consider starting the instance and running migrations now."
    echo "      Alternatively, downgrade for now and run migrations in the background once the instance is started."
    return 0
  }
  # For running instances update the whole stack, will also finalize migrations
  echo "Starting instance."
  instance_start
}

autoscale_gather() {
  local instance
  local shortname
  local normalized_shortname
  if [[ "$#" -gt 0 ]]; then
    instance="$1"
    shortname=$(basename "$instance")
  else
    instance="$PROJECT_DIR"
    shortname="$PROJECT_NAME"
  fi
  [[ -f "${instance}/${DCCONFIG_FILENAME}" ]] && [[ -f "${instance}/config.yml" ]] ||
    fatal "$shortname is not a $DEPLOYMENT_MODE instance."
  normalized_shortname="$(value_from_config_yml "$instance" '.stackName')"

  # if instance not running return
  if ! instance_has_services_running "$normalized_shortname"; then
    return 1
  fi

  # gather active meetings of today and extract number of users
  MEETINGS_TODAY=0
  ACCOUNTS_TODAY=0
  local today=$(date +%s)

  j_meeting_data=$(call_manage_tool "$instance" get meeting --fields start_time,end_time,user_ids)
  for i in $(jq '(. | keys)[]' <<< "$j_meeting_data"); do
    start_time="$(jq ".${i}.start_time" <<< "$j_meeting_data")"
    end_time="$(jq ".${i}.end_time" <<< "$j_meeting_data")"
    users="$(jq ".${i}.user_ids | length" <<< "$j_meeting_data")"
    if [[ "$start_time" == null ]] || [[ "$end_time" == null ]] ||
        [[ "$start_time" -le 0 ]] || [[ "$end_time" -le 0 ]]
    then
      continue
    fi
    # end_time is 00:00h on final event day, but we want scaling to end only on the next day
    # -> add one day minus one second to the timestamp (+ 86399s)
    ((end_time+=86399))
    [[ "$today" -ge "$start_time" ]] && [[ "$today" -le "$end_time" ]] ||
      continue
    ((MEETINGS_TODAY+=1))
    ((ACCOUNTS_TODAY+="$users"))
  done
  if [[ -n "$ACCOUNTS" ]]; then
    # if --accounts was provided overwrite ACCOUNTS_TODAY
    ACCOUNTS_TODAY="$ACCOUNTS"
  else
    # else read current number of users in the instance
    ACCOUNTS=$(call_manage_tool "$instance" get user --fields id | jq '. | length')
  fi

  # ask current scalings from docker
  while read -r service s_scale; do
    [[ "$s_scale" =~ ([0-9]+)/([0-9]+) ]]
    SCALE_RUNNING["$service"]="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    SCALE_FROM["$service"]="${BASH_REMATCH[2]}"
    # will be overwritten when parsing config
    SCALE_TO["$service"]="${BASH_REMATCH[2]}"
  done < <(docker stack services --format '{{ .Name }} {{ .Replicas }}' "$normalized_shortname" |
    gawk '{ sub(/^.+_/, "", $1); print } ')

  # fallback: autoscale everything to 1 if not configured otherwise
  [[ -n "$AUTOSCALE_ACCOUNTS_OVER" ]] ||
    AUTOSCALE_ACCOUNTS_OVER[0]="auth=1 autoupdate=1 backend=1 backendAction=1 backendPresenter=1 backendManage=1 client=1 datastoreReader=1 datastoreWriter=1 icc=1 manage=1 media=1 proxy=1 redis=1 vote=1"

  [[ -n "$AUTOSCALE_RESET_ACCOUNTS_OVER" ]] ||
    AUTOSCALE_RESET_ACCOUNTS_OVER[0]="auth=1 autoupdate=1 backend=1 backendAction=1 backendPresenter=1 backendManage=1 client=1 datastoreReader=1 datastoreWriter=1 icc=1 manage=1 media=1 proxy=1 redis=1 vote=1"

  # parse scale goals from configuration
  # make sure indices are in ascending order
  if [[ "$MEETINGS_TODAY" -eq 0 ]]; then
    tlist=$(echo "${!AUTOSCALE_RESET_ACCOUNTS_OVER[@]}" | tr " " "\n" | sort -g | tr "\n" " ")
    accounts="$ACCOUNTS"
  else
    tlist=$(echo "${!AUTOSCALE_ACCOUNTS_OVER[@]}" | tr " " "\n" | sort -g | tr "\n" " ")
    accounts="$ACCOUNTS_TODAY"
  fi
  for threshold in $tlist; do
    if [[ "$accounts" -ge "$threshold" ]]; then
      if [[ "$MEETINGS_TODAY" -eq 0 ]]; then
        scalings="${AUTOSCALE_RESET_ACCOUNTS_OVER[$threshold]}"
      else
        scalings="${AUTOSCALE_ACCOUNTS_OVER[$threshold]}"
      fi
      # parse scalings string one by one ...
      while [[ $scalings =~ ^\ *([a-zA-Z0-9-]+)=([0-9]+)\ * ]]; do
        # and update array
        SCALE_TO["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        # truncate parsed info
        scalings="${scalings:${#BASH_REMATCH[0]}}"
      done
      # if len(scalings) != 0 not every value matched the regex
      [[ -z "$scalings" ]] ||
        fatal "scaling values could not be parsed, see: $scalings"
    fi
  done
}

instance_autoscale() {
  declare -A services_changed=()
  log_scale() { # Append to metadata
    for service in ${!services_changed[@]}
    do
      append_metadata "$PROJECT_DIR" "$(date +"%F %H:%M"):"\
        "Autoscaled $service from ${SCALE_FROM[$service]} to ${SCALE_TO[$service]}"
    done
  }

  autoscale_gather ||
    fatal "Cannot autoscale stopped instance"

  declare -A scale_commands=()

  # determine services on which action needs to be taken
  for service in "${!SCALE_FROM[@]}"
  do
    # never scale if nothing to do
    [[ "${SCALE_FROM[$service]}" -ne "${SCALE_TO[$service]}" ]] ||
      continue
    # only scale if scaling up or no meeting today (substitute for --allow-downscale behavior)
    [[ "${SCALE_FROM[$service]}" -lt "${SCALE_TO[$service]}" ]] ||
        [[ "$MEETINGS_TODAY" -eq 0 ]] ||
      continue

    scale_commands[$service]="docker service scale ${PROJECT_STACK_NAME}_${service}=${SCALE_TO[$service]}"
  done

  # print out overview
  local fmt_str="%-24s %-12s %-12s\n"
  # headline
  if [[ "$MEETINGS_TODAY" -eq 0 ]]; then
    echo "Resetting scalings of $PROJECT_NAME to handle $ACCOUNTS accounts in idle mode. $MEETINGS_TODAY meetings on $(date +%F)."
  else
    echo "Scaling $PROJECT_NAME to handle $ACCOUNTS_TODAY accounts in $MEETINGS_TODAY meetings on $(date +%F)."
  fi
  printf "$fmt_str" "<service>" "<scale from>" "<scale to>"
  # body
  for service in "${!scale_commands[@]}"
  do
    printf "$fmt_str" "$service" "${SCALE_RUNNING[$service]}" "${SCALE_TO[$service]}"
  done

  # all services are already appropriately scaled
  [[ ${#scale_commands[@]} -gt 0 ]] || {
    echo "No action required"
    return 0
  }

  # if dry run, print commands instead of performing them
  [[ -z "$OPT_DRY_RUN" ]] ||
    echo "!DRY RUN!"
  # docker scale commands 
  for service in "${!scale_commands[@]}"
  do
    if [[ -n "$OPT_DRY_RUN" ]]; then
      echo "${scale_commands[$service]}"
    else
      ${scale_commands[$service]}
      services_changed[$service]=1
    fi
  done

  log_scale
}

instance_has_locks() {
  local instance=$1
  local lockfile="${INSTANCES}/${instance}/${LOCKFILE}"
  if [[ -f "$lockfile" ]] && [[ $(wc -l < "$lockfile" ) -ge 1 ]]; then
    return 0
  else
    return 1
  fi
}

action_is_locked() {
  local instance=$1
  local action_query=${2:-all}
  local lockfile="${INSTANCES}/${instance}/${LOCKFILE}"
  local action locktime name email reason
  [[ -d "${INSTANCES}/${instance}" ]] || fatal "Illegal argument to action_is_locked()?"
  if [[ -f "${lockfile}" ]]; then
    while IFS=$'\t' read -r action locktime name email reason; do
      if [[ "$action" = "$action_query" ]] || [[ "$action" = "all" ]] || [[ "$action_query" = "all" ]]; then
        locktime=$(date -d "@$locktime" -I)
        echo "Action '$action' locked by ${name} (${email}) on ${locktime}: ${reason}"
        return 0
      fi
    done < "${lockfile}"
  fi
  echo "Action '$action_query' not locked."
  return 1
}

instance_lock() {
  local instance=$1
  local lockfile="${INSTANCES}/${instance}/${LOCKFILE}"
  local is_locked
  read -p "Reason: "
  [[ -n "$REPLY" ]] || fatal "Need a reason to lock instance."
  for i in "${OPT_LOCK_ACTION[@]:-all}"; do
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$i"); then
      warn "Already locked: $is_locked"
    else
      local locktime=$(date "+%s")
      touch "${lockfile}"
      printf "%s\t%d\t%s\t%s\t%s\n" "${i}" "$locktime" "${LOGNAME:-"unknown"}" \
        "${EMAIL:-"unknown"}" "$REPLY" >> "${lockfile}"
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): $i locked by ${LOGNAME:-"unknown"} (${EMAIL:-"unknown"}): $REPLY"
      echo "Action '$i' has been locked on ${PROJECT_NAME}."
    fi
  done
}

instance_unlock() {
  local instance=$1
  local lockfile="${INSTANCES}/${instance}/${LOCKFILE}"
  local is_locked
  for i in "${OPT_LOCK_ACTION[@]:-all}"; do
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$i"); then
      if [[ "$i" = "all" ]]; then
        rm "${lockfile}"
      else
        local tmp=$(mktemp)
        gawk -F'\t' -va="$i" '$1 == a {next} 1' "${lockfile}" >| "$tmp"
        mv "$tmp" "${lockfile}"
      fi
      echo "Action '$i' has been unlocked on ${PROJECT_NAME}."
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): $i unlocked by ${LOGNAME:-"unknown"} (${EMAIL:-"unknown"})"
    else
      verbose 1 "$is_locked"
    fi
  done
}

run_hook() {
  local hook hook_name
  [[ -d "$HOOKS_DIR" ]] || return 0
  hook_name="$1"
  hook="${HOOKS_DIR}/${hook_name}"
  shift
  if [[ -x "$hook" ]]; then
    cd "$PROJECT_DIR"
    echo "Running $hook_name hook..."
    set +eu
    (. "$hook")
    set -eu
    echo "End of $hook_name hook."
  fi
}

trap clean_up EXIT

# In order to be able to switch deployment modes, it should probably be added
# as an explicit option.  The program name based setting (osinstancectl vs.
# osstackctl) has led to problems in the past.
DEPLOYMENT_MODE=stack

shortopt="halsjmiMnfed:t:O:"
longopt=(
  help
  color:
  json
  project-dir:
  force
  no-pid-file
  verbose

  # display options
  long
  services
  secrets
  metadata
  stats

  # Template opions
  compose-template:
  config-template:

  # filtering
  all
  online
  offline
  error
  locked
  unlocked
  version:
  search-metadata
  fast
  patient

  # adding instances
  clone-from:
  local-only
  no-add-account

  # adding & upgrading instances
  tag:
  management-tool:
  migrations-finalize
  migrations-no-ask

  # autoscaling
  accounts:
  dry-run

  # locking
  action:
)
# format options array to comma-separated string for getopt
longopt=$(IFS=,; echo "${longopt[*]}")

ARGS=$(getopt -o "$shortopt" -l "$longopt" -n "$ME" -- "$@")
if [ $? -ne 0 ]; then usage; exit 1; fi
eval set -- "$ARGS";
unset ARGS

# Config file
if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
fi

# Parse options
while true; do
  case "$1" in
    --no-pid-file)
      OPT_PIDFILE=
      shift 1
      ;;
    -d|--project-dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    --compose-template)
      COMPOSE_TEMPLATE="$2"
      [[ -r "$COMPOSE_TEMPLATE" ]] || fatal "$COMPOSE_TEMPLATE not found."
      shift 2
      ;;
    --config-template)
      CONFIG_YML_TEMPLATE="$2"
      [[ -r "$CONFIG_YML_TEMPLATE" ]] || fatal "$CONFIG_YML_TEMPLATE not found."
      shift 2
      ;;
    -t|--tag)
      DOCKER_IMAGE_TAG_OPENSLIDES="$2"
      shift 2
      ;;
    -O|--management-tool)
      OPT_MANAGEMENT_TOOL=$2
      shift 2
      ;;
    --no-add-account)
      OPT_ADD_ACCOUNT=
      shift 1
      ;;
    --migrations-finalize)
      OPT_MIGRATIONS_FINALIZE=1
      shift 1
      ;;
    --migrations-no-ask)
      OPT_MIGRATIONS_ASK=
      shift 1
      ;;
    -a|--all)
      OPT_LONGLIST=1
      OPT_METADATA=1
      OPT_IMAGE_INFO=1
      OPT_SECRETS=1
      OPT_SERVICES=1
      OPT_STATS=1
      shift 1
      ;;
    --services)
      OPT_SERVICES=1
      shift 1
      ;;
    --stats)
      OPT_STATS=1
      shift 1
      ;;
    -l|--long)
      OPT_LONGLIST=1
      shift 1
      ;;
    -s|--secrets)
      OPT_SECRETS=1
      shift 1
      ;;
    -m|--metadata)
      OPT_METADATA=1
      shift 1
      ;;
    -M|--search-metadata)
      OPT_METADATA_SEARCH=1
      shift 1
      ;;
    -j|--json)
      OPT_JSON=1
      shift 1
      ;;
    -n|--online)
      FILTER_RUNNING_STATE="online"
      shift 1
      ;;
    -f|--offline)
      FILTER_RUNNING_STATE="stopped"
      shift 1
      ;;
    -e|--error)
      FILTER_RUNNING_STATE="error"
      shift 1
      ;;
    --version)
      FILTER_VERSION="$2"
      shift 2
      ;;
    --locked)
      FILTER_LOCKED_STATE="locked"
      shift 1
      ;;
    --unlocked)
      FILTER_LOCKED_STATE="unlocked"
      shift 1
      ;;
    --action)
      OPT_LOCK_ACTION+=($2)
      shift 2
      ;;
    --clone-from)
      CLONE_FROM="$2"
      shift 2
      ;;
    --local-only)
      OPT_LOCALONLY=1
      shift 1
      ;;
    --color)
      OPT_COLOR="$2"
      shift 2
      ;;
    --force)
      OPT_FORCE=1
      shift 1
      ;;
    --fast)
      OPT_FAST=1
      OPT_PATIENT=
      shift 1
      ;;
    --patient)
      OPT_PATIENT=1
      OPT_USE_PARALLEL=0
      OPT_FAST=
      CURL_OPTS=(--max-time 60 --retry 5 --retry-delay 1 --retry-max-time 0)
      shift 1
      ;;
    --accounts)
      ACCOUNTS="$2"
      shift 2
      ;;
    --dry-run)
      OPT_DRY_RUN=1
      shift 1
      ;;
    --verbose)
      OPT_VERBOSE=$((OPT_VERBOSE +1))
      shift 1
      ;;
    -h|--help) USAGE=1; break;;
    --) shift ; break ;;
    *) usage; exit 1 ;;
  esac
done

# Parse commands
for arg; do
  case $arg in
    help)
      USAGE=1
      shift 1
      ;;
    ls|list)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=list
      shift 1
      ;;
    add|create)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=create
      [[ -z "$CLONE_FROM" ]] || MODE=clone
      shift 1
      ;;
    rm|remove)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=remove
      shift 1
      ;;
    start|up)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=start
      shift 1
      ;;
    stop|down)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=stop
      shift 1
      ;;
    erase)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=erase
      shift 1
      ;;
    update)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=update
      shift 1
      ;;
    autoscale)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=autoscale
      shift 1
      ;;
    manage)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=manage
      shift 1
      ;;
    lock)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=lock
      shift 1
      ;;
    unlock)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=unlock
      shift 1
      ;;
    setup)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=setup
      shift 1
      ;;
    *)
      # The final argument should be the project name/search pattern
      PROJECT_NAME="$arg"
      shift 1
      break
      ;;
  esac
done

case "$OPT_COLOR" in
  auto)
    if [[ -t 1 ]]; then enable_color; fi ;;
  always)
    enable_color ;;
  never) true ;;
  *)
    fatal "Unknown option to --color" ;;
esac

# Config file
if [[ -f "$CONFIG" ]]; then
  verbose 1 "Applying options from ${CONFIG}."
  # This actually happens before option parsing but is only printed here, so
  # the --verbose options have been evaluated.
fi

# Use GNU parallel if found
if [[ "$OPT_USE_PARALLEL" -ne 0 ]] && [[ -f /usr/bin/env_parallel.bash ]]; then
  source /usr/bin/env_parallel.bash
  OPT_USE_PARALLEL=1
  verbose 2 "GNU parallel is enabled."
else
  verbose 2 "GNU parallel is disabled."
fi

# Check if user has access to docker
if docker info >/dev/null 2>&1; then
  HAS_DOCKER_ACCESS=1
fi

# PROJECT_NAME should be lower-case
PROJECT_NAME="$(echo "$PROJECT_NAME" | tr '[A-Z]' '[a-z]')"

# Prevent --project-dir to be used together with a project name
if [[ -n "$PROJECT_DIR" ]] && [[ -n "$PROJECT_NAME" ]]; then
  fatal "Mutually exclusive options"
fi
# Deduce project name from path
if [[ -n "$PROJECT_DIR" ]]; then
  PROJECT_NAME="$(basename "$(readlink -f "$PROJECT_DIR")")"
  OPT_METADATA_SEARCH=
# Treat the project name "." as --project-dir=.
elif [[ "$PROJECT_NAME" = "." ]]; then
  PROJECT_NAME="$(basename "$(readlink -f "$PROJECT_NAME")")"
  PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
  OPT_METADATA_SEARCH=
  # Signal that the project name is based on the directory and could be
  # transformed into a more precise regexp internally:
  OPT_PRECISE_PROJECT_NAME=1
else
  PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
fi

# The project name is a valid domain which is not suitable as a Docker
# stack name.  Here, we remove all dots from the domain which turns the
# domain into a compatible name.  This also appears to be the method
# docker-compose uses to name its containers, networks, etc.
PROJECT_STACK_NAME="$(echo "$PROJECT_NAME" | tr -d '.')"

verbose 1 "Configuring for deployment mode: ${DEPLOYMENT_MODE}."
case "$DEPLOYMENT_MODE" in
  "stack")
    DCCONFIG_FILENAME="docker-stack.yml"
    ;;
esac
DCCONFIG="${PROJECT_DIR}/${DCCONFIG_FILENAME}"

# If `help`, then the next argument is the mode to look up usage info for
if [[ "$USAGE" ]]; then
  HELP_TOPIC=$MODE
  MODE=help
fi

case "$MODE" in
  help)
    usage
    ;;
  setup)
    self_setup
    ;;
  remove)
    create_and_check_pid_file
    arg_check
    # Check that instance was created by osinstancectl
    [[ -n "$OPT_FORCE" ]] || marker_check "$PROJECT_DIR" ||
      fatal "Refusing to delete unless --force is given."
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    # Ask for confirmation
    ANS=
    echo "Delete the following instance including all of its data and configuration?"
    # Show instance listing
    OPT_LONGLIST=1 OPT_STATS=1 OPT_METADATA=1 OPT_METADATA_SEARCH= \
      ls_instance "$PROJECT_DIR" | colorize_ls
    echo
    read -rp "Really delete? (uppercase YES to confirm) " ANS
    [[ "$ANS" = "YES" ]] || exit 0
    run_hook "pre-${MODE}"
    remove "$PROJECT_NAME"
    echo "Done."
    ;;
  create)
    create_and_check_pid_file
    arg_check
    # Use defaults in the absence of options
    echo "Creating new instance: $PROJECT_NAME"
    # If not specified, set management tool to the latest available version.
    [[ -n "$OPT_MANAGEMENT_TOOL" ]] || OPT_MANAGEMENT_TOOL=$DEFAULT_MANAGEMENT_VERSION
    verbose 2 "OPT_MANAGEMENT_TOOL=$OPT_MANAGEMENT_TOOL"
    query_user_account_name
    select_management_tool
    PORT=$(next_free_port)
    create_instance_dir
    {
      update_config_instance_specifics
      create_admin_secrets_file
      create_user_setup_file "${OPENSLIDES_USER_FIRSTNAME}" \
        "${OPENSLIDES_USER_LASTNAME}" "${OPENSLIDES_USER_EMAIL}"
      create_organization_setup_file
      update_config_services_db_connect_params
      recreate_compose_yml
      append_metadata "$PROJECT_DIR" ""
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): Instance created (${DEPLOYMENT_MODE})"
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): image=$DOCKER_IMAGE_TAG_OPENSLIDES manage=$MANAGEMENT_TOOL_HASH"
      [[ -z "$OPT_LOCALONLY" ]] ||
        append_metadata "$PROJECT_DIR" "No HAProxy config added (--local-only)"
      add_to_haproxy_cfg
      run_hook "post-${MODE}"
      ask_start || true
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  clone)
    create_and_check_pid_file
    CLONE_FROM_DIR="${INSTANCES}/${CLONE_FROM}"
    arg_check
    # Check instance's lock status
    if is_locked=$(action_is_locked "${CLONE_FROM}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    echo "Creating new instance: $PROJECT_NAME (based on $CLONE_FROM)"
    select_management_tool
    PORT=$(next_free_port)
    run_hook "pre-${MODE}"
    create_instance_dir
    {
      clone_instance_dir
      update_config_instance_specifics
      update_config_services_db_connect_params
      recreate_compose_yml
      append_metadata "$PROJECT_DIR" ""
      append_metadata "$PROJECT_DIR" "Cloned from $CLONE_FROM on $(date)"
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): image=$(value_from_config_yml "$PROJECT_DIR" '.defaults.tag')" \
        "manage=$MANAGEMENT_TOOL_HASH"
      [[ -z "$OPT_LOCALONLY" ]] ||
        append_metadata "$PROJECT_DIR" "No HAProxy config added (--local-only)"
      add_to_haproxy_cfg
      run_hook "post-${MODE}"
      ask_start || true
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  list)
    arg_check
    [[ -z "$OPT_PRECISE_PROJECT_NAME" ]] || PROJECT_NAME="^${PROJECT_NAME}$"
    list_instances
    ;;
  start)
    create_and_check_pid_file
    arg_check
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    {
      select_management_tool
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): Starting with manage=$MANAGEMENT_TOOL_HASH"
      instance_start
      run_hook "post-${MODE}"
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  stop)
    create_and_check_pid_file
    arg_check
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    {
      instance_stop
      run_hook "post-${MODE}"
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  erase)
    create_and_check_pid_file
    arg_check
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    # Ask for confirmation
    ANS=
    echo "Stop the following instance, and remove its containers and volumes?"
    # Show instance listing
    OPT_LONGLIST=1 OPT_STATS=1 OPT_METADATA=1 OPT_METADATA_SEARCH= \
      ls_instance "$PROJECT_DIR" | colorize_ls
    echo
    read -rp "Really delete? (uppercase YES to confirm) " ANS
    [[ "$ANS" = "YES" ]] || exit 0
    {
      instance_erase
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  update)
    create_and_check_pid_file
    arg_check
    # Check that instance was created by osinstancectl
    [[ -n "$OPT_FORCE" ]] || marker_check "$PROJECT_DIR" ||
      fatal "Refusing to delete unless --force is given."
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    # If not specified on the command line, set management tool to the latest
    # available version.  Do not simply read the current, i.e., outdated,
    # version from config.yml.
    [[ -n "$OPT_MANAGEMENT_TOOL" ]] || OPT_MANAGEMENT_TOOL=$DEFAULT_MANAGEMENT_VERSION
    verbose 2 "OPT_MANAGEMENT_TOOL=$OPT_MANAGEMENT_TOOL"
    {
      select_management_tool
      append_metadata "$PROJECT_DIR" \
        "$(date +"%F %H:%M"): Update using manage=$MANAGEMENT_TOOL_HASH"
      run_hook "pre-${MODE}"
      instance_update
      run_hook "post-${MODE}"
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  autoscale)
    create_and_check_pid_file
    arg_check
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    {
      select_management_tool
      instance_autoscale
      echo "Done."
    } |& log_output "${PROJECT_DIR}"
    ;;
  manage)
    create_and_check_pid_file
    arg_check || { usage; exit 2; }
    # Check instance's lock status
    if is_locked=$(action_is_locked "${PROJECT_NAME}" "$MODE"); then
      fatal "Can not $MODE instance: $is_locked"
    else
      verbose 1 "$MODE action is not locked."
    fi
    select_management_tool
    call_manage_tool "$PROJECT_DIR" "$@"
    ;;
  lock)
    arg_check
    instance_lock "$PROJECT_NAME"
    ;;
  unlock)
    arg_check
    instance_unlock "$PROJECT_NAME"
    ;;
  *)
    fatal "Missing command.  Please consult $ME --help."
    ;;
esac
