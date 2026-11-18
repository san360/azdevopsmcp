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
   authorization-server metadata, calls its `register` endpoint when offered, then sends the
   authorization request with `resource` + `scope` (RFC 8707). It follows one gateway
   redirect to Entra and reports any `AADSTS` code. No one signs in. For the multi-tenant
   `organizations` authority it evaluates with the configured tenant, because Entra checks
   resource/scope only once it knows the user's tenant. When the authorization server is
   on the gateway host, it also checks **isolation**: issuer, `authorize`, `token` and
   `register` must all be under the MCP URL's first path segment (`/ado-mcp-proxy/...`), so
   the working setup never claims routes at the gateway root. For every target it also
   checks that the challenge URL, PRM `resource`, authorization servers and OAuth endpoints
   are on the **host the client connected to** (or Entra): behind a reverse proxy a backend
   host such as `*.azure-api.net` there means the proxy did not preserve `Host`
   ([APP-GATEWAY.md](APP-GATEWAY.md#why-the-host-name-matters)).
3. **mcp**: with a token, `initialize` → `notifications/initialized` → `tools/list` → `tools/call core_list_projects`.
4. **validation**: with a token, every `validationCases` entry against targets marked
   `toolValidation`. No target enforces validation any more, so the invalid cases print
   `INFO` with what the server answered (see section 5).

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

Prefer clicking through? The [`http/`](../http/README.md) folder has the same flow as
`.http` files for VS Code REST Client, one request per step with explanations, for the
native and the working setup side by side.


```powershell
$gw  = 'https://<gateway>'
$init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
$h = @{ Accept = 'application/json, text/event-stream' }

# a) the 401 challenge: both MCP servers point at /<api>/.well-known/oauth-protected-resource/<org> (APIM built in, no scope)
foreach ($api in 'ado-mcp-native','ado-mcp-proxy') {
  Invoke-WebRequest "$gw/$api/<org>" -Method Post -Body $init -ContentType application/json -Headers $h -SkipHttpErrorCheck |
    Select-Object StatusCode, @{n='WWW-Authenticate';e={$_.Headers['WWW-Authenticate']}} }

# b) the PRM each setup returns at that URL
Invoke-RestMethod "$gw/ado-mcp-native/.well-known/oauth-protected-resource/<org>" | ConvertTo-Json               # APIM built in: resource = gateway URL, AS = Entra
Invoke-RestMethod "$gw/ado-mcp-proxy/.well-known/oauth-protected-resource/<org>" | ConvertTo-Json                # API ado-mcp-proxy-prm: resource = gateway URL, AS = {gw}/ado-mcp-proxy/oauth
Invoke-RestMethod "$gw/ado-mcp-proxy/oauth/.well-known/openid-configuration" | ConvertTo-Json                    # APIM authorization-server metadata
Invoke-RestMethod "$gw/.well-known/oauth-authorization-server/ado-mcp-proxy/oauth" | ConvertTo-Json              # same, path-inserted alias

# b2) isolation: nothing of the working setup at the gateway root
foreach ($p in '/authorize','/token','/register','/.well-known/oauth-authorization-server','/.well-known/openid-configuration') {
  "{0} {1}" -f (Invoke-WebRequest "$gw$p" -SkipHttpErrorCheck).StatusCode, $p }                                  # all 404

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
| [VS Code](clients/vscode.md) | ✅ | ⚠️ built-in Microsoft account sign-in if the device has a session for the tenant; else ❌ `AADSTS9010010` |
| [GitHub Copilot CLI](clients/copilot-cli.md) | ✅ | ⚠️ Entra account broker; `-p` only if the broker can sign in silently |
| [OpenAI Codex CLI](clients/codex.md) | ✅ | ❌ *Dynamic registration failed: HTTP 404* (no metadata; root `/register` does not exist) |
| [Claude Code](clients/claude-code.md) | ✅ | ❌ no DCR, or `AADSTS9010010` with `--client-id` |
| [MCP Inspector](clients/mcp-inspector.md) | ✅ | ❌ no DCR, or `AADSTS9010010` with a client ID |

### Per-CLI test checklist

Each row is self-contained and writes nothing to your normal profile. Replace `<url>` with
`https://<gateway>/ado-mcp-proxy/<org>`. Full guides with expected output: [docs/clients](clients/README.md).

| CLI | 1. Configure (scratch) | 2. Sign in | 3. Test | Pass when |
|---|---|---|---|---|
| GitHub Copilot CLI | `{"mcpServers":{"ado_proxy":{"type":"http","url":"<url>","tools":["*"]}}}` in `%TEMP%\ado-mcp\copilot-mcp.json` | `copilot --additional-mcp-config "@%TEMP%\ado-mcp\copilot-mcp.json"` → `/mcp` → `ado_proxy` → sign in | `copilot --additional-mcp-config "@..." --disable-builtin-mcps -p "<prompt>" --allow-tool ado_proxy` | `core_list_projects` called, project names listed |
| OpenAI Codex CLI | `$env:CODEX_HOME="$env:TEMP\ado-mcp\codex-home"; codex mcp add ado_proxy --url <url>` | `codex mcp login ado_proxy` (`--no-browser` prints the URL) | `codex mcp list` → `Auth: OAuth`; with a model: `codex exec "<prompt>"` | `Successfully logged in`, authorize URL starts with `<gateway>/ado-mcp-proxy/oauth/authorize` |
| Claude Code | In a scratch folder: `claude mcp add --transport http -s local ado-proxy <url>` | `claude mcp login ado-proxy` (`--no-browser` prints the URL) | `claude mcp list` | `ado-proxy: ... √ Connected` |
| VS Code | **MCP: Open User Configuration** → `"ado-apim-proxy": {"type":"http","url":"<url>"}` | **MCP: List Servers** → start → sign in | Agent mode: *"List the Azure DevOps projects I can access."* | Projects listed |
| MCP Inspector | `npx @modelcontextprotocol/inspector` → Streamable HTTP, `<url>` | **Connect** | **Tools → List Tools → core_list_projects** | Tool result shown |

`<prompt>`: *"Use only the ado_proxy MCP server. Call core_list_projects with no arguments and
print the project names."* Earlier versions of this checklist also asked for `top` set to 500
and expected the gateway's validation error. That error is no longer expected: the gateway
does not validate tool arguments, and the server accepts `top: 500`
([TOOL-VALIDATION.md](TOOL-VALIDATION.md)). For each client, `client-signins.kql` should then show `prm`, `as-metadata`,
`register`, `authorize`, `token` and `proxy-inbound` rows, and every OAuth request path under
`/ado-mcp-proxy/oauth` or a `/.well-known/.../ado-mcp-proxy` alias.

Re-testing after a gateway change: sign out first (`claude mcp logout`, `codex mcp logout`,
VS Code **Accounts: Sign Out**), because clients cache the authorization server they
discovered. VS Code's Copilot agent host also loads Copilot CLI's
`~/.copilot/mcp-config.json`; name test servers distinctly per client so you know which
definition you are testing.

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
python tools/query_logs.py docs/kql/client-signins.kql @la --param client=codex     # one client's sign-in steps (User-Agent filter)
```

Or paste the `.kql` files into **Application Insights → Logs** or **Log Analytics → Logs**.
In App Insights, `OperationId` equals the probe's trace ID for the probe's MCP calls (its discovery and OAuth requests are separate operations). Gateway calls are under **requests** (not traces). The **traces** table holds the `<trace>` policy events. Real MCP clients send no `traceparent`, so each of their calls is its own operation; [`session-timeline.kql`](kql/session-timeline.kql) puts one client's session back into one timeline. See [OBSERVABILITY.md](OBSERVABILITY.md).

## 5. Tool argument validation (not deployed)

Neither setup validates tool arguments at the gateway; see
[TOOL-VALIDATION.md](TOOL-VALIDATION.md) for the reason and for how to add validation. The
probe still runs `validationCases` against the targets marked `"toolValidation": "none"`
(both setups in `probe.example.json`) and records what the server does with each case:

```text
PASS   apim-proxy   validation: core_list_projects valid: server result: [...]
INFO   apim-proxy   validation: core_list_projects top out of range: not validated at the gateway; server answered server result: [...]
```

`INFO` lines never fail the run. Run them with:

```powershell
python tools/mcp_probe.py --config tools/probe.local.json --token az --only apim-proxy --only apim-native
```

## 6. Behind Application Gateway

With the optional edge ([APP-GATEWAY.md](APP-GATEWAY.md)), add targets for the public host
to `tools/probe.local.json`, for example `agw-proxy` (`https://<host>/ado-mcp-proxy/<org>`),
`agw-proxy-bare` (`https://<host>/ado-mcp-proxy`) and `agw-native`
(`https://<host>/ado-mcp-native/<org>`, `expectFailures` like `apim-native`). For a second
host with the custom domain only on App Gateway
([APP-GATEWAY.md, section 9](APP-GATEWAY.md#9-second-host-custom-domain-only-on-application-gateway))
add the same three for `<host2>` (`agw2-proxy`, `agw2-proxy-bare`, `agw2-native`); the
regular setup there fails at discovery, so give `agw2-native`
`"expectFailures": ["discovery: URLs on the client's host", "client: PRM accepted", "client: authorization server metadata"]`.
Then:

```powershell
python tools/mcp_probe.py --config tools/probe.local.json --token az --only agw-proxy --only agw-proxy-bare --only agw-native --only agw2-proxy --only agw2-proxy-bare --only agw2-native --skip-validation
```

Expected: the same results as on the plain gateway, and *discovery: URLs on the client's
host* passes for every target except `agw2-native`. App Gateway's own view of each request:
[`docs/kql/appgw-access.kql`](kql/appgw-access.kql). The routing, streaming, timeout and
rate-limit tests and their results are in
[APP-GATEWAY.md, section 13](APP-GATEWAY.md#13-test-results).

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
| An MCP server returns 500 for every request after adding `validate-content` | `validate-content` needs API operations; MCP servers have none | Remove it; see [TOOL-VALIDATION.md](TOOL-VALIDATION.md) for options |
| Codex: `OAuth metadata discovery failed ... unexpected HTTP status 500` | A policy failed on Codex's body-less `GET` probe (seen with an earlier HTTP-proxy version) | Deploy the current version; the probe check `discovery: GET without token is not 5xx` must pass (the MCP server answers `405`) |
| Deployment fails on API `ado-mcp-proxy` after upgrading from a version with an HTTP proxy | An API's type cannot change from HTTP to MCP | Delete the old API first ([GETTING-STARTED](GETTING-STARTED.md#upgrading-from-an-earlier-version)) |
| Sign-in through the working setup ends with `AADSTS9010010` or *does not support dynamic client registration* | The MCP server's built-in metadata answered the PRM URL: the API `ado-mcp-proxy-prm` is missing | Redeploy; `GET /ado-mcp-proxy/.well-known/oauth-protected-resource/<org>` must name `/ado-mcp-proxy/oauth` as authorization server |
| One `400` on the first authenticated request of a session | The client offered a newer MCP protocol version; the server refused and the client fell back | Nothing to fix |
| Copilot CLI `-p`: *Browser-based OAuth required* or *requires authentication* | Headless mode cannot show a sign-in. On the native URL the account broker signs in silently only for a tenant the device is joined to | Sign in once interactively (`/mcp`); for the working setup the token is then reused headless |
| Browser opens `https://<gateway>/authorize` and gets `404` | The client cached the authorization server of an older, root-mounted lab version (seen with Claude Code) | Sign out of the server (`claude mcp logout <name>`, `codex mcp logout <name>`) and sign in again |
| *Dynamic registration failed: HTTP 404* or *Dynamic Client Registration rejected (HTTP 404)* on the proxy | The discovery aliases are missing (`rootDiscoveryAliases = false`, or deleted); Codex and Claude Code then fall back to the gateway root | Redeploy with `rootDiscoveryAliases = true` |
| Probe: `client: OAuth endpoints under the MCP path (isolation)` fails | The PRM or authorization-server metadata names an issuer or endpoint outside the setup's path (an old policy version is deployed) | Redeploy the current version. To detect leftover root APIs (which this check cannot see), run the root-`404` loop in [GETTING-STARTED](GETTING-STARTED.md#upgrading-from-an-earlier-version) |
