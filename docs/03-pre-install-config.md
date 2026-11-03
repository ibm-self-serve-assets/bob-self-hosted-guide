# Pre-install configuration — config files

> **Scope:** Verify cluster registry reachability, check your cluster storage, create
> `config.yaml` and `model-gateway.yaml`, and deploy an NFS provisioner if needed.
> Complete this before running `bobctl install`.

**Part of the IBM Bob on TechZone install series:**

1. [TechZone cluster provisioning](00-techzone-cluster-provisioning.md)
2. [Workstation prerequisites](01-workstation-prereqs.md)
3. [Obtain your IBM entitlement key](02-entitlement-key.md)
4. **Pre-install configuration — config files** ← you are here
5. [Manual install walkthrough](04-manual-install.md)

---

## §3 — Verify cluster registry reachability

Before starting the install, confirm that the cluster nodes can reach the registries
Bob pulls from. A blocked registry will cause `ImagePullBackOff` errors mid-install
with no clear indication of which registry is the problem.

Run the reachability test from inside the cluster using `oc debug`:

```bash
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') -- \
  chroot /host bash -c "
    curl -s -o /dev/null -w 'cp.icr.io: %{http_code}\n' --connect-timeout 8 https://cp.icr.io/v2/
    curl -s -o /dev/null -w 'icr.io:    %{http_code}\n' --connect-timeout 8 https://icr.io/v2/
  "
```

Expected output — both must return `401`, not `000`:

```
cp.icr.io: 401
icr.io:    401
```

| Result | Meaning |
|---|---|
| `401` | Registry is reachable — the auth gate responded. This is the correct result. |
| `000` | Hard timeout or DNS failure. The cluster cannot reach this registry. |

> If any registry returns `000`, the cluster's VPC Public Gateway or egress rules are
> blocking outbound HTTPS to that host. This must be resolved before proceeding — the
> direct-pull install path requires outbound access to both registries. Contact your
> TechZone reservation owner or IBM Cloud network administrator.

---

## §4 — Storage: check storage classes, provision NFS if needed

Bob requires:

| Purpose | Access mode | Recommended storage class |
|---|---|---|
| File storage (RWX) | ReadWriteMany | `ocs-storagecluster-cephfs` or `nfs-client` |
| Block storage (RWO) | ReadWriteOnce | `ocs-storagecluster-ceph-rbd` or `ibmc-vpc-block` |

### 4a — Check what is available

```bash
oc get sc
```

Bob requires one RWX class and one RWO class. A TechZone ODF cluster looks like:

```
NAME                                         PROVISIONER                             RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
ocs-external-storagecluster-ceph-rbd         openshift-storage.rbd.csi.ceph.com      Delete          Immediate           true                   100m
ocs-external-storagecluster-cephfs           openshift-storage.cephfs.csi.ceph.com   Delete          Immediate           true                   100m
ocs-storagecluster-ceph-rbd (default)        openshift-storage.rbd.csi.ceph.com      Delete          Immediate           true                   102m
ocs-storagecluster-ceph-rbd-virtualization   openshift-storage.rbd.csi.ceph.com      Delete          Immediate           true                   102m
ocs-storagecluster-cephfs                    openshift-storage.cephfs.csi.ceph.com   Delete          Immediate           true                   102m
openshift-storage.noobaa.io                  openshift-storage.noobaa.io/obc         Delete          Immediate           false                  94m
```

> **Note:** The `(default)` suffix after a class name is display-only — it is not part of
> the class name and does not affect whether it satisfies the requirement.

**If `ocs-storagecluster-cephfs` and `ocs-storagecluster-ceph-rbd` appear in the list** — ODF is
installed. Use them (they match the validated `config.yaml` in §5). Skip to §5.

**If only `ibmc-vpc-block` appears** — you need an RWX class. This is optional — ODF is the
recommended storage for Bob. If you don't have ODF installed, see:
[Appendix E — Deploy a managed NFS provisioner](#appendix-e--deploy-a-managed-nfs-provisioner).

*Only complete this appendix if your cluster doesn't have ODF storage classes.* After deploying
the NFS provisioner, update your `config.yaml` with the values shown below and return here to
continue to §5.

```yaml
fileStorageClass: nfs-client
blockStorageClass: ibmc-vpc-block
```

---

## §5 — Pre-flight configuration

Bob is configured via two YAML files that you create before running `bobctl install`:

| File | Purpose |
|---|---|
| `config.yaml` | Helm override values: namespaces, storage, image pull secret, model gateway secrets |
| `model-gateway.yaml` | Bifrost inference gateway: which LLM endpoints to route to, model aliases |

Both files must live in the **same directory as `bobctl`** (the install package root).
The automated install script (`bob-autoinstall.sh`) also expects them there — their names
are hardcoded and cannot be changed via environment variables in the autoinstall path.

### 5a — `config.yaml`

Copy `config-template.yaml` to `config.yaml` and fill in the two required storage class
fields and your model gateway API key. The template documents every available option —
the minimum working config for a fresh ODF-backed install is shown below. Substitute
your own storage class names if you deployed NFS in Appendix E.

```yaml
global:
  operatorNamespace: ibm-bob-operators
  instanceNamespace: ibm-bob

  fileStorageClass: ocs-storagecluster-cephfs    # RWX — ODF CephFS; Required
  blockStorageClass: ocs-storagecluster-ceph-rbd # RWO — ODF Ceph RBD; Required

  # imagePullPrefix defaults to icr.io — omit unless you are using a private mirror
  imagePullSecretName: ibm-entitlement-key

bob:
  modelGateway:
    modelConfig: model-gateway.yaml
    secrets:
      MY_INFERENCE_API_KEY: "<YOUR_API_KEY>"  # must match the env.* ref in model-gateway.yaml
```

> **Required fields:** `fileStorageClass` and `blockStorageClass` are the only fields
> you must change from the template. Everything else has a working default.

> **Storage substitution:** If you deployed NFS in Appendix E, use:
> ```yaml
> fileStorageClass: nfs-client
> blockStorageClass: ibmc-vpc-block
> ```

#### Optional add-ons

All of the following are disabled by default unless noted. Add these keys to your
`config.yaml` under the `bob:` block to enable them.

| Key | Default | Description |
|-----|---------|-------------|
| `bob.metrics.enabled` | `true` | Exposes a Prometheus `/metrics` endpoint on the Bob service. Enabled by default — set to `false` to disable. |
| `bob.rag.enabled` | `false` | Enables Retrieval-Augmented Generation. Automatically includes OpenSearch in the deployment and image mirroring. |
| `bob.zProxy.enabled` | `false` | Enables the zProxy / Z RAG stack (zProxy + hash API + zlookup MCP). Implicitly enables `rag` — you do not need to set `rag.enabled` separately. |
| `bob.understand.enabled` | `false` | Enables Z Understand and Refactor. Requires `./bobctl understand setup` after install. |

**Example — enabling metrics, RAG, and Understand:**

```yaml
bob:
  metrics:
    enabled: true          # expose Prometheus /metrics (default: true)

  rag:
    enabled: true          # add OpenSearch; required for Understand

  understand:
    enabled: true          # Z Understand and Refactor (run ./bobctl understand setup after install)

  modelGateway:
    modelConfig: model-gateway.yaml
    secrets:
      MY_INFERENCE_API_KEY: "<YOUR_API_KEY>"
```

**zProxy** (Z RAG stack) uses two optional sub-keys for the hash API secret:

```yaml
bob:
  zProxy:
    enabled: true
    # hashApiSecretName: ""     # Kubernetes Secret name holding the encryption key.
    #                           # Auto-created on first reconcile if omitted.
    # hashApiSecretKeyName: ""  # Key name (filename) inside that Secret.
    #                           # Defaults to a controller-chosen name if omitted.
```

### 5b — `model-gateway.yaml`

Copy `config-model-gateway-template.yaml` to `model-gateway.yaml` (or any filename —
pass it via `--model-config`). The template defines four provider examples in the
`x-providers` scratchpad section (`azure`, `bedrock`, `gemini`, `inference_service`).
Only the provider referenced in the `models:` block is active; the others are ignored.

The minimum structure Bob requires:

- **One primary model** (`exposed: true`) — the main inference model users and IDE
  extensions route to. Its `model_name` must match `routers[0].static.default_model`.
- **One or more aliases** — additional `model_name` entries that merge the primary
  model's config. The template ships `security` and `background` as examples.
- **A `routers:` block** — declares the routing strategy and the default model name.

A complete working example using Azure OpenAI:

```yaml
x-providers:
  azure: &azure
    openai_compatible:
      model: gpt-5.6-sol
      base_url: https://<resource>.cognitiveservices.azure.com/openai
      api_key: env.AZURE_API_KEY     # env.<VAR> resolves from bob.modelGateway.secrets
    model_info:
      exposed: true
      provider: openai
      family: gpt
      version: "5.6-sol"
      max_input_tokens: 270000
      max_output_tokens: 20000
      supports_prompt_caching: true
      supports_vision: true
      mode: chat

models:
  - &chat_llm
    <<: *azure
    model_name: premium-ide
    model_info:
      exposed: true

  - <<: *chat_llm
    model_name: security

  - <<: *chat_llm
    model_name: background

routers:
  - name: router
    strategy: static
    static:
      default_model: premium-ide
```

The secret value is injected by `config.yaml` → `bob.modelGateway.secrets.AZURE_API_KEY`.
Do not put the raw key value in `model-gateway.yaml`; put it only in `config.yaml`
(which stays out of source control).

> **Supported providers:** Azure OpenAI (`openai_compatible`), AWS Bedrock (`bedrock`),
> Google Vertex AI / Gemini (`vertex`), and any OpenAI-compatible endpoint
> (`openai_compatible` with a custom `base_url`). See the provider examples in
> `config-model-gateway-template.yaml` for the exact field names for each provider.
>
> **RHOAI Model Catalog / NVIDIA NIM:** Models deployed on-cluster via the
> [OpenShift AI Model Catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/working_with_the_model_catalog/deploying-a-model-from-the-model-catalog_working-model-catalog)
> (including [NVIDIA Nemotron models via the Red Hat AI Factory](https://www.redhat.com/en/blog/bringing-nemotron-models-red-hat-ai-factory-nvidia))
> expose an OpenAI-compatible inference endpoint. Use the `openai_compatible` provider
> and set `base_url` to the inference service's route URL from your cluster.

> **`model_info` fields:** `provider`, `family`, `version`, `mode`, `max_input_tokens`,
> `max_output_tokens`, `supports_prompt_caching`, `supports_vision`.

### 5c — Optional: use NVIDIA Nemotron models

If you do not have an Azure, Bedrock, or Gemini endpoint, you can route Bob to NVIDIA
Nemotron models hosted at `integrate.api.nvidia.com`. The repo ships ready-made templates
for this setup:

| Template | Copy to | Purpose |
|---|---|---|
| [`templates/nvidia/config.yaml`](../templates/nvidia/config.yaml) | `config.yaml` | Install config with the `NVIDIA_API_KEY` secret |
| [`templates/nvidia/model-gateway.yaml`](../templates/nvidia/model-gateway.yaml) | `model-gateway.yaml` | Gateway config that routes to `nvidia/nemotron-3-ultra-550b-a55b` |

**1. Get an NVIDIA API key**

Create a key at **[build.nvidia.com/settings/api-keys](https://build.nvidia.com/settings/api-keys)**
and copy it. Treat it like a password.

**2. Copy the templates into the install package root**

Run from the root of this repo, and replace `<path-to-ibm-bob>` with the directory that
contains `bobctl`:

```bash
cp templates/nvidia/config.yaml        <path-to-ibm-bob>/config.yaml
cp templates/nvidia/model-gateway.yaml <path-to-ibm-bob>/model-gateway.yaml
```

**3. Edit `config.yaml`**

- Set `NVIDIA_API_KEY` to the key you created.
- Confirm `fileStorageClass` and `blockStorageClass` match your cluster (see §4). If you
  deployed NFS in Appendix E, use `nfs-client` and `ibmc-vpc-block`.

```yaml
bob:
  modelGateway:
    modelConfig: model-gateway.yaml
    secrets:
      NVIDIA_API_KEY: "<YOUR_NVIDIA_API_KEY>"  # must match env.NVIDIA_API_KEY in model-gateway.yaml
```

**4. Review `model-gateway.yaml`**

No edits are required to use the default model. The template defines:

- **Provider** — `openai_compatible` with `base_url: https://integrate.api.nvidia.com`
  and `api_key: env.NVIDIA_API_KEY`, which resolves from `bob.modelGateway.secrets` in
  `config.yaml`.
- **Models** — the primary `premium-ide` model plus `security` and `background` aliases,
  all backed by the same Nemotron model.
- **Router** — `static` strategy with `premium-ide` as the default model.

To use a different Nemotron model, change `model` (and the matching `version` and token
limits under `model_info`) in the provider block.

> The secret name in `config.yaml` (`NVIDIA_API_KEY`) must exactly match the
> `env.<VAR>` reference in `model-gateway.yaml`. Do not put the raw key in
> `model-gateway.yaml`, and keep `config.yaml` out of source control.

---

## Appendix E — Deploy a managed NFS provisioner

Apply the manifest below. It creates a Namespace, ServiceAccount, RBAC, an NFS server
Deployment backed by an `emptyDir` volume, the NFS subdir provisioner Deployment, and
a `StorageClass` named `nfs-client`. All images are pulled from public registries —
no mirroring required.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nfs-provisioner
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
rules:
  - apiGroups: [""]
    resources: [endpoints]
    verbs: [get, list, watch, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-provisioner
roleRef:
  kind: Role
  name: nfs-client-provisioner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: [persistentvolumes]
    verbs: [get, list, watch, create, delete]
  - apiGroups: [""]
    resources: [persistentvolumeclaims]
    verbs: [get, list, watch, update]
  - apiGroups: [storage.k8s.io]
    resources: [storageclasses]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [events]
    verbs: [create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-provisioner
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: nfs-provisioner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      containers:
        - name: nfs-server
          image: docker.io/itsthenetwork/nfs-server-alpine:12
          securityContext:
            privileged: true
          env:
            - name: SHARED_DIRECTORY
              value: /exports
          volumeMounts:
            - mountPath: /exports
              name: nfs-vol
      volumes:
        - name: nfs-vol
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: nfs-provisioner
spec:
  ports:
    - name: nfs
      port: 2049
    - name: mountd
      port: 20048
    - name: rpcbind
      port: 111
  selector:
    app: nfs-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir-external-provisioner
            - name: NFS_SERVER
              value: nfs-server.nfs-provisioner.svc.cluster.local
            - name: NFS_PATH
              value: /exports
      volumes:
        - name: nfs-client-root
          nfs:
            server: nfs-server.nfs-provisioner.svc.cluster.local
            path: /exports
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
mountOptions:
  - nfsvers=4.1
EOF
```

Grant the provisioner ServiceAccount the SCC it needs to mount NFS volumes:

```bash
oc adm policy add-scc-to-user hostmount-anyuid \
  -z nfs-client-provisioner -n nfs-provisioner
```

Grant the NFS server the `privileged` SCC (required to bind port 2049):

```bash
oc adm policy add-scc-to-user privileged \
  -z default -n nfs-provisioner
```

Wait for both pods to be `Running`:

```bash
oc rollout status deployment/nfs-server -n nfs-provisioner
oc rollout status deployment/nfs-client-provisioner -n nfs-provisioner
```

Verify the StorageClass can provision an RWX volume before proceeding:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-rwx-test
  namespace: default
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
EOF

sleep 10
oc get pvc nfs-rwx-test -n default   # STATUS must be Bound
oc delete pvc nfs-rwx-test -n default
```

If the PVC stays `Pending`, check provisioner logs:

```bash
oc logs -n nfs-provisioner deployment/nfs-client-provisioner
```

The most common cause is the NFS server pod not yet `Running` — wait for it and retry.

Return to §4a and update your `config.yaml` storage class values, then continue to §5.

---

**Next:** [Manual install walkthrough →](04-manual-install.md)
