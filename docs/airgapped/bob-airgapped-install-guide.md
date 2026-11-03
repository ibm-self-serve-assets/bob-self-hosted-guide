# IBM Bob on OpenShift: air-gapped installation guide

This guide takes a platform team from nothing to a running self-hosted IBM Bob in an
OpenShift cluster that has no internet access. The container images are downloaded once on a
connected host, moved across the air gap, and loaded into the customer's Artifactory. The
cluster then pulls everything from Artifactory.

The guide uses only `oc`, `skopeo` and `helm`. It does not require IBM's `bobctl` tool. An
optional `bobctl` path is in [Appendix B](#appendix-b-using-bobctl-optional).

## At a glance

| Item | Value |
|---|---|
| Product release | IBM Bob install package `ibm-bob-install-20260924-163534` |
| Helm chart | `ibm-bob` 2.0.0 (app version 2.0.0-3) |
| Bob operator | 1.0.0 |
| Kubernetes | 1.33 or later |
| Architecture | `amd64` |
| Images to load | 22 for core Bob, up to 47 with every optional feature. You choose in [section 3](#3-choose-your-features) |
| Download size | up to about 21 GiB for the `amd64` set. Core Bob alone is much smaller |
| Source registries | `cp.icr.io` (needs an IBM entitlement key) and `icr.io` (anonymous) |
| Helm repository needed | None. All charts are in the install package |
| Always installed | Bob core, Keycloak, PostgreSQL, Redis, usage metering |
| Optional features | RAG (with OpenSearch), Bob for Z (zProxy), Z Understand and Refactor |

**Decide which optional features you need before Step 1.** They change which images you
download, what you put in `values.yaml`, and whether you need an extra setup step after the
install.

### Files that go with this guide

| File | Purpose |
|---|---|
| [`bob-image-inventory.csv`](bob-image-inventory.csv) | Every image with registry, path, tag, digest and architecture. 144 rows |
| [`mappings/amd64/*.lst`](mappings/amd64) | Ready-made `oc image mirror` lists for an `amd64` cluster, split by feature |
| [`mappings/full/*.lst`](mappings/full) | The same lists with every architecture of each image. Larger |
| [`mappings/select-lists.sh`](mappings/select-lists.sh) | Prints the list files that match the features you choose |
| [`mappings/oc-mirror/image-set-config.yaml`](mappings/oc-mirror/image-set-config.yaml) | All 47 images as an `oc-mirror` v2 configuration, grouped by feature |

### Who needs which credential

| Credential | Held by | Used for |
|---|---|---|
| IBM entitlement key | Connected host only | Pulling `cp.icr.io` images in [Step 1](#step-1-download-the-images-connected-host) |
| Artifactory push account | Air-gapped host | Loading images in [Step 3](#step-3-push-the-images-to-artifactory-air-gapped-side) |
| Artifactory read account | OpenShift cluster | The image pull secret in [Step 4](#step-4-install-bob) |
| Cluster-admin on OpenShift | Installer | Applying cluster resources and running Helm |

The entitlement key never needs to enter the air-gapped network.

---

## 1. How the install works

No machine is assumed to reach both the internet and the customer's network. The work is split
across the gap:

| Procedure | Where | What happens |
|---|---|---|
| Step 1: Download | Connected Linux host | Pull the images from IBM's registries to local disk |
| Step 2: Package and transfer | Connected host, then across the gap | Checksum the files and carry them over by your approved transfer method |
| Step 3: Push | Air-gapped Linux host | Load the images into Artifactory |
| Step 4: Install | Air-gapped Linux host | Apply the Bob charts with Helm. The cluster pulls from Artifactory |

You need free disk on each side for the images you chose. Plan for up to 21 GiB if you take every
feature.

Sections 2 to 4 give the background and requirements. The numbered Steps 1 to 4 are the
procedure, in order.

## 2. Prerequisites

### Connected host (Linux)

- `oc` (the OpenShift client), 4.x
- `skopeo`
- Free disk for the images you chose (up to about 21 GiB), plus room for a copy if you package the files
- Outbound HTTPS to `cp.icr.io` and `icr.io`
- The customer's IBM entitlement key (IBM Container Library at myibm.ibm.com)
- Optional: `oc-mirror` v2, only if the transfer path limits file size (see [Step 2](#step-2-package-and-transfer))
- CA certificates installed on the host (a minimal container without them fails with `x509: certificate signed by unknown authority`)

### Air-gapped host (Linux)

- `oc`, `skopeo` and `helm` 3.14 or later
- Optional: `oc-mirror` v2, only if you used it in [Step 2](#step-2-package-and-transfer)
- Network access to Artifactory and to the OpenShift API
- The IBM Bob install package, supplied by IBM (for the `charts/` directory and the model gateway template)
- This guide and its `mappings/` directory
- Free disk for the transferred images (up to about 21 GiB)

### Artifactory

Your Artifactory owner must provide each of these:

- [ ] A Docker repository (or virtual repository) that accepts pushes of multi-architecture images and serves them back unchanged. Bob pulls by digest.
- [ ] One registry address that serves both the `cp/` and `cpopen/` paths. See [Registry layout](#4-registry-layout).
- [ ] A push account for the loader and a read-only account for the cluster.
- [ ] The Artifactory TLS certificate is trusted by the air-gapped host. If it uses a private CA, either add the CA to the host trust store or pass `--certificate-authority=<ca.crt>` to `oc image mirror`.
- [ ] No repository policy rewrites tags or blocks digest-addressed pulls.

### OpenShift cluster

- [ ] Kubernetes 1.33 or later
- [ ] **cert-manager Operator for Red Hat OpenShift** installed (mirror it through your normal OperatorHub process; it is not part of this guide). If you prefer to mirror the upstream Jetstack release instead of OperatorHub, use `mappings/cert-manager.lst` — see the [TechZone simulation guide](techzone-simulation-guide.md) (section 9.1) for the full mirroring and install steps.
- [ ] A ReadWriteMany storage class and a ReadWriteOnce storage class
- [ ] Cluster nodes trust the Artifactory TLS certificate. For a private CA, add it through the cluster image configuration (`additionalTrustedCA`)
- [ ] An inference endpoint for the model gateway that the cluster can reach (see [Model gateway](#model-gateway))
- [ ] Only if you enable Z Understand and Refactor: a database it can reach, supplied in `setup.json` (see [Step 4.7](#step-4-install-bob))

## 3. Choose your features

Bob has a core and three optional features. Each optional feature is switched on in
`values.yaml` ([Step 4.1](#step-4-install-bob)) and needs its own images in Artifactory. If a
feature is on and its images are missing, its pods stay in `ImagePullBackOff`. If a feature is
off, you can leave its images out.

| Feature | `values.yaml` switch | What it gives you | Extra images | Extra setup after install |
|---|---|---|---|---|
| **Core** (always on) | none | Bob gateway, admin, authentication, inference, metering, Keycloak, PostgreSQL, Redis | 22 | None |
| **Metrics** | `bob.metrics.enabled` (on by default) | Prometheus `/metrics` endpoint | None known | None |
| **RAG** | `bob.rag.enabled` | Retrieval-augmented generation: knowledge snapshot restore, RAG MCP server, OpenSearch | 17 | None |
| **Bob for Z** (zProxy) | `bob.zProxy.enabled` | Z shell proxy, hash API and zlookup MCP. **Turns on RAG too** | 3, plus the 17 RAG images | None. A hash-API secret is created for you |
| **Z Understand and Refactor** | `bob.understand.enabled` | Z code understanding and refactoring | 5, plus the 17 RAG images | **Yes.** A `setup.json` secret with database settings ([Step 4.7](#step-4-install-bob)) |

Image totals by choice:

| What you enable | `select-lists.sh` options | Images |
|---|---|---|
| Core only | none | 22 |
| RAG | `--rag` | 39 |
| Bob for Z | `--zproxy` | 42 |
| Z Understand and Refactor | `--understand` | 44 |
| Bob for Z and Z Understand | `--zproxy --understand` | 47 |

**How the images were assigned to features.** The chart hands the operator every image as one
flat list and does not say which feature uses which. The assignment above comes from image names
and from the example cluster snapshot, which ran with RAG, zProxy and Understand all off. It
started none of the RAG, Bob for Z or Understand images and none of the OpenSearch images. Treat
the assignment as well founded but not confirmed by IBM. If you are unsure, mirror everything. The
extra images cost disk and transfer time, nothing else.

**Sizes.** The RAG knowledge snapshots are the bulk of the download: three of the four chunks
are about 3.1 to 3.2 GiB each, so RAG adds at least 9.5 GiB. `bobz-understand` is about 2.4 GiB.
If you do not use RAG, Bob for Z or Understand, you skip all of that.

**Dependencies the charts enforce.**
- `bob.zProxy.enabled: true` implies RAG. Both IBM's `bobctl` and the operator treat it that way.
- RAG needs OpenSearch. The guide sets `opencontent-opensearch.enabled: true` for you whenever RAG is on.
- IBM's own pre-install notes call OpenSearch "required for Understand". The guide therefore treats Understand as needing RAG's images too.

**One image is unaccounted for.** The chart also names an image, `cp/bob/vector`, that is in no
IBM image list and cannot be pulled from `cp.icr.io`. The example cluster, which had metrics on,
ran no pod from it, so a core install does not need it. It is not known which feature, if any,
launches it. If a pod is stuck pulling it, report it to IBM. See open question 1.

The full list with tags is in [Appendix A](#appendix-a-image-list). Digests are in
[`bob-image-inventory.csv`](bob-image-inventory.csv).

The `amd64/` lists copy single-architecture images and tag them `<version>-amd64`. All images —
including PostgreSQL and Redis — use amd64-specific digests.
The cluster pulls by digest, so the tags only label the images.

## 4. Registry layout

Every Bob chart builds each image reference the same way: the configured
`imagePullPrefix`, then the original repository path, then the original digest.

```text
<imagePullPrefix>/<repository path>@<digest>

source:  cp.icr.io/cp/bob/bob-admin@sha256:4544...4b64
target:  <artifactory-host>/cp/bob/bob-admin@sha256:4544...4b64
```

This sets three rules for Artifactory:

1. **One address serves both `cp/` and `cpopen/`.** The charts replace both `icr.io` and `cp.icr.io` with the one prefix.
2. **Paths are not renamed.** `cp/bob/bob-admin` stays `cp/bob/bob-admin`.
3. **Digests are preserved.** Do not let any process re-sign or convert the manifests.

The prefix can include a repository key, for example `artifactory.example.com/docker-local`.
Artifactory's subdomain and port access methods give a prefix with no path; its
repository-path method gives `host/<repository-key>`.

---

## Step 1: Download the images (connected host)

**1.1 Create a stub kubeconfig.** `oc registry login` refuses to run without a kubeconfig,
even though it never contacts a cluster. A stub is enough.

```bash
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
```

**1.2 Log in to `cp.icr.io`.** The username is the literal text `cp`. The password is the
entitlement key. `icr.io` needs no login.

```bash
read -rs ENTITLEMENT_KEY    # paste <IBM_ENTITLEMENT_KEY>, then press Enter
oc registry login --auth-basic "cp:${ENTITLEMENT_KEY}" --registry cp.icr.io -a ./auth.json
```

This writes `auth.json`. Treat it as a secret and delete it when the download is done.

**1.3 Build the download list.** Each line of the mapping files is
`SOURCE@digest=REGISTRY_HOST/path:tag`. For a download to disk, the target becomes `file:///`.

Set `FEATURES` to match the features you chose in [section 3](#3-choose-your-features). Use
`--rag`, `--zproxy` and `--understand`, in any combination, or leave it empty for core Bob only.
`select-lists.sh` adds the OpenSearch and shared helper images for you.

```bash
FEATURES="--zproxy"        # example: Bob for Z. Use "" for core only, "--zproxy --understand" for both

LISTS=$(mappings/select-lists.sh mappings/amd64 ${FEATURES})
echo "${LISTS}"                                   # check the files it picked
echo "$(cat ${LISTS} | grep -c .) images"         # compare with the totals in section 3

cat ${LISTS} | sed -E 's#=REGISTRY_HOST/#=file:///#' > download.lst
```

Write down the `FEATURES` value. You need the same value in 3.1 and 3.3. It must also match the
switches you put in `values.yaml` in 4.1.

**1.4 Download.**

```bash
oc image mirror -f download.lst -a ./auth.json --dir=./bob-images \
  --keep-manifest-list --skip-multiple-scopes --max-per-registry=1
```

`--max-per-registry=1` keeps the load on the registry low. The download is about 21 GiB.

**Tag naming:** all lists in `mappings/amd64/` use an `-amd64` tag suffix because they copy
single-architecture images. The Redis (`ibm-redis-cp.lst`) and PostgreSQL (`ibm-pg-operator.lst`)
lists now use the amd64-specific digests (for example `:1.4.0-amd64`), consistent with the Bob
core and Keycloak lists.

**Expected result:** the command exits with status 0 and the last line starts with
`info: Mirroring completed`. `./bob-images/v2/` contains `cp/` and `cpopen/` directories.

If the command fails part-way, delete the partial files and run it again:

```bash
find ./bob-images -name '*.download' -delete
```

## Step 2: Package and transfer

Create checksums so the receiving side can detect any change in transit.

```bash
(cd bob-images && find . -type f -exec sha256sum {} +) > bob-images.sha256
```

Move these across the gap: `bob-images/`, `bob-images.sha256`, this guide, the `mappings/`
directory, and the IBM Bob install package (it supplies the Helm charts for Step 4). On the
far side, check the files:

```bash
(cd bob-images && sha256sum -c ../bob-images.sha256 --quiet) && echo "all files match"
```

### If the transfer path limits file size

Some transfer paths accept only files up to a fixed size (for example 10 GB) and scan them.
A directory tree split with `tar | split` can fail that scan. `oc-mirror` v2 produces
archives of a controlled size instead, and replaces Steps 1.3 to 1.4 and the Step 3 push.
The supplied configuration lists all 47 images in labelled groups. Before you run it, delete the
groups for features you did not choose, using the same rules as `select-lists.sh`.

On the connected host, after the login in 1.2:

```bash
oc-mirror --v2 -c mappings/oc-mirror/image-set-config.yaml file://$PWD/bob-archive \
  --authfile ./auth.json --cache-dir $PWD/oc-mirror-cache \
  --parallel-images 1 --parallel-layers 1 --image-timeout 60m --retry-times 5 \
  --strict-archive
```

The result is a set of `mirror_000001.tar`, `mirror_000002.tar` and so on in `bob-archive/`.
`archiveSize` in the configuration is a whole number of gigabytes (`9` in the supplied file).
Transfer the whole `bob-archive/` directory plus `image-set-config.yaml`.

On the air-gapped host, push straight from the archives:

```bash
oc-mirror --v2 -c image-set-config.yaml --from file://$PWD/bob-archive \
  docker://<artifactory-host> --authfile ./auth.json --cache-dir $PWD/oc-mirror-cache \
  --parallel-images 1 --parallel-layers 1 --image-timeout 60m
```

`oc-mirror` creates `<artifactory-host>/cp/...` and `<artifactory-host>/cpopen/...` with the
original tags and digests, which is the layout the charts need. It pushes to a registry root,
so use it only when Artifactory is reached by subdomain or port. If Artifactory uses the
repository-path method (`host/<repository-key>`), use the `oc image mirror` route in Step 3
instead. `oc-mirror` also writes `ImageDigestMirrorSet` files in
`bob-archive/working-dir/cluster-resources/`. Bob does not need them.

If you used `oc-mirror`, skip the push in Step 3 and go to 3.3 to check the result. Set `DEST`
first, as in 3.1. In the `oc-mirror` push command above, `auth.json` must hold your Artifactory
login: create the stub kubeconfig from 1.1 and log in as in 3.2.

## Step 3: Push the images to Artifactory (air-gapped side)

**3.1 Build the upload list.** Replace `REGISTRY_HOST` with your registry address (with the
repository key if you use one), and point each source at the downloaded files. Use the same
`FEATURES` value as in 1.3.

```bash
export DEST=<artifactory-host>            # or <artifactory-host>/<repository-key>
FEATURES="--zproxy"                       # the same value you used in 1.3

LISTS=$(mappings/select-lists.sh mappings/amd64 ${FEATURES})

cat ${LISTS} \
  | sed -E -e "s#REGISTRY_HOST#${DEST}#" \
           -e 's#^[^/]+/([^=]*@sha256:[0-9a-f]+)=#file:///\1=#' > upload.lst
```

Check the first line. It should look like this:

```text
file:///cp/bob/ad-core-server@sha256:2900...0c=<artifactory-host>/cp/bob/ad-core-server:3.1.0-amd64
```

**3.2 Log in and push.**

```bash
export KUBECONFIG=$PWD/kube.yaml          # the stub kubeconfig from step 1.1
read -rs ARTIFACTORY_TOKEN
oc registry login --auth-basic "<user>:${ARTIFACTORY_TOKEN}" --registry <artifactory-host> -a ./auth.json

oc image mirror -f upload.lst -a ./auth.json --from-dir=./bob-images \
  --keep-manifest-list --skip-multiple-scopes --max-per-registry=1
```

If Artifactory uses a private CA that the host does not trust, add
`--certificate-authority=<ca.crt>` to the command.

**3.3 Check the result.** This script compares each image's manifest in Artifactory with the
digest in the mapping files. A match means the image arrived unchanged.

```bash
skopeo login <artifactory-host>           # once, with the read or push account

cat > check-mirror.sh <<'EOF'
#!/usr/bin/env bash
# usage: check-mirror.sh <registry-host[/prefix]> <list-file>...
dest="$1"; shift; fail=0
for f in "$@"; do
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    want="${line%%=*}"; want="${want#*@sha256:}"
    ref="${line#*=}"; ref="${ref/REGISTRY_HOST/$dest}"
    got=$(skopeo inspect --format '{{.Digest}}' "docker://${ref}" 2>/dev/null | sed 's/sha256://')
    if [ "$got" = "$want" ]; then echo "OK    $ref"; else echo "FAIL  $ref"; fail=1; fi
  done < "$f"
done
exit $fail
EOF
chmod +x check-mirror.sh
./check-mirror.sh "${DEST}" ${LISTS}
```

**Expected result:** one `OK` line per image, so 22 for core only up to 47 with every feature (see
the totals in [section 3](#3-choose-your-features)), and exit status 0. Any `FAIL` line names an
image to push again. If you used `oc-mirror`, set `FEATURES` and `LISTS` as in 3.1 first.

---

## Step 4: Install Bob

Everything in this step runs on the air-gapped host with `oc` logged in to the cluster. The
charts come from the `charts/` directory of the install package.

**4.1 Create the values file.** Save as `values.yaml`. The `global:` block is the same for every
install. The `bob:` block must match the `FEATURES` you mirrored in Step 1: turn on each feature
you mirrored, and no other.

```yaml
global:
  operatorNamespace: ibm-bob-operators
  instanceNamespace: ibm-bob
  fileStorageClass: <RWX storage class>
  blockStorageClass: <RWO storage class>
  imagePullPrefix: <artifactory-host>        # or <artifactory-host>/<repository-key>
  imagePullSecret: bob-registry-pull
```

| You mirrored | Add this under `bob:` |
|---|---|
| Core only (`FEATURES=""`) | Nothing. Leave `bob:` out unless you add model secrets in 4.2 |
| RAG (`--rag`) | `rag: {enabled: true}` |
| Bob for Z (`--zproxy`) | `zProxy: {enabled: true}`. This also turns on RAG, so you do not set `rag` |
| Z Understand and Refactor (`--understand`) | `understand: {enabled: true}` **and** `rag: {enabled: true}`. IBM's notes say OpenSearch is required for Understand, and only `rag` or `zProxy` turns it on. This is the cautious reading. See open question 9 |

For example, Bob for Z and Z Understand and Refactor together:

```yaml
bob:
  zProxy:
    enabled: true        # Bob for Z. Also turns on RAG and OpenSearch
  understand:
    enabled: true        # Z Understand and Refactor. Needs the extra setup in 4.7
```

Never turn on a feature whose images you did not mirror. Its pods would stay in
`ImagePullBackOff`. Turning a feature on later means mirroring its images first (Steps 1 to 3
with the new `FEATURES`), then running `helm upgrade` with the new switch.

`imagePullSecret` is the chart's key. (The `imagePullSecretName` key in IBM's
`config-template.yaml` is a `bobctl` setting and the charts ignore it.)

**OpenSearch switch.** OpenSearch is a separate chart that is off by default. Turn it on with a
Helm flag whenever `bob.rag.enabled` or `bob.zProxy.enabled` is `true`, and leave it off
otherwise. Set this variable once. The Helm commands in 4.3 and 4.5 use it:

```bash
# RAG, Bob for Z, or Z Understand and Refactor (any of the three):
OPENSEARCH="--set opencontent-opensearch.enabled=true"
# Core only:
# OPENSEARCH=""
```

**4.2 Prepare the model gateway file.** Copy `config-model-gateway-template.yaml` from the
install package to `model-gateway.yaml` and edit it. See [Model gateway](#model-gateway).
If an entry reads its key from `env.<NAME>`, add that key to `values.yaml` now, before 4.5:

```yaml
bob:
  modelGateway:
    secrets:
      <NAME>: <your inference API key>
```

Merge this under the existing `bob:` block in `values.yaml`. Keep that file out of source control.

**4.3 Create the namespaces, CRDs and cluster roles.**

```bash
helm template ibm-bob-cluster-scoped ./charts/ibm-bob-cluster-scoped -f values.yaml \
  ${OPENSEARCH} > cluster-resources.yaml

oc apply -f cluster-resources.yaml --server-side --force-conflicts
```

`--force-conflicts` avoids an "annotations too long" error on the large CRDs.

**Expected result:** the two namespaces `ibm-bob-operators` and `ibm-bob` exist
(`oc get ns ibm-bob ibm-bob-operators`).

**4.4 Create the image pull secret in both namespaces.** It must have the same name as
`global.imagePullSecret` and use the read-only Artifactory account.

```bash
read -rs READ_TOKEN        # the read-only account's token
for ns in ibm-bob-operators ibm-bob; do
  oc create secret docker-registry bob-registry-pull -n "$ns" \
    --docker-server=<artifactory-host> \
    --docker-username=<read-user> --docker-password="${READ_TOKEN}"
done
```

**4.5 Install.**

```bash
helm upgrade --install --reset-then-reuse-values ibm-bob ./charts/ibm-bob \
  -n ibm-bob -f values.yaml \
  --set global.arch=amd64 \
  --set global.licenseAccept=true \
  ${OPENSEARCH} \
  --set-file bob.modelGateway.modelConfig=model-gateway.yaml
```

`global.licenseAccept=true` means you accept the IBM license in `charts/ibm-bob/LICENSE`.
`--reset-then-reuse-values` needs Helm 3.14 or later; older versions ignore it and
values can drift on upgrade.

**4.6 Watch the install.**

```bash
oc get pods -n ibm-bob-operators                    # operators start first
oc get bob -n ibm-bob                               # the Bob instance and its version
oc logs -n ibm-bob-operators deployment/ibm-bob-operator -f
```

Check whether the Bob instance is available. Repeat until it prints `True`:

```bash
oc get bob -n ibm-bob \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}{"\n"}'
```

Then print the URL:

```bash
oc get ingress bob-gateway -n ibm-bob \
  -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' | awk '!/^api\./{print "https://" $1; exit}'
```

**Expected result:** no pod is in `ImagePullBackOff`, the `Available` condition is `True`, and
the second command prints the Bob URL.

Each optional feature reports its own state on the Bob resource. Check the ones you turned on:

```bash
oc get bob -n ibm-bob -o jsonpath='{range .items[*]}rag={.status.rag.status} zProxy={.status.zProxy.status} understand={.status.understand.status}{"\n"}{end}'
```

A feature you did not enable shows `Disabled`. A feature you enabled should leave `Disabled`
and settle on a ready state. Z Understand and Refactor stays unready until you finish 4.7.

**4.7 Set up Z Understand and Refactor (only if enabled).** Skip this if you did not turn on
`bob.understand.enabled`. Understand needs a one-time setup that supplies its database
settings. IBM's `bobctl` does this with `./bobctl understand setup --config setup.json`. Without
`bobctl` the same two actions are:

1. Make sure the install in 4.5 has run with `bob.understand.enabled: true`. `bobctl` refuses to
   run setup before that, so do the same here.
2. Create the secret from IBM's `setup.json` and point the Bob resource at it. The secret must be
   in the instance namespace and must hold the file under the key `setup.json`.

```bash
oc create secret generic bobz-understand-setup -n ibm-bob --from-file=setup.json=./setup.json

BOB_NAME=$(oc get bob -n ibm-bob -o jsonpath='{.items[0].metadata.name}')
oc patch bob "${BOB_NAME}" -n ibm-bob --type=merge \
  -p '{"spec":{"understand":{"setupSecretName":"bobz-understand-setup"}}}'
```

Then repeat this until it prints `Ready`. It can take up to 15 minutes:

```bash
oc get bob "${BOB_NAME}" -n ibm-bob -o jsonpath='{.status.understand.status}{"\n"}'
```

`setup.json` comes from IBM, in two samples: `setup.sample.ocp.db2.json` and
`setup.sample.ocp.sqlserver.json`. They name the database that Understand uses (Db2 or SQL
Server). That database is the customer's, so the cluster must be able to reach it. The samples
were not in the install package this guide was written against, so their contents are not
described here. Get them and the database requirements from IBM before the install day. Keep
`setup.json` out of source control: it holds database credentials.

## 5. After the install

### Model gateway

The model gateway sends requests to the language model endpoints you configure. In an air gap
these must be endpoints the cluster can reach, for example a model served inside the network.

- The file needs a `models:` section and a `routers:` section.
- Three model names are required: `premium-ide`, `security` and `background`. The template defines all three.
- API keys for the endpoint go under `bob.modelGateway.secrets` in `values.yaml`. Keep that file out of source control.

### TLS and client trust

By default the cluster generates the certificate. Export its CA so IDE and Bob Shell clients
can trust it:

```bash
oc get secret bob-external-tls -n ibm-bob -o jsonpath='{.data.ca\.crt}' | base64 --decode > bob-ca.crt
```

Distribute `bob-ca.crt` to the client machines. If the customer uses its own certificate,
create a secret with `tls.crt` and `tls.key` (and `ca.crt` if available), then point the Bob
resource at it:

```bash
oc create secret generic <tls-secret> -n ibm-bob \
  --from-file=tls.crt=<tls.crt> --from-file=tls.key=<tls.key> --from-file=ca.crt=<ca.crt>

BOB_NAME=$(oc get bob -n ibm-bob -o jsonpath='{.items[0].metadata.name}')
oc patch bob "${BOB_NAME}" -n ibm-bob --type=merge \
  -p '{"spec":{"externalCertificate":{"secretName":"<tls-secret>"}}}'
```

### Image sources are not rewritten at the cluster level

Bob reads the registry from `imagePullPrefix`, so no `ImageDigestMirrorSet` is required.

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `oc registry login`: "Missing or incomplete configuration info" | No kubeconfig | Use the stub in step 1.1 and set `KUBECONFIG` |
| Pull from `cp.icr.io`: "unauthorized" | Wrong or missing entitlement key | Log in again in step 1.2 with username `cp` |
| Download fails, rerun says "link ... .download: file exists" | A previous run was interrupted | `find ./bob-images -name '*.download' -delete`, then rerun |
| "context deadline exceeded" on a large blob | Slow link or heavy parallelism | Rerun `oc image mirror` (it resumes). For `oc-mirror`, keep `--parallel-images 1 --parallel-layers 1` and raise `--image-timeout` |
| `x509: certificate signed by unknown authority` from `oc`, `skopeo` or `oc-mirror` on a host | Host lacks CA certificates, or Artifactory uses a private CA | Install CA certificates, or add the CA to the host trust store, or pass `--certificate-authority` |
| Pod `ImagePullBackOff`, "unauthorized" | Pull secret missing from one namespace, wrong name, or wrong registry host | Create it in **both** namespaces; its name must equal `global.imagePullSecret` |
| Pod `ImagePullBackOff`, "manifest unknown" | Image or digest not in Artifactory, or the path is wrong | Run `check-mirror.sh`. Compare `imagePullPrefix` with the registry layout in section 4 |
| Pod `ImagePullBackOff`, `x509` from the node | Nodes do not trust Artifactory's certificate | Add the CA through the cluster image configuration (`additionalTrustedCA`) |
| `helm`: Kubernetes version error | Cluster older than 1.33 | Upgrade the cluster |
| Values change unexpectedly on upgrade | Helm older than 3.14 | Upgrade Helm |
| Bob instance never becomes ready, no pods start | cert-manager missing | Install the cert-manager Operator for Red Hat OpenShift |
| A feature's pods are in `ImagePullBackOff`, but core pods are fine | The feature is on in `values.yaml` but its images were not mirrored (a different `FEATURES` in Step 1) | Rerun Steps 1 to 3 with the right `FEATURES`, then `check-mirror.sh` |
| `status.zProxy.status` or `status.rag.status` stays `Disabled` after install | The switch is missing from `values.yaml`, or Helm used old values | Check `oc get bob -o yaml`. Rerun `helm upgrade` with the right `bob:` block |
| RAG pods start but the OpenSearch pods never appear | `opencontent-opensearch.enabled` was not set | Set `OPENSEARCH` as in 4.1 and rerun 4.3 and 4.5 |
| `status.understand.status` stays pending or `ReconcileError` | The setup secret is missing, or `setup.json` is wrong or its database is unreachable | Check `oc get secret bobz-understand-setup -n ibm-bob` and the operator log (`oc logs -n ibm-bob-operators deployment/ibm-bob-operator`) |

---

## Appendix A: Image list

All images are in [`bob-image-inventory.csv`](bob-image-inventory.csv) with their digests.
Columns: `group, source_registry, repository_path, tag, digest, arch, source_ref_by_digest`.
Rows with `arch=list` are the multi-architecture manifest list; `amd64` rows are the
single-architecture image the charts pull by digest.

The tables are grouped by feature. Each heading names its list file in `mappings/amd64/` and
`mappings/full/`. **Core** groups are always mirrored.

### Core (always): 22 images

**Bob core** (`ibm-bob.lst`, 10 images)

| Image | Tag | Registry path |
|---|---|---|
| bob-admin | 1.8.1 | `cp.icr.io/cp/bob` |
| bob-admin-db | 1.4.1 | `cp.icr.io/cp/bob` |
| bob-admin-ui | 1.10.0 | `cp.icr.io/cp/bob` |
| bob-authn | 2.4.0 | `cp.icr.io/cp/bob` |
| bob-authz | 1.1.4 | `cp.icr.io/cp/bob` |
| bob-gateway | 1.1.0 | `cp.icr.io/cp/bob` |
| bob-inference | 1.20.0 | `cp.icr.io/cp/bob` |
| bob-metering | 1.5.1 | `cp.icr.io/cp/bob` |
| bob-keycloak-scim-plugin | 1.0.9 | `cp.icr.io/cp/bob` |
| ibm-bob-operator | 1.0.0 | `icr.io/cpopen` |

### RAG (`--rag`): 5 images here, plus OpenSearch (10) and shared helpers (2)

**RAG** (`ibm-bob-rag.lst`, 5 images)

| Image | Tag | Registry path |
|---|---|---|
| bob-rag-mcp-server | 1.19.7 | `cp.icr.io/cp/bob` |
| bob-rag-snapshot-onprem-chunk_001 to _004 | 1.0.42 | `cp.icr.io/cp/bob` |

**Shared helpers** (`ibm-bob-z-common.lst`, 2 images, mirrored with any of RAG, Bob for Z, Understand)

| Image | Tag | Registry path |
|---|---|---|
| wca4z-common-busybox-docker | 1.0.59 | `cp.icr.io/cp/bob` |
| wca4z-common-ubi-minimal-docker | 1.0.224 | `cp.icr.io/cp/bob` |

### Bob for Z (`--zproxy`): 3 images, plus everything under RAG

**Bob for Z** (`ibm-bob-zproxy.lst`, 3 images)

| Image | Tag | Registry path |
|---|---|---|
| bob4z-shell-proxy-bob2 | 1.24.17 | `cp.icr.io/cp/bob` |
| bob4z-shell-proxy-ragapi | 1.24.17 | `cp.icr.io/cp/bob` |
| bob4z-shell-proxy-zlookup | 1.24.17 | `cp.icr.io/cp/bob` |

### Z Understand and Refactor (`--understand`): 5 images, plus everything under RAG

**Z Understand and Refactor** (`ibm-bob-understand.lst`, 5 images)

| Image | Tag | Registry path |
|---|---|---|
| bobz-understand | 3.1.0-RC5 | `cp.icr.io/cp/bob` |
| orientdb | 3.2.55 | `cp.icr.io/cp/bob` |
| refactoring-assistant | 3.1.0 | `cp.icr.io/cp/bob` |
| refactoring-assistant-ui | 3.1.0 | `cp.icr.io/cp/bob` |
| ad-core-server | 3.1.0 | `cp.icr.io/cp/bob` |

### Supporting components

The remaining groups follow. Core groups are marked.

**Keycloak** (`rhbk-operator.lst`, 2 images, core)

| Image | Tag | Registry path |
|---|---|---|
| keycloak-rhel9 | 26.6.4-2 | `cp.icr.io/cp/bob` |
| keycloak-rhel9-operator | 26.6.4-2 | `cp.icr.io/cp/bob` |

**Usage metering** (`ibm-usage-metering.lst`, 3 images, core)

| Image | Tag | Registry path |
|---|---|---|
| ibm-usage-metering-operator | 1.0.7 | `icr.io/cpopen` |
| ibm-usage-metering-instance | 1.0.7 | `icr.io/cpopen/cpfs` |
| cpfs-utils | 4.6.23 | `icr.io/cpopen/cpfs` |

**PostgreSQL** (`ibm-pg-operator.lst`, 3 images, core)

| Image | Tag | Registry path |
|---|---|---|
| ibm-pg-operator | v28.4.5 | `icr.io/cpopen` |
| ibm-pg-18 | 18.6-v28.4.5 | `icr.io/cpopen/ibm-pg` |
| ibm-pg-pooler | 1.25.2-v28.4.5 | `icr.io/cpopen/ibm-pg` |

**Redis** (`ibm-redis-cp.lst`, 3 images, core)

| Image | Tag | Registry path |
|---|---|---|
| ibm-redis-cp-operator | 1.4.0 | `icr.io/cpopen` |
| ibm-redis-cp-haproxy | 1.4.0 | `cp.icr.io/cp` |
| ibm-redis-cp-operand | 1.4.0 | `cp.icr.io/cp` |

**OpenSearch** (`opencontent-opensearch.lst`, 10 images, only with RAG, Bob for Z or Understand)

| Image | Tag | Registry path |
|---|---|---|
| opencontent-ibm-opensearch-base-9 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-min-3.5.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugins-3.5.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugin-security-3.5.0.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugin-ism-3.5.0.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugin-knn-3.5.0.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugin-ml-common-3.5.0.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugin-neural-search-3.5.0.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-plugin-job-scheduler-3.5.0.0 | 1.4.5 | `cp.icr.io/cp` |
| opencontent-ibm-opensearch-operator | 1.4.5 | `icr.io/cpopen` |

**Licensing operand** (`extra-ibm-licensing.lst`, 1 image, core)

| Image | Tag | Registry path |
|---|---|---|
| ibm-licensing | 4.2.24 | `icr.io/cpopen/cpfs` |

## Appendix B: Using `bobctl` (optional)

If the customer allows IBM's `bobctl` tool, it can do Steps 1 to 4 from the install package.
Run it from inside the install package directory, after copying `config-template.yaml` to
`config.yaml` and setting `global.imagePullPrefix` to the Artifactory address.

```bash
# Connected host
./bobctl download-images --to-dir /data/bob-images --src-creds "cp:<IBM_ENTITLEMENT_KEY>" --arch amd64

# Air-gapped host. Copy work/*-from-filesystem-mapping.lst along with the images
sed -i 's#placeholder#<artifactory-host>#g' work/*-from-filesystem-mapping.lst
./bobctl upload-images --from-dir /data/bob-images --dest-registry <artifactory-host> --dest-creds "<user>:<token>"
./bobctl verify-images --creds "<user>:<token>" --arch amd64
```

`bobctl` reads the features from `config.yaml` (`bob.rag`, `bob.zProxy`, `bob.understand`). It
adds OpenSearch to the mirror set and the Helm install when RAG or Bob for Z is on. The Bob
image list it mirrors (`ibm-bob-images.csv`) is not split by feature: it always includes the RAG,
Bob for Z and Understand images. Mirror with `bobctl` and you get all 25 `ibm-bob` images, about
12 GiB more than core needs, whether or not you use the features. Understand has its own
`bobctl understand setup` command, which is what 4.7 does by hand.

Known behaviors of this release of `bobctl`:

| Behavior | What to do |
|---|---|
| `download-images` writes `placeholder/...` as the target in `work/*-from-filesystem-mapping.lst`, so `upload-images` fails with "denied" or "unauthorized" | Run the `sed` command above before `upload-images` |
| `upload-images` reads the mapping files from `work/`, not from `--from-dir`. Missing files are skipped with a warning | Copy the `.lst` files into `work/` on the air-gapped host |
| `--insecure` is built in to the login, mirror and verify steps | Use a registry with a valid certificate, or plain HTTP. For a private CA, use the `oc image mirror` route in this guide |
| A failed download leaves `*.download` files and a rerun fails | `find <to-dir> -name '*.download' -delete` |
| `--arch amd64` applies only to `ibm-bob-images.csv` and `rhbk-operator-images.csv`, and tags those images `<version>-amd64` | Expected. Other images are copied as full manifest lists |
| An `imagePullPrefix` with a port (`host:5000`) is cut at the colon in `bobctl`'s log and in `verify-images` | Use an address without a port |
| `ibm-licensing:4.2.24` is in no `bobctl` image list | Copy it with `mappings/amd64/extra-ibm-licensing.lst` using the steps in this guide |
| `bobctl` produces a plain directory, not size-limited archives | Use `oc-mirror` as described in Step 2 |

## Appendix C: Reference

### Glossary

| Term | Meaning |
|---|---|
| Manifest list | An image tag that points to one image per CPU architecture. Its digest identifies the whole set |
| Digest | A `sha256:` value that identifies an image's exact content. Bob pulls by digest |
| `imagePullPrefix` | The Helm value that replaces `icr.io` and `cp.icr.io` in every image reference |
| Entitlement key | The IBM-issued password for `cp.icr.io`. Username is `cp` |
| Stub kubeconfig | A placeholder file that lets `oc registry login` run without a cluster |

### Mapping file format

Each line of a `.lst` file is one image:

```text
<source registry>/<path>@<digest>=REGISTRY_HOST/<path>:<tag>
```

`oc image mirror -f` reads this format. `REGISTRY_HOST` is replaced by the `sed` commands in
Steps 1.3 and 3.1.

### Useful `oc image mirror` options

| Option | Use |
|---|---|
| `--dir=<dir>` | Write images to a directory when a target is `file:///` |
| `--from-dir=<dir>` | Read images from that directory when a source is `file:///` |
| `--keep-manifest-list` | Copy the manifest list and every child image |
| `--max-per-registry=1` | One transfer at a time per registry |
| `--skip-multiple-scopes` | Avoid multi-scope token requests that some registries reject |
| `--certificate-authority=<ca.crt>` | Trust a private CA for the target registry |
| `--continue-on-error` | Keep going after a failed image |
| `--dry-run` | Show what would be copied |
