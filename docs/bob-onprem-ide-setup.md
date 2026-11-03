# Connecting Bob IDE to the on-prem environment

**Prerequisites:** Bob IDE already installed and signed in to a Bob instance · `bob-ca.crt` certificate file from your admin · your user account created by the admin (LDAP or direct Keycloak)

---

## Step 1 — Trust the CA certificate

> **Skip this step** if your admin confirmed the cluster uses an enterprise or commercially-trusted CA — your workstation already trusts the endpoint.

If the cluster is using its default self-signed CA (your admin will tell you), import `bob-ca.crt` into the OS trust store.

**macOS:**

```bash
# Remove any stale entry first (safe to run even on first install)
sudo security remove-certificate -c "bob-ca" 2>/dev/null || true
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain bob-ca.crt
```

**Linux:**

```bash
sudo cp bob-ca.crt /usr/local/share/ca-certificates/bob-ca.crt
sudo update-ca-certificates
```

**After importing, fully quit and relaunch Bob IDE (⌘Q on macOS — not just close the window).** Bob IDE (Electron) reads the keychain only on startup.

> **Still seeing `UNABLE_TO_VERIFY_LEAF_SIGNATURE` after restart?**
> Enable the experimental keychain setting in Bob IDE settings:
> ```
> "http.experimental.systemCertificatesV2": true
> ```

---

## Step 2 — Configure the client endpoint

**Before starting:** Fully quit Bob IDE (⌘Q) if it is currently running.

First, generate your cluster's gateway URL. Run this on any machine that has `oc` logged in to the cluster:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
echo "https://api.bob.ibm-bob.${CLUSTER_DOMAIN}/"
```

Copy the printed URL — you will use it as the value of `gatewayUrl` below. This file is shared with Bob Shell, so one `gatewayUrl` setting points both at the same environment.

Open `~/.bob/settings/settings.json` (create the file and directory if they do not exist) and add or update the `gatewayUrl` key:

```json
{
  "gatewayUrl": "https://api.bob.ibm-bob.<YOUR_CLUSTER_DOMAIN>/"
}
```

> **The URL must end with a trailing slash.**

If you prefer a one-liner, this Python snippet will safely merge the key into an existing file without overwriting other settings:

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

Relaunch Bob IDE (⌘Q, then reopen) — this setting is persistent across sessions, so you do not need to launch from a terminal.

> **Switching back to SaaS:** Deactivate the key by renaming it (e.g. `"gatewayUrl-old"`) in `~/.bob/settings/settings.json`, or delete the line, then fully relaunch Bob IDE. Rename it back to `gatewayUrl` to return to on-prem.

---

## Step 3 — Sign in

Click **Sign In** in Bob IDE. You will be redirected to the on-prem Keycloak login page — sign in with the organisational credentials your admin set up for you.

---

> **Also using Bob Shell?** It reads the same `gatewayUrl` from this settings file, so no extra configuration is needed beyond trusting the CA — see the [Shell setup guide](bob-onprem-shell-setup.md).
