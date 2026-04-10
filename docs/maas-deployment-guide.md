# MaaS Deployment Guide — RHOAI 3.3 on xKS

This document covers the full stack deployment and end-to-end authentication flow
for Models as a Service (MaaS) running on managed Kubernetes (AKS), replicating
the RHOAI 3.3 experience from OpenShift.

## Stack Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         AKS Cluster                             │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │ cert-manager │  │ Sail (Istio) │  │  LWS Operator      │    │
│  │   operator   │  │  + Gateway   │  │  (LeaderWorkerSet) │    │
│  │  (TLS PKI)   │  │    API       │  │  (multi-node GPU)  │    │
│  └──────────────┘  └──────────────┘  └────────────────────┘    │
│                                                                 │
│  ┌──────────────┐  ┌─────────────────────────────────────┐     │
│  │    KServe     │  │  RHCL (Kuadrant)                    │     │
│  │  controller   │  │  ├─ Authorino (AuthN/AuthZ)         │     │
│  │ (model CRDs)  │  │  ├─ Limitador (rate limiting)       │     │
│  └──────────────┘  │  └─ DNS/TLS policy operators         │     │
│                     └─────────────────────────────────────┘     │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  MaaS (charts/maas)                                      │   │
│  │  ├─ maas-api (RHOAI 3.3 productized image)              │   │
│  │  ├─ PostgreSQL (API keys + subscriptions)                │   │
│  │  ├─ Keycloak (OIDC identity provider, auto-configured)   │   │
│  │  ├─ Gateway + HTTPRoute                                  │   │
│  │  ├─ AuthPolicy (API key + JWT auth via Authorino)        │   │
│  │  └─ InferenceService CRD (bundled)                       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
export KUBECONFIG=~/.kube/aks-cluster.yaml
cd rhaii-on-xks/

# One command deploys the full stack
make deploy-all RHCL=true MAAS=true
```

This deploys (in order):

1. **cert-manager** — TLS certificate management
2. **Sail Operator (Istio)** — Gateway API + service mesh
3. **LWS Operator** — LeaderWorkerSet for multi-node GPU workloads
4. **RHCL (Kuadrant)** — Authorino (auth), Limitador (rate limiting)
5. **KServe** — LLMInferenceService controller
6. **MaaS** — maas-api, PostgreSQL, Keycloak, Gateway, AuthPolicy

After deployment, the user deploys a model (`InferenceService` CR) and interacts
with it via the MaaS API gateway.

## Component Details

| Component | Namespace | Image / Chart | Purpose |
|-----------|-----------|---------------|---------|
| cert-manager-operator | cert-manager | `charts/cert-manager-operator` | TLS certificate management |
| Sail Operator (Istio) | istio-system | `charts/sail-operator` | Gateway API, service mesh |
| LWS Operator | lws-system | `charts/lws-operator` | Multi-node GPU workloads |
| KServe | opendatahub | OCI chart from `ghcr.io` | LLMInferenceService lifecycle |
| RHCL (Kuadrant) | kuadrant-system | `charts/rhcl` | API gateway auth, rate limiting |
| MaaS API | opendatahub | `registry.redhat.io/rhoai/odh-maas-api-rhel9` (v3.3.0 by digest) | API key mgmt, model listing |
| PostgreSQL | opendatahub | `registry.redhat.io/rhel9/postgresql-15` | Persistent storage for MaaS |
| Keycloak | keycloak | `quay.io/keycloak/keycloak:24.0` | OIDC identity provider (bundled) |

## MaaS Helm Chart — Template Inventory

```
charts/maas/
├── Chart.yaml                          # v0.2.0-rhoai33, appVersion 3.3
├── values.yaml                         # All configurable values
├── helmfile.yaml.gotmpl                # Helmfile release + presync/postsync hooks
├── crds/
│   └── serving.kserve.io_inferenceservices.yaml   # Bundled KServe CRD
└── templates/
    ├── namespace.yaml                  # opendatahub namespace
    ├── pull-secret.yaml                # registry.redhat.io credentials (with lookup guard)
    ├── gateway.yaml                    # Gateway API Gateway resource
    ├── httproute.yaml                  # HTTPRoute: /v1/models + /maas-api/*
    ├── networkpolicy.yaml              # Network policies
    ├── tier-mapping.yaml               # ConfigMap: tier-to-group-mapping
    ├── maas-api/
    │   ├── deployment.yaml             # maas-api Deployment (--storage=external)
    │   ├── service.yaml                # ClusterIP service on port 8080
    │   ├── serviceaccount.yaml         # ServiceAccount
    │   ├── clusterrole.yaml            # RBAC: inferenceservices, configmaps, secrets, etc.
    │   └── role.yaml                   # Namespaced Role for secrets
    ├── postgresql/
    │   ├── deployment.yaml             # PostgreSQL Deployment
    │   └── secret.yaml                 # DB connection URL secret
    ├── keycloak/
    │   ├── namespace.yaml              # keycloak namespace (with lookup guard)
    │   ├── deployment.yaml             # Keycloak with --import-realm
    │   ├── service.yaml                # ClusterIP on port 8080
    │   └── realm-configmap.yaml        # Pre-configured realm JSON (auto-import)
    └── policies/
        ├── default-auth.yaml           # Gateway-level deny-all default
        └── maas-api-auth-policy.yaml   # Per-route AuthPolicy (API key + JWT)
```

## Deployment Options

### Option 1: Full Stack (Recommended)

Deploys everything including Keycloak as the identity provider:

```bash
make deploy-all RHCL=true MAAS=true
```

Keycloak is auto-configured with:
- Realm: `maas`
- Client: `maas-gateway` (with groups protocol mapper)
- Group: `system:authenticated`
- Demo user: `demo-user` / `demo-password`

No manual Keycloak setup needed.

### Option 2: Azure AD Instead of Keycloak

For enterprise environments using Azure AD for identity:

```bash
make deploy-all RHCL=true MAAS=true

# Then redeploy MaaS with Azure AD:
helmfile apply --selector name=maas \
  --state-values-set maas.enabled=true \
  --set keycloak.deploy=false \
  --set azureAD.enabled=true \
  --set azureAD.tenantId=<your-tenant-id> \
  --set azureAD.clientId=<your-client-id>
```

**Prerequisites**: Azure AD App Registration must have "Expose an API" configured.
See `docs/azure-ad-identity-provider.md` for full setup instructions.

### Option 3: MaaS-Only (Operators Already Running)

```bash
helmfile apply --selector name=maas --state-values-set maas.enabled=true
```

## Authentication Architecture

### How It Works on OpenShift (RHOAI 3.3)

On OpenShift, MaaS uses `kubernetesTokenReview` via Authorino to validate
OpenShift user tokens. The user's identity and groups come from the OpenShift
OAuth server.

### How We Replicated It on xKS

On managed Kubernetes (AKS), there is no OpenShift OAuth server. We replaced
`kubernetesTokenReview` with a pluggable OIDC provider (Keycloak or Azure AD)
while keeping the rest of the architecture identical:

```
                    ┌─────────────────────────────────────────────┐
                    │             Authorino (RHCL)                │
                    │                                             │
  User Request ──►  │  1. Check Authorization header:             │
  (Bearer token)    │     ├─ "Bearer sk-oai-*" → API key flow     │
                    │     └─ Other Bearer → JWT flow              │
                    │                                             │
                    │  API Key Flow:                               │
                    │     2a. Extract key from header              │
                    │     3a. POST to /internal/v1/api-keys/      │
                    │         validate (callback to maas-api)     │
                    │     4a. Check response.valid == "true"       │
                    │     5a. Inject X-MaaS-Username,             │
                    │         X-MaaS-Group, X-MaaS-Subscription   │
                    │                                             │
                    │  JWT Flow (Keycloak / Azure AD):             │
                    │     2b. Validate JWT against OIDC issuer    │
                    │     3b. Check audience (azp / aud)          │
                    │     4b. Inject X-MaaS-Username from         │
                    │         preferred_username claim            │
                    │     5b. Inject X-MaaS-Group from            │
                    │         groups claim                        │
                    │                                             │
                    └──────────────┬──────────────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────────────────────┐
                    │              maas-api                        │
                    │                                             │
                    │  Reads X-MaaS-Username, X-MaaS-Group        │
                    │  Maps group → tier (via tier-mapping CM)    │
                    │  Serves /v1/models, /v1/api-keys, etc.     │
                    └─────────────────────────────────────────────┘
```

### Auth Methods

| Auth Method | Token Format | When Used | Header Injection |
|-------------|-------------|-----------|-----------------|
| API Key | `Bearer sk-oai-<key>` | Programmatic access | Username, group, subscription from MaaS API callback |
| JWT (Keycloak) | `Bearer eyJ...` | Default (bundled) | `preferred_username` and `groups` from JWT claims |
| JWT (Azure AD) | `Bearer eyJ...` | Enterprise SSO | `preferred_username` and `groups` from Azure AD claims |

### Tier Mapping

MaaS API maps user groups to subscription tiers using the `tier-to-group-mapping`
ConfigMap. The mapping must include `groups` for each tier:

```yaml
- name: free
  displayName: Free Tier
  level: 0
  groups:
    - tier-free-users
    - system:authenticated    # All authenticated users get free tier
- name: premium
  displayName: Premium Tier
  level: 1
  groups:
    - tier-premium-users
- name: enterprise
  displayName: Enterprise Tier
  level: 2
  groups:
    - tier-enterprise-users
    - admin-group
```

## User Workflow After Deployment

Once `make deploy-all RHCL=true MAAS=true` completes:

### 1. Deploy a Model

```bash
kubectl apply -f my-model.yaml   # InferenceService or LLMInferenceService CR
```

### 2. Get a JWT Token

```bash
# From inside the cluster (issuer must match Authorino config):
kubectl run token --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST \
    http://keycloak.keycloak.svc.cluster.local:8080/realms/maas/protocol/openid-connect/token \
    -d grant_type=password \
    -d client_id=maas-gateway \
    -d client_secret=maas-gateway-secret \
    -d username=demo-user \
    -d password=demo-password
```

### 3. List Models

```bash
GATEWAY_IP=$(kubectl get gateway maas-default-gateway -n istio-system -o jsonpath='{.status.addresses[0].value}')

curl -H "Authorization: Bearer $TOKEN" http://$GATEWAY_IP/v1/models
```

### 4. Create an API Key

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-key","expirationDays":30}' \
  http://$GATEWAY_IP/maas-api/v1/api-keys
```

### 5. Use the API Key (No JWT Needed)

```bash
curl -H "Authorization: Bearer sk-oai-<your-key>" \
  http://$GATEWAY_IP/v1/models
```

## End-to-End Test

After deployment, verify the full flow from inside the cluster:

```bash
GATEWAY_IP=$(kubectl get gateway maas-default-gateway -n istio-system -o jsonpath='{.status.addresses[0].value}')

kubectl run e2e-test --rm -i --restart=Never --image=curlimages/curl -- sh -c '
TOKEN=$(curl -s -X POST \
  http://keycloak.keycloak.svc.cluster.local:8080/realms/maas/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=maas-gateway \
  -d client_secret=maas-gateway-secret \
  -d username=demo-user \
  -d password=demo-password | grep -o "access_token\":\"[^\"]*" | cut -d\" -f3)
echo "Token length: ${#TOKEN}"
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | grep -o "groups\":\[[^]]*\]"

echo "=== GET /v1/models ==="
curl -s -w "\nHTTP %{http_code}\n" -H "Authorization: Bearer $TOKEN" http://'"$GATEWAY_IP"'/v1/models

echo "=== GET /maas-api/v1/api-keys ==="
curl -s -w "\nHTTP %{http_code}\n" -H "Authorization: Bearer $TOKEN" http://'"$GATEWAY_IP"'/maas-api/v1/api-keys
'
```

Expected output:

```
Token length: ~1200
groups":["system:authenticated"]

=== GET /v1/models ===
{"data":null,"object":"list"}
HTTP 200

=== GET /maas-api/v1/api-keys ===
[]
HTTP 200
```

## xKS Compatibility Gaps Solved

| Gap | OpenShift (RHOAI 3.3) | xKS Solution |
|-----|----------------------|--------------|
| User identity | `kubernetesTokenReview` via OpenShift OAuth | Pluggable OIDC: Keycloak (bundled) or Azure AD |
| InferenceService CRD | Pre-installed by OpenShift AI operator | Bundled in `charts/maas/crds/` |
| Image pulls | Internal registry, no auth needed | `imagePullSecrets` + `redhat-pull-secret` with lookup guard |
| MaaS API image tag | Human-readable tag (e.g., `v3.3`) | Digest tag `sha256-0c9a17...` (no readable tag published) |
| Storage flag | Implicit (OpenShift operator sets it) | Explicit `command: ["./maas-api"]` + `args: ["--storage=external"]` |
| Gateway | OpenShift Routes | Gateway API + Istio (`gatewayClassName: istio`) |
| maas-controller | Not present in 3.3 | N/A — manual policy creation |
| RBAC | Managed by OpenShift AI operator | Full ClusterRole matching upstream |
| Pull secret conflicts | Single operator manages namespace | `lookup` guard prevents Helm ownership conflicts |
| Identity provider setup | Built into OpenShift | Keycloak auto-deployed and configured by the chart |

## Gateway Routes

| Path | Backend | Description |
|------|---------|-------------|
| `/v1/models` | `maas-api:8080` | OpenAI-compatible model listing |
| `/maas-api/*` | `maas-api:8080` (rewrite to `/`) | All other MaaS API endpoints (api-keys, subscriptions, health) |

## Teardown

```bash
# Remove MaaS only
make undeploy-maas

# Remove everything
make undeploy
```
