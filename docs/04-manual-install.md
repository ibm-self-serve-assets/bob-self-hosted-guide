# IBM Bob — manual install walkthrough

> **Scope:** Install IBM Bob on a TechZone OpenShift cluster step by step, verify the
> installation, add users, and run an end-to-end smoke test.
>
> **Prerequisites:** Complete the first four guides before starting here:
> - [TechZone cluster provisioning](00-techzone-cluster-provisioning.md)
> - [Workstation prerequisites](01-workstation-prereqs.md)
> - [Obtain your IBM entitlement key](02-entitlement-key.md)
> - [Pre-install configuration — config files](03-pre-install-config.md)

**Part of the IBM Bob on TechZone install series:**

1. [TechZone cluster provisioning](00-techzone-cluster-provisioning.md)
2. [Workstation prerequisites](01-workstation-prereqs.md)
3. [Obtain your IBM entitlement key](02-entitlement-key.md)
4. [Pre-install configuration — config files](03-pre-install-config.md)
5. **Manual install walkthrough** ← you are here

---

## In This Guide

This guide continues from the previous guides. The earlier guides cover these sections:

| Section | Covered in |
|---|---|
| §1 — Provision a TechZone cluster | [`00-techzone-cluster-provisioning.md`](00-techzone-cluster-provisioning.md) |
| §2 — Workstation prerequisites | [`01-workstation-prereqs.md`](01-workstation-prereqs.md) |
| §4 — Verify registry reachability, storage classes | [`03-pre-install-config.md`](03-pre-install-config.md) |

**What this guide covers:**
- §3 — Install cert-manager
- §6 — Generate and apply cluster-scoped resources
- §7 — Install Bob
- §8 — Verify the installation
- §9 — Post-install: extract CA certificate
- §10 — Post-install: set bootstrap admin password
- §11 — Post-install: add users
- §12 — End-to-end verification with bob-shell

---

## §3 — Install cert-manager

Bob requires cert-manager v1.14+ for TLS certificate provisioning. The installation
uses the **Red Hat cert-manager Operator** — OLM-managed and integrated with the
standard OpenShift operator lifecycle.

First, check whether cert-manager is already installed:

```bash
oc get crd certificates.cert-manager.io 2>/dev/null \
  && echo "cert-manager already installed — check version below" \
  || echo "cert-manager not found — install required"
```

If already installed, verify the version meets the v1.14+ minimum:

```bash
oc get csv -n cert-manager-operator \
  -o jsonpath='{.items[0].spec.version}'; echo
```

If cert-manager is **not** installed, continue with the CLI install below.

> On production accounts where OperatorHub is accessible in the web console, you can
> install via the UI instead — see
> [Appendix G — Install cert-manager via OperatorHub web console](#appendix-g--install-cert-manager-via-operatorhub-web-console).

### Install via CLI

```bash
# Create the operator namespace
oc new-project cert-manager-operator

# Create the OperatorGroup
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
EOF

# Create the Subscription
oc apply -f - <<EOF
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
```

### Verify the installation

Wait for the CSV to reach `Succeeded` (takes 1–2 minutes):

```bash
oc get csv -n cert-manager-operator -w
```

The command streams change events as new lines — it does not update in place. You will
see an initial row with `Installing`, then a new row appended when the phase changes.
Wait until you see a row for `cert-manager-operator` with `Succeeded` at the end, then
press `Ctrl+C`:

```
NAME                            DISPLAY                                        VERSION   REPLACES                        PHASE
cert-manager-operator.v1.20.0   cert-manager Operator for Red Hat OpenShift   1.20.0    cert-manager-operator.v1.19.0   Installing
cert-manager-operator.v1.20.0   cert-manager Operator for Red Hat OpenShift   1.20.0    cert-manager-operator.v1.19.0   Succeeded
```

> Other operators already installed on the cluster (such as `external-secrets-operator`
> or `itz-deployer-operator`) will also appear in the list — that is normal. You only
> need to confirm the `cert-manager-operator` row reaches `Succeeded`.

Confirm the cert-manager pods are running:

```bash
oc get pods -n cert-manager
```

All three pods (`cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook`)
should show `Running`.

> If you cannot use OperatorHub (e.g. a non-OCP cluster or a restricted environment),
> see [Appendix C — Install cert-manager via Helm](#appendix-c--install-cert-manager-via-helm).

---

## §6 — Generate and apply cluster-scoped resources

Before `bobctl install` can run, the operator namespace, instance namespace, and any
cluster-scoped CRDs or RBAC must exist. The `ibm-bob-cluster-scoped` Helm chart renders
these into `work/cluster-resources.yaml`.

```bash
./bobctl generate-cluster-resources
```

A successful run prints the Helm version, cluster URL, OpenShift version, the path of the
rendered file, and then the exact `oc apply` command to run next. If any of those lines are
missing — or you see an error — stop and resolve it before continuing.

Apply the rendered file with server-side apply to avoid annotation length errors:

```bash
oc apply -f work/cluster-resources.yaml --force-conflicts --server-side
```

Every line of output should end with `serverside-applied`. You should see:

- 2 namespaces (`ibm-bob` and `ibm-bob-operators`)
- ~17 CRDs (`customresourcedefinition.apiextensions.k8s.io/...`)
- Several cluster roles and cluster role bindings (`clusterrole`, `clusterrolebinding`)
- Mutating and validating webhook configurations

If any line shows `Error` or `failed`, stop and resolve it before continuing. A line ending in
`configured` or `created` instead of `serverside-applied` is not an error but indicates the
resource already existed and was patched by a different method — this is harmless on a fresh
install and can be ignored.

Verify the namespaces exist:

```bash
oc get namespace ibm-bob-operators ibm-bob
```

Expected response:
```txt
NAME                STATUS   AGE
ibm-bob-operators   Active   2m42s
ibm-bob             Active   2m42s
```

---

## §7 — Install Bob

### 7a — Create entitlement pull secret

The namespaces `ibm-bob-operators` and `ibm-bob` were created in §6. Before running the
installer, create the `ibm-entitlement-key` pull secret in both namespaces using your IBM
entitlement key (see [Obtain your IBM entitlement key](02-entitlement-key.md) if you have
not yet obtained it):

```bash
export IBM_ENTITLEMENT_KEY="<your IBM entitlement key>"
```

> **Secret naming:** The secret is named `ibm-entitlement-key` — that exact name is
> hardcoded as the default in the Helm charts. The Helm ownership labels and annotations
> are added at creation time so that `bobctl install` can manage this secret without an
> ownership conflict.

```bash
# Create ibm-entitlement-key in both namespaces.
# Operator pods run in ibm-bob-operators; Bob instance pods run in ibm-bob.
# Both pull from cp.icr.io.
for ns in ibm-bob-operators ibm-bob; do
  oc create secret docker-registry ibm-entitlement-key \
    --namespace "$ns" \
    --docker-server=cp.icr.io \
    --docker-username=cp \
    --docker-password="$IBM_ENTITLEMENT_KEY" \
    --dry-run=client -o yaml \
  | oc label --local -f - \
      app.kubernetes.io/managed-by=Helm \
      -o yaml \
  | oc annotate --local -f - \
      meta.helm.sh/release-name=ibm-bob \
      meta.helm.sh/release-namespace=ibm-bob \
      -o yaml \
  | oc apply -f -
done
```

### 7b — Run cluster-side image pull smoke test

Before launching the 15–20 minute installer, run a fast cluster-side smoke test using a
disposable pod to confirm that the cluster's worker nodes can reach and pull from
`cp.icr.io`. Auth failures and network egress blocks are separate failure modes —
a registry that is unreachable mid-install produces an opaque `ImagePullBackOff` with no
obvious connection to a missing credential or firewall rule.

```bash
oc run test-pull \
  --namespace ibm-bob \
  --image="cp.icr.io/cp/bob/bob-admin@sha256:a942b8e31e1f0ce7c98a44a6c69861f3c8aa5e5a7e1395b8221976db39e0a653" \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"ibm-entitlement-key"}]}}' \
  --restart=Never
sleep 20
oc get pod test-pull -n ibm-bob
oc delete pod test-pull -n ibm-bob --ignore-not-found
```

> The pod may crash immediately after the pull succeeds — `bob-admin` has no standalone
> entrypoint. A crash after pull is a pass; only `ImagePullBackOff` or `ErrImagePull`
> indicate a registry or auth problem.

The pod is not expected to stay running — it exists only to trigger a pull.
Interpret the resulting STATUS as follows:

| STATUS | Meaning |
|---|---|
| `Running` | ✅ Pass — image pulled and container started |
| `Error` | ✅ Pass — image pulled; container exited non-zero (no standalone entrypoint) |
| `Completed` | ✅ Pass — image pulled and container exited cleanly |
| `OOMKilled` | ✅ Pass — image pulled; container was killed by the kernel |
| `ImagePullBackOff` | ❌ Fail — registry auth or network problem |
| `ErrImagePull` | ❌ Fail — registry auth or network problem |

If the pod shows `ImagePullBackOff` or `ErrImagePull`, inspect the events with:

```bash
oc describe pod test-pull -n ibm-bob
```

> **Troubleshooting pull failures:**
> - `401 Unauthorized` / `invalid username/password`: The IBM entitlement key is invalid or your IBM Bob entitlement is not active. Verify at [myibm.ibm.com/products-services/containerlibrary](https://myibm.ibm.com/products-services/containerlibrary) (see [Obtain your IBM entitlement key](02-entitlement-key.md)).
> - `i/o timeout` / `no route to host`: The cluster VPC Public Gateway is blocking outbound HTTPS egress. See [§3 — Verify cluster registry reachability](03-pre-install-config.md#3--verify-cluster-registry-reachability).

### 7c — Execute `bobctl install`

Run `bobctl install` with your configuration files and IBM entitlement key:

```bash
./bobctl install \
  --accept-license \
  --model-config model-gateway.yaml \
  --registry-creds "cp:${IBM_ENTITLEMENT_KEY}"
```

- **`--accept-license`** — Required. Confirms your acceptance of the IBM license
  agreement (sets `global.licenseAccept=true` in the Helm release).
- **`--registry-creds`** — Passes `global.registryUsername` and `global.registryPassword`
  to Helm, which uses them to **create and reconcile** the `ibm-entitlement-key` pull secret
  (`cp.icr.io`) in both `ibm-bob-operators` and `ibm-bob` during install,
  overwriting the secret you created manually in §7a. If you omit `--registry-creds`,
  `bobctl` instead reads `imagePullSecretName` from `config.yaml` and validates that the
  secret already exists — the manually-created secret from §7a satisfies that check.
- **`--model-config`** — Injects the model gateway configuration at install time. If omitted,
  you would need to run `./bobctl update-model-config --model-config model-gateway.yaml` afterward.

Installation typically takes 10–20 minutes. `bobctl` tees all Helm output to a log file
in `logs/`.

---

## §8 — Verify the installation

After `bobctl install` completes, the CLI prints the following monitoring commands to
help you track roll-out progress:

```
Install started. Monitor progress with:
  # Check operator status
  oc get pods -n ibm-bob-operators
  # Check Bob instance status and version
  oc get bob -n ibm-bob
  # View operator logs
  oc logs -n ibm-bob-operators deployment/ibm-bob-operator -f
```

The install typically takes 10–20 minutes. The authoritative done signal is
`Available: True` on the Bob CR — run one of the following in a separate terminal
while it reconciles:

**Option A — live watch (refreshes every 15 s):**

```bash
watch -n 15 "oc get bob -n ibm-bob -o json | jq -r '.items[0].status.conditions[] | \"\(.type): \(.status)\"'"
```

**Option B — wait-and-notify (exits automatically when ready):**

```bash
until oc get bob -n ibm-bob -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; do
  echo "$(date +%H:%M:%S) — still waiting…"
  sleep 15
done
echo "✅ Bob is Available — proceed to §8a"
```

While waiting, the conditions will look like this:

```
Available: Unknown   ← still reconciling
Progressing: True
Degraded: False      ← False is correct here
VectorPVCReady: True
```

When `Available` flips to `True`, the install is complete and you can proceed through the
rest of §8.

### 8a — Pod health

```bash
# Operator pods — expect 5 × Running 1/1
oc get pods -n ibm-bob-operators

# Instance pods — expect ~15 pods: mix of Running and Completed
oc get pods -n ibm-bob
```

### 8b — Bob CR status

```bash
oc get bob -n ibm-bob -o jsonpath='{.items[0].status.conditions}' | python3 -m json.tool
```

A healthy install produces three conditions. The `type` names follow the Kubernetes
convention where **you read `status`, not `type`** to determine health:

| `type` | Healthy `status` | Meaning |
|---|---|---|
| `Available` | `True` | Bob is up and serving requests — this is the authoritative signal |
| `Progressing` | `True` | Operator is actively reconciling — normal steady-state, not a warning |
| `Degraded` | `False` | Bob is **not** degraded — `False` is the good value here |

`Degraded: False` is correct. `Degraded: True` would indicate a problem.

The zProxy and Understand conditions reference those optional features, which are disabled by
default. Their messages (`zProxy controller is actively working`, `zProxy workload is operating
as expected`) reflect idle teardown state — they are harmless when `Available` is `True`.

A healthy output looks like this:

```json
[
    {
        "lastTransitionTime": "2026-09-22T19:01:46Z",
        "message": "Last reconciliation succeeded",
        "reason": "Reconciling",
        "status": "True",
        "type": "Available"
    },
    {
        "lastTransitionTime": "2026-09-22T18:58:15Z",
        "message": "zProxy controller is actively working toward the desired state",
        "observedGeneration": 1,
        "reason": "Reconciling",
        "status": "True",
        "type": "Progressing"
    },
    {
        "lastTransitionTime": "2026-09-22T18:58:15Z",
        "message": "zProxy workload is operating as expected",
        "observedGeneration": 1,
        "reason": "AsExpected",
        "status": "False",
        "type": "Degraded"
    },
    {
        "lastTransitionTime": "2026-09-22T18:58:15Z",
        "message": "Vector audit PVC is bound and ready",
        "reason": "PVCBound",
        "status": "True",
        "type": "VectorPVCReady"
    }
]
```

### 8c — Routes

```bash
oc get routes -n ibm-bob
```

| Route | Purpose |
|---|---|
| `bob.<ns>.<cluster-domain>` | Admin UI and user-facing Bob interface |
| `api.bob.<ns>.<cluster-domain>` | REST API endpoint (for IDE extensions and bob-shell) |
| `bob-keycloak.<ns>.<cluster-domain>` | Keycloak SSO admin console |
| `ibm-usage-metering-fetch-<ns>.<cluster-domain>` | Usage metering (IBM internal) |

If you need the cluster domain value on its own — for example, to construct URLs manually — run:

```bash
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.domain}'
```

**Example output:**
```
apps.itz-1turyw.hub01-lb.techzone.ibm.com
```

The full route hostnames follow the pattern `<route-name>.ibm-bob.<cluster-domain>`, so with the example above the Admin UI would be at `https://bob.ibm-bob.apps.itz-1turyw.hub01-lb.techzone.ibm.com`.

---

## §9 — Post-install: extract the CA certificate and distribute to users

> **Note:** If you are using a corporate or enterprise certificate instead of the default
> self-signed cert, see **[Appendix J — Custom TLS certificate](#appendix-j--custom-tls-certificate)**.

Bob uses a self-signed internal CA. Users must trust this CA before their browser or
IDE can connect to the cluster.

### 9a — Extract the CA certificate

```bash
./bobctl get-ca-cert --output "$HOME/bob-ca.crt"

# Verify
openssl x509 -in "$HOME/bob-ca.crt" -noout -subject -issuer -dates
# Expected:
# subject=CN=Bob Internal CA
# issuer=CN=Bob Internal CA
# notBefore=<install date>
# notAfter=<~10 years after install date>
```

The file is written to `$HOME/bob-ca.crt`. This path is used by default in the bob-shell
`NODE_EXTRA_CA_CERTS` export in §12b.

> **Note — CA rotation:** cert-manager rotates the CA automatically — no manual action
> is needed for the rotation itself. `bobctl get-ca-cert` always prints the expiry date
> and warns when the cert is within 30 days of expiry. To detect rotation proactively,
> set `BOB_CA_CERT_FILE` to your previously saved copy before running the command:
>
> ```bash
> BOB_CA_CERT_FILE=./bob-ca.crt ./bobctl get-ca-cert --output bob-ca-new.crt
> ```
>
> If the live cluster cert differs from the saved copy, `bobctl` prints a
> **CA ROTATION DETECTED** warning. Redistribute the new cert to all users.

> **Note — CA certificate distribution (complete after §11):** Once users have been
> added, share `$HOME/bob-ca.crt` with each of them. They will need to import it before
> their browser or IDE can connect to the cluster:
>
> - **macOS:** `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain bob-ca.crt`
> - **bob-shell:** `export NODE_EXTRA_CA_CERTS="$HOME/bob-ca.crt"` — bob-shell is a
>   Node.js application and does not read the macOS keychain; add this export to your
>   `~/.zshrc` or `~/.bashrc` so it applies to every session
> - **bob-ide:** Open the Command Palette (`⌘⇧P`), run **Open User Settings (JSON)**,
>   and add `"http.experimental.systemCertificatesV2": true` to your `settings.json`.
>   Then fully quit bob-ide (`⌘Q`) and relaunch — closing the window is not enough, the
>   Electron process must fully exit. Alternatively, run this one-liner to add the setting
>   from the terminal:
>   ```bash
>   python3 -c "
>     import json, os
>     p = os.path.expanduser('~/Library/Application Support/IBM Bob/User/settings.json')
>     s = json.load(open(p)) if os.path.exists(p) else {}
>     s['http.experimental.systemCertificatesV2'] = True
>     json.dump(s, open(p, 'w'), indent=2)
>     print('Done — quit and relaunch bob-ide')
>   "
>   ```
>   To verify the setting was written, run:
>   ```bash
>   cat ~/Library/Application\ Support/IBM\ Bob/User/settings.json
>   ```

---

## §10 — Post-install: set the bootstrap admin password

> ⚠️ **Pre-GA note:** The bootstrap user `bob-admin@bob.ibm.com` is created by the
> operator during install but has **no password set**. You must set one via `kcadm.sh`
> before first login. This is expected pre-GA behaviour.

> **Important:** The operator uses the credentials in the `bob-keycloak-initial-admin`
> secret for automated reconciliation. Do **not** change the password stored in that
> secret — doing so breaks the operator's Keycloak management. The commands below read
> the secret's password to authenticate `kcadm.sh` but set a separate password on the
> **`bob-admin@bob.ibm.com` user** in the `bob` realm.

> ⚠️ **A `BobIdp` resource must exist before anyone can log in.** A fresh install can
> finish with no `BobIdp`, in which case the Admin UI rejects every login even after
> you set the password. Check first:
>
> ```bash
> oc get bobidp -n ibm-bob
> # "No resources found in ibm-bob namespace." means you must create one:
> ```
>
> Create the minimal IdP (keep `bob.ibm.com` and `bob-admin@bob.ibm.com`, or you lock
> out the bootstrap admin):
>
> ```bash
> cat > config-idp.yaml <<'EOF'
> domains:
>   - bob.ibm.com
> adminEmails:
>   - bob-admin@bob.ibm.com
> EOF
> ./bobctl configure-idp --config config-idp.yaml
> oc get bobidp -n ibm-bob      # expect READY=True, "Last reconciliation succeeded"
> ```
>
> `bob-autoinstall.sh` does this for you (see [§11](#11--post-install-add-users)).

> **Note:** `kcadm.sh` is pointed at the Keycloak service URL
> (`http://bob-keycloak-service.ibm-bob.svc:8080`), not `localhost:8080`.

```bash
# Set your chosen admin password here — all commands below use this variable
BOB_ADMIN_PASSWORD="<YOUR_CHOSEN_PASSWORD>"

# Retrieve the Keycloak bootstrap credentials (temp-admin / <auto-generated password>)
KC_PASS=$(oc get secret bob-keycloak-initial-admin -n ibm-bob \
  -o jsonpath='{.data.password}' | base64 -d)

KC_USER=$(oc get secret bob-keycloak-initial-admin -n ibm-bob \
  -o jsonpath='{.data.username}' | base64 -d)

# Authenticate kcadm — config lives in /tmp and must be re-done after pod restarts
oc exec -n ibm-bob bob-keycloak-0 -c keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://bob-keycloak-service.ibm-bob.svc:8080 \
    --realm master \
    --user "${KC_USER}" \
    --password "${KC_PASS}" \
    --config /tmp/kcadm.config

# Get the bob-admin user ID from the bob realm
BOB_ADMIN_ID=$(oc exec -n ibm-bob bob-keycloak-0 -c keycloak -- \
  /opt/keycloak/bin/kcadm.sh get users -r bob \
    --config /tmp/kcadm.config \
    -q email=bob-admin@bob.ibm.com \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

# Set a password and mark email verified
oc exec -n ibm-bob bob-keycloak-0 -c keycloak -- \
  /opt/keycloak/bin/kcadm.sh set-password -r bob \
    --config /tmp/kcadm.config \
    --userid "${BOB_ADMIN_ID}" \
    --new-password "${BOB_ADMIN_PASSWORD}"

oc exec -n ibm-bob bob-keycloak-0 -c keycloak -- \
  /opt/keycloak/bin/kcadm.sh update users/"${BOB_ADMIN_ID}" -r bob \
    --config /tmp/kcadm.config \
    -s emailVerified=true
```

You can now log in to the Bob Admin UI at
`https://bob.ibm-bob.<cluster-domain>/admin` with:
- **Email:** `bob-admin@bob.ibm.com`
- **Password:** the value you set above

---

## §11 — Post-install: add users

> **Automated installs:** `bob-autoinstall.sh` / `.ps1` create the `BobIdp` CR
> automatically, before setting the admin password. It uses `BOB_IDP_CONFIG` if set,
> otherwise `config-idp.yaml` in the install directory, otherwise a generated baseline
> (`bob.ibm.com` / `bob-admin@bob.ibm.com`). Set `BOB_SKIP_IDP_CONFIG=true` to skip
> (not recommended: nobody can log in). To add LDAP/AD or more domains, put a
> `config-idp.yaml` next to the script before running it (or re-run
> `./bobctl configure-idp` later — it is idempotent). OIDC/w3id is **not** automated;
> configure it in the Admin UI after the baseline `BobIdp` exists.

Bob's login page routes users by **email domain**. The only domain registered at
bootstrap is `bob.ibm.com`. Any email with a different domain — including `ibm.com` —
triggers a redirect to the SaaS IBM ID provider, which does not exist in an on-prem
deployment. The result is Keycloak's **"We are sorry… Client not found"** error.

To see which domains are currently registered, open the Admin UI — run the commands
below to get the exact URL for your cluster:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
echo "https://bob.ibm-bob.${CLUSTER_DOMAIN}/admin/idp"
```

Expand your IdP in the list — the Domains column shows all registered domains and their
verification status.

### Option A — Local Keycloak users (no LDAP)

Adding users without LDAP is a two-step process: register the domain(s) first, then
create the user in Keycloak. If you are only using the default `@bob.ibm.com` domain,
skip step 1.

**Step 1 — Register the email domain via the Admin UI (skip if using `@bob.ibm.com`)**

1. Run the command above to get your Admin UI URL and open `/admin/idp`.
2. Find your IdP (e.g. `ibm_bob_on_premises`) and click the **⋮ → Manage domains** action.
3. Add each email domain your users will log in with (e.g. `ibm.com`, `us.ibm.com`).
4. The domains will appear with a yellow **Pending** status — this is expected. The UI
   requires a DNS TXT record to auto-verify, which is not applicable for an on-prem admin
   who already controls the instance. The next step bypasses that check directly in the
   database.

**Step 1b — Mark the domains as verified**

Because this is an on-prem deployment, you as the cluster admin assert domain ownership
by updating the rows directly. This is safe and intentional — the ability to run
`oc exec` against the database pod is equivalent proof of ownership.

Run this once after adding all your domains in the UI:

```bash
DB_PASS=$(oc get secret bob-db-app -n ibm-bob -o jsonpath='{.data.password}' | base64 -d)

oc exec -n ibm-bob bob-db-1 -- bash -c "
  PGPASSWORD='${DB_PASS}' psql -h bob-db-rw -p 5432 -U bob -d bob -c \"
    UPDATE idp_domains
    SET verified = true,
        verified_at = now(),
        updated_at = now()
    WHERE verified = false;
  \"
"
```

Expected output: `UPDATE <N>` where N is the number of domains you added. You can
confirm the result with:

```bash
oc exec -n ibm-bob bob-db-1 -- bash -c "
  PGPASSWORD='${DB_PASS}' psql -h bob-db-rw -p 5432 -U bob -d bob \
  -c 'SELECT domain_suffix, verified, verified_at FROM idp_domains;'
"
```

All rows should now show `verified = t`. The UI will reflect green status on the next
page load.

> If you prefer to register domains entirely via command line without touching the UI,
> see [Appendix H — Register IdP domains via DB commands](#appendix-h--register-idp-domains-via-db-commands).

**Step 2 — Create the user in Keycloak**

First, retrieve the `temp-admin` password and Keycloak URL:

```bash
# Password
oc get secret bob-keycloak-initial-admin -n ibm-bob \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Console URL
echo "https://$(oc get routes -n ibm-bob -o jsonpath='{.items[?(@.spec.to.name=="bob-keycloak-service")].spec.host}')"
```

In the Keycloak admin console:

1. Log in with username `temp-admin` and the password printed above.
2. In the top-left click "Manage realms" from the table click **`bob`** to switch your realm.
3. Go to **Users → Add user**.
   - Email: must end in a registered domain (`@bob.ibm.com` or whatever you inserted in step 1).
   - Set **Email Verified = ON**.
   - Enter their email for `Username` and `Email` fields, enter first and last name.
   - Click "Join Groups" select `bob-admins` or `bob-users`. Click "Join" button.
   - Click "Create" button
4. Switch to the **Credentials** tab: set a password, disable "Temporary".

> ⚠️ **Keycloak group ≠ Bob admin role.** Adding a user to `bob-admins` in Keycloak controls login access only. To grant Bob admin permissions, log in to the Bob Admin UI (`https://bob.ibm-bob.<cluster-domain>/admin`), go to **Users**, find the user, and set their role to **Admin**.

> **Note on managing groups later:** To change a user's role in the future, navigate to **Users → (select user) → Groups** tab, where you can join or leave `bob-users` (standard user) and `bob-admins` (admin).

> ⚠️ `temp-admin` lives in the `master` realm and has **no access to Bob** itself. Do
> not use the `master` realm for Bob user management.

### Option B — LDAP / Active Directory federation

For production deployments, federate your corporate directory. LDAP federation
automatically registers the correct domain via the `domains` field in the BobIdp CR,
so users with that email domain are routed to LDAP automatically — no manual domain
registration or Keycloak user creation needed.

```bash
cp config-idp-template.yaml my-idp.yaml
# Edit my-idp.yaml: set server URL, bind DN, user/group search base, and domains list.
# Keep bob.ibm.com in domains and bob-admin@bob.ibm.com in adminEmails (bootstrap admin).
./bobctl configure-idp --config my-idp.yaml
```

> **Note — Required secrets:** Any secrets referenced in the config file
> (`bindPasswordSecret`, `ldapsCACertSecret`) must be pre-created in the instance
> namespace **before** running `configure-idp`:
>
> ```bash
> # Bind password for an LDAP service account
> oc create secret generic corp-ldap-bind --from-literal=password=<pw> -n <instance-namespace>
>
> # Certificate authority certificate for a private LDAPS endpoint
> oc create secret generic corp-ldap-ca --from-file=ca.crt=./ca.pem -n <instance-namespace>
> ```
>
> `bobctl` verifies that every referenced secret exists before applying the CR and
> exits with a remediation message if one is missing.

`bobctl configure-idp` waits up to **600 seconds** for the `BobIdp` CR `Ready`
condition to become `True`. Override with `BOB_IDP_WAIT_TIMEOUT`:

```bash
BOB_IDP_WAIT_TIMEOUT=900 ./bobctl configure-idp --config my-idp.yaml
```

To inspect CR status after the command completes:

```bash
oc get bobidp bob-idp -n <instance-namespace>
oc get bobidp bob-idp -n <instance-namespace> -o yaml
```

---

## §12 — End-to-end verification with bob-shell

This section verifies the full stack: cluster → Keycloak → inference gateway → model.
**Prerequisites:** §10 and §11 must be complete — you need a Bob user account that can
sign in (SSO/IdP or Keycloak).

> **Note:** bob-shell signs in through your IdP/SSO once `gatewayUrl` is set in
> `~/.bob/settings/settings.json` (see §12b). No API key is required. If you prefer
> an API key (for example, for non-interactive use), see the *Alternative* section in
> [`bob-onprem-shell-setup.md`](bob-onprem-shell-setup.md). That key is a
> **user-created API key generated in the Bob Admin UI** — not the cluster-level
> `bob-admin-secret`, which must not be used for bob-shell sessions.

### 12a — Check Node.js and install bob-shell

```bash
# Verify Node.js 24+
node --version

# Install or upgrade bob-shell
curl -fsSL https://bob.ibm.com/download/bobshell.sh | bash

# Confirm v2
bob --version
# Must show 2.x or higher — v1 uses `bob -p` and will fail with a confusing error
```

### 12b — Point bob-shell at the gateway

```bash
# Discover your ingress domain
# TechZone clusters populate .status.domain; .spec.domain is typically absent
INGRESS=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.status.domain}')

# Set gatewayUrl in the settings file shared by Bob Shell and Bob IDE
python3 -c "
import json, os, sys
p = os.path.expanduser('~/.bob/settings/settings.json')
os.makedirs(os.path.dirname(p), exist_ok=True)
s = json.load(open(p)) if os.path.exists(p) else {}
s['gatewayUrl'] = 'https://api.bob.ibm-bob.' + sys.argv[1] + '/'
json.dump(s, open(p, 'w'), indent=2)
print('gatewayUrl set')
" "${INGRESS}"

# Private-CA clusters only: Node.js does not read the OS trust store
export NODE_EXTRA_CA_CERTS="$HOME/bob-ca.crt"
```

To switch back to SaaS, rename the key (e.g. `"gatewayUrl-old"`) or delete it, then restart bob.

### 12c — Sign in and run the e2e test

Start `bob` once and sign in through your IdP/SSO, then run:

```bash
bob --accept-license run "Hello"
```

Expected output (truncated):

```
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
User (1) 2026-09-17 17:55:31.877 UTC (+6.4s)

Hello

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
Assistant (1) 2026-09-17 17:55:37.908 UTC (+12.4s)

Hello! How can I help you today?
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

Task Summary

Total Cost:              0.0000
Total Duration:          12.8s


Assistant Messages:      1
Tool Calls:              0
Task ID:                 901658651e7db52936e2aa1f0898faf4
```

If the command succeeds, the full stack is working end-to-end.

---

## Appendix A — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every login fails, even `bob-admin@bob.ibm.com` | No `BobIdp` CR (`oc get bobidp -n ibm-bob` returns nothing) | Create it with `./bobctl configure-idp --config config-idp.yaml` (see §10); `bob-autoinstall.sh` now does this automatically unless `BOB_SKIP_IDP_CONFIG=true` |
| Any email → "Client not found" | Email domain not in `idp_domains` table | Use `bob-admin@bob.ibm.com`, or add the domain via Option B in §11 |
| `@ibm.com` → "Client not found" | `ibm.com` ≠ `bob.ibm.com` — different domains | Use `@bob.ibm.com` or register `ibm.com` separately (Option B in §11) |
| Login works but user has no access | User not in `bob-users` group | Add user to `bob-users` in Keycloak console (`bob` realm) |
| `temp-admin` cannot log into Bob UI | `temp-admin` is a `master` realm user, not a Bob user | Use `bob-admin@bob.ibm.com` for Bob; use `temp-admin` only in Keycloak console |
| CLI returns `HTTP 400: unknown model: <name>` | Model name not in gateway config | Verify the `model_name` entry exists in `model-gateway.yaml` and re-run `bobctl update-model-config` |
| CLI returns `BOBSHELL_API_KEY and BOB_API_KEY are both set` | Leftover `BOBSHELL_API_KEY` from a v1 bob-shell install is still exported in your shell profile | Run `unset BOBSHELL_API_KEY`, then remove or replace it in your `.zshrc`/`.bash_profile` |
| `403 Access denied` persists after fixing auth scheme | The gateway's Lua shared-dict cache stored the earlier denial and replays it for up to 24h | Flush the cache by restarting the gateway pod: `oc delete pod -n "$BOB_NS" -l app=bob-gateway && oc rollout status deploy/bob-gateway -n "$BOB_NS" --timeout=2m` — then retry immediately |
| `ImagePullBackOff` on operator pods | Wrong or missing pull secret | Verify `ibm-entitlement-key` secret exists in `ibm-bob-operators` and credentials are valid (`cp.icr.io`, username `cp`) |
| cert-manager schema validation error on `helm upgrade` | cert-manager CRDs out of date | Upgrade cert-manager CRDs separately before running `bobctl upgrade` |
| NFS provisioner pod stuck in `FailedMount` | SCC not granted | Run `oc adm policy add-scc-to-user hostmount-anyuid -z nfs-client-provisioner -n nfs-provisioner` |
| `bob-ca.crt`: certificate verify failed (Node.js) | Node.js does not read the macOS keychain | Export `NODE_EXTRA_CA_CERTS="$HOME/bob-ca.crt"` in the same session |

---

## Appendix B — Upgrade Bob

To upgrade to a new Bob version, unpack the new installer bundle and run:

```bash
# Step 1 — copy your config.yaml from the old package into the new one
cp ../ibm-bob-install-<old-version>/config.yaml ./config.yaml

# Step 2 — re-apply cluster-scoped resources (CRDs, RBAC) from the new package
./bobctl generate-cluster-resources
oc apply -f work/cluster-resources.yaml --force-conflicts --server-side

# Step 3 — upgrade the namespaced Helm release
./bobctl upgrade

# Step 4 — push model gateway config and secrets (upgrade does not do this automatically)
./bobctl update-model-config --model-config model-gateway.yaml --update-secrets
```

> ⚠️ **Always re-apply cluster-scoped resources when upgrading.** New releases may
> introduce new CRDs (such as `BobIdP`). `bobctl upgrade` only upgrades the namespaced
> Helm release — it does **not** re-apply the `ibm-bob-cluster-scoped` chart. Skipping
> Step 2 will cause post-upgrade commands like `bobctl configure-idp` to fail with
> `no matches for kind "BobIdp"`.

> **Note:** `bobctl upgrade` only accepts `--dry-run`. There is no `--config` flag —
> it always reads `config.yaml` from the package directory. To use a non-default config
> path, set `BOB_CONFIG_FILE=/path/to/config.yaml` before running.

> **Note:** `bobctl upgrade` does **not** accept `--registry-creds` — it reuses the
> image pull secret created during `bobctl install`. If your entitlement key has rotated,
> update the secret manually before upgrading:
> ```bash
> oc create secret docker-registry ibm-entitlement-key \
>   --namespace ibm-bob \
>   --docker-server=cp.icr.io \
>   --docker-username=cp \
>   --docker-password=<NEW_IBM_ENTITLEMENT_KEY> \
>   --dry-run=client -o yaml | oc apply -f -
> ```

Helm uses `--reset-then-reuse-values` (requires Helm 3.14.0+) to merge new chart
defaults with your overrides. Older Helm versions silently ignore this flag and will lose
values during upgrade.

---

## Appendix C — Install cert-manager via Helm

Use this method only if you cannot use OperatorHub (for example, a non-OCP Kubernetes
cluster or a restricted environment where the Red Hat operator catalog is unavailable).
For TechZone OCP clusters, use §3 instead.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

Verify the installation:

```bash
oc rollout status deployment/cert-manager -n cert-manager
oc rollout status deployment/cert-manager-webhook -n cert-manager
oc rollout status deployment/cert-manager-cainjector -n cert-manager
```

All three deployments must report `successfully rolled out` before proceeding.

---

## Appendix G — Install cert-manager via OperatorHub web console

Use this method on production OpenShift accounts where the **Operators** section is
visible in the web console left nav. TechZone clusters provisioned with a temporary
`kube-admin` user do not show the Operators nav — use the CLI method in §3 instead.

1. In the OpenShift web console, navigate to **Operators → OperatorHub**.
2. Search for `cert-manager Operator for Red Hat OpenShift`.
3. Select the **Red Hat** tile (not the community tile).
4. Click **Install**.
5. On the Install Operator page:
   - **Update channel:** `stable-v1` (default — leave as-is)
   - **Installation mode:** All namespaces
   - **Installed Namespace:** `cert-manager-operator` (default — leave as-is)
   - **Update approval:** Automatic
6. Click **Install** and wait for the status to show **Succeeded**.

Then follow the [Verify the installation](#verify-the-installation) steps in §3.

---

## Appendix H — Register IdP domains via DB commands

Use this method if you prefer to bypass the Admin UI entirely and register domains
directly from the command line. This was the original approach documented in §11 and
is preserved here as a reference.

The UI + UPDATE approach in §11 Option A is preferred because the UI handles the FK
lookup and row creation, reducing the number of things that can go wrong. Use this
appendix only if the Admin UI is unavailable or you are scripting a fully automated
install.

**Step 1 — Retrieve the IdP ID**

```bash
DB_PASS=$(oc get secret bob-db-app -n ibm-bob -o jsonpath='{.data.password}' | base64 -d)

IDP_ID=$(oc exec -n ibm-bob bob-db-1 -- bash -c "
  PGPASSWORD='${DB_PASS}' psql -h bob-db-rw -p 5432 -U bob -d bob -At \
  -c \"SELECT id FROM custom_idps WHERE name='ibm_bob_on_premises';\"
")

# Verify IDP_ID resolved before inserting — if empty, the custom_idps row doesn't exist yet
echo "IDP_ID: ${IDP_ID}"
```

The output must be a UUID. If it is empty, stop — the `custom_idps` row is not present
and the insert will fail with a null foreign key. The IdP must be created first (see
§11 Option A Step 1, or create it via the Admin UI at `/admin/idp`).

**Step 2 — Insert each domain as verified**

```bash
oc exec -n ibm-bob bob-db-1 -- bash -c "
  PGPASSWORD='${DB_PASS}' psql -h bob-db-rw -p 5432 -U bob -d bob -c \"
    INSERT INTO idp_domains (id, idp_id, domain_suffix, verified, verified_at, created_at, updated_at)
    VALUES (gen_random_uuid(), '${IDP_ID}', '<YOUR_DOMAIN>', true, now(), now(), now());
  \"
"
```

Repeat the insert for each additional domain, reusing the same `DB_PASS` and `IDP_ID`
variables. Do not run this if the domain was already added via the UI — the insert will
fail with a duplicate key error. Use the `UPDATE` command from §11 Step 1b instead.

---

## Appendix I — Verify model inferencing

Use this appendix after completing §7 (install) and §5b (model gateway config) to confirm
that the inference gateway is up, models are loaded, and end-to-end inference is working.
Set the namespace variable once at the top and every command below will work as-is.

```bash
BOB_NS="ibm-bob"   # change if you used a non-default instanceNamespace
```

### I1 — Gateway health

```bash
# Inference Service pod is Running and all containers are Ready
oc get pods -n "$BOB_NS" -l app=bob-inference

# Startup logs — filter to just level, caller, and message; suppress metering noise
oc logs -n "$BOB_NS" deploy/bob-inference --since=5m \
  | jq -r 'select(.caller | test("metering") | not) | [.ts, .level, .msg] | @tsv'

# List configured models — confirms Bifrost loaded the gateway config
oc exec -n "$BOB_NS" deploy/bob-gateway -- \
  sh -c 'curl -sk https://bob-inference.'"$BOB_NS"'.svc.cluster.local:7330/v1/model/info | jq .'
```

> If you see metering errors (`Failed to send metering event ... too many colons in address`)
> in the log output, suppress them with the `jq` filter shown above to focus on the
> inference signal. These errors do not affect inferencing.

### I2 — End-to-end inference test

This test goes through the public Bob gateway using your API key — the same path bob-shell
uses.

**Step 1 — Resolve and export the gateway URL:**

```bash
export BOB_GATEWAY_URL="https://$(oc get route -n "$BOB_NS" \
  -o jsonpath='{.items[?(@.spec.to.name=="bob-gateway")].spec.host}' \
  | tr ' ' '\n' | grep '^api\.')"
echo "BOB_GATEWAY_URL=$BOB_GATEWAY_URL"
```

**Step 2 — Get a valid `BOB_API_KEY`.** Log in to the Bob Admin UI and generate one:

```bash
# Print the Admin UI URL
echo "https://$(oc get route -n "$BOB_NS" \
  -o jsonpath='{.items[?(@.spec.to.name=="bob-gateway")].spec.host}' \
  | tr ' ' '\n' | grep -v '^api\.')/admin"
```

Go to **API Keys → Generate**, copy the key, then:

```bash
export BOB_API_KEY="<key from Admin UI>"
echo "BOB_API_KEY set (length: ${#BOB_API_KEY})"
```

> **Auth header format:** Bob API keys (`bob_onprem_...`) are opaque tokens, not JWTs. The gateway
> recognises them via `Authorization: APIKey <key>` or `X-API-Key: <key>`. Using
> `Authorization: Bearer <key>` routes them to the JWT verifier and returns
> `invalid jwt string`. Always use `APIKey` as the scheme.

**Step 3 — Run the inference test:**

```bash
# Extract the first exposed model name directly from the inference service
PRIMARY_MODEL=$(oc exec -n "$BOB_NS" deploy/bob-gateway -- \
  curl -sk https://bob-inference."$BOB_NS".svc.cluster.local:7330/v1/model/info \
  | jq -r '.data[] | select(.model_info.exposed == true) | .model_name' | head -1)
echo "Testing model: $PRIMARY_MODEL"

# Confirm both required variables are set before sending
echo "BOB_GATEWAY_URL=$BOB_GATEWAY_URL"
echo "BOB_API_KEY set: $( [[ -n "$BOB_API_KEY" ]] && echo yes || echo NO — set it first )"

# Send a minimal inference request through the public gateway
# Note 1: use "APIKey" scheme, not "Bearer" — Bob opaque keys are not JWTs
# Note 2: the path MUST start with /inference/ — the gateway uses this prefix
#          to route and authorize the request before stripping it for the backend.
#          Calling /v1/chat/completions directly bypasses the routing rules and
#          produces a 403 Access denied from OPA.
curl -sk "$BOB_GATEWAY_URL/inference/v1/chat/completions" \
  -H "Authorization: APIKey $BOB_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$PRIMARY_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say: pong\"}], \"max_tokens\": 10}" \
  | jq .
```

A successful response contains a `choices` array with a `message.content` field.

| HTTP status / error | Cause | Fix |
|---|---|---|
| `401` / `invalid jwt string` | `Authorization: Bearer` was used with a Bob opaque API key — `Bearer` routes to the JWT verifier which rejects non-JWT tokens | Change header to `Authorization: APIKey $BOB_API_KEY` |
| `401` / `invalid jwt string` (using `APIKey` scheme) | Key is stale, was copied with surrounding whitespace, or the Keycloak-backed key store is unavailable | Regenerate in the Admin UI; check `oc logs -n "$BOB_NS" deploy/bob-gateway --since=2m \| grep -i "apikey\|permission"` |
| `403` / `Access denied` | Request path is missing the `/inference/` prefix | Change URL to `$BOB_GATEWAY_URL/inference/v1/chat/completions` |
| `404 Not Found` | `model_name` does not match what the provider exposes | Run the I1 `model/info` check and compare `model_name` values |
| `502 Bad Gateway` | The upstream model endpoint is unreachable | Check I3 log stream for `connection refused` or `no route to host` |

> **Tip:** Test each model name listed in your gateway config in turn. Bob rejects requests
> if the model is unreachable or misconfigured, even if other models respond correctly.

### I3 — Live log stream (run alongside I2)

```bash
oc logs -n "$BOB_NS" deploy/bob-inference -f
```

Key log patterns to look for:

| Pattern | Meaning |
|---|---|
| `Model registered successfully` | Bifrost loaded the model entry without errors |
| `connection refused` / `no route to host` | Connectivity failure to the model endpoint |
| `401` / `403 from upstream` | Credential is wrong or lacks required permissions |
| `certificate signed by unknown authority` | `ca_cert_pem` is missing or incorrect |
| `environment variable not found` | A secret referenced with `env.*` is missing from `bob.modelGateway.secrets` |

### I5 — Update model config and restart inference pods

Use this procedure whenever you change `model-gateway.yaml` (add/remove a model, update
an endpoint URL, rotate an API key) and need to push the change to the cluster without
doing a full `bobctl upgrade`.

Run all commands from inside the install package directory (`ibm-bob-install-*/`).

#### Update the model config (ConfigMap)

```bash
./bobctl update-model-config --model-config model-gateway.yaml
```

This renders the model gateway ConfigMap via `helm template` and applies it with
`oc apply --server-side --force-conflicts`. Adjust the path to `model-gateway.yaml`
if yours lives elsewhere.

#### Update secrets only (API key rotation)

If you only changed a secret value in `config.yaml` (e.g. rotated an API key) and
did **not** edit `model-gateway.yaml`, use `--update-secrets` instead:

```bash
./bobctl update-model-config --update-secrets
```

#### Update both config and secrets in one pass

```bash
./bobctl update-model-config --model-config ../model-gateway.yaml --update-secrets
```

#### Rolling restart of the inference pods

After either command above, trigger a rolling restart so the `bob-inference` pods pick
up the new ConfigMap and/or Secret without downtime:

```bash
oc rollout restart deploy/bob-inference -n "$BOB_NS"
oc rollout status  deploy/bob-inference -n "$BOB_NS" --timeout=5m
```

#### List configured models — confirms Bifrost loaded the gateway config

```bash
oc exec -n "$BOB_NS" deploy/bob-gateway -- \
  sh -c 'curl -sk https://bob-inference.'"$BOB_NS"'.svc.cluster.local:7330/v1/model/info | jq .'
```

---

## Appendix J — Custom TLS certificate

By default, Bob uses a self-signed certificate managed by cert-manager. This appendix
covers replacing that certificate with one from your own CA — a common requirement in
corporate and enterprise environments.

| Scenario | When it applies | What you need to do |
|---|---|---|
| **A — Default self-signed** | No custom cert installed | Extract the CA cert (§9a) and distribute it to every user workstation |
| **B — Customer certificate** | `setup-route` was run with a custom secret | `ca.crt` is likely already trusted org-wide — distribution optional |

After running `setup-route`, `./bobctl get-ca-cert` automatically reads `ca.crt` from
the custom secret instead of the default self-signed secret.

### J1 — Create the TLS secret

The secret must exist in the instance namespace and contain `tls.crt` and `tls.key`
(PEM format, unencrypted). Including `ca.crt` is recommended when your certificate was
issued by a private or corporate CA — it enables `get-ca-cert` to extract and distribute
the CA cert (Scenario B). Omit it only when your certificate was issued by a
publicly-trusted CA (e.g. Let's Encrypt, DigiCert) where clients already trust the issuer.

```bash
# With CA cert — recommended when using a private/corporate CA
oc create secret generic my-tls-secret \
  --from-file=tls.crt=/path/to/tls.crt \
  --from-file=tls.key=/path/to/tls.key \
  --from-file=ca.crt=/path/to/ca.crt \
  -n <instance-namespace>

# Without CA cert — publicly-trusted CA only
oc create secret tls my-tls-secret \
  --cert=/path/to/tls.crt \
  --key=/path/to/tls.key \
  -n <instance-namespace>
```

### J2 — Install the custom certificate (`setup-route`)

```bash
./bobctl setup-route --tls-secret my-tls-secret
```

`bobctl` validates the secret, patches `spec.externalCertificate.secretName` on the Bob
CR, then polls until the operator confirms the Ingress `spec.tls.secretName` matches and
the cert-manager issuer annotation is removed. If `ca.crt` is absent, a warning is
printed but the command succeeds.

**Options:**

| Flag | Required | Description |
|---|---|---|
| `--tls-secret <secret>` | Yes | Secret containing `tls.crt` and `tls.key` (`ca.crt` optional) |
| `--no-wait` | No | Skip polling for operator reconciliation |
| `--dry-run` | No | Preview changes without applying them |

**Timeouts:** default 30 retries × 10 s = 5 minutes. Override with environment variables:

```bash
BOB_ROUTE_WAIT_RETRIES=60 BOB_ROUTE_WAIT_DELAY=15 ./bobctl setup-route --tls-secret my-tls-secret
```

### J3 — Revert to the default certificate (`reset-route`)

To remove the custom certificate and let the operator resume managing TLS automatically
via cert-manager:

```bash
./bobctl reset-route
```

`bobctl` removes `spec.externalCertificate` from the Bob CR and polls until the operator
reconciles — confirming the Ingress `spec.tls.secretName` is back to `bob-external-tls`
and the cert-manager issuer annotation is restored. The self-signed CA cert is printed on
success (Scenario A), ready to distribute.

If no custom certificate is configured, the command exits cleanly with no changes.

**Options:**

| Flag | Required | Description |
|---|---|---|
| `--no-wait` | No | Skip polling for operator reconciliation |
| `--dry-run` | No | Preview changes without applying them |
