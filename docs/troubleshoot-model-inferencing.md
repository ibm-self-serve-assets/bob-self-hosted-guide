# Troubleshoot model inferencing

Use this guide for **day-2 troubleshooting** — diagnosing model loading failures, connection
issues, and inference errors. For routine operations (viewing models, updating config),
see also [`ops-commands.md`](ops-commands.md).

All commands run from inside the install package directory (e.g. `ibm-bob-install-20260923-150531/`).

---

## Prerequisites

Set these two variables once. Every command in this guide references them.

```bash
BOB_NS="ibm-bob"   # change if you used a non-default instanceNamespace
```

Export the public gateway URL from the cluster:

```bash
export BOB_GATEWAY_URL="https://$(oc get route -n "$BOB_NS" \
  -o jsonpath='{.items[?(@.spec.to.name=="bob-gateway")].spec.host}' \
  | tr ' ' '\n' | grep '^api\.')"
echo "BOB_GATEWAY_URL=$BOB_GATEWAY_URL"
```

**Get a `BOB_API_KEY`.** Log in to the Bob Admin UI and generate one:
```bash
# Print the Admin UI URL
echo "https://$(oc get route -n "$BOB_NS" \
  -o jsonpath='{.items[?(@.spec.to.name=="bob-gateway")].spec.host}' \
  | tr ' ' '\n' | grep -v '^api\.')/admin"
```

Go to **API Keys → Generate**, copy the key, then:
```bash
export BOB_API_KEY="<key from Admin UI>"
echo "BOB_API_KEY set (length: ${#BOB_API_KEY})"
```

---

## 1 — View currently configured models

You can query the inference endpoint directly through the public gateway — no need
to exec into a pod.

**Primary — via the public gateway:**

```bash
curl -sk "$BOB_GATEWAY_URL/inference/v1/model/info" \
  -H "Authorization: APIKey $BOB_API_KEY" \
  | jq .
```

> `BOB_API_KEY` must be set. See [§2](#2--test-inference-directly-through-bob) for how
> to generate one from the Admin UI.

**Alternative — direct internal call (when the public route is unavailable):**

```bash
oc exec -n "$BOB_NS" deploy/bob-gateway -- \
  sh -c "curl -sk https://bob-inference.${BOB_NS}.svc.cluster.local:7330/v1/model/info | jq ."
```

**Reading the output:**

| Field | Meaning |
|---|---|
| `model_name` | The name to use in `"model": "..."` inference requests |
| `model_info.exposed` | `true` = visible to clients; `false` = internal alias only |
| `model_info.mode` | `chat`, `embedding`, or `image_generation` |

---

## 2 — Test inference directly through Bob

This sends a request through the same path that bob-shell uses, confirming
end-to-end inference is working from your workstation.

> **Auth header format:** Bob API keys (`bob_onprem_...`) are opaque tokens, not JWTs.
> Use `Authorization: APIKey <key>`. Using `Authorization: Bearer <key>` routes the
> request to the JWT verifier, which returns `invalid jwt string`.

**Detect the primary model and send a test request:**

```bash
# Detect the primary exposed model from the inference service
PRIMARY_MODEL=$(oc exec -n "$BOB_NS" deploy/bob-gateway -- \
  sh -c "curl -sk https://bob-inference.${BOB_NS}.svc.cluster.local:7330/v1/model/info" \
  | jq -r '.data[] | select(.model_info.exposed == true) | .model_name' | head -1)
echo "Testing model: $PRIMARY_MODEL"

# Send a minimal chat completion
# Note: the path MUST start with /inference/ — the gateway uses this prefix
# to route and authorize the request. /v1/chat/completions directly returns 403.
curl -sk "$BOB_GATEWAY_URL/inference/v1/chat/completions" \
  -H "Authorization: APIKey $BOB_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$PRIMARY_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say: pong\"}], \"max_tokens\": 10}" \
  | jq .
```

A successful response contains a `choices` array with a `message.content` field.

**Troubleshooting:**

| HTTP status / error | Cause | Fix |
|---|---|---|
| `401` / `invalid jwt string` | `Authorization: Bearer` used with a Bob opaque key | Change to `Authorization: APIKey $BOB_API_KEY` |
| `401` / `invalid jwt string` (with `APIKey`) | Key is stale, has surrounding whitespace, or Keycloak is unavailable | Regenerate in Admin UI; check `oc logs -n "$BOB_NS" deploy/bob-gateway --since=2m \| grep -i "apikey\|permission"` |
| `403` / `Access denied` | Path missing the `/inference/` prefix | Change URL to `$BOB_GATEWAY_URL/inference/v1/chat/completions` |
| `404 Not Found` | `model_name` does not match what the provider exposes | Run the §1 model list and compare `model_name` values |
| `502 Bad Gateway` | Upstream model endpoint is unreachable | Check §4 log stream for `connection refused` or `no route to host` |

---

## 3 — Update the model config

Run from inside the install package directory. A rolling restart (§4) is required
after any of these commands for the pods to pick up the changes.

Under the hood each command renders the relevant Kubernetes resource via
`helm template` and applies it with `oc apply --server-side --force-conflicts`.

**Config only** (edited `model-gateway.yaml`):

```bash
./bobctl update-model-config --model-config model-gateway.yaml
```

**Secrets only** (rotated an API key in `config.yaml`, did not touch `model-gateway.yaml`):

```bash
./bobctl update-model-config --update-secrets
```

**Config and secrets together:**

```bash
./bobctl update-model-config --model-config model-gateway.yaml --update-secrets
```

**Dry-run — validate YAML before pushing:**

```bash
./bobctl update-model-config --model-config model-gateway.yaml \
  --output-config /tmp/mg-check.yaml --dry-run \
  && cat /tmp/mg-check.yaml
```

Run this first if pods are stuck in `Pending` or `CrashLoopBackOff` after a
restart — a malformed `model-gateway.yaml` is the most common cause.

---

## 4 — Rolling restart

Run after any `update-model-config` to pick up the new ConfigMap and/or Secret
without downtime.

```bash
oc rollout restart deploy/bob-inference -n "$BOB_NS"
oc rollout status  deploy/bob-inference -n "$BOB_NS" --timeout=5m
```

After the rollout completes, confirm the updated models loaded:

```bash
curl -sk "$BOB_GATEWAY_URL/inference/v1/model/info" \
  -H "Authorization: APIKey $BOB_API_KEY" \
  | jq .
```

**Full before/after workflow:**

```bash
# 1 — View models before
curl -sk "$BOB_GATEWAY_URL/inference/v1/model/info" \
  -H "Authorization: APIKey $BOB_API_KEY" | jq .

# 2 — Apply updated model-gateway.yaml
./bobctl update-model-config --model-config model-gateway.yaml

# 3 — Rolling restart
oc rollout restart deploy/bob-inference -n "$BOB_NS"
oc rollout status  deploy/bob-inference -n "$BOB_NS" --timeout=5m

# 4 — Confirm models after
curl -sk "$BOB_GATEWAY_URL/inference/v1/model/info" \
  -H "Authorization: APIKey $BOB_API_KEY" | jq .
```

---

## 5 — Live log stream

Run this in a separate terminal alongside an inference test to see what the
inference service is doing in real time.

```bash
oc logs -n "$BOB_NS" deploy/bob-inference -f
```

To suppress metering noise and focus on the inference signal:

```bash
oc logs -n "$BOB_NS" deploy/bob-inference --since=5m \
  | jq -r 'select(.caller | test("metering") | not) | [.ts, .level, .msg] | @tsv'
```

> Entries like `Failed to send metering event ... too many colons in address` are
> harmless and do not affect inferencing. Filter them out with the `jq` command
> above when triaging inference failures.

---

## Cluster health checks

Before diving into model-specific issues, verify basic cluster health:

### Pod status
```bash
# Inferencing pods should be Running
oc get pods -n "$BOB_NS" -l app=bob-inference

# Gateway pods should be Running
oc get pods -n "$BOB_NS" -l app=bob-gateway
```

### Service endpoints
```bash
# Verify services have endpoints
oc get endpoints bob-inference -n "$BOB_NS"
oc get endpoints bob-gateway -n "$BOB_NS"
```

### Route accessibility
```bash
# Check routes exist and have hostnames
oc get route bob-gateway -n "$BOB_NS"
```

### Network connectivity test
```bash
# Test DNS resolution from within the cluster
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') -- \
  chroot /host bash -c "nslookup bob-inference.${BOB_NS}.svc.cluster.local"
```

---

## Common error scenarios

| Symptom | Likely cause | Diagnostic command |
|---|---|---|
| `401` / `invalid jwt string` | Wrong auth scheme or stale key | See §2 — Test inference directly through Bob |
| `403` / `Access denied` | Missing `/inference/` path prefix | Verify URL includes `/inference/v1/...` |
| `404 Not Found` | Model name mismatch | `curl -sk .../model/info` to list loaded models |
| `502 Bad Gateway` | Model endpoint unreachable | Check model gateway log for `connection refused` |
| Inference slow/unresponsive | Model endpoint slow or circuit breaker open | Check `bob-inference` logs for timeout entries |
| `Model not registered` | model-gateway.yaml not loaded | `oc get configmap bob-gateway -n "$BOB_NS" -o yaml` |

**Key log patterns:**

| Pattern | Meaning |
|---|---|
| `Model registered successfully` | Bifrost loaded the model entry without errors |
| `connection refused` / `no route to host` | Connectivity failure to the model endpoint — check the `base_url` in `model-gateway.yaml` |
| `401` / `403 from upstream` | Credential is wrong or lacks required permissions — re-check the API key secret |
| `certificate signed by unknown authority` | `ca_cert_pem` is missing or incorrect in `model-gateway.yaml` |
| `environment variable not found` | A secret referenced with `env.*` is missing from `bob.modelGateway.secrets` in `config.yaml` |
