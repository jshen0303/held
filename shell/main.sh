# on user button press, call this script to create shell hooks
# everything remains same
# call ship on each command and on end instead of timed interval
# get rid of finding path dynamically


# Portable Coro core — source (do not exec)
# Works in zsh and bash. Quiet by default. No job-control spam.

# ----- config / state ---------------------------------------------------------
CORO_ACTIVE=false
CORO_INFLIGHT=false
CORO_FDS_OPEN=false
CORO_CAPTURE_OUTPUT=false
CORO_VERBOSE="${CORO_VERBOSE:-0}"  # 0 = quiet, 1 = chatty

# Get the plugin directory dynamically
if [ -z "${CORO_PLUGIN_DIR:-}" ]; then
  if [ -n "${HYPER_PLUGIN_DIR:-}" ]; then
    CORO_PLUGIN_DIR="$HYPER_PLUGIN_DIR"
  else
    # Try to find the plugin directory relative to this script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CORO_PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
  fi
fi
CORO_BACKEND_DIR="${CORO_BACKEND_DIR:-$CORO_PLUGIN_DIR/backend}"
CORO_LOG_DIR="${CORO_LOG_DIR:-$CORO_BACKEND_DIR/state}"
CORO_LOG_FILE="${CORO_LOG_FILE:-$CORO_LOG_DIR/dump.jsonl}"
CORO_PIDFILE="${CORO_PIDFILE:-$CORO_LOG_DIR/shipper.pid}"
CORO_ENV_FILE="${CORO_ENV_FILE:-$HOME/.coro/.env}"
mkdir -p "$CORO_LOG_DIR" >/dev/null 2>&1; umask 077

# SSH state
CORO_SSH_SESSION=false
CORO_SSH_HOST=""
CORO_SSH_USER=""
CORO_SSH_ENABLED=true
CORO_SSH_OUTPUT_FILE=""
CORO_SSH_OUTPUT_CAPTURE=false
: "${CORO_SSH_WRAP:=1}"   # 1=wrap ssh with script(1) to capture full TTY transcript

# Backend venv + shipper
CORO_VENV_PY="${CORO_VENV_PY:-/bin/sh}"
CORO_SHIPPER="${CORO_SHIPPER:-$CORO_BACKEND_DIR/shipper-http.sh}"


# Per-command state
CORO_CMD=""
CORO_CWD=""
CORO_TS_START=""
CORO_T0=""
CORO_STDOUT_FILE=""
CORO_STDERR_FILE=""

# ----- utils ------------------------------------------------------------------
coro_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
coro_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

coro_now_float() {
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s' "$EPOCHREALTIME";
  elif command -v python3 >/dev/null 2>&1; then python3 - <<'PY'
import time, sys; sys.stdout.write(f"{time.time():.6f}")
PY
  else printf '%s' "$(date +%s)"; fi
}

coro_ms_between() { awk -v a="$1" -v b="$2" 'BEGIN{printf("%.0f",(b-a)*1000);}'; }

coro_cmd_start_marker() { printf '\033]133;C\007'; }
coro_cmd_end_marker()   { printf '\033]133;D;exit=%d\007' "$1"; }
coro_cwd_marker()       { printf '\033]7;file://%s%s\007' "$HOSTNAME" "$PWD"; }

coro_bootstrap_backend() {
  local vdir="$CORO_BACKEND_DIR/.venv"
  if [ ! -x "$CORO_VENV_PY" ]; then
    command -v python3 >/dev/null 2>&1 || { echo "❌ python3 not found"; return 1; }
    [ "$CORO_VERBOSE" = "1" ] && echo "⏳ Creating Coro venv at $vdir"
    python3 -m venv "$vdir" >/dev/null 2>&1 || return 1
  fi
  if [ -f "$CORO_BACKEND_DIR/requirements.txt" ]; then
    local pip="$vdir/bin/pip"; [ -x "$pip" ] || pip="$vdir/Scripts/pip.exe"
    "$pip" install -r "$CORO_BACKEND_DIR/requirements.txt" >/dev/null 2>&1 || true
  fi
}

# ----- shipper: one-shot + daemon --------------------------------------------
coro_run_shipper() {
  # $1 = rotate flag: 0 (ship live file) or 1 (rotate+ship snapshot)
  local rotate="${1:-0}"
  local log="${CORO_LOG_DIR}/shipper.log"
  [ -x "$CORO_VENV_PY" ] || coro_bootstrap_backend
  
  # Load environment variables from .env file if it exists
  local team_id=""
  local supabase_url=""
  if [ -n "${CORO_ENV_FILE:-}" ] && [ -f "$CORO_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CORO_ENV_FILE"
    team_id="${CORO_TEAM_ID:-}"
    supabase_url="${SUPABASE_URL:-}"
  fi
  
  ( cd "$CORO_BACKEND_DIR" 2>/dev/null || cd "$CORO_PLUGIN_DIR/backend" 2>/dev/null || true
    env PYTHONUNBUFFERED=1 \
        CORO_PLUGIN_DIR="$CORO_PLUGIN_DIR" \
        CORO_BACKEND_DIR="$CORO_BACKEND_DIR" \
        CORO_LOG_DIR="$CORO_LOG_DIR" \
        CORO_LOG_FILE="$CORO_LOG_FILE" \
        CORO_ENV_FILE="$CORO_ENV_FILE" \
        CORO_TEAM_ID="$team_id" \
        SUPABASE_URL="$supabase_url" \
        SHIP_ROTATE="$rotate" \
        "$CORO_VENV_PY" "$CORO_SHIPPER"
  ) >>"$log" 2>&1
}

coro_start_shipper_daemon() {
  mkdir -p "$CORO_LOG_DIR" >/dev/null 2>&1
  local pf="${CORO_PIDFILE:-$CORO_LOG_DIR/shipper.pid}"
  local log="${CORO_LOG_DIR}/shipper.log"

  if [ -f "$pf" ]; then
    local pid; pid="$(cat "$pf" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      [ "${CORO_VERBOSE:-0}" = "1" ] && echo "⛴️  Shipper already running (pid $pid)."
      return 0
    fi
    rm -f "$pf" 2>/dev/null || true
  fi

  # immediate quiet ship of live file
  if ! coro_run_shipper 0; then
    echo "$(date -u +"%F %T") ship-now live failed (see above for stderr)" >>"$log"
  fi

  # daemon body (rotate+ship every interval)
  local daemon='
    umask 077
    pf="$1"; interval="$2"
    echo $$ > "$pf"
    trap "rm -f \"$pf\"; exit 0" EXIT HUP INT TERM
    while :; do
      '"$(typeset -f coro_run_shipper)"'
      coro_run_shipper 1
      sleep "$interval"
    done
  '

  if command -v setsid >/dev/null 2>&1; then
    setsid -f sh -c "$daemon" sh "$pf" "${CORO_SHIP_INTERVAL:-120}" >/dev/null 2>&1 || true
  else
    if [ -n "${ZSH_VERSION:-}" ]; then
      local had_monitor=0
      if [[ -o monitor ]]; then had_monitor=1; unsetopt monitor; fi
      ( nohup sh -c "$daemon" sh "$pf" "${CORO_SHIP_INTERVAL:-120}" >/dev/null 2>&1 & ) 2>/dev/null
      [ "$had_monitor" -eq 1 ] && setopt monitor
    else
      local had_m=0; case $- in *m*) had_m=1;; esac
      set +m
      ( nohup sh -c "$daemon" sh "$pf" "${CORO_SHIP_INTERVAL:-120}" >/dev/null 2>&1 & ) 2>/dev/null
      [ "$had_m" -eq 1 ] && set -m
    fi
  fi
}

coro_stop_shipper_daemon() {
  local pf="${CORO_PIDFILE:-$CORO_LOG_DIR/shipper.pid}"
  if [ -f "$pf" ]; then
    local pid; pid="$(cat "$pf" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" >/dev/null 2>&1 || true
      for i in 1 2 3; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pf" 2>/dev/null || true
  fi
}

# ----- interactivity heuristic ------------------------------------------------
coro_is_interactive_cmd() {
  set -- $1
  local cmd0="${1:-}"
  case "$cmd0" in
    vim|nvim|less|more|man|tmux|top|htop|watch|nano|fzf|tig) return 0 ;;
    ssh|sftp|ftp|telnet) return 0 ;;
    python|ipython|node|irb|R) return 0 ;;
    kubectl) [ "${2:-}" = "exec" ] || [ "${2:-}" = "attach" ] && return 0 ;;
    docker)  [ "${2:-}" = "exec" ] && return 0 ;;
  esac
  case " $* " in *" -it "*|*" -ti "*) return 0 ;; esac
  return 1
}

# ----- SSH transcript support (wrapper) --------------------------------------
coro_ssh_session_end() {
  if [ "$CORO_SSH_SESSION" = "true" ] && [ -n "$CORO_SSH_HOST" ]; then
    local ts_end j_host j_user ssh_output="" j_b64=""
    ts_end="$(coro_now_iso)"
    if [ -n "$CORO_SSH_OUTPUT_FILE" ] && [ -f "$CORO_SSH_OUTPUT_FILE" ]; then
      ssh_output="$(cat "$CORO_SSH_OUTPUT_FILE" 2>/dev/null || true)"
      rm -f "$CORO_SSH_OUTPUT_FILE" 2>/dev/null
    fi
    j_host="$(coro_json_escape "$CORO_SSH_HOST")"
    j_user="$(coro_json_escape "$CORO_SSH_USER")"
    [ -n "$ssh_output" ] && j_b64="$(printf '%s' "$ssh_output" | base64 | tr -d '\n')"
    printf '{"ts_end":"%s","event":"ssh_session_end","host":"%s","user":"%s","local_user":"%s","local_host":"%s","session_output_b64":"%s"}\n' \
      "$ts_end" "$j_host" "$j_user" "$USER" "$HOSTNAME" "$j_b64" >> "$CORO_LOG_FILE"
    [ "$CORO_VERBOSE" = "1" ] && echo "🔌 SSH session logging ended for $CORO_SSH_USER@$CORO_SSH_HOST"
    CORO_SSH_SESSION=false
    CORO_SSH_HOST=""; CORO_SSH_USER=""
    CORO_SSH_OUTPUT_FILE=""; CORO_SSH_OUTPUT_CAPTURE=false
  fi
}

coro_define_ssh_wrapper() {
  # If user has a custom ssh function, don't override it; remove alias so our function wins
  case "$(type -t ssh 2>/dev/null)" in alias) unalias ssh 2>/dev/null || true;; esac
  case "$(type -t ssh 2>/dev/null)" in function) return 0;; esac

  ssh() {
    # If inactive or disabled, call real ssh
    if [ "${CORO_SSH_WRAP:-1}" != "1" ] || [ "${CORO_ACTIVE:-false}" != "true" ] || [ "${CORO_SSH_ENABLED:-true}" != "true" ]; then
      command ssh "$@"; return $?
    fi

    # Grab first non-flag arg as host/user@host
    local _user="" _host="" _a
    for _a in "$@"; do
      case "$_a" in
        -*) ;;                  # skip flags
        *@*) _user="${_a%@*}"; _host="${_a#*@}"; break ;;
        *)   _host="$_a"; _user="${USER}"; break ;;
      esac
    done

    CORO_SSH_SESSION=true
    CORO_SSH_HOST="${_host}"
    CORO_SSH_USER="${_user}"
    CORO_SSH_OUTPUT_FILE="$(mktemp -t coro.ssh.XXXXXX)"
    CORO_SSH_OUTPUT_CAPTURE=true

    local _ts_start="$(coro_now_iso)" _t0="$(coro_now_float)"
    local _j_host="$(coro_json_escape "$_host")"
    local _j_user="$(coro_json_escape "$_user")"
    local _j_cmd="$(coro_json_escape "ssh $*")"
    printf '{"ts_start":"%s","event":"ssh_session_start","host":"%s","user":"%s","cmd":"%s","local_user":"%s","local_host":"%s"}\n' \
      "$_ts_start" "$_j_host" "$_j_user" "$_j_cmd" "$USER" "$HOSTNAME" >> "$CORO_LOG_FILE"

    # Run ssh under script(1). Prefer util-linux form (-c) when available; else BSD form.
    local _exit=0
    if command -v script >/dev/null 2>&1; then
      if script -q -c "true" /dev/null >/dev/null 2>&1; then
        # Linux util-linux: script -q -f -c "ssh args" file
        script -q -f -c "$(printf 'ssh %s' "$(printf '%q ' "$@")")" "$CORO_SSH_OUTPUT_FILE" || _exit=$?
      else
        # BSD/macOS: script -q file command args...
        script -q "$CORO_SSH_OUTPUT_FILE" command ssh "$@" || _exit=$?
      fi
    else
      # No script(1): run ssh normally (no transcript)
      command ssh "$@" || _exit=$?
    fi

    coro_ssh_session_end

    # Envelope for the ssh command itself (no stdout/stderr here)
    local _ts_end="$(coro_now_iso)" _t1="$(coro_now_float)"
    local _dur="$(coro_ms_between "$_t0" "$_t1" 2>/dev/null || echo 0)"
    local _j_cwd="$(coro_json_escape "$PWD")"
    printf '{"ts_start":"%s","ts_end":"%s","duration_ms":%s,"cwd":"%s","cmd":"%s","exit":%s,"stdout":"","stderr":"","ssh_host":"%s","ssh_user":"%s"}\n' \
      "$_ts_start" "$_ts_end" "$_dur" "$_j_cwd" "$_j_cmd" "$_exit" "$_j_host" "$_j_user" >> "$CORO_LOG_FILE"

    return $_exit
  }
}

# ----- preexec / precmd -------------------------------------------------------
coro_preexec() {
  case "$1" in coro\ *) CORO_INFLIGHT=false; return ;; esac
  [ "$CORO_ACTIVE" = "true" ] || { CORO_INFLIGHT=false; return; }

  # If ssh is wrapped, let the wrapper handle logging & transcript entirely
  if [ "${CORO_SSH_WRAP:-1}" = "1" ] && [ "${1#ssh }" != "$1" ]; then
    CORO_INFLIGHT=false
    return
  fi

  CORO_INFLIGHT=true
  CORO_CMD="$1"; CORO_CWD="$PWD"
  CORO_TS_START="$(coro_now_iso)"; CORO_T0="$(coro_now_float)"

  coro_cmd_start_marker; coro_cwd_marker

  CORO_CAPTURE_OUTPUT=false
  if [ -t 1 ] && ! coro_is_interactive_cmd "$CORO_CMD"; then
    CORO_CAPTURE_OUTPUT=true
    CORO_STDOUT_FILE="$(mktemp -t coro.stdout.XXXXXX)"
    CORO_STDERR_FILE="$(mktemp -t coro.stderr.XXXXXX)"
    exec 3>&1 4>&2
    exec > >(tee -a "$CORO_STDOUT_FILE")
    exec 2> >(tee -a "$CORO_STDERR_FILE" >&2)
    CORO_FDS_OPEN=true
  fi
}

coro_precmd() {
  local exit_status="${1:-$?}"
  [ "$CORO_ACTIVE" = "true" ] && [ "$CORO_INFLIGHT" = "true" ] || return 0

  local ts_end t1 duration_ms stdout_text="" stderr_text=""
  ts_end="$(coro_now_iso)"; t1="$(coro_now_float)"
  duration_ms="$(coro_ms_between "$CORO_T0" "$t1" 2>/dev/null || echo 0)"

  if [ "$CORO_CAPTURE_OUTPUT" = "true" ] && [ "$CORO_FDS_OPEN" = "true" ]; then
    exec 1>&3 2>&4
    exec 3>&- 4>&-
    CORO_FDS_OPEN=false
    sleep 0.03
    [ -f "$CORO_STDOUT_FILE" ] && stdout_text="$(cat "$CORO_STDOUT_FILE")"
    [ -f "$CORO_STDERR_FILE" ] && stderr_text="$(cat "$CORO_STDERR_FILE")"
    rm -f "$CORO_STDOUT_FILE" "$CORO_STDERR_FILE" 2>/dev/null
  fi

  coro_cmd_end_marker "$exit_status"; coro_cwd_marker

  stdout_text="${stdout_text//AKIA[0-9A-Z]*/[REDACTED_AWS_KEY]}"
  stderr_text="${stderr_text//AKIA[0-9A-Z]*/[REDACTED_AWS_KEY]}"

  local j_cmd j_cwd j_out j_err
  j_cmd="$(coro_json_escape "$CORO_CMD")"
  j_cwd="$(coro_json_escape "$CORO_CWD")"
  j_out="$(coro_json_escape "$stdout_text")"
  j_err="$(coro_json_escape "$stderr_text")"

  printf '{"ts_start":"%s","ts_end":"%s","duration_ms":%s,"cwd":"%s","cmd":"%s","exit":%s,"stdout":"%s","stderr":"%s"}\n' \
    "$CORO_TS_START" "$ts_end" "$duration_ms" "$j_cwd" "$j_cmd" "$exit_status" "$j_out" "$j_err" >> "$CORO_LOG_FILE"

  CORO_INFLIGHT=false; CORO_CAPTURE_OUTPUT=false
  CORO_CMD=""; CORO_CWD=""; CORO_TS_START=""; CORO_STDOUT_FILE=""; CORO_STDERR_FILE=""
}

# ----- control ---------------------------------------------------------------
coro() {
  case "$1" in
    start)
      if [ "$CORO_ACTIVE" = "true" ]; then [ "$CORO_VERBOSE" = "1" ] && echo "ℹ️  Coro already running → $CORO_LOG_FILE"; return 0; fi
      CORO_ACTIVE=true
      echo "🟢 Coro logging ACTIVE"
      [ "$CORO_SSH_ENABLED" = "true" ] && echo "🔗 SSH session logging ENABLED" || echo "🔗 SSH session logging DISABLED"
      coro_bootstrap_backend
      coro_start_shipper_daemon
      [ "$CORO_VERBOSE" = "1" ] && echo "⛴️  Shipper loop detached."
      ;;
    stop)
      if [ "$CORO_ACTIVE" != "true" ]; then echo "ℹ️  No Coro processes are running"; return 1; fi
      if [ "$CORO_FDS_OPEN" = "true" ]; then exec 1>&3 2>&4; exec 3>&- 4>&-; CORO_FDS_OPEN=false; fi
      CORO_ACTIVE=false; CORO_INFLIGHT=false
      echo "🔴 Coro logging STOPPED"
      coro_stop_shipper_daemon
      # Final ship (live then rotate)
      # Load environment variables from .env file if it exists
      local team_id=""
      local supabase_url=""
      if [ -n "${CORO_ENV_FILE:-}" ] && [ -f "$CORO_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CORO_ENV_FILE"
        team_id="${CORO_TEAM_ID:-}"
        supabase_url="${SUPABASE_URL:-}"
      fi
      CORO_ENV_FILE="$CORO_ENV_FILE" CORO_LOG_DIR="$CORO_LOG_DIR" CORO_LOG_FILE="$CORO_LOG_FILE" CORO_TEAM_ID="$team_id" SUPABASE_URL="$supabase_url" SHIP_ROTATE=0 "$CORO_VENV_PY" "$CORO_SHIPPER" >/dev/null 2>&1
      CORO_ENV_FILE="$CORO_ENV_FILE" CORO_LOG_DIR="$CORO_LOG_DIR" CORO_LOG_FILE="$CORO_LOG_FILE" CORO_TEAM_ID="$team_id" SUPABASE_URL="$supabase_url" SHIP_ROTATE=1 "$CORO_VENV_PY" "$CORO_SHIPPER" >/dev/null 2>&1
      ;;
    ship-now)
      # coro ship-now [0|1] -> live or rotate+ship
      local rotate="${2:-0}"
      if [ "$rotate" != "0" ] && [ "$rotate" != "1" ]; then echo "Usage: coro ship-now [0|1]"; return 2; fi
      if coro_run_shipper "$rotate"; then
        [ "${CORO_VERBOSE:-0}" = "1" ] && echo "⛴️  Ship complete (rotate=$rotate)."
      else
        echo "❌ shipper failed. See $CORO_LOG_DIR/shipper.log"; return 1
      fi
      ;;
    ssh-enable)  CORO_SSH_ENABLED=true;  echo "🔗 SSH session logging ENABLED" ;;
    ssh-disable) CORO_SSH_ENABLED=false; echo "🔗 SSH session logging DISABLED" ;;
    status)
      if [ "$CORO_ACTIVE" = "true" ]; then
        echo "🟢 ACTIVE → $CORO_LOG_FILE"
        if [ "$CORO_SSH_ENABLED" = "true" ]; then
          [ "$CORO_SSH_SESSION" = "true" ] && echo "🔗 SSH session: $CORO_SSH_USER@$CORO_SSH_HOST" || echo "🔗 SSH session logging: READY"
        else
          echo "🔗 SSH session logging: DISABLED"
        fi
      else
        echo "🔴 INACTIVE"
      fi
      ;;
    ssh-status)
      if [ "$CORO_SSH_ENABLED" = "true" ]; then
        if [ "$CORO_SSH_SESSION" = "true" ]; then
          echo "🔗 Active SSH session: $CORO_SSH_USER@$CORO_SSH_HOST"
          [ "$CORO_SSH_OUTPUT_CAPTURE" = "true" ] && echo "📝 Output capture: ACTIVE → $CORO_SSH_OUTPUT_FILE" || echo "📝 Output capture: INACTIVE"
        else
          echo "🔗 SSH session logging: READY"
        fi
      else
        echo "🔗 SSH session logging: DISABLED"
      fi
      ;;
    ssh-show-output)
      if [ "$CORO_SSH_SESSION" = "true" ] && [ -n "$CORO_SSH_OUTPUT_FILE" ] && [ -f "$CORO_SSH_OUTPUT_FILE" ]; then
        echo "📝 SSH session output for $CORO_SSH_USER@$CORO_SSH_HOST:"
        echo "─────────────────────────────────────────────────────────────"
        cat "$CORO_SSH_OUTPUT_FILE"
        echo "─────────────────────────────────────────────────────────────"
      else
        echo "❌ No active SSH session or output file not found"
      fi
      ;;
    *)
      echo "Usage: coro {start|stop|ship-now|ssh-enable|ssh-disable|status|ssh-status|ssh-show-output}"
      ;;
  esac
}

# ----- session id + cleanup ---------------------------------------------------
CORO_STATE_DIR="${CORO_STATE_DIR:-$CORO_BACKEND_DIR/state}"
CORO_CHAT_DIR="${CORO_CHAT_DIR:-$CORO_STATE_DIR/chat_histories}"
mkdir -p "$CORO_CHAT_DIR" 2>/dev/null
export CORO_TTY="${CORO_TTY:-$( (tty) 2>/dev/null )}"

if [ -n "${CORO_CHAT_SESSION:-}" ]; then
  export CORO_SESSION_ID="$CORO_CHAT_SESSION"
else
  if command -v uuidgen >/dev/null 2>&1; then CORO_SESSION_ID="sh-$(uuidgen | tr A-F a-f | tr -d '-')"
  else
    seed="$(date +%s)-$RANDOM-$$-${PPID:-0}-${CORO_TTY}"
    h="$(printf '%s' "$seed" | openssl sha1 2>/dev/null | awk '{print $2}')"
    [ -z "$h" ] && h="${RANDOM}$$${PPID:-0}"
    CORO_SESSION_ID="sh-${h:0:12}"
  fi
  export CORO_SESSION_ID
fi

_coro_cleanup_chat_history() {
  local sid="${CORO_CHAT_SESSION:-$CORO_SESSION_ID}"
  local safe="${sid//[^A-Za-z0-9_.-]/-}"; safe="${safe:0:80}"
  local d="${CORO_CHAT_DIR:-$CORO_BACKEND_DIR/state/chat_histories}"
  [ -f "$d/$safe.json" ] && rm -f -- "$d/$safe.json"
  [ -f "$d/${safe}-ai.json" ] && rm -f -- "$d/${safe}-ai.json"
  [ -f "$d/${safe}-search.json" ] && rm -f -- "$d/${safe}-search.json"
}
trap _coro_cleanup_chat_history EXIT HUP

# ----- hook installer ---------------------------------------------------------
coro_install_hooks() {
  case "$1" in
    zsh)
      autoload -Uz add-zsh-hook 2>/dev/null
      add-zsh-hook -d preexec coro_preexec  >/dev/null 2>&1 || true
      add-zsh-hook -d precmd  coro_precmd   >/dev/null 2>&1 || true
      add-zsh-hook preexec coro_preexec
      add-zsh-hook precmd  coro_precmd
      coro_define_ssh_wrapper
      ;;
    bash)
      coro_bash_preexec() { [ -n "${CORO_IN_PROMPT:-}" ] && return 0; coro_preexec "$BASH_COMMAND"; }
      trap 'coro_bash_preexec' DEBUG
      coro_precmd_wrapper() { local _es=$?; CORO_IN_PROMPT=1; coro_precmd "$_es"; unset CORO_IN_PROMPT; }
      if [ -n "${PROMPT_COMMAND:-}" ]; then
        case "$PROMPT_COMMAND" in *coro_precmd_wrapper*) : ;; *) PROMPT_COMMAND="coro_precmd_wrapper; $PROMPT_COMMAND" ;; esac
      else
        PROMPT_COMMAND="coro_precmd_wrapper"
      fi
      coro_define_ssh_wrapper
      ;;
  esac
}
