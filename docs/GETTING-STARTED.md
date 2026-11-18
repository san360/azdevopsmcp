# Getting started

This guide takes you from an API Management instance (or an empty resource group, if you let
the template create APIM) to a first successful MCP call through the gateway. Every step says **why** you run it and shows the **expected output**, so you
can tell at once whether it worked. Terms are explained in the [glossary](GLOSSARY.md).
Plan about 30 minutes with an existing API Management (APIM) instance, or about 75 if you
create one.

**Learning path:** [README](../README.md) (what and why) → **Getting started** (this page) →
[Testing](TESTING.md) → [Client guides](clients/README.md) →
[What APIM changes for clients](CLIENTS-APIM-CHANGES.md) → [Policies](POLICIES.md) →
[Analysis](ANALYSIS.md).

## 0. Prerequisites

| You need | Why |
|---|---|
| An Azure subscription with an APIM instance (Developer tier or higher), or permission to create one | APIM is the gateway under test. Developer tier is enough for a lab (no SLA) |
| Contributor on the resource group that holds APIM (`<rg>`), and Log Analytics Reader on it to run the KQL | The template deploys **into the APIM resource group** and creates the workspace and Application Insights there |
| Access to at least one project in the Azure DevOps organization | `core_list_projects` returns only projects the signed-in user can see |
| An **Entra-backed** Azure DevOps organization with at least one project | The hosted MCP server only accepts Microsoft Entra tokens. Create the organization in the Azure DevOps portal; there is no API for it |
| Azure CLI with Bicep (`az bicep version`), PowerShell 7.4+, Python 3.10+ | Deployment, the Entra script and the probe. Node.js only for MCP Inspector |
| In the organization's tenant: Application Administrator, Cloud Application Administrator or Global Administrator | `setup-entra.ps1` creates an app registration and a service principal |

## 1. Sign in to the right tenant

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
az account show --query "{name:name, tenant:tenantId}" -o table
```

**Why:** the Entra objects must live in the tenant that backs the Azure DevOps
organization, and the deployment goes to the subscription that holds APIM.
**Expected:** your subscription name and `<tenant-id>`.

## 2. Prepare Microsoft Entra

```powershell
./scripts/setup-entra.ps1 -TenantId <tenant-id> -GrantAdminConsent `
  -McpUrl https://<apim-name>.azure-api.net/ado-mcp-proxy/<org>, https://<apim-name>.azure-api.net/ado-mcp-native/<org>
```

**Why:**

1. It creates the **Azure DevOps MCP enterprise application** (service principal) in your
   tenant if it is missing. Without it, the hosted server accepts your token but answers
   every MCP request with **HTTP 500 and an empty body**
   ([troubleshooting guide](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting#cant-find-the-azure-devops-mcp-enterprise-application-in-the-tenant)).
2. It creates the **public client** app registration that the gateway hands to MCP clients,
   because Entra cannot register clients on the fly ([DCR](GLOSSARY.md#dcr)). It holds the
   delegated permission `Ado.Mcp.Tools` and the [redirect URIs](GLOSSARY.md#redirect-uri) of
   every tested client (VS Code, Copilot CLI, Codex, Claude Code, MCP Inspector, the probe).
   `-McpUrl` adds the per-URL redirect URIs that Codex needs. The URLs are predictable from
   the APIM name; use your custom domain if you have one.
3. `-GrantAdminConsent` consents for the whole tenant, so users are not prompted. Leave it
   out to let each user consent at first sign-in.

If your public client already exists under another name, add `-AppName <name>`.
Otherwise the script creates a new app called `ado-mcp-apim-client`.

**Expected:**

```text
1/3 Azure DevOps MCP enterprise application
    already present                              (or: created service principal for Azure DevOps MCP)
2/3 Public client app 'ado-mcp-apim-client'
    created <public-client-id>                   (or: updated <public-client-id>)
3/3 Consent
    admin consent granted for Ado.Mcp.Tools

publicClientId = '<public-client-id>'   (put this in infra/main.local.bicepparam and tools/probe.local.json)
```

Use the value as `publicClientId` in the Bicep parameters (step 3) and as `clientId` in
`tools/probe.local.json` (step 5). Rerunning the script keeps redirect URIs that are already
registered and adds the missing ones.

## 3. Fill in the parameters

```powershell
Copy-Item infra/main.example.bicepparam infra/main.local.bicepparam
```

Edit `infra/main.local.bicepparam`. It is git-ignored, so your values never reach the
repository:

| Parameter | Set to | Why |
|---|---|---|
| `apimName` | Your APIM instance | The gateway the lab configures |
| `adoOrganization` | Your organization name | Used for the output URLs; any allowed organization works at run time |
| `tenantId` | `<tenant-id>` | Where `/authorize` and `/token` send users. `organizations` (several tenants) also needs a multi-tenant public client and consent in each tenant; `setup-entra.ps1` creates a single-tenant app, so this is not covered by the lab |
| `publicClientId` | Output of step 2 | Returned by `/register`. Leave empty to deploy only the regular setup |
| `allowedOrganizations` | `['<org>']` | Only these organizations are accepted on the proxy; `[]` accepts any well-formed name |
| `createApim` | `false` (or `true` plus `publisherEmail`) | Creating a Developer-tier instance takes 30–45 minutes |

`allowedOrganizations`, `readOnly` and `toolsets` become APIM **named values**
(`mcp-allowed-organizations`, `mcp-readonly`, `mcp-toolsets`) that the policy fragments read.
You can change them in the portal (APIM → *Named values*) without redeploying; the next
deployment resets them to the parameters.

Other parameters (defaults are fine for a first run):

| Parameter | Default | Effect |
|---|---|---|
| `readOnly` | `true` | Both setups send `X-MCP-Readonly: true`; the server lists only read-only tools (26 of 43 in the lab, November 2026) |
| `toolsets` | `''` | Both setups: `X-MCP-Toolsets`, for example `repos,wit` |
| `rateLimitCalls` / `rateLimitPeriod` | `60` / `60` | Working setup: per-IP rate limit |
| `mcpRequestBodyBytes` | `4096` | JSON-RPC **request** bytes logged for MCP APIs (0 disables). Response bodies are never logged |
| `toolValidation` | `true` | Working setup: validate `tools/call` arguments of vetted tools ([TOOL-VALIDATION.md](TOOL-VALIDATION.md)) |
| `unlistedToolAction` | `allow` | `deny` rejects tools that have no gateway schema |
| `toolValidationDebug` | `false` | Lab only: echo raw validation errors, which can contain submitted values |

## 4. Validate, preview, deploy

`<rg>` is the resource group that holds APIM (with `createApim = true`, create it first with
`az group create -n <rg> -l <region>`).

```powershell
az bicep build --file infra/main.bicep --stdout > $null
az deployment group what-if -g <rg> --parameters infra/main.local.bicepparam
az deployment group create  -g <rg> --parameters infra/main.local.bicepparam --query properties.outputs
```

**Why:** `build` catches template errors locally. `what-if` shows exactly what will be
created or changed in APIM, and it changes nothing. `create` deploys: the Log Analytics
workspace, Application Insights, APIM loggers and diagnostics, the backend, the three APIs,
their policies, the tool schemas and the validation fragment.

**Expected** (`create`, after 2–5 minutes on an existing instance; abridged, the real output also
shows `"type"` for each value):

```json
{
  "nativeMcpUrl":  { "value": "https://<apim-name>.azure-api.net/ado-mcp-native/<org>" },
  "proxyMcpUrl":   { "value": "https://<apim-name>.azure-api.net/ado-mcp-proxy/<org>" },
  "originUrl":     { "value": "https://mcp.dev.azure.com/<org>" },
  "appInsightsName": { "value": "appi-<apim-name>" },
  "workspaceId":   { "value": "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/log-<apim-name>" },
  "validatedTools": { "value": [ "core_list_projects", "wit_work_item" ] }
}
```

If ARM answers `502` or a conflict, rerun `create`; deployments are idempotent.

From here on, **`<gateway>`** means the host of `nativeMcpUrl` (`https://<apim-name>.azure-api.net`,
or your custom domain), and the Log Analytics workspace name is `log-<apim-name>`. Note that
`workspaceId` is an ARM resource ID; `tools/query_logs.py` takes `-g <rg> -w log-<apim-name>`
(or `--workspace-id` with the workspace's *customer ID* GUID, not this output).

## 5. First call without a browser

```powershell
Copy-Item tools/probe.example.json tools/probe.local.json
python tools/mcp_probe.py --config tools/probe.local.json --token az
```

Before running, edit `tools/probe.local.json` (git-ignored):

| In the file | Replace with | From |
|---|---|---|
| `tenantId` | `<tenant-id>` | Step 1 |
| `clientId` | `<public-client-id>` | Step 2 (`publicClientId`) |
| `example-gateway.azure-api.net` (in every target URL) | your gateway host | Step 4 (`nativeMcpUrl`) |
| `example-organization` (URLs and `orgName`) | `<org>` | `adoOrganization` |
| `example-project` (validation cases) | a project you can access | Azure DevOps |

**Why:** the probe checks both setups and the origin the same way, without a person in the
loop. It runs discovery, emulates a client's sign-in up to Entra (and reports any `AADSTS`
code), then calls `initialize`, `tools/list` and `tools/call` with an Azure CLI token, and
finally the tool-validation cases. `--token az` uses
`az account get-access-token --scope https://mcp.dev.azure.com/.default`, which works once
step 2 has created the service principal.

**Expected** (abridged):

```text
XFAIL  origin           client: Entra authorize request: invalid_target AADSTS9010010; resource=https://mcp.dev.azure.com/<org> ...
PASS   origin-bare      client: Entra authorize request: sign-in page served [evaluated with tenant authority]; resource=https://mcp.dev.azure.com
XFAIL  apim-native      client: Entra authorize request: invalid_target AADSTS9010010; resource=https://<gateway>/ado-mcp-native/<org>
PASS   apim-native      mcp: tools/call core_list_projects: isError=False [...]
PASS   apim-proxy       discovery: GET without token is not 5xx: HTTP 405
PASS   apim-proxy       client: Entra authorize request: sign-in page served (via gateway redirect); resource=https://mcp.dev.azure.com
PASS   apim-proxy       mcp: tools/call core_list_projects: isError=False [...]
PASS   apim-proxy       validation: core_list_projects top out of range: gateway JSON-RPC error -32602 [top:maximum]
INFO   apim-native      validation: core_list_projects top out of range: not validated at the gateway; server answered server result: [...]
... checks, 2 expected failures, 0 unexpected
```

`XFAIL` marks a failure that is expected for that target: the reproduction. The exit code is
non-zero only when something differs from expectations.

## 6. First sign-in with a real client

Pick one client from [docs/clients](clients/README.md). VS Code is the quickest: add
`https://<gateway>/ado-mcp-proxy/<org>` as an HTTP MCP server, start it, sign in, and ask
*"List the Azure DevOps projects I can access."* Then add the native URL and watch the
sign-in fail with `AADSTS9010010`. That is the reported problem, reproduced.

## 7. Look at the logs

Wait 2–5 minutes, then:

```powershell
python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name>
```

You see one row per policy trace (a request with several traces appears several times): client (`User-Agent`), step (`prm`, `register`,
`authorize`, `token`, `proxy-inbound`), redirect URI and the token's client app. More queries
are in [OBSERVABILITY.md](OBSERVABILITY.md).

## Organization mapping and multiple organizations

Both setups use **one backend**, the bare host `https://mcp.dev.azure.com`. The
organization is the last segment of the **client URL**, and APIM appends it when
forwarding. One deployment therefore serves any number of organizations:

| Client URL | Forwarded to | Notes |
|---|---|---|
| `https://<gateway>/ado-mcp-proxy/contoso` | `https://mcp.dev.azure.com/contoso` | Working setup; add one MCP server entry per organization |
| `https://<gateway>/ado-mcp-proxy/fabrikam` | `https://mcp.dev.azure.com/fabrikam` | Same deployment, same sign-in (same tenant) |
| `https://<gateway>/ado-mcp-proxy` | `https://mcp.dev.azure.com` | No organization: tools need an `orgName` argument |
| `https://<gateway>/ado-mcp-native/<org>` | `https://mcp.dev.azure.com/<org>` | Regular setup |

In the working setup, each per-organization URL gets its own protected-resource metadata
(`/.well-known/oauth-protected-resource/ado-mcp-proxy/<org>`) whose `resource` equals that
URL. All organizations share one authorization facade, because the token audience is the
same (`https://mcp.dev.azure.com`). Organization names are validated
(`^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$`) and checked against `allowedOrganizations`. Anything
else returns `404` before reaching Azure DevOps. Organizations in **different Entra tenants**
need `tenantId = 'organizations'`, so users sign in with the account of the tenant that
backs each organization. That also needs a multi-tenant public client with consent in each
tenant; `setup-entra.ps1` creates a single-tenant app, and the lab did not test this case. Codex needs one redirect URI per URL, so pass every organization
URL to `setup-entra.ps1 -McpUrl`.

Why not put the organization in the backend URL? APIM's native pass-through appends
everything after the API path to the backend URL. That applies to MCP calls and to the
PRM path it advertises:

| Backend URL | Client URL | PRM URL APIM advertises → forwards to | Result |
|---|---|---|---|
| `https://mcp.dev.azure.com/<org>` | `/ado-mcp-native` | `/<org>/.well-known/oauth-protected-resource/<org>` | 404, discovery breaks |
| `https://mcp.dev.azure.com` (used) | `/ado-mcp-native/<org>` | `/.well-known/oauth-protected-resource/<org>` | 200; only Entra fails |

`docs/kql/backend-url-mapping.kql` shows the effective `BackendUrl` per request. The portal
shows only the API base URL. **Clients must append `/<org>`.**

## Clean up

Delete the lab resource group (or, with an existing APIM, the three APIs, the schemas, the
policy fragment, the loggers and diagnostics this lab added). APIM Developer tier is billed
per hour while it exists. Remove the public client app registration if you no longer need it.
