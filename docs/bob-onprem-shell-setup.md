# Connecting Bob Shell to the on-prem environment

**Prerequisites:** macOS or Linux laptop · Bob Shell 2.x (see Step 2) · your user account on the Bob instance (sign in through your organisation's IdP/SSO) · `bob-ca.crt` certificate file (ask your admin) if the cluster uses a private CA

Bob Shell and Bob IDE read the same settings file, `~/.bob/settings/settings.json`. Setting `gatewayUrl` there is all it takes to point either one at the on-prem environment. You do not need shell helper functions, `BOB_AUTHN_URL` or an API key.

---

## Step 1 — Trust the CA certificate

> **Skip this step** if your admin confirmed the cluster uses an enterprise or commercially-trusted CA — your workstation already trusts the endpoint.

Copy `bob-ca.crt` to your home directory:

```bash
cp bob-ca.crt ~/bob-ca.crt
```

Trust the cert in the OS store:

**macOS:**

```bash
# Remove any stale entry first (safe to run even on first install)
sudo security remove-certificate -c "bob-ca" 2>/dev/null || true
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/bob-ca.crt
```

**Linux:**

```bash
sudo cp ~/bob-ca.crt /usr/local/share/ca-certificates/bob-ca.crt
sudo update-ca-certificates
```

Bob Shell is a Node.js application and does not read the macOS system keychain for TLS trust. For a private-CA cluster, also point Node.js at the cert by adding this line to your `~/.zshrc` (or `~/.bashrc`):

```bash
export NODE_EXTRA_CA_CERTS="$HOME/bob-ca.crt"
```

Then open a new terminal (or run `source ~/.zshrc`).

---

## Step 2 — Check Bob Shell version

```bash
bob --version
```

You need **2.x or higher**. Version 1 uses a different CLI interface and will fail with a confusing error against this environment.

If you need to install or upgrade:

```bash
curl -fsSL https://bob.ibm.com/download/bobshell.sh | bash
```

---

## Step 3 — Set `gatewayUrl`

Get your cluster's gateway URL. Run this on any machine that has `oc` logged in to the cluster:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
echo "https://api.bob.ibm-bob.${CLUSTER_DOMAIN}/"
```

Open `~/.bob/settings/settings.json` (create the file and directory if they do not exist) and add or update the `gatewayUrl` key:

```json
{
  "gatewayUrl": "https://api.bob.ibm-bob.<YOUR_CLUSTER_DOMAIN>/"
}
```

> **The URL must end with a trailing slash.**

To merge the key into an existing file without overwriting other settings:

```bash
python3 -c "
import json, os
p = os.path.expanduser('~/.bob/settings/settings.json')
os.makedirs(os.path.dirname(p), exist_ok=True)
s = json.load(open(p)) if os.path.exists(p) else {}
s['gatewayUrl'] = 'https://api.bob.ibm-bob.<YOUR_CLUSTER_DOMAIN>/'
json.dump(s, open(p, 'w'), indent=2)
print('Done')
"
```

> **Previously used the `bob-onprem` / `bob-saas` helpers?** They are no longer needed. Remove the `# ── Bob Shell environment helpers` block from your `~/.zshrc`. A leftover `BOB_AUTHN_URL` or `BOB_API_KEY` export can override the settings.json flow.

---

## Step 4 — Start Bob Shell and sign in

```bash
bob
```

Sign in through your organisation's IdP/SSO when prompted. On first run you will also be prompted to accept the IBM license agreement. After that, behavior is the same as the cloud version.

For a single non-interactive prompt:

```bash
bob run "explain this file"
```

---

## Switching between on-prem and SaaS

The `gatewayUrl` key in `~/.bob/settings/settings.json` controls which environment Bob Shell and Bob IDE use.

- **To use SaaS:** deactivate the key by renaming it (JSON has no comments), e.g. `"gatewayUrl-old"`, or delete the line. Restart Bob.
- **To use on-prem again:** rename it back to `gatewayUrl`. Restart Bob.

---

## Alternative — authenticate with an API key

SSO sign-in is the default. If you need non-interactive authentication (for example, in automation), you can use a personal API key instead. Bob Shell still reads `gatewayUrl` from settings.json; the key replaces the interactive sign-in.

### Create the key

Open the Bob Admin UI and create a personal API key. Get the full URL by running:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
echo "https://bob.ibm-bob.${CLUSTER_DOMAIN}/admin/apikeys"
```

1. Click **Create API key**
2. Enter a **Name** (required) and an optional **Description**
3. Set the **Scope** to **Inference** — this is required for Bob Shell
4. Select your **Team** if applicable
5. Set an **Expiration date**
6. Click **Generate** and **copy the key immediately** — you cannot view it again after closing the dialog

> **Security reminder:** Treat your API key like a password. Do not share it, commit it to source control, or store it in plain text in your `~/.zshrc`.

### Store the key

**macOS** — store the key in the macOS keychain:

```bash
security add-generic-password -a "$USER" -s "bob-onprem-api-key" -w "<YOUR_BOB_API_KEY>"
```

To rotate the key later, add `-U` to update the existing entry:

```bash
security add-generic-password -a "$USER" -s "bob-onprem-api-key" -w "<NEW_KEY>" -U
```

**Linux** — the macOS keychain is not available. Store the key in a protected file instead:

```bash
mkdir -p ~/.bob
printf '%s' "<YOUR_BOB_API_KEY>" > ~/.bob/bob-api-key
chmod 600 ~/.bob/bob-api-key
```

### Export the key

Nothing loads a stored key for you. Export it in the session where you run Bob Shell:

```bash
# macOS
export BOB_API_KEY="$(security find-generic-password -a "$USER" -s "bob-onprem-api-key" -w)"

# Linux
export BOB_API_KEY="$(cat ~/.bob/bob-api-key)"
```

---

## Reference — environment variables

| Variable | Required | Purpose |
|---|---|---|
| `NODE_EXTRA_CA_CERTS` | Only for a private-CA cluster | Tells Node.js to trust the on-prem CA cert. Bob Shell does not read the macOS system keychain. |
| `BOB_API_KEY` | No (alternative to SSO) | Your personal inference API key. Not needed when you sign in through SSO. |

`BOB_AUTHN_URL` is no longer used. The gateway comes from `gatewayUrl` in `~/.bob/settings/settings.json`.

> **Also using Bob IDE?** It uses the same `gatewayUrl` setting — see the [IDE setup guide](bob-onprem-ide-setup.md).
