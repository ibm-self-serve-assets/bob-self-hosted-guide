#!/usr/bin/env bash
# cluster-snapshot.sh — Structured IBM Bob cluster snapshot for AI-assisted analysis.
# Captures node layout, pod placement by node (all namespaces), resource allocation,
# and key Bob diagnostics. Output is designed to be pasted directly into a chat context.
#
# Usage: ./scripts/cluster-snapshot.sh [--out <file>]
#        ./scripts/cluster-snapshot.sh --out docs/diagrams/new-cluster-snapshot.txt
#
# Requires: oc (logged in), cluster-admin or equivalent view permissions.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_FILE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Tee to file if --out was given, otherwise stdout only
if [[ -n "$OUT_FILE" ]]; then
  exec > >(tee "$OUT_FILE") 2>&1
fi

# ── helpers ──────────────────────────────────────────────────────────────────
section()    { printf '\n══════════════════════════════════════════════════════\n%s\n══════════════════════════════════════════════════════\n' "$*"; }
subsection() { printf '\n── %s ──\n' "$*"; }

BOB_NS="ibm-bob"
OPS_NS="ibm-bob-operators"
COLLECTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Detect Bob instance namespace from the Bob CR if possible
BOB_NS_DETECTED="$(oc get bob --all-namespaces --no-headers 2>/dev/null | awk '{print $1}' | head -1)"
[[ -n "$BOB_NS_DETECTED" ]] && BOB_NS="$BOB_NS_DETECTED"

echo "IBM Bob Cluster Snapshot"
echo "Collected : $COLLECTED_AT"
echo "Bob NS    : $BOB_NS"
echo "Ops NS    : $OPS_NS"

# ── 1. NODES ─────────────────────────────────────────────────────────────────
section "1. NODES"
oc get nodes -o wide
echo ""
oc get nodes -o custom-columns=\
"NAME:.metadata.name,\
ZONE:.metadata.labels.topology\.kubernetes\.io/zone,\
REGION:.metadata.labels.topology\.kubernetes\.io/region,\
RACK:.metadata.labels.topology\.kubernetes\.io/rack,\
CPU:.status.capacity.cpu,\
MEMORY:.status.capacity.memory,\
ARCH:.status.nodeInfo.architecture"

# ── 2. POD PLACEMENT — grouped by node (ALL namespaces) ──────────────────────
section "2. POD PLACEMENT — all namespaces, grouped by node"

WORKERS="$(oc get nodes --no-headers -l node-role.kubernetes.io/worker \
  -o custom-columns="NAME:.metadata.name" | sort)"

for node in $WORKERS; do
  subsection "NODE: $node"
  printf "%-50s %-40s %-12s %-8s %s\n" "POD" "NAMESPACE" "STATUS" "RESTARTS" "AGE"
  printf "%-50s %-40s %-12s %-8s %s\n" "---" "---------" "------" "--------" "---"
  oc get pods -A -o wide --field-selector "spec.nodeName=${node}" --no-headers \
    | awk '{printf "%-50s %-40s %-12s %-8s %s\n", $2, $1, $4, $5, $6}' \
    | sort -k2
done

# ── 3. POD PLACEMENT — ibm-bob (with IPs, as before) ─────────────────────────
section "3. POD PLACEMENT — $BOB_NS (detail)"
printf "%-50s %-12s %-22s %-16s %-10s %s\n" "NAME" "STATUS" "NODE" "IP" "RESTARTS" "AGE"
oc get pods -n "$BOB_NS" -o wide \
  --sort-by=.spec.nodeName \
  --no-headers \
  | awk '{printf "%-50s %-12s %-22s %-16s %-10s %s\n", $1, $3, $7, $6, $4, $8}'

# ── 4. POD PLACEMENT — ibm-bob-operators (with IPs) ──────────────────────────
section "4. POD PLACEMENT — $OPS_NS (detail)"
printf "%-50s %-12s %-22s %-16s %-10s %s\n" "NAME" "STATUS" "NODE" "IP" "RESTARTS" "AGE"
oc get pods -n "$OPS_NS" -o wide \
  --sort-by=.spec.nodeName \
  --no-headers \
  | awk '{printf "%-50s %-12s %-22s %-16s %-10s %s\n", $1, $3, $7, $6, $4, $8}'

# ── 5. NAMESPACE INVENTORY ───────────────────────────────────────────────────
section "5. NAMESPACE INVENTORY"
echo "--- Non-system namespaces (excluding kube-* and openshift-*) ---"
oc get namespaces --no-headers \
  | awk '$1 !~ /^(kube|openshift)/ {print $1, $2, $3}' \
  | column -t

echo ""
echo "--- All namespaces ---"
oc get namespaces --no-headers | column -t

# ── 6. NODE RESOURCE ALLOCATION ──────────────────────────────────────────────
section "6. NODE RESOURCE ALLOCATION (requests vs capacity)"
for node in $WORKERS; do
  subsection "$node"
  oc describe node "$node" \
    | awk '/^Allocated resources:/,/^Events:/' \
    | grep -v "^Events:" \
    | head -20
done

# ── 7. STATEFULSETS & DEPLOYMENTS — ibm-bob ──────────────────────────────────
section "7. STATEFULSETS — $BOB_NS"
oc get statefulsets -n "$BOB_NS" -o wide

section "7b. DEPLOYMENTS — $BOB_NS"
oc get deployments -n "$BOB_NS" -o wide

# ── 8. BOB CUSTOM RESOURCE ───────────────────────────────────────────────────
section "8. BOB CUSTOM RESOURCE"
oc get bob -n "$BOB_NS" -o yaml 2>/dev/null || echo "(no Bob CR found in $BOB_NS)"

# ── 9. RESOURCE REQUESTS & LIMITS — ibm-bob ──────────────────────────────────
section "9. RESOURCE REQUESTS & LIMITS — $BOB_NS"
printf "%-52s %-22s %-12s %-12s %-12s %s\n" "POD" "CONTAINER" "CPU_REQ" "CPU_LIM" "MEM_REQ" "MEM_LIM"
oc get pods -n "$BOB_NS" --no-headers -o custom-columns="NAME:.metadata.name" \
  | while read -r pod; do
      oc get pod "$pod" -n "$BOB_NS" -o json 2>/dev/null \
        | jq -r --arg pod "$pod" '
            .spec.containers[] |
            [$pod, .name,
             (.resources.requests.cpu // "-"),
             (.resources.limits.cpu // "-"),
             (.resources.requests.memory // "-"),
             (.resources.limits.memory // "-")]
            | @tsv' \
        | awk '{printf "%-52s %-22s %-12s %-12s %-12s %s\n", $1,$2,$3,$4,$5,$6}'
    done

# ── 10. AFFINITY & TOPOLOGY SPREAD — ibm-bob ─────────────────────────────────
section "10. AFFINITY & TOPOLOGY SPREAD CONSTRAINTS — $BOB_NS"
oc get pods -n "$BOB_NS" --no-headers -o custom-columns="NAME:.metadata.name" \
  | while read -r pod; do
      echo ""
      echo "--- $pod"
      AFFINITY="$(oc get pod "$pod" -n "$BOB_NS" -o jsonpath='{.spec.affinity}' 2>/dev/null)"
      TSC="$(oc get pod "$pod" -n "$BOB_NS" -o jsonpath='{.spec.topologySpreadConstraints}' 2>/dev/null)"
      [[ -n "$AFFINITY" ]] && echo "  affinity: $(echo "$AFFINITY" | python3 -m json.tool 2>/dev/null || echo "$AFFINITY")"
      [[ -n "$TSC" ]]      && echo "  topologySpreadConstraints: $(echo "$TSC" | python3 -m json.tool 2>/dev/null || echo "$TSC")"
      [[ -z "$AFFINITY" && -z "$TSC" ]] && echo "  (none)"
    done

# ── 11. STORAGE ───────────────────────────────────────────────────────────────
section "11. STORAGE CLASSES (cluster-wide)"
oc get storageclasses

section "11b. PERSISTENT VOLUME CLAIMS — $BOB_NS"
oc get pvc -n "$BOB_NS" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage,STORAGECLASS:.spec.storageClassName,ACCESS:.spec.accessModes[0],VOLUME:.spec.volumeName"

section "11c. PERSISTENT VOLUMES (bound to $BOB_NS)"
oc get pv -o json \
  | jq -r --arg ns "$BOB_NS" '
      .items[] | select(.spec.claimRef.namespace==$ns) |
      [.metadata.name, .spec.capacity.storage,
       .spec.accessModes[0], .spec.storageClassName,
       (.spec.claimRef.namespace + "/" + .spec.claimRef.name),
       .spec.persistentVolumeReclaimPolicy] | @tsv' \
  | column -t

# ── 12. SERVICES & ROUTES ─────────────────────────────────────────────────────
section "12. SERVICES — $BOB_NS"
oc get svc -n "$BOB_NS" \
  -o custom-columns="NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,PORT:.spec.ports[*].port,SELECTOR:.spec.selector"

section "12b. ROUTES — $BOB_NS"
oc get routes -n "$BOB_NS" \
  -o custom-columns="NAME:.metadata.name,HOST:.spec.host,PORT:.spec.port.targetPort,TLS:.spec.tls.termination,SERVICE:.spec.to.name"

# ── 13. EVENTS — warnings only ───────────────────────────────────────────────
section "13. EVENTS — $BOB_NS (warnings only)"
oc get events -n "$BOB_NS" \
  --field-selector type=Warning \
  --sort-by='.lastTimestamp' \
  2>/dev/null | tail -30 || echo "(no warnings)"

section "13b. EVENTS — $OPS_NS (warnings only)"
oc get events -n "$OPS_NS" \
  --field-selector type=Warning \
  --sort-by='.lastTimestamp' \
  2>/dev/null | tail -20 || echo "(no warnings)"

echo ""
echo "══ Snapshot complete: $COLLECTED_AT ══"
[[ -n "$OUT_FILE" ]] && echo "Saved to: $OUT_FILE"
