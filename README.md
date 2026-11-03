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

## Installation

### 1. Download and extract the latest release

Download the latest release from the [IBM Bob releases page](https://github.com/IBM/ibm-bob/releases/), then extract its contents:

```bash
mkdir ibm-bob
tar -C ibm-bob -xvf ibm-bob-install-<version>.tar.gz
cd ibm-bob
```

Replace `<version>` with the version number of the release you downloaded.

### 2. Connect to your OpenShift cluster

Provision a TechZone OpenShift cluster and log in to it from your terminal by following [TechZone OpenShift cluster — provisioning](docs/00-techzone-cluster-provisioning.md).

