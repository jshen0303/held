# on user button press, call this script to create shell hooks
# everything remains same
# call ship on each command and on end instead of timed interval
# get rid of finding path dynamically


# Portable HELD core — source (do not exec)
# Works in zsh and bash. Quiet by default. No job-control spam.

# ----- config / state ---------------------------------------------------------
HELD_ACTIVE=false
HELD_INFLIGHT=false
HELD_FDS_OPEN=false
HELD_CAPTURE_OUTPUT=false
HELD_VERBOSE="${HELD_VERBOSE:-0}"  # 0 = quiet, 1 = chatty

# Get the plugin directory dynamically
if [ -z "${HELD_PLUGIN_DIR:-}" ]; then
  if [ -n "${HYPER_PLUGIN_DIR:-}" ]; then
    HELD_PLUGIN_DIR="$HYPER_PLUGIN_DIR"
  else
    # Try to find the plugin directory relative to this script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HELD_PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
  fi
fi
HELD_BACKEND_DIR="${HELD_BACKEND_DIR:-$HELD_PLUGIN_DIR/backend}"
HELD_LOG_DIR="${HELD_LOG_DIR:-$HELD_BACKEND_DIR/state}"
HELD_LOG_FILE="${HELD_LOG_FILE:-$HELD_LOG_DIR/dump.jsonl}"
HELD_PIDFILE="${HELD_PIDFILE:-$HELD_LOG_DIR/shipper.pid}"
HELD_ENV_FILE="${HELD_ENV_FILE:-$HOME/.HELD/.env}"
mkdir -p "$HELD_LOG_DIR" >/dev/null 2>&1; umask 077

# SSH state
HELD_SSH_SESSION=false
HELD_SSH_HOST=""
HELD_SSH_USER=""
HELD_SSH_ENABLED=true
HELD_SSH_OUTPUT_FILE=""
HELD_SSH_OUTPUT_CAPTURE=false
: "${HELD_SSH_WRAP:=1}"   # 1=wrap ssh with script(1) to capture full TTY transcript

# Backend venv + shipper
HELD_VENV_PY="${HELD_VENV_PY:-/bin/sh}"
HELD_SHIPPER="${HELD_SHIPPER:-$HELD_BACKEND_DIR/shipper-http.sh}"


# Per-command state
HELD_CMD=""
HELD_CWD=""
HELD_TS_START=""
HELD_T0=""
HELD_STDOUT_FILE=""
HELD_STDERR_FILE=""

# ----- utils ------------------------------------------------------------------
HELD_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
HELD_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

HELD_now_float() {
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s' "$EPOCHREALTIME";
  elif command -v python3 >/dev/null 2>&1; then python3 - <<'PY'
import time, sys; sys.stdout.write(f"{time.time():.6f}")
PY
  else printf '%s' "$(date +%s)"; fi
}

HELD_ms_between() { awk -v a="$1" -v b="$2" 'BEGIN{printf("%.0f",(b-a)*1000);}'; }

HELD_cmd_start_marker() { printf '\033]133;C\007'; }
HELD_cmd_end_marker()   { printf '\033]133;D;exit=%d\007' "$1"; }
HELD_cwd_marker()       { printf '\033]7;file://%s%s\007' "$HOSTNAME" "$PWD"; }

HELD_bootstrap_backend() {
  local vdir="$HELD_BACKEND_DIR/.venv"
  if [ ! -x "$HELD_VENV_PY" ]; then
    command -v python3 >/dev/null 2>&1 || { echo "❌ python3 not found"; return 1; }
    [ "$HELD_VERBOSE" = "1" ] && echo "⏳ Creating HELD venv at $vdir"
    python3 -m venv "$vdir" >/dev/null 2>&1 || return 1
  fi
  if [ -f "$HELD_BACKEND_DIR/requirements.txt" ]; then
    local pip="$vdir/bin/pip"; [ -x "$pip" ] || pip="$vdir/Scripts/pip.exe"
    "$pip" install -r "$HELD_BACKEND_DIR/requirements.txt" >/dev/null 2>&1 || true
  fi
}

# ----- shipper: one-shot + daemon --------------------------------------------
HELD_run_shipper() {
  # $1 = rotate flag: 0 (ship live file) or 1 (rotate+ship snapshot)
  local rotate="${1:-0}"
  local log="${HELD_LOG_DIR}/shipper.log"
  [ -x "$HELD_VENV_PY" ] || HELD_bootstrap_backend
  
  # Load environment variables from .env file if it exists
  local team_id=""
  local supabase_url=""
  if [ -n "${HELD_ENV_FILE:-}" ] && [ -f "$HELD_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$HELD_ENV_FILE"
    team_id="${HELD_TEAM_ID:-}"
    supabase_url="${SUPABASE_URL:-}"
  fi
  
  ( cd "$HELD_BACKEND_DIR" 2>/dev/null || cd "$HELD_PLUGIN_DIR/backend" 2>/dev/null || true
    env PYTHONUNBUFFERED=1 \
        HELD_PLUGIN_DIR="$HELD_PLUGIN_DIR" \
        HELD_BACKEND_DIR="$HELD_BACKEND_DIR" \
        HELD_LOG_DIR="$HELD_LOG_DIR" \
        HELD_LOG_FILE="$HELD_LOG_FILE" \
        HELD_ENV_FILE="$HELD_ENV_FILE" \
        HELD_TEAM_ID="$team_id" \
        SUPABASE_URL="$supabase_url" \
        SHIP_ROTATE="$rotate" \
        "$HELD_VENV_PY" "$HELD_SHIPPER"
  ) >>"$log" 2>&1
}

HELD_start_shipper_daemon() {
  mkdir -p "$HELD_LOG_DIR" >/dev/null 2>&1
  local pf="${HELD_PIDFILE:-$HELD_LOG_DIR/shipper.pid}"
  local log="${HELD_LOG_DIR}/shipper.log"

  if [ -f "$pf" ]; then
    local pid; pid="$(cat "$pf" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      [ "${HELD_VERBOSE:-0}" = "1" ] && echo "⛴️  Shipper already running (pid $pid)."
      return 0
    fi
    rm -f "$pf" 2>/dev/null || true
  fi

  # immediate quiet ship of live file
  if ! HELD_run_shipper 0; then
    echo "$(date -u +"%F %T") ship-now live failed (see above for stderr)" >>"$log"
  fi

  # daemon body (rotate+ship every interval)
  local daemon='
    umask 077
    pf="$1"; interval="$2"
    echo $$ > "$pf"
    trap "rm -f \"$pf\"; exit 0" EXIT HUP INT TERM
    while :; do
      '"$(typeset -f HELD_run_shipper)"'
      HELD_run_shipper 1
      sleep "$interval"
    done
  '

  if command -v setsid >/dev/null 2>&1; then
    setsid -f sh -c "$daemon" sh "$pf" "${HELD_SHIP_INTERVAL:-120}" >/dev/null 2>&1 || true
  else
    if [ -n "${ZSH_VERSION:-}" ]; then
      local had_monitor=0
      if [[ -o monitor ]]; then had_monitor=1; unsetopt monitor; fi
      ( nohup sh -c "$daemon" sh "$pf" "${HELD_SHIP_INTERVAL:-120}" >/dev/null 2>&1 & ) 2>/dev/null
      [ "$had_monitor" -eq 1 ] && setopt monitor
    else
      local had_m=0; case $- in *m*) had_m=1;; esac
      set +m
      ( nohup sh -c "$daemon" sh "$pf" "${HELD_SHIP_INTERVAL:-120}" >/dev/null 2>&1 & ) 2>/dev/null
      [ "$had_m" -eq 1 ] && set -m
    fi
  fi
}

HELD_stop_shipper_daemon() {
  local pf="${HELD_PIDFILE:-$HELD_LOG_DIR/shipper.pid}"
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
HELD_is_interactive_cmd() {
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
HELD_ssh_session_end() {
  if [ "$HELD_SSH_SESSION" = "true" ] && [ -n "$HELD_SSH_HOST" ]; then
    local ts_end j_host j_user ssh_output="" j_b64=""
    ts_end="$(HELD_now_iso)"
    if [ -n "$HELD_SSH_OUTPUT_FILE" ] && [ -f "$HELD_SSH_OUTPUT_FILE" ]; then
      ssh_output="$(cat "$HELD_SSH_OUTPUT_FILE" 2>/dev/null || true)"
      rm -f "$HELD_SSH_OUTPUT_FILE" 2>/dev/null
    fi
    j_host="$(HELD_json_escape "$HELD_SSH_HOST")"
    j_user="$(HELD_json_escape "$HELD_SSH_USER")"
    [ -n "$ssh_output" ] && j_b64="$(printf '%s' "$ssh_output" | base64 | tr -d '\n')"
    printf '{"ts_end":"%s","event":"ssh_session_end","host":"%s","user":"%s","local_user":"%s","local_host":"%s","session_output_b64":"%s"}\n' \
      "$ts_end" "$j_host" "$j_user" "$USER" "$HOSTNAME" "$j_b64" >> "$HELD_LOG_FILE"
    [ "$HELD_VERBOSE" = "1" ] && echo "🔌 SSH session logging ended for $HELD_SSH_USER@$HELD_SSH_HOST"
    HELD_SSH_SESSION=false
    HELD_SSH_HOST=""; HELD_SSH_USER=""
    HELD_SSH_OUTPUT_FILE=""; HELD_SSH_OUTPUT_CAPTURE=false
  fi
}

HELD_define_ssh_wrapper() {
  # If user has a custom ssh function, don't override it; remove alias so our function wins
  case "$(type -t ssh 2>/dev/null)" in alias) unalias ssh 2>/dev/null || true;; esac
  case "$(type -t ssh 2>/dev/null)" in function) return 0;; esac

  ssh() {
    # If inactive or disabled, call real ssh
    if [ "${HELD_SSH_WRAP:-1}" != "1" ] || [ "${HELD_ACTIVE:-false}" != "true" ] || [ "${HELD_SSH_ENABLED:-true}" != "true" ]; then
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

    HELD_SSH_SESSION=true
    HELD_SSH_HOST="${_host}"
    HELD_SSH_USER="${_user}"
    HELD_SSH_OUTPUT_FILE="$(mktemp -t HELD.ssh.XXXXXX)"
    HELD_SSH_OUTPUT_CAPTURE=true

    local _ts_start="$(HELD_now_iso)" _t0="$(HELD_now_float)"
    local _j_host="$(HELD_json_escape "$_host")"
    local _j_user="$(HELD_json_escape "$_user")"
    local _j_cmd="$(HELD_json_escape "ssh $*")"
    printf '{"ts_start":"%s","event":"ssh_session_start","host":"%s","user":"%s","cmd":"%s","local_user":"%s","local_host":"%s"}\n' \
      "$_ts_start" "$_j_host" "$_j_user" "$_j_cmd" "$USER" "$HOSTNAME" >> "$HELD_LOG_FILE"

    # Run ssh under script(1). Prefer util-linux form (-c) when available; else BSD form.
    local _exit=0
    if command -v script >/dev/null 2>&1; then
      if script -q -c "true" /dev/null >/dev/null 2>&1; then
        # Linux util-linux: script -q -f -c "ssh args" file
        script -q -f -c "$(printf 'ssh %s' "$(printf '%q ' "$@")")" "$HELD_SSH_OUTPUT_FILE" || _exit=$?
      else
        # BSD/macOS: script -q file command args...
        script -q "$HELD_SSH_OUTPUT_FILE" command ssh "$@" || _exit=$?
      fi
    else
      # No script(1): run ssh normally (no transcript)
      command ssh "$@" || _exit=$?
    fi

    HELD_ssh_session_end

    # Envelope for the ssh command itself (no stdout/stderr here)
    local _ts_end="$(HELD_now_iso)" _t1="$(HELD_now_float)"
    local _dur="$(HELD_ms_between "$_t0" "$_t1" 2>/dev/null || echo 0)"
    local _j_cwd="$(HELD_json_escape "$PWD")"
    printf '{"ts_start":"%s","ts_end":"%s","duration_ms":%s,"cwd":"%s","cmd":"%s","exit":%s,"stdout":"","stderr":"","ssh_host":"%s","ssh_user":"%s"}\n' \
      "$_ts_start" "$_ts_end" "$_dur" "$_j_cwd" "$_j_cmd" "$_exit" "$_j_host" "$_j_user" >> "$HELD_LOG_FILE"

    return $_exit
  }
}

# ----- preexec / precmd -------------------------------------------------------
HELD_preexec() {
  case "$1" in HELD\ *) HELD_INFLIGHT=false; return ;; esac
  [ "$HELD_ACTIVE" = "true" ] || { HELD_INFLIGHT=false; return; }

  # If ssh is wrapped, let the wrapper handle logging & transcript entirely
  if [ "${HELD_SSH_WRAP:-1}" = "1" ] && [ "${1#ssh }" != "$1" ]; then
    HELD_INFLIGHT=false
    return
  fi

  HELD_INFLIGHT=true
  HELD_CMD="$1"; HELD_CWD="$PWD"
  HELD_TS_START="$(HELD_now_iso)"; HELD_T0="$(HELD_now_float)"

  HELD_cmd_start_marker; HELD_cwd_marker

  HELD_CAPTURE_OUTPUT=false
  if [ -t 1 ] && ! HELD_is_interactive_cmd "$HELD_CMD"; then
    HELD_CAPTURE_OUTPUT=true
    HELD_STDOUT_FILE="$(mktemp -t HELD.stdout.XXXXXX)"
    HELD_STDERR_FILE="$(mktemp -t HELD.stderr.XXXXXX)"
    exec 3>&1 4>&2
    exec > >(tee -a "$HELD_STDOUT_FILE")
    exec 2> >(tee -a "$HELD_STDERR_FILE" >&2)
    HELD_FDS_OPEN=true
  fi
}

HELD_precmd() {
  local exit_status="${1:-$?}"
  [ "$HELD_ACTIVE" = "true" ] && [ "$HELD_INFLIGHT" = "true" ] || return 0

  local ts_end t1 duration_ms stdout_text="" stderr_text=""
  ts_end="$(HELD_now_iso)"; t1="$(HELD_now_float)"
  duration_ms="$(HELD_ms_between "$HELD_T0" "$t1" 2>/dev/null || echo 0)"

  if [ "$HELD_CAPTURE_OUTPUT" = "true" ] && [ "$HELD_FDS_OPEN" = "true" ]; then
    exec 1>&3 2>&4
    exec 3>&- 4>&-
    HELD_FDS_OPEN=false
    sleep 0.03
    [ -f "$HELD_STDOUT_FILE" ] && stdout_text="$(cat "$HELD_STDOUT_FILE")"
    [ -f "$HELD_STDERR_FILE" ] && stderr_text="$(cat "$HELD_STDERR_FILE")"
    rm -f "$HELD_STDOUT_FILE" "$HELD_STDERR_FILE" 2>/dev/null
  fi

  HELD_cmd_end_marker "$exit_status"; HELD_cwd_marker

  stdout_text="${stdout_text//AKIA[0-9A-Z]*/[REDACTED_AWS_KEY]}"
  stderr_text="${stderr_text//AKIA[0-9A-Z]*/[REDACTED_AWS_KEY]}"

  local j_cmd j_cwd j_out j_err
  j_cmd="$(HELD_json_escape "$HELD_CMD")"
  j_cwd="$(HELD_json_escape "$HELD_CWD")"
  j_out="$(HELD_json_escape "$stdout_text")"
  j_err="$(HELD_json_escape "$stderr_text")"

  printf '{"ts_start":"%s","ts_end":"%s","duration_ms":%s,"cwd":"%s","cmd":"%s","exit":%s,"stdout":"%s","stderr":"%s"}\n' \
    "$HELD_TS_START" "$ts_end" "$duration_ms" "$j_cwd" "$j_cmd" "$exit_status" "$j_out" "$j_err" >> "$HELD_LOG_FILE"

  HELD_INFLIGHT=false; HELD_CAPTURE_OUTPUT=false
  HELD_CMD=""; HELD_CWD=""; HELD_TS_START=""; HELD_STDOUT_FILE=""; HELD_STDERR_FILE=""
}

# ----- control ---------------------------------------------------------------
HELD() {
  case "$1" in
    start)
      if [ "$HELD_ACTIVE" = "true" ]; then [ "$HELD_VERBOSE" = "1" ] && echo "ℹ️  HELD already running → $HELD_LOG_FILE"; return 0; fi
      HELD_ACTIVE=true
      echo "🟢 HELD logging ACTIVE"
      [ "$HELD_SSH_ENABLED" = "true" ] && echo "🔗 SSH session logging ENABLED" || echo "🔗 SSH session logging DISABLED"
      HELD_bootstrap_backend
      HELD_start_shipper_daemon
      [ "$HELD_VERBOSE" = "1" ] && echo "⛴️  Shipper loop detached."
      ;;
    stop)
      if [ "$HELD_ACTIVE" != "true" ]; then echo "ℹ️  No HELD processes are running"; return 1; fi
      if [ "$HELD_FDS_OPEN" = "true" ]; then exec 1>&3 2>&4; exec 3>&- 4>&-; HELD_FDS_OPEN=false; fi
      HELD_ACTIVE=false; HELD_INFLIGHT=false
      echo "🔴 HELD logging STOPPED"
      HELD_stop_shipper_daemon
      # Final ship (live then rotate)
      # Load environment variables from .env file if it exists
      local team_id=""
      local supabase_url=""
      if [ -n "${HELD_ENV_FILE:-}" ] && [ -f "$HELD_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$HELD_ENV_FILE"
        team_id="${HELD_TEAM_ID:-}"
        supabase_url="${SUPABASE_URL:-}"
      fi
      HELD_ENV_FILE="$HELD_ENV_FILE" HELD_LOG_DIR="$HELD_LOG_DIR" HELD_LOG_FILE="$HELD_LOG_FILE" HELD_TEAM_ID="$team_id" SUPABASE_URL="$supabase_url" SHIP_ROTATE=0 "$HELD_VENV_PY" "$HELD_SHIPPER" >/dev/null 2>&1
      HELD_ENV_FILE="$HELD_ENV_FILE" HELD_LOG_DIR="$HELD_LOG_DIR" HELD_LOG_FILE="$HELD_LOG_FILE" HELD_TEAM_ID="$team_id" SUPABASE_URL="$supabase_url" SHIP_ROTATE=1 "$HELD_VENV_PY" "$HELD_SHIPPER" >/dev/null 2>&1
      ;;
    ship-now)
      # HELD ship-now [0|1] -> live or rotate+ship
      local rotate="${2:-0}"
      if [ "$rotate" != "0" ] && [ "$rotate" != "1" ]; then echo "Usage: HELD ship-now [0|1]"; return 2; fi
      if HELD_run_shipper "$rotate"; then
        [ "${HELD_VERBOSE:-0}" = "1" ] && echo "⛴️  Ship complete (rotate=$rotate)."
      else
        echo "❌ shipper failed. See $HELD_LOG_DIR/shipper.log"; return 1
      fi
      ;;
    ssh-enable)  HELD_SSH_ENABLED=true;  echo "🔗 SSH session logging ENABLED" ;;
    ssh-disable) HELD_SSH_ENABLED=false; echo "🔗 SSH session logging DISABLED" ;;
    status)
      if [ "$HELD_ACTIVE" = "true" ]; then
        echo "🟢 ACTIVE → $HELD_LOG_FILE"
        if [ "$HELD_SSH_ENABLED" = "true" ]; then
          [ "$HELD_SSH_SESSION" = "true" ] && echo "🔗 SSH session: $HELD_SSH_USER@$HELD_SSH_HOST" || echo "🔗 SSH session logging: READY"
        else
          echo "🔗 SSH session logging: DISABLED"
        fi
      else
        echo "🔴 INACTIVE"
      fi
      ;;
    ssh-status)
      if [ "$HELD_SSH_ENABLED" = "true" ]; then
        if [ "$HELD_SSH_SESSION" = "true" ]; then
          echo "🔗 Active SSH session: $HELD_SSH_USER@$HELD_SSH_HOST"
          [ "$HELD_SSH_OUTPUT_CAPTURE" = "true" ] && echo "📝 Output capture: ACTIVE → $HELD_SSH_OUTPUT_FILE" || echo "📝 Output capture: INACTIVE"
        else
          echo "🔗 SSH session logging: READY"
        fi
      else
        echo "🔗 SSH session logging: DISABLED"
      fi
      ;;
    ssh-show-output)
      if [ "$HELD_SSH_SESSION" = "true" ] && [ -n "$HELD_SSH_OUTPUT_FILE" ] && [ -f "$HELD_SSH_OUTPUT_FILE" ]; then
        echo "📝 SSH session output for $HELD_SSH_USER@$HELD_SSH_HOST:"
        echo "─────────────────────────────────────────────────────────────"
        cat "$HELD_SSH_OUTPUT_FILE"
        echo "─────────────────────────────────────────────────────────────"
      else
        echo "❌ No active SSH session or output file not found"
      fi
      ;;
    *)
      echo "Usage: HELD {start|stop|ship-now|ssh-enable|ssh-disable|status|ssh-status|ssh-show-output}"
      ;;
  esac
}

# ----- session id + cleanup ---------------------------------------------------
HELD_STATE_DIR="${HELD_STATE_DIR:-$HELD_BACKEND_DIR/state}"
HELD_CHAT_DIR="${HELD_CHAT_DIR:-$HELD_STATE_DIR/chat_histories}"
mkdir -p "$HELD_CHAT_DIR" 2>/dev/null
export HELD_TTY="${HELD_TTY:-$( (tty) 2>/dev/null )}"

if [ -n "${HELD_CHAT_SESSION:-}" ]; then
  export HELD_SESSION_ID="$HELD_CHAT_SESSION"
else
  if command -v uuidgen >/dev/null 2>&1; then HELD_SESSION_ID="sh-$(uuidgen | tr A-F a-f | tr -d '-')"
  else
    seed="$(date +%s)-$RANDOM-$$-${PPID:-0}-${HELD_TTY}"
    h="$(printf '%s' "$seed" | openssl sha1 2>/dev/null | awk '{print $2}')"
    [ -z "$h" ] && h="${RANDOM}$$${PPID:-0}"
    HELD_SESSION_ID="sh-${h:0:12}"
  fi
  export HELD_SESSION_ID
fi

_HELD_cleanup_chat_history() {
  local sid="${HELD_CHAT_SESSION:-$HELD_SESSION_ID}"
  local safe="${sid//[^A-Za-z0-9_.-]/-}"; safe="${safe:0:80}"
  local d="${HELD_CHAT_DIR:-$HELD_BACKEND_DIR/state/chat_histories}"
  [ -f "$d/$safe.json" ] && rm -f -- "$d/$safe.json"
  [ -f "$d/${safe}-ai.json" ] && rm -f -- "$d/${safe}-ai.json"
  [ -f "$d/${safe}-search.json" ] && rm -f -- "$d/${safe}-search.json"
}
trap _HELD_cleanup_chat_history EXIT HUP

# ----- hook installer ---------------------------------------------------------
HELD_install_hooks() {
  case "$1" in
    zsh)
      autoload -Uz add-zsh-hook 2>/dev/null
      add-zsh-hook -d preexec HELD_preexec  >/dev/null 2>&1 || true
      add-zsh-hook -d precmd  HELD_precmd   >/dev/null 2>&1 || true
      add-zsh-hook preexec HELD_preexec
      add-zsh-hook precmd  HELD_precmd
      HELD_define_ssh_wrapper
      ;;
    bash)
      HELD_bash_preexec() { [ -n "${HELD_IN_PROMPT:-}" ] && return 0; HELD_preexec "$BASH_COMMAND"; }
      trap 'HELD_bash_preexec' DEBUG
      HELD_precmd_wrapper() { local _es=$?; HELD_IN_PROMPT=1; HELD_precmd "$_es"; unset HELD_IN_PROMPT; }
      if [ -n "${PROMPT_COMMAND:-}" ]; then
        case "$PROMPT_COMMAND" in *HELD_precmd_wrapper*) : ;; *) PROMPT_COMMAND="HELD_precmd_wrapper; $PROMPT_COMMAND" ;; esac
      else
        PROMPT_COMMAND="HELD_precmd_wrapper"
      fi
      HELD_define_ssh_wrapper
      ;;
  esac
}
