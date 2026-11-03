# IBM Bob — Deployment Architecture

**Cluster:** itz-sxd5vd  
**Updated:** 2026-09-24  
**OpenShift:** 3 control plane nodes · 3 worker nodes · cert-manager (Red Hat Operator)

> **Note:** RAG (OpenSearch), Vector agent, zProxy, and Z Understand are all
> **disabled by default** in this installation. They are shown in diagrams with
> dashed borders / greyed styling. Enable each via the corresponding Bob CR field.

---

## Diagram 1 — Request Flow (logical)

```mermaid
graph LR
    USER([End User])
    IDE([IDE / API Client])

    subgraph INGRESS["Entry Point  ·  bob-gateway"]
        GW["bob-gateway\nbob.* route  ·  UI\napi.bob.* route  ·  API/IDE\nHTTPS reencrypt · :8443/:8080"]
    end

    subgraph SERVICES["Application Services  ·  ibm-bob ns"]
        UI["bob-admin-ui"]
        ADMIN["bob-admin"]
        AUTHZ["bob-authz"]
        AUTHN["bob-authn"]
        INF["bob-inference"]
    end

    subgraph DATA["Data Layer  ·  ibm-bob ns"]
        KC[("Keycloak")]
        PG[("PostgreSQL\nbob-db")]
        KCPG[("PostgreSQL\nbob-keycloak-db")]
        RD[("bob-admin-redis\n3 replicas · redis+sentinel per pod\nHAProxy front-end · quorum 2")]
        METER["ibm-usage-metering"]
    end

    subgraph EXT1["External — Identity"]
        IDP["Identity Provider\nLDAP / OIDC"]
    end

    subgraph EXT2["External — LLM"]
        LLM["External LLM / Model API\nconfigurable: NVIDIA NIM, Azure,\nAWS Bedrock, Gemini, custom…"]
    end

    subgraph EXT3["External — License"]
        LICENSE["IBM License Service\nmetering phone-home"]
    end

    subgraph OPTIONAL["Optional Add-ons  ·  disabled by default"]
        OS["OpenSearch\nrag.enabled: false"]
        ZP["zProxy\nzProxy.enabled: false"]
        VEC["Vector Agent\nvector.enabled: false"]
        ZU["Z Understand\nunderstand.enabled: false"]
    end

    USER -->|browser  ·  bob.* route| GW
    IDE -->|API/IDE  ·  api.bob.* route| GW
    GW --> UI
    UI -->|back-channel svc.cluster.local:8443| GW
    GW -->|auth :7330| AUTHN
    GW --> ADMIN & AUTHZ & INF
    AUTHN -->|OIDC :8080| KC
    KC -.->|LDAP/OIDC federation| IDP
    AUTHN & ADMIN & AUTHZ & INF --> PG
    ADMIN & AUTHZ & GW & INF & AUTHN --> RD
    KC --> KCPG
    INF -.->|model requests| LLM
    METER -.->|license phone-home\ndedicated route| LICENSE
```

## Diagram 2 — Node & Storage Placement (infrastructure)

```mermaid
graph TB
    subgraph OPS["ibm-bob-operators namespace"]
        direction LR
        OPBOB["ibm-bob-operator\nworker-1"]
        OPPG["ibm-pg-operator\nworker-1"]
        OPREDIS["ibm-redis-cp-operator\nworker-1"]
        OPMETER["ibm-usage-metering-operator\nworker-1"]
        OPRHBK["rhbk-operator\nworker-3"]
    end

    subgraph W1["Worker Node 1  (16 CPU · 64 GB · 10.10.10.21)"]
        direction LR
        GW2["bob-gateway\n:8443/:8080"]
        ADMIN2["bob-admin\n:7330"]
        AUTHZ2["bob-authz\n:7330"]
        METER2["ibm-usage-metering\n:8080/:8081"]
        KC2[("bob-keycloak\n:8080/:9000")]
        KDB2[("bob-keycloak-db\nPostgreSQL :5432")]
        BOBDB2[("bob-db\nPostgreSQL :5432")]
        RD2[("redis-server-2\nredis+sentinel")]
    end

    subgraph W2["Worker Node 2  (16 CPU · 64 GB · 10.10.10.22)"]
        direction LR
        INF2["bob-inference\n:7330 / :7331 internal"]
        UI2["bob-admin-ui\n:3001"]
        RD1[("redis-server-1\nredis+sentinel")]
    end

    subgraph W3["Worker Node 3  (16 CPU · 64 GB · 10.10.10.23)"]
        direction LR
        AUTHN2["bob-authn\n:7330"]
        HAPROXY["redis-haproxy\n:6379/:6380 TLS"]
        RD0[("redis-server-0\nredis+sentinel")]
    end

    subgraph STORAGERWO["Block Storage RWO  ·  spec.blockStorageClass\ne.g. ocs-storagecluster-ceph-rbd"]
        B1[("bob-db · 2Gi · RWO")]
        B2[("keycloak-db · 2Gi · RWO")]
        B3[("vector-data · 1Gi · RWO\nprovisioned  ·  rag disabled")]
    end

    subgraph STORAGERWX["File Storage RWX  ·  spec.fileStorageClass\ne.g. ocs-storagecluster-cephfs  ·  no PVCs bound in this install"]
    end

    subgraph OPTIONAL2["Optional Add-ons  ·  disabled by default"]
        direction LR
        OPT_OS["OpenSearch  ·  rag.enabled: false"]
        OPT_ZP["zProxy  ·  zProxy.enabled: false"]
        OPT_VEC["Vector Agent  ·  vector.enabled: false"]
        OPT_ZU["Z Understand  ·  understand.enabled: false"]
    end

    BOBDB2 --> B1
    KDB2 --> B2
    INF2 -.->|provisioned| B3
    HAPROXY --> RD0 & RD1 & RD2
```

---

## Component Summary

| Component | Pod | Namespace | Node | Role |
|---|---|---|---|---|
| API Gateway | bob-gateway | ibm-bob | worker-1 | Routes all client requests · serves both UI and API routes |
| Application | bob-admin | ibm-bob | worker-1 | Admin interface backend |
| Application | bob-admin-ui | ibm-bob | worker-2 | Browser UI · calls gateway via svc.cluster.local:8443 |
| Auth | bob-authn | ibm-bob | worker-3 | Authentication (Keycloak OIDC) |
| Auth | bob-authz | ibm-bob | worker-1 | Authorization (policy enforcement) |
| Inference | bob-inference | ibm-bob | worker-2 | LLM request handling · model gateway |
| Identity | bob-keycloak | ibm-bob | worker-1 | OIDC / SSO — StatefulSet 1/1 |
| Database | bob-db (PostgreSQL) | ibm-bob | worker-1 | Primary app data store · ibm-pg-operator |
| Database | bob-keycloak-db (PostgreSQL) | ibm-bob | worker-1 | Keycloak-dedicated store · ibm-pg-operator |
| Cache | redis-server-0/1/2 | ibm-bob | worker-3/2/1 | Session & object cache · redis+sentinel per pod |
| Cache proxy | redis-haproxy | ibm-bob | worker-3 | HAProxy front-end to Redis cluster · :6379/:6380 TLS |
| Metering | ibm-usage-metering | ibm-bob | worker-1 | IBM license usage tracking · dedicated external route |
| Operator | ibm-bob-operator | ibm-bob-operators | worker-1 | Reconciles Bob CR |
| Operator | ibm-pg-operator | ibm-bob-operators | worker-1 | Manages PostgreSQL StatefulSets |
| Operator | ibm-redis-cp-operator | ibm-bob-operators | worker-1 | Manages Redis cluster |
| Operator | ibm-usage-metering-operator | ibm-bob-operators | worker-1 | Manages metering instance |
| Operator | rhbk-operator | ibm-bob-operators | worker-3 | Manages Keycloak StatefulSet |

## Routes (External Ingress)

| Route | Host | TLS Mode | Target |
|---|---|---|---|
| `bob-gateway` (UI) | `bob.ibm-bob.apps.<cluster>` | reencrypt | bob-gateway :8443 |
| `bob-gateway` (API) | `api.bob.ibm-bob.apps.<cluster>` | reencrypt | bob-gateway :8443 |
| `bob-keycloak-ingress` | `bob-keycloak.ibm-bob.apps.<cluster>` | edge | bob-keycloak-service :8080 |
| `ibm-usage-metering-fetch` | `ibm-usage-metering-fetch-ibm-bob.apps.<cluster>` | reencrypt | ibm-usage-metering :8080 |

## Storage

| Volume | Size | Access | Used by | Note |
|---|---|---|---|---|
| bob-db-1 | 2 Gi | RWO | PostgreSQL bob-db | `spec.blockStorageClass` (e.g. ocs-storagecluster-ceph-rbd) |
| bob-keycloak-db-1 | 2 Gi | RWO | PostgreSQL bob-keycloak-db | `spec.blockStorageClass` |
| vector-data | 1 Gi | RWO | (reserved) | Provisioned but unused — `rag.enabled: false` |
| _(none bound)_ | — | RWX | — | `spec.fileStorageClass` configured (e.g. ocs-storagecluster-cephfs) — no PVCs bound in this install |

## Optional Add-ons (disabled by default)

| Component | CR field | Purpose | Dependency |
|---|---|---|---|
| OpenSearch | `bob.rag.enabled` | RAG / vector search for code context | Standalone |
| Vector agent | `bob.vector.enabled` | Log collection to IBM COS | — |
| zProxy | `bob.zProxy.enabled` | IBM Z RAG stack | Implies `rag.enabled: true` |
| Z Understand | `bob.understand.enabled` | Mainframe code analysis (requires Db2 or SQL Server) | Standalone |

## Cluster Prerequisites

| Component | Required | Purpose |
|---|---|---|
| cert-manager | Yes (Red Hat Operator) | TLS for all external routes + internal mTLS |
| Helm ≥ 3.14.0 | Yes | `--reset-then-reuse-values` flag support |
| `oc` CLI | Yes | Install and management |
| Block storage (RWO) | Yes | Database PVCs |
| File storage (RWX) | Yes (configured) | Shared volumes — not yet consumed in this install |
