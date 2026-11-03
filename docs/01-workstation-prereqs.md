# Workstation prerequisites

> **Scope:** Verify that your administrator workstation has all required tools before
> starting the IBM Bob installation. Each section includes a version check command
> followed by install/upgrade instructions if the check fails.
>
> **Audience:** IBM technical practitioners installing IBM Bob on TechZone.

**Part of the IBM Bob on TechZone install series:**

1. [TechZone cluster provisioning](00-techzone-cluster-provisioning.md)
2. **Workstation prerequisites** ← you are here
3. [Obtain your IBM entitlement key](02-entitlement-key.md)
4. [Pre-install configuration — config files](03-pre-install-config.md)
5. [Manual install walkthrough](04-manual-install.md)

---

## OpenShift CLI (`oc`)

```bash
oc version --client
```

Any supported OpenShift 4.x client is fine:

```
Client Version: 4.x.x
Kustomize Version: v5.x.x
```

> **After logging into your cluster:**
> Once you have completed [§1c of the cluster provisioning guide](00-techzone-cluster-provisioning.md#1c--log-in-to-the-cluster),
> run `oc version` (without `--client`) to confirm your session is active. You should
> see two additional lines:
>
> ```
> Client Version: 4.x.x
> Kustomize Version: v5.x.x
> Server Version: 4.x.x
> Kubernetes Version: v1.xx.x
> ```
>
> If `Server Version` is absent, you are not logged in — re-run the `oc login` command
> from §1c of the cluster provisioning guide.

**Install or upgrade:**

**macOS (Homebrew):**
```bash
brew install openshift-cli
```

**macOS / Linux (direct download):**
```bash
# macOS arm64 example — replace "stable" with your cluster version if needed
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-mac-arm64.tar.gz
tar -xzf openshift-client-mac-arm64.tar.gz
sudo mv oc /usr/local/bin/
oc version --client
```

**Linux (x86_64):**
```bash
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
tar -xzf openshift-client-linux.tar.gz
sudo mv oc /usr/local/bin/
oc version --client
```

For other platforms, download from the [OpenShift mirror](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/).

---

## Helm (must be 3.14.0–3.x, Helm 4 not supported)

```bash
helm version --short
```

The version must be **3.14.0 or later, and must be Helm 3 — Helm 4 is not supported**.
Bob's install script uses `--reset-then-reuse-values`, a flag introduced in Helm 3.14.0 —
older versions silently ignore it, causing upgrades to lose their configured values. Helm 4
is a breaking release with incompatible API changes that cause the install to fail.

```
v3.14.x+g...    ✅  good to go
v3.22.x+g...    ✅  good to go
v3.13.x+g...    ❌  too old — upgrade before continuing
v4.x.x+g...     ❌  Helm 4 is not supported — install Helm 3 alongside it (see below)
```

**Install or upgrade:**

**macOS (Homebrew):**
```bash
brew install helm          # fresh install
brew upgrade helm          # upgrade an existing install
helm version --short       # confirm v3.14.0+
```

**Linux / macOS (official install script):**
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version --short
```

**Direct binary download** — pick your platform from
[https://github.com/helm/helm/releases/latest](https://github.com/helm/helm/releases/latest),
unpack, and move the `helm` binary to a directory on your `PATH`.

**If Helm 4 is already on your PATH**, install Helm 3 and ensure it takes precedence:

```bash
# Install Helm 3 to /usr/local/bin
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Prepend /usr/local/bin so Helm 3 is found first (add to ~/.zshrc to make it permanent)
export PATH="/usr/local/bin:$PATH"

# Confirm
helm version --short   # must show v3.x.x
```

---

## openssl

```bash
openssl version
```

Any modern release (1.1.x or 3.x) is fine. As long as the command runs without error
you can continue.

**macOS** ships OpenSSL as a LibreSSL shim. The install guide only uses `openssl` for
certificate inspection — either version works. If you want the full OpenSSL 3.x:

```bash
brew install openssl@3
# add to PATH if needed:
export PATH="$(brew --prefix openssl@3)/bin:$PATH"
openssl version
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt-get update && sudo apt-get install -y openssl
openssl version
```

**Linux (RHEL/Fedora):**
```bash
sudo dnf install -y openssl
openssl version
```

---

## Node.js (v24.0.0 or higher)

```bash
node --version
```

The version must be **v24.0.0 or higher**. Node.js is only required for the end-to-end
smoke test in the manual install guide — if it is missing or out of date you can continue
the installation and fix it later.

**macOS (Homebrew):**
```bash
brew install node          # installs the current LTS
brew upgrade node          # upgrade an existing install
node --version             # confirm v24+
```

**macOS / Linux (nvm — recommended if you manage multiple Node versions):**
```bash
# Install nvm if not already present
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.nvm/nvm.sh

# Install and use Node.js 24
nvm install 24
nvm use 24
node --version
```

**Linux (NodeSource — Debian/Ubuntu):**
```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
```

**Linux (NodeSource — RHEL/Fedora):**
```bash
curl -fsSL https://rpm.nodesource.com/setup_24.x | sudo bash -
sudo dnf install -y nodejs
node --version
```

**Direct download:** [https://nodejs.org/en/download](https://nodejs.org/en/download) —
select the v24.x LTS installer for your platform.

---

**Next:** [Obtain your IBM entitlement key →](02-entitlement-key.md)
