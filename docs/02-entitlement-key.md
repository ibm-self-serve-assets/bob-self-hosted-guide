# Obtain your IBM entitlement key

> **Scope:** Get the IBM entitlement key that authorises image pulls from `cp.icr.io`.
> You need this before running `bobctl install` or mirroring images.

**Part of the IBM Bob on TechZone install series:**

1. [TechZone cluster provisioning](00-techzone-cluster-provisioning.md)
2. [Workstation prerequisites](01-workstation-prereqs.md)
3. **Obtain your IBM entitlement key** ← you are here
4. [Pre-install configuration — config files](03-pre-install-config.md)
5. [Manual install walkthrough](04-manual-install.md)

---

All IBM Bob container images are hosted on `cp.icr.io`. A single IBM entitlement key
is required to pull them — the same key covers every Bob component image.

## Steps

1. Go to [myibm.ibm.com/products-services/containerlibrary](https://myibm.ibm.com/products-services/containerlibrary).
2. Click **View library** and confirm you have an **IBM Bob** entitlement listed. If you do not see it, contact your IBM account team to verify your entitlement.
3. Click **Copy** next to your existing key, or click **New key** to generate one.
4. Export the key in your shell session before running any install commands. The username for `cp.icr.io` is always `cp`:

```bash
export IBM_ENTITLEMENT_KEY="<paste key here>"
```

> **Keep this value safe.** The key is a long-lived credential. Do not commit it to source
> control, paste it into chat, or store it in plain text outside a secrets manager.
> For the automated install, it goes in `bob-autoinstall.env` (which must be `chmod 600`
> and is `.gitignore`d).

## Where it is used

| Step | How the key is consumed |
|---|---|
| Manual install (§7a) | Passed as `--registry-creds "cp:$IBM_ENTITLEMENT_KEY"` to `bobctl install` |
| Automated install | Set as `IBM_ENTITLEMENT_KEY` in `bob-autoinstall.env` |
| Image mirroring | Passed to `./bobctl mirror-images` as `--registry-creds` |
| Pull secret rotation | Used to recreate the `ibm-entitlement-key` Kubernetes secret |

## Verify the key works

After exporting the key, you can do a quick login test from your workstation:

```bash
echo "$IBM_ENTITLEMENT_KEY" | docker login cp.icr.io --username cp --password-stdin
# or with podman:
echo "$IBM_ENTITLEMENT_KEY" | podman login cp.icr.io --username cp --password-stdin
```

A successful login prints `Login Succeeded`. An `unauthorized: authentication required`
response means the key is invalid or your IBM Bob entitlement is not active — return
to the container library and verify the entitlement is listed.

---

**Next:** [Pre-install configuration — config files →](03-pre-install-config.md)
