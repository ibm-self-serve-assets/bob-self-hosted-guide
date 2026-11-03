#!/usr/bin/env bash
# bob-client-setup.sh — On-prem Bob client-side workstation setup.
#
# Automates the end-user workstation setup for on-prem Bob:
#   1. Trust the CA certificate in the OS keychain / CA store
#   2. Set gatewayUrl in ~/.bob/settings/settings.json (shared by Bob IDE and
#      Bob Shell; users then sign in through their IdP/SSO)
#   3. Optionally store an API key (only when BOB_API_KEY is set in the env file)
#   4. Warn if an obsolete Bob Shell helper block is still in ~/.zshrc
#
# This script is standalone — it has no `oc` dependency and does NOT source
# any bin/*.sh from the install package. It only requires bash 4+, python3,
# and standard OS tools (security, update-ca-certificates).
#
# Usage:
#   ./scripts/bob-client-setup.sh [--env-file <path>] [--dry-run] [--help]
#
# The --env-file must be bob-client-setup.env (filled from .env.example).

set -eo pipefail

# ── Self-contained logging ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${BOB_LOG_DIR:-${SCRIPT_DIR}/logs}"
LOG_TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
LOG_FILE="${LOG_DIR}/bob-client-setup-${LOG_TIMESTAMP}.log"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

if [[ -n "${NOCOLOR:-}" ]]; then
  _CI=""
  _CW=""
  _CE=""
  _CR=""
else
  _CI=$'\033[0;32m'
  _CW=$'\033[0;33m'
  _CE=$'\033[0;31m'
  _CR=$'\033[0m'
fi

_write_log() {
  local level="$1"; shift
  printf '%s %s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "${level}" "$*" >> "${LOG_FILE}"
}

log_info() {
  _write_log "INFO " "$@"
  printf '%b\n' "${_CI}$*${_CR}"
}

log_warn() {
  _write_log "WARN " "$@"
  printf '%b\n' "${_CW}$*${_CR}"
}

log_error() {
  _write_log "ERROR" "$@"
  printf '%b\n' "${_CE}$*${_CR}" >&2
}

log_dry_run() {
  _write_log "DRY  " "$@"
  printf '%b\n' "${_CW}[DRY-RUN] $*${_CR}"
}

export LOG_FILE

# ── DRY_RUN & SKIP_CERT flags ──────────────────────────────────────────────────

export DRY_RUN=false
SKIP_CERT=false

# ── Constants ───────────────────────────────────────────────────────────────────

# Keychain service name for the API key (matches docs/bob-onprem-shell-setup.md).
readonly KEYCHAIN_SERVICE="bob-onprem-api-key"

# Marker comment written to ~/.zshrc by older versions of this script. It is no
# longer written; it is only used to warn that the old block is obsolete.
readonly ZSH_MARKER="# ── Bob Shell environment helpers"

# ── usage ───────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
bob-client-setup.sh — On-prem Bob workstation setup

Usage:
  bob-client-setup.sh [--env-file <path>] [--skip-cert] [--dry-run] [--help]

Options:
  --env-file <path>   Path to the .env file (default: ./bob-client-setup.env
                      in the script's own directory).
  --skip-cert         Skip CA certificate installation and OS trust store import.
  --dry-run           Log all actions without making any changes.
  --help              Show this help message.

The .env file must contain (see bob-client-setup.env.example):
  BOB_GATEWAY_URL    (required) — full gateway base URL
  BOB_API_KEY        (optional) — alternative to SSO sign-in; if empty, no key
                     is stored and no prompt is shown
  BOB_CA_CERT_PATH   (optional) — path to CA cert; omitted/empty for trusted CAs
EOF
}

# ── Argument parser ─────────────────────────────────────────────────────────────

ENV_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ -z "${2:-}" ]]; then
        log_error "--env-file requires a path argument"
        exit 2
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    --skip-cert|--no-cert)
      SKIP_CERT=true
      shift
      ;;
    --dry-run)
      export DRY_RUN=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      log_error "Usage: $0 [--env-file <path>] [--skip-cert] [--dry-run] [--help]"
      exit 2
      ;;
  esac
done

# ── Locate env file ─────────────────────────────────────────────────────────────
# Look for bob-client-setup.env alongside the script, or at the --env-file path.

if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="${SCRIPT_DIR}/bob-client-setup.env"
fi

# ── Env file loader ─────────────────────────────────────────────────────────────
# Wrap source in `set +x` so secrets are not echoed in debug output.
# (Pattern from bob-autoinstall.sh lines 106–110 and AGENTS.md convention.)

load_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    log_error "Env file not found: ${ENV_FILE}"
    log_error "Copy scripts/bob-client-setup.env.example to bob-client-setup.env and fill in your values."
    exit 1
  fi

  log_info "Loading env file: ${ENV_FILE}"

  # Source with set +x guard to prevent secrets appearing in debug output.
  set +x
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set -eo pipefail
}

# ── Validate required env ───────────────────────────────────────────────────────

validate_env() {
  if [[ -z "${BOB_GATEWAY_URL:-}" ]]; then
    log_error "BOB_GATEWAY_URL is not set in ${ENV_FILE}"
    log_error "This is required — please fill it in and re-run."
    exit 1
  fi

  log_info "Gateway URL: ${BOB_GATEWAY_URL}"
}

# ── Derive values ───────────────────────────────────────────────────────────────

derive_values() {
  # BOB_IDE_GATEWAY_URL ensures trailing slash for gatewayUrl in settings.json
  BOB_IDE_GATEWAY_URL="${BOB_GATEWAY_URL}"
  # Strip any trailing slash, then add one
  BOB_IDE_GATEWAY_URL="${BOB_IDE_GATEWAY_URL%/}/"
  export BOB_IDE_GATEWAY_URL

  # Bob Shell reads NODE_EXTRA_CA_CERTS from ~/bob-ca.crt if configured
  BOB_CA_FILE="${HOME}/bob-ca.crt"
  export BOB_CA_FILE

  # Determine whether certificate trust step is needed
  DO_INSTALL_CERT=false
  CERT_SOURCE=""

  if [[ "${SKIP_CERT}" == "true" ]]; then
    log_info "CA Cert:      Skipping (explicit --skip-cert flag)"
  elif [[ -z "${BOB_CA_CERT_PATH:-}" ]]; then
    log_info "CA Cert:      Skipping (BOB_CA_CERT_PATH empty/unset — trusted CA assumed)"
  else
    DO_INSTALL_CERT=true
    CERT_SOURCE="${BOB_CA_CERT_PATH/#\~/$HOME}"
    # Resolve relative paths against env file directory or script directory
    if [[ ! "${CERT_SOURCE}" = /* ]]; then
      if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
        CERT_SOURCE="$(dirname "${ENV_FILE}")/${CERT_SOURCE}"
      else
        CERT_SOURCE="${SCRIPT_DIR}/${CERT_SOURCE}"
      fi
    fi
  fi
  export DO_INSTALL_CERT
  export CERT_SOURCE

  log_info "gatewayUrl:   ${BOB_IDE_GATEWAY_URL}"
  if [[ "${DO_INSTALL_CERT}" == "true" ]]; then
    log_info "CA cert src:  ${CERT_SOURCE}"
    log_info "CA cert dst:  ${BOB_CA_FILE}"
  fi
}

# ── Detect OS ───────────────────────────────────────────────────────────────────

detect_os() {
  local uname_out
  uname_out="$(uname -s 2>/dev/null || true)"
  if [[ "${uname_out}" == "Darwin" ]]; then
    export BOB_OS="macos"
  elif [[ "${uname_out}" == "Linux" ]]; then
    export BOB_OS="linux"
  else
    log_error "Unsupported OS: ${uname_out}"
    exit 1
  fi
  log_info "Detected OS: ${BOB_OS}"
}

# ── Sub-Task 3: install_ca_cert ─────────────────────────────────────────────────

install_ca_cert() {
  if [[ "${DO_INSTALL_CERT}" != "true" ]]; then
    log_info "=== Step 1: Install CA certificate (Skipped) ==="
    log_info "Skipping CA certificate installation — cluster certificate is assumed trusted by standard authorities."
    return 0
  fi

  log_info "=== Step 1: Install CA certificate ==="

  if [[ ! -f "${CERT_SOURCE}" ]]; then
    log_warn "CA certificate not found at specified path: ${CERT_SOURCE}"
    log_warn "Skipping certificate installation and continuing setup."
    return 0
  fi

  # Copy cert to $HOME/bob-ca.crt (the path NODE_EXTRA_CA_CERTS should point at).
  # Skip the copy when src and dst resolve to the same path to avoid a fatal
  # "cp: identical" error under set -eo pipefail.
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would copy ${CERT_SOURCE} -> ${BOB_CA_FILE}"
  else
    local real_src real_dst
    real_src="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${CERT_SOURCE}")"
    real_dst="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BOB_CA_FILE}")"
    if [[ "${real_src}" == "${real_dst}" ]]; then
      log_info "CA cert already at ${BOB_CA_FILE} — skipping copy"
    else
      log_info "Copying CA cert to ${BOB_CA_FILE}"
      cp "${CERT_SOURCE}" "${BOB_CA_FILE}"
    fi
  fi

  # Trust the cert in the OS store
  if [[ "$BOB_OS" == "macos" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry_run "Would run: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"${BOB_CA_FILE}\""
    else
      log_info "Trusting CA cert in macOS System keychain..."
      # Check if already trusted to make this idempotent.
      local already_trusted
      already_trusted="$(security find-certificate -c "bob-ca" -a -p 2>/dev/null | grep -c "BEGIN CERTIFICATE" || true)"
      if [[ "${already_trusted}" -ge 1 ]]; then
        log_warn "CA cert appears to already be in the keychain — re-running trust step"
      fi
      # add-trusted-cert returns non-zero if the cert is already trusted.
      # Remove any existing entry first, then re-add (idempotent on re-runs).
      sudo security remove-certificate -c "bob-ca" 2>/dev/null || true
      sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "${BOB_CA_FILE}" \
        2>&1 | tee -a "${LOG_FILE}" || true
    fi
  elif [[ "$BOB_OS" == "linux" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry_run "Would run: sudo cp \"${BOB_CA_FILE}\" /usr/local/share/ca-certificates/bob-ca.crt && sudo update-ca-certificates"
    else
      log_info "Trusting CA cert in Linux CA store..."
      sudo cp "${BOB_CA_FILE}" /usr/local/share/ca-certificates/bob-ca.crt
      sudo update-ca-certificates 2>&1 | tee -a "${LOG_FILE}" || true
    fi
  fi

  log_info "CA certificate installed."
}

# ── Sub-Task 4: configure_ide_settings ──────────────────────────────────────────

configure_ide_settings() {
  log_info "=== Step 2: Set gatewayUrl in ~/.bob/settings/settings.json (Bob IDE + Bob Shell) ==="

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would create ~/.bob/settings/ if missing"
    log_dry_run "Would set gatewayUrl to '${BOB_IDE_GATEWAY_URL}' in ~/.bob/settings/settings.json via python3"
    return
  fi

  local settings_dir="${HOME}/.bob/settings"
  local settings_file="${settings_dir}/settings.json"

  mkdir -p "${settings_dir}"

  if [[ -f "${settings_file}" ]]; then
    log_info "Existing settings.json found — merging gatewayUrl"
  else
    log_info "No existing settings.json — creating new one"
  fi

  # Python 3 one-liner to safely merge JSON into settings.json.
  # Pattern adapted from docs/04-manual-install.md lines 474–481.
  python3 -c "
import json, os
p = os.path.expanduser('${settings_file}')
s = json.load(open(p)) if os.path.exists(p) else {}
s['gatewayUrl'] = '${BOB_IDE_GATEWAY_URL}'
json.dump(s, open(p, 'w'), indent=2)
print('Done — gatewayUrl written to ${settings_file}')
" 2>&1 | tee -a "${LOG_FILE}"

  log_info "Bob settings updated. gatewayUrl: ${BOB_IDE_GATEWAY_URL}"
  log_warn "Tip: to switch back to SaaS, rename the 'gatewayUrl' key (e.g. 'gatewayUrl-old') or delete it, then restart Bob"
}

# ── Sub-Task 5: capture_and_store_api_key (optional) ────────────────────────────

capture_and_store_api_key() {
  local api_key="${BOB_API_KEY:-}"

  if [[ -z "${api_key}" ]]; then
    log_info "=== Step 3: API key (Skipped) ==="
    log_info "No BOB_API_KEY in env file — sign in through your IdP/SSO instead."
    log_info "(Optional alternative: create a key with Scope 'Inference' at ${BOB_GATEWAY_URL}/admin/apikeys"
    log_info " and set BOB_API_KEY in the env file, or see docs/bob-onprem-shell-setup.md.)"
    return 0
  fi

  log_info "=== Step 3: Store API key (optional alternative to SSO) ==="
  log_info "Using API key from env file"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would store API key in keychain (macOS) or file (Linux)"
    return
  fi

  if [[ "$BOB_OS" == "macos" ]]; then
    log_info "Storing API key in macOS keychain (service: ${KEYCHAIN_SERVICE})"
    security add-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" \
      -w "$api_key" -U 2>&1 | tee -a "${LOG_FILE}" || true
    log_info "API key stored in keychain service '${KEYCHAIN_SERVICE}'"
  elif [[ "$BOB_OS" == "linux" ]]; then
    log_warn "macOS keychain is not available on Linux."
    log_info "Storing API key in a protected file: ~/.bob/bob-api-key (chmod 600)"
    local key_file="${HOME}/.bob/bob-api-key"
    mkdir -p "${HOME}/.bob"
    printf '%s' "$api_key" > "$key_file"
    chmod 600 "$key_file"
    log_info "API key written to ${key_file}"
  fi

  log_warn "Nothing loads the stored key automatically. To use it, export it in the shell where you run Bob:"
  if [[ "$BOB_OS" == "macos" ]]; then
    log_warn "  export BOB_API_KEY=\"\$(security find-generic-password -a \"\$USER\" -s \"${KEYCHAIN_SERVICE}\" -w)\""
  else
    log_warn "  export BOB_API_KEY=\"\$(cat ~/.bob/bob-api-key)\""
  fi
}

# ── Sub-Task 6: warn_obsolete_zshrc_block ───────────────────────────────────────

# Older versions of this script appended bob-onprem/bob-saas helper functions to
# ~/.zshrc. They are no longer needed. This only warns — it never edits the file.
warn_obsolete_zshrc_block() {
  local zshrc="${HOME}/.zshrc"

  if [[ -f "${zshrc}" ]] && grep -qF "${ZSH_MARKER}" "${zshrc}" 2>/dev/null; then
    log_info "=== Step 4: Obsolete ~/.zshrc helpers detected ==="
    log_warn "${zshrc} still contains the '${ZSH_MARKER}' block from an older version of this script."
    log_warn "It is no longer needed (bob-onprem / bob-saas / BOB_AUTHN_URL). Remove the block manually."
    log_warn "While it exists, bob-onprem may set BOB_AUTHN_URL / BOB_API_KEY and override the settings.json flow."
  else
    log_info "=== Step 4: Obsolete ~/.zshrc helpers (none found) ==="
  fi
}

# ── Sub-Task 7: main ────────────────────────────────────────────────────────────

main() {
  log_info "=== Bob Client-Side Setup ==="
  log_info "Started: $(date)"
  log_info "Log file: ${LOG_FILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY-RUN mode: no changes will be made"
  fi
  log_info ""

  load_env_file
  validate_env
  detect_os
  derive_values
  install_ca_cert
  configure_ide_settings
  capture_and_store_api_key
  warn_obsolete_zshrc_block

  log_info ""
  log_info "=== Setup Complete ==="
  log_info ""
  log_info "Next steps:"
  log_info "  1. Restart Bob (Shell or IDE) so it picks up gatewayUrl."
  log_info "  2. Sign in through your IdP/SSO:"
  log_info "       bob               # Bob Shell, interactive"
  log_info "       bob run \"<prompt>\"   # Bob Shell, non-interactive single prompt"
  if [[ "${DO_INSTALL_CERT}" == "true" ]]; then
    log_info "  3. Private-CA cluster: Bob Shell (Node.js) does not read the OS trust store."
    log_info "     Add this line to ~/.zshrc (or ~/.bashrc), then open a new terminal:"
    log_info "       export NODE_EXTRA_CA_CERTS=\"\$HOME/bob-ca.crt\""
  fi
  log_info ""
  log_info "Bob IDE:"
  log_info "  - Close Bob IDE fully (^Q / Cmd+Q) and relaunch — closing the window is not"
  log_info "    enough, the Electron process must fully exit."
  log_info ""
  log_info "Switching back to SaaS (Bob IDE and Bob Shell):"
  log_info "  - Rename the 'gatewayUrl' key in ~/.bob/settings/settings.json (e.g. 'gatewayUrl-old')"
  log_info "    or delete it, then restart Bob. Rename it back to return to on-prem."
  log_info ""
  log_info "Log file: ${LOG_FILE}"
}

main "$@"
