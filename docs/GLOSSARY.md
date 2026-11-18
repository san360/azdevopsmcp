# Glossary

Plain-language explanations of the terms used in this repository, each with a link to the
authoritative source.

**Placeholders used in the docs:** `<gateway>` = your APIM gateway host
(`https://<apim-name>.azure-api.net` or a custom domain), `<org>` = Azure DevOps organization,
`<tenant-id>` = Entra tenant, `<public-client-id>` = the app created by `setup-entra.ps1`,
`<rg>` = the resource group that holds APIM, `log-<apim-name>` = the Log Analytics workspace.

### AADSTS9010010

Microsoft Entra error *"The resource parameter provided in the request doesn't match with
the requested scopes."* Entra refuses to issue a token when the
[resource indicator](#resource-indicator) names something other than the API that owns the
requested scope, for example a gateway URL together with the Azure DevOps MCP scope. It is
the reported error and the core of the reproduction.

### AADSTS50011

Entra error *"The redirect URI ... does not match the redirect URIs configured for the
application."* The client's [redirect URI](#redirect-uri) is not registered on the app.
Entra shows it **after** the user has signed in.

### AADSTS900144

Entra error *"The request body must contain the following parameter: 'scope'."* Some client
versions omit `scope`; the gateway's `/authorize` and `/token` add it.

### Access token, audience, `azp`, `oid`

The **access token** is the key the client sends as `Authorization: Bearer <token>`. Its
**audience** (`aud`) is the API it is for; here, Azure DevOps MCP. `azp` (or `appid`) is
the client app that obtained it, and `oid` is the signed-in user's object ID. The gateway
logs `azp` and `oid`, never the token itself.

### API Management (APIM) terms

- **API**: a set of operations under one path (`/ado-mcp-proxy`). An **MCP API** (native
  pass-through) is a special API type that forwards MCP traffic and has no operations.
- **Operation**: one method and URL template inside an API (`POST /{org}`).
- **Backend**: the upstream service (`https://mcp.dev.azure.com`).
- **Policy**: XML that runs per request in four sections: `inbound` (before the backend),
  `backend` (forwarding), `outbound` (on the response) and `on-error`.
  [Policy reference](https://learn.microsoft.com/azure/api-management/api-management-policies).
- **Policy expression**: C# inside `@( … )` (one expression) or `@{ … }` (a block with
  `return`). [Expressions](https://learn.microsoft.com/azure/api-management/api-management-policy-expressions).
- **Policy fragment**: reusable policy XML included with `<include-fragment>`.
- **Schema**: a JSON schema stored in APIM and used by `validate-content`.
- **`<trace>`**: a policy that writes a custom event to Application Insights `traces`.

### Authorization server, authorization-server metadata (RFC 8414)

The **authorization server** issues tokens: Microsoft Entra, or the gateway acting on
Entra's behalf in the working setup. Its **metadata** document
(`/.well-known/oauth-authorization-server`) is its address book: `issuer`,
`authorization_endpoint`, `token_endpoint`, `registration_endpoint`.
[RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414).

### Authorization code flow, PKCE

The browser-based sign-in. The client sends the user to `/authorize`, receives a one-time
**code** at its [redirect URI](#redirect-uri), and swaps it for tokens at `/token`. **PKCE**
(Proof Key for Code Exchange, [RFC 7636](https://datatracker.ietf.org/doc/html/rfc7636))
binds the code to the client that started the flow: a secret `code_verifier`, of which only
a hash (`code_challenge`, method `S256`) is sent at the start. The gateway requires S256.

### DCR

**Dynamic client registration** ([RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591)):
a client calls `POST /register` with its name and redirect URIs and receives a client ID.
It is like a registration desk at the entrance. Microsoft Entra has no such desk. The
working setup's `/register` hands every client the same pre-registered public client ID.

### Entra public client

An app registration with no secret, for apps that run on the user's device (CLIs, desktop
apps). Platform *Mobile and desktop applications*, with *Allow public client flows* on.
`scripts/setup-entra.ps1` creates one and registers each MCP client's redirect URI.

### JSON-RPC

The message format of MCP: `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{…}}`.
Responses carry `result` or `error` (`-32602` = *Invalid params*).
[JSON-RPC 2.0](https://www.jsonrpc.org/specification).

### MCP

The **Model Context Protocol**: how AI assistants discover and call tools on servers.
Lifecycle: `initialize` → `notifications/initialized` → `tools/list` → `tools/call`.
[Specification](https://modelcontextprotocol.io/specification/2025-06-18).

### MCP-Protocol-Version

Request header with the negotiated MCP version (`2025-06-18` for the hosted Azure DevOps
server). Newer clients first offer a newer version and fall back when the server refuses,
which shows up as one `400` in the logs.

### Native pass-through (regular setup)

APIM's built-in MCP API type that "exposes an existing MCP server". It rewrites the server's
OAuth discovery to the gateway, which leads to [AADSTS9010010](#aadsts9010010).
[Expose an existing MCP server](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server).

### PRM

**Protected-resource metadata** ([RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)):
a small JSON document that describes an API, like the sign on a door. It names the API
(`resource`), the scopes, and which [authorization server](#authorization-server-authorization-server-metadata-rfc-8414)
issues its tokens. Clients find it through the `401` header `WWW-Authenticate:
Bearer resource_metadata="…"` or at `/.well-known/oauth-protected-resource/<path>`. Many
clients require `resource` to equal the URL they connected to.

### Redirect URI

Where Entra sends the browser back after sign-in, usually a tiny web server the client runs
on your machine (`http://127.0.0.1:<port>/…` or `http://localhost:<port>/…`). It must be
registered on the app. Microsoft documents that Entra ignores the port for `localhost`; in the
lab it also ignored it for `127.0.0.1`. The path must match exactly. [Redirect URI rules](https://learn.microsoft.com/entra/identity-platform/reply-url).

### Resource indicator

The `resource` parameter ([RFC 8707](https://datatracker.ietf.org/doc/html/rfc8707)) on
`/authorize` and `/token`: "this token is for API X". MCP clients send the PRM `resource`,
which is the gateway URL. Entra accepts only identifiers of the API that owns the scope
(`https://mcp.dev.azure.com`), so the gateway replaces it. It is like correcting the
addressee on a parcel at the reception desk.

### Scope

What the token may do, for example `https://mcp.dev.azure.com/.default` (all delegated
permissions granted to the client for Azure DevOps MCP, here `Ado.Mcp.Tools`).

### SSE, Streamable HTTP

The MCP transport used here: every message is an HTTP `POST` to one URL, and the server
answers with JSON or a **Server-Sent Events** stream (`text/event-stream`). A gateway must
not buffer or read that stream.
[Transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).

### Origin

The hosted Azure DevOps MCP server itself (`https://mcp.dev.azure.com/<org>`), without the
gateway. The probe tests it for comparison.

### Probe results: PASS, FAIL, XFAIL, INFO

`tools/mcp_probe.py` prints `PASS`/`FAIL` per check, `XFAIL` for a failure listed as expected
for that target (the reproduction), and `INFO` for observations that are not pass/fail.

### Regular setup

The [native pass-through](#native-pass-through-regular-setup) API at `/ado-mcp-native/<org>`,
kept unchanged to reproduce the reported problem.

### Service principal (enterprise application), admin consent

The tenant's local instance of an app. The *Azure DevOps MCP* app needs one in your tenant,
or the server fails with HTTP 500. **Admin consent** grants the public client's permission
(`Ado.Mcp.Tools`) for every user at once.

### x-apim-request-id, CorrelationId

Every gateway response carries `x-apim-request-id`; Log Analytics stores it as
`CorrelationId`. Use it to find one request in the logs.

### X-MCP-Readonly, X-MCP-Toolsets, X-MCP-Tools

Request headers the hosted Azure DevOps MCP server honours to restrict which tools it lists
and runs. The gateway sets them, so users cannot remove them.

### Working setup

This repository's fix: an APIM HTTP API proxy plus OAuth compatibility endpoints, so
clients sign in through the gateway with their own identity. See
[CLIENTS-APIM-CHANGES.md](CLIENTS-APIM-CHANGES.md) and [POLICIES.md](POLICIES.md).
