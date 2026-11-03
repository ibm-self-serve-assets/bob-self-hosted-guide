#!/usr/bin/env bash
# package-client-kit.sh — Package on-prem Bob client setup kit for distribution.
#
# Creates a clean, self-contained zip package containing:
#   1. bob-client-setup.sh (workstation configuration script)
#   2. bob-client-setup.env (pre-populated with gateway URL, cert path, and optional API key —
#      an alternative to IdP/SSO sign-in)
#   3. bob-ca.crt (CA certificate)
#   4. README.md / QUICKSTART instructions for the recipient
#
# Usage:
#   ./scripts/package-client-kit.sh [options]
#
# Options:
#   --gateway-url <url>      Full gateway base URL (e.g. https://api.bob.ibm-bob.apps....)
#   --ca-cert <path>         Path to bob-ca.crt (default: check ~/bob-ca.crt, ./bob-ca.crt, install pkg)
#   --api-key <key>          Optional API key to pre-populate (alternative to SSO; leave blank for SSO)
#   --output-dir <path>      Output directory for zip (default: current directory or scripts/dist)
#   --output-name <name>     Zip file name (default: bob-client-setup-kit.zip)
#   --dry-run                Show what would be packaged without creating zip
#   --help                   Show this help message

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

log_info() {
  printf '%b\n' "${_CI}$*${_CR}"
}

log_warn() {
  printf '%b\n' "${_CW}$*${_CR}"
}

log_error() {
  printf '%b\n' "${_CE}$*${_CR}" >&2
}

log_dry_run() {
  printf '%b\n' "${_CW}[DRY-RUN] $*${_CR}"
}

export DRY_RUN=false
GATEWAY_URL=""
CA_CERT_PATH=""
API_KEY=""
OUTPUT_DIR="${SCRIPT_DIR}"
OUTPUT_NAME="bob-client-setup-kit.zip"
INCLUDE_KEY=false
SKIP_CERT=false

usage() {
  cat <<'EOF'
package-client-kit.sh — Package Bob client setup kit for distribution

Usage:
  ./scripts/package-client-kit.sh [options]

Options:
  --gateway-url <url>      Full gateway base URL (auto-detected if oc is logged in or from env)
  --ca-cert <path>         Path to bob-ca.crt (default: looks in ~/bob-ca.crt, ./bob-ca.crt)
  --skip-cert              Omit CA cert (for clusters using trusted certificates)
  --api-key <key>          Pre-populate a specific API key in the package .env
  --include-api-key        Include the API key found in scripts/bob-client-setup.env
  --output-dir <dir>       Directory to save the zip (default: ./scripts)
  --output-name <name>     Zip archive filename (default: bob-client-setup-kit.zip)
  --dry-run                Preview packaging without writing files
  --help                   Show this help message
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url)
      GATEWAY_URL="$2"
      shift 2
      ;;
    --ca-cert)
      CA_CERT_PATH="$2"
      shift 2
      ;;
    --skip-cert|--no-cert)
      SKIP_CERT=true
      shift
      ;;
    --api-key)
      API_KEY="$2"
      shift 2
      ;;
    --include-api-key)
      INCLUDE_KEY=true
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --output-name)
      OUTPUT_NAME="$2"
      shift 2
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
      usage
      exit 2
      ;;
  esac
done

# ── Detect or read existing values ───────────────────────────────────────────

log_info "=== IBM Bob Client Package Builder ==="

EXISTING_ENV="${SCRIPT_DIR}/bob-client-setup.env"
if [[ -f "${EXISTING_ENV}" ]]; then
  log_info "Reading defaults from ${EXISTING_ENV}"
  # Extract values safely without executing side effects
  EXISTING_GATEWAY="$(grep -E '^BOB_GATEWAY_URL=' "${EXISTING_ENV}" | head -n1 | cut -d'=' -f2- | tr -d '"'\'' ' || true)"
  EXISTING_KEY="$(grep -E '^BOB_API_KEY=' "${EXISTING_ENV}" | head -n1 | cut -d'=' -f2- | tr -d '"'\'' ' || true)"
  EXISTING_CERT="$(grep -E '^BOB_CA_CERT_PATH=' "${EXISTING_ENV}" | head -n1 | cut -d'=' -f2- | tr -d '"'\'' ' || true)"
fi

# 1. Gateway URL resolution
if [[ -z "${GATEWAY_URL}" ]]; then
  if [[ -n "${EXISTING_GATEWAY:-}" ]]; then
    GATEWAY_URL="${EXISTING_GATEWAY}"
    log_info "Found Gateway URL from bob-client-setup.env: ${GATEWAY_URL}"
  elif command -v oc &>/dev/null && oc whoami &>/dev/null; then
    # Try getting from Bob CR status or cluster ingress
    log_info "Querying cluster via oc..."
    CR_GATEWAY="$(oc get bob -n ibm-bob -o jsonpath='{.items[0].status.gatewayURL}' 2>/dev/null || true)"
    if [[ -n "${CR_GATEWAY}" ]]; then
      GATEWAY_URL="${CR_GATEWAY}"
    else
      CLUSTER_DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
      if [[ -n "${CLUSTER_DOMAIN}" ]]; then
        GATEWAY_URL="https://api.bob.ibm-bob.${CLUSTER_DOMAIN}"
      fi
    fi
  fi
fi

if [[ -z "${GATEWAY_URL}" ]]; then
  log_error "Could not determine BOB_GATEWAY_URL."
  log_error "Please provide it with --gateway-url <url> or configure scripts/bob-client-setup.env"
  exit 1
fi

# Ensure trailing slash is stripped for base URL consistency
GATEWAY_URL="${GATEWAY_URL%/}"

# Derive admin console and API keys URL
# Typically if gateway is https://api.bob.NAMESPACE.DOMAIN, web console is https://bob.NAMESPACE.DOMAIN
# or if on same host, ${GATEWAY_URL}/admin/apikeys
if [[ "${GATEWAY_URL}" =~ ^https://api\.(bob\..+)$ ]]; then
  CONSOLE_HOST="https://${BASH_REMATCH[1]}"
else
  CONSOLE_HOST="${GATEWAY_URL}"
fi
API_KEYS_URL="${CONSOLE_HOST}/admin/apikeys"
ADMIN_CONSOLE_URL="${CONSOLE_HOST}/admin"

# 2. CA Certificate resolution
if [[ "${SKIP_CERT}" == "true" ]]; then
  log_info "CA Certificate: Omitted (--skip-cert specified)"
  CA_CERT_PATH=""
else
  if [[ -z "${CA_CERT_PATH}" ]]; then
    if [[ -n "${EXISTING_CERT:-}" && -f "${EXISTING_CERT/#\~/$HOME}" ]]; then
      CA_CERT_PATH="${EXISTING_CERT/#\~/$HOME}"
    elif [[ -f "${HOME}/bob-ca.crt" ]]; then
      CA_CERT_PATH="${HOME}/bob-ca.crt"
    elif [[ -f "${SCRIPT_DIR}/bob-ca.crt" ]]; then
      CA_CERT_PATH="${SCRIPT_DIR}/bob-ca.crt"
    elif [[ -f "${WORKSPACE_ROOT}/bob-ca.crt" ]]; then
      CA_CERT_PATH="${WORKSPACE_ROOT}/bob-ca.crt"
    else
      # Check inside any ibm-bob-install-*/ directory
      for pkg_dir in "${WORKSPACE_ROOT}"/ibm-bob-install-*; do
        if [[ -f "${pkg_dir}/work/bob-ca.crt" ]]; then
          CA_CERT_PATH="${pkg_dir}/work/bob-ca.crt"
          break
        elif [[ -f "${pkg_dir}/bob-ca.crt" ]]; then
          CA_CERT_PATH="${pkg_dir}/bob-ca.crt"
          break
        fi
      done
    fi
  fi

  if [[ -z "${CA_CERT_PATH}" || ! -f "${CA_CERT_PATH}" ]]; then
    if [[ -z "${EXISTING_CERT:-}" ]]; then
      log_info "No CA certificate found or specified — omitting certificate (trusted CA assumed)"
      SKIP_CERT=true
      CA_CERT_PATH=""
    else
      log_error "CA certificate ${EXISTING_CERT} not found!"
      log_error "Please specify the path with --ca-cert <path>, use --skip-cert, or extract it first using:"
      log_error "  ./bobctl get-ca-cert --output bob-ca.crt"
      exit 1
    fi
  else
    log_info "Found CA Certificate: ${CA_CERT_PATH}"
  fi
fi

# 3. API Key resolution
if [[ -z "${API_KEY}" ]]; then
  if [[ "${INCLUDE_KEY}" == "true" && -n "${EXISTING_KEY:-}" ]]; then
    API_KEY="${EXISTING_KEY}"
    log_info "Including existing API key in package .env"
  fi
fi

# ── Packaging ─────────────────────────────────────────────────────────────────

PKG_TMP="$(mktemp -d)"
PKG_NAME="bob-client-setup"
PKG_DIR="${PKG_TMP}/${PKG_NAME}"
mkdir -p "${PKG_DIR}"
mkdir -p "${OUTPUT_DIR}"

cleanup() {
  rm -rf "${PKG_TMP}"
}
trap cleanup EXIT

log_info "Preparing package contents in ${PKG_NAME}/..."

# 1. Copy setup scripts (both Bash and PowerShell)
cp "${SCRIPT_DIR}/bob-client-setup.sh" "${PKG_DIR}/bob-client-setup.sh"
chmod +x "${PKG_DIR}/bob-client-setup.sh"
if [[ -f "${SCRIPT_DIR}/bob-client-setup.ps1" ]]; then
  cp "${SCRIPT_DIR}/bob-client-setup.ps1" "${PKG_DIR}/bob-client-setup.ps1"
fi

# 2. Copy CA certificate (if applicable)
if [[ "${SKIP_CERT}" != "true" && -n "${CA_CERT_PATH}" && -f "${CA_CERT_PATH}" ]]; then
  cp "${CA_CERT_PATH}" "${PKG_DIR}/bob-ca.crt"
  PKG_CA_PATH="bob-ca.crt"
else
  PKG_CA_PATH=""
fi

# 3. Generate pre-populated bob-client-setup.env
cat > "${PKG_DIR}/bob-client-setup.env" <<EOF
# bob-client-setup.env — Pre-configured for on-prem IBM Bob
# chmod 600 bob-client-setup.env

# ── Required ────────────────────────────────────────────────────────────────────
# Gateway base URL
BOB_GATEWAY_URL="${GATEWAY_URL}"

# ── Optional ────────────────────────────────────────────────────────────────────
# Your personal Bob API key (Scope: Inference). NOT required — leave empty and
# sign in through your IdP/SSO instead. If set, bob-client-setup.sh stores it
# (you must still export BOB_API_KEY yourself).
# To generate one manually: ${API_KEYS_URL}
BOB_API_KEY="${API_KEY}"

# ── CA Certificate (Optional) ────────────────────────────────────────────────────
# Leave empty for trusted CA deployments (e.g. TechZone showcase cluster).
BOB_CA_CERT_PATH="${PKG_CA_PATH}"
EOF

chmod 600 "${PKG_DIR}/bob-client-setup.env"

# 4. Generate README / Instructions
cat > "${PKG_DIR}/README.md" <<EOF
# IBM Bob — Client Setup Kit

This package contains everything needed to connect **Bob IDE** and **Bob Shell** to your on-prem IBM Bob instance.

## Deployment Details
- **Gateway API URL:** \`${GATEWAY_URL}\`
- **Web Console / Admin UI:** \`${ADMIN_CONSOLE_URL}\`
- **API Keys Management (optional alternative to SSO):** \`${API_KEYS_URL}\`

---

## Quick Setup (Automated)

### Windows (PowerShell)
Open PowerShell in this directory and run:

\`\`\`powershell
.\bob-client-setup.ps1
\`\`\`

### macOS / Linux (Terminal)
Open Terminal in this directory and run:

\`\`\`bash
./bob-client-setup.sh
\`\`\`

---

## What the Setup Script Does
1. Trusts the \`bob-ca.crt\` certificate in your OS trust store and copies it to \`~/bob-ca.crt\` (only when a CA cert is included in this kit).
2. Sets \`gatewayUrl\` in \`~/.bob/settings/settings.json\`. **Bob IDE and Bob Shell both read this one file**, so both route to the on-prem gateway.
3. *(Only if \`BOB_API_KEY\` is set in \`bob-client-setup.env\`)* Stores that API key in the secure OS credential store.
4. Warns if an obsolete \`bob-onprem\` / \`bob-saas\` helper block from an older kit is still in your shell profile.

No shell helper functions or API key are required — you sign in through your IdP/SSO.

---

## Using IBM Bob

### 1. Bob IDE
1. Fully quit Bob IDE (press **Cmd+Q** on macOS — closing the window is not enough).
2. Relaunch Bob IDE and sign in. It will now connect to the on-prem instance.

### 2. Bob Shell
1. Restart your terminal (or just start a new \`bob\` session) so it picks up \`gatewayUrl\`.
2. Run Bob Shell and sign in through your IdP/SSO:
   \`\`\`bash
   bob
   \`\`\`
3. Or run a single command prompt:
   \`\`\`bash
   bob run "Explain this project"
   \`\`\`
4. If your cluster uses a private CA, Bob Shell (Node.js) also needs this line in \`~/.zshrc\` (or \`~/.bashrc\`):
   \`\`\`bash
   export NODE_EXTRA_CA_CERTS="\$HOME/bob-ca.crt"
   \`\`\`

### 3. Switching between on-prem and SaaS
Rename the \`gatewayUrl\` key in \`~/.bob/settings/settings.json\` (for example to \`gatewayUrl-old\`) or delete it, then restart Bob. Rename it back to return to on-prem. This applies to both Bob IDE and Bob Shell.

---

## Manual Steps & Troubleshooting

### Using an API key instead of SSO (optional)
If you need non-interactive access, create a personal API key, then export it as \`BOB_API_KEY\` in the session where you run Bob Shell:
1. Open \`${API_KEYS_URL}\` in your browser.
2. Click **Create API key**.
3. Name it, set Scope to **Inference**, and set an expiration date.
4. Copy the generated key.

### Certificate Trust Issues
If Bob IDE displays \`UNABLE_TO_VERIFY_LEAF_SIGNATURE\`:
- Ensure you fully quit and restarted Bob IDE via **Cmd+Q**.
- In Bob IDE settings, set \`"http.experimental.systemCertificatesV2": true\`.
EOF

ZIP_OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_NAME}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log_dry_run "Would create archive: ${ZIP_OUTPUT_PATH}"
  log_dry_run "Archive contents:"
  log_dry_run "  - ${PKG_NAME}/bob-client-setup.sh"
  log_dry_run "  - ${PKG_NAME}/bob-client-setup.env (Gateway: ${GATEWAY_URL})"
  if [[ "${SKIP_CERT}" != "true" && -n "${CA_CERT_PATH}" ]]; then
    log_dry_run "  - ${PKG_NAME}/bob-ca.crt"
  fi
  log_dry_run "  - ${PKG_NAME}/README.md"
  exit 0
fi

# Create zip archive
rm -f "${ZIP_OUTPUT_PATH}"
(
  cd "${PKG_TMP}"
  zip -q -r "${ZIP_OUTPUT_PATH}" "${PKG_NAME}"
)

log_info ""
log_info "════════════════════════════════════════════════════════════════"
log_info "  Client Setup Package created successfully!"
log_info "════════════════════════════════════════════════════════════════"
log_info "  File:         ${ZIP_OUTPUT_PATH}"
log_info "  Gateway URL:  ${GATEWAY_URL}"
log_info "  Admin URL:    ${ADMIN_CONSOLE_URL}"
log_info "  API Keys:     ${API_KEYS_URL}"
if [[ -n "${API_KEY}" ]]; then
  log_info "  API Key:      [Pre-populated in .env]"
else
  log_info "  API Key:      [Not included — recipients sign in via IdP/SSO]"
fi
log_info "════════════════════════════════════════════════════════════════"
log_info ""
log_info "You can now share '${ZIP_OUTPUT_PATH}' with your team or manager."
