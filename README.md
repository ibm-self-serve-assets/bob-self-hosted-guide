# Bob Self-Hosted Guide

## Repository layout

```
.
├── README.md
├── docs/        Step-by-step guides (00–04 install series), ops, SSO, client setup,
│                airgapped/, diagrams/, video-walkthroughs/
├── scripts/     Helper scripts (cleanup, client setup, cluster snapshot, client kit)
│   └── install-scripts-run-install-dir/   Auto-install script and config files
└── templates/
    └── nvidia/  Starter config.yaml and model-gateway.yaml (NVIDIA Nemotron)
```

Where the scripts run:

- `scripts/install-scripts-run-install-dir/` — copy its contents into the extracted
  release directory (next to `bobctl`) and run `bob-autoinstall.sh` from there. The script
  looks for `config.yaml`, `model-gateway.yaml`, `bob-autoinstall.env` and `bobctl` in its
  own directory.
- `scripts/bob-cleanup.sh` and `scripts/package-client-kit.sh` — run from this repo.
  They look for an `ibm-bob-install-*` directory in the repo root. If you extracted the
  release to `ibm-bob/` as shown below, pass it explicitly:
  `./scripts/bob-cleanup.sh --install-dir ./ibm-bob`.

## Overview of the on-prem installation

IBM Bob is installed on an OpenShift cluster with the `bobctl` CLI. The install has three
parts: deploy the Bob platform, connect it to an LLM backend, and configure local clients.
You can run the install either manually (step by step) or with the automated
`bob-autoinstall.sh` script.

| Phase | What happens | Guide |
|---|---|---|
| A. Prepare | Provision a cluster, set up the workstation, get the entitlement key, check the cluster, write the config files | Steps 1–6 below |
| B. Install | Install cert-manager, apply cluster-scoped resources, create pull secrets, run `bobctl install` | Steps 7–10 below |
| C. Post-install | Verify, extract the CA cert, set the admin password, add users | Steps 11–14 below |
| D. Clients | Point Bob Shell or Bob IDE at the on-prem gateway | Steps 15–16 below |

## Installation steps

### Phase A — Prepare

#### 1. Download and extract the latest release

Download the latest release from the [IBM Bob releases page](https://github.com/IBM/ibm-bob/releases/), then extract its contents:

```bash
mkdir ibm-bob
tar -C ibm-bob -xvf ibm-bob-install-<version>.tar.gz
cd ibm-bob
```

Replace `<version>` with the version number of the release you downloaded.

#### 2. Provision and log in to an OpenShift cluster

Reserve a TechZone **Certified Base OpenShift Cluster** and log in with `oc login`.

- OpenShift **4.20** minimum
- 3 worker nodes, **16 vCPU × 64 GB** each (the default 4 vCPU × 16 GB flavor is too small)
- Purpose: **Test**; provisioning takes 20–40 minutes
- Confirm with `oc get nodes -o wide` (all nodes `Ready`)

Guide: [TechZone OpenShift cluster — provisioning](docs/00-techzone-cluster-provisioning.md)

#### 3. Verify workstation prerequisites

| Tool | Version |
|---|---|
| `oc` CLI | Any OpenShift 4.x |
| Helm | 3.14.0 or later, Helm 3 only (Helm 4 is not supported) |
| openssl | 1.1.x or 3.x |
| Node.js | v24+ (only needed for the end-to-end smoke test) |

Guide: [Workstation prerequisites](docs/01-workstation-prereqs.md)

#### 4. Obtain your IBM entitlement key

Get the key from [myibm.ibm.com/products-services/containerlibrary](https://myibm.ibm.com/products-services/containerlibrary), confirm an **IBM Bob** entitlement is listed, and export it. The registry user for `cp.icr.io` is always `cp`.

```bash
export IBM_ENTITLEMENT_KEY="<your key>"
```

Guide: [Obtain your IBM entitlement key](docs/02-entitlement-key.md)

#### 5. Check registry reachability and storage

- From a cluster node, `cp.icr.io` and `icr.io` must both return HTTP `401` (not `000`).
- `oc get sc` must show one RWX class (`ocs-storagecluster-cephfs` or `nfs-client`) and one RWO class (`ocs-storagecluster-ceph-rbd` or `ibmc-vpc-block`). If there is no RWX class, deploy the managed NFS provisioner described in the guide.

#### 6. Create `config.yaml` and `model-gateway.yaml`

Place both files in the same directory as `bobctl`.

- `config.yaml` — namespaces (`ibm-bob-operators`, `ibm-bob`), `fileStorageClass`, `blockStorageClass`, image pull secret, and model gateway API keys. Optional add-ons: metrics, RAG, zProxy, Understand.
- `model-gateway.yaml` — the LLM endpoints and model aliases. The reserved names `security`, `background` and `premium-ide` must be present. Starter NVIDIA Nemotron files are in [`templates/nvidia/`](templates/nvidia/).

Guide: [Pre-install configuration](docs/03-pre-install-config.md)

### Phase B — Install

> **Automated option:** copy the contents of
> [`scripts/install-scripts-run-install-dir/`](scripts/install-scripts-run-install-dir/)
> next to `bobctl`, fill in `bob-autoinstall.env` (copy from `bob-autoinstall.env.example`,
> `chmod 600`) and run `./bob-autoinstall.sh` (add `--dry-run` to preview). It performs
> prerequisite checks, the NFS provisioner (if needed), steps 7–10, the IdP setup, and
> steps 12–13 for you. Use the manual steps below for custom installs.

#### 7. Install cert-manager (v1.14+)

Install the Red Hat cert-manager Operator through OLM (namespace, OperatorGroup, Subscription). Wait for the CSV to reach `Succeeded` and for the three `cert-manager` pods to be `Running`.

#### 8. Generate and apply cluster-scoped resources

```bash
./bobctl generate-cluster-resources
oc apply -f work/cluster-resources.yaml --force-conflicts --server-side
oc get namespace ibm-bob-operators ibm-bob
```

#### 9. Create the entitlement pull secret and run an image pull smoke test

Create the `ibm-entitlement-key` docker-registry secret in both `ibm-bob-operators` and `ibm-bob`. Then start a throwaway pod from a Bob image on `cp.icr.io`. `ImagePullBackOff` or `ErrImagePull` means a registry, auth or network problem; any other status means the image pulled.

#### 10. Run `bobctl install`

```bash
./bobctl install \
  --accept-license \
  --model-config model-gateway.yaml \
  --registry-creds "cp:${IBM_ENTITLEMENT_KEY}"
```

This takes about 10–20 minutes. Logs are written to `logs/`.

### Phase C — Post-install

#### 11. Verify the installation

- Operator pods: 5 × `Running`
- Instance pods in `ibm-bob`: about 15, a mix of `Running` and `Completed`
- The Bob custom resource reports ready, and the routes exist in `ibm-bob`

#### 12. Extract the CA certificate

```bash
./bobctl get-ca-cert --output "$HOME/bob-ca.crt"
```

Bob uses a self-signed internal CA by default; distribute `bob-ca.crt` to users. To use a corporate certificate instead, see Appendix J of the manual install guide.

#### 13. Set the bootstrap admin password

Set the password for `bob-admin@bob.ibm.com` in the `bob` Keycloak realm (using `kcadm` in the Keycloak pod).

#### 14. Add users

Create local Keycloak users, or federate LDAP / Active Directory. For SSO, see the [w3id SSO (OIDC) configuration guide](docs/w3id-sso-oidc-configuration-guide.md).

Steps 7–14 are covered in the [Manual install walkthrough](docs/04-manual-install.md). Verify model inferencing in its Appendix I, and see the [model inferencing troubleshooting guide](docs/troubleshoot-model-inferencing.md) if there are problems.

### Phase D — Configure clients

Each user trusts `bob-ca.crt` and sets `gatewayUrl` in `~/.bob/settings/settings.json` (`https://api.bob.ibm-bob.<ingress-domain>/`). Both clients share that file and sign in through your IdP/SSO.

#### 15. Bob Shell (2.x)

Install Bob Shell, set `NODE_EXTRA_CA_CERTS=$HOME/bob-ca.crt`, sign in, and run the end-to-end test:

```bash
bob --accept-license run "Hello"
```

Guides: [Shell setup](docs/bob-onprem-shell-setup.md) · automated: `scripts/bob-client-setup.sh` / `.ps1`

#### 16. Bob IDE

Import the CA into the OS trust store, set `gatewayUrl`, fully quit and relaunch the IDE, and sign in.

Guide: [IDE setup](docs/bob-onprem-ide-setup.md)

## Other documentation

| Topic | Location |
|---|---|
| Deployment options summary (automated vs manual, model inferencing, clients) | [`docs/tz-deployment-options.md`](docs/tz-deployment-options.md) |
| Day-2 operations | [`docs/ops-commands.md`](docs/ops-commands.md) |
| Air-gapped install (no internet access; uses `oc`, `skopeo`, `helm`) | [`docs/airgapped/`](docs/airgapped/bob-airgapped-install-guide.md) |
| Architecture diagrams | [`docs/diagrams/`](docs/diagrams/architecture-overview.md) |
| Upgrade, custom TLS certificate, cleanup | Appendices of [`docs/04-manual-install.md`](docs/04-manual-install.md); `scripts/bob-cleanup.sh` |
