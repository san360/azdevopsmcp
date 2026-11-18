# Testing guide

Every test runs from your own machine against the deployed lab. Use the URLs from the
deployment outputs:

| Name | URL | Expected |
|---|---|---|
| Origin (org URL) | `https://mcp.dev.azure.com/<org>` | Data plane works; spec-strict sign-in fails (Azure DevOps PRM issue, see ANALYSIS) |
| Origin (bare) | `https://mcp.dev.azure.com` | Works; pass `orgName` to tools |
| **Regular setup** | `https://<gateway>/ado-mcp-native/<org>` | Data plane works; sign-in fails (`AADSTS9010010` or "no DCR") |
| **Working setup** | `https://<gateway>/ado-mcp-proxy/<org>` | Sign-in and data plane work (any allowed organization) |
| Working setup, no org | `https://<gateway>/ado-mcp-proxy` | Works; pass `orgName` to tools |

The portal shows the native MCP server URL **without** `/<org>`. Always append it (see
[organization mapping](GETTING-STARTED.md#organization-mapping-and-multiple-organizations)).

New to the lab? Deploy it first with [GETTING-STARTED.md](GETTING-STARTED.md). Terms are in the
[glossary](GLOSSARY.md).

## 1. End-to-end probe (no browser needed)

`tools/mcp_probe.py` uses only the Python standard library. For every target it runs:

1. **discovery**: unauthenticated `initialize`, the `401` challenge, the advertised PRM, and a
   body-less `GET` that must not return `5xx` (OpenAI Codex sends one before signing in).
2. **client**: emulates an MCP client the way VS Code does it. It accepts PRM only if
   `resource` equals the server URL (RFC 9728) and falls back as VS Code does. It loads
   authorization-server metadata, calls `/register` when offered, then sends the
   authorization request with `resource` + `scope` (RFC 8707). It follows one gateway
   redirect to Entra and reports any `AADSTS` code. No one signs in. For the multi-tenant
   `organizations` authority it evaluates with the configured tenant, because Entra checks
   resource/scope only once it knows the user's tenant.
3. **mcp**: with a token, `initialize` → `notifications/initialized` → `tools/list` → `tools/call core_list_projects`.
4. **validation**: with a token, every `validationCases` entry against targets marked
   `toolValidation` (see section 5).

```powershell
Copy-Item tools/probe.example.json tools/probe.local.json
# edit tenantId, clientId (publicClientId from setup-entra.ps1), example-gateway.azure-api.net,
# example-organization and example-project (see GETTING-STARTED.md step 5)

python tools/mcp_probe.py --config tools/probe.local.json                 # discovery + client only
python tools/mcp_probe.py --config tools/probe.local.json --token az      # + MCP calls (Azure CLI token)
python tools/mcp_probe.py --config tools/probe.local.json --token browser # + MCP calls (interactive, clientId)
python tools/mcp_probe.py --config tools/probe.local.json --token az --only apim-proxy --json-out result.json
```

Token options:

| `--token` | Source | Notes |
|---|---|---|
| `none` (default) | n/a | Discovery and client emulation only |
| `az` | `az account get-access-token --scope https://mcp.dev.azure.com/.default` | Quickest. The token has `aud` Azure DevOps MCP, `azp` Azure CLI and `scp` `Ado.Mcp.Tools` |
| `browser` | Authorization code + PKCE with `clientId` from the config, loopback redirect `http://localhost:<port>` | Same flow a real client uses |
| `env` | `MCP_ACCESS_TOKEN` | Bring your own token. Never commit it |

Each line prints `[apim <id>]` (the `x-apim-request-id` / Log Analytics `CorrelationId`). At
the end the probe prints the **run ID** and **trace ID**. `expectFailures` in the config marks
known failures as `XFAIL`. The exit code is `0` unless a result differs from expectations.
Tokens are kept in memory only.

Unit and loopback tests (no network):

```powershell
python -m unittest discover -s tools/tests -v
```

## 2. curl / PowerShell (raw protocol)

```powershell
$gw  = 'https://<gateway>'
$init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
$h = @{ Accept = 'application/json, text/event-stream' }

# a) the 401 challenge: native rewrites to the gateway, proxy points at APIM-hosted metadata
Invoke-WebRequest "$gw/ado-mcp-native/<org>" -Method Post -Body $init -ContentType application/json -Headers $h -SkipHttpErrorCheck |
  Select-Object StatusCode, @{n='WWW-Authenticate';e={$_.Headers['WWW-Authenticate']}}

# b) the PRM each setup returns
Invoke-RestMethod "$gw/ado-mcp-native/.well-known/oauth-protected-resource/<org>" | ConvertTo-Json   # resource = gateway URL, scope = Azure DevOps
Invoke-RestMethod "$gw/.well-known/oauth-protected-resource/ado-mcp-proxy/<org>" | ConvertTo-Json    # resource = gateway URL, AS = gateway
Invoke-RestMethod "$gw/.well-known/oauth-authorization-server" | ConvertTo-Json                      # APIM authorization-server metadata

# c) authenticated calls
$token = az account get-access-token --scope https://mcp.dev.azure.com/.default --query accessToken -o tsv
$h.Authorization = "Bearer $token"
$r = Invoke-WebRequest "$gw/ado-mcp-proxy/<org>" -Method Post -Body $init -ContentType application/json -Headers $h
$r.Content                                   # SSE: event: message / data: {...serverInfo AzureDevOps.Mcp...}
$h['Mcp-Session-Id'] = $r.Headers['Mcp-Session-Id']   # generic MCP step; the Azure DevOps server issues no session ID
Invoke-WebRequest "$gw/ado-mcp-proxy/<org>" -Method Post -ContentType application/json -Headers $h `
  -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' | Select-Object StatusCode   # 202
(Invoke-WebRequest "$gw/ado-mcp-proxy/<org>" -Method Post -ContentType application/json -Headers $h `
  -Body '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"core_list_projects","arguments":{"top":5}}}').Content
```

Reproduce the Entra rejection without a browser. Send the request an RFC 8707 client builds
from the native PRM, and do not follow redirects:

```powershell
$q = @{
  client_id = '<public-client-id>'; response_type = 'code'; redirect_uri = 'http://localhost'
  scope = 'https://mcp.dev.azure.com/.default'; resource = "$gw/ado-mcp-native/<org>"
  code_challenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'; code_challenge_method = 'S256'; state = 'x'
}
$qs = ($q.GetEnumerator() | % { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&'
$r = Invoke-WebRequest "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize?$qs" -MaximumRedirection 0 -SkipHttpErrorCheck -AllowInsecureRedirect -ErrorAction SilentlyContinue
[System.Net.WebUtility]::UrlDecode($r.Headers.Location)   # ...error=invalid_target&error_description=AADSTS9010010...
# Change resource to https://mcp.dev.azure.com and Entra serves the sign-in page instead.
```

## 3. Real MCP clients (VS Code, Copilot CLI, Codex, Claude Code, MCP Inspector)

Each client has its own guide with configuration, sign-in steps, expected output, a test
prompt and the matching log query: [docs/clients](clients/README.md). Why the clients
behave differently, and what the gateway changes for them:
[CLIENTS-APIM-CHANGES.md](CLIENTS-APIM-CHANGES.md).

| Client | Proxy (working setup) | Native (regular setup) |
|---|---|---|
| [VS Code](clients/vscode.md) | ✅ | ❌ `AADSTS9010010` |
| [GitHub Copilot CLI](clients/copilot-cli.md) | ✅ | ⚠️ connects through its own Entra broker (interactive only) |
| [OpenAI Codex CLI](clients/codex.md) | ✅ | ⚠️ connects only because the working setup's OAuth endpoints share the host |
| [Claude Code](clients/claude-code.md) | ✅ | ❌ no DCR, or `AADSTS9010010` with `--client-id` |
| [MCP Inspector](clients/mcp-inspector.md) | ✅ | ❌ no DCR, or `AADSTS9010010` with a client ID |

## 4. Find a request in the logs

The probe and every APIM response give you an `x-apim-request-id`; the probe also prints a
run ID and a W3C trace ID. Allow 2–5 minutes for ingestion. The first diagnostic setting can
take longer.

```powershell
$la = @('-g','<rg>','-w','log-<apim-name>')
python tools/query_logs.py docs/kql/requests-by-run.kql @la --param run-id=<run-id>
python tools/query_logs.py docs/kql/gateway-by-request-id.kql @la --param x-apim-request-id=<id>
python tools/query_logs.py docs/kql/www-authenticate-rewrite.kql @la
python tools/query_logs.py docs/kql/backend-url-mapping.kql @la
python tools/query_logs.py docs/kql/policy-traces.kql @la --param run-id=<run-id>   # <trace> events per step
python tools/query_logs.py docs/kql/tool-validation.kql @la --param run-id=<run-id>  # validation decisions, backend reached?
python tools/query_logs.py docs/kql/client-signins.kql @la --param client=codex     # one client's sign-in steps (User-Agent filter)
```

Or paste the `.kql` files into **Application Insights → Logs** or **Log Analytics → Logs**.
In App Insights, `OperationId` equals the probe's trace ID. Gateway calls are under **requests** (not traces). The **traces** table holds the `<trace>` policy events. See [OBSERVABILITY.md](OBSERVABILITY.md).

## 5. Tool argument validation (working setup)

The probe runs every entry in `validationCases` against targets marked
`"toolValidation": "enforced"` (the proxy) and `"none"` (native, for comparison):

```powershell
python tools/mcp_probe.py --config tools/probe.local.json --token az --only apim-proxy --only apim-native
```

| Case | Proxy (enforced) | Native (no validation) |
|---|---|---|
| `core_list_projects` `{"top":5}` | PASS (forwarded) | PASS |
| `top:"5"` / `top:500` / `stateFilter:"everything"` / unknown `query` | `-32602` `[top:type]` / `[top:maximum]` / `[stateFilter:enum]` / `[query:additionalProperties]` | server **accepts** `"5"`, `500` and `query`, and reports a generic tool error for the enum |
| `top:500` with `MCP-Protocol-Version: 2025-11-25` | `result.isError: true` | — |
| `wit_work_item` `{"action":"my","project":…}` | PASS | PASS |
| `{}` / `action:"delete"` / `id:"12"` / `id:0` / `get` without `id` / unknown `wiql` | `-32602` `[action:required]` / `[action:enum]` / `[id:type]` / `[id:minimum]` / `[id:required]` / `[wiql:additionalProperties]` | server runs the tool and returns `isError` texts, or **accepts** `wiql` |
| `CORE_LIST_PROJECTS` (other case) | `-32602` `[params.name:const]` | server: unknown tool |
| JSON-RPC batch `[{…}]` | `-32602` `[request:batch-not-allowed]` | HTTP 500 from the server |

A rejected call by hand (PowerShell):

```powershell
$gw = 'https://<gateway>'; $token = az account get-access-token --scope https://mcp.dev.azure.com/.default --query accessToken -o tsv
$h = @{ Authorization = "Bearer $token"; Accept = 'application/json, text/event-stream'; 'MCP-Protocol-Version' = '2025-06-18' }
$body = '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"core_list_projects","arguments":{"top":"5","query":1}}}'
$r = Invoke-WebRequest "$gw/ado-mcp-proxy/<org>" -Method Post -Body $body -ContentType application/json -Headers $h
$r.Headers['x-mcp-gateway-validation']   # rejected
$r.Content                               # {"jsonrpc":"2.0","id":11,"error":{"code":-32602,"message":"Invalid arguments for tool core_list_projects: top violates type; query violates additionalProperties. ..."}}

$h['MCP-Protocol-Version'] = '2025-11-25'   # newer clients get a tool execution error instead
(Invoke-WebRequest "$gw/ado-mcp-proxy/<org>" -Method Post -Body $body -ContentType application/json -Headers $h).Content
# {"jsonrpc":"2.0","id":11,"result":{"content":[{"type":"text","text":"Invalid arguments for tool core_list_projects: ..."}],"isError":true}}
```

The same with curl:

```bash
curl -s https://<gateway>/ado-mcp-proxy/<org> -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"wit_work_item","arguments":{"action":"get","id":0}}}'
# {"jsonrpc":"2.0","id":12,"error":{"code":-32602,"message":"Invalid arguments for tool wit_work_item: id violates minimum. ..."}}
```

In MCP Inspector (UI), call `core_list_projects` with `top` = `500` to see the gateway's
error in the tool result pane. In VS Code, the agent receives the error text and usually
retries with corrected arguments.

**Prove the backend was never called.** After 2–5 minutes:

```powershell
python tools/query_logs.py docs/kql/tool-validation.kql -g <rg> -w log-<apim-name> --param run-id=<run-id>
```

Rejected rows show `result: rejected`, the violations (field and rule only),
`reachedBackend: false` and an empty `BackendResponseCode`. Passed rows show
`reachedBackend: true` and `BackendResponseCode: 200`.

**Deny unvetted tools.** Redeploy with `unlistedToolAction=deny`
(`az deployment group create … --parameters infra/main.local.bicepparam unlistedToolAction=deny`).
`tools/call repo_repository` then returns
`-32602 "Tool repo_repository is not allowed by the gateway policy."`, and the header reads
`x-mcp-gateway-validation: denied`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Origin returns **500 with an empty body** for every authenticated call | The *Azure DevOps MCP* service principal is missing in the tenant | `scripts/setup-entra.ps1` (or `az ad sp create --id 2a72489c-aab2-4b65-b93a-a91edccf33b8`) |
| `AADSTS9010010 … resource … doesn't match … scopes` | `resource` is not an Azure DevOps MCP identifier URI (native pass-through, or the org URL directly) | Use the working setup, or the bare origin URL |
| `Incompatible auth server: does not support dynamic client registration` | The authorization server is Entra (native setup), and Entra has no DCR | Use the working setup, or give the client a pre-registered client ID |
| `Issuer mismatch … expected …/organizations/v2.0, received …/{tenantid}/v2.0` | Client connected to a URL **without `/<org>`**, so the bare PRM advertises the multi-tenant authority, whose templated issuer fails strict RFC 8414 checks | Append `/<org>` to the native URL, or use the working setup |
| `AADSTS50011` redirect URI mismatch (after sign-in) | The client's redirect URI is not on the public client. Each CLI uses its own: Copilot CLI `http://127.0.0.1:<port>/`, Claude Code `http://localhost:<port>/callback`, Codex `http://127.0.0.1:<port>/callback/<id per URL>` | Re-run `setup-entra.ps1` (with `-McpUrl <url>` for Codex). The `register` trace in `client-signins.kql` shows the URI the client used |
| `AADSTS65001` consent | No consent for `Ado.Mcp.Tools` | `setup-entra.ps1 -GrantAdminConsent` or user consent |
| Native discovery `404` on the PRM URL | Organization placed in the backend URL; APIM duplicates it in the PRM path | Bare backend + `/<org>` in the client URL (this repo's default) |
| `VS30063 … https://dev.azure.com` on `tools/call` | Backend called without the organization, for example an MCP endpoint override APIM ignores (`/mcp` becomes the org name) | Check `backend-url-mapping.kql`; use the URL shapes above |
| Tool calls hang or stream arrives at once | Response buffering or body logging | Keep response body bytes at 0; never read `context.Response.Body` |
| `Organization name is required` (bare origin) | Bare URL has no organization context | Pass `orgName` in tool arguments |
| `404 {"error":"unknown_organization"}` (working setup) | Organization not in `allowedOrganizations`, or not a valid name | Add it to the parameter and redeploy |
| Every request to the proxy fails with `400 Unspecified content type application/json is not allowed`, or validation never triggers | The proxy POST operation lacks an `application/json` request representation, which `validate-content` requires | Redeploy `mcp-proxy.bicep` (it declares the representation) |
| Native MCP API returns 500 for every request after adding validation | `validate-content` cannot run on native MCP APIs (no operations) | Keep validation on the proxy only (default) |
| A valid call is rejected with `-32602` | The curated schema is stricter than the server, or out of date | Update `infra/schemas/tools/<tool>.json` and redeploy |
| Codex: `OAuth metadata discovery failed ... unexpected HTTP status 500` | A policy failed on Codex's body-less `GET` probe | Redeploy the current policies; the probe check `discovery: GET without token is not 5xx` must pass |
| One `400` on the first authenticated request of a session | The client offered a newer MCP protocol version; the server refused and the client fell back | Nothing to fix |
| Copilot CLI `-p`: *Browser-based OAuth required* or *requires authentication* | Headless mode cannot start a browser sign-in | Sign in once interactively (`/mcp`) |
