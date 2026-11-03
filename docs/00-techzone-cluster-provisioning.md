# TechZone OpenShift cluster — provisioning

> **Scope:** Provision a TechZone OpenShift cluster and log in to it from your terminal.
>
> **Audience:** IBM technical practitioners installing IBM Bob on TechZone.

**Part of the IBM Bob on TechZone install series:**

1. **TechZone cluster provisioning** ← you are here
2. [Workstation prerequisites](01-workstation-prereqs.md)
3. [Obtain your IBM entitlement key](02-entitlement-key.md)
4. [Pre-install configuration — config files](03-pre-install-config.md)
5. [Manual install walkthrough](04-manual-install.md)

---

## §1 — Provision a TechZone OpenShift cluster

### 1a — Navigate to the collection

Open the **Certified Base OpenShift Clusters** collection:
**[techzone.ibm.com/collection/tech-zone-certified-base-images/journey-base-open-shift](https://techzone.ibm.com/collection/tech-zone-certified-base-images/journey-base-open-shift)**

### 1b — Select the environment

Choose the **Certified Base OpenShift Clusters** tile (not the Approval-Gated option).

> **Why Certified Base, not Approval-Gated?**
> Certified Base clusters provision with no preinstalled software — exactly what you need
> to install Bob from scratch. The Approval-Gated option requires an IBM approval queue
> and a Sales Cloud Opportunity code, which is unnecessary for an internal PoC.

On the **OpenShift Cluster OCPv IBM Cloud** card click **ocpv-cloud environment** button.

This opens a 6-step **Create a request** form. Work through each step as follows.

---

**Step 1: General**

| Field | Value |
|---|---|
| **Name** | `IBM Bob On-Prem PoC` |
| **Description** | `IBM Bob on-premises installation test using bobctl on a clean OCP cluster. Internal enablement only — no client or regulated data.` |

The **Request resources** section is pre-populated — do not change it. Click **Next**.

---

**Step 2: Business purpose**

Under **Purpose → Primary use**, select **Test** — Need to test a specific function, configuration, or customization.

> **Do not select Learning** — TechZone will block the reservation with a policy error
> because this environment is not linked to an IBM training course. Do not select **Demo**
> or **Pilot** — both require a Sales Cloud Opportunity code.

Leave both opportunity fields blank and click **Next**.

---

**Step 3: Deployment**

| Field | Value |
|---|---|
| **Geography** | `itz-osv-01 - americas - any region - any datacenter` |

> Choose Americas for lowest latency from a US-based laptop. Europe and AP are valid
> alternatives if you are in those regions.

Click **Next**.

---

**Step 4: Scheduling**

> **Policy limits for this environment:**
> - Initial reservation: up to **12 hours**
> - Extendable **3 times**, each extension up to **12 hours** (total maximum: 2 days)
> - Limit of **3 reservations per 2 days**
>
> The Bob install takes approximately 1–2 hours. Start your reservation when you have a
> solid uninterrupted block of time. Use [My Reservations](https://techzone.ibm.com/my/reservations)
> to extend before the window closes.

Leave the start time as-is (start immediately) and the end time at 12 hours. Click **Next**.

---

**Step 5: Configuration**

Click **Customize** to edit the three fields:

| Field | Value |
|---|---|
| **OpenShift cluster version** | `4.20` |
| **Worker node count** | `3` |
| **Worker node flavor** | `16 vCPU x 64 GB - 100 GB ephemeral storage` |

> **OCP version:** Bob requires OCP 4.20 minimum. Do not use 4.19 or lower.

> ⚠️ **Worker node sizing is critical.** The default `4 vCPU × 16 GB` flavor is too
> small — pods will fail to schedule or OOMKill during install. Use `16 vCPU × 64 GB`
> minimum. Available flavors: `4 vCPU x 16 GB`, `8 vCPU x 32 GB`,
> `16 vCPU x 64 GB - 100 GB ephemeral storage`, `16 vCPU x 64 GB - 300 GB ephemeral storage`,
> `32 vCPU x 128 GB - 300 GB ephemeral storage`. Storage is bundled into the flavor label.

Click **Save**, then click **Next**.

---

**Step 6: Review and submit**

Verify the summary before submitting:

| Section | Field | Value |
|---|---|---|
| General | Name | `IBM Bob On-Prem PoC` |
| Business Purpose | Purpose | `Test` |
| Deployment | Geography | `any` |
| Scheduling | Duration | 12 hours |
| Configuration | OpenShift cluster version | `4.20` |
| Configuration | Worker node count | `3` |
| Configuration | Worker node flavor | `16 vCPU x 64 GB - 100 GB ephemeral storage` |

Check the **"I agree to IBM Technology Zone's terms & conditions"** box and click **Submit**.

Provisioning takes **20–40 minutes**. You will receive an email when the cluster is ready.

> ⚠️ **Save your Request ID immediately.** It is shown only once on the confirmation
> screen. Go to [My Reservations](https://techzone.ibm.com/my/reservations) to track
> status, or click **Track my request** on the success screen.

### 1c — Log in to the cluster

> **Prerequisite — OpenShift CLI (`oc`) must be installed.**
> If you have not installed `oc` yet, complete the
> [OpenShift CLI section of the workstation prerequisites guide](01-workstation-prereqs.md#openshift-cli-oc)
> first, then return here.

Once the reservation status shows **Ready**:

1. Open [My Reservations](https://techzone.ibm.com/my/reservations) and click the reservation.
2. On the reservation details page, expand the **OUTPUTS** section to find your credentials:
   - **Cluster Admin Username** — typically `kubeadmin`
   - **Cluster Admin Password** — click the eye icon to reveal it, or the copy icon to copy it
3. Click **Open your environment** (or use the **OCP Console** link in OUTPUTS) — this opens the Red Hat OpenShift web console.
4. On the login screen, click **kube:admin**, then enter the **Cluster Admin Username** and **Cluster Admin Password** from the OUTPUTS section.
5. In the web console, click your username (top-right) → **Copy login command**.
6. Click **Display token** and copy the full `oc login` command.
7. Paste and run it in your terminal:

```bash
oc login --token=<YOUR_TOKEN> --server=<YOUR_API_SERVER>
```

Verify the login worked:

```bash
oc get nodes -o wide
```

Every node in the `STATUS` column must show `Ready`. You need at least one node with the
`worker` role (the `ROLES` column). A typical TechZone cluster looks like:

```
NAME                  STATUS   ROLES                  AGE    VERSION    INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                  CONTAINER-RUNTIME
itz-sxd5vd-master-1   Ready    control-plane,master   123m   v1.33.13   10.10.10.11   <none>        Red Hat Enterprise Linux CoreOS 9.6.x   5.14.0-xxx.el9_6.x86_64   cri-o://1.33.x
itz-sxd5vd-master-2   Ready    control-plane,master   137m   v1.33.13   10.10.10.12   <none>        Red Hat Enterprise Linux CoreOS 9.6.x   5.14.0-xxx.el9_6.x86_64   cri-o://1.33.x
itz-sxd5vd-master-3   Ready    control-plane,master   137m   v1.33.13   10.10.10.13   <none>        Red Hat Enterprise Linux CoreOS 9.6.x   5.14.0-xxx.el9_6.x86_64   cri-o://1.33.x
itz-sxd5vd-worker-1   Ready    worker                 122m   v1.33.13   10.10.10.21   <none>        Red Hat Enterprise Linux CoreOS 9.6.x   5.14.0-xxx.el9_6.x86_64   cri-o://1.33.x
itz-sxd5vd-worker-2   Ready    worker                 122m   v1.33.13   10.10.10.22   <none>        Red Hat Enterprise Linux CoreOS 9.6.x   5.14.0-xxx.el9_6.x86_64   cri-o://1.33.x
itz-sxd5vd-worker-3   Ready    worker                 122m   v1.33.13   10.10.10.23   <none>        Red Hat Enterprise Linux CoreOS 9.6.x   5.14.0-xxx.el9_6.x86_64   cri-o://1.33.x
```

If any node shows `NotReady`, the cluster is still initialising — wait a few minutes and
re-run the command before continuing.

> **Token expiry:** the login token is valid for ~24 hours. If it expires during a long
> install session, return to the web console → **Copy login command** to get a fresh one.

---

## Cluster sizing reference (PoC minimum)

| Role | Count | vCPU | RAM |
|---|---|---|---|
| Control plane | 3 | 8 | 32 GB |
| Worker | 3 | 16 | 64 GB |

For production deployments, consult the IBM Bob on-premises product documentation
(`docs/installation/bob-onprem.pdf`) for full sizing guidance.

---

**Next:** [Workstation prerequisites →](01-workstation-prereqs.md)
