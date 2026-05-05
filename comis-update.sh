#!/usr/bin/env bash
# comis-update.sh -- safe update for comisai global install
#
# Practices adopted from openclaw's update implementation:
#  - Pre-flight version capture and target resolution
#  - Downgrade guard (require confirmation)
#  - --omit=optional / --no-optional retry on first install failure
#  - Post-restart runtime verification via gateway /health
#  - Manager-aware install (npm | pnpm | bun)
#
# Practices skipped (YAGNI):
#  - No flock / lock file (single-operator VPS, no auto-updater)
#  - No history log
#  - No staged temp-prefix swap, no channels, no auto-rollback
#
# Service-manager-agnostic: defers to `comis daemon` (which itself
# auto-detects systemd / systemd-user / pm2 / direct-spawn).

set -euo pipefail

# ---------- args ----------
DRY_RUN=0
NO_RESTART=0
ASSUME_YES=0
TARGET_TAG="latest"
STEP_TIMEOUT=600
PKG_MANAGER=""
GATEWAY_URL="http://localhost:4766"

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--no-restart] [--tag <ver|dist-tag>]
          [--pkg-manager <npm|pnpm|bun>] [--gateway-url <url>]
          [--yes] [--timeout <s>]

  --dry-run             Print what would happen, don't execute mutating steps
  --no-restart          Skip restarting the daemon after install
  --tag <spec>          Target version or dist-tag (default: latest)
  --pkg-manager <name>  Force a package manager (default: auto-detect)
  --gateway-url <url>   Comis gateway base URL (default: ${GATEWAY_URL})
  --yes                 Skip confirmation prompts
  --timeout <s>         Per-step timeout in seconds (default: ${STEP_TIMEOUT})
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --no-restart)  NO_RESTART=1; shift ;;
    --tag)         TARGET_TAG="$2"; shift 2 ;;
    --pkg-manager) PKG_MANAGER="$2"; shift 2 ;;
    --gateway-url) GATEWAY_URL="$2"; shift 2 ;;
    --yes)         ASSUME_YES=1; shift ;;
    --timeout)     STEP_TIMEOUT="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------- log helpers ----------
ts()   { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log()  { printf '[%s] %s\n'           "$(ts)" "$*"; }
step() { printf '\n[%s] === %s ===\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARN: %s\n'     "$(ts)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n'    "$(ts)" "$*" >&2; exit 1; }
run() {
  log "exec: $*"
  if [[ $DRY_RUN -eq 1 ]]; then log "(dry-run) skipped"; return 0; fi
  "$@"
}
run_to() {
  local secs="$1"; shift
  log "exec(timeout=${secs}s): $*"
  if [[ $DRY_RUN -eq 1 ]]; then log "(dry-run) skipped"; return 0; fi
  timeout "$secs" "$@"
}
confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then die "stdin not a tty; pass --yes to confirm: $prompt"; fi
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- package manager detection ----------
# Diagnostic output goes to stderr; only the resolved manager name is printed
# to stdout so the caller can capture it via $(detect_pkg_manager).
detect_pkg_manager() {
  local found=()
  if command -v pnpm >/dev/null 2>&1; then
    if pnpm list -g comisai 2>/dev/null | grep -qE 'comisai\s+[0-9]'; then
      found+=("pnpm")
    fi
  fi
  if command -v npm >/dev/null 2>&1; then
    if npm ls -g --depth=0 comisai 2>/dev/null | grep -qE 'comisai@[0-9]'; then
      found+=("npm")
    fi
  fi
  if command -v bun >/dev/null 2>&1; then
    if bun pm ls -g 2>/dev/null | grep -qE 'comisai(@|\s)'; then
      found+=("bun")
    fi
  fi

  if [[ ${#found[@]} -eq 0 ]]; then
    log "no package manager reports comisai globally installed" >&2
    log "falling back to npm (pass --pkg-manager to override)" >&2
    printf 'npm'
  elif [[ ${#found[@]} -gt 1 ]]; then
    warn "multiple package managers claim comisai is installed: ${found[*]}"
    warn "this is a dual-install state -- continuing risks divergence"
    die  "resolve manually (uninstall from all but one) or pass --pkg-manager"
  else
    log "detected package manager: ${found[0]}" >&2
    printf '%s' "${found[0]}"
  fi
}

pm_install_cmd() {
  case "$1" in
    npm)  echo "npm install -g comisai@${TARGET_TAG}" ;;
    pnpm) echo "pnpm add -g comisai@${TARGET_TAG}" ;;
    bun)  echo "bun add -g comisai@${TARGET_TAG}" ;;
    *)    die "unknown package manager: $1" ;;
  esac
}

pm_install_retry_cmd() {
  case "$1" in
    npm)  echo "npm install -g --omit=optional comisai@${TARGET_TAG}" ;;
    pnpm) echo "pnpm add -g --no-optional comisai@${TARGET_TAG}" ;;
    bun)  echo "" ;;  # bun: no equivalent retry
    *)    die "unknown package manager: $1" ;;
  esac
}

pm_prefix_for_diskcheck() {
  case "$1" in
    npm)  npm config get prefix 2>/dev/null || echo "" ;;
    pnpm) pnpm config get global-dir 2>/dev/null || pnpm root -g 2>/dev/null || echo "" ;;
    bun)  echo "${BUN_INSTALL:-$HOME/.bun}" ;;
  esac
}

# ---------- /health helpers ----------
# Extract a JSON string field from /health output. Uses sed (no jq dep).
# Returns empty string if field is absent.
health_field() {
  local body="$1" field="$2"
  printf '%s' "$body" | sed -n "s/.*\"${field}\":\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

fetch_health() {
  curl -fsS --max-time 5 "${GATEWAY_URL}/health" 2>/dev/null || true
}

# ---------- preflight ----------
step "preflight"

command -v node  >/dev/null || die "node not on PATH"
command -v comis >/dev/null || die "comis not on PATH (is comisai installed globally?)"
command -v curl  >/dev/null || die "curl not on PATH (needed for /health verification)"

NODE_VER=$(node --version)
log "node=${NODE_VER}"

INSTALL_PATH=$(readlink -f "$(command -v comis)" 2>/dev/null || command -v comis)
log "comis binary: ${INSTALL_PATH}"

if [[ -z "$PKG_MANAGER" ]]; then
  PKG_MANAGER=$(detect_pkg_manager)
fi
log "using package manager: ${PKG_MANAGER}"

# we still need npm for `npm view` to resolve target version
command -v npm >/dev/null || die "npm not on PATH (needed to resolve target version)"
log "npm version: $(npm --version)"

# disk space warn-only
PREFIX=$(pm_prefix_for_diskcheck "$PKG_MANAGER")
if [[ -n "$PREFIX" && -d "$PREFIX" ]]; then
  AVAIL_KB=$(df -Pk "$PREFIX" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "${AVAIL_KB:-}" && "$AVAIL_KB" -lt 524288 ]]; then
    warn "low disk on ${PREFIX}: $((AVAIL_KB/1024)) MiB free (<512 MiB)"
  else
    log "${PKG_MANAGER} prefix=${PREFIX} free=$((${AVAIL_KB:-0}/1024)) MiB"
  fi
fi

log "pre-update daemon status:"
( comis daemon status 2>&1 || true ) | sed 's/^/  | /'

# pre-update /health snapshot (used for restart verification)
log "pre-update /health snapshot at ${GATEWAY_URL}/health:"
PRE_HEALTH=$(fetch_health)
if [[ -n "$PRE_HEALTH" ]]; then
  printf '%s\n' "$PRE_HEALTH" | sed 's/^/  | /'
  PRE_INSTANCE=$(health_field "$PRE_HEALTH" instanceId)
  PRE_STARTED=$(health_field "$PRE_HEALTH" startedAt)
  PRE_VERSION=$(health_field "$PRE_HEALTH" version)
  log "pre instanceId=${PRE_INSTANCE:-unknown} startedAt=${PRE_STARTED:-unknown} version=${PRE_VERSION:-(not exposed)}"
else
  warn "could not reach ${GATEWAY_URL}/health (gateway down or wrong URL)"
  PRE_INSTANCE=""; PRE_STARTED=""; PRE_VERSION=""
fi

OLD_VERSION=$(comis --version 2>/dev/null | tr -d '[:space:]' || echo "unknown")
log "old version (binary): ${OLD_VERSION}"

log "resolving target via npm registry: comisai@${TARGET_TAG}"
NEW_VERSION=$(timeout 30 npm view "comisai@${TARGET_TAG}" version 2>/dev/null | tail -n1 | tr -d '[:space:]') \
  || die "could not resolve comisai@${TARGET_TAG} from npm registry"
[[ -n "$NEW_VERSION" ]] || die "npm view returned empty version for comisai@${TARGET_TAG}"
log "target version: ${NEW_VERSION}"

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  log "already at ${NEW_VERSION} -- will refresh install + restart anyway"
fi

# downgrade guard
if [[ "$OLD_VERSION" != "$NEW_VERSION" && "$OLD_VERSION" != "unknown" ]]; then
  if [[ "$(printf '%s\n%s\n' "$OLD_VERSION" "$NEW_VERSION" | sort -V | head -n1)" == "$NEW_VERSION" ]]; then
    warn "this is a DOWNGRADE: ${OLD_VERSION} -> ${NEW_VERSION}"
    confirm "proceed with downgrade?" || die "aborted by user"
  fi
fi

log "pre-update health command output:"
( comis health 2>&1 || true ) | sed 's/^/  | /'

# ---------- stop ----------
step "stop daemon"
if run_to 30 comis daemon stop; then
  log "comis daemon stop returned"
else
  warn "comis daemon stop returned non-zero; will verify directly"
fi

if [[ $DRY_RUN -eq 0 ]]; then
  # `comis daemon stop` can return 0 while the daemon is still alive --
  # specifically when systemd reports `activating` (sd-notify timing).
  # Letting `npm install -g` overwrite files of a running daemon corrupts
  # the install. Verify via /health; if still up, escalate to systemctl.
  log "verifying daemon is stopped (polling /health)"
  STOP_VERIFIED=0
  for i in 1 2 3; do
    sleep 2
    if [[ -z "$(fetch_health)" ]]; then
      STOP_VERIFIED=1
      log "  /health no longer responding (attempt ${i}/3)"
      break
    fi
    log "  /health still responding (attempt ${i}/3)"
  done

  # Build a systemctl prefix appropriate for the current uid. We try sudo -n
  # only if not root; the actual auth check happens when the command runs (so
  # we surface its error message instead of pre-rejecting).
  sysctl_run() {
    # $1 = "system" | "user", remaining args = systemctl subcommand+args
    local scope="$1"; shift
    local out rc
    if [[ "$scope" == "user" ]]; then
      out=$(systemctl --user "$@" 2>&1); rc=$?
    elif [[ $EUID -eq 0 ]]; then
      out=$(systemctl "$@" 2>&1); rc=$?
    elif command -v sudo >/dev/null 2>&1; then
      out=$(sudo -n systemctl "$@" 2>&1); rc=$?
    else
      out="(no sudo available)"; rc=127
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  | /'
    return $rc
  }

  HAS_SYSTEM_UNIT=0
  HAS_USER_UNIT=0
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files comis.service 2>/dev/null | grep -qE '^comis\.service\s'; then
      HAS_SYSTEM_UNIT=1
    fi
    if systemctl --user list-unit-files comis.service 2>/dev/null | grep -qE '^comis\.service\s'; then
      HAS_USER_UNIT=1
    fi
  fi
  log "systemd units: system=${HAS_SYSTEM_UNIT} user=${HAS_USER_UNIT}"

  if [[ $STOP_VERIFIED -eq 0 ]]; then
    if [[ $HAS_SYSTEM_UNIT -eq 1 ]]; then
      warn "escalating: systemctl stop comis (system unit)"
      sysctl_run system stop comis && log "  systemctl stop comis OK" || warn "  systemctl stop comis rc=$?"
    fi
    if [[ $HAS_USER_UNIT -eq 1 ]]; then
      warn "escalating: systemctl --user stop comis"
      sysctl_run user stop comis && log "  systemctl --user stop comis OK" || warn "  systemctl --user stop comis rc=$?"
    fi
    for i in 1 2 3 4 5; do
      sleep 2
      if [[ -z "$(fetch_health)" ]]; then
        STOP_VERIFIED=1
        log "  /health no longer responding after escalation (attempt ${i}/5)"
        break
      fi
      log "  /health still responding after escalation (attempt ${i}/5)"
    done
  fi

  if [[ $STOP_VERIFIED -eq 0 ]]; then
    die "daemon still serving /health after stop attempts -- aborting before install to avoid corrupting a running daemon. Stop manually (e.g. 'sudo systemctl stop comis') and retry."
  fi

  # Reset systemd failure counter so any install-time blip doesn't burn
  # through the restart budget mid-install.
  if [[ $HAS_SYSTEM_UNIT -eq 1 ]]; then
    sysctl_run system reset-failed comis >/dev/null 2>&1 && log "systemctl reset-failed comis (system unit)" || true
  fi
  if [[ $HAS_USER_UNIT -eq 1 ]]; then
    sysctl_run user reset-failed comis >/dev/null 2>&1 && log "systemctl --user reset-failed comis" || true
  fi
fi

# ---------- install ----------
INSTALL_CMD=$(pm_install_cmd "$PKG_MANAGER")
RETRY_CMD=$(pm_install_retry_cmd "$PKG_MANAGER")

step "install: ${INSTALL_CMD}"
INSTALL_OK=0
if run_to "$STEP_TIMEOUT" bash -c "$INSTALL_CMD"; then
  INSTALL_OK=1
elif [[ -n "$RETRY_CMD" ]]; then
  warn "install failed; retrying without optional deps: ${RETRY_CMD}"
  if run_to "$STEP_TIMEOUT" bash -c "$RETRY_CMD"; then
    INSTALL_OK=1
  fi
else
  warn "install failed and no retry strategy for ${PKG_MANAGER}"
fi
[[ $INSTALL_OK -eq 1 ]] || die "install failed; daemon left stopped, see rollback hint at end"

# ---------- verify swap ----------
step "verify installed binary version"
hash -r 2>/dev/null || true
INSTALLED_VERSION=$(comis --version 2>/dev/null | tr -d '[:space:]' || echo "")
log "comis --version reports: ${INSTALLED_VERSION}"
if [[ $DRY_RUN -eq 0 && "$INSTALLED_VERSION" != "$NEW_VERSION" ]]; then
  warn "expected ${NEW_VERSION} but installed reports ${INSTALLED_VERSION}"
  warn "PATH cache or stale binary may be at fault; check 'which comis' and shell hash"
fi

# ---------- doctor ----------
step "comis doctor"
DOCTOR_OK=0
if run_to "$STEP_TIMEOUT" comis doctor; then DOCTOR_OK=1
else warn "comis doctor exited non-zero -- review output above"; fi
log "doctor_ok=${DOCTOR_OK}"

# ---------- restart ----------
RESTART_VERIFIED="skipped"
if [[ $NO_RESTART -eq 1 ]]; then
  step "skip restart (--no-restart)"
  warn "daemon left stopped; start manually with: comis daemon start"
else
  step "restart daemon"
  if run_to 60 comis daemon start; then
    log "comis daemon start returned ok"
  else
    warn "comis daemon start returned non-zero -- check status/logs below"
  fi
  log "waiting up to 30s for /health to respond"

  if [[ $DRY_RUN -eq 0 ]]; then
    POST_HEALTH=""
    for i in 1 2 3 4 5 6; do
      sleep 5
      POST_HEALTH=$(fetch_health)
      if [[ -n "$POST_HEALTH" ]]; then break; fi
      log "  attempt ${i}/6: no /health response yet"
    done

    step "verify restarted daemon"
    log "daemon status:"
    ( comis daemon status 2>&1 || true ) | sed 's/^/  | /'
    log "last 50 daemon log lines:"
    ( comis daemon logs --lines 50 2>&1 || true ) | sed 's/^/  | /'

    if [[ -z "$POST_HEALTH" ]]; then
      warn "no /health response after 30s -- daemon may not be up"
      RESTART_VERIFIED="failed-no-health"
    else
      log "post-update /health snapshot:"
      printf '%s\n' "$POST_HEALTH" | sed 's/^/  | /'
      POST_INSTANCE=$(health_field "$POST_HEALTH" instanceId)
      POST_STARTED=$(health_field "$POST_HEALTH" startedAt)
      POST_VERSION=$(health_field "$POST_HEALTH" version)
      log "post instanceId=${POST_INSTANCE:-unknown} startedAt=${POST_STARTED:-unknown} version=${POST_VERSION:-(not exposed)}"

      # Three-way version check matching the plan:
      if [[ -z "$POST_VERSION" ]]; then
        warn "/health did not return a 'version' field -- daemon predates the version field on /health"
        warn "binary version (${INSTALLED_VERSION}) was verified; running version could not be confirmed"
        RESTART_VERIFIED="degraded-no-version-field"
      elif [[ "$POST_VERSION" == "$NEW_VERSION" ]]; then
        log "version verified: /health reports ${POST_VERSION}, expected ${NEW_VERSION}"
        RESTART_VERIFIED="ok"
      else
        warn "version mismatch: /health reports ${POST_VERSION}, expected ${NEW_VERSION}"
        RESTART_VERIFIED="failed-version-mismatch"
      fi

      # Restart sanity: startedAt should differ from pre-restart snapshot
      if [[ -n "$PRE_STARTED" && "$POST_STARTED" == "$PRE_STARTED" ]]; then
        warn "startedAt unchanged (${POST_STARTED}) -- daemon process may not have restarted"
      fi
    fi
  fi
fi

# ---------- summary ----------
step "summary"
log "old=${OLD_VERSION}  new=${INSTALLED_VERSION:-unknown}  doctor_ok=${DOCTOR_OK}  restart=${RESTART_VERIFIED}"
ROLLBACK_CMD=$(pm_install_cmd "$PKG_MANAGER" | sed "s/comisai@${TARGET_TAG}/comisai@${OLD_VERSION}/")
log "rollback (if needed):"
log "  comis daemon stop && ${ROLLBACK_CMD} && comis daemon start"

# Exit non-zero on hard failures only. "degraded-no-version-field" is benign
# when running against a daemon that predates the /health version field.
case "$RESTART_VERIFIED" in
  failed-version-mismatch|failed-no-health)
    die "restart verification failed: ${RESTART_VERIFIED}"
    ;;
esac
log "done"
