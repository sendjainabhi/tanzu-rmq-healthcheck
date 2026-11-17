#!/usr/bin/env bash
# Tanzu RabbitMQ Tile 4.x / Tanzu Platform 10+ read-only health assessment
# READ-ONLY: No packages installed, no SSH, no config changes.
# Requires bash 4+. Optional: curl, jq, openssl, bosh, cf (pre-existing only).
# No credentials are written to any report file.
set -u
ORIG_ARGS=("$@")
VERSION='1.0.0'
DO_INIT=0; CHECK_CONFIG=0

# ANSI colors — disabled when stdout is not a terminal
if [[ -t 1 ]]; then
  _G='\033[0;32m' _R='\033[0;31m' _Y='\033[0;33m' _B='\033[0;36m' _W='\033[1m' _X='\033[0m'
else
  _G='' _R='' _Y='' _B='' _W='' _X=''
fi

# ── Defaults ────────────────────────────────────────────────────────────────
CUSTOMER=''; CLUSTER=''; URL=''; EXPECTED=''
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/reports"
BOSH_DEP=''; BOSH_ENV=''; BOSH_CLIENT_VAR=''; BOSH_SECRET=''; BOSH_CA=''
USERNAME=''; PASSWORD=''; NO_PACKAGE=0; CONFIG_FILE=''; CURL_INSECURE=0

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: ./tanzu_rmq_healthcheck.sh [--config FILE] [options]

Required (minimum config):
  --customer NAME        Customer/org short name (used in filenames)
  --url URL              RabbitMQ Management API base URL (https://HOST or https://HOST:PORT)

Credentials:
  --username NAME        RabbitMQ user ID
  --password PASS        RabbitMQ password
                         If not provided, script will prompt on TTY

Auto-detected from cluster (no need to specify):
  --cluster NAME         Friendly cluster label — derived from URL hostname if omitted
  --expected-nodes N     Expected running nodes — detected from /api/nodes if omitted

Optional:
  --config FILE          Read values from key=value config file
  --output DIR           Output directory (default: ./reports/ alongside the script)
  --bosh-deployment NAME BOSH deployment name for VM inventory
  --no-package           Skip ZIP packaging

READ-ONLY: No packages installed. No SSH. No config changes.
No credentials or message payloads are written to reports.

Minimum config file:
  customer=AcmeCorp
  url=https://rmq-host.example.com
  username=monitor-user
  password=S3cur3P@ss

Full config file (all options):
  customer=AcmeCorp
  url=https://rmq-host.example.com
  username=monitor-user
  password=S3cur3P@ss
  cluster=rmq-prod-01        # optional: auto-derived from URL if omitted
  expected_nodes=3           # optional: auto-detected from API if omitted
  output=./reports           # optional: default is ./reports
  bosh_deployment=           # optional: BOSH deployment name for VM inventory
  bosh_environment=          # optional: BOSH Director IP or hostname
  bosh_client=               # optional: BOSH client / username
  bosh_client_secret=        # optional: BOSH client secret / password
  bosh_ca_cert=              # optional: path to BOSH Director CA certificate file
USAGE
}

# ── Config file parser (CLI args override config) ────────────────────────────
load_config() {
  local file=$1
  [[ -f $file && ! -L $file ]] || { echo "Config file not found: $file" >&2; exit 4; }
  while IFS='=' read -r key val; do
    # strip comments and blank lines
    [[ $key =~ ^[[:space:]]*# || -z ${key// /} ]] && continue
    key=${key//[[:space:]]/}
    val=${val#"${val%%[! ]*}"}   # ltrim
    val=${val%"${val##*[! ]}"}   # rtrim
    case "$key" in
      customer)         [[ -z $CUSTOMER ]] && CUSTOMER=$val ;;
      cluster)          [[ -z $CLUSTER  ]] && CLUSTER=$val  ;;
      url)              [[ -z $URL      ]] && URL=$val       ;;
      expected_nodes)   [[ -z $EXPECTED ]] && EXPECTED=$val ;;
      output)           OUT=$val ;;
      username)         [[ -z $USERNAME  ]] && USERNAME=$val  ;;
      password)         [[ -z $PASSWORD  ]] && PASSWORD=$val  ;;
      bosh_deployment)    [[ -z $BOSH_DEP        ]] && BOSH_DEP=$val        ;;
      bosh_environment)   [[ -z $BOSH_ENV        ]] && BOSH_ENV=$val        ;;
      bosh_client)        [[ -z $BOSH_CLIENT_VAR ]] && BOSH_CLIENT_VAR=$val ;;
      bosh_client_secret) [[ -z $BOSH_SECRET     ]] && BOSH_SECRET=$val     ;;
      bosh_ca_cert)       [[ -z $BOSH_CA         ]] && BOSH_CA=$val         ;;
    esac
  done < "$file"
}

# ── Setup wizard (--init) ────────────────────────────────────────────────────
init_wizard() {
  local cfg_path="${1:-rmq.conf}"
  local sep='================================================================'
  printf '\n%s\n  Tanzu RabbitMQ Health Check — Setup Wizard\n%s\n\n' "$sep" "$sep"
  printf '  This will create a config file so you can run the health check\n'
  printf '  with a single command next time.\n\n'

  local _cust _url _user _pass _bosh_ans
  read -r -p "  Customer / organisation name (e.g. Acme-Corp): " _cust
  read -r -p "  RabbitMQ cluster URL   (e.g. https://rmq-host.example.com): " _url
  read -r -p "  RabbitMQ user ID: " _user
  read -r -s -p "  RabbitMQ password: " _pass; printf '\n'

  # Strip path from URL if pasted with /api/...
  _url=${_url%/}
  if [[ $_url =~ ^(https?://[^/]+)/.+ ]]; then
    _url="${BASH_REMATCH[1]}"
    printf '  Note: path removed from URL — using %s\n' "$_url"
  fi

  printf '\n  BOSH Director access enables VM infrastructure checks (optional).\n'
  read -r -p "  Do you have BOSH Director access? [y/N]: " _bosh_ans

  local _bosh_section=''
  if [[ ${_bosh_ans,,} == 'y' ]]; then
    local _bosh_dep _bosh_env _bosh_client _bosh_secret _bosh_ca
    read -r -p "  BOSH deployment name (run 'bosh deployments' to find it): " _bosh_dep
    read -r -p "  BOSH Director IP or hostname: " _bosh_env
    read -r -p "  BOSH client / username (usually ops_manager): " _bosh_client
    read -r -s -p "  BOSH client secret: " _bosh_secret; printf '\n'
    read -r -p "  Path to BOSH CA cert file on this machine: " _bosh_ca
    _bosh_section="
bosh_deployment=${_bosh_dep}
bosh_environment=${_bosh_env}
bosh_client=${_bosh_client}
bosh_client_secret=${_bosh_secret}
bosh_ca_cert=${_bosh_ca}"
    unset _bosh_secret
  fi

  umask 077
  printf 'customer=%s\nurl=%s\nusername=%s\npassword=%s%s\n' \
    "$_cust" "$_url" "$_user" "$_pass" "$_bosh_section" > "$cfg_path"
  unset _pass

  printf '\n  Config saved to: %s\n' "$cfg_path"
  printf '\n  Run the health check with:\n'
  printf '    bash tanzu_rmq_healthcheck.sh --config %s\n\n' "$cfg_path"
  printf '%s\n\n' "$sep"
}

# ── CLI argument parsing ─────────────────────────────────────────────────────
while (($#)); do
  case "$1" in
    --config)           [[ $# -ge 2 ]] || { usage; exit 4; }; CONFIG_FILE=$2; shift 2 ;;
    --customer)         [[ $# -ge 2 ]] || { usage; exit 4; }; CUSTOMER=$2;    shift 2 ;;
    --cluster)          [[ $# -ge 2 ]] || { usage; exit 4; }; CLUSTER=$2;     shift 2 ;;
    --url)              [[ $# -ge 2 ]] || { usage; exit 4; }; URL=$2;         shift 2 ;;
    --expected-nodes)   [[ $# -ge 2 ]] || { usage; exit 4; }; EXPECTED=$2;    shift 2 ;;
    --output)           [[ $# -ge 2 ]] || { usage; exit 4; }; OUT=$2;         shift 2 ;;
    --username)         [[ $# -ge 2 ]] || { usage; exit 4; }; USERNAME=$2;   shift 2 ;;
    --password)         [[ $# -ge 2 ]] || { usage; exit 4; }; PASSWORD=$2;   shift 2 ;;
    --bosh-deployment)  [[ $# -ge 2 ]] || { usage; exit 4; }; BOSH_DEP=$2;  shift 2 ;;
    --init)             DO_INIT=1; shift ;;
    --check-config)     CHECK_CONFIG=1; shift ;;
    --no-package)       NO_PACKAGE=1; shift ;;
    --insecure)         CURL_INSECURE=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 4 ;;
  esac
done

# Load config file (CLI args already set take precedence)
[[ -n $CONFIG_FILE ]] && load_config "$CONFIG_FILE"

# Run setup wizard if --init was requested
((DO_INIT)) && { init_wizard "${CONFIG_FILE:-rmq.conf}"; exit 0; }

# ── Interactive prompts — only customer and url are required ─────────────────
if [[ -t 0 ]]; then
  if [[ -z $CUSTOMER ]]; then
    read -r -p 'Customer / organisation name (letters, numbers, hyphens): ' CUSTOMER
  fi
  if [[ -z $URL ]]; then
    read -r -p 'RabbitMQ Management API URL (https://HOST or https://HOST:PORT): ' URL
  fi
fi

# ── Validate URL format ───────────────────────────────────────────────────────
[[ -n $CUSTOMER ]] || CUSTOMER='unknown-customer'
[[ $CUSTOMER =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'Customer name must contain only letters, numbers, underscore, dot, hyphen' >&2; exit 4; }
[[ -z $EXPECTED || $EXPECTED =~ ^[1-9][0-9]*$ ]] || { echo 'Expected nodes must be a positive integer' >&2; exit 4; }
# Auto-strip /api/... path if user pasted a full URL
if [[ -n $URL && $URL =~ ^(https?://[^/]+)/.+ ]]; then
  printf 'Note: path removed from URL — using %s\n' "${BASH_REMATCH[1]}" >&2
  URL="${BASH_REMATCH[1]}"
fi
[[ -z $URL || $URL =~ ^https?://[^/]+/?$ ]] || {
  echo 'Invalid URL. Use just the hostname: https://your-rmq-host.example.com' >&2
  echo 'Remove any /api/... path, credentials, or query string from the URL.' >&2
  exit 4
}
URL=${URL%/}

# ── Auto-derive cluster name from URL hostname if not set ────────────────────
if [[ -z $CLUSTER && -n $URL ]]; then
  _host=${URL#https://}; _host=${_host#http://}; _host=${_host%%:*}; _host=${_host%%/*}
  _seg=${_host%%.*}          # first subdomain segment
  CLUSTER=${_seg:0:24}       # cap at 24 chars to keep filenames manageable
  unset _host _seg
fi
[[ -n $CLUSTER ]] || CLUSTER='unknown-cluster'
# sanitize for filesystem use
CLUSTER=${CLUSTER//[^a-zA-Z0-9_.-]/-}

# ── Directory and log setup ──────────────────────────────────────────────────
STAMP=$(date -u +%Y%m%d_%H%M%S 2>/dev/null || printf unknown)
SAFE_CUSTOMER=${CUSTOMER//[^a-zA-Z0-9_.-]/_}
SAFE_CLUSTER=${CLUSTER//[^a-zA-Z0-9_.-]/_}
RUNID="${SAFE_CUSTOMER}_healthcheck_${STAMP}"
DIR="$OUT/$RUNID"
if ! mkdir -p "$DIR" 2>/dev/null; then
  DIR="${TMPDIR:-/tmp}/$RUNID"
  mkdir -p "$DIR" 2>/dev/null || { echo 'Cannot create report directory' >&2; exit 4; }
fi

RESULTS="$DIR/.checks.jsonl"; : > "$RESULTS"
ERRORS="$DIR/errors.log";     : > "$ERRORS"
EXEC="$DIR/execution.log";    : > "$EXEC"

log() { printf '%s | %s\n' "$(date -u +%FT%TZ)" "$*" >> "$EXEC"; }
err() { printf '%s | %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ERRORS"; log "ERROR: $*"; }
progress() { [[ -t 1 ]] && printf "${_B}  ▸ %s${_X}\n" "$1"; log "progress: $1"; }

# Track API endpoint results for the metadata table
declare -A API_RESULTS=()

# ── Tool detection ───────────────────────────────────────────────────────────
HAVE_JQ=0; HAVE_CURL=0; HAVE_SSL=0; HAVE_BOSH=0; HAVE_CF=0
command -v jq      >/dev/null 2>&1 && HAVE_JQ=1
command -v curl    >/dev/null 2>&1 && HAVE_CURL=1
command -v openssl >/dev/null 2>&1 && HAVE_SSL=1
command -v bosh    >/dev/null 2>&1 && HAVE_BOSH=1
command -v cf      >/dev/null 2>&1 && HAVE_CF=1

# Export BOSH connection vars from config (only if not already set in environment)
[[ -n $BOSH_ENV        && -z ${BOSH_ENVIRONMENT:-}   ]] && export BOSH_ENVIRONMENT="$BOSH_ENV"
[[ -n $BOSH_CLIENT_VAR && -z ${BOSH_CLIENT:-}        ]] && export BOSH_CLIENT="$BOSH_CLIENT_VAR"
[[ -n $BOSH_SECRET     && -z ${BOSH_CLIENT_SECRET:-} ]] && export BOSH_CLIENT_SECRET="$BOSH_SECRET"
[[ -n $BOSH_CA         && -z ${BOSH_CA_CERT:-}       ]] && export BOSH_CA_CERT="$BOSH_CA"

# ── JSON helpers ─────────────────────────────────────────────────────────────
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# add category id title status actual baseline recommendation evidence
add() {
  local cat=$1 id=$2 title=$3 state=$4 actual=$5 base=$6 rec=$7 evidence=${8:-}
  if ((HAVE_JQ)); then
    jq -cn \
      --arg c "$cat" --arg id "$id" --arg t "$title" --arg s "$state" \
      --arg a "$actual" --arg b "$base" --arg r "$rec" --arg e "$evidence" \
      '{category:$c,id:$id,title:$t,status:$s,actual:$a,baseline:$b,recommendation:$r,evidence:$e}' \
      >> "$RESULTS"
  else
    printf '{"category":"%s","id":"%s","title":"%s","status":"%s","actual":"%s","baseline":"%s","recommendation":"%s","evidence":"%s"}\n' \
      "$(json_escape "$cat")" "$(json_escape "$id")" "$(json_escape "$title")" \
      "$(json_escape "$state")" "$(json_escape "$actual")" "$(json_escape "$base")" \
      "$(json_escape "$rec")" "$(json_escape "$evidence")" >> "$RESULTS"
  fi
  log "$id $state: $title"
}

# ── 18 health check categories ───────────────────────────────────────────────
CATS=(
  'Tile & Service Instance'
  'BOSH Infrastructure'
  'Cluster & Node Health'
  'Memory Management'
  'Erlang Runtime'
  'Disk & Persistence'
  'Queue Health'
  'Messaging Performance'
  'High Availability & Quorum'
  'Connections & Channels'
  'RabbitMQ Configuration'
  'Security & TLS'
  'RabbitMQ 4.x Features'
  'Monitoring & Alerting'
  'Recovery & Operational Readiness'
  'Stream Queues'
  'Classic Queues'
  'Application Health'
)

# ── Prerequisite checks (separate from 15 categories) ───────────────────────
PREREQ_RESULTS="$DIR/.prereqs.jsonl"; : > "$PREREQ_RESULTS"
add_prereq() {
  local id=$1 title=$2 state=$3 actual=$4
  if ((HAVE_JQ)); then
    jq -cn --arg id "$id" --arg t "$title" --arg s "$state" --arg a "$actual" \
      '{id:$id,title:$t,status:$s,actual:$a}' >> "$PREREQ_RESULTS"
  fi
  log "$id $state: $title"
}
for spec in 'bash:Bash' 'curl:curl' 'jq:jq' 'openssl:OpenSSL' 'bosh:BOSH CLI' 'cf:CF CLI'; do
  bin=${spec%%:*}; tool=${spec#*:}
  if command -v "$bin" >/dev/null 2>&1; then
    add_prereq "TOOL-$bin" "$tool" PASS 'Installed'
  else
    add_prereq "TOOL-$bin" "$tool" 'NOT VERIFIED' 'Missing'
    err "Missing optional collector: $bin"
  fi
done

# ── Temp dir setup ────────────────────────────────────────────────────────────
TMP="$DIR/.tmp"; mkdir -p "$TMP"; chmod 700 "$TMP" 2>/dev/null || :

# ── Credential handling ──────────────────────────────────────────────────────
# Priority: username+password in config/CLI > interactive TTY prompt
API_OK=0; CURL_AUTH=()
_build_authfile() {
  local user=$1 pass=$2
  umask 077
  local af="$TMP/curl-auth.conf"
  if [[ $user != *$'\n'* && $user != *'"'* && $user != *'\\'* &&
        $pass != *$'\n'* && $pass != *'"'* && $pass != *'\\'* ]]; then
    printf 'user = "%s:%s"\n' "$user" "$pass" > "$af"
    CURL_AUTH=(--config "$af")
  else
    err 'Credentials contain unsupported characters — check username and password in config.'
  fi
  unset pass
}

if [[ -n $USERNAME && -n $PASSWORD ]]; then
  _build_authfile "$USERNAME" "$PASSWORD"
  unset PASSWORD
elif [[ -t 0 && -n $URL && $HAVE_CURL == 1 ]]; then
  read -r -p 'RabbitMQ monitoring username: ' USERNAME
  read -r -s -p 'RabbitMQ monitoring password: ' _pw; printf '\n'
  _build_authfile "$USERNAME" "$_pw"
  unset _pw
fi

# ── API call helper ──────────────────────────────────────────────────────────
api() {
  local path=$1 dest=$2 http_status
  [[ $API_OK == 1 ]] || return 1
  local _insecure_flag=(); ((CURL_INSECURE)) && _insecure_flag=(--insecure)
  http_status=$(curl --silent --show-error --max-redirs 0 \
    --connect-timeout 5 --max-time 20 --retry 1 --retry-delay 1 \
    "${_insecure_flag[@]}" "${CURL_AUTH[@]}" -o "$dest" -w '%{http_code}' \
    "$URL$path" 2>> "$ERRORS") || { err "GET $path transport error"; API_RESULTS[$path]="transport error"; return 1; }
  API_RESULTS[$path]="HTTP $http_status"
  [[ $http_status == 200 ]] || { err "GET $path HTTP $http_status"; return 1; }
  jq -e . "$dest" >/dev/null 2>&1 || { err "GET $path invalid JSON"; API_RESULTS[$path]="invalid JSON"; return 1; }
  log "GET $path HTTP 200"
  return 0
}

[[ -n $URL && $HAVE_CURL == 1 && $HAVE_JQ == 1 && ${#CURL_AUTH[@]} -gt 0 ]] && API_OK=1
((API_OK)) || err 'API collector unavailable: missing URL, curl, jq, or credentials.'

# ── Pre-scan ─────────────────────────────────────────────────────────────────
# Probes tools, API endpoints, and BOSH before running checks.
# Prints a summary and (on a TTY) asks the user whether to continue.
prescan() {
  local sep='================================================================'
  local -a issues=() fixes=() ok_lines=()
  local needs_monitoring=0 needs_admin=0

  printf '\n%s\n  PRE-SCAN: Checking access and tools before health check\n%s\n' "$sep" "$sep"

  # ── Tools ───────────────────────────────────────────────────────────────────
  printf '\n  TOOLS\n'
  local required_missing=0
  for spec in 'bash:required' 'curl:required' 'jq:required' \
              'openssl:optional' 'zip:optional' 'bosh:optional' 'cf:optional'; do
    local bin=${spec%%:*} req=${spec#*:}
    if command -v "$bin" >/dev/null 2>&1; then
      printf "    ${_G}[OK]${_X}      %-12s installed\n" "$bin"
      ok_lines+=("tool:$bin")
    else
      if [[ $req == required ]]; then
        printf "    ${_R}[MISSING]${_X} %-12s REQUIRED — health checks cannot run without this\n" "$bin"
        issues+=("Missing required tool: $bin")
        ((required_missing++))
      else
        printf "    ${_Y}[MISSING]${_X} %-12s optional — related checks will be NOT VERIFIED\n" "$bin"
        issues+=("Missing optional tool: $bin")
        case "$bin" in
          openssl) fixes+=("Install openssl to enable TLS certificate expiry check") ;;
          zip)     fixes+=("Install zip (apt install zip / yum install zip) for ZIP packaging") ;;
          bosh)    fixes+=("Install and authenticate bosh CLI for BOSH VM inventory checks") ;;
          cf)      fixes+=("Install cf CLI for CF service plan checks") ;;
        esac
      fi
    fi
  done

  # ── API connectivity ─────────────────────────────────────────────────────────
  printf '\n  RABBITMQ MANAGEMENT API\n'
  if ! ((API_OK)); then
    printf "    ${_Y}[SKIP]${_X}    API probing skipped — missing URL, curl, jq, or credentials\n"
    issues+=("API access not configured — check url/credentials in config")
    fixes+=("Ensure url, username, and password are set in config")
  else
    local _st _tmpf _ps_insecure=(); _tmpf=$(mktemp 2>/dev/null || printf '%s' "$TMP/prescan.json")
    ((CURL_INSECURE)) && _ps_insecure=(--insecure)

    # Overview — basic connectivity
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/overview" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      local rmq_v; rmq_v=$(jq -r '.rabbitmq_version // "unknown"' "$_tmpf" 2>/dev/null)
      printf "    ${_G}[OK]${_X}      /api/overview  → HTTP 200  (RabbitMQ %s)\n" "$rmq_v"
    else
      printf "    ${_R}[FAIL]${_X}    /api/overview  → HTTP %s  — check URL and credentials\n" "$_st"
      issues+=("Cannot reach /api/overview (HTTP $_st) — URL or credentials incorrect")
      fixes+=("Verify 'url' field (must be https://hostname, no path) and credentials in config")
    fi

    # Nodes — monitoring tag
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/nodes" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      local nc; nc=$(jq 'length' "$_tmpf" 2>/dev/null || printf '?')
      printf "    ${_G}[OK]${_X}      /api/nodes     → HTTP 200  (%s node(s) visible)\n" "$nc"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/nodes     → HTTP 401  — requires monitoring tag\n"
      printf '              Affects: CLU-01 CLU-02 CLU-04 CLU-05 MEM-01 ERL-01 ERL-02 DISK-01\n'
      issues+=("/api/nodes → 401: 8 node health checks will be NOT VERIFIED")
      needs_monitoring=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/nodes     → HTTP %s\n" "$_st"
      issues+=("/api/nodes → HTTP $_st")
    fi

    # Shovels — monitoring tag
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/shovels" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      printf "    ${_G}[OK]${_X}      /api/shovels   → HTTP 200\n"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/shovels   → HTTP 401  — requires monitoring tag\n"
      printf '              Affects: DR-03 (shovel status)\n'
      issues+=("/api/shovels → 401: DR-03 shovel check will be NOT VERIFIED")
      needs_monitoring=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/shovels   → HTTP %s\n" "$_st"
    fi

    # Federation links — monitoring tag (404 = plugin not installed, not an error)
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/federation-links" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      local _fl; _fl=$(jq 'length' "$_tmpf" 2>/dev/null || printf '?')
      printf "    ${_G}[OK]${_X}      /api/federation-links → HTTP 200  (%s link(s))\n" "$_fl"
    elif [[ $_st == 404 ]]; then
      printf "    ${_G}[OK]${_X}      /api/federation-links → HTTP 404  (federation plugin not enabled — expected if not in use)\n"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/federation-links → HTTP 401  — requires monitoring tag\n"
      printf '              Affects: DR-04 (federation link health)\n'
      issues+=("/api/federation-links → 401: DR-04 federation check will be NOT VERIFIED")
      needs_monitoring=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/federation-links → HTTP %s\n" "$_st"
    fi

    # Consumers — monitoring tag (Application Health)
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/consumers?page=1&page_size=1&pagination=true" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      local _ccount; _ccount=$(jq '.filtered_count // .total_count // (.items|length) // 0' "$_tmpf" 2>/dev/null || printf '?')
      printf "    ${_G}[OK]${_X}      /api/consumers → HTTP 200  (%s consumer(s))\n" "$_ccount"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/consumers → HTTP 401  — requires monitoring tag\n"
      printf '              Affects: APP-02 (consumer auto-ack check)\n'
      issues+=("/api/consumers → 401: APP-02 will be NOT VERIFIED")
      needs_monitoring=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/consumers → HTTP %s\n" "$_st"
    fi

    # Bindings — monitoring tag (Application Health)
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/bindings" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      local _bcount; _bcount=$(jq 'length' "$_tmpf" 2>/dev/null || printf '?')
      printf "    ${_G}[OK]${_X}      /api/bindings  → HTTP 200  (%s binding(s))\n" "$_bcount"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/bindings  → HTTP 401  — requires monitoring tag\n"
      printf '              Affects: APP-03 (queues without bindings) APP-07 (exchange topology gaps)\n'
      issues+=("/api/bindings → 401: APP-03 APP-07 will be NOT VERIFIED")
      needs_monitoring=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/bindings  → HTTP %s\n" "$_st"
    fi

    # Exchanges — monitoring tag (Application Health)
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/exchanges" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      local _xcount; _xcount=$(jq 'length' "$_tmpf" 2>/dev/null || printf '?')
      printf "    ${_G}[OK]${_X}      /api/exchanges → HTTP 200  (%s exchange(s))\n" "$_xcount"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/exchanges → HTTP 401  — requires monitoring tag\n"
      printf '              Affects: APP-07 (exchange topology gaps)\n'
      issues+=("/api/exchanges → 401: APP-07 will be NOT VERIFIED")
      needs_monitoring=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/exchanges → HTTP %s\n" "$_st"
    fi

    # Users — administrator tag
    _st=$(curl --silent --max-time 10 --max-redirs 0 \
          "${_ps_insecure[@]}" "${CURL_AUTH[@]}" -o "$_tmpf" -w '%{http_code}' \
          "$URL/api/users" 2>/dev/null)
    if [[ $_st == 200 ]]; then
      printf "    ${_G}[OK]${_X}      /api/users     → HTTP 200\n"
    elif [[ $_st == 401 ]]; then
      printf "    ${_Y}[DENIED]${_X}  /api/users     → HTTP 401  — requires administrator tag\n"
      printf '              Affects: SEC-02 (guest user) SEC-03 (admin count)\n'
      issues+=("/api/users → 401: SEC-02 SEC-03 security checks will be NOT VERIFIED")
      needs_admin=1
    else
      printf "    ${_R}[FAIL]${_X}    /api/users     → HTTP %s\n" "$_st"
    fi

    rm -f "$_tmpf" 2>/dev/null || :
  fi

  # ── BOSH ────────────────────────────────────────────────────────────────────
  printf '\n  BOSH INFRASTRUCTURE\n'
  if [[ -z $BOSH_DEP ]]; then
    printf "    ${_Y}[SKIP]${_X}    bosh_deployment not set in config — BOSH-01 will be NOT VERIFIED\n"
    issues+=("bosh_deployment not configured — BOSH VM inventory skipped")
    fixes+=("Add bosh_deployment, bosh_environment, bosh_client, bosh_client_secret, bosh_ca_cert to config file")
  elif ! ((HAVE_BOSH)); then
    printf "    ${_Y}[MISSING]${_X} bosh CLI not found — BOSH-01 will be NOT VERIFIED\n"
    issues+=("bosh CLI not installed")
  else
    local bosh_ok=0
    if bosh env >/dev/null 2>&1; then
      printf "    ${_G}[OK]${_X}      BOSH Director reachable\n"
      bosh_ok=1
    else
      printf "    ${_R}[FAIL]${_X}    BOSH Director not reachable — check BOSH_ENVIRONMENT / BOSH_CLIENT env vars\n"
      issues+=("BOSH Director not reachable — BOSH-01 will be NOT VERIFIED")
      fixes+=("Add bosh_environment, bosh_client, bosh_client_secret, bosh_ca_cert to config file (or export BOSH_* env vars before running)")
    fi
    if ((bosh_ok)); then
      if bosh -d "$BOSH_DEP" vms >/dev/null 2>&1; then
        printf "    ${_G}[OK]${_X}      Deployment \"%s\" accessible\n" "$BOSH_DEP"
      else
        printf "    ${_R}[FAIL]${_X}    Deployment \"%s\" not found or not accessible\n" "$BOSH_DEP"
        issues+=("BOSH deployment '$BOSH_DEP' not accessible")
        fixes+=("Verify bosh_deployment name matches output of: bosh deployments")
      fi
    fi
  fi

  # ── Permission fix instructions ──────────────────────────────────────────────
  if ((needs_monitoring || needs_admin)); then
    local tags='management'
    ((needs_monitoring)) && tags="$tags monitoring"
    ((needs_admin))      && tags="$tags administrator"
    fixes+=("Grant RabbitMQ user tags — ask your platform team to run:
    Option A (rabbitmqctl via BOSH SSH):
      rabbitmqctl set_user_tags <username> $tags
    Option B (Management UI):
      Admin tab → select user → Tags field → set: $tags
    NOTE: The script is READ-ONLY and cannot do this itself.")
  fi

  # ── Summary ──────────────────────────────────────────────────────────────────
  printf '\n  SUMMARY\n'
  if ((${#issues[@]} == 0)); then
    printf "    ${_G}All checks passed — full coverage expected.${_X}\n"
  else
    printf '    %d issue(s) found — some checks will be NOT VERIFIED:\n' "${#issues[@]}"
    for issue in "${issues[@]}"; do
      printf '      • %s\n' "$issue"
    done
    if ((${#fixes[@]} > 0)); then
      printf '\n    How to improve coverage:\n'
      local i=1
      for fix in "${fixes[@]}"; do
        printf '      %d. %s\n' "$i" "$fix"
        ((i++))
      done
    fi
  fi

  # ── Interactive prompt ────────────────────────────────────────────────────────
  if [[ -t 0 ]]; then
    printf '\n%s\n' "$sep"
    if ((${#issues[@]} > 0)); then
      printf '  Options:\n'
      printf "    ${_G}[C] Continue${_X}  — run health check now with current access\n"
      printf "    ${_B}[R] Re-run${_X}    — I have fixed the issues, restart the script\n"
      printf "    ${_Y}[Q] Quit${_X}      — exit so I can fix the issues first\n"
      printf '%s\n' "$sep"
      while true; do
        read -r -p '  Choice [C/R/Q]: ' _choice
        case "${_choice^^}" in
          C|'') printf '\n  Continuing...\n\n'; break ;;
          R)    printf '\n  Re-running script...\n\n'
                exec "$0" "${ORIG_ARGS[@]}" ;;
          Q)    printf '\n  Exiting. Fix the issues above and re-run the script.\n\n'
                exit 0 ;;
          *)    printf '  Please enter C, R, or Q.\n' ;;
        esac
      done
    else
      printf '  Press Enter to begin health check, or Ctrl-C to cancel.\n'
      printf '%s\n' "$sep"
      read -r -p '  ' _
      printf '\n'
    fi
  else
    # Non-interactive — just print summary and continue
    printf '\n%s\n  Non-interactive mode: continuing with current access.\n%s\n\n' "$sep" "$sep"
  fi
}

# ── Config summary ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  printf "${_W}  Config loaded:${_X}  customer=${_W}%s${_X}  url=${_W}%s${_X}  user=${_W}%s${_X}\n\n" \
    "$CUSTOMER" "${URL:-not set}" "${USERNAME:-not set}"
fi

prescan

# Exit here if --check-config was requested (pre-scan already validated everything)
((CHECK_CONFIG)) && { printf '\n  Config and connectivity check complete.\n\n'; exit 0; }

# ── CHECKS ───────────────────────────────────────────────────────────────────

# ── Category 1 & 13: Tile & Service Instance + RabbitMQ 4.x Features ─────────
progress 'Checking tile & cluster overview...'
if ((API_OK)) && api /api/overview "$TMP/overview.json"; then
  rmq_version=$(jq -r '.rabbitmq_version // "unknown"' "$TMP/overview.json")
  erlang_version=$(jq -r '.erlang_version // "unknown"' "$TMP/overview.json")
  mgmt_version=$(jq -r '.management_version // "unknown"' "$TMP/overview.json")
  cname=$(jq -r '.cluster_name // "unknown"' "$TMP/overview.json")
  rates_mode=$(jq -r '.rates_mode // "unknown"' "$TMP/overview.json")

  add 'Tile & Service Instance' 'TILE-01' 'RabbitMQ runtime version' \
    REVIEW "$rmq_version" 'RabbitMQ 4.x (Tanzu tile)' \
    'Verify installed tile patch and version mapping in Ops Manager.' \
    "Source: GET /api/overview | rabbitmq_version=$rmq_version erlang_version=$erlang_version management_version=$mgmt_version cluster_name=$cname"

  if [[ $mgmt_version != "$rmq_version" && $mgmt_version != 'unknown' ]]; then
    add 'Tile & Service Instance' 'TILE-03' 'Management plugin version match' \
      WARNING "management=$mgmt_version, broker=$rmq_version" 'Versions should match' \
      'Reinstall or verify tile integrity via Ops Manager.' \
      "Source: GET /api/overview | management_version=$mgmt_version rabbitmq_version=$rmq_version — mismatch indicates possible tile issue"
  else
    add 'Tile & Service Instance' 'TILE-03' 'Management plugin version match' \
      PASS "$mgmt_version" 'Matches broker version' 'No action.' \
      "Source: GET /api/overview | management_version=$mgmt_version matches rabbitmq_version=$rmq_version"
  fi

  if [[ $rates_mode == 'none' ]]; then
    add 'Monitoring & Alerting' 'MON-02' 'Management stats collection mode' \
      WARNING "rates_mode=none" 'basic or detailed' \
      'Enable management stats for meaningful performance metrics.' \
      "Source: GET /api/overview | rates_mode=none — message rate data disabled; MSG-03 and performance checks will show zero rates"
  else
    add 'Monitoring & Alerting' 'MON-02' 'Management stats collection mode' \
      PASS "rates_mode=$rates_mode" 'basic or detailed' 'No action.' \
      "Source: GET /api/overview | rates_mode=$rates_mode — message rate collection is active"
  fi

  _rmq_major=${rmq_version%%.*}
  if [[ $_rmq_major == '4' ]]; then
    add 'RabbitMQ 4.x Features' 'FTR-01' 'RabbitMQ 4.x runtime' \
      PASS "$rmq_version" 'RabbitMQ 4.x family' 'Confirm exact tile patch via Ops Manager.' \
      "Source: GET /api/overview | rabbitmq_version=$rmq_version — 4.x family confirmed"
  else
    add 'RabbitMQ 4.x Features' 'FTR-01' 'RabbitMQ 4.x runtime' \
      REVIEW "$rmq_version" 'RabbitMQ 4.x family' \
      'Unexpected major version — verify tile version mapping in Ops Manager.' \
      "Source: GET /api/overview | rabbitmq_version=$rmq_version — expected major version 4"
  fi
  unset _rmq_major

  # Messaging performance: live rates from overview (zero extra API call)
  pub_rate=$(jq -r '.message_stats.publish_details.rate // 0' "$TMP/overview.json")
  del_rate=$(jq -r '.message_stats.deliver_details.rate // 0' "$TMP/overview.json")
  redeliver_rate=$(jq -r '.message_stats.redeliver_details.rate // 0' "$TMP/overview.json")

  if [[ $rates_mode != 'none' ]]; then
    if (( $(echo "$redeliver_rate > 0" | awk '{print ($1+0 > 0)}') )); then
      add 'Messaging Performance' 'MSG-03' 'Live redelivery rate' \
        REVIEW "redeliver=${redeliver_rate}/s publish=${pub_rate}/s deliver=${del_rate}/s" \
        'Redelivery rate near zero' \
        'Investigate consumer-side processing failures or poison messages.' '/api/overview message_stats'
    else
      add 'Messaging Performance' 'MSG-03' 'Live redelivery rate' \
        PASS "redeliver=${redeliver_rate}/s publish=${pub_rate}/s deliver=${del_rate}/s" \
        'Redelivery rate near zero' 'No action.' '/api/overview message_stats'
    fi
  fi
else
  add 'Cluster & Node Health' 'CLU-00' 'Management API connectivity' \
    'NOT VERIFIED' 'API overview failed' 'HTTP 200 with valid JSON' \
    'Check URL, TLS, credentials, permissions and routing.' '/api/overview'
fi

# ── Category 3: Cluster & Node Health ────────────────────────────────────────
progress 'Checking node health, memory, Erlang runtime & disk...'
if ((API_OK)) && api /api/nodes "$TMP/nodes.json"; then
  total=$(jq 'length' "$TMP/nodes.json")
  running=$(jq '[.[]|select(.running==true)]|length' "$TMP/nodes.json")

  # Auto-detect expected_nodes from API if not specified in config/CLI
  [[ -z $EXPECTED ]] && EXPECTED=$total && log "expected_nodes auto-detected from API: $total"

  if ((running == EXPECTED && total == EXPECTED)); then state=PASS; else state=CRITICAL; fi
  node_detail=$(jq -r '[.[]|.name+"(running="+(.running|tostring)+",type="+(.type//"disc")+")"]|join(", ")' "$TMP/nodes.json")
  add 'Cluster & Node Health' 'CLU-01' 'Node availability' "$state" \
    "$running/$total running" "$EXPECTED nodes expected (auto-detected)" \
    'Investigate unavailable or unexpected nodes via BOSH.' \
    "Source: GET /api/nodes | total=$total running=$running expected=$EXPECTED | $node_detail"

  # Network partition detection (critical check)
  partitioned=$(jq '[.[]|select(.partitions|length>0)]|length' "$TMP/nodes.json")
  if ((partitioned > 0)); then
    part_detail=$(jq -r '[.[]|select(.partitions|length>0)|.name+" partitioned-from: "+(.partitions|join(","))]|join("; ")' "$TMP/nodes.json")
    add 'Cluster & Node Health' 'CLU-04' 'Network partition (split-brain)' \
      CRITICAL "$partitioned node(s) in partition" 'Zero partitions' \
      'Immediate action required: resolve partition per RabbitMQ partition handling docs.' \
      "Source: GET /api/nodes | partitions field | $part_detail"
  else
    add 'Cluster & Node Health' 'CLU-04' 'Network partition (split-brain)' \
      PASS 'No partitions detected' 'Zero partitions' 'No action.' \
      "Source: GET /api/nodes | partitions=[] on all $total nodes — cluster is not split"
  fi

  # Node type (ram nodes deprecated/removed in RMQ 4.x)
  ram_nodes=$(jq '[.[]|select(.type=="ram")]|length' "$TMP/nodes.json")
  if ((ram_nodes > 0)); then
    add 'Cluster & Node Health' 'CLU-05' 'Node type (disc vs ram)' \
      CRITICAL "$ram_nodes ram-type node(s) detected" 'All nodes disc type' \
      'Ram nodes are removed in RabbitMQ 4.x. Convert to disc nodes.' '/api/nodes type field'
  else
    add 'Cluster & Node Health' 'CLU-05' 'Node type (disc vs ram)' \
      PASS 'All nodes are disc type' 'All nodes disc type' 'No action.' '/api/nodes type field'
  fi

  # Resource alarms
  alarms=$(jq '[.[]|select(.mem_alarm==true or .disk_free_alarm==true)]|length' "$TMP/nodes.json")
  alarm_detail=$(jq -r '[.[]|select(.mem_alarm==true or .disk_free_alarm==true)|.name+" mem_alarm="+(.mem_alarm|tostring)+" disk_alarm="+(.disk_free_alarm|tostring)]|join("; ")' "$TMP/nodes.json")
  if ((alarms == 0)); then state=PASS; alarm_detail="mem_alarm=false disk_free_alarm=false on all $total nodes"; fi
  add 'Cluster & Node Health' 'CLU-02' 'Node resource alarms' "$state" \
    "$alarms node(s) with active alarms" '0 active memory/disk alarms' \
    'Investigate resource alarms — publishers will be blocked.' \
    "Source: GET /api/nodes | $alarm_detail"

  # Per-node metrics: memory, FDs, processes, sockets, disk
  while IFS=$'\t' read -r name mem_used mem_limit fd fdmax proc procmax sockets sockmax disk disklim uptime_ms node_type; do
    [[ -n $name ]] || continue

    # Memory watermark utilization
    if [[ $mem_used != null && $mem_limit != null && $mem_limit =~ ^[0-9]+$ && $mem_limit -gt 0 ]]; then
      pct=$((100 * mem_used / mem_limit))
      if   ((pct >= 95)); then s=CRITICAL
      elif ((pct >= 85)); then s=WARNING
      else s=PASS; fi
      add 'Memory Management' 'MEM-01' "Memory watermark utilization: $name" "$s" \
        "$pct%" 'Warning >=85%, critical >=95% of watermark' \
        'Review memory breakdown, queue growth and allocated capacity.' \
        "mem_used=$mem_used mem_limit=$mem_limit"
    fi

    # File descriptors
    if [[ $fd != null && $fdmax =~ ^[0-9]+$ && $fdmax -gt 0 ]]; then
      pct=$((100 * fd / fdmax))
      if   ((pct >= 90)); then s=CRITICAL
      elif ((pct >= 75)); then s=WARNING
      else s=PASS; fi
      add 'Erlang Runtime' 'ERL-01' "File descriptors: $name" "$s" "$pct%" \
        'Warning >=75%, critical >=90%' \
        'Investigate connection count and file descriptor headroom.' \
        "fd_used=$fd fd_total=$fdmax"
    fi

    # Erlang processes
    if [[ $proc != null && $procmax =~ ^[0-9]+$ && $procmax -gt 0 ]]; then
      pct=$((100 * proc / procmax))
      if   ((pct >= 90)); then s=CRITICAL
      elif ((pct >= 75)); then s=WARNING
      else s=PASS; fi
      add 'Erlang Runtime' 'ERL-02' "Erlang processes: $name" "$s" "$pct%" \
        'Warning >=75%, critical >=90%' \
        'Investigate process growth from queue or connection pressure.' \
        "proc_used=$proc proc_total=$procmax"
    fi

    # Sockets
    if [[ $sockets != null && $sockets != 'null' && $sockmax =~ ^[0-9]+$ && $sockmax -gt 0 ]]; then
      pct=$((100 * sockets / sockmax))
      if   ((pct >= 90)); then s=CRITICAL
      elif ((pct >= 75)); then s=WARNING
      else s=PASS; fi
      add 'Erlang Runtime' 'ERL-03' "Sockets: $name" "$s" "$pct%" \
        'Warning >=75%, critical >=90%' \
        'High socket usage indicates excessive connections.' \
        "sockets_used=$sockets sockets_total=$sockmax"
    fi

    # Disk headroom
    if [[ $disk =~ ^[0-9]+$ && $disklim =~ ^[0-9]+$ && $disklim -gt 0 ]]; then
      if   ((disk <= disklim));         then s=CRITICAL
      elif ((disk * 10 < disklim * 15)); then s=WARNING
      else s=PASS; fi
      add 'Disk & Persistence' 'DISK-01' "Disk-free headroom: $name" "$s" \
        "$disk bytes free" 'Warning <1.5x disk-free limit; critical <=limit' \
        'Review persistent disk and queue retention policies.' \
        "disk_free=$disk disk_free_limit=$disklim"
      # Validate watermark is reasonable (>=1GB)
      if [[ $disklim =~ ^[0-9]+$ && $disklim -lt 1073741824 ]]; then
        add 'Disk & Persistence' 'DISK-03' "Disk-free limit sanity: $name" \
          REVIEW "disk_free_limit=$(( disklim / 1048576 ))MB" '>=1GB recommended' \
          'A very low disk_free_limit may mask actual disk pressure.' \
          "disk_free_limit=$disklim bytes"
      fi
    fi

    # Node uptime (flag recent restarts)
    if [[ $uptime_ms =~ ^[0-9]+$ ]]; then
      uptime_min=$((uptime_ms / 60000))
      if ((uptime_min < 5)); then
        add 'Recovery & Operational Readiness' 'DR-02' "Recent node restart: $name" \
          REVIEW "Uptime: ${uptime_min}m" '>5 minutes uptime expected' \
          'Node restarted recently — verify it has fully rejoined the cluster.' \
          "uptime_ms=$uptime_ms"
      fi
    fi

  done < <(jq -r '.[] | [
    .name,
    (.mem_used   // "null"), (.mem_limit  // "null"),
    (.fd_used    // "null"), (.fd_total   // "null"),
    (.proc_used  // "null"), (.proc_total // "null"),
    (.sockets_used // "null"), (.sockets_total // "null"),
    (.disk_free  // "null"), (.disk_free_limit // "null"),
    (.uptime     // "null"),
    (.type       // "disc")
  ] | @tsv' "$TMP/nodes.json")

else
  _nodes_status="${API_RESULTS[/api/nodes]:-unknown}"
  add 'Cluster & Node Health' 'CLU-01' 'Node availability' \
    'NOT VERIFIED' "GET /api/nodes returned $_nodes_status" \
    'All expected nodes running' \
    "Grant the 'monitoring' tag to the RabbitMQ user to unlock node-level checks (nodes, memory, disk, Erlang runtime)." \
    "Source: GET /api/nodes | $_nodes_status — user requires 'monitoring' or 'administrator' tag in RabbitMQ management"
  # Also explicitly mark Memory and Erlang categories as not collected due to 401
  add 'Memory Management' 'MEM-00' 'Memory metrics' \
    'NOT VERIFIED' "GET /api/nodes returned $_nodes_status — per-node memory data unavailable" \
    'Per-node memory watermark utilization' \
    "Grant 'monitoring' tag to the RabbitMQ user to enable memory checks." \
    "Source: GET /api/nodes | $_nodes_status — MEM-01 (watermark utilization) requires /api/nodes access"
  add 'Erlang Runtime' 'ERL-00' 'Erlang runtime metrics' \
    'NOT VERIFIED' "GET /api/nodes returned $_nodes_status — per-node Erlang data unavailable" \
    'File descriptors, processes, sockets per node' \
    "Grant 'monitoring' tag to the RabbitMQ user to enable Erlang runtime checks." \
    "Source: GET /api/nodes | $_nodes_status — ERL-01/02/03 (FDs, processes, sockets) require /api/nodes access"
  add 'Disk & Persistence' 'DISK-00' 'Disk-free metrics' \
    'NOT VERIFIED' "GET /api/nodes returned $_nodes_status — per-node disk data unavailable" \
    'Disk-free headroom per node' \
    "Grant 'monitoring' tag to the RabbitMQ user to enable disk checks." \
    "Source: GET /api/nodes | $_nodes_status — DISK-01 (disk headroom) requires /api/nodes access"
fi

# ── Vhost health check ────────────────────────────────────────────────────────
progress 'Checking virtual host health...'
if ((API_OK)) && api /api/health/checks/virtual-hosts "$TMP/vhost_health.json"; then
  add 'Cluster & Node Health' 'CLU-06' 'Virtual host health' \
    PASS 'HTTP 200 — all vhosts healthy' 'All vhosts have a running process' 'No action.' \
    "Source: GET /api/health/checks/virtual-hosts | HTTP 200 — all vhosts responding"
else
  _vh_status="${API_RESULTS[/api/health/checks/virtual-hosts]:-no response}"
  if [[ $_vh_status == "HTTP 503" ]]; then
    add 'Cluster & Node Health' 'CLU-06' 'Virtual host health' \
      CRITICAL "HTTP 503 — one or more vhosts are down" 'All vhosts healthy' \
      'Investigate failing vhosts via RabbitMQ management or BOSH.' \
      "Source: GET /api/health/checks/virtual-hosts | HTTP 503 — broker reports unhealthy vhost(s)"
  else
    add 'Cluster & Node Health' 'CLU-06' 'Virtual host health' \
      'NOT VERIFIED' "Unavailable ($_vh_status)" 'All vhosts healthy' \
      'Check endpoint availability and monitoring permissions.' \
      "Source: GET /api/health/checks/virtual-hosts | $_vh_status"
  fi
fi

# ── Cluster-wide health endpoint ──────────────────────────────────────────────
progress 'Checking cluster-wide alarms...'
if ((API_OK)) && api /api/health/checks/alarms "$TMP/alarms.json"; then
  add 'Cluster & Node Health' 'CLU-03' 'Cluster-wide alarm endpoint' \
    PASS 'HTTP 200 — no cluster alarms' 'No cluster alarms' 'No action.' \
    "Source: GET /api/health/checks/alarms | HTTP 200 — broker reports no active cluster-wide alarms"
else
  add 'Cluster & Node Health' 'CLU-03' 'Cluster-wide alarm endpoint' \
    'NOT VERIFIED' "Unavailable (${API_RESULTS[/api/health/checks/alarms]:-no response})" \
    'No cluster alarms' \
    "Source: GET /api/health/checks/alarms | ${API_RESULTS[/api/health/checks/alarms]:-no response} — check endpoint availability and monitoring permissions"
fi

# ── Category 7: Queue Health (paginated) ─────────────────────────────────────
progress 'Collecting queue inventory (paginated)...'
page=1; complete=1; : > "$TMP/queues.jsonl"; totalq=0
while :; do
  ppath="/api/queues?page=$page&page_size=100&pagination=true&disable_stats=false"
  if ! api "$ppath" "$TMP/page.json"; then complete=0; break; fi
  if ! jq -e '(.items|type)=="array" and (.page_count|type)=="number"' "$TMP/page.json" >/dev/null; then
    complete=0; err 'Queue pagination response missing expected fields'; break
  fi
  jq -c '.items[]' "$TMP/page.json" >> "$TMP/queues.jsonl"
  totalq=$((totalq + $(jq '.items|length' "$TMP/page.json")))
  count=$(jq '.page_count' "$TMP/page.json")
  ((page >= count)) && break
  page=$((page + 1))
  if ((page > 1000)); then complete=0; err 'Queue pagination exceeded safety cap (1000 pages)'; break; fi
done

if ((complete)); then
  add 'Queue Health' 'QUE-01' 'Queue inventory collected' PASS \
    "$totalq queues" 'All pages retrieved' \
    'Review queue-level findings below.' \
    "Source: GET /api/queues (paginated, page_size=100) | $page page(s) fetched | $totalq total queues"

  classic=$(jq -s '[.[]|select(.type=="classic")]|length' "$TMP/queues.jsonl")
  quorum=$(jq  -s '[.[]|select(.type=="quorum")]|length'  "$TMP/queues.jsonl")
  streams=$(jq -s '[.[]|select(.type=="stream")]|length'  "$TMP/queues.jsonl")
  add 'RabbitMQ 4.x Features' 'FTR-02' 'Queue type inventory' REVIEW \
    "classic=$classic, quorum=$quorum, stream=$streams" \
    'Select queue type per workload and HA requirements' \
    'Review classic queues for quorum migration; evaluate stream suitability.' \
    "Source: GET /api/queues | total=$totalq | classic=$classic quorum=$quorum stream=$streams — business criticality of each queue type is unknown"

  # Queue state: any flow/down/crashed is critical
  bad_state_count=$(jq -s '[.[]|select(.state=="flow" or .state=="down" or .state=="crashed")]|length' "$TMP/queues.jsonl")
  if ((bad_state_count > 0)); then
    bad_detail=$(jq -sr '[.[]|select(.state=="flow" or .state=="down" or .state=="crashed")|(.name+":"+.state)]|join(", ")' "$TMP/queues.jsonl")
    add 'Queue Health' 'QUE-04' 'Queue process state' CRITICAL \
      "$bad_state_count queue(s) in abnormal state: $bad_detail" 'All queues running or idle' \
      'Investigate queues in flow/down/crashed state immediately.' '/api/queues state field'
  else
    add 'Queue Health' 'QUE-04' 'Queue process state' PASS \
      'All queues running or idle' 'All queues running or idle' 'No action.' '/api/queues state field'
  fi

  # Ready messages
  ready=$(jq -s '[.[]|(.messages_ready//0)]|add//0' "$TMP/queues.jsonl")
  if   ((ready >= 50000)); then s=CRITICAL
  elif ((ready >= 10000)); then s=WARNING
  else s=PASS; fi
  add 'Queue Health' 'QUE-02' 'Total ready messages' "$s" "$ready" \
    'Warning >=10000, critical >=50000; customize per workload' \
    'Inspect queues with sustained backlog and investigate consumers.' 'Point-in-time snapshot'

  # Backlogged queues without consumers
  zero=$(jq -s '[.[]|select((.messages_ready//0)>0 and (.consumers//0)==0)]|length' "$TMP/queues.jsonl")
  if ((zero > 0)); then s=WARNING; else s=PASS; fi
  add 'Queue Health' 'QUE-03' 'Backlogged queues without consumers' "$s" \
    "$zero queue(s)" '0 unless intentional' \
    'Confirm expected consumer presence and queue purpose.' 'Queue inventory snapshot'

  # Unacknowledged messages ratio
  unacked=$(jq -s '[.[]|(.messages_unacknowledged//0)]|add//0' "$TMP/queues.jsonl")
  if ((ready > 0 && unacked > ready * 2)); then s=WARNING; else s=PASS; fi
  add 'Queue Health' 'QUE-05' 'Unacknowledged messages ratio' "$s" \
    "unacked=$unacked vs ready=$ready" 'Unacked should not exceed 2x ready' \
    'Investigate consumer processing speed and ack latency.' 'Queue inventory snapshot'

  # Consumer utilization (flag slow consumers)
  slow=$(jq -s '[.[]|select((.consumer_utilisation//1)<0.5 and (.messages_ready//0)>1000)]|length' "$TMP/queues.jsonl")
  if ((slow > 0)); then s=WARNING; else s=PASS; fi
  add 'Messaging Performance' 'MSG-04' 'Consumer utilization (slow consumers)' "$s" \
    "$slow queue(s) with utilisation <50% and backlog >1000" \
    'Consumer utilisation >=50% on loaded queues' \
    'Investigate consumer processing throughput and prefetch settings.' \
    '/api/queues consumer_utilisation'

  # Top queues snapshot
  top=$(jq -sr 'sort_by(.messages_ready//0)|reverse|.[0:10]|map((.vhost//"/")+"/"+(.name//"?")+"="+((.messages_ready//0)|tostring))|join("; ")' "$TMP/queues.jsonl")
  add 'Messaging Performance' 'MSG-01' 'Top ready-message queues (snapshot)' REVIEW \
    "$top" 'Workload-specific backlog SLO' \
    'Compare against monitoring history; a single snapshot cannot prove long-term health.' \
    'Point-in-time snapshot only'

  # Quorum queue inventory and leader balance
  qq=$(jq -s '[.[]|select(.type=="quorum")]|length' "$TMP/queues.jsonl")
  if ((qq == 0)); then
    if ((classic > 0)); then
      add 'High Availability & Quorum' 'HA-01' 'Quorum queue inventory' REVIEW \
        'No quorum queues found; classic queues present' \
        'Critical queues should use quorum type for HA' \
        'Evaluate migrating critical classic queues to quorum type.' 'Queue type inventory'
    else
      add 'High Availability & Quorum' 'HA-01' 'Quorum queue inventory' REVIEW \
        "No quorum queues (classic=$classic, stream=$streams)" \
        'Depends on workload HA requirements' \
        'Verify stream queues have appropriate replica counts for HA.' 'Queue type inventory'
    fi
  else
    # Leader distribution
    leader_dist=$(jq -sr '[.[]|select(.type=="quorum")|.leader//empty]|group_by(.)|map({node:.[0],count:length})|sort_by(.count)|reverse' "$TMP/queues.jsonl" 2>/dev/null || echo '[]')
    max_leaders=$(echo "$leader_dist" | jq -r '.[0].count // 0' 2>/dev/null || echo 0)
    if ((qq > 0 && max_leaders > qq * 60 / 100)); then
      top_node=$(echo "$leader_dist" | jq -r '.[0].node // "unknown"' 2>/dev/null || echo unknown)
      add 'High Availability & Quorum' 'HA-01' 'Quorum queue leader balance' WARNING \
        "$max_leaders/$qq quorum leaders on node $top_node" \
        'Leaders balanced across nodes (<60% on any single node)' \
        'Rebalance quorum queue leaders using rabbitmq-queues rebalance command.' \
        '/api/queues leader field'
    else
      add 'High Availability & Quorum' 'HA-01' 'Quorum queue leader balance' PASS \
        "$qq quorum queues, leaders balanced" 'Leaders balanced across nodes' \
        'No action.' '/api/queues leader field'
    fi
  fi

  add 'High Availability & Quorum' 'HA-02' 'Quorum replica majority and leader' \
    'NOT VERIFIED' 'Detailed replica diagnostics require rabbitmq-queues CLI' \
    'All critical quorum queues have leader and majority' \
    'Use approved rabbitmq-queues diagnostics for detailed replica status.' \
    'Queue count is insufficient for replica verification'

  # ── Stream Queue checks ─────────────────────────────────────────────────────
  if ((streams > 0)); then
    stream_running=$(jq -s '[.[]|select(.type=="stream" and .state=="running")]|length' "$TMP/queues.jsonl")
    stream_bad=$(jq -s '[.[]|select(.type=="stream")|select(.state!="running" and .state!=null and .state!="")]|length' "$TMP/queues.jsonl")
    if ((stream_bad > 0)); then
      stream_bad_detail=$(jq -sr '[.[]|select(.type=="stream")|select(.state!="running" and .state!=null and .state!="")|(.name+":"+.state)]|join(", ")' "$TMP/queues.jsonl")
      add 'Stream Queues' 'STR-01' 'Stream queue state' CRITICAL \
        "$stream_bad/$streams stream queue(s) in abnormal state: $stream_bad_detail" \
        'All stream queues running' \
        'Investigate stream queues not in running state — data consumption may be impacted.' \
        "Source: GET /api/queues | streams=$streams running=$stream_running abnormal=$stream_bad"
    else
      add 'Stream Queues' 'STR-01' 'Stream queue state' PASS \
        "All $streams stream queue(s) running" 'All stream queues running' 'No action.' \
        "Source: GET /api/queues | streams=$streams all in running state"
    fi

    # Replica health: compare members_online vs members per stream queue
    stream_degraded=$(jq -s '[.[]|select(.type=="stream")|select(((.members_online//[])|length) < ((.members//[])|length) and ((.members//[])|length) > 0)]|length' "$TMP/queues.jsonl")
    if ((stream_degraded > 0)); then
      stream_deg_detail=$(jq -sr '[.[]|select(.type=="stream")|select(((.members_online//[])|length) < ((.members//[])|length) and ((.members//[])|length) > 0)|(.name+": online="+((.members_online//[])|length|tostring)+"/total="+((.members//[])|length|tostring))]|join(", ")' "$TMP/queues.jsonl")
      add 'Stream Queues' 'STR-02' 'Stream queue replica health' WARNING \
        "$stream_degraded stream(s) with offline replicas: $stream_deg_detail" \
        'All stream replicas online' \
        'Degraded replicas reduce durability and fault tolerance — investigate offline nodes.' \
        "Source: GET /api/queues | members vs members_online fields per stream queue"
    else
      add 'Stream Queues' 'STR-02' 'Stream queue replica health' PASS \
        "All $streams stream queue(s) have all replicas online" 'All stream replicas online' 'No action.' \
        "Source: GET /api/queues | members_online matches members on all $streams stream queue(s)"
    fi

    # Streams without consumers: streams retain data indefinitely until TTL/max-length, so orphans consume disk
    stream_no_consumer=$(jq -s '[.[]|select(.type=="stream" and ((.consumers//0)==0))]|length' "$TMP/queues.jsonl")
    if ((stream_no_consumer > 0)); then
      stream_nc_names=$(jq -sr '[.[]|select(.type=="stream" and ((.consumers//0)==0))|.name]|join(", ")' "$TMP/queues.jsonl")
      add 'Stream Queues' 'STR-03' 'Stream queues without consumers' REVIEW \
        "$stream_no_consumer/$streams stream queue(s) have no active consumers: $stream_nc_names" \
        '0 unattended streams unless intentional' \
        'Streams retain messages until TTL or max-length is reached. Orphaned streams consume disk indefinitely. Confirm each is intentional.' \
        "Source: GET /api/queues | streams without consumers=$stream_no_consumer of $streams"
    else
      add 'Stream Queues' 'STR-03' 'Stream queues without consumers' PASS \
        "All $streams stream queue(s) have active consumers" 'All stream queues consumed' 'No action.' \
        "Source: GET /api/queues | all $streams stream queues have consumers"
    fi
  else
    # No stream queues: assess whether workloads could benefit
    add 'Stream Queues' 'STR-01' 'Stream queue inventory' REVIEW \
      "No stream queues detected (classic=$classic quorum=$quorum)" \
      'Consider streams for high-throughput or fan-out workloads' \
      'Stream queues are ideal for high-throughput ingestion, audit logs, and fan-out (multiple independent consumers reading the same data). Evaluate suitability for applicable workloads.' \
      "Source: GET /api/queues | total=$totalq classic=$classic quorum=$quorum stream=0"
  fi

  # ── Classic Queue checks ────────────────────────────────────────────────────
  if ((classic > 0)); then
    # Backlogged classic queues without consumers
    classic_orphan=$(jq -s '[.[]|select(.type=="classic" and ((.consumers//0)==0) and ((.messages_ready//0)>0))]|length' "$TMP/queues.jsonl")
    if ((classic_orphan > 0)); then
      classic_orphan_names=$(jq -sr '[.[]|select(.type=="classic" and ((.consumers//0)==0) and ((.messages_ready//0)>0))|.name]|join(", ")' "$TMP/queues.jsonl")
      add 'Classic Queues' 'CLS-01' 'Classic queues: backlog without consumers' WARNING \
        "$classic_orphan classic queue(s) have messages but no consumers: $classic_orphan_names" \
        '0 unless intentional' \
        'Classic queues accumulating messages without consumers may indicate application disconnect or orphaned queues. Investigate each.' \
        "Source: GET /api/queues | classic queues with messages>0 and consumers=0: $classic_orphan of $classic"
    else
      add 'Classic Queues' 'CLS-01' 'Classic queues: backlog without consumers' PASS \
        "All $classic classic queue(s) are consumed or empty" 'No unattended message backlog' 'No action.' \
        "Source: GET /api/queues | all $classic classic queues have consumers or are empty"
    fi

    # Migration posture: in RMQ 4.x CQv1 is removed; CQv2 remains but quorum queues provide stronger HA
    add 'Classic Queues' 'CLS-02' 'Classic queue migration posture' REVIEW \
      "$classic classic queue(s) in use" \
      'Migrate business-critical classic queues to quorum or stream type' \
      'Classic Queue v1 (CQv1) is removed in RabbitMQ 4.x. CQv2 is supported but does not provide quorum-based HA. For business-critical queues, evaluate migration to quorum queues (strong consistency, leader election) or stream queues (high-throughput, fan-out).' \
      "Source: GET /api/queues | classic=$classic — CQv2 is the only supported classic format in RMQ 4.x; quorum or stream queues recommended for HA workloads"
  else
    add 'Classic Queues' 'CLS-01' 'Classic queue inventory' PASS \
      'No classic queues in use' 'Quorum or stream queues preferred in RMQ 4.x' 'No action.' \
      "Source: GET /api/queues | classic=0 — all queues are quorum or stream type"
  fi

else
  add 'Queue Health' 'QUE-01' 'Queue inventory collected' 'NOT VERIFIED' \
    "$totalq partial queues collected" 'Complete inventory' \
    'Review API permissions and pagination errors in errors.log.' 'Partial queue data — not scored'
fi

# ── Category 10: Connections & Channels ──────────────────────────────────────
progress 'Checking connections & channels...'
if ((API_OK)) && api /api/connections "$TMP/connections.json"; then
  con=$(jq 'length' "$TMP/connections.json")
  blocked=$(jq '[.[]|select(.state=="blocked" or .state=="blocking")]|length' "$TMP/connections.json")
  if ((blocked > 0)); then s=CRITICAL; else s=PASS; fi
  add 'Connections & Channels' 'CON-01' 'Active connections' REVIEW \
    "$con total" 'Compare with workload baseline and limits' \
    'Investigate sustained churn or imbalance if historical metrics are available.' \
    "Source: GET /api/connections | total=$con connections"
  add 'Connections & Channels' 'CON-02' 'Blocked/blocking connections' "$s" \
    "$blocked connection(s) blocked or blocking" '0 blocked connections' \
    'Broker is under resource pressure — investigate memory or disk alarms.' \
    "Source: GET /api/connections | blocked/blocking=$blocked of $con — blocked means publisher is being throttled by the broker"
else
  add 'Connections & Channels' 'CON-01' 'Active connections' 'NOT VERIFIED' \
    "Unavailable (${API_RESULTS[/api/connections]:-no response})" \
    'Connection inventory available' \
    "Source: GET /api/connections | ${API_RESULTS[/api/connections]:-no response} — grant monitoring permissions"
fi

# Channels
if ((API_OK)) && api /api/channels "$TMP/channels.json"; then
  ch_total=$(jq 'length' "$TMP/channels.json")
  add 'Connections & Channels' 'CON-03' 'Active channels' REVIEW \
    "$ch_total channels" 'Compare with connection count; >100 channels/connection is a code smell' \
    'Review channel-per-connection ratio in application code.' '/api/channels'
else
  add 'Connections & Channels' 'CON-03' 'Active channels' 'NOT VERIFIED' \
    "Unavailable (${API_RESULTS[/api/channels]:-no response})" \
    'Channel inventory available' 'Check permissions.' '/api/channels'
fi

# ── Category 11: RabbitMQ Configuration ──────────────────────────────────────
progress 'Checking policies & feature flags...'
if ((API_OK)) && api /api/policies "$TMP/policies.json"; then
  pol=$(jq 'length' "$TMP/policies.json")
  # Detect dead HA-mode policies (removed in RMQ 4.x, silently no-op)
  dead_ha=$(jq '[.[]|select(.definition["ha-mode"]!=null)]|length' "$TMP/policies.json")
  if ((dead_ha > 0)); then
    dead_names=$(jq -r '[.[]|select(.definition["ha-mode"]!=null)|.name]|join(", ")' "$TMP/policies.json")
    add 'High Availability & Quorum' 'HA-03' 'Deprecated HA-mode policies detected' CRITICAL \
      "$dead_ha policy(ies) with ha-mode: $dead_names" \
      'No ha-mode policies (removed in RabbitMQ 4.x)' \
      'Remove ha-mode policies — they are silently ignored in RMQ 4.x and provide no protection. Use quorum queues instead.' \
      '/api/policies ha-mode key'
  fi
  add 'RabbitMQ Configuration' 'CFG-01' 'Queue policy inventory' REVIEW \
    "$pol policies (dead ha-mode: $dead_ha)" \
    'Approved TTL, DLX, overflow policies; zero ha-mode policies' \
    'Review policy content with customer — verify TTL, DLX and overflow are set appropriately.' \
    '/api/policies count; raw definitions excluded'
else
  add 'RabbitMQ Configuration' 'CFG-01' 'Queue policy inventory' 'NOT VERIFIED' \
    "Unavailable (${API_RESULTS[/api/policies]:-no response})" \
    'Policies readable' 'Check permissions.' '/api/policies'
fi

# Feature flags
if ((API_OK)) && api /api/feature-flags "$TMP/feature_flags.json"; then
  khepri_state=$(jq -r '[.[]|select(.name=="khepri_db")][0].state // "not_found"' "$TMP/feature_flags.json")
  total_flags=$(jq 'length' "$TMP/feature_flags.json")
  disabled_flags=$(jq '[.[]|select(.state=="disabled")]|length' "$TMP/feature_flags.json")
  unavail_flags=$(jq '[.[]|select(.state=="unavailable")]|length' "$TMP/feature_flags.json")

  if [[ $khepri_state == 'enabled' ]]; then
    add 'RabbitMQ 4.x Features' 'FTR-03' 'Khepri metadata store' PASS \
      'khepri_db=enabled' 'Khepri active (Mnesia removed in RMQ 4.x)' \
      'No action — Khepri is the required metadata store for RMQ 4.x.' \
      "Source: GET /api/feature-flags | khepri_db=enabled — Raft-based metadata store confirmed"
  elif [[ $khepri_state == 'disabled' ]]; then
    add 'RabbitMQ 4.x Features' 'FTR-03' 'Khepri metadata store' CRITICAL \
      'khepri_db=disabled — Mnesia not available in RMQ 4.x' \
      'Khepri required (Mnesia removed in RMQ 4.1+)' \
      'Khepri migration did not complete. Cluster is in an unsupported state. Complete migration via Ops Manager tile upgrade or rabbitmqctl enable_feature_flag khepri_db.' \
      "Source: GET /api/feature-flags | khepri_db=disabled — Mnesia is removed in RabbitMQ 4.1+; this is an unsupported metadata store configuration"
  else
    add 'RabbitMQ 4.x Features' 'FTR-03' 'Khepri metadata store' REVIEW \
      "khepri_db=$khepri_state" 'Khepri required in RMQ 4.x' \
      'Verify metadata store state via Ops Manager. Mnesia is not available in RMQ 4.1+.' \
      "Source: GET /api/feature-flags | khepri_db=$khepri_state — unexpected state; verify via Ops Manager"
  fi
  add 'RabbitMQ Configuration' 'CFG-02' 'Feature flags' REVIEW \
    "total=$total_flags disabled=$disabled_flags unavailable=$unavail_flags" \
    'All required feature flags enabled' \
    'Review disabled or unavailable feature flags before tile upgrades.' '/api/feature-flags'
else
  add 'RabbitMQ 4.x Features' 'FTR-03' 'Khepri metadata store' 'NOT VERIFIED' \
    "Feature flags endpoint unavailable (${API_RESULTS[/api/feature-flags]:-no response})" \
    'Khepri expected as metadata store' \
    'Verify feature flags via Ops Manager or broker CLI.' '/api/feature-flags'
  add 'RabbitMQ Configuration' 'CFG-02' 'Feature flags' 'NOT VERIFIED' \
    "Unavailable (${API_RESULTS[/api/feature-flags]:-no response})" \
    'Feature flag inventory' 'Check permissions.' '/api/feature-flags'
fi

# Shovel status (DR/WSR check)
progress 'Checking shovel & federation status...'
if ((API_OK)) && api /api/shovels "$TMP/shovels.json"; then
  shovel_total=$(jq 'length' "$TMP/shovels.json")
  shovel_not_running=$(jq '[.[]|select(.state!="running")]|length' "$TMP/shovels.json")
  if ((shovel_not_running > 0)); then
    add 'Recovery & Operational Readiness' 'DR-03' 'Shovel status' WARNING \
      "$shovel_not_running/$shovel_total shovels not running" 'All shovels running' \
      'Investigate stopped shovels — may indicate DR/replication failure.' \
      "Source: GET /api/shovels | total=$shovel_total not-running=$shovel_not_running (source/dest URIs excluded)"
  elif ((shovel_total > 0)); then
    add 'Recovery & Operational Readiness' 'DR-03' 'Shovel status' PASS \
      "All $shovel_total shovel(s) running" 'All shovels running' 'No action.' \
      "Source: GET /api/shovels | total=$shovel_total all in running state"
  else
    add 'Recovery & Operational Readiness' 'DR-03' 'Shovel status' REVIEW \
      'No shovels configured' 'Shovels if used for DR/WSR replication' \
      'If DR uses shovels, confirm they are configured and running.' \
      "Source: GET /api/shovels | HTTP 200 — empty list; shovels plugin may not be in use"
  fi
else
  _shovel_status="${API_RESULTS[/api/shovels]:-unknown}"
  add 'Recovery & Operational Readiness' 'DR-03' 'Shovel status' 'NOT VERIFIED' \
    "GET /api/shovels returned $_shovel_status" \
    'All shovels running (if used for DR/WSR)' \
    "Grant 'monitoring' tag to the RabbitMQ user to enable shovel status checks." \
    "Source: GET /api/shovels | $_shovel_status — requires monitoring or administrator role"
fi

# Federation link health (DR-04)
if ((API_OK)) && api /api/federation-links "$TMP/fed_links.json"; then
  fed_total=$(jq 'length' "$TMP/fed_links.json")
  if ((fed_total == 0)); then
    add 'Recovery & Operational Readiness' 'DR-04' 'Federation link health' REVIEW \
      'No federation links configured' 'All links running (if federation is in use)' \
      'If federation is not in use this is expected. Confirm with application team.' \
      "Source: GET /api/federation-links | HTTP 200 — empty list; federation plugin may not be in use"
  else
    fed_running=$(jq '[.[]|select(.status=="running")]|length' "$TMP/fed_links.json")
    fed_stale=$(jq '[.[]|select(.status=="stale")]|length' "$TMP/fed_links.json")
    fed_error=$(jq '[.[]|select(.status=="error" or .status=="starting" or (.status!="running" and .status!="stale"))]|length' "$TMP/fed_links.json")
    fed_errors_detail=$(jq -r '[.[]|select(.status!="running")|"  "+.status+": "+(.exchange//.queue//"unknown")+" (vhost="+.vhost+")"]|join("\n")' "$TMP/fed_links.json" 2>/dev/null || printf '')
    if ((fed_error > 0)); then
      add 'Recovery & Operational Readiness' 'DR-04' 'Federation link health' CRITICAL \
        "$fed_error/$fed_total link(s) in error/unknown state" 'All federation links running' \
        'Investigate errored federation links — data may not be flowing between clusters.' \
        "Source: GET /api/federation-links | total=$fed_total running=$fed_running stale=$fed_stale error=$fed_error | link state detail (URIs excluded): $fed_errors_detail"
    elif ((fed_stale > 0)); then
      add 'Recovery & Operational Readiness' 'DR-04' 'Federation link health' WARNING \
        "$fed_stale/$fed_total link(s) stale" 'All federation links running' \
        'Stale links indicate the upstream is not reachable or has not sent data recently. Check upstream connectivity.' \
        "Source: GET /api/federation-links | total=$fed_total running=$fed_running stale=$fed_stale | link state detail (URIs excluded): $fed_errors_detail"
    else
      add 'Recovery & Operational Readiness' 'DR-04' 'Federation link health' PASS \
        "All $fed_total link(s) running" 'All federation links running' 'No action.' \
        "Source: GET /api/federation-links | total=$fed_total all in running state (URIs excluded from report)"
    fi
    # Note: message lag and retry counts are not available via the Management REST API
  fi
elif [[ "${API_RESULTS[/api/federation-links]:-}" == 'HTTP 404' ]]; then
  add 'Recovery & Operational Readiness' 'DR-04' 'Federation link health' REVIEW \
    'Federation plugin not enabled (HTTP 404)' 'All links running (if federation in use)' \
    'If federation is not in use this is expected. Enable rabbitmq_federation plugin if needed.' \
    "Source: GET /api/federation-links | HTTP 404 — plugin not installed or not enabled"
else
  _fed_status="${API_RESULTS[/api/federation-links]:-unknown}"
  add 'Recovery & Operational Readiness' 'DR-04' 'Federation link health' 'NOT VERIFIED' \
    "GET /api/federation-links returned $_fed_status" \
    'All federation links running (if in use)' \
    "Grant 'monitoring' tag to enable federation link checks." \
    "Source: GET /api/federation-links | $_fed_status — requires monitoring role"
fi

progress 'Checking security & TLS certificates...'
# ── Category 12: Security & TLS ──────────────────────────────────────────────
# Flag plaintext HTTP
if [[ $URL == http://* ]]; then
  add 'Security & TLS' 'SEC-00' 'Transport security' CRITICAL \
    'URL uses HTTP (no TLS)' 'HTTPS required' \
    'Use HTTPS endpoint for all RabbitMQ Management API access.' 'URL scheme'
fi

# Users (count only — no usernames written to report)
if ((API_OK)) && api /api/users "$TMP/users.json"; then
  user_count=$(jq 'length' "$TMP/users.json")
  admin_count=$(jq '[.[]|select(.tags|(if type=="array" then index("administrator")!=null else contains("administrator") end))]|length' "$TMP/users.json")
  guest_exists=$(jq '[.[]|select(.name=="guest")]|length' "$TMP/users.json")
  if ((guest_exists > 0)); then
    add 'Security & TLS' 'SEC-02' 'Default guest user' CRITICAL \
      'Guest user account exists' 'Guest user removed or restricted' \
      'Remove or restrict the guest user — it has default credentials and poses a security risk.' \
      "Source: GET /api/users | total=$user_count — guest user found (count only; usernames excluded from report)"
  else
    add 'Security & TLS' 'SEC-02' 'Default guest user' PASS \
      'Guest user not found' 'Guest user removed or restricted' 'No action.' \
      "Source: GET /api/users | total=$user_count — no guest user (count only; usernames excluded from report)"
  fi
  if ((admin_count > 3)); then
    add 'Security & TLS' 'SEC-03' 'Administrator user count' WARNING \
      "$admin_count administrator-tagged users" '<=3 administrators recommended' \
      'Review and reduce number of administrator-tagged users.' \
      "Source: GET /api/users | total=$user_count, administrators=$admin_count"
  else
    add 'Security & TLS' 'SEC-03' 'Administrator user count' PASS \
      "$admin_count administrator-tagged users (of $user_count total)" \
      '<=3 administrators' 'No action.' \
      "Source: GET /api/users | total=$user_count, administrators=$admin_count"
  fi
else
  _users_status="${API_RESULTS[/api/users]:-unknown}"
  add 'Security & TLS' 'SEC-02' 'Default guest user' 'NOT VERIFIED' \
    "GET /api/users returned $_users_status" \
    'Guest user removed or restricted' \
    "Grant 'administrator' tag to the RabbitMQ user to enable user security checks." \
    "Source: GET /api/users | $_users_status — requires administrator role"
  add 'Security & TLS' 'SEC-03' 'Administrator user count' 'NOT VERIFIED' \
    "GET /api/users returned $_users_status" \
    '<=3 administrators recommended' \
    "Grant 'administrator' tag to the RabbitMQ user to enable user security checks." \
    "Source: GET /api/users | $_users_status — requires administrator role"
fi

# TLS certificate expiry
if ((HAVE_SSL)) && [[ $URL == https://* ]]; then
  hostport=${URL#https://}
  host=${hostport%%:*}
  port=${hostport##*:}; [[ $hostport == *:* ]] || port=443
  if [[ $host =~ ^[a-zA-Z0-9_.-]+$ && $port =~ ^[0-9]+$ ]]; then
    expiry=$( (echo | openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null) || : )
    if [[ $expiry == notAfter=* ]]; then
      datepart=${expiry#notAfter=}
      expiry_epoch=$(date -u -d "$datepart" +%s 2>/dev/null || printf 0)
      now=$(date -u +%s)
      if ((expiry_epoch > 0)); then
        days=$(( (expiry_epoch - now) / 86400 ))
        if   ((days < 7));  then s=CRITICAL
        elif ((days < 30)); then s=WARNING
        else s=PASS; fi
        add 'Security & TLS' 'SEC-01' 'Presented TLS certificate expiry' "$s" \
          "$days days remaining" 'Warning <30 days, critical <7 days' \
          'Renew certificate through the approved platform workflow.' \
          "Source: openssl s_client -connect $host:$port | notAfter=$datepart | $days days remaining — presented certificate only; full chain trust validated by curl"
      else
        add 'Security & TLS' 'SEC-01' 'Presented TLS certificate expiry' 'NOT VERIFIED' \
          "$expiry" 'Valid certificate date' \
          'Inspect TLS certificate format.' 'OpenSSL date parse failed'
      fi
    else
      add 'Security & TLS' 'SEC-01' 'Presented TLS certificate expiry' 'NOT VERIFIED' \
        'TLS handshake unavailable' 'Readable certificate' \
        'Check endpoint and TLS listener.' 'openssl s_client'
    fi
  fi
else
  add 'Security & TLS' 'SEC-01' 'Presented TLS certificate expiry' 'NOT VERIFIED' \
    'OpenSSL or HTTPS endpoint unavailable' 'Valid certificate' \
    'Provide OpenSSL and HTTPS endpoint.' 'Preflight'
fi

# ── Category 2: BOSH Infrastructure ──────────────────────────────────────────
progress 'Checking BOSH infrastructure...'
if [[ -n $BOSH_DEP && $HAVE_BOSH == 1 ]]; then
  if bosh -d "$BOSH_DEP" vms > "$TMP/bosh-vms.txt" 2>> "$ERRORS"; then
    running_vms=$(grep -c 'running' "$TMP/bosh-vms.txt" 2>/dev/null; :)
    failing_vms=$(grep -cE 'failing|stopped|unresponsive' "$TMP/bosh-vms.txt" 2>/dev/null; :)
    running_vms=${running_vms:-0}; failing_vms=${failing_vms:-0}
    if ((failing_vms > 0)); then s=CRITICAL; else s=PASS; fi
    add 'BOSH Infrastructure' 'BOSH-01' 'BOSH VM process state' "$s" \
      "running=$running_vms failing=$failing_vms" 'All VMs running' \
      'Investigate failing BOSH VMs via bosh instances --ps.' \
      'bosh vms output parsed; raw host details excluded'
  else
    add 'BOSH Infrastructure' 'BOSH-01' 'BOSH VM inventory' 'NOT VERIFIED' \
      'BOSH command failed' 'Healthy BOSH deployment' \
      'Check BOSH authentication, deployment name and permissions.' 'bosh vms'
  fi
else
  add 'BOSH Infrastructure' 'BOSH-01' 'BOSH VM inventory' 'NOT VERIFIED' \
    'No authenticated BOSH collector configured' 'Healthy BOSH deployment' \
    'Provide --bosh-deployment and authenticated BOSH CLI for infrastructure checks.' 'Preflight'
fi

# ── Application Health ────────────────────────────────────────────────────────
progress 'Checking application health patterns...'

# APP-01 and APP-06: use existing queues.jsonl (no extra API calls)
if [[ -s "$TMP/queues.jsonl" ]]; then

  # APP-01: Dead Letter Queue depth
  _dlq_total=$(jq -s '[.[]|select(.name|test("(?i)(dlq|deadletter|dead.letter|\\.dead|\\.failed|\\.error|_dead|_failed|_error|-dl$|_dl$|dead$|failed$|error$)"))]|length' "$TMP/queues.jsonl")
  _dlq_msgs=$(jq -s '[.[]|select(.name|test("(?i)(dlq|deadletter|dead.letter|\\.dead|\\.failed|\\.error|_dead|_failed|_error|-dl$|_dl$|dead$|failed$|error$)"))|select((.messages_ready//0)>0)]|length' "$TMP/queues.jsonl")
  if ((_dlq_msgs > 0)); then
    if ((_dlq_msgs >= 3)); then s=CRITICAL; else s=WARNING; fi
    _dlq_names=$(jq -sr '[.[]|select(.name|test("(?i)(dlq|deadletter|dead.letter|\\.dead|\\.failed|\\.error|_dead|_failed|_error|-dl$|_dl$|dead$|failed$|error$)"))|select((.messages_ready//0)>0)|.name+"="+(.messages_ready|tostring)]|join(", ")' "$TMP/queues.jsonl")
    add 'Application Health' 'APP-01' 'Dead letter queue depth' "$s" \
      "$_dlq_msgs DLQ(s) accumulating messages: $_dlq_names" \
      '0 DLQs with messages unless intentional' \
      'Application processing failures are dead-lettering messages. Investigate consumer logs for rejection reasons and confirm DLX policy configuration.' \
      "Source: GET /api/queues | queues matching DLQ naming patterns with messages_ready>0: $_dlq_msgs of $_dlq_total detected"
  elif ((_dlq_total > 0)); then
    add 'Application Health' 'APP-01' 'Dead letter queue depth' PASS \
      "$_dlq_total DLQ(s) detected, all empty" '0 DLQs with messages unless intentional' 'No action.' \
      "Source: GET /api/queues | $_dlq_total DLQ queue(s) matched by naming pattern — all have messages_ready=0"
  else
    add 'Application Health' 'APP-01' 'Dead letter queue depth' REVIEW \
      'No queues matching DLQ naming patterns detected' 'DLQ pattern check by name' \
      'If dead-lettering is in use, confirm DLX policies are configured. DLQ detection uses naming patterns: dlq, dead, failed, error, -dl, _dl suffixes.' \
      "Source: GET /api/queues | no queues matched common DLQ naming patterns (dlq, dead*, failed*, error*, *-dl, *_dl)"
  fi

  # APP-06: High redelivery rate per queue
  _high_redeliver=$(jq -s '[.[]|
    select(
      ((.message_stats.redeliver_details.rate//0) > 0.5) and
      ((.message_stats.deliver_details.rate//0) > 0) and
      ((.message_stats.redeliver_details.rate//0) / (.message_stats.deliver_details.rate//0) > 0.1)
    )]|length' "$TMP/queues.jsonl")
  if ((_high_redeliver > 0)); then
    _redeliver_detail=$(jq -sr '[.[]|
      select(
        ((.message_stats.redeliver_details.rate//0) > 0.5) and
        ((.message_stats.deliver_details.rate//0) > 0) and
        ((.message_stats.redeliver_details.rate//0) / (.message_stats.deliver_details.rate//0) > 0.1)
      )|.name+"="+((.message_stats.redeliver_details.rate//0)|tostring)+"/s"]|join(", ")' "$TMP/queues.jsonl")
    add 'Application Health' 'APP-06' 'High redelivery rate per queue' WARNING \
      "$_high_redeliver queue(s) with sustained redelivery >10% of deliver rate: $_redeliver_detail" \
      'Redelivery rate <10% of deliver rate' \
      'Consumer-side processing failures or poison messages causing repeated redelivery. Add a DLQ policy to quarantine poison messages and investigate consumer error handling.' \
      "Source: GET /api/queues | redeliver_details.rate / deliver_details.rate per queue; threshold >0.5/s AND >10% of delivery rate"
  else
    add 'Application Health' 'APP-06' 'High redelivery rate per queue' PASS \
      'No queues with sustained high redelivery rate' 'Redelivery rate <10% of deliver rate' 'No action.' \
      "Source: GET /api/queues | redeliver/deliver ratio within normal range on all queues"
  fi
fi

# APP-04: Consumer channels without prefetch limit (uses existing channels.json)
if [[ -f "$TMP/channels.json" ]]; then
  _total_con_ch=$(jq '[.[]|select((.consumer_count//0)>0)]|length' "$TMP/channels.json")
  if ((_total_con_ch > 0)); then
    _no_prefetch=$(jq '[.[]|select(((.prefetch_count//0)==0) and ((.consumer_count//0)>0))]|length' "$TMP/channels.json")
    if ((_no_prefetch > 0)); then
      add 'Application Health' 'APP-04' 'Consumer channels without prefetch limit' WARNING \
        "$_no_prefetch/$_total_con_ch consumer channel(s) have prefetch_count=0 (unlimited)" \
        'Prefetch limit set on all consumer channels' \
        'Set a prefetch limit (basicQos) on consumer channels. Unlimited prefetch causes one consumer to hoard all messages, starving others and crashing on high load.' \
        "Source: GET /api/channels | prefetch_count=0 on $_no_prefetch of $_total_con_ch consumer channels"
    else
      add 'Application Health' 'APP-04' 'Consumer channels without prefetch limit' PASS \
        "All $_total_con_ch consumer channel(s) have prefetch limits configured" \
        'Prefetch limit set on all consumer channels' 'No action.' \
        "Source: GET /api/channels | prefetch_count>0 on all $_total_con_ch consumer channels"
    fi
  else
    add 'Application Health' 'APP-04' 'Consumer channels without prefetch limit' REVIEW \
      'No consumer channels detected at time of scan' 'Consumer channels with prefetch configured' \
      'No active consumers via channels at scan time. Re-run during active workload to assess prefetch configuration.' \
      "Source: GET /api/channels | no channels with consumer_count>0 found at scan time"
  fi
fi

# APP-05: Client library versions (uses existing connections.json)
if [[ -f "$TMP/connections.json" ]]; then
  _app05_count=$(jq 'length' "$TMP/connections.json")
  if ((_app05_count > 0)); then
    _client_summary=$(jq -r '[.[]|
      ((.client_properties.product//"unknown")+" "+(.client_properties.version//"unknown"))]|
      group_by(.)|map({lib:.[0],count:length})|sort_by(.count)|reverse|.[0:6]|
      map((.count|tostring)+"x "+.lib)|join(", ")' "$TMP/connections.json" 2>/dev/null || printf 'unknown')
    _unknown_clients=$(jq '[.[]|select((.client_properties.product//"")=="")]|length' "$TMP/connections.json" 2>/dev/null || printf 0)
    add 'Application Health' 'APP-05' 'Client library versions' REVIEW \
      "$_app05_count connection(s) — library breakdown: $_client_summary" \
      'Supported, up-to-date client libraries in use' \
      'Review client library versions with application teams. Outdated or unsupported clients may have bugs or compatibility issues with RabbitMQ 4.x.' \
      "Source: GET /api/connections | client_properties.product and .version fields — $_unknown_clients connection(s) with unidentified library"
  fi
fi

# APP-02: Consumer auto-ack (fetch /api/consumers — paginated)
if ((API_OK)); then
  _con_page=1; _con_ok=1; : > "$TMP/consumers.jsonl"
  while :; do
    _con_path="/api/consumers?page=${_con_page}&page_size=200&pagination=true"
    if ! api "$_con_path" "$TMP/con_p.json"; then _con_ok=0; break; fi
    if jq -e '(.items|type)=="array"' "$TMP/con_p.json" >/dev/null 2>&1; then
      jq -c '.items[]' "$TMP/con_p.json" >> "$TMP/consumers.jsonl" 2>/dev/null || :
      _con_pages=$(jq '.page_count // 1' "$TMP/con_p.json")
      ((_con_page >= _con_pages)) && break
      _con_page=$((_con_page + 1))
      ((_con_page > 50)) && break
    else
      jq -c '.[]' "$TMP/con_p.json" >> "$TMP/consumers.jsonl" 2>/dev/null || cp "$TMP/con_p.json" "$TMP/consumers.jsonl"
      break
    fi
  done
  if ((_con_ok)) && [[ -s "$TMP/consumers.jsonl" ]]; then
    _total_consumers=$(jq -s '[.[]|select(.queue.name|test("^rabbitmq\\.")|not)]|length' "$TMP/consumers.jsonl")
    _auto_ack=$(jq -s '[.[]|select(.ack_required==false)|select(.queue.name|test("^rabbitmq\\.")|not)]|length' "$TMP/consumers.jsonl")
    if ((_auto_ack > 0)); then
      _auto_ack_queues=$(jq -sr '[.[]|select(.ack_required==false)|select(.queue.name|test("^rabbitmq\\.")|not)|.queue.name]|unique|join(", ")' "$TMP/consumers.jsonl")
      add 'Application Health' 'APP-02' 'Consumer auto-acknowledgement' WARNING \
        "$_auto_ack/$_total_consumers consumer(s) using auto-ack on queue(s): $_auto_ack_queues" \
        'All consumers using manual acknowledgement' \
        'Auto-ack consumers risk silent message loss on crash — the broker removes messages on delivery before the application confirms processing. Switch to manual acknowledgement with explicit ack/nack.' \
        "Source: GET /api/consumers | ack_required=false on $_auto_ack of $_total_consumers consumers"
    else
      add 'Application Health' 'APP-02' 'Consumer auto-acknowledgement' PASS \
        "All $_total_consumers application consumer(s) using manual acknowledgement" \
        'All consumers using manual acknowledgement' 'No action.' \
        "Source: GET /api/consumers | ack_required=true on all $_total_consumers application consumers (internal rabbitmq.* queues excluded)"
    fi
  elif ((_con_ok)); then
    add 'Application Health' 'APP-02' 'Consumer auto-acknowledgement' REVIEW \
      'No consumers detected at time of scan' 'All consumers using manual acknowledgement' \
      'No active consumers at scan time. Re-run during active workload to assess acknowledgement mode.' \
      "Source: GET /api/consumers | HTTP 200 — empty consumer list at scan time"
  else
    _con_err="${API_RESULTS[$_con_path]:-no response}"
    add 'Application Health' 'APP-02' 'Consumer auto-acknowledgement' 'NOT VERIFIED' \
      "GET /api/consumers returned $_con_err" \
      'All consumers using manual acknowledgement' \
      "Grant 'monitoring' tag to the RabbitMQ user to enable consumer checks." \
      "Source: GET /api/consumers | $_con_err — requires monitoring role"
  fi
else
  add 'Application Health' 'APP-02' 'Consumer auto-acknowledgement' 'NOT VERIFIED' \
    'API not available' 'All consumers using manual acknowledgement' \
    'Configure RabbitMQ API access to enable consumer checks.' \
    "Source: GET /api/consumers | API not available"
fi

# APP-03 and APP-07: Bindings + exchange topology (new API calls)
if ((API_OK)) && api /api/bindings "$TMP/bindings.json"; then

  # APP-03: Queues with no exchange bindings
  if [[ -s "$TMP/queues.jsonl" ]]; then
    _bound_q=$(jq -c '[.[]|select(.destination_type=="queue")|.destination]|unique' "$TMP/bindings.json")
    _unbound=$(jq -s --argjson b "$_bound_q" \
      '[.[]|select(.name as $n | ($b|index($n))==null)]|length' "$TMP/queues.jsonl")
    _unbound_msgs=$(jq -s --argjson b "$_bound_q" \
      '[.[]|select(.name as $n | ($b|index($n))==null)|select((.messages_ready//0)>0)]|length' "$TMP/queues.jsonl")
    if ((_unbound_msgs > 0)); then
      _unbound_names=$(jq -sr --argjson b "$_bound_q" \
        '[.[]|select(.name as $n | ($b|index($n))==null)|select((.messages_ready//0)>0)|.name]|join(", ")' "$TMP/queues.jsonl")
      add 'Application Health' 'APP-03' 'Queues with no exchange bindings' WARNING \
        "$_unbound_msgs queue(s) have messages but no exchange binding: $_unbound_names" \
        '0 queues accumulating messages without an exchange binding' \
        'Queues without bindings can only receive messages via the default exchange (direct queue-name routing). If routing topology changed, publishers may no longer reach these queues.' \
        "Source: GET /api/bindings + /api/queues | $_unbound total queues with no exchange binding; $_unbound_msgs of those have messages_ready>0"
    elif ((_unbound > 0)); then
      add 'Application Health' 'APP-03' 'Queues with no exchange bindings' REVIEW \
        "$_unbound queue(s) have no exchange bindings (all empty)" \
        '0 unbound queues or confirmed intentional use of default exchange routing' \
        'Queues without bindings rely on default exchange routing (key = queue name). Confirm this is intentional.' \
        "Source: GET /api/bindings + /api/queues | $_unbound unbound queues detected — all have messages_ready=0"
    else
      add 'Application Health' 'APP-03' 'Queues with no exchange bindings' PASS \
        'All queues have at least one exchange binding' 'All queues reachable via exchanges' 'No action.' \
        "Source: GET /api/bindings + /api/queues | all queues appear as binding destinations"
    fi
  fi

  # APP-07: Exchange topology gaps (fetch /api/exchanges)
  if ((API_OK)) && api /api/exchanges "$TMP/exchanges.json"; then
    _bound_x=$(jq -c '[.[]|select(.destination_type=="queue")|.source]|unique' "$TMP/bindings.json")
    _gap_count=$(jq --argjson b "$_bound_x" \
      '[.[]|select(.name!="" and (.name|test("^amq\\.")|not) and (.name as $n | ($b|index($n))==null))]|length' \
      "$TMP/exchanges.json")
    if ((_gap_count > 0)); then
      _gap_names=$(jq -r --argjson b "$_bound_x" \
        '[.[]|select(.name!="" and (.name|test("^amq\\.")|not) and (.name as $n | ($b|index($n))==null))|.name+" ("+.type+")"]|join(", ")' \
        "$TMP/exchanges.json")
      add 'Application Health' 'APP-07' 'Exchange topology gaps' WARNING \
        "$_gap_count user-defined exchange(s) have no queue bindings: $_gap_names" \
        '0 exchanges without queue bindings' \
        'Messages published to these exchanges are silently discarded — no queues are bound to receive them. Verify the routing topology and add bindings or remove unused exchanges.' \
        "Source: GET /api/exchanges + /api/bindings | $_gap_count non-default non-amq.* exchanges have no bound queues"
    else
      add 'Application Health' 'APP-07' 'Exchange topology gaps' PASS \
        'All user-defined exchanges have at least one queue binding' 'No exchange topology gaps' 'No action.' \
        "Source: GET /api/exchanges + /api/bindings | all non-default exchanges have bound queues"
    fi
  else
    add 'Application Health' 'APP-07' 'Exchange topology gaps' 'NOT VERIFIED' \
      "GET /api/exchanges returned ${API_RESULTS[/api/exchanges]:-no response}" \
      '0 exchanges without queue bindings' \
      "Grant 'monitoring' tag to the RabbitMQ user to enable exchange topology checks." \
      "Source: GET /api/exchanges | ${API_RESULTS[/api/exchanges]:-no response} — requires monitoring role"
  fi
else
  _bindings_err="${API_RESULTS[/api/bindings]:-no response}"
  add 'Application Health' 'APP-03' 'Queues with no exchange bindings' 'NOT VERIFIED' \
    "GET /api/bindings returned $_bindings_err" \
    '0 unbound queues' \
    "Grant 'monitoring' tag to the RabbitMQ user to enable binding checks." \
    "Source: GET /api/bindings | $_bindings_err — requires monitoring role"
  add 'Application Health' 'APP-07' 'Exchange topology gaps' 'NOT VERIFIED' \
    "GET /api/bindings returned $_bindings_err" \
    '0 exchanges without queue bindings' \
    "Grant 'monitoring' tag to the RabbitMQ user to enable exchange topology checks." \
    "Source: GET /api/bindings | $_bindings_err — requires monitoring role"
fi

# ── Static evidence-gap entries for categories not covered by API ─────────────
add 'Tile & Service Instance' 'TILE-02' 'Tile patch and service plan' 'NOT VERIFIED' \
  'Ops Manager inventory not collected' 'Supported tile build and service plan' \
  'Review Ops Manager deployment and CF service instance details.' 'Ops Manager integration not enabled'

add 'Disk & Persistence' 'DISK-02' 'Persistent disk I/O latency' 'NOT VERIFIED' \
  'Historical storage telemetry unavailable' 'Storage I/O within SLO' \
  'Review BOSH vitals (bosh vms --vitals) or platform storage monitoring.' 'No storage telemetry integration'

add 'Messaging Performance' 'MSG-02' 'Historical throughput and redelivery trend' 'NOT VERIFIED' \
  'No time-series data source' 'Stable processing; no abnormal accumulation' \
  'Review Prometheus or Tanzu Hub monitoring data for trends.' 'Snapshot-only collector'

add 'RabbitMQ Configuration' 'CFG-03' 'Runtime parameters and limits' 'NOT VERIFIED' \
  'Not fully visible via Management API' 'Approved runtime configuration' \
  'Collect supported diagnostics and Ops Manager tile configuration.' 'Requires broker CLI or Ops Manager access'

add 'Monitoring & Alerting' 'MON-01' 'Metrics delivery and alert routing' 'NOT VERIFIED' \
  'Monitoring integration not configured' 'Required monitoring active' \
  'Review Tanzu Hub, Healthwatch, or Prometheus scrape configuration.' 'No monitoring credentials supplied'

add 'Recovery & Operational Readiness' 'DR-01' 'Backup and recovery readiness' 'NOT VERIFIED' \
  'No recovery evidence collectible via API' 'Tested recovery; approved RPO/RTO' \
  'Request customer DR runbook and most recent recovery test results.' 'Not inferable from broker API'

# ── Ensure all 18 categories have at least one entry ─────────────────────────
for i in "${!CATS[@]}"; do
  cat_id="CAT$(printf '%02d' $((i+1)))"
  if ((HAVE_JQ)); then
    present=$(jq -s --arg c "${CATS[$i]}" '[.[]|select(.category==$c)]|length' "$RESULTS")
  else
    present=0
  fi
  if ((present == 0)); then
    add "${CATS[$i]}" "$cat_id" 'Category not collected' 'NOT VERIFIED' \
      'No supported collector available for this category' 'Supported data source' \
      'Provide appropriate platform, broker or monitoring access.' 'No check evidence'
  fi
done

# ── Compute summary counts ────────────────────────────────────────────────────
PASS=0; WARN=0; CRIT=0; NV=0; REVIEW_COUNT=0
if ((HAVE_JQ)); then
  PASS=$(jq   -s '[.[]|select(.status=="PASS")]|length'         "$RESULTS")
  WARN=$(jq   -s '[.[]|select(.status=="WARNING")]|length'      "$RESULTS")
  CRIT=$(jq   -s '[.[]|select(.status=="CRITICAL")]|length'     "$RESULTS")
  NV=$(jq     -s '[.[]|select(.status=="NOT VERIFIED")]|length' "$RESULTS")
  REVIEW_COUNT=$(jq -s '[.[]|select(.status=="REVIEW")]|length' "$RESULTS")
else
  NV=$(wc -l < "$RESULTS" | tr -d ' ')
fi

# ── Compute per-category worst status (for dashboard) ────────────────────────
cat_status_json='[]'
if ((HAVE_JQ)); then
  cat_status_json=$(jq -s '
    group_by(.category) |
    map({
      category: .[0].category,
      worst: (
        if map(select(.status=="CRITICAL"))|length > 0 then "CRITICAL"
        elif map(select(.status=="WARNING"))|length  > 0 then "WARNING"
        elif map(select(.status=="PASS"))|length     > 0 then "PASS"
        elif map(select(.status=="REVIEW"))|length   > 0 then "REVIEW"
        else "NOT VERIFIED" end
      )
    })
  ' "$RESULTS")
fi

# ── HTML helpers ──────────────────────────────────────────────────────────────
html_escape() {
  local s=$1
  s=${s//&/\&amp;}; s=${s//</\&lt;}; s=${s//>/\&gt;}
  s=${s//\"/\&quot;}; s=${s//\'/\&#39;}
  printf '%s' "$s"
}

HTML_NAME="${SAFE_CLUSTER}_rmq_health_report_${STAMP}.html"
HTML="$DIR/$HTML_NAME"
{
# ────────────────────────────────────────────────────────────────────────────
cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title id="page-title">Tanzu RabbitMQ Health Check</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font:14px/1.6 Arial,sans-serif;background:#f0f2f5;color:#17263c}
a{color:inherit;text-decoration:none}

/* Nav */
nav{background:#001e3c;padding:10px 24px;display:flex;align-items:center;gap:20px;position:sticky;top:0;z-index:100}
nav a{color:#90bfff;font-size:13px;padding:4px 8px;border-radius:4px;transition:background .15s}
nav a:hover{background:#003366;color:white}
nav .nav-brand{color:white;font-weight:bold;font-size:15px;margin-right:12px}

/* Header */
header{background:linear-gradient(135deg,#003366 0%,#0063a6 100%);color:white;padding:28px 32px}
header h1{font-size:26px;font-weight:bold;margin-bottom:6px}
header .meta{font-size:13px;opacity:.9;line-height:1.8}
header .meta span{margin-right:20px}

/* Layout */
.wrap{max-width:1400px;margin:auto;padding:20px}

/* Sections */
.section{background:white;border-radius:10px;margin:20px 0;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08)}
.section-header{background:#003a6e;color:white;padding:12px 20px;font-size:15px;font-weight:bold}
.section-body{padding:20px;overflow-x:auto}

/* Sharing warning banner */
.warning-banner{background:#fff3cd;border:1px solid #ffc107;border-radius:8px;padding:14px 18px;margin-bottom:20px;font-size:13px}
.warning-banner strong{color:#856404}

/* Summary cards */
.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:20px}
.card{border-radius:8px;padding:16px 20px;text-align:center}
.card .count{font-size:32px;font-weight:bold;line-height:1}
.card .label{font-size:12px;margin-top:4px;font-weight:bold;text-transform:uppercase;letter-spacing:.5px}
.card-critical{background:#ffe4e1;color:#9c2219}
.card-warning{background:#fff3cd;color:#825800}
.card-pass{background:#d4edda;color:#155724}
.card-review{background:#cce5ff;color:#004085}
.card-nv{background:#e9ecef;color:#495057}

/* Category grid */
.cat-grid{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:20px}
.cat-tile{border-radius:8px;padding:12px;cursor:pointer;transition:transform .1s;border:2px solid transparent}
.cat-tile:hover{transform:translateY(-2px)}
.cat-tile .cat-name{font-size:12px;font-weight:bold;line-height:1.3}
.cat-tile .cat-pill{margin-top:6px}
.cat-tile-CRITICAL{background:#ffe4e1;border-color:#f5a09a}
.cat-tile-WARNING{background:#fff3cd;border-color:#ffd060}
.cat-tile-PASS{background:#d4edda;border-color:#98d4a7}
.cat-tile-REVIEW{background:#cce5ff;border-color:#80bdff}
.cat-tile-NOTVERIFIED{background:#e9ecef;border-color:#ced4da}

/* Status pills */
.pill{display:inline-block;padding:3px 10px;border-radius:12px;font-size:11px;font-weight:bold;white-space:nowrap}
.PASS{background:#d4edda;color:#155724}
.WARNING{background:#fff3cd;color:#825800}
.CRITICAL{background:#ffe4e1;color:#9c2219}
.REVIEW{background:#cce5ff;color:#004085}
.NOTVERIFIED{background:#e9ecef;color:#495057}

/* Legend */
.legend{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:16px;font-size:12px;align-items:center}
.legend span{padding:3px 10px;border-radius:12px;font-weight:bold}

/* Tables */
table{border-collapse:collapse;width:100%;font-size:12px}
th{background:#e8f0fe;color:#1a3d6e;font-weight:bold;padding:10px;text-align:left;border-bottom:2px solid #c5d5ef}
td{padding:9px 10px;border-bottom:1px solid #e8ecf0;vertical-align:top}
tr:last-child td{border-bottom:none}
tr:hover td{background:#f8faff}
.row-CRITICAL td{border-left:4px solid #dc3545}
.row-WARNING td{border-left:4px solid #ffc107}
.row-PASS td{border-left:4px solid #28a745}
.row-REVIEW td{border-left:4px solid #007bff}
.row-NOTVERIFIED td{border-left:4px solid #6c757d}

/* Category group */
.cat-group{margin-bottom:16px;border:1px solid #dee2e6;border-radius:8px;overflow:hidden}
.cat-group summary{background:#f1f4f9;padding:10px 16px;cursor:pointer;display:flex;justify-content:space-between;align-items:center;font-weight:bold;font-size:13px;list-style:none}
.cat-group summary::-webkit-details-marker{display:none}
.cat-group summary .cat-summary-left{display:flex;align-items:center;gap:10px}
.cat-group summary .cat-counts{font-size:11px;color:#6c757d;font-weight:normal}
.cat-group[open] summary{background:#e8f0fe}
.cat-group table{border-radius:0}

/* Metadata grid */
.meta-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.meta-block{font-size:12px}
.meta-block table th{background:#f1f4f9;color:#333;font-weight:bold}
.meta-block table td{background:white}
.status-ok{color:#28a745;font-weight:bold}
.status-err{color:#dc3545;font-weight:bold}
.status-na{color:#6c757d}

/* Evidence details */
details.evidence{border:1px solid #dee2e6;border-radius:5px;margin:5px 0}
details.evidence summary{padding:6px 10px;cursor:pointer;font-size:11px;color:#555}
details.evidence pre{padding:10px;font-size:11px;background:#f8f9fa;white-space:pre-wrap;overflow-wrap:anywhere}

/* Footer */
footer{background:#001e3c;color:#90bfff;padding:20px 32px;font-size:12px;line-height:1.8}
footer strong{color:white}

/* Print */
@media print{
  nav,footer .no-print{display:none}
  body{background:white;font-size:12px}
  .section{box-shadow:none;break-inside:avoid;border:1px solid #ddd}
  .cat-grid{grid-template-columns:repeat(5,1fr)}
  .cards{grid-template-columns:repeat(5,1fr)}
  thead{display:table-header-group}
  .cat-group{break-inside:avoid}
  @page{margin:1.5cm;size:A4}
}
</style>
</head>
<body>
HTML

# Nav
printf '<nav><span class="nav-brand">Tanzu RabbitMQ Health Check</span>'
printf '<a href="#overview">Overview</a>'
printf '<a href="#action">Action Required</a>'
printf '<a href="#gaps">Evidence Gaps</a>'
printf '<a href="#categories">All Checks</a>'
printf '<a href="#logs">Logs</a></nav>\n'

# Header
printf '<header>\n'
printf '<h1>Tanzu RabbitMQ Health Check</h1>\n'
printf '<div class="meta">\n'
printf '<span><strong>Customer:</strong> %s</span>' "$(html_escape "$CUSTOMER")"
printf '<span><strong>Cluster:</strong> %s</span>' "$(html_escape "$CLUSTER")"
printf '<span><strong>Generated UTC:</strong> %s</span>' "$(html_escape "$STAMP")"
printf '<span><strong>Script:</strong> v%s</span>' "$VERSION"
printf '</div></header>\n'

printf '<div class="wrap">\n'

# ── Sharing warning banner ────────────────────────────────────────────────────
cat <<'WARN_BANNER'
<div class="warning-banner">
<strong>⚠ Before sharing this report with Broadcom Support:</strong>
Review queue names, vhost names, hostnames and topology for any confidential information.
<strong>Not collected:</strong> passwords, message bodies, user credentials, or payloads.
Share only with authorized Broadcom Support personnel via approved channels.
</div>
WARN_BANNER

# ── Overview section ──────────────────────────────────────────────────────────
printf '<section id="overview" class="section">\n'
printf '<div class="section-header">Overview &amp; Assessment Coverage</div>\n'
printf '<div class="section-body">\n'

# Legend
cat <<'LEGEND'
<div class="legend">
<strong>Status key:</strong>
<span class="pill PASS">PASS</span> Baseline met &nbsp;
<span class="pill WARNING">WARNING</span> Investigate &nbsp;
<span class="pill CRITICAL">CRITICAL</span> Act now &nbsp;
<span class="pill REVIEW">REVIEW</span> Judgment call — not a failure &nbsp;
<span class="pill NOTVERIFIED">NOT VERIFIED</span> Missing evidence — not a pass
</div>
LEGEND

# Summary cards
printf '<div class="cards">\n'
printf '<div class="card card-critical"><div class="count">%s</div><div class="label">Critical</div></div>\n' "$CRIT"
printf '<div class="card card-warning"><div class="count">%s</div><div class="label">Warning</div></div>\n' "$WARN"
printf '<div class="card card-pass"><div class="count">%s</div><div class="label">Pass</div></div>\n' "$PASS"
printf '<div class="card card-review"><div class="count">%s</div><div class="label">Review</div></div>\n' "$REVIEW_COUNT"
printf '<div class="card card-nv"><div class="count">%s</div><div class="label">Not Verified</div></div>\n' "$NV"
printf '</div>\n'

# Category grid (15 tiles)
printf '<div class="cat-grid">\n'
for i in "${!CATS[@]}"; do
  cname="${CATS[$i]}"
  worst='NOTVERIFIED'
  if ((HAVE_JQ)); then
    worst=$(echo "$cat_status_json" | jq -r --arg c "$cname" '.[]|select(.category==$c)|.worst // "NOT VERIFIED"' 2>/dev/null | head -1)
    worst=${worst// /}
    [[ -z $worst ]] && worst='NOTVERIFIED'
  fi
  anchor="cat-$(echo "$cname" | tr ' &/' '-' | tr -d "'" | tr '[:upper:]' '[:lower:]')"
  printf '<a href="#%s"><div class="cat-tile cat-tile-%s">' "$anchor" "$worst"
  printf '<div class="cat-name">%s</div>' "$(html_escape "$cname")"
  display_worst=${worst//NOTVERIFIED/NOT VERIFIED}
  printf '<div class="cat-pill"><span class="pill %s">%s</span></div>' "$worst" "$display_worst"
  printf '</div></a>\n'
done
printf '</div>\n'

# Run metadata
printf '<div class="meta-grid">\n'

# Collectors
printf '<div class="meta-block">\n'
printf '<table><tr><th colspan="2">Collectors Available</th></tr>\n'
for spec in 'bash:Bash' 'curl:curl' 'jq:jq' 'openssl:OpenSSL' 'bosh:BOSH CLI' 'cf:CF CLI'; do
  bin=${spec%%:*}; tool=${spec#*:}
  if command -v "$bin" >/dev/null 2>&1; then
    printf '<tr><td>%s</td><td class="status-ok">✓ Available</td></tr>\n' "$tool"
  else
    printf '<tr><td>%s</td><td class="status-na">— Not found</td></tr>\n' "$tool"
  fi
done
printf '</table></div>\n'

# API coverage
printf '<div class="meta-block">\n'
printf '<table><tr><th colspan="2">API Endpoint Results</th></tr>\n'
printf '<tr><td>%s</td><td>%s</td></tr>\n' \
  "Expected nodes" "$(html_escape "${EXPECTED:-Not specified}")"
for path in /api/overview /api/nodes /api/health/checks/alarms /api/queues /api/connections /api/channels /api/policies /api/feature-flags /api/shovels /api/federation-links /api/users; do
  result="${API_RESULTS[$path]:-Not attempted}"
  if [[ $result == "HTTP 200" ]]; then css="status-ok"; icon="✓"
  elif [[ $result == "Not attempted" ]]; then css="status-na"; icon="—"
  else css="status-err"; icon="✗"; fi
  printf '<tr><td>%s</td><td class="%s">%s %s</td></tr>\n' \
    "$(html_escape "$path")" "$css" "$icon" "$(html_escape "$result")"
done
printf '</table></div>\n'
printf '</div>\n'  # end meta-grid

printf '</div></section>\n'

# ── Priority Findings: Action Required ───────────────────────────────────────
printf '<section id="action" class="section">\n'
printf '<div class="section-header">🚨 Action Required (CRITICAL &amp; WARNING)</div>\n'
printf '<div class="section-body">\n'
if ((HAVE_JQ)); then
  # Sort: CRITICAL=0, WARNING=1
  findings=$(jq -s '
    map(select(.status=="CRITICAL" or .status=="WARNING")) |
    sort_by(if .status=="CRITICAL" then 0 elif .status=="WARNING" then 1 else 2 end)
  ' "$RESULTS")
  count=$(echo "$findings" | jq 'length')
  if ((count == 0)); then
    printf '<p style="color:#155724;font-weight:bold;padding:10px">✓ No critical or warning findings.</p>\n'
  else
    printf '<table><tr><th>ID</th><th>Category</th><th>Check</th><th>Status</th><th>Actual</th><th>Recommendation</th></tr>\n'
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      mapfile -t fields < <(jq -r '[.id,.category,.title,.status,.actual,.recommendation]|.[]|@base64' <<< "$line")
      vals=(); for f in "${fields[@]}"; do vals+=("$(printf '%s' "$f" | base64 -d)"); done
      css_class="${vals[3]// /}"
      printf '<tr class="row-%s"><td><strong>%s</strong></td><td>%s</td><td>%s</td><td><span class="pill %s">%s</span></td><td>%s</td><td>%s</td></tr>\n' \
        "$css_class" \
        "$(html_escape "${vals[0]}")" "$(html_escape "${vals[1]}")" \
        "$(html_escape "${vals[2]}")" "$css_class" \
        "$(html_escape "${vals[3]}")" "$(html_escape "${vals[4]}")" \
        "$(html_escape "${vals[5]}")"
    done < <(echo "$findings" | jq -c '.[]')
    printf '</table>\n'
  fi
else
  printf '<p>Install jq for structured findings.</p>\n'
fi
printf '</div></section>\n'

# ── Evidence Gaps ─────────────────────────────────────────────────────────────
printf '<section id="gaps" class="section">\n'
printf '<div class="section-header">📋 Evidence Gaps (NOT VERIFIED — missing access or tooling, not necessarily failures)</div>\n'
printf '<div class="section-body">\n'
printf '<p style="margin:0 0 12px;font-size:0.93em;color:#555;">Each row below could not be verified during this run. The <strong>Root Cause</strong> column explains exactly why — permission denied, missing tool, or not collectible via the Management API alone. The <strong>How to fix</strong> column gives the specific action needed to get a result on the next run.</p>\n'
if ((HAVE_JQ)); then
  printf '<table><tr><th>ID</th><th>Category</th><th>Check</th><th>Root Cause</th><th>How to fix</th></tr>\n'
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    mapfile -t fields < <(jq -r '[.id,.category,.title,.actual,.recommendation,.evidence]|.[]|@base64' <<< "$line")
    vals=(); for f in "${fields[@]}"; do vals+=("$(printf '%s' "$f" | base64 -d)"); done
    # Derive a short cause label from actual/evidence text
    _actual_lc="${vals[3],,}"; _evid_lc="${vals[5],,}"
    _cause_label=''; _cause_css=''
    if [[ $_evid_lc == *'401'* || $_actual_lc == *'401'* ]]; then
      _cause_label='Permission denied (HTTP 401)'; _cause_css='color:#8B4513;font-weight:600'
    elif [[ $_evid_lc == *'missing'* || $_actual_lc == *'missing'* || $_actual_lc == *'not installed'* ]]; then
      _cause_label='Tool not installed'; _cause_css='color:#555;font-weight:600'
    elif [[ $_actual_lc == *'not configured'* || $_actual_lc == *'not set'* ]]; then
      _cause_label='Not configured'; _cause_css='color:#555;font-weight:600'
    elif [[ $_actual_lc == *'api'* && $_actual_lc == *'not'* ]]; then
      _cause_label='Not available via Management API'; _cause_css='color:#555;font-weight:600'
    else
      _cause_label='Evidence unavailable'; _cause_css='color:#555'
    fi
    printf '<tr class="row-NOTVERIFIED">'
    printf '<td><strong>%s</strong></td><td>%s</td><td>%s</td>' \
      "$(html_escape "${vals[0]}")" "$(html_escape "${vals[1]}")" "$(html_escape "${vals[2]}")"
    printf '<td><span style="%s">%s</span><br><small style="color:#666;font-family:monospace">%s</small></td>' \
      "$_cause_css" "$(html_escape "$_cause_label")" "$(html_escape "${vals[3]}")"
    printf '<td>%s<details style="margin-top:6px"><summary style="font-size:0.85em;cursor:pointer;color:#1b4a7a">evidence detail</summary><pre style="font-size:0.8em;margin:4px 0 0;white-space:pre-wrap">%s</pre></details></td>' \
      "$(html_escape "${vals[4]}")" "$(html_escape "${vals[5]}")"
    printf '</tr>\n'
  done < <(jq -sc '.[]|select(.status=="NOT VERIFIED")' "$RESULTS")
  printf '</table>\n'
fi
printf '</div></section>\n'

# ── All Checks: Category-grouped ─────────────────────────────────────────────
printf '<section id="categories" class="section">\n'
printf '<div class="section-header">All Health Checks by Category</div>\n'
printf '<div class="section-body">\n'

# Execution prerequisites (separate from 15 categories)
printf '<details class="cat-group" open>\n'
printf '<summary><div class="cat-summary-left"><span class="pill PASS">Preflight</span> Execution Prerequisites</div></summary>\n'
printf '<table><tr><th>Tool</th><th>Status</th><th>Result</th></tr>\n'
if ((HAVE_JQ)); then
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    mapfile -t fields < <(jq -r '[.id,.title,.status,.actual]|.[]|@base64' <<< "$line")
    vals=(); for f in "${fields[@]}"; do vals+=("$(printf '%s' "$f" | base64 -d)"); done
    css="${vals[2]// /}"
    printf '<tr class="row-%s"><td>%s</td><td><span class="pill %s">%s</span></td><td>%s</td></tr>\n' \
      "$css" "$(html_escape "${vals[1]}")" "$css" "$(html_escape "${vals[2]}")" "$(html_escape "${vals[3]}")"
  done < "$PREREQ_RESULTS"
fi
printf '</table></details>\n'

# 15 categories
for i in "${!CATS[@]}"; do
  cname="${CATS[$i]}"
  anchor="cat-$(echo "$cname" | tr ' &/' '-' | tr -d "'" | tr '[:upper:]' '[:lower:]')"
  worst='NOTVERIFIED'
  cat_crit=0; cat_warn=0; cat_pass=0; cat_rev=0; cat_nv=0
  if ((HAVE_JQ)); then
    worst=$(echo "$cat_status_json" | jq -r --arg c "$cname" '.[]|select(.category==$c)|.worst // "NOT VERIFIED"' 2>/dev/null | head -1)
    worst=${worst// /}; [[ -z $worst ]] && worst='NOTVERIFIED'
    cat_crit=$(jq -s --arg c "$cname" '[.[]|select(.category==$c and .status=="CRITICAL")]|length' "$RESULTS")
    cat_warn=$(jq  -s --arg c "$cname" '[.[]|select(.category==$c and .status=="WARNING")]|length' "$RESULTS")
    cat_pass=$(jq  -s --arg c "$cname" '[.[]|select(.category==$c and .status=="PASS")]|length'    "$RESULTS")
    cat_rev=$(jq   -s --arg c "$cname" '[.[]|select(.category==$c and .status=="REVIEW")]|length'  "$RESULTS")
    cat_nv=$(jq    -s --arg c "$cname" '[.[]|select(.category==$c and .status=="NOT VERIFIED")]|length' "$RESULTS")
  fi

  # Auto-open if has critical or warning
  open_attr=''; [[ $worst == 'CRITICAL' || $worst == 'WARNING' ]] && open_attr=' open'
  printf '<details id="%s" class="cat-group"%s>\n' "$anchor" "$open_attr"
  display_worst=${worst//NOTVERIFIED/NOT VERIFIED}
  printf '<summary><div class="cat-summary-left"><span class="pill %s">%s</span> %s</div>' \
    "$worst" "$display_worst" "$(html_escape "$cname")"
  printf '<div class="cat-counts">%s PASS &nbsp; %s WARNING &nbsp; %s CRITICAL &nbsp; %s REVIEW &nbsp; %s NOT VERIFIED</div>' \
    "$cat_pass" "$cat_warn" "$cat_crit" "$cat_rev" "$cat_nv"
  printf '</summary>\n'

  printf '<table><tr><th>ID</th><th>Check</th><th>Status</th><th>Actual</th><th>Baseline</th><th>Recommendation</th><th>Evidence</th></tr>\n'
  if ((HAVE_JQ)); then
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      mapfile -t fields < <(jq -r '[.id,.title,.status,.actual,.baseline,.recommendation,.evidence]|.[]|@base64' <<< "$line")
      vals=(); for f in "${fields[@]}"; do vals+=("$(printf '%s' "$f" | base64 -d)"); done
      css="${vals[2]// /}"
      printf '<tr class="row-%s"><td><strong>%s</strong></td><td>%s</td><td><span class="pill %s">%s</span></td><td>%s</td><td>%s</td><td>%s</td><td><details class="evidence"><summary>details</summary><pre>%s</pre></details></td></tr>\n' \
        "$css" \
        "$(html_escape "${vals[0]}")" "$(html_escape "${vals[1]}")" \
        "$css" "$(html_escape "${vals[2]}")" "$(html_escape "${vals[3]}")" \
        "$(html_escape "${vals[4]}")" "$(html_escape "${vals[5]}")" \
        "$(html_escape "${vals[6]}")"
    done < <(jq -sc --arg c "$cname" '.[]|select(.category==$c)' "$RESULTS")
  fi
  printf '</table></details>\n'
done
printf '</div></section>\n'

# ── Logs ──────────────────────────────────────────────────────────────────────
printf '<section id="logs" class="section">\n'
printf '<div class="section-header">Diagnostic Logs &amp; Evidence</div>\n'
printf '<div class="section-body">\n'

# Per-check evidence (one collapsible per result, like the original report)
printf '<h3 style="margin-bottom:10px;font-size:13px;color:#003a6e">Per-Check Evidence</h3>\n'
if ((HAVE_JQ)); then
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    mapfile -t fields < <(jq -r '[.id,.title,.status,.actual,.baseline,.evidence]|.[]|@base64' <<< "$line")
    vals=(); for f in "${fields[@]}"; do vals+=("$(printf '%s' "$f" | base64 -d)"); done
    css="${vals[2]// /}"
    printf '<details class="evidence"><summary><span class="pill %s" style="font-size:10px">%s</span> &nbsp;<strong>%s</strong> — %s</summary>\n' \
      "$css" "$(html_escape "${vals[2]}")" "$(html_escape "${vals[0]}")" "$(html_escape "${vals[1]}")"
    printf '<pre>Actual:   %s\nBaseline: %s\nEvidence: %s</pre></details>\n' \
      "$(html_escape "${vals[3]}")" "$(html_escape "${vals[4]}")" "$(html_escape "${vals[5]}")"
  done < "$RESULTS"
else
  printf '<p>Install jq to enable per-check evidence detail.</p>\n'
fi

printf '<hr style="margin:16px 0;border:none;border-top:1px solid #dee2e6">\n'
printf '<h3 style="margin-bottom:10px;font-size:13px;color:#003a6e">Execution Log</h3>\n'
printf '<details class="evidence" open><summary>All API calls and check results (%s entries)</summary><pre>' \
  "$(wc -l < "$EXEC" | tr -d ' ')"
while IFS= read -r l; do html_escape "$l"; printf '\n'; done < "$EXEC"
printf '</pre></details>\n'

printf '<h3 style="margin:16px 0 10px;font-size:13px;color:#003a6e">Errors Log</h3>\n'
printf '<details class="evidence" open><summary>Errors and failed API calls (%s entries)</summary><pre>' \
  "$(wc -l < "$ERRORS" | tr -d ' ')"
while IFS= read -r l; do html_escape "$l"; printf '\n'; done < "$ERRORS"
printf '</pre></details>\n'
printf '</div></section>\n'

# ── Footer ────────────────────────────────────────────────────────────────────
printf '<footer>\n'
printf '<strong>%s — %s | %s | Script v%s</strong><br>\n' \
  "$(html_escape "$CUSTOMER")" "$(html_escape "$CLUSTER")" "$STAMP" "$VERSION"
printf 'Data collected: cluster topology, node metrics (counts, %%, alarms), queue inventory, TLS certificate status, API endpoint responses.<br>\n'
printf 'Not collected: passwords, message bodies, user credentials, payloads, source/destination URIs from shovels.<br>\n'
printf 'Queue names and vhost names appear in this report and may reveal business domain — review before sharing.<br>\n'
printf 'READ-ONLY assessment: no packages installed, no SSH, no config changes made to the cluster.\n'
printf '</footer>\n'
printf '</div></body></html>\n'

} > "$HTML" || { echo 'Unable to write HTML report' >&2; exit 4; }

# ── Cleanup temp files ────────────────────────────────────────────────────────
rm -rf "$TMP" "$RESULTS" "$PREREQ_RESULTS" 2>/dev/null || :

# ── Package ZIP ───────────────────────────────────────────────────────────────
ARCHIVE=''
if ((NO_PACKAGE == 0)); then
  OUTDIR="$(cd "$(dirname "$DIR")" && pwd)"
  ZIPNAME="$OUTDIR/$RUNID.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "$DIR" && zip -q "$ZIPNAME" "$HTML_NAME" errors.log execution.log) 2>> "$ERRORS" \
      && ARCHIVE="$ZIPNAME"
  elif command -v jar >/dev/null 2>&1; then
    (cd "$DIR" && jar cf "$ZIPNAME" "$HTML_NAME" errors.log execution.log) 2>> "$ERRORS" \
      && ARCHIVE="$ZIPNAME"
  else
    err 'Neither zip nor jar available — report directory retained unpackaged.'
  fi
fi

# ── Terminal output ───────────────────────────────────────────────────────────
printf '\nReport complete.\n'
printf '  HTML:          %s\n' "$HTML"
printf '  Errors log:    %s\n' "$ERRORS"
printf '  Execution log: %s\n' "$EXEC"
[[ -n $ARCHIVE && -f $ARCHIVE ]] && printf '  ZIP:           %s\n' "$ARCHIVE"

printf '\n================================================================\n'
printf '  BEFORE SHARING THIS REPORT WITH BROADCOM SUPPORT\n'
printf '================================================================\n'
printf '  Review the ZIP contents for potentially sensitive information:\n'
printf '    - Queue names and vhost names (may reveal business domain)\n'
printf '    - Hostnames and API endpoint URLs\n'
printf '    - Cluster topology details\n'
printf '\n'
printf '  NOT collected:\n'
printf '    - Passwords or credentials\n'
printf '    - Message bodies or payloads\n'
printf '    - Shovel/federation source or destination URIs\n'
printf '    - Usernames (only counts are recorded)\n'
printf '\n'
printf '  Open the HTML report in a browser and verify before sharing.\n'
printf '  Share only with authorized Broadcom Support personnel.\n'
printf '================================================================\n\n'

# ── Exit code ─────────────────────────────────────────────────────────────────
if   ((CRIT > 0)); then exit 2
elif ((WARN > 0)); then exit 1
elif ((NV   > 0)); then exit 3
else exit 0; fi
