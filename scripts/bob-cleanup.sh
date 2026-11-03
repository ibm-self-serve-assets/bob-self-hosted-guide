#!/usr/bin/env bash
# bob-cleanup.sh — Full cluster cleanup for a dedicated IBM Bob OpenShift cluster.
# Returns the cluster to its post-provisioning, pre-Bob-install state so Bob
# can be reinstalled from scratch.
#
# Usage: ./scripts/bob-cleanup.sh [--dry-run] [--yes] [--install-dir <path>]

set -eo pipefail

# ── 1. Locate the install package ────────────────────────────────────────────
# SCRIPT_DIR is this script's own directory (workspace root / scripts/).
# The install package lives one level up, named ibm-bob-install-*.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse flags ──────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_CONFIRM=false
INSTALL_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes)
      SKIP_CONFIRM=true
      shift
      ;;
    --install-dir)
      if [[ -z "${2:-}" ]]; then
        printf '%s\n' "ERROR: --install-dir requires a path argument" >&2
        exit 2
      fi
      INSTALL_DIR_OVERRIDE="$2"
      shift 2
      ;;
    *)
      printf '%s\n' "ERROR: Unknown option: $1" >&2
      printf '%s\n' "Usage: $0 [--dry-run] [--yes] [--install-dir <path>]" >&2
      exit 2
      ;;
  esac
done

export DRY_RUN

if [[ -n "$INSTALL_DIR_OVERRIDE" ]]; then
  BOB_DIR="$INSTALL_DIR_OVERRIDE"
elif [[ -d "$WORKSPACE_ROOT/ibm-bob-install-20260924-163534" ]]; then
  BOB_DIR="$WORKSPACE_ROOT/ibm-bob-install-20260924-163534"
else
  # Glob for ibm-bob-install-* directories at the workspace root.
  shopt -s nullglob
  install_matches=("$WORKSPACE_ROOT"/ibm-bob-install-*/)
  shopt -u nullglob

  match_count=${#install_matches[@]}
  if [[ $match_count -eq 0 ]]; then
    printf '%s\n' "ERROR: No install package directory (ibm-bob-install-*) found at $WORKSPACE_ROOT" >&2
    printf '%s\n' "       Specify the path with: $0 --install-dir <path>" >&2
    exit 1
  elif [[ $match_count -gt 1 ]]; then
    printf '%s\n' "ERROR: Multiple install package directories found:" >&2
    for m in "${install_matches[@]}"; do
      printf '  - %s\n' "$m"
    done
    printf '%s\n' "       Specify which to use with: $0 --install-dir <path>" >&2
    exit 1
  fi

  # Strip trailing slash from glob result.
  BOB_DIR="${install_matches[0]%/}"
fi

export BOB_DIR

# ── 2. Set up environment variables (same pattern as bobctl) ─────────────────
export BOB_LOG_DIR="${BOB_LOG_DIR:-$WORKSPACE_ROOT/logs}"
export BOB_WORK_DIR="${BOB_WORK_DIR:-$BOB_DIR/work}"
export BOB_CONFIG_FILE="${BOB_CONFIG_FILE:-$BOB_DIR/config.yaml}"

# ── 3. Source shared helpers ─────────────────────────────────────────────────
# bin/utils.sh provides: log_info, log_warn, log_error, log_dry_run,
#   check_helm, check_oc_login, validate_namespace, read_config_value, usage
source "$BOB_DIR/bin/utils.sh"

# bin/configure-tls.sh provides: _get_bob_cr_name
source "$BOB_DIR/bin/configure-tls.sh"

# bin/install.sh provides: generate_cluster_resources
source "$BOB_DIR/bin/install.sh"

# ── 4. Set up LOG_FILE ───────────────────────────────────────────────────────
LOG_TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$BOB_LOG_DIR/bobctl-cleanup-${LOG_TIMESTAMP}.log"
mkdir -p "$BOB_LOG_DIR"
touch "$LOG_FILE"
export LOG_FILE

log_info "Log file: $LOG_FILE"
log_info "Install package: $BOB_DIR"
log_info "Config file: $BOB_CONFIG_FILE"

# ── 5. Main cleanup ──────────────────────────────────────────────────────────
main() {
  log_info "=== Bob Cluster Cleanup ==="
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Dry-run mode enabled — no changes will be made to the cluster"
  fi

  # --- Pre-flight checks ---
  check_helm
  check_oc_login

  # --- Determine namespaces ---
  # If config.yaml exists, read from it; otherwise fall back to template or defaults.
  local instanceNamespace operatorNamespace
  local source_config="$BOB_CONFIG_FILE"

  if [[ ! -f "$source_config" ]]; then
    if [[ -f "$BOB_DIR/config-template.yaml" ]]; then
      source_config="$BOB_DIR/config-template.yaml"
      log_info "config.yaml not found — reading default namespaces from config-template.yaml"
    fi
  fi

  if [[ -f "$source_config" ]]; then
    operatorNamespace=$(read_config_value "operatorNamespace" "$source_config")
    instanceNamespace=$(read_config_value "instanceNamespace" "$source_config")
  fi

  operatorNamespace="${operatorNamespace:-ibm-bob-operators}"
  instanceNamespace="${instanceNamespace:-ibm-bob}"

  # --- Determine the Bob CR name ---
  # Look up the CR name if present on the cluster; if not found (e.g. already deleted
  # or partial install), continue gracefully with "" so steps 1 & 2 skip cleanly.
  local cr_name=""
  if [[ "$DRY_RUN" == "true" ]]; then
    cr_name="bob-cr"
  else
    local full_name
    full_name=$(oc get bob -n "$instanceNamespace" -o name 2>/dev/null | head -1 || true)
    cr_name="${full_name#*/}"
  fi

  log_info "Namespace (operator):   $operatorNamespace"
  log_info "Namespace (instance):   $instanceNamespace"
  log_info "Bob CR name:            ${cr_name}"

  # --- Confirmation prompt (unless --yes) ---
  if [[ "$SKIP_CONFIRM" != "true" && "$DRY_RUN" != "true" ]]; then
    log_warn "WARNING: This will permanently delete ALL IBM Bob resources, including:"
    log_warn "  - Bob CR and the operator's reconciled child resources"
    log_warn "  - Helm release 'ibm-bob' (operator deployment, RBAC, configmaps, secrets)"
    log_warn "  - Non-Helm extras (entitlement pull secrets, bob-metrics-forwarder)"
    log_warn "  - ALL PVCs in both namespaces"
    log_warn "  - BOTH namespaces: '$operatorNamespace' and '$instanceNamespace'"
    log_warn "  - Cluster-scoped resources (CRDs, ClusterRoles, webhook configs)"
    log_warn "This operation cannot be undone."
    printf 'Continue? [y/N] '
    read -r reply
    if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
      log_info "Aborted."
      exit 0
    fi
  fi

  # ── Step 1: Delete the Bob CR (so the operator can clean up its children) ──
  if [[ -n "$cr_name" ]]; then
    log_info "Step 1: Deleting Bob CR '${cr_name}' in namespace '${instanceNamespace}'..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry_run "Would delete bob/${cr_name} in namespace '${instanceNamespace}'"
    else
      oc delete bob "${cr_name}" -n "${instanceNamespace}" --ignore-not-found 2>&1 | tee -a "$LOG_FILE"
    fi

    # ── Step 2: Wait for Bob CR deletion to complete ──────────────────────────
    log_info "Step 2: Waiting for Bob CR '${cr_name}' to be deleted..."
    local bob_cr_wait_timeout="${BOB_INSTALL_TIMEOUT:-300}"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry_run "Would wait for deletion of bob/${cr_name} (timeout: ${bob_cr_wait_timeout}s)"
    else
      if ! oc wait --for=delete "bob/${cr_name}" -n "${instanceNamespace}" --timeout="${bob_cr_wait_timeout}s" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Timed out waiting for Bob CR '${cr_name}' to be deleted (timeout: ${bob_cr_wait_timeout}s)"
        log_warn "Remaining finalizers on the CR:"
        # Print finalizers and status so the user can diagnose what is stuck.
        oc get bob "${cr_name}" -n "${instanceNamespace}" -o jsonpath='{.metadata.finalizers}' 2>/dev/null | tee -a "$LOG_FILE" || true
        log_info ""
        log_info "The operator may still be processing finalizers. Check operator logs:"
        log_info "  oc logs -n ${operatorNamespace} deployment/ibm-bob-operator -f"
        log_error "Aborting before helm uninstall — the operator must be alive to process finalizers."
        exit 1
      fi
      log_info "Bob CR '${cr_name}' has been deleted."
    fi
  else
    log_info "Step 1: No Bob CR found in namespace '${instanceNamespace}' — skipping"
    log_info "Step 2: No Bob CR to wait on — skipping"
  fi

  # ── Step 3: Helm uninstall ────────────────────────────────────────────────
  log_info "Step 3: Uninstalling Helm release 'ibm-bob' in namespace '${operatorNamespace}'..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check if Helm release 'ibm-bob' exists, then uninstall it"
  else
    # Check if the release exists; skip uninstall if it doesn't (idempotent).
    if helm list -n "${operatorNamespace}" --short 2>/dev/null | grep -q "^ibm-bob$"; then
      helm uninstall ibm-bob -n "${operatorNamespace}" 2>&1 | tee -a "$LOG_FILE"
      log_info "Helm release 'ibm-bob' uninstalled."
    else
      log_info "Helm release 'ibm-bob' not found — skipping uninstall (idempotent)"
    fi
  fi

  # ── Step 4: Delete non-Helm extras (entitlement secrets + metrics forwarder)
  log_info "Step 4: Deleting non-Helm extras..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would delete secrets 'ibm-entitlement-key' and 'ibm-prod-entitlement-key' in both namespaces"
    log_dry_run "Would delete deployment 'bob-metrics-forwarder' in namespace '${instanceNamespace}'"
  else
    # Entitlement pull secrets created by bob-autoinstall.sh in both namespaces.
    for ns in "${operatorNamespace}" "${instanceNamespace}"; do
      oc delete secret ibm-entitlement-key -n "${ns}" --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true
      oc delete secret ibm-prod-entitlement-key -n "${ns}" --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true
    done

    # bob-metrics-forwarder Deployment (Appendix F fix).
    oc delete deployment bob-metrics-forwarder -n "${instanceNamespace}" --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # ── Step 5: Delete all PVCs in both namespaces ─────────────────────────────
  log_info "Step 5: Deleting all PVCs in both namespaces..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would delete all PVCs in namespaces: '${operatorNamespace}', '${instanceNamespace}'"
  else
    for ns in "${operatorNamespace}" "${instanceNamespace}"; do
      oc delete pvc --all -n "${ns}" --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true
    done
  fi

  # ── Step 6: Delete both namespaces ─────────────────────────────────────────
  log_info "Step 6: Deleting namespaces '${operatorNamespace}' and '${instanceNamespace}'..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would delete namespaces: '${operatorNamespace}', '${instanceNamespace}'"
  else
    oc delete namespace "${operatorNamespace}" "${instanceNamespace}" --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # ── Step 7: Delete cluster-scoped resources from work/cluster-resources.yaml
  log_info "Step 7: Deleting cluster-scoped resources (CRDs, ClusterRoles, webhooks)..."

  local cluster_resources_file="$BOB_WORK_DIR/cluster-resources.yaml"

  # Regenerate cluster-resources.yaml if it doesn't exist.
  # Use helm template directly with config-template.yaml fallback so config.yaml is not required.
  if [[ ! -f "$cluster_resources_file" ]]; then
    log_warn "work/cluster-resources.yaml not found — rendering cluster-scoped chart templates..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry_run "Would render cluster-scoped resources to $cluster_resources_file"
    else
      mkdir -p "$BOB_WORK_DIR"
      local render_config="$source_config"
      local clusterChartDir="$BOB_DIR/charts/ibm-bob-cluster-scoped"
      local helm_render_args=(
        template ibm-bob-cluster-scoped "$clusterChartDir"
        -f "$render_config"
        --set "opencontent-opensearch.enabled=true"
      )
      if ! helm "${helm_render_args[@]}" > "$cluster_resources_file" 2>> "$LOG_FILE"; then
        log_error "Failed to render cluster-scoped resources"
        exit 1
      fi
      log_info "Cluster-scoped resources rendered to: $cluster_resources_file"
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would filter Namespace resources from $cluster_resources_file and delete the rest with 'oc delete -f -'"
  else
    # Filter out Namespace resources (already deleted in Step 6) to avoid conflicts,
    # then delete the remaining cluster-scoped resources.
    if [[ -f "$cluster_resources_file" ]]; then
      # Use grep -v to skip yaml documents that start with 'kind: Namespace'
      # (the '---' separator is preserved; only the Namespace kind block is removed).
      oc delete --ignore-not-found -f - <<EOF 2>&1 | tee -a "$LOG_FILE"
$(awk 'BEGIN { doc=""; first=1 } /^---/ { if (doc != "") { if (doc !~ /kind:[[:space:]]+Namespace/) { if (!first) print "---"; printf "%s", doc; first=0 } } doc = ""; next } { doc = doc $0 "\n" } END { if (doc != "") { if (doc !~ /kind:[[:space:]]+Namespace/) { if (!first) print "---"; printf "%s", doc; first=0 } } }' "$cluster_resources_file")
EOF
      log_info "Cluster-scoped resources deleted."
    else
      log_warn "cluster-resources.yaml still not available after regeneration attempt — skipping cluster-scoped cleanup."
      log_warn "Please run: ./bobctl generate-cluster-resources && oc apply -f work/cluster-resources.yaml --force-conflicts --server-side"
      log_warn "Then manually delete the cluster-scoped resources."
    fi
  fi

  # ── Step 8: Verification ───────────────────────────────────────────────────
  log_info ""
  log_info "=== Verification ==="
  verify_cleanup

  # ── Print manual verification commands ────────────────────────────────────
  log_info ""
  log_info "=== Manual Verification Commands ==="
  log_info "  # Check for remaining Bob CRs:"
  log_info "  oc get bob -A"
  log_info "  # Check for remaining Helm releases:"
  log_info "  helm list -A | grep ibm-bob"
  log_info "  # Check for remaining CRDs:"
  log_info "  oc get crd | grep -iE 'bob|keycloak|pg.ibm|redis.cloud|opensearch.cloud|ibmlicensing|ibmusagemetering'"
  log_info "  # Check for remaining PVCs:"
  log_info "  oc get pvc -n ${operatorNamespace} -n ${instanceNamespace} 2>/dev/null || true"
  log_info "  # Check for remaining namespaces:"
  log_info "  oc get namespace ${operatorNamespace} ${instanceNamespace} 2>/dev/null || true"
  log_info ""
  log_info "Cleanup complete. Log file: $LOG_FILE"
}

# ── verify_cleanup ────────────────────────────────────────────────────────────
# Runs checks on each resource category and prints ✓/✗ status.
verify_cleanup() {
  local all_clean=true

  # 1. Bob CR
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check: Bob CR deleted in '${instanceNamespace}'"
  else
    if oc get bob -n "${instanceNamespace}" --ignore-not-found 2>/dev/null | grep -q .; then
      log_info "  ✗ Bob CR still present in namespace '${instanceNamespace}'"
      all_clean=false
    else
      log_info "  ✓ No Bob CRs found in namespace '${instanceNamespace}'"
    fi
  fi

  # 2. Helm release
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check: Helm release 'ibm-bob' absent in '${operatorNamespace}'"
  else
    if helm list -n "${operatorNamespace}" --short 2>/dev/null | grep -q "^ibm-bob$"; then
      log_info "  ✗ Helm release 'ibm-bob' still present in namespace '${operatorNamespace}'"
      all_clean=false
    else
      log_info "  ✓ No Helm release 'ibm-bob' found in namespace '${operatorNamespace}'"
    fi
  fi

  # 3. Non-Helm extras (entitlement secrets + metrics forwarder)
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check: entitlement secrets and bob-metrics-forwarder absent"
  else
    local leftover_extras=false
    for ns in "${operatorNamespace}" "${instanceNamespace}"; do
      if oc get secret ibm-entitlement-key -n "${ns}" --ignore-not-found 2>/dev/null | grep -q .; then
        log_info "  ✗ Secret 'ibm-entitlement-key' still present in namespace '${ns}'"
        leftover_extras=true
        all_clean=false
      fi
      if oc get secret ibm-prod-entitlement-key -n "${ns}" --ignore-not-found 2>/dev/null | grep -q .; then
        log_info "  ✗ Secret 'ibm-prod-entitlement-key' still present in namespace '${ns}'"
        leftover_extras=true
        all_clean=false
      fi
    done
    if oc get deployment bob-metrics-forwarder -n "${instanceNamespace}" --ignore-not-found 2>/dev/null | grep -q .; then
      log_info "  ✗ Deployment 'bob-metrics-forwarder' still present in namespace '${instanceNamespace}'"
      all_clean=false
    fi
    if [[ "$leftover_extras" != "true" ]]; then
      log_info "  ✓ No non-Helm extras (entitlement secrets, metrics forwarder) found"
    fi
  fi

  # 4. PVCs
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check: no PVCs in both namespaces"
  else
    local leftover_pvcs=false
    for ns in "${operatorNamespace}" "${instanceNamespace}"; do
      if oc get pvc -n "${ns}" --ignore-not-found 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "  ✗ PVCs still present in namespace '${ns}':"
        oc get pvc -n "${ns}" --ignore-not-found 2>/dev/null | tail -n +2 | tee -a "$LOG_FILE"
        leftover_pvcs=true
        all_clean=false
      fi
    done
    if [[ "$leftover_pvcs" != "true" ]]; then
      log_info "  ✓ No PVCs found in either namespace"
    fi
  fi

  # 5. Namespaces
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check: both namespaces deleted"
  else
    local leftover_ns=false
    for ns in "${operatorNamespace}" "${instanceNamespace}"; do
      if oc get namespace "${ns}" --ignore-not-found 2>/dev/null | grep -q .; then
        log_info "  ✗ Namespace '${ns}' still exists"
        leftover_ns=true
        all_clean=false
      fi
    done
    if [[ "$leftover_ns" != "true" ]]; then
      log_info "  ✓ Both namespaces ('${operatorNamespace}', '${instanceNamespace}') have been deleted"
    fi
  fi

  # 6. Cluster-scoped resources (CRDs)
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would check: no Bob-related CRDs remain"
  else
    local leftover_crds
    leftover_crds=$(oc get crd 2>/dev/null | grep -iE 'bob\.ibm|bobidp\.bob|pg\.ibm\.com|redis\.ibm\.com|opensearch\.ibm|keycloak\.org|ibmlicensing|ibmusagemetering' || true)
    if [[ -n "$leftover_crds" ]]; then
      log_info "  ✗ Bob-related CRDs still present:"
      printf '%s\n' "$leftover_crds" | tee -a "$LOG_FILE"
      all_clean=false
    else
      log_info "  ✓ No Bob-related CRDs found"
    fi
  fi

  if [[ "$all_clean" == "true" ]]; then
    log_info ""
    log_info "✓ Cluster is clean — all Bob resources have been removed."
  else
    log_warn ""
    log_warn "✗ Cluster is NOT fully clean — some resources remain (see above)."
  fi
}

# Run main with all passed flags.
main "$@"
