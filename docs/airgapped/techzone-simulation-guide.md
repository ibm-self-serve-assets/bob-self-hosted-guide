# IBM Bob air-gap install: TechZone simulation guide

This guide simulates the air-gapped install process on a TechZone OpenShift cluster that has
internet access. It is a companion to the real
[air-gapped install guide](bob-airgapped-install-guide.md).

---

## The three phases

This process has three completely separate phases. Each involves different credentials,
different machines, and a different registry. Keep them distinct in your mind:

```
PHASE 1 — DOWNLOAD          PHASE 2 — PUSH               PHASE 3 — INSTALL
────────────────────        ─────────────────────        ─────────────────────
Your laptop                 Your laptop                  Your laptop (oc/helm)
    ↓                           ↓                              ↓
cp.icr.io (IBM)             ~/bob-airgap-sim/            OCP cluster
    ↓                       bob-images/ (disk)           (pulls from registry pod)
~/bob-airgap-sim/               ↓
bob-images/ (disk)          registry:2 pod
                            in OCP cluster
Credential: IBM             Credential: OCP              Credential: OCP
entitlement key             login token                  login token
```

| Phase | Steps | What touches IBM credentials |
|---|---|---|
| Download | Steps 4–6 | `auth.json` on your laptop only — IBM entitlement key never leaves your machine |
| Push | Step 7 | No credentials — the `registry:2` pod has no auth |
| Install | Steps 8–9 | No IBM credentials — cluster pulls from the in-cluster registry pod |

**What this simulates and what it doesn't.**

| Real air-gap step | How it is simulated here |
|---|---|
| Download images from IBM to a connected host | Same — your laptop downloads to local disk |
| Carry disk across the air gap | Skipped — the disk never leaves your laptop |
| Push images from disk to Artifactory | Same process — target is a `registry:2` pod inside the OCP cluster acting as Artifactory |
| Cluster pulls only from Artifactory, never the internet | Same — the cluster pulls only from the in-cluster registry pod |

**Why not the OCP internal registry?** The OCP internal registry enforces a strict
`<project>/<name>` two-segment path format. Bob's image paths have three or four segments
(e.g. `cp/bob/bob-admin`), which the internal registry rejects with `repository name invalid`.
A plain `registry:2` container has no such restriction and behaves like Artifactory.

---

## Time estimates

**Assumptions:** laptop in North America or Europe connecting to a TechZone Asia-Pacific
cluster (Tokyo or Sydney). Observed speeds: ~9 MB/s download from IBM, ~1–9 MB/s upload
to cluster. Times will be faster from a host closer to the TechZone region.

| Step | What happens | Estimated time |
|---|---|---|
| 0–0.1 | Login + set variables | < 2 min |
| 1 | Deploy registry pod + MCP rollout | **10–15 min** (nodes reboot one at a time) |
| 2–5 | Working dir + auth + download list | < 5 min |
| 6 | Download 47 images from IBM to disk (~21 GiB) | **30–50 min** at 7–12 MB/s |
| 7 | Push 47 images from disk to cluster (~21 GiB) | **30–90 min** at 4–12 MB/s |
| 8 | Edit config.yaml + model-gateway.yaml | < 10 min |
| 9.1 | Mirror cert-manager (4 images, ~300 MB) + install | **5–10 min** |
| 9.2 | Generate cluster resources + `bobctl install` | < 5 min |
| 9.3 | Bob CR reaching `READY=True` | **20–30 min** |
| **Total** | | **~2–3 hours** |

> If you already have `bob-images/` on disk from a previous run, skip Step 6. Total drops
> to **~1.5–2 hours**.

---

## Prerequisites

### Tools on your laptop

| Tool | Minimum version | Check |
|---|---|---|
| `oc` | 4.x | `oc version --client` |
| `helm` | 3.14 or later (**Helm 3 only — Helm 4 not tested**) | `helm version` |

### What you need before starting

- [ ] IBM entitlement key — get it from [myibm.ibm.com](https://myibm.ibm.com) →
  Container software library
- [ ] An LLM endpoint and credentials for `model-gateway.yaml`
  (Azure OpenAI, AWS Bedrock, or Google Gemini)
- [ ] `oc login` to your TechZone cluster as `kubeadmin`
- [ ] The install package at `ibm-bob-install-20260924-full-install/` (unmodified)
- [ ] This guide's `mappings/` directory alongside it

### Verified starting state

The following were confirmed on the TechZone cluster used to build this guide:

```
oc version --client   → Client Version: 4.22.12
skopeo --version      → skopeo version 1.24.0
helm version          → v3.22.0  ← Helm 3 only; Helm 4 not tested
oc whoami             → kube:admin
```

---

## Step 0: Log in to your TechZone cluster

Get the `oc login` command from TechZone:

1. Open your TechZone reservation
2. Click **Open your IBM Cloud environment**
3. In the OpenShift web console, click your username (top right) → **Copy login command**
4. Click **Display token**, then copy the `oc login` command

Run it in your terminal:

```bash
oc login --token=<your-token> --server=<your-api-server>
```

Verify you are logged in as cluster-admin:

```bash
oc whoami
```

**Expected output:** `kube:admin`

---

## Step 0.1: Set shell variables

Run these once at the start of every terminal session. Everything else in this guide
references them.

**Edit these two lines for your machine — this is the only place you need to change anything:**

```bash
# ── Set these two paths for your machine ──────────────────────────────────────
# Root of the install package (the directory you extracted from the release build)
export BOB_PKG=~/ibm-bob-install-20260924-full-install

# Root of this repo (the directory that contains docs/airgapped/mappings/)
export AIRGAP_DIR=~/bob-install/docs/airgapped
# ──────────────────────────────────────────────────────────────────────────────

# Everything below is copy-paste from here on

# FEATURES controls which images are mirrored in Steps 5 and 8.
# It must match the features you enable in config.yaml (Step 9).
# "--zproxy --understand" = all premium features (47 images).
# Note: --rag is intentionally omitted — --zproxy implies --rag automatically.
#       select-lists.sh adds the RAG, OpenSearch and Z-common images for you.
export FEATURES="--zproxy --understand"

# DEST is the in-cluster registry hostname.
# If the registry is already deployed (Step 1 is done), set it now:
export DEST=$(oc get route registry -n bob-registry -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
echo "DEST=$DEST"

# Namespace constants — used throughout Steps 9 and 10
export INSTANCE_NS=ibm-bob
export OPERATOR_NS=ibm-bob-operators

# Admin UI URL — only meaningful after Step 9 (Bob CR READY=True).
# Derived live from the cluster so it works on any TechZone reservation.
export BOB_ADMIN_UI=$(oc get ingress bob-gateway -n ibm-bob \
  -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' 2>/dev/null \
  | awk '!/^api\./{print "https://" $1; exit}')
echo "BOB_ADMIN_UI=$BOB_ADMIN_UI"

# API base URL — the api. host of the same ingress; used by all curl calls in this guide.
export BOB_URL=$(oc get ingress bob-gateway -n ibm-bob \
  -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' 2>/dev/null \
  | awk '/^api\./{print "https://" $1; exit}')
echo "BOB_URL=$BOB_URL"
```

> **Re-run this block at the start of every new terminal session.**
> `$DEST`, `$BOB_ADMIN_UI`, and `$BOB_URL` are derived live from the cluster — they will be empty before
> the relevant steps are complete, which is expected.
> Never hardcode these values — route hostnames differ between TechZone reservations.

---

## Step 1: Deploy the in-cluster registry

Deploy a plain `registry:2` container inside the OCP cluster. This acts as Artifactory —
no path restrictions, reachable from both your laptop (via a Route) and the cluster nodes.

```bash
# Create a dedicated namespace
oc new-project bob-registry

# Deploy the registry
oc create deployment registry \
  --image=docker.io/library/registry:2 \
  -n bob-registry

# Expose it as a service
oc expose deployment registry \
  --port=5000 \
  -n bob-registry

# Create a passthrough route so your laptop can push to it over HTTPS
oc create route edge registry \
  --service=registry \
  --port=5000 \
  -n bob-registry

# Grab the route hostname and set $DEST
export DEST=$(oc get route registry -n bob-registry -o jsonpath='{.spec.host}')
echo "Registry: $DEST"
```

**Expected result:** `Registry: registry-bob-registry.apps.<cluster>.techzone.ibm.com`

Allow the cluster to pull from this registry without TLS verification (it uses the
cluster's default self-signed certificate):

```bash
oc patch image.config.openshift.io/cluster \
  --type json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/registrySources/insecureRegistries/-\",\"value\":\"${DEST}\"}]"
```

Wait for the machine config to roll out. On TechZone this takes **10–15 minutes** as
each node reboots one at a time. Watch progress with:

```bash
watch oc get mcp
```

Wait until both `master` and `worker` show `UPDATED=True`, `UPDATING=False`, and
`READYMACHINECOUNT` equals `MACHINECOUNT` (3/3 on a standard TechZone cluster).

**Expected result:**
```
NAME     CONFIG                        UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT
master   rendered-master-...           True      False      False      3              3
worker   rendered-worker-...           True      False      False      3              3
```

---

## Step 2: Create the download working directory

All download artifacts live here. This directory is what you would carry on a hard drive
in a real air-gap scenario.

```bash
mkdir -p ~/bob-airgap-sim
cd ~/bob-airgap-sim
```

---

## Step 3: Create the stub kubeconfig

`oc registry login` refuses to run without a kubeconfig, even though it never contacts a
cluster. A stub file is enough.

```bash
cd ~/bob-airgap-sim

cat > kube.yaml <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: none
  cluster:
    server: none
contexts:
- name: none
  context:
    cluster: none
    user: none
current-context: none
users:
- name: none
  user: {}
EOF

export KUBECONFIG=$PWD/kube.yaml
echo "KUBECONFIG=$KUBECONFIG"
```

**Expected result:** `KUBECONFIG=/Users/<you>/bob-airgap-sim/kube.yaml`

---

## Step 4: Create the auth file

`auth.json` is a credential store that `oc image mirror` reads when it pulls or pushes
images. `oc registry login` is just a helper that writes login credentials into this file —
it is equivalent to `docker login` or `podman login`. No cluster connection is made here.

**First time (no `bob-images/` on disk yet) — Step 6 needs IBM credentials to pull from `cp.icr.io`:**

```bash
cd ~/bob-airgap-sim

echo '{}' > auth.json

# Save IBM registry credentials into auth.json so oc image mirror can pull from cp.icr.io.
# "cp" is the literal required username for cp.icr.io (IBM mandates this, it is not a placeholder).
# This credential stays on your laptop — it never touches the OCP cluster.
read -rs ENTITLEMENT_KEY        # paste your IBM entitlement key, then press Enter
oc registry login \
  --auth-basic "cp:${ENTITLEMENT_KEY}" \
  --registry cp.icr.io \
  -a ./auth.json

```

**Subsequent runs (`bob-images/` already on disk, skipping Step 6) — only the push credential needed:**

```bash
cd ~/bob-airgap-sim

echo '{}' > auth.json
```

**Expected result:** confirm the entry is present:

```bash
cat auth.json | python3 -m json.tool | grep '"' | grep -v auth
```

---

## Step 5: Build the download list

The mapping files describe every image as:
`SOURCE@digest=REGISTRY_HOST/path:tag`

For the download step, you replace `REGISTRY_HOST` with `file:///` so images are saved
to local disk instead of pushed to a registry.

```bash
cd ~/bob-airgap-sim

LISTS=$(${AIRGAP_DIR}/mappings/select-lists.sh ${AIRGAP_DIR}/mappings/amd64 ${FEATURES})
echo "List files selected:"
echo "${LISTS}"

# Note: $LISTS is newline-separated paths — pipe through xargs so each path is a separate
# argument to cat. Passing $LISTS unquoted collapses newlines to spaces, which cat treats
# as one giant filename and errors with "file name too long".
echo "Total images: $(echo "${LISTS}" | xargs cat | grep -c .)"

# Build download list: source → local disk
echo "${LISTS}" | xargs cat | sed -E 's#=REGISTRY_HOST/#=file:///#' > download.lst
echo "Total images in download.lst: $(wc -l < download.lst)"
echo "First line:"
head -1 download.lst
```

**Expected result:** with `--zproxy --understand`, the total should be **47 images**.
The first line of `download.lst` should look like:
```
cp.icr.io/cp/bob/bob-admin@sha256:4544...=file:///cp/bob/bob-admin:1.8.1-amd64
```

---

## Step 6: Download images to local disk

This is the "connected host" side of the air gap. Images are saved to `./bob-images/`.

```bash
cd ~/bob-airgap-sim

oc image mirror \
  -f download.lst \
  -a ./auth.json \
  --dir=./bob-images \
  --keep-manifest-list \
  --skip-multiple-scopes \
  --max-per-registry=1
```

**This is the slow step.** With all features (`--zproxy --understand`) expect ~21 GiB and
a long wait. Core only (`FEATURES=""`) is much smaller.

**Expected result:** command exits 0. Last line starts with `info: Mirroring completed`.
`./bob-images/v2/` contains `cp/` and `cpopen/` directories.

If it fails partway, delete partial files and re-run:

```bash
find ./bob-images -name '*.download' -delete
# then re-run the oc image mirror command above
```

---

## Step 7: Push images from disk to the in-cluster registry

The stub kubeconfig from Step 3 is still active. Switch back to the real kubeconfig
first so `oc` can reach the cluster.

```bash
export KUBECONFIG=~/.kube/config
oc whoami   # must print kube:admin
```

Confirm `$DEST` is still set (if it is empty, re-run the Step 0.1 variable block):

```bash
echo "Registry: $DEST"
```

**Expected output:** `Registry: registry-bob-registry.apps.<cluster>.techzone.ibm.com`

Build the upload list fresh from the current `$DEST`, then push immediately:

```bash
cd ~/bob-airgap-sim

# Build upload list: local disk → in-cluster registry
# Always build this fresh — it embeds $DEST and goes stale if the registry changes.
LISTS=$(${AIRGAP_DIR}/mappings/select-lists.sh ${AIRGAP_DIR}/mappings/amd64 ${FEATURES})

echo "${LISTS}" | xargs cat \
  | sed -E \
      -e "s#=REGISTRY_HOST/#=${DEST}/#" \
      -e 's#^[^/]+/([^=]*@sha256:[0-9a-f]+)=#file:///\1=#' \
  > upload.lst

echo "Total images: $(wc -l < upload.lst)"
echo "First line:"
head -1 upload.lst
```

**Expected result:** 47 images. The first line should look like:
```
file:///cp/bob/bob-admin@sha256:4544...=registry-bob-registry.apps.<cluster>/cp/bob/bob-admin:1.8.1-amd64
```

The in-cluster `registry:2` has no auth — push directly with an empty auth file:

```bash
echo '{}' > auth-push.json

oc image mirror \
  -f upload.lst \
  -a ./auth-push.json \
  --from-dir=./bob-images \
  --keep-manifest-list \
  --skip-multiple-scopes \
  --insecure \
  --max-per-registry=1 > push.log 2>&1
echo "Exit: $?"
```

**Expected result:** command exits 0. Last line of `push.log` starts with
`info: Mirroring completed`.

Verify the images landed in the registry:

```bash
curl -sk https://${DEST}/v2/_catalog | python3 -m json.tool | head -10
```

**Expected result:** a JSON list of repository paths starting with `cp/bob/...` and
`cpopen/...`. If the list is empty or the command errors, the push did not complete
successfully — check `push.log` for errors.

---

## Step 8: Create `config.yaml` and `model-gateway.yaml`

```bash
cd $BOB_PKG

# Check available storage classes — you need one RWX and one RWO
oc get storageclass

cp config-template.yaml config.yaml
cp config-model-gateway-template.yaml model-gateway.yaml
```

Edit `config.yaml`. Set `imagePullPrefix` directly from `$DEST` — do not type the
hostname manually, copy-paste errors here cause `ImagePullBackOff` on every operator pod
in Step 9 with no obvious error message.

Minimum required values:

```yaml
global:
  operatorNamespace: ibm-bob-operators
  instanceNamespace: ibm-bob
  fileStorageClass: "ocs-storagecluster-cephfs"       # RWX — standard on TechZone
  blockStorageClass: "ocs-storagecluster-ceph-rbd"    # RWO — standard on TechZone
  imagePullPrefix: <DEST>                              # set by the sed command below — do not type manually
  imagePullSecretName: ibm-entitlement-key

bob:
  zProxy:
    enabled: true
  understand:
    enabled: true
```

Verify your storage classes first — if they differ, use `oc get storageclass` to find the
correct names.

Write `imagePullPrefix` directly from `$DEST` so it cannot be mistyped or go stale:

```bash
sed -i.bak "s|imagePullPrefix:.*|imagePullPrefix: ${DEST}|" $BOB_PKG/config.yaml \
  && rm $BOB_PKG/config.yaml.bak
grep imagePullPrefix $BOB_PKG/config.yaml
echo "DEST=$DEST"
```

Both lines must show the same hostname.

Edit `model-gateway.yaml` — point the `ACTIVE MODEL` section at your LLM provider
and fill in the correct `base_url` / region / project and credentials.

---

## Step 9: Install Bob

### 9.1 Install cert-manager (required prerequisite)

`bobctl install` checks for cert-manager before running and refuses to proceed if it is
not installed.

In an air-gapped cluster the OperatorHub catalogs and `quay.io` are unreachable, so
cert-manager is mirrored exactly like Bob's images in Steps 5–7:
**pull to your laptop → push to the in-cluster registry → install from there.**
It is four images plus one manifest file — both are already committed to `mappings/`:

| What | File in `mappings/` | Mirrored to |
|---|---|---|
| `cert-manager-controller`, `-webhook`, `-cainjector`, `-acmesolver` (v1.21.3) | `cert-manager.lst` | `$DEST/jetstack/` |
| CRDs + Deployment manifests | `cert-manager.yaml` | applied with image names rewritten to `$DEST` |

No `curl` or internet access is needed after this point — `cert-manager.yaml` is
carried across the gap with the rest of the `mappings/` directory.

> **Which cert-manager?** This is the upstream (Jetstack) release, not the Red Hat
> cert-manager Operator. It is the air-gap-friendly choice: no operator catalog to mirror,
> no extra tooling, and no additional credentials. It provides the same
> `certificates.cert-manager.io` CRD that `bobctl install` checks for. Bob requires
> v1.14 or later.
>
> **Do NOT use `oc mirror` or `oc-mirror` here.** Those are separate plug-in binaries
> (not built in to `oc`) that only run on Linux and require an `ImageSetConfiguration`.
> This guide uses `oc image mirror`, which is a built-in `oc` subcommand available on all
> platforms. If you see `error: unknown command "mirror" for "oc"`, you have run
> `oc mirror …` instead of `oc image mirror …`.

#### 9.1.1 Download cert-manager to local disk

This is Steps 5 and 6 again, for cert-manager. Stay in `~/bob-airgap-sim/` so the images
go into the **same** `./bob-images` directory — one directory is all you carry across the
gap. The `quay.io` images are public so no IBM credentials are needed; an empty
`auth.json` is sufficient if you are entering here fresh (e.g. from a new terminal after
Steps 5–7 are already done):

```bash
cd ~/bob-airgap-sim
# If auth.json does not exist or is stale, recreate it (quay.io is public — no credentials needed)
[[ -f auth.json ]] || echo '{}' > auth.json

# Build download list: source → local disk (same transform as Step 5)
sed -E 's#=REGISTRY_HOST/#=file:///#' ${AIRGAP_DIR}/mappings/cert-manager.lst > cm-download.lst
echo "Total images: $(wc -l < cm-download.lst)"
head -1 cm-download.lst

oc image mirror \
  -f cm-download.lst \
  -a ./auth.json \
  --dir=./bob-images \
  --keep-manifest-list \
  --skip-multiple-scopes \
  --max-per-registry=1
```

**Expected result:** 4 images. The first line of `cm-download.lst` looks like:
```
quay.io/jetstack/cert-manager-controller@sha256:9f4f...=file:///jetstack/cert-manager-controller:v1.21.3
```
`oc image mirror` exits 0 with `info: Mirroring completed` (about 300 MB).

#### 9.1.2 Push cert-manager to the in-cluster registry

This is Step 7 again. Stay in `~/bob-airgap-sim/`. Switch back to the real kubeconfig
and confirm `$DEST`:

```bash
export KUBECONFIG=~/.kube/config
oc whoami                        # must print kube:admin
echo "Registry: $DEST"           # must not be empty
```

Build the upload list fresh from the current `$DEST`, then push:

```bash
cd ~/bob-airgap-sim

# Build upload list: local disk → in-cluster registry (same transform as Step 7)
sed -E \
  -e "s#=REGISTRY_HOST/#=${DEST}/#" \
  -e 's#^[^/]+/([^=]*@sha256:[0-9a-f]+)=#file:///\1=#' \
  ${AIRGAP_DIR}/mappings/cert-manager.lst > cm-upload.lst

echo "Total images: $(wc -l < cm-upload.lst)"
head -1 cm-upload.lst

echo '{}' > auth-push.json

oc image mirror \
  -f cm-upload.lst \
  -a ./auth-push.json \
  --from-dir=./bob-images \
  --keep-manifest-list \
  --skip-multiple-scopes \
  --insecure \
  --max-per-registry=1 > cm-push.log 2>&1
echo "Exit: $?"
```

**Expected result:** the first line of `cm-upload.lst` looks like:
```
file:///jetstack/cert-manager-controller@sha256:9f4f...=registry-bob-registry.apps.<cluster>/jetstack/cert-manager-controller:v1.21.3
```
The push exits 0 and the last line of `cm-push.log` starts with `info: Mirroring completed`.
Verify the images landed:

```bash
curl -sk https://${DEST}/v2/_catalog | python3 -m json.tool | grep jetstack
```

**Expected result:** four `jetstack/cert-manager-*` repositories.

#### 9.1.3 Install cert-manager from the in-cluster registry

Rewrite the image references in the committed manifest so every pod pulls from `$DEST`,
then apply it. The cluster already trusts the registry (the `insecureRegistries` patch in
Step 1).

```bash
cd ~/bob-airgap-sim

sed "s#quay.io/jetstack/#${DEST}/jetstack/#g" \
  ${AIRGAP_DIR}/mappings/cert-manager.yaml > cert-manager-airgap.yaml

# No reference to quay.io may remain — this must print 0
grep -c 'quay.io' cert-manager-airgap.yaml

oc apply -f cert-manager-airgap.yaml --server-side
```

Wait for the three deployments, then confirm:

```bash
oc rollout status deployment/cert-manager -n cert-manager
oc rollout status deployment/cert-manager-webhook -n cert-manager
oc rollout status deployment/cert-manager-cainjector -n cert-manager

oc get pods -n cert-manager
oc get crd certificates.cert-manager.io
```

**Expected result:** three pods running — `cert-manager`, `cert-manager-cainjector`,
and `cert-manager-webhook` — and the `certificates.cert-manager.io` CRD exists.

### 9.2 Run the install

First generate and apply the cluster-scoped resources. This creates the
`ibm-bob-operators` and `ibm-bob` namespaces that `bobctl install` requires — it will
refuse to proceed with `Namespace 'ibm-bob' does not exist` if this step is skipped.

```bash
cd $BOB_PKG

./bobctl generate-cluster-resources

oc apply -f work/cluster-resources.yaml --force-conflicts --server-side
```

Confirm both namespaces exist before continuing:

```bash
oc get namespace ibm-bob-operators ibm-bob
```

**Expected result:**
```
NAME                STATUS   AGE
ibm-bob-operators   Active   Xs
ibm-bob             Active   Xs
```

Then run the install. Pass `--registry-creds cp:unused` to bypass the pull-secret
existence check — `bobctl install` requires either a pre-created `ibm-entitlement-key`
secret or this flag. Since `imagePullPrefix` in `config.yaml` points everything at the
in-cluster registry, no pod ever contacts `cp.icr.io` and the value is never evaluated.

```bash
./bobctl install \
  --accept-license \
  --model-config model-gateway.yaml \
  --registry-creds cp:unused
```

### 9.3 Watch progress

Run this to watch both namespaces refresh every 15 seconds:

```bash
watch -n 15 'oc get bob -n ibm-bob; echo; oc get pods -n ibm-bob-operators; echo; oc get pods -n ibm-bob'
```

> **macOS:** `watch` is not installed by default. Either install it (`brew install watch`) or
> use this equivalent:
> ```bash
> while true; do clear; oc get bob -n ibm-bob; echo; oc get pods -n ibm-bob-operators; echo; oc get pods -n ibm-bob; sleep 15; done
> ```

The install takes **20–30 minutes**. Pods come up in this order:

1. **Operators** (`ibm-bob-operators`) — all six go `1/1 Running` within ~2 minutes
2. **Databases** — `bob-db-1`, `bob-keycloak-db-1` go `1/1 Running`
3. **OpenSearch** — `bob-core-opensearch-nodes-000` and `-001` go `1/1 Running`; a snapshot job runs and completes
4. **Redis** — `bob-admin-redis-server-0` and `-1` go `2/2 Running`
5. **Keycloak** — `bob-keycloak-0` goes `1/1 Running` (this is usually the last pod)
6. **Bob CR flips** — `READY=True`

**You are done when the Bob CR shows `READY=True`:**

```
NAME     READY   MESSAGE   AGE
bob-cr   True              35m
```

Until then, `READY=False` with a message like `RAG workload is being provisioned` is
normal — it just means the operator is still waiting for a dependency to become ready.

---

### 9.4 Set up Z Understand and Refactor

> **Skip this step** if you did not enable `understand: {enabled: true}` in `config.yaml`.

Z Understand requires a one-time setup step after the Bob CR reaches `READY=True`. The
operator holds the Understand workload in a pending state until you create the setup secret
with your external database credentials.

**Before you start**, provision the database:

- **Db2** (port `50000`) or **SQL Server** (port `1433`) — must be reachable from inside the
  OpenShift cluster.
- Create a dedicated database user with read/write access.
- Note the host, port, username, and password — you will need them below.

Generate the two internal passwords first — these are not looked up anywhere, just set once
and saved:

```bash
GRAPH_DB_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
UNDERSTAND_ADMIN_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
echo "graphDatabaseServer.password : $GRAPH_DB_PASS"
echo "userAccess.password          : $UNDERSTAND_ADMIN_PASS"
```

Save both values somewhere safe — they cannot be recovered after setup completes.

**Create `setup.json`** from the README field table (the sample files are listed in the
README but not shipped in the package — create the file directly):

```bash
cat > $BOB_PKG/setup.json << EOF
{
  "relationalDatabaseServer": {
    "host": "<INSERT_DB_HOST>",
    "port": <INSERT_DB_PORT>,
    "username": "<INSERT_DB_USERNAME>",
    "password": "<INSERT_DB_PASSWORD>"
  },
  "graphDatabaseServer": {
    "password": "${GRAPH_DB_PASS}"
  },
  "userAccess": {
    "password": "${UNDERSTAND_ADMIN_PASS}"
  }
}
EOF
```

Replace the `<INSERT_...>` placeholders in `relationalDatabaseServer` with your real database
connection details. The `generalSettings.ip` field is not required; the controller resolves
the hostname automatically.

**Run setup:**

```bash
cd $BOB_PKG
./bobctl understand setup --config setup.json
```

The command:
1. Validates that `bob.understand.enabled: true` is on the cluster
2. Creates the secret `bobz-understand-setup` in the instance namespace
3. Patches the Bob CR to reference the secret

The controller unblocks and deploys the Understand workload. Watch for the pods:

```bash
oc get pods -n ibm-bob | grep understand
```

> **Keep `setup.json` out of source control** — it contains database credentials.
> Delete it from the install package directory once setup succeeds.

> **Note:** `bobctl understand setup` is a one-time operation and cannot be re-run once
> configured. To start over, run `bobctl understand uninstall` first (see the package README).

**Z Understand has no web UI.** Access is through the `bobctl understand cli` command, which
execs into the running pod. The `userAccess.password` you set above is the password for that
CLI session:

```bash
cd $BOB_PKG

# List all projects
./bobctl understand cli --ls

# Build a project
./bobctl understand cli -b MyProject

# Open a full interactive shell in the pod
./bobctl understand cli -a
```

---

## Step 10: Post-install

### 10.1 Get the Admin UI URL

```bash
echo "Admin UI: $BOB_ADMIN_UI"
echo "API base: $BOB_URL"
```

If `$BOB_ADMIN_UI` is empty, re-run the Step 0.1 variable block first.

**Expected result:**
```
Admin UI: https://bob.ibm-bob.apps.<cluster>.techzone.ibm.com
API base: https://api.bob.ibm-bob.apps.<cluster>.techzone.ibm.com
```

Open `$BOB_ADMIN_UI` in your browser — you will get a TLS warning until you trust the CA cert
in the next step. **All `curl` API calls in this guide use `$BOB_URL` (the `api.` host), not
`$BOB_ADMIN_UI`.**

### 10.2 Extract and trust the CA certificate

Extract the cert:

```bash
cd $BOB_PKG
./bobctl get-ca-cert --output ~/bob-ca.crt
openssl x509 -in ~/bob-ca.crt -noout -subject -issuer -dates
```

**Expected result:** subject and issuer both reference `ibm-bob`, with a validity window
several years in the future.

Trust it on your laptop so the browser and Bob CLI stop rejecting the TLS connection:

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/bob-ca.crt
```

**Linux:**
```bash
sudo cp ~/bob-ca.crt /usr/local/share/ca-certificates/bob-ca.crt
sudo update-ca-certificates
```

**Windows (PowerShell as Administrator — all users on this PC):**
```powershell
certutil -addstore -f Root "$env:USERPROFILE\bob-ca.crt"
```

Or for current user only (confirm the security prompt):
```powershell
certutil -user -addstore Root "$env:USERPROFILE\bob-ca.crt"
```

Also export it for Node.js so Bob Shell and Bob IDE trust the certificate:

**macOS / Linux:**
```bash
echo 'export NODE_EXTRA_CA_CERTS="$HOME/bob-ca.crt"' >> ~/.zshrc
source ~/.zshrc
```

**Windows (PowerShell — persists for your user; restart Bob and all terminals afterwards):**
```powershell
setx NODE_EXTRA_CA_CERTS "$env:USERPROFILE\bob-ca.crt"
```

### 10.3 Point Bob Shell / Bob IDE at this cluster

Set `gatewayUrl` in `~/.bob/settings/settings.json`. The gateway URL is the **`api.`** host
— not the Admin UI host. Run this to print the exact JSON to paste:

```bash
oc get ingress bob-gateway -n ibm-bob \
  -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' \
  | awk '/^api\./{print "{ \"gatewayUrl\": \"https://" $1 "/\" }"; exit}'
```

**Expected output:**
```
{ "gatewayUrl": "https://api.bob.ibm-bob.apps.<cluster>.techzone.ibm.com/" }
```

Copy the printed JSON into `~/.bob/settings/settings.json`. To switch back to Bob SaaS
later, rename the key to `gatewayUrl-old` and restart Bob.

### 10.4 Set the bob-admin password

```bash
# Wait for Keycloak to be ready
oc wait pod bob-keycloak-0 -n ${INSTANCE_NS} \
  --for=condition=Ready --timeout=300s

# Get bootstrap credentials
KC_USER=$(oc get secret bob-keycloak-initial-admin -n ${INSTANCE_NS} \
  -o jsonpath='{.data.username}' | base64 -d)
KC_PASS=$(oc get secret bob-keycloak-initial-admin -n ${INSTANCE_NS} \
  -o jsonpath='{.data.password}' | base64 -d)
KC_CONTAINER=$(oc get pod bob-keycloak-0 -n ${INSTANCE_NS} \
  -o jsonpath='{.spec.containers[0].name}')

# Authenticate kcadm
oc exec -n ${INSTANCE_NS} bob-keycloak-0 -c ${KC_CONTAINER} -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://bob-keycloak-service.${INSTANCE_NS}.svc:8080 \
    --realm master \
    --user "${KC_USER}" \
    --password "${KC_PASS}" \
    --config /tmp/kcadm.config

# Get bob-admin user ID
BOB_ADMIN_ID=$(oc exec -n ${INSTANCE_NS} bob-keycloak-0 -c ${KC_CONTAINER} -- \
  /opt/keycloak/bin/kcadm.sh get users -r bob \
    --config /tmp/kcadm.config \
    -q email=bob-admin@bob.ibm.com \
    --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -n1)
echo "bob-admin ID: ${BOB_ADMIN_ID}"
```

Set the password (you will be prompted):

```bash
read -rs BOB_ADMIN_PASS
oc exec -n ${INSTANCE_NS} bob-keycloak-0 -c ${KC_CONTAINER} -- \
  /opt/keycloak/bin/kcadm.sh set-password -r bob \
    --config /tmp/kcadm.config \
    --userid "${BOB_ADMIN_ID}" \
    --new-password "${BOB_ADMIN_PASS}"

oc exec -n ${INSTANCE_NS} bob-keycloak-0 -c ${KC_CONTAINER} -- \
  /opt/keycloak/bin/kcadm.sh update "users/${BOB_ADMIN_ID}" -r bob \
    --config /tmp/kcadm.config \
    -s emailVerified=true
echo "Password set for bob-admin@bob.ibm.com"
```

### 10.5 Verify end-to-end

#### 10.5.1 Create an API key in the Admin UI

1. Open `$BOB_ADMIN_UI` in your browser (printed by Step 0.1, or run `echo $BOB_ADMIN_UI`)
2. Sign in as `bob-admin@bob.ibm.com` with the password you set in Step 10.4
3. Navigate to **API Keys → Generate**
4. Copy the key — it starts with `bob_onprem_...` and cannot be viewed again after closing the dialog

```bash
export BOB_API_KEY="bob_onprem_..."   # paste your key here
```

#### 10.5.2 Run the CLI test

```bash
bob run --accept-license "Reply with exactly one word: hello"
```

**Expected result:** a single-word response.

| Error | Cause | Fix |
|---|---|---|
| TLS error / browser warning | CA cert not trusted or `NODE_EXTRA_CA_CERTS` not set | Re-run Step 10.2 |
| `Request Failed. Not Found` | `gatewayUrl` points at the Admin UI host instead of the `api.` host | Re-run Step 10.3 — URL must start with `https://api.bob.` |
| `401` / auth error | `gatewayUrl` wrong or `BOB_API_KEY` not exported | Check `~/.bob/settings/settings.json` and re-export `$BOB_API_KEY` |
| `unknown option '--auth-method'` | Flag not supported by this Bob Shell version | Remove `--auth-method api-key`; Bob picks up `BOB_API_KEY` automatically |
| `invalid jwt string` | `Authorization: Bearer` used instead of `APIKey` | Upgrade Bob Shell to a current version |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `repository name invalid: it must be of the format <project>/<name>` | Pushing to OCP internal registry (2-segment limit) | Use the in-cluster `registry:2` pod instead (Step 1) |
| `ImagePullBackOff` on Bob workload pods (not operators) mid-install | Image path mismatch or registry not trusted | Check `imagePullPrefix` matches `$DEST` exactly; confirm insecureRegistries patch was applied |
| `oc registry login` errors with kubeconfig | Stub kubeconfig still active | Run `export KUBECONFIG=~/.kube/config` then retry |
| `oc image mirror` exits non-zero mid-download | Network blip | Delete `*.download` files and re-run the download command |
| `helm: requires Helm 3.14+` warning | Old Helm ignores `--reset-then-reuse-values` | Already on 3.22 — safe to ignore |
| Push fails with `x509: certificate signed by unknown authority` | Registry TLS not trusted by laptop | Add `--insecure` to the `oc image mirror` push command (Step 7) |
| MachineConfigPool stuck after insecureRegistries patch | Nodes rebooting | Wait longer; check with `oc get mcp` |
| cert-manager pods `ImagePullBackOff` | Manifest still references `quay.io`, or images are not in the registry | Run `grep -c quay.io cert-manager-airgap.yaml` (must be 0) and re-check the `jetstack` repositories in the registry catalog (Step 9.1.2) |
| `oc image mirror` fails on `quay.io` in 9.1.1 with `502 Bad Gateway` | Transient quay.io outage | Re-run the same command; it resumes where it stopped |
| `error: unknown command "mirror" for "oc"` | You ran `oc mirror …` (the `oc-mirror` plug-in, not installed) instead of `oc image mirror …` | Change the command to `oc image mirror …` — `oc image mirror` is a built-in `oc` subcommand; `oc mirror` is a separate Linux-only binary |
| All operator pods `ImagePullBackOff` immediately after `bobctl install` | `imagePullPrefix` in `config.yaml` has a stale registry hostname from a previous reservation | Run `grep imagePullPrefix $BOB_PKG/config.yaml` and compare to `echo $DEST`. Fix with `sed -i.bak "s\|imagePullPrefix:.*\|imagePullPrefix: ${DEST}\|" $BOB_PKG/config.yaml && rm $BOB_PKG/config.yaml.bak` then re-run `bobctl install` |
| `$DEST` is empty in a new terminal | Shell variables not re-exported after opening a new session | Re-run the Step 0.1 variable block — `$DEST` is now set automatically from the live cluster route |

---

## Reference: image counts by feature

| Features (`FEATURES=`) | `select-lists.sh` flags | Images |
|---|---|---|
| Core only | `""` | 22 |
| RAG | `--rag` | 39 |
| Bob for Z | `--zproxy` | 42 |
| Z Understand | `--understand` | 44 |
| Bob for Z + Z Understand | `--zproxy --understand` | 47 |
