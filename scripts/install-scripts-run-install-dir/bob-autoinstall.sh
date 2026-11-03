#!/usr/bin/env bash
# bob-autoinstall.sh — fully automated IBM Bob install for GA release
#
# Usage:
#   ./bob-autoinstall.sh [--dry-run]
#
# Prerequisites:
#   - bob-autoinstall.env exists alongside this script (chmod 600)
#   - oc is logged in to the target cluster
#   - helm 3.14.0+ is on PATH
#   - config.yaml and model-gateway.yaml are present in the same directory
#
# Environment variables (set in bob-autoinstall.env):
#   IBM_ENTITLEMENT_KEY           — IBM entitlement key for cp.icr.io  (required)
#   BOB_ADMIN_PASSWORD            — bob-admin@bob.ibm.com password     (optional; prompted if empty)
#   BOB_KEYCLOAK_WAIT_TIMEOUT     — seconds to wait for Keycloak pod Ready (default 120)
#   BOB_IDP_CONFIG                — path to IdP config file (optional; default: ./config-idp.yaml if present, else a generated bob.ibm.com baseline)
#   BOB_SKIP_IDP_CONFIG           — skip BobIdp creation if "true" (not recommended; nobody can log in)
#   BOB_IDP_WAIT_TIMEOUT          — seconds to wait for BobIdp CR Ready (default 600)

set -eo pipefail

# ── Self-contained logging ────────────────────────────────────────────────────

BOB_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOB_LOG_DIR="${BOB_LOG_DIR:-${BOB_SCRIPT_DIR}/logs}"
BOB_LOG_TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
BOB_LOG_FILE="${BOB_LOG_DIR}/bob-autoinstall-${BOB_LOG_TIMESTAMP}.log"

mkdir -p "${BOB_LOG_DIR}"
touch "${BOB_LOG_FILE}"

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
  printf '%s %s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "${level}" "$*" >> "${BOB_LOG_FILE}"
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

# ── DRY_RUN flag ──────────────────────────────────────────────────────────────

export DRY_RUN=false

for _arg in "$@"; do
  if [[ "${_arg}" == "--dry-run" ]]; then
    export DRY_RUN=true
  fi
done

# ── Constants ─────────────────────────────────────────────────────────────────

readonly OPERATOR_NS="ibm-bob-operators"
readonly INSTANCE_NS="ibm-bob"
readonly SMOKE_IMAGE="cp.icr.io/cp/bob/bob-admin@sha256:a942b8e31e1f0ce7c98a44a6c69861f3c8aa5e5a7e1395b8221976db39e0a653"
readonly INSTALL_RETRIES="${BOBCTL_INSTALL_RETRIES:-3}"
readonly INSTALL_RETRY_DELAY="${BOBCTL_INSTALL_RETRY_DELAY:-15}"
readonly BOB_INSTALL_TIMEOUT="${BOB_INSTALL_TIMEOUT:-1500}"

# ── permission helpers ────────────────────────────────────────────────────────

# _get_file_perms <file>
# Prints the octal mode (e.g. 600) or nothing if it cannot be determined.
# GNU stat is tried first: on GNU (Linux, Git Bash, WSL) `stat -f` means
# "filesystem status" and prints multi-line text, so it must not come before
# `stat -c`. BSD/macOS stat is the fallback.
_get_file_perms() {
  local f="$1" p
  p="$(stat -c '%a' "${f}" 2>/dev/null || true)"
  if [[ "${p}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s' "${p}"
    return 0
  fi
  p="$(stat -f '%OLp' "${f}" 2>/dev/null || true)"
  if [[ "${p}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s' "${p}"
    return 0
  fi
  return 0
}

# _is_windows_shell
# Returns 0 under Git Bash / MSYS / Cygwin.
_is_windows_shell() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# _fs_ignores_chmod <file>
# Returns 0 if chmod cannot be enforced on the file's filesystem
# (Git Bash / MSYS / Cygwin, or a Windows drive mounted into WSL).
_fs_ignores_chmod() {
  local f="$1"
  if _is_windows_shell; then
    return 0
  fi
  if [[ "${f}" == /mnt/[a-zA-Z]/* ]]; then
    return 0
  fi
  return 1
}

# ── oc exec wrapper ───────────────────────────────────────────────────────────

# _oc_exec <oc exec args...>
# Git Bash (MSYS) rewrites any argument that starts with "/" into a Windows path
# before oc.exe sees it (e.g. /opt/keycloak/bin/kcadm.sh becomes
# C:/Program Files/Git/opt/keycloak/bin/kcadm.sh). Those are paths INSIDE the
# container, so conversion must be off. Ignored on Linux, macOS and WSL.
_oc_exec() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' oc exec "$@"
}

# ── check_prerequisites ───────────────────────────────────────────────────────

check_prerequisites() {
  log_info "==> §1 Checking prerequisites"

  # bob-autoinstall.env must exist and be chmod 600
  local env_file="${BOB_SCRIPT_DIR}/bob-autoinstall.env"
  if [[ ! -f "${env_file}" ]]; then
    log_error "bob-autoinstall.env not found at ${env_file}"
    log_error "Copy bob-autoinstall.env.example to bob-autoinstall.env and fill in your values."
    exit 1
  fi

  local env_perms
  env_perms="$(_get_file_perms "${env_file}")"
  if [[ "${env_perms}" != "600" ]]; then
    if _fs_ignores_chmod "${env_file}"; then
      log_warn "bob-autoinstall.env permissions are ${env_perms:-unknown}, not 600."
      log_warn "This filesystem (Windows drive) cannot enforce Unix permissions — continuing."
      log_warn "For real protection, run from a Linux-side directory (e.g. WSL ~/bob/...)."
    else
      log_error "bob-autoinstall.env must be chmod 600 (current: ${env_perms:-unknown})"
      log_error "Run: chmod 600 ${env_file}"
      exit 1
    fi
  fi

  # Source env file — wrap set +x so the key is not echoed in debug mode
  set +x
  # shellcheck source=/dev/null
  source "${env_file}"
  set -eo pipefail

  if [[ -z "${IBM_ENTITLEMENT_KEY:-}" ]]; then
    log_error "IBM_ENTITLEMENT_KEY is not set in bob-autoinstall.env"
    exit 1
  fi

  # Tooling checks
  local missing=0
  for tool in oc helm openssl base64; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      log_error "Required tool not found: ${tool}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1

  # Helm version >= 3.14
  local helm_ver
  helm_ver="$(helm version --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  local helm_major helm_minor
  helm_major="$(printf '%s' "${helm_ver}" | cut -d. -f1)"
  helm_minor="$(printf '%s' "${helm_ver}" | cut -d. -f2)"
  if [[ "${helm_major}" -lt 3 ]] || { [[ "${helm_major}" -eq 3 ]] && [[ "${helm_minor}" -lt 14 ]]; }; then
    log_error "helm 3.14.0+ is required (found: ${helm_ver})"
    exit 1
  fi

  # oc login check
  if ! oc whoami >/dev/null 2>&1; then
    log_error "oc is not logged in — run 'oc login ...' before continuing"
    exit 1
  fi

  # config files
  if [[ ! -f "${BOB_SCRIPT_DIR}/config.yaml" ]]; then
    log_error "config.yaml not found in ${BOB_SCRIPT_DIR}"
    log_error "Create it from config-template.yaml: cp config-template.yaml config.yaml"
    exit 1
  fi

  if [[ ! -f "${BOB_SCRIPT_DIR}/model-gateway.yaml" ]]; then
    log_error "model-gateway.yaml not found in ${BOB_SCRIPT_DIR}"
    exit 1
  fi

  log_info "    Prerequisites: OK"
  log_info "    Cluster: $(oc whoami --show-server)"
  log_info "    User:    $(oc whoami)"
  log_info "    Helm:    ${helm_ver}"
}

# ── install_cert_manager ──────────────────────────────────────────────────────

install_cert_manager() {
  log_info "==> §3 Checking / installing cert-manager"

  if oc get crd certificates.cert-manager.io >/dev/null 2>&1; then
    local version
    version="$(oc get csv -n cert-manager-operator \
      -o jsonpath='{.items[0].spec.version}' 2>/dev/null || true)"
    log_info "    cert-manager already installed (${version:-unknown version}) — skipping"
    return
  fi

  log_info "    cert-manager not found — installing via OLM"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "oc new-project cert-manager-operator"
    log_dry_run "oc apply -f <OperatorGroup>"
    log_dry_run "oc apply -f <Subscription>"
    return
  fi

  oc new-project cert-manager-operator 2>/dev/null || true

  oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
EOF

  oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  log_info "    Waiting for cert-manager CSV to reach Succeeded (up to 3 min)…"
  local deadline=$(( $(date +%s) + 180 ))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    local phase
    phase="$(oc get csv -n cert-manager-operator \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" ]]; then
      log_info "    cert-manager CSV: Succeeded"
      return
    fi
    sleep 10
  done
  log_error "cert-manager did not reach Succeeded within 3 minutes"
  exit 1
}

# ── deploy_nfs_provisioner ────────────────────────────────────────────────────

deploy_nfs_provisioner() {
  log_info "==> §4 Checking storage classes"

  if oc get sc ocs-storagecluster-cephfs >/dev/null 2>&1 && \
     oc get sc ocs-storagecluster-ceph-rbd >/dev/null 2>&1; then
    log_info "    ODF storage classes present — NFS provisioner not needed"
    return
  fi

  log_warn "    ODF storage classes not found — NFS provisioner may be required."
  log_warn "    Bob needs both RWX and RWO storage classes (ODF). If the cluster was provisioned"
  log_warn "    with a small disk (e.g. 100 GB), ODF may have failed or been skipped."
  log_warn "    Re-provision with 300 GB or more, or fix ODF, before continuing."
  log_warn "    If your config.yaml already specifies a valid RWX class, this warning can be ignored."
  log_warn "    See Appendix G of the install guide to deploy the managed NFS provisioner manually."
}

# ── validate_config_files ─────────────────────────────────────────────────────

validate_config_files() {
  log_info "==> §5 Validating config files"

  for f in config.yaml model-gateway.yaml; do
    if [[ ! -s "${BOB_SCRIPT_DIR}/${f}" ]]; then
      log_error "${f} is missing or empty"
      exit 1
    fi
    log_info "    ${f}: OK"
  done
}

# ── generate_cluster_resources ────────────────────────────────────────────────

generate_cluster_resources() {
  log_info "==> §6 Generating and applying cluster-scoped resources"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "./bobctl generate-cluster-resources"
    log_dry_run "oc apply -f work/cluster-resources.yaml --force-conflicts --server-side"
    return
  fi

  cd "${BOB_SCRIPT_DIR}"
  ./bobctl generate-cluster-resources 2>&1 | tee -a "${BOB_LOG_FILE}"

  oc apply -f work/cluster-resources.yaml --force-conflicts --server-side \
    2>&1 | tee -a "${BOB_LOG_FILE}"

  log_info "    Cluster-scoped resources applied"

  # Confirm namespaces
  if ! oc get namespace "${OPERATOR_NS}" "${INSTANCE_NS}" >/dev/null 2>&1; then
    log_error "Namespaces ${OPERATOR_NS} and/or ${INSTANCE_NS} not found after apply"
    exit 1
  fi
}

# ── create_pull_secrets ───────────────────────────────────────────────────────

create_pull_secrets() {
  log_info "==> §7a Creating ibm-entitlement-key pull secret"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "oc create secret docker-registry ibm-entitlement-key --namespace ${OPERATOR_NS} --docker-server=cp.icr.io --docker-username=cp [...]"
    log_dry_run "oc create secret docker-registry ibm-entitlement-key --namespace ${INSTANCE_NS}  --docker-server=cp.icr.io --docker-username=cp [...]"
    return
  fi

  for ns in "${OPERATOR_NS}" "${INSTANCE_NS}"; do
    oc create secret docker-registry ibm-entitlement-key \
      --namespace "${ns}" \
      --docker-server=cp.icr.io \
      --docker-username=cp \
      --docker-password="${IBM_ENTITLEMENT_KEY}" \
      --dry-run=client -o yaml \
    | oc label --local -f - \
        app.kubernetes.io/managed-by=Helm \
        -o yaml \
    | oc annotate --local -f - \
        meta.helm.sh/release-name=ibm-bob \
        meta.helm.sh/release-namespace=ibm-bob \
        -o yaml \
    | oc apply -f -
    log_info "    ibm-entitlement-key created/updated in namespace ${ns}"
  done
}

# ── run_smoke_test ────────────────────────────────────────────────────────────

run_smoke_test() {
  log_info "==> §7b Running image pull smoke test"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "oc run test-pull --image=${SMOKE_IMAGE} --namespace ${INSTANCE_NS} [...]"
    return
  fi

  # Clean up any leftover pod from a previous run
  oc delete pod test-pull -n "${INSTANCE_NS}" --ignore-not-found >/dev/null 2>&1 || true

  oc run test-pull \
    --namespace "${INSTANCE_NS}" \
    --image="${SMOKE_IMAGE}" \
    --overrides='{"spec":{"imagePullSecrets":[{"name":"ibm-entitlement-key"}]}}' \
    --restart=Never \
    2>&1 | tee -a "${BOB_LOG_FILE}"

  log_info "    Waiting 20s for pull to complete…"
  sleep 20

  local status
  status="$(oc get pod test-pull -n "${INSTANCE_NS}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  local reason
  reason="$(oc get pod test-pull -n "${INSTANCE_NS}" \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"

  log_info "    Smoke test pod status: ${status:-unknown} (waiting reason: ${reason:-none})"

  oc delete pod test-pull -n "${INSTANCE_NS}" --ignore-not-found >/dev/null 2>&1 || true

  if [[ "${reason}" == "ImagePullBackOff" || "${reason}" == "ErrImagePull" ]]; then
    log_error "Smoke test FAILED — image pull error: ${reason}"
    log_error "Verify IBM_ENTITLEMENT_KEY is valid for cp.icr.io"
    exit 1
  fi

  log_info "    Smoke test PASSED — image pull succeeded"
}

# ── run_install ───────────────────────────────────────────────────────────────

run_install() {
  log_info "==> §7c Running bobctl install (up to ${INSTALL_RETRIES} attempts)"

  cd "${BOB_SCRIPT_DIR}"

  local attempt=1
  while [[ "${attempt}" -le "${INSTALL_RETRIES}" ]]; do
    log_info "    Install attempt ${attempt}/${INSTALL_RETRIES}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      log_dry_run "./bobctl install --accept-license --model-config model-gateway.yaml --registry-creds cp:<IBM_ENTITLEMENT_KEY>"
      break
    fi

    if ./bobctl install \
        --accept-license \
        --model-config model-gateway.yaml \
        --registry-creds "cp:${IBM_ENTITLEMENT_KEY}" \
        2>&1 | tee -a "${BOB_LOG_FILE}"; then
      log_info "    bobctl install succeeded"
      break
    fi

    local exit_code="${PIPESTATUS[0]}"
    if [[ "${attempt}" -ge "${INSTALL_RETRIES}" ]]; then
      log_error "bobctl install failed after ${INSTALL_RETRIES} attempts (exit code ${exit_code})"
      exit 1
    fi

    log_warn "    Install attempt ${attempt} failed (exit code ${exit_code}) — retrying in ${INSTALL_RETRY_DELAY}s…"
    sleep "${INSTALL_RETRY_DELAY}"
    attempt=$(( attempt + 1 ))
  done

  # Poll for Available: True on the Bob CR
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "Polling Bob CR for Available: True (timeout ${BOB_INSTALL_TIMEOUT}s)"
    return
  fi

  log_info "    Polling Bob CR for Available: True (timeout ${BOB_INSTALL_TIMEOUT}s)…"
  local deadline=$(( $(date +%s) + BOB_INSTALL_TIMEOUT ))

  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    local avail
    avail="$(oc get bob -n "${INSTANCE_NS}" \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' \
      2>/dev/null || true)"
    if [[ "${avail}" == "True" ]]; then
      log_info "    Bob CR Available: True — install complete"
      return
    fi
    log_info "    $(date +%H:%M:%S) — Available: ${avail:-Unknown} — waiting…"
    sleep 15
  done

  log_error "Timed out (${BOB_INSTALL_TIMEOUT}s) waiting for Bob CR Available: True"
  log_error "Check: oc get bob -n ${INSTANCE_NS} -o jsonpath='{.items[0].status.conditions}' | python3 -m json.tool"
  exit 1
}

# ── post_install_admin ────────────────────────────────────────────────────────

# _wait_keycloak_ready <namespace> <timeout_seconds>
# Blocks until bob-keycloak-0 is Running+Ready, then prints the container name.
# Exits 1 on timeout.
_wait_keycloak_ready() {
  local ns="$1"
  local timeout="${2:-120}"
  local deadline=$(( $(date +%s) + timeout ))

  log_info "    Waiting for bob-keycloak-0 to be Ready (timeout ${timeout}s)…" >&2
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    local phase container_name ready
    phase="$(oc get pod bob-keycloak-0 -n "${ns}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    container_name="$(oc get pod bob-keycloak-0 -n "${ns}" \
      -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || true)"
    ready="$(oc get pod bob-keycloak-0 -n "${ns}" \
      -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"

    if [[ "${phase}" == "Running" && "${ready}" == "true" && -n "${container_name}" ]]; then
      log_info "    bob-keycloak-0 is Ready (container: ${container_name})" >&2
      echo "${container_name}"
      return 0
    fi
    log_info "    $(date +%H:%M:%S) — keycloak pod phase=${phase:-unknown} ready=${ready:-unknown} — waiting…" >&2
    sleep 10
  done

  log_error "Timed out (${timeout}s) waiting for bob-keycloak-0 to be Ready"
  log_error "Check: oc get pod bob-keycloak-0 -n ${ns} -o yaml"
  exit 1
}

post_install_admin() {
  log_info "==> §9/§10 Post-install: CA cert extraction and admin password"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "./bobctl get-ca-cert --output ${HOME}/bob-ca.crt"
    log_dry_run "oc exec -n ${INSTANCE_NS} bob-keycloak-0 -c <container> -- /opt/keycloak/bin/kcadm.sh set-password ..."
    return
  fi

  # Extract CA cert
  log_info "    Extracting CA certificate to ${HOME}/bob-ca.crt"
  ./bobctl get-ca-cert --output "${HOME}/bob-ca.crt"
  openssl x509 -in "${HOME}/bob-ca.crt" -noout -subject -issuer -dates \
    2>&1 | tee -a "${BOB_LOG_FILE}"
  log_info "    CA cert written to ${HOME}/bob-ca.crt"

  # Admin password — fail hard if unset and stdin is not a terminal
  local admin_pass="${BOB_ADMIN_PASSWORD:-}"
  if [[ -z "${admin_pass}" ]]; then
    if [[ ! -t 0 ]]; then
      log_error "BOB_ADMIN_PASSWORD is not set and stdin is not a terminal — cannot prompt."
      log_error "Set BOB_ADMIN_PASSWORD in bob-autoinstall.env and re-run."
      exit 1
    fi
    printf '%b' "${_CW}Enter bob-admin@bob.ibm.com password: ${_CR}"
    read -rs admin_pass
    printf '\n'
    if [[ -z "${admin_pass}" ]]; then
      log_error "No password entered — aborting"
      exit 1
    fi
  fi

  # Wait for Keycloak pod to be Running+Ready and discover the container name
  local kc_container
  kc_container="$(_wait_keycloak_ready "${INSTANCE_NS}" "${BOB_KEYCLOAK_WAIT_TIMEOUT:-120}")"

  log_info "    Setting bob-admin@bob.ibm.com password via kcadm.sh"

  # Retrieve Keycloak bootstrap credentials
  local kc_pass
  kc_pass="$(oc get secret bob-keycloak-initial-admin -n "${INSTANCE_NS}" \
    -o jsonpath='{.data.password}' | base64 -d)"
  local kc_user
  kc_user="$(oc get secret bob-keycloak-initial-admin -n "${INSTANCE_NS}" \
    -o jsonpath='{.data.username}' | base64 -d)"

  # Authenticate kcadm
  _oc_exec -n "${INSTANCE_NS}" bob-keycloak-0 -c "${kc_container}" -- \
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://bob-keycloak-service.${INSTANCE_NS}.svc:8080 \
      --realm master \
      --user "${kc_user}" \
      --password "${kc_pass}" \
      --config /tmp/kcadm.config \
    2>&1 | tee -a "${BOB_LOG_FILE}"

  # Get bob-admin user ID (no python3: on Windows it is usually the Microsoft Store stub)
  local bob_admin_id uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  bob_admin_id="$(_oc_exec -n "${INSTANCE_NS}" bob-keycloak-0 -c "${kc_container}" -- \
    /opt/keycloak/bin/kcadm.sh get users -r bob \
      --config /tmp/kcadm.config \
      -q email=bob-admin@bob.ibm.com \
      --fields id --format csv --noquotes \
    2>/dev/null | tr -d '\r' | head -n1 || true)"
  if [[ ! "${bob_admin_id}" =~ ${uuid_re} ]]; then
    # Fallback: pull the first "id" out of the JSON output
    bob_admin_id="$(_oc_exec -n "${INSTANCE_NS}" bob-keycloak-0 -c "${kc_container}" -- \
      /opt/keycloak/bin/kcadm.sh get users -r bob \
        --config /tmp/kcadm.config \
        -q email=bob-admin@bob.ibm.com \
      2>/dev/null | tr -d '\r' \
      | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
  fi
  if [[ ! "${bob_admin_id}" =~ ${uuid_re} ]]; then
    log_error "Could not find user bob-admin@bob.ibm.com in Keycloak realm 'bob' (got: '${bob_admin_id}')"
    exit 1
  fi

  # Set password
  _oc_exec -n "${INSTANCE_NS}" bob-keycloak-0 -c "${kc_container}" -- \
    /opt/keycloak/bin/kcadm.sh set-password -r bob \
      --config /tmp/kcadm.config \
      --userid "${bob_admin_id}" \
      --new-password "${admin_pass}" \
    2>&1 | tee -a "${BOB_LOG_FILE}"

  # Mark email verified
  _oc_exec -n "${INSTANCE_NS}" bob-keycloak-0 -c "${kc_container}" -- \
    /opt/keycloak/bin/kcadm.sh update "users/${bob_admin_id}" -r bob \
      --config /tmp/kcadm.config \
      -s emailVerified=true \
    2>&1 | tee -a "${BOB_LOG_FILE}"

  log_info "    bob-admin@bob.ibm.com password set successfully"
}

# ── configure_idp ───────────────────────────────────────────────────────────────

# Create the BobIdp CR so users can log in. Without a BobIdp CR nobody can
# authenticate to the Admin UI, so this runs by default.
#
# Config file selection (first match wins):
#   1. BOB_IDP_CONFIG                      (explicit path, relative to this script dir)
#   2. <script dir>/config-idp.yaml        (if present)
#   3. a generated baseline: domains [bob.ibm.com], adminEmails [bob-admin@bob.ibm.com]
# Set BOB_SKIP_IDP_CONFIG=true to skip entirely (not recommended).
# OIDC (w3id) is not automated - configure it in the Admin UI afterwards.
IDP_CONFIG_SOURCE=""

configure_idp() {
  if [[ "${BOB_SKIP_IDP_CONFIG:-false}" == "true" ]]; then
    IDP_CONFIG_SOURCE="skipped"
    log_warn "==> §11 Skipping IdP configuration (BOB_SKIP_IDP_CONFIG=true)"
    log_warn "    No BobIdp will exist, so NOBODY can log in to the Admin UI until you create one:"
    log_warn "    - Run: ./bobctl configure-idp --config config-idp.yaml"
    log_warn "      (copy config-idp-template.yaml; keep bob.ibm.com and bob-admin@bob.ibm.com)"
    log_warn "    - OIDC (w3id): Admin UI /admin/idp -> Add IDP -> OIDC (needs a BobIdp first)"
    return
  fi

  local idp_config="${BOB_IDP_CONFIG:-}"
  if [[ -n "${idp_config}" ]]; then
    if [[ ! "${idp_config}" = /* ]]; then
      idp_config="${BOB_SCRIPT_DIR}/${idp_config}"
    fi
    if [[ ! -f "${idp_config}" ]]; then
      log_error "IdP config file not found: ${idp_config}"
      log_error "Set BOB_IDP_CONFIG correctly, or unset it to use the default baseline"
      exit 1
    fi
    IDP_CONFIG_SOURCE="${idp_config}"
  elif [[ -f "${BOB_SCRIPT_DIR}/config-idp.yaml" ]]; then
    idp_config="${BOB_SCRIPT_DIR}/config-idp.yaml"
    IDP_CONFIG_SOURCE="${idp_config}"
  else
    idp_config="${BOB_WORK_DIR:-${BOB_SCRIPT_DIR}/work}/config-idp-default.yaml"
    IDP_CONFIG_SOURCE="default baseline (bob.ibm.com only)"
  fi

  log_info "==> §11 Configuring BobIdp using ${IDP_CONFIG_SOURCE}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry_run "./bobctl configure-idp --config ${idp_config}"
    return
  fi

  if [[ "${IDP_CONFIG_SOURCE}" == default* ]]; then
    mkdir -p "$(dirname "${idp_config}")"
    {
      printf '%s\n' "# Generated by bob-autoinstall.sh - baseline BobIdp (bootstrap admin only)"
      printf '%s\n' "domains:"
      printf '%s\n' "  - bob.ibm.com"
      printf '%s\n' "adminEmails:"
      printf '%s\n' "  - bob-admin@bob.ibm.com"
    } > "${idp_config}"
  fi

  cd "${BOB_SCRIPT_DIR}"

  local wait_timeout="${BOB_IDP_WAIT_TIMEOUT:-600}"
  log_info "    Running bobctl configure-idp (timeout: ${wait_timeout}s)..."
  BOB_IDP_WAIT_TIMEOUT="${wait_timeout}" ./bobctl configure-idp --config "${idp_config}" 2>&1 | tee -a "${BOB_LOG_FILE}"

  local exit_code="${PIPESTATUS[0]}"
  if [[ "${exit_code}" -ne 0 ]]; then
    log_error "bobctl configure-idp failed (exit code ${exit_code})"
    log_error "Re-run manually: BOB_IDP_WAIT_TIMEOUT=${wait_timeout} ./bobctl configure-idp --config ${idp_config}"
    exit 1
  fi

  log_info "    BobIdp applied. Verify with: oc get bobidp -n ${INSTANCE_NS}"
}

# ── print_summary ─────────────────────────────────────────────────────────────

print_summary() {
  local cluster_domain
  cluster_domain="$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.status.domain}' 2>/dev/null || true)"

  local admin_url api_url
  if [[ -n "${cluster_domain}" ]]; then
    admin_url="https://bob.${INSTANCE_NS}.${cluster_domain}/admin"
    api_url="https://api.bob.${INSTANCE_NS}.${cluster_domain}"
  fi

  log_info ""
  log_info "════════════════════════════════════════════════════════════════"
  log_info "  IBM Bob install complete"
  log_info "════════════════════════════════════════════════════════════════"
  if [[ -n "${cluster_domain}" ]]; then
    log_info "  Admin UI:  ${admin_url}"
    log_info "  API:       ${api_url}"
  fi
  log_info "  CA cert:   ${HOME}/bob-ca.crt"
  log_info "  Log:       ${BOB_LOG_FILE}"
  case "${IDP_CONFIG_SOURCE:-}" in
    skipped)
      log_info "  IdP config:  SKIPPED - no BobIdp, login will NOT work until configured" ;;
    default*)
      log_info "  IdP config:  ${IDP_CONFIG_SOURCE}"
      log_info "  Login domains: bob.ibm.com only" ;;
    "")
      log_info "  IdP config:  dry-run / not applied" ;;
    *)
      log_info "  IdP config:  ${IDP_CONFIG_SOURCE}"
      log_info "  Login domains: as defined in the file above" ;;
  esac
  log_info "════════════════════════════════════════════════════════════════"
  log_info ""

  # ── 1. Trust the CA cert ───────────────────────────────────────────────────
  log_info "1. Trust the CA certificate"
  log_info "   The CA cert has been saved to: ${HOME}/bob-ca.crt"
  log_info "   Every user who connects to IBM Bob must trust this certificate."
  log_info ""
  local uname_out
  uname_out="$(uname -s 2>/dev/null || true)"
  if [[ "${uname_out}" == "Darwin" ]]; then
    log_info "   Run on this machine:"
    log_info "     sudo security add-trusted-cert -d -r trustRoot \\"
    log_info "       -k /Library/Keychains/System.keychain ${HOME}/bob-ca.crt"
  elif [[ "${uname_out}" == "Linux" ]]; then
    log_info "   Run on this machine:"
    log_info "     sudo cp ${HOME}/bob-ca.crt /usr/local/share/ca-certificates/bob-ca.crt"
    log_info "     sudo update-ca-certificates"
  elif _is_windows_shell; then
    local win_ca
    win_ca="$(cygpath -w "${HOME}/bob-ca.crt" 2>/dev/null || printf '%s' "${HOME}/bob-ca.crt")"
    log_info "   Windows — do NOT skip this step; untrusted TLS to the gateway can trigger"
    log_info "   a security alert. Pick ONE option:"
    log_info "     A. PowerShell as Administrator (all users on this PC):"
    log_info "          certutil -addstore -f Root \"${win_ca}\""
    log_info "     B. Normal PowerShell (current user only; confirm the security prompt):"
    log_info "          certutil -user -addstore Root \"${win_ca}\""
    log_info "     C. GUI: double-click the file -> Install Certificate -> Local Machine (or"
    log_info "          Current User) -> Place all certificates in: Trusted Root Certification"
    log_info "          Authorities -> Finish."
    log_info "   Verify: certutil -store Root | findstr /i bob   (or run certmgr.msc / certlm.msc)"
  else
    log_info "   On macOS:"
    log_info "     sudo security add-trusted-cert -d -r trustRoot \\"
    log_info "       -k /Library/Keychains/System.keychain ${HOME}/bob-ca.crt"
    log_info "   On Linux:"
    log_info "     sudo cp ${HOME}/bob-ca.crt /usr/local/share/ca-certificates/bob-ca.crt"
    log_info "     sudo update-ca-certificates"
  fi
  log_info ""

  # ── 2. Point Bob at the gateway ────────────────────────────────────────────
  log_info "2. Point Bob Shell / Bob IDE at this cluster"
  log_info "   Set gatewayUrl in ~/.bob/settings/settings.json (shared by Shell and IDE):"
  if [[ -n "${api_url}" ]]; then
    log_info "     { \"gatewayUrl\": \"${api_url}/\" }"
  else
    log_info "     { \"gatewayUrl\": \"https://api.bob.<instance-ns>.<cluster-domain>/\" }"
  fi
  log_info "   To switch back to Bob SaaS, rename the key (e.g. \"gatewayUrl-old\") and restart Bob."
  log_info ""
  log_info "   If the cluster uses a private CA, also add this to ~/.zshrc (or ~/.bashrc):"
  log_info "     export NODE_EXTRA_CA_CERTS=\"\${HOME}/bob-ca.crt\""
  if _is_windows_shell; then
    local win_ca_env
    win_ca_env="$(cygpath -w "${HOME}/bob-ca.crt" 2>/dev/null || printf '%s' "${HOME}/bob-ca.crt")"
    log_info "   Windows (PowerShell, persists for your user; restart Bob/terminals afterwards):"
    log_info "     setx NODE_EXTRA_CA_CERTS \"${win_ca_env}\""
  fi
  log_info ""

  # ── 3. Sign in ─────────────────────────────────────────────────────────────
  log_info "3. Sign in"
  log_info "   Run 'bob' (or open Bob IDE) and sign in through your IdP / SSO."
  log_info "   No API key is required. (Optional: API keys can still be created in"
  log_info "   the Admin UI for headless / CI use.)"
  log_info ""

  # ── 4. End-to-end test ────────────────────────────────────────────────────
  log_info "4. Run an end-to-end test"
  log_info "   After signing in once, verify Bob is reachable and the TLS certificate is trusted:"
  log_info "     bob run --accept-license \"Reply with exactly one word: hello\""
  log_info ""
  log_info "   Expected: a single-word response. Any TLS or auth error means the CA"
  log_info "   cert is not trusted or gatewayUrl is not set correctly."
  log_info ""

  # ── 5. IdP / SSO configuration ─────────────────────────────────────────────
  if [[ "${IDP_CONFIG_SOURCE:-}" == "skipped" || "${IDP_CONFIG_SOURCE:-}" == default* ]]; then
    log_info "5. Allow other email domains to log in (optional)"
    log_info "   Currently only 'bob.ibm.com' (bootstrap admin) can log in."
    log_info "   SSO/OIDC provisioning (e.g. w3id) requires two email addresses: a technical"
    log_info "   contact and a business contact. Have both ready before you start."
    log_info ""
    log_info "   Option A - LDAP/AD or extra domains (automated):"
    log_info "     1. cp config-idp-template.yaml config-idp.yaml and edit it"
    log_info "        (always keep bob.ibm.com in domains and bob-admin@bob.ibm.com in adminEmails)"
    log_info "     2. Create referenced secrets (bind password, LDAPS CA cert) in the cluster"
    log_info "     3. Run: ./bobctl configure-idp --config config-idp.yaml"
    log_info "     4. Verify: oc get bobidp -n ${INSTANCE_NS}   (READY=True)"
    log_info ""
    log_info "   Option B - OIDC / w3id (manual via Admin UI):"
    log_info "     1. Open Admin UI: ${admin_url:-https://bob.ibm-bob.<cluster-domain>/admin}"
    log_info "     2. Go to /admin/idp -> Add IDP -> OIDC configuration"
    log_info "     3. Set Issuer URL: https://login.w3.ibm.com/oidc/endpoint/default"
    log_info "     4. Add your email domains, then verify domains (docs/04-manual-install.md §11)"
    log_info ""
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  log_info "IBM Bob autoinstall — $(date)"
  log_info "Log file: ${BOB_LOG_FILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY-RUN mode: no changes will be made"
  fi
  log_info ""

  check_prerequisites
  install_cert_manager
  deploy_nfs_provisioner
  validate_config_files
  generate_cluster_resources
  create_pull_secrets
  run_smoke_test
  run_install
  configure_idp
  post_install_admin
  print_summary
}

main "$@"
