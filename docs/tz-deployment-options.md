# One-Slide Summary: On-Prem Bob Deployment Options
*Single slide for sales enablement — high-level decision paths, no CLI details.*

---

## **[Title]** IBM Bob On-Prem: Your Deployment Path

Sales-facing overview of the three steps every on-prem customer must complete.

---

### 1. Deploy the Agent Harness

**What:** Get the Bob platform running on a reserved OpenShift (TechZone) cluster.

| Path | How | Who decides |
|---|---|---|
| **Automated (recommended)** | Run the 1-click auto-install script with your `bob-autoinstall.env` credentials file | Admin / installer |
| **Manual (custom)** | Follow the step-by-step install guide — cert-manager, pull-secret, `bobctl install`, cluster-scoped resources | Admin / installer |

- **Cluster:** Reserve via [TechZone journey](https://techzone.ibm.com/collection/69c6c2db1bdc18e8109d08ed/journey-overview)
- **Download:** GA release from the [IBM Bob releases page](https://github.com/IBM/ibm-bob/releases#release-v2.0.0)
- **Docs:** [Install guide](https://public-dev.bob.ibm.com/docs/ide/enterprise/on-premises/installation) | [TechZone-specific guidance](https://github.ibm.com/blennox-us/bob-install/tree/main/docs)
- **After install:** Add users in Keycloak → [SSO guide](w3id-sso-oidc-configuration-guide.md)

---

### 2. Model Inferencing (LLM Backend)

**What:** Connect Bob to one or more external LLM APIs so the agent can actually generate responses.

| Option | Cost | Notes |
|---|---|---|
| **Free-tier API keys** | No cost (rate-limited) | [Poolside](https://platform.poolside.ai/api-keys) · [NVIDIA](https://build.nvidia.com/settings/api-keys) |
| **TechZone certified accounts** | Paid (>$250K opp required) | Submit a [request with business justification](https://techzone.ibm.com/collection/69c6c50f9e211774886357b4) |

- API keys are stored as Kubernetes secrets via `bobctl update-model-config --model-config model-gateway.yaml`
- Reserved model names must be present: `security`, `background`, `premium-ide`
- Day-2 ops: [Troubleshooting guide](troubleshoot-model-inferencing.md)

---

### 3. Configure Your Local Client

**What:** Point either an IDE (VS Code) or a shell (Bob Shell 2.x) at the on-prem cluster.

| Client | What's needed | Guide |
|---|---|---|
| **IDE (VS Code)** | Trust CA cert · set `gatewayUrl` in `~/.bob/settings/settings.json` | [IDE setup](bob-onprem-ide-setup.md) |
| **Shell (Bob Shell 2.x)** | Trust CA cert · set the same `gatewayUrl` in `~/.bob/settings/settings.json` | [Shell setup](bob-onprem-shell-setup.md) |

- Both clients read the same settings file and sign in through your IdP/SSO — no API key or shell helper functions needed
- A personal API key (Scope = **Inference**) remains available as an alternative for Bob Shell — see the [Shell setup](bob-onprem-shell-setup.md) guide
- Switching back to SaaS is a one-line config change (rename the `gatewayUrl` key, e.g. `gatewayUrl-old`, or delete it)

---

### Quick Reference: Prerequisites

| Tool | Version |
|---|---|
| `oc` CLI | Any OpenShift 4.x |
| Helm | 3.14.0–3.x (Helm 4 not supported) |
| Node.js | v24+ (smoke test only) |
| OpenSSL | 1.1.x or 3.x |

- Full workstation checklist: [01-workstation-prereqs.md](01-workstation-prereqs.md)
