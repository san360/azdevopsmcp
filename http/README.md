# Step-by-step HTTP walkthroughs

These `.http` files replay, request by request, what an MCP client does to sign in and call
a tool. Run them top to bottom and read the comment block above each request: **what** it
does, **why** the client does it (spec reference), the **expected** response (sanitized),
and **where** to find it in the logs.

| File | Shows |
|---|---|
| [`01-not-working-native.http`](01-not-working-native.http) | Native APIM MCP pass-through. Sign-in ends at step 5 with `AADSTS9010010`; the MCP calls work with a token from elsewhere |
| [`02-working-proxy.http`](02-working-proxy.http) | The working setup, from the anonymous call to a successful `tools/call`, including the gateway's PRM under `/ado-mcp-proxy/.well-known/...` and its `register`, `authorize` and `token` under `/ado-mcp-proxy/oauth` |
| [`03-app-gateway.http`](03-app-gateway.http) | The working setup behind Application Gateway with APIM internal ([APP-GATEWAY.md](../docs/APP-GATEWAY.md)): the same sign-in on a custom host that APIM also has, then on a host only App Gateway has (challenge rewrite, `X-Forwarded-Host`), and what App Gateway blocks |
| [`04-ai-gateway.http`](04-ai-gateway.http) | Azure AI Gateway: no discovery, a gateway token, and the on-behalf-of exchange ([AI-GATEWAY.md](../docs/AI-GATEWAY.md)) |

## Native vs. working, step by step

The step numbers are the same in files 01 and 02, so you can see exactly where they diverge.

| Step | Native pass-through (01) | Working setup (02) |
|---|---|---|
| 1 Anonymous `initialize` | `401`, `resource_metadata` **rewritten by APIM** to `/ado-mcp-native/.well-known/...` | `401`, the same built-in APIM behaviour: `resource_metadata` points at `/ado-mcp-proxy/.well-known/...`, no `scope` |
| 2 PRM | APIM's built-in metadata: `resource` = gateway URL, `authorization_servers` = **Entra**, scope = Azure DevOps | The API `ado-mcp-proxy-prm` answers instead: `resource` = gateway URL, `authorization_servers` = **the gateway** (`/ado-mcp-proxy/oauth`) |
| 3 Authorization-server metadata | Entra's OpenID configuration, **no** `registration_endpoint` | APIM's metadata: issuer `/ado-mcp-proxy/oauth` with its `authorize`, `token`, `register` |
| 4 Client registration | Nothing to call (Entra has no DCR); needs a pre-set client ID | `POST /ado-mcp-proxy/oauth/register` → `201` with the pre-registered public client |
| 5 Authorize | Entra answers `302` → `error=invalid_target`, **`AADSTS9010010`** | APIM answers `302` to Entra with `resource=https://mcp.dev.azure.com` → sign-in page |
| 6 Token | Not reachable | `POST /ado-mcp-proxy/oauth/token` (APIM translates `resource`) → user token for Azure DevOps MCP |
| 7–10 `initialize`, `notifications/initialized`, `tools/list`, `tools/call` | Work with a token obtained outside MCP | Work with the token from step 6 (or the same shortcut token) |
| 11 Out-of-range `tools/call` (`top: 500`) | Accepted by the server | Accepted by the server too: no gateway validation ([TOOL-VALIDATION.md](../docs/TOOL-VALIDATION.md)) |

## Plain gateway vs. Application Gateway (file 03)

The sign-in is the same; only who makes the URLs right changes. Steps A1–A8 of file 03
follow steps 1–7 and 10 of file 02.

| Step | Plain gateway (02) | `<host>`: custom host on App Gateway and APIM (03, part A) | `<host2>`: custom domain only on App Gateway (03, part B) |
|---|---|---|---|
| Host APIM sees | `<apim-name>.azure-api.net` | `<host>` (App Gateway forwards it) | `<apim-name>.azure-api.net`, public host in `X-Forwarded-Host` |
| `401` `resource_metadata` | built by APIM from the host | built by APIM from the host, already public | built by APIM with the internal host, **rewritten by App Gateway** to `<host2>` |
| PRM, OAuth metadata | from the host | from the host | from `X-Forwarded-Host` (`trustForwardedFor = true`) |
| `register`, `authorize`, `token` | APIM policies | same policies, through App Gateway | same |
| Sign-in page | Entra, directly in the browser | same: App Gateway is not on the Entra path | same |
| Paths reachable | every API on the instance | MCP paths only; others `502` (part C) | same |
| Regular setup (`ado-mcp-native`) | fails at Entra, `AADSTS9010010` | same | fails earlier: its PRM names the internal host (C4) |

## Client registration (DCR) and the Entra app

**Why DCR.** The MCP authorization spec (2025-06-18) says clients SHOULD register
themselves through dynamic client registration ([RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591)):
`POST <registration_endpoint>` with a name and redirect URIs, and they get a `client_id`
back. Claude Code, Codex, MCP Inspector, VS Code and Copilot CLI all do this when the
authorization-server metadata has a `registration_endpoint`. Several stop without one
(*Incompatible auth server: does not support dynamic client registration*, *Dynamic
registration failed: HTTP 404*).

**Why Entra cannot serve it.** Microsoft Entra has no registration endpoint. Apps are
created by an administrator, not by the client at sign-in.

**How the working setup handles it.** The gateway publishes its own
`registration_endpoint` (`/ado-mcp-proxy/oauth/register`). `oauth-register.xml` answers
every client with `201` and the **same pre-registered Entra public client ID** (deployment
parameter `publicClientId`, created by `scripts/setup-entra.ps1`). It echoes the
`redirect_uris` the client sent and issues no secret (`token_endpoint_auth_method: none`;
PKCE protects the code). Nothing is created in Entra. Entra still checks at sign-in that
the client's redirect URI is registered on that app.
Details: [CLIENTS-APIM-CHANGES.md, change 3](../docs/CLIENTS-APIM-CHANGES.md#change-3-a-registration-desk-that-hands-out-one-pre-registered-client)
and [change 8](../docs/CLIENTS-APIM-CHANGES.md#change-8-the-entra-public-client-allows-each-clients-redirect-uri).

**Which app.** Step 4 of file 02 (A4/B4 of file 03) shows it as `client_id`; it equals
`clientId` in your environment file. Check it with:

```powershell
az ad app show --id <public-client-id> --query "{name:displayName, publicClient:isFallbackPublicClient, redirectUris:publicClient.redirectUris}"
```

| Entra object | What it is | Who uses it |
|---|---|---|
| Public client (default name `ado-mcp-apim-client`) | Single-tenant app, *Allow public client flows* on, no secret or certificate, platform *Mobile and desktop* with loopback redirect URIs; delegated permission **Azure DevOps MCP / `Ado.Mcp.Tools`** with admin consent | Handed out by `/register`; the `client_id` (`azp`) of every token obtained through the working setup |
| Azure DevOps MCP enterprise application (app ID `2a72489c-aab2-4b65-b93a-a91edccf33b8`) | Microsoft's resource app; audience of the token (`https://mcp.dev.azure.com`) | Must exist as a service principal in the tenant (`setup-entra.ps1` step 1) |

**Entra changes for Application Gateway.** None to the app's type, permission or consent:
the browser goes to Entra directly, and the gateway replaces `resource` with
`https://mcp.dev.azure.com`, so Entra never sees a gateway host name. Redirect URIs are
loopback addresses on the user's machine, the same for every host. The only per-host
entries are **OpenAI Codex**'s, `http://127.0.0.1/callback/<id>`, where `<id>` is derived
from the exact MCP URL. Add one per new URL:

```powershell
./scripts/setup-entra.ps1 -TenantId <tenant-id> -AppName <existing-app-name> `
  -McpUrl https://<host>/ado-mcp-proxy/<org>, https://<host>/ado-mcp-proxy, https://<host2>/ado-mcp-proxy/<org>, https://<host2>/ado-mcp-proxy
```

Pass `-AppName` with the existing app's display name, otherwise the script creates a new
app. A missing redirect URI shows up only after sign-in, as `AADSTS50011`.

## Set up

1. Install one of:
   - VS Code **REST Client** (`humao.rest-client`). The files use its syntax, including
     response chaining such as `{{prm.response.body.$.authorization_servers[0]}}`.
   - VS Code **httpYac** or the `httpyac` CLI. Request names, file variables, `# @no-redirect`
     and environment files work as is. Chained values use httpyac's own syntax
     (`{{prm.authorization_servers[0]}}`), so replace the `.response.body.$` part when you
     use it. `.httpyac.json` turns off its cookie jar (see below).
   - JetBrains **HTTP Client**: the request format, `###` separators and
     `http-client.env.json` are the same; chaining needs a response handler script.
2. Copy `http-client.env.example.json` to `http-client.env.json` and fill in `gateway`,
   `org`, `tenant` and `clientId` (outputs of the deployment and `setup-entra.ps1`), and
   for file 03 `agwHost` and `agwHost2` (the App Gateway hosts, `https://...`). Put
   tokens in `http-client.private.env.json`. Both files are git-ignored; never commit
   real values.
   REST Client does not read these files: put the same values in `.vscode/settings.json`
   (also git-ignored). Then select the environment `lab`, see
   [Select the environment](#select-the-environment).
3. Tokens (they expire after about an hour):

   ```powershell
   az account get-access-token --scope https://mcp.dev.azure.com/.default --query accessToken -o tsv      # token
   az account get-access-token --scope https://ai.gateway.azure.com/Data.All --query accessToken -o tsv  # aigwToken (04 only)
   ```

4. Run the requests in order (**Send Request** above each one). Later steps read values
   from earlier responses, so run steps 2 to 5 of file 02 before step 6.

With the httpyac CLI, convert the chaining syntax first (a temporary copy; do not commit it):

```powershell
cd http
(Get-Content 02-working-proxy.http -Raw).Replace('.response.body.$.', '.') | Set-Content -Encoding utf8NoBOM 02.httpyac.tmp.http
npx httpyac send 02.httpyac.tmp.http --all --env lab --var "token=$(az account get-access-token --scope https://mcp.dev.azure.com/.default --query accessToken -o tsv)" -o short
Remove-Item 02.httpyac.tmp.http
```

Without the conversion, httpyac stops at step 3 with *Cannot read properties of undefined
(reading 'body')*.

## Select the environment

The files contain no hosts or IDs: `{{gateway}}`, `{{org}}`, `{{clientId}}`, `{{agwHost}}`,
`{{token}}` and the others come from the **environment** you select. Until one is selected
the variables stay unresolved, and the first request fails (the URL still contains
`{{gateway}}`). The example file has one environment, `lab`.

| Tool | Where the values come from | How to select `lab` |
|---|---|---|
| VS Code **REST Client** | `rest-client.environmentVariables` in `.vscode/settings.json` (does **not** read `http-client.env.json`) | `Ctrl+Alt+E`, or **F1 → Rest Client: Switch Environment**, then `lab`. The status bar (bottom right) shows the active environment; *No Environment* means none |
| VS Code **httpYac** | `http-client.env.json` and `http-client.private.env.json` next to the `.http` file (also `httpyac.environmentVariables` in settings) | **F1 → httpYac: Select Environment** (or **Toggle Environment**), or click the environment item in the status bar. To preselect it: `"httpyac.environmentSelectedOnStart": ["lab"]` |
| **httpyac CLI** | the same files | `--env lab`; `--var token=...` overrides one value for that run |
| JetBrains **HTTP Client** | `http-client.env.json` and `http-client.private.env.json` | The **Run with** environment list at the top of the `.http` editor, then `lab` |

REST Client settings (keys as in `http-client.env.example.json`; `$shared` values apply to
every environment):

```json
{
  "rest-client.environmentVariables": {
    "$shared": {},
    "lab": {
      "gateway": "https://<gateway-host>",
      "org": "<organization>",
      "tenant": "<tenant-id>",
      "clientId": "<public-client-id>",
      "agwHost": "https://<host>",
      "agwHost2": "https://<host2>",
      "token": "<az account get-access-token --scope https://mcp.dev.azure.com/.default>"
    }
  }
}
```

**More than one target.** Add an environment per target, with the same keys, and switch
between them instead of editing the files. For example, `agw` with
`"gateway": "https://<host>"` runs file 02 unchanged through Application Gateway (every
path it calls is routed, [APP-GATEWAY.md section 6](../docs/APP-GATEWAY.md#6-routing)).
File 03 needs `agwHost` and `agwHost2` in the selected environment, and App Gateway must
be running.

**Refresh the token.** `token` expires after about an hour. Update it in the file you use
(settings for REST Client, `http-client.private.env.json` for the others), or pass it with
`--var` on the CLI. An expired token gives `401` on the MCP calls even with an environment
selected.

## The manual steps (file 02, steps 5 and 6)

A `.http` file cannot sign a user in. To exchange a real code instead of using the token
shortcut:

1. Send step 5. Copy the `Location` header value (a `login.microsoftonline.com` URL with
   `resource=https%3A%2F%2Fmcp.dev.azure.com`) into a browser.
2. Sign in with an account of the organization's tenant.
3. The browser goes to `http://localhost/?code=...&state=walkthrough-proxy` and shows
   "can't connect". That is expected: nothing listens on localhost. Copy the `code` value
   from the address bar (everything between `code=` and `&state`).
4. Paste it into `@authCode` at the top of the file and send step 6 within about ten
   minutes. A code works only once.
5. Set `@bearer = {{token6.response.body.$.access_token}}` and run steps 7 to 11.

`http://localhost` (any port) is registered on the public client by `setup-entra.ps1`. The
PKCE pair at the top of the files is fixed and documented for the lab only; real clients
create a new random verifier for every sign-in (RFC 7636).

## Reading the responses

- **SSE:** the Azure DevOps server answers MCP requests with `Content-Type:
  text/event-stream`. The tools show the raw text, for example
  `event: message` / `data: {"result":...}`. The JSON-RPC response is the `data:` line.
- **Gateway answers** (for example `404 {"error":"unknown_organization"}`) are plain
  `application/json`. The `401` has no body.
- **Request IDs:** every gateway response has `x-apim-request-id`. Find it with
  `python tools/query_logs.py docs/kql/gateway-by-request-id.kql -g <rg> -w log-<apim-name> --param x-apim-request-id=<id>`,
  and see the policy steps with `policy-traces.kql` and sign-in steps with `client-signins.kql`.
- **Cookies:** the Azure DevOps origin sets a cookie for its own backend host, and the
  gateway passes `Set-Cookie` through. Strict clients (httpyac) reject a cookie for a
  different domain, so `.httpyac.json` disables the cookie jar. MCP does not use cookies.

## Validated

Files 01 and 04 were run against the lab on 2026-11-18 with the httpyac CLI. File 02 was
re-run on the current layout (working setup as an APIM MCP server, OAuth under
`/ado-mcp-proxy/oauth`) on 2026-11-18 with the conversion above: all 11 requests answered as
documented (`401`, `200`, `200`, `201`, `302`, step 6 `400 invalid_grant` with the
placeholder code, then `200`, `202`, `200`, `200`, `200`).

File 03 was run through both App Gateway hosts on 2026-11-19 with the same conversion: all
18 requests answered as documented. Part A: `401`, `200`, `200`, `201`, `302` with
`resource=https%3A%2F%2Fmcp.dev.azure.com`, A6 `400 invalid_grant` (`AADSTS9002313`,
placeholder code), `200`, `200`. Part B: the same on `<host2>`, with the rewritten challenge
and PRM/metadata on `<host2>`. Part C: the forged `X-Forwarded-Host` was ignored, `502`,
`502`, and the native PRM named the internal `<apim-name>.azure-api.net` host.
