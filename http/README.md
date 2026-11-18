# Step-by-step HTTP walkthroughs

These `.http` files replay, request by request, what an MCP client does to sign in and call
a tool. Run them top to bottom and read the comment block above each request: **what** it
does, **why** the client does it (spec reference), the **expected** response (sanitized),
and **where** to find it in the logs.

| File | Shows |
|---|---|
| [`01-not-working-native.http`](01-not-working-native.http) | Native APIM MCP pass-through. Sign-in ends at step 5 with `AADSTS9010010`; the MCP calls work with a token from elsewhere |
| [`02-working-proxy.http`](02-working-proxy.http) | The working setup, from the anonymous call to a successful `tools/call`, including the gateway's `/register`, `/authorize` and `/token` |
| [`03-tool-validation.http`](03-tool-validation.http) | A valid call, then calls the gateway rejects with JSON-RPC `-32602` |
| [`04-ai-gateway.http`](04-ai-gateway.http) | Azure AI Gateway: no discovery, a gateway token, and the on-behalf-of exchange ([AI-GATEWAY.md](../docs/AI-GATEWAY.md)) |

## Native vs. working, step by step

The step numbers are the same in files 01 and 02, so you can see exactly where they diverge.

| Step | Native pass-through (01) | Working setup (02) |
|---|---|---|
| 1 Anonymous `initialize` | `401`, `resource_metadata` **rewritten by APIM** to `/ado-mcp-native/.well-known/...` | `401`, `resource_metadata` points at **APIM-hosted** PRM, plus `scope=` |
| 2 PRM | `resource` = gateway URL, `authorization_servers` = **Entra**, scope = Azure DevOps | `resource` = gateway URL, `authorization_servers` = **the gateway** |
| 3 Authorization-server metadata | Entra's OpenID configuration, **no** `registration_endpoint` | APIM's metadata: `/authorize`, `/token`, `/register` |
| 4 Client registration | Nothing to call (Entra has no DCR); needs a pre-set client ID | `POST /register` → `201` with the pre-registered public client |
| 5 Authorize | Entra answers `302` → `error=invalid_target`, **`AADSTS9010010`** | APIM answers `302` to Entra with `resource=https://mcp.dev.azure.com` → sign-in page |
| 6 Token | Not reachable | `POST /token` (APIM translates `resource`) → user token for Azure DevOps MCP |
| 7–10 `initialize`, `notifications/initialized`, `tools/list`, `tools/call` | Work with a token obtained outside MCP | Work with the token from step 6 (or the same shortcut token) |
| 11 Invalid `tools/call` (`top: 500`) | Accepted by the server | Rejected by the gateway: `-32602`, `x-mcp-gateway-validation: rejected` |

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
   `org`, `tenant` and `clientId` (outputs of the deployment and `setup-entra.ps1`). Put
   tokens in `http-client.private.env.json`. Both files are git-ignored; never commit
   real values.
   For REST Client, put the same values under `rest-client.environmentVariables.lab` in
   `.vscode/settings.json` (also git-ignored), and select the environment `lab`
   (**Rest Client: Switch Environment**).
3. Tokens (they expire after about an hour):

   ```powershell
   az account get-access-token --scope https://mcp.dev.azure.com/.default --query accessToken -o tsv      # token
   az account get-access-token --scope https://ai.gateway.azure.com/Data.All --query accessToken -o tsv  # aigwToken (04 only)
   ```

4. Run the requests in order (**Send Request** above each one). Later steps read values
   from earlier responses, so run steps 2 to 5 of file 02 before step 6.

With the httpyac CLI:

```powershell
cd http
npx httpyac send 01-not-working-native.http --all --env lab -o short
```

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
- **Gateway answers** (rejections, `401`, `404`) are plain `application/json`.
- **Request IDs:** every gateway response has `x-apim-request-id`. Find it with
  `python tools/query_logs.py docs/kql/gateway-by-request-id.kql -g <rg> -w log-<apim-name> --param x-apim-request-id=<id>`,
  and see the policy steps with `policy-traces.kql`, sign-in steps with `client-signins.kql`,
  validation decisions with `tool-validation.kql`.
- **Cookies:** the Azure DevOps origin sets a cookie for its own backend host, and the
  gateway passes `Set-Cookie` through. Strict clients (httpyac) reject a cookie for a
  different domain, so `.httpyac.json` disables the cookie jar. MCP does not use cookies.

## Validated

All four files were run against the lab on 2026-11-18 with the httpyac CLI. Steps 1–11
behave as documented on both setups. Step 6 of file 02 needs a real code (manual); with the
placeholder it returns `400 invalid_grant` (`AADSTS9002313`) as documented.
