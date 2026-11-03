# Bob Ops Commands

All commands run from inside the install package directory (e.g. `ibm-bob-install-20260923-150531/`).
All logs are written to `logs/` at the repository root.

For deeper troubleshooting (connection failures, log analysis), see also
[`troubleshoot-model-inferencing.md`](troubleshoot-model-inferencing.md).

---

## Quick reference

| Task | Command |
|---|---|
| Check cluster health | See **Cluster health checks** below |
| Check GPU topology & interconnect | See **GPU & distributed LLM serving diagnostics** below |
| View models | `oc exec ... /v1/model/info` |
| Update model config | `./bobctl update-model-config ...` |
| Rolling restart | `oc rollout restart ...` |
| View logs | `oc logs -n ibm-bob-operators ...` |

---

## Cluster health checks

### Pod status
```bash
# Operator pods — expect 5 × Running 1/1
oc get pods -n ibm-bob-operators

# Instance pods — expect ~15 pods
oc get pods -n ibm-bob

# Filter by specific app
oc get pods -n ibm-bob -l app=bob-inference
oc get pods -n ibm-bob -l app=bob-gateway
```

### Basic resources
```bash
# Bob CR status
oc get bob -n ibm-bob -o jsonpath='{.items[0].status.conditions}' | python3 -m json.tool

# Routes
oc get routes -n ibm-bob

# Secrets
oc get secrets -n ibm-bob | grep -E "(pull|entitlement)"
```

### Storage
```bash
# Storage classes (should have ODF or NFS)
oc get sc

# PVCs in instance namespace
oc get pvc -n ibm-bob
```

### Network
```bash
# Test DNS resolution
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') -- \
  chroot /host bash -c "nslookup bob-inference.ibm-bob.svc.cluster.local"

# Test registry reachability
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') -- \
  chroot /host bash -c "
    curl -s -o /dev/null -w 'cp.icr.io: %{http_code}\n' --connect-timeout 8 https://cp.icr.io/v2/
    curl -s -o /dev/null -w 'icr.io:    %{http_code}\n' --connect-timeout 8 https://icr.io/v2/
  "
```

---

## GPU & distributed LLM serving diagnostics

### 1. Check GPU allocation, model, and host type across nodes
```bash
oc get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.machine
```

**Example output:**
```text
NAME                  STATUS   ROLES                  AGE   VERSION    GPU.PRODUCT       GPU.COUNT   GPU.MACHINE
itz-cmp0zl-master-1   Ready    control-plane,master   21d   v1.33.13
itz-cmp0zl-master-2   Ready    control-plane,master   21d   v1.33.13
itz-cmp0zl-master-3   Ready    control-plane,master   21d   v1.33.13
itz-cmp0zl-worker-1   Ready    worker                 21d   v1.33.13
itz-cmp0zl-worker-2   Ready    worker                 21d   v1.33.13
itz-cmp0zl-worker-3   Ready    worker                 21d   v1.33.13
itz-cmp0zl-worker-4   Ready    worker                 21d   v1.33.13
itz-cmp0zl-worker-5   Ready    worker                 21d   v1.33.13
itz-cmp0zl-worker-6   Ready    worker                 21d   v1.33.13   NVIDIA-H100-NVL   1           OpenShift-Virtualization
itz-cmp0zl-worker-7   Ready    worker                 21d   v1.33.13   NVIDIA-H100-NVL   1           OpenShift-Virtualization
itz-cmp0zl-worker-8   Ready    worker                 21d   v1.33.13   NVIDIA-H100-NVL   1           OpenShift-Virtualization
itz-cmp0zl-worker-9   Ready    worker                 21d   v1.33.13   NVIDIA-H100-NVL   1           OpenShift-Virtualization
```

**How to interpret:**
- **`GPU.COUNT: 1` per worker:** The cluster has 4 total GPUs, but each GPU is located on a **separate node** (`worker-6`, `worker-7`, `worker-8`, `worker-9`).
- **`GPU.MACHINE: OpenShift-Virtualization`:** The worker nodes are virtual machines with individual PCIe passthrough GPUs. Any communication between these GPUs must travel over the **cluster network** (virtual bridge / OVN-Kubernetes).

---

### 2. Verify distributed pod placement
```bash
oc get pods -n llm-serving -o wide
```

**Example output:**
```text
NAME                                 READY   STATUS      RESTARTS   AGE   IP             NODE                  NOMINATED NODE   READINESS GATES
laguna-bf16-head-7fdcb75dd8-98782    1/1     Running     0          17h   10.131.0.224   itz-cmp0zl-worker-6   <none>           <none>
laguna-bf16-rank1-7f7d7c759c-jvxnk   1/1     Running     0          17h   10.128.2.178   itz-cmp0zl-worker-7   <none>           <none>
laguna-bf16-rank2-79846966cf-mcwjv   1/1     Running     0          17h   10.130.1.66    itz-cmp0zl-worker-8   <none>           <none>
laguna-bf16-rank3-6758598bf7-n5l7j   1/1     Running     0          17h   10.131.2.176   itz-cmp0zl-worker-9   <none>           <none>
```

**How to interpret:**
- Distributed model ranks (Head/Rank 0, Rank 1, Rank 2, Rank 3) are scheduled 1:1 across worker nodes 6 through 9.
- This confirms that inter-rank communication is multi-node and network-bound.

---

### 3. Check GPU interconnect topology & NVLink status
Run these checks inside the NVIDIA driver daemonset container on any GPU node:

```bash
# Check intra-node topology
oc exec -n nvidia-gpu-operator daemonset/nvidia-driver-daemonset-$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.nodeInfo.osImage}' | grep -o '9\.[0-9.]*-[0-9]*') -c nvidia-driver-ctr -- nvidia-smi topo -m

# Check NVLink connection status
oc exec -n nvidia-gpu-operator daemonset/nvidia-driver-daemonset-$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.nodeInfo.osImage}' | grep -o '9\.[0-9.]*-[0-9]*') -c nvidia-driver-ctr -- nvidia-smi nvlink -s
```

*Note: Alternatively, target the daemonset directly:*
```bash
oc exec -n nvidia-gpu-operator daemonset/nvidia-driver-daemonset-9.6.20260702-0 -c nvidia-driver-ctr -- nvidia-smi topo -m
oc exec -n nvidia-gpu-operator daemonset/nvidia-driver-daemonset-9.6.20260702-0 -c nvidia-driver-ctr -- nvidia-smi nvlink -s
```

**Example output (`nvidia-smi topo -m`):**
```text
        GPU0    CPU Affinity    NUMA Affinity   GPU NUMA ID
GPU0     X      0-31            0               N/A
```

**Example output (`nvidia-smi nvlink -s`):**
```text
GPU 0: NVIDIA H100 NVL (UUID: GPU-9432b89c-4c45-16e1-c6fc-9215a053ee78)
Device does not have or support Nvlink
```

**How to interpret:**
- **Single entry (`GPU0 X`)**: Only one GPU is visible inside the node/VM; no other local GPUs exist on the PCIe bus.
- **`Device does not have or support Nvlink`**: There is no active physical NVLink bridge attached to the GPU in this VM.

---

### 4. Parallelism Strategy Decision: Pipeline (PP) vs Tensor (TP)

When configuring multi-GPU LLM inference engines (such as vLLM):

| Parameter | Recommended Interconnect | Why it applies here |
|---|---|---|
| **Pipeline Parallelism (`--pipeline-parallel-size 4`)** | **Multi-node network** (TCP / OVN / Ethernet) | **Required for this topology.** Splits the model layers sequentially across stages (e.g. layers 1–16 on rank 0, 17–32 on rank 1, etc.). Only transfers intermediate activation tensors between stage boundaries at the end of each layer block. Traffic volume is relatively small and tolerates standard network latency. |
| **Tensor Parallelism (`--tensor-parallel-size 4`)** | **Intra-node NVLink** (up to 900 GB/s) or high-speed InfiniBand/RoCE | **Do not use across separate nodes/VMs.** Shards individual matrix multiplications inside every attention and feed-forward layer. Requires multiple All-Reduce synchronizations per layer. Over virtualized TCP networking, the network latency overhead will cause massive token generation latency and throughput collapse. |

---

## Operator logs

### Stream (live) and append to file
```bash
oc logs -n ibm-bob-operators deployment/ibm-bob-operator -f | tee -a ../logs/operator.log
```

### Snapshot only
```bash
oc logs -n ibm-bob-operators deployment/ibm-bob-operator >> ../logs/operator-$(date +%Y%m%d-%H%M%S).log
```

---

## Model gateway update

**Config only:**
```bash
./bobctl update-model-config --model-config model-gateway.yaml
```

**Secrets only (rotated an API key):**
```bash
./bobctl update-model-config --update-secrets
```

**Config and secrets together:**
```bash
./bobctl update-model-config --model-config model-gateway.yaml --update-secrets
```

---

## View current model list

```bash
oc exec -n ibm-bob deploy/bob-gateway -- \
  curl -sk https://bob-inference.ibm-bob.svc.cluster.local:7330/v1/model/info | jq .
```

---

## Rolling restart

**Restart and wait for rollout:**
```bash
oc rollout restart deploy/bob-inference -n ibm-bob && \
  oc rollout status deploy/bob-inference -n ibm-bob --timeout=5m
```

---

## Before / after model change workflow

```bash
# 1 — View models before
oc exec -n ibm-bob deploy/bob-gateway -- \
  curl -sk https://bob-inference.ibm-bob.svc.cluster.local:7330/v1/model/info | jq .

# 2 — Apply updated model-gateway.yaml
./bobctl update-model-config --model-config model-gateway.yaml

# 3 — Rolling restart
oc rollout restart deploy/bob-inference -n ibm-bob && \
  oc rollout status deploy/bob-inference -n ibm-bob --timeout=5m

# 4 — Confirm models after
oc exec -n ibm-bob deploy/bob-gateway -- \
  curl -sk https://bob-inference.ibm-bob.svc.cluster.local:7330/v1/model/info | jq .
```

---

## Dry-run / troubleshoot config

```bash
./bobctl update-model-config --model-config model-gateway.yaml \
  --output-config /tmp/mg-check.yaml --dry-run \
  && cat /tmp/mg-check.yaml
```
