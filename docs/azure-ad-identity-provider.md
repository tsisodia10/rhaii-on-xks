# Azure AD as Identity Provider for MaaS on xKS

## Status: Blocked — App Registration Setup Required

Azure AD can replace OpenShift's `kubernetesTokenReview` as the user identity
provider for MaaS API on xKS. The Helm chart supports it via `azureAD.enabled`,
but the Azure AD tenant must be pre-configured before tokens can be issued.

## What Works

- AuthPolicy template conditionally renders Azure AD JWT authentication
- Authorino validates tokens against `https://login.microsoftonline.com/{tenantId}/v2.0`
- Audience check ensures tokens are scoped to the correct App Registration
- Response headers extract `preferred_username` and `groups` from Azure AD claims

## Prerequisites (Azure Portal)

Before enabling `azureAD.enabled=true`, the following must be configured in the
Azure AD tenant by a tenant admin:

1. **Create or select an App Registration**
   - Note the Application (client) ID → `azureAD.clientId`
   - Note the Directory (tenant) ID → `azureAD.tenantId`

2. **Expose an API** (App Registration → "Expose an API")
   - Set the Application ID URI (e.g., `api://<clientId>`)
   - Add a scope (e.g., `access_as_user`)

3. **Authorize the Azure CLI** (for developer token acquisition)
   - Under the exposed API, click "Add a client application"
   - Add Azure CLI client ID: `04b07795-8ddb-461a-bbee-02f9e1bf7b46`
   - Check the scope checkbox

4. **Configure Groups claim** (App Registration → "Token configuration")
   - Add a groups claim so JWT tokens include the user's group memberships
   - This maps to the `X-MaaS-Group` header for tier resolution

## Usage

```bash
# Deploy with Azure AD enabled
helmfile apply --selector name=maas \
  --state-values-set maas.enabled=true \
  --set azureAD.enabled=true \
  --set azureAD.tenantId=<your-tenant-id> \
  --set azureAD.clientId=<your-client-id>

# Get a token (requires step 3 above)
az login --tenant <tenant-id>
TOKEN=$(az account get-access-token \
  --scope api://<client-id>/.default \
  --query accessToken -o tsv)

# Test
curl -H "Authorization: Bearer $TOKEN" http://<gateway-ip>/v1/models
```

## Error Without Setup

Without steps 2-3, `az account get-access-token` returns:

```
AADSTS650057: Invalid resource. The client has requested access to a resource
which is not listed in the requested permissions in the client's application
registration.
```

## Current Workaround

Use Keycloak as the identity provider instead (`keycloak.enabled=true`).
Keycloak runs in-cluster and does not require external admin configuration.
