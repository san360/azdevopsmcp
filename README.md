# Azure DevOps MCP server behind Azure API Management

## What this repository solves

**Audience:** platform and security teams who want AI assistants (GitHub Copilot in
VS Code, GitHub Copilot CLI, OpenAI Codex CLI, Claude Code, MCP Inspector and similar MCP
clients) to use the **hosted Azure DevOps MCP server** through their **central API gateway**.

**Why a gateway.** Organizations put Azure API Management (often branded as their *AI
gateway*) in front of every AI tool endpoint. That gives one governed entry point with
rate limits, tool restrictions (read-only, toolsets), header hygiene, IP/network control,
central logging in Application Insights / Log Analytics, and a stable URL they can
allow-list. **APIM's role here is that governance layer. It is not an identity provider
and must not replace the user's identity.** Azure DevOps must keep authorizing and
auditing every call as the signed-in user.

**The problem.** APIM's built-in *MCP pass-through* rewrites the server's OAuth
discovery metadata so that it points at the gateway. Microsoft Entra then refuses to sign
the user in (`AADSTS9010010`). The MCP traffic itself would work, but clients never get a
token. Support confirmed this is by design. The usual workaround, APIM Credential Manager,
replaces the user's identity with a shared one.

**What this repository gives you:**

1. A **reproduction** of the failure (regular setup), with raw responses, telemetry and a
   root-cause analysis.
2. A **working setup** that uses the same APIM MCP server feature, plus a few plain APIs
   under its own path. They answer OAuth discovery and translate one parameter (`resource`)
   on the way to Entra. The user's own Azure DevOps token flows through unchanged, for any
   number of organizations.
3. **Tooling** to prove it: Bicep, an end-to-end probe, KQL queries, and step-by-step tests
   with VS Code, GitHub Copilot CLI, OpenAI Codex CLI, Claude Code, MCP Inspector and curl.

## At a glance

A reproducible lab that puts the **hosted Azure DevOps MCP server**
(`https://mcp.dev.azure.com/<org>`) behind **Azure API Management (APIM)** in two ways,
side by side, with full telemetry:

| | Regular setup | Working setup |
|---|---|---|
| APIM feature | MCP server, native pass-through ("expose an existing MCP server") | The same MCP server feature + plain HTTP APIs for PRM and OAuth compatibility |
| Listed in APIM under *MCP servers* | ✅ `ado-mcp-native` | ✅ `ado-mcp-proxy` |
| Client URL | `https://<gateway>/ado-mcp-native/<org>` | `https://<gateway>/ado-mcp-proxy/<org>` |
| `initialize`, `tools/list`, `tools/call` with a valid token | ✅ | ✅ |
| Sign-in from VS Code / MCP Inspector / Claude Code | ❌ `AADSTS9010010` or no DCR | ✅ |
| Sign-in from GitHub Copilot CLI / OpenAI Codex CLI | ⚠️ see [Client compatibility](#client-compatibility) | ✅ |
| Who Azure DevOps sees | The signed-in user | The signed-in user |

The working setup builds on [carolga/ado-apim](https://github.com/carolga/ado-apim)
(see [Credits](#credits)). Both setups send telemetry to Application Insights and Log
Analytics, ship ready-made KQL, and come with an end-to-end probe that tests the origin and
the gateway the same way.

### Documentation: a learning path

| Step | Read | You learn |
|---|---|---|
| 1 | This README | What the problem is, why a gateway, how both setups work (10 minutes) |
| 2 | [Getting started](docs/GETTING-STARTED.md) | Deploy the lab step by step, with expected output |
| 3 | [Testing](docs/TESTING.md) | Probe, raw protocol with curl/PowerShell, logs, client checklist |
| 3a | [Step-by-step `.http` walkthroughs](http/README.md) | Every request of the sign-in and MCP flow, native vs. working, side by side |
| 4 | [Client guides](docs/clients/README.md) | VS Code, GitHub Copilot CLI, OpenAI Codex CLI, Claude Code, MCP Inspector |
| 5 | [What APIM changes for clients](docs/CLIENTS-APIM-CHANGES.md) | Each gateway change: client behaviour, the error without it, before/after, how to verify |
| 6 | [Policies](docs/POLICIES.md) | Every APIM policy, element by element |
| 7 | [Analysis](docs/ANALYSIS.md) | Root cause, reference implementation, options, sources |
| 8 | [Azure AI Gateway](docs/AI-GATEWAY.md) | Does the new AI Gateway (GA 2026-11-17) solve this natively? Requirement matrix and live test |
| — | [Glossary](docs/GLOSSARY.md) · [Observability](docs/OBSERVABILITY.md) · [Tool argument validation (optional)](docs/TOOL-VALIDATION.md) | Reference |

## How a remote MCP server connection works

The hosted Azure DevOps MCP server is a **remote MCP server** using the
[Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http):

- **One endpoint.** The client sends every JSON-RPC message as an HTTP `POST` to one URL
  (`https://mcp.dev.azure.com/<org>`). The server answers with JSON or, as here, a
  Server-Sent Events (SSE) stream (`Content-Type: text/event-stream`, `event: message` /
  `data: {…}`). A gateway must never buffer or read that stream.
- **Lifecycle.** `initialize` negotiates the protocol version (`2025-06-18`) and
  capabilities. Then the client sends the `notifications/initialized` notification
  (answered with `202`), discovers tools with `tools/list`, and invokes them with
  `tools/call`. Servers may issue an `Mcp-Session-Id`; the Azure DevOps server does not, so
  it is stateless.
- **Authorization**
  ([MCP authorization](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)).
  The server is an OAuth 2.1 *protected resource* and Entra is the *authorization server*.
  A client without a token gets `401` plus a `WWW-Authenticate` header pointing to the
  **protected-resource metadata** (PRM, [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)).
  The PRM names the resource, its scopes and its authorization servers. The client then:
  1. reads the authorization server's metadata ([RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414));
  2. obtains a client ID (pre-registered, built in, or [dynamic registration](https://datatracker.ietf.org/doc/html/rfc7591));
  3. runs the authorization-code flow with PKCE in a browser, sending the PRM `resource` as
     the [RFC 8707](https://datatracker.ietf.org/doc/html/rfc8707) `resource` parameter
     together with the scopes;
  4. exchanges the code for an access token and sends `Authorization: Bearer <token>` on
     every MCP request.
- **What Azure DevOps expects.** A delegated Entra token for the *Azure DevOps MCP* app
  (`2a72489c-aab2-4b65-b93a-a91edccf33b8`, scope `https://mcp.dev.azure.com/.default` →
  `Ado.Mcp.Tools`). Azure DevOps then calls its REST APIs **as that user**. Entra accepts as
  `resource` only that app's identifier URIs: `https://mcp.dev.azure.com`,
  `https://mcp.dev.azure.com/`, `api://2a72489c-…` and the app ID.

A gateway in the middle must therefore get two things right. **Discovery** must lead the
client to a consistent resource/scope pair that Entra accepts. The **data plane** must
forward the user's token and stream responses untouched.

## The problem

With **native MCP pass-through**, APIM rewrites the origin's `resource_metadata` URL **and**
the PRM `resource` to the gateway URL. This is by design and cannot be changed by policy.
It leaves `scopes_supported` pointing to Azure DevOps. VS Code requires `resource` to equal
the URL it connected to, and has forwarded it to Entra since May 2026
([microsoft/vscode#314784](https://github.com/microsoft/vscode/pull/314784)). Entra then
receives a gateway URL as the resource but an Azure DevOps scope, and rejects the request
before anyone can sign in.

### Raw responses (lab, 2026-11-17; host, organization and tenant replaced by placeholders)

**1. Unauthenticated `initialize`. The origin's challenge, then the one APIM returns:**

```http
POST https://mcp.dev.azure.com/<org>
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.dev.azure.com/.well-known/oauth-protected-resource/<org>"
Content-Length: 0
```

```http
POST https://<gateway>/ado-mcp-native/<org>
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://<gateway>/ado-mcp-native/.well-known/oauth-protected-resource/<org>"
Content-Length: 0
x-apim-request-id: <request-id>
```

**2. Protected-resource metadata. Origin, then the version rewritten by APIM. `resource` changed, `scopes_supported` did not:**

```json
GET https://mcp.dev.azure.com/.well-known/oauth-protected-resource/<org>
{
  "resource": "https://mcp.dev.azure.com/<org>",
  "authorization_servers": [ "https://login.microsoftonline.com/<tenant-id>/v2.0" ],
  "bearer_methods_supported": [ "header" ],
  "scopes_supported": [ "https://mcp.dev.azure.com/.default" ]
}
```

```json
GET https://<gateway>/ado-mcp-native/.well-known/oauth-protected-resource/<org>
{
  "resource": "https://<gateway>/ado-mcp-native/<org>",
  "authorization_servers": [ "https://login.microsoftonline.com/<tenant-id>/v2.0" ],
  "bearer_methods_supported": [ "header" ],
  "scopes_supported": [ "https://mcp.dev.azure.com/.default" ]
}
```

**3. The authorization request a client builds from that PRM. Entra rejects it immediately:**

```http
GET https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize?client_id=<public-client-id>
    &response_type=code&redirect_uri=http://127.0.0.1:33418/&code_challenge=…&code_challenge_method=S256&state=demo
    &scope=https://mcp.dev.azure.com/.default
    &resource=https://<gateway>/ado-mcp-native/<org>
HTTP/1.1 302 Found
Location: http://127.0.0.1:33418/?error=invalid_target&error_description=AADSTS9010010: The resource parameter
  provided in the request doesn't match with the requested scopes. Trace ID: <trace-id> Correlation ID: <correlation-id>
  Timestamp: 2026-11-17 18:40:16Z&state=demo
```

**4. The data plane is fine.** With a pre-acquired delegated token, the same native API works and Azure DevOps answers as the user:

```http
POST https://<gateway>/ado-mcp-native/<org>        Authorization: Bearer <token>
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message
data: {"result":{"protocolVersion":"2025-06-18","capabilities":{"logging":{},"tools":{}},"serverInfo":{"name":"AzureDevOps.Mcp","version":"1.0.0.0"}},"id":1,"jsonrpc":"2.0"}
```

```http
POST https://<gateway>/ado-mcp-native/<org>        {"method":"tools/call","params":{"name":"core_list_projects","arguments":{"top":5}}}
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message
data: {"result":{"content":[{"type":"text","text":"[{\"id\":\"<project-id>\",\"name\":\"<project>\",\"url\":\"https://dev.azure.com/<org>/_apis/projects/<project-id>\",\"state\":\"WellFormed\",\"visibility\":\"Private\",…}]"}]},"id":3,"jsonrpc":"2.0"}
```

**5. The working setup.** It is the same kind of APIM MCP server, so APIM returns the same
kind of challenge. The difference: a plain API of the working setup answers the PRM URL
that the challenge names, and that PRM names the gateway's OAuth facade (under the setup's
own path) as authorization server. The facade's `/authorize` then sends Entra a `resource`
that matches the scope:

```http
POST https://<gateway>/ado-mcp-proxy/<org>
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://<gateway>/ado-mcp-proxy/.well-known/oauth-protected-resource/<org>"
```

```json
GET https://<gateway>/ado-mcp-proxy/.well-known/oauth-protected-resource/<org>
{
  "resource": "https://<gateway>/ado-mcp-proxy/<org>",
  "authorization_servers": [ "https://<gateway>/ado-mcp-proxy/oauth" ],
  "bearer_methods_supported": [ "header" ],
  "scopes_supported": [ "https://mcp.dev.azure.com/.default" ],
  "resource_name": "Azure DevOps MCP via API Management"
}
```

```http
GET https://<gateway>/ado-mcp-proxy/oauth/authorize?client_id=<public-client-id>&…&resource=https://<gateway>/ado-mcp-proxy/<org>
HTTP/1.1 302 Found
Location: https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize?client_id=<public-client-id>&response_type=code
  &redirect_uri=http://127.0.0.1:33418/&scope=https://mcp.dev.azure.com/.default&code_challenge=…&code_challenge_method=S256
  &state=demo&resource=https://mcp.dev.azure.com
```

Entra then serves the normal sign-in page, and the user's token works through the working
setup's MCP server exactly as in step 4. Reproduce all of this with `tools/mcp_probe.py` or the curl/PowerShell
snippets in [docs/TESTING.md](docs/TESTING.md#2-curl--powershell-raw-protocol).

## Diagram 1: how an MCP client connects, and where native pass-through breaks

High-resolution exports: [SVG](docs/diagrams/01-mcp-connect-native-pass-through.svg) · [PNG](docs/diagrams/01-mcp-connect-native-pass-through.png) · [Mermaid source](docs/diagrams/01-mcp-connect-native-pass-through.mmd)

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant C as MCP client<br/>(VS Code, Inspector)
    participant G as APIM native MCP<br/>/ado-mcp-native/{org}
    participant O as Azure DevOps MCP<br/>mcp.dev.azure.com/{org}
    participant E as Microsoft Entra ID

    rect rgb(235, 242, 255)
    Note over C,O: Phase A: discovery (no token)
    C->>G: POST initialize (no Authorization)
    G->>O: POST /{org}
    O-->>G: 401 WWW-Authenticate: resource_metadata=".../oauth-protected-resource/{org}"
    G-->>C: 401 with resource_metadata rewritten to {gateway}/ado-mcp-native/.well-known/...
    C->>G: GET protected-resource metadata
    G->>O: GET /.well-known/oauth-protected-resource/{org}
    O-->>G: resource=https://mcp.dev.azure.com/{org}, scopes=https://mcp.dev.azure.com/.default
    G-->>C: resource REWRITTEN to {gateway}/ado-mcp-native/{org}, scopes unchanged
    C->>C: check resource == server URL (passes)
    C->>E: GET OpenID / OAuth metadata of the tenant
    end

    rect rgb(255, 236, 236)
    Note over U,E: Phase B: authorization code + PKCE with RFC 8707 resource
    C->>U: open browser
    U->>E: /authorize?client_id, scope=https://mcp.dev.azure.com/.default,<br/>resource={gateway}/ado-mcp-native/{org}, code_challenge
    E-->>U: AADSTS9010010 invalid_target (resource does not match scope)
    Note over C,E: Sign-in stops here. No token is issued.
    end

    rect rgb(235, 250, 235)
    Note over C,O: Phase C: MCP session (verified with a pre-acquired token)
    C->>G: POST initialize, Authorization: Bearer (aud = Azure DevOps MCP)
    G->>O: forwarded with the same token
    O-->>C: 200 SSE: protocolVersion, capabilities, serverInfo
    C->>G: notifications/initialized, tools/list, tools/call
    G->>O: forwarded
    O-->>C: 202 / tool list / tool result, Azure DevOps acts as the user
    end
```

| Step | What happens | Why it matters |
|---|---|---|
| 1–2 | The client opens the MCP session with `initialize`, without a token. APIM forwards it to the origin. | Clients discover authorization only when the server says it is needed. |
| 3 | Azure DevOps answers `401` with `WWW-Authenticate: Bearer resource_metadata=…`. | This is the MCP-standard pointer to the PRM document. |
| 4 | **APIM rewrites** that URL to its own host (native pass-through feature). | The client will now read metadata through APIM. |
| 5–7 | The client fetches the PRM; APIM proxies it from the origin. | The PRM names `resource`, `scopes_supported` and `authorization_servers`. |
| 8 | **APIM rewrites `resource`** to the gateway URL and leaves the scope as Azure DevOps. | The source of the inconsistency. Not configurable. |
| 9 | The client checks that `resource` equals the URL it used (RFC 9728 §3.3). | Passes because APIM rewrote it. With the origin's value the client would reject the PRM. |
| 10 | The client reads Entra's tenant metadata (authorize/token endpoints). | Entra is the authorization server named in the PRM. |
| 11–12 | The browser goes to Entra `/authorize` with `scope` (Azure DevOps) and `resource` (gateway). | RFC 8707: the client binds the token to the resource from the PRM. |
| 13 | **Entra rejects** with `AADSTS9010010`: the resource is not an identifier of the app that owns the scope. | Sign-in fails before the user can authenticate. |
| 14–16 | With a token obtained elsewhere, `initialize` succeeds. APIM forwards the token, and the origin replies over SSE. | Proves the data plane and user identity survive native pass-through. |
| 17–19 | `notifications/initialized` (202), `tools/list`, `tools/call` all succeed. | Only discovery and sign-in are broken, not MCP traffic. |

## Diagram 2: the working setup, and what each APIM policy changes

High-resolution exports: [SVG](docs/diagrams/02-working-setup-apim-policies.svg) · [PNG](docs/diagrams/02-working-setup-apim-policies.png) · [Mermaid source](docs/diagrams/02-working-setup-apim-policies.mmd)

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant C as MCP client
    participant P as APIM MCP server<br/>/ado-mcp-proxy/{org}<br/>proxy-mcp.xml
    participant A as APIM PRM + OAuth APIs<br/>/ado-mcp-proxy/.well-known/...<br/>/ado-mcp-proxy/oauth/...<br/>+ .well-known aliases
    participant O as Azure DevOps MCP<br/>mcp.dev.azure.com/{org}
    participant E as Microsoft Entra ID

    C->>P: POST initialize (no token)
    Note over P: proxy-mcp.xml inbound: HTTPS,<br/>org allow-list (else 404),<br/>rate limit, header hygiene
    P-->>C: 401 resource_metadata={gateway}/ado-mcp-proxy/<br/>.well-known/oauth-protected-resource/{org}
    Note over C,P: CHANGE 6: generated by APIM's MCP server<br/>(as on the regular setup).<br/>No policy rewrite, no scope parameter.
    C->>A: GET /ado-mcp-proxy/.well-known/oauth-protected-resource/{org}
    Note over A: CHANGE 1 (oauth-prm.xml, API ado-mcp-proxy-prm):<br/>the more specific API answers, not APIM's<br/>built-in metadata. resource={gateway}/ado-mcp-proxy/{org},<br/>authorization_servers=[{gateway}/ado-mcp-proxy/oauth]
    A-->>C: PRM (resource matches the URL the client used)
    C->>A: GET /.well-known/oauth-authorization-server/ado-mcp-proxy/oauth
    Note over A: CHANGE 2 (oauth-as-metadata.xml):<br/>APIM is the authorization server<br/>(issuer={gateway}/ado-mcp-proxy/oauth)<br/>with authorize, token and register
    A-->>C: AS metadata
    C->>A: POST /ado-mcp-proxy/oauth/register (dynamic client registration)
    Note over A: CHANGE 3 (oauth-register.xml):<br/>return the pre-registered Entra public<br/>client ID (Entra has no DCR endpoint)
    A-->>C: client_id
    C->>U: open browser
    U->>A: GET /ado-mcp-proxy/oauth/authorize?...&resource={gateway}/ado-mcp-proxy/{org}
    Note over A: CHANGE 4 (oauth-authorize.xml):<br/>drop the client's resource,<br/>set resource=https://mcp.dev.azure.com,<br/>add scope if missing, require PKCE S256
    A-->>U: 302 to login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
    U->>E: sign in + consent
    E-->>C: browser redirect with authorization code (127.0.0.1 / localhost / vscode.dev)
    C->>A: POST /ado-mcp-proxy/oauth/token (code, code_verifier, resource={gateway}/...)
    Note over A: CHANGE 5 (oauth-token.xml):<br/>same resource rewrite, remove Origin,<br/>forward to Entra, tokens never logged
    A->>E: POST /token (resource=https://mcp.dev.azure.com)
    E-->>A: access_token (aud = Azure DevOps MCP, the user) + refresh_token
    A-->>C: token response unchanged
    C->>P: POST initialize, tools/list, tools/call + Bearer
    Note over P: The MCP server forwards the user's<br/>token unchanged to /{org} and streams<br/>the SSE response. proxy-mcp.xml adds<br/>governance and telemetry only
    P->>O: same token
    O-->>C: results, Azure DevOps authorizes as the signed-in user
```

The change numbers are the same as in
[docs/CLIENTS-APIM-CHANGES.md](docs/CLIENTS-APIM-CHANGES.md), which explains each change for
newcomers, per client and with before/after snippets.
[docs/POLICIES.md](docs/POLICIES.md) explains every policy element by element.

| Step | What happens | Policy (in `infra/policies/`) |
|---|---|---|
| 1–2 | Unauthenticated `initialize` reaches the working setup's MCP server. The policy checks HTTPS and the organization in the path (allow-list), and applies the rate limit. APIM answers `401` with `resource_metadata` pointing at `{gateway}/ado-mcp-proxy/.well-known/oauth-protected-resource/{org}`. **Change 6**: this challenge is built into the MCP server, exactly as on the regular setup. No policy rewrites it, and it carries no `scope` parameter. | `proxy-mcp.xml` inbound; the challenge itself: APIM, no policy |
| 3–4 | **Change 1, the fix.** The URL from the challenge is answered by the plain API `ado-mcp-proxy-prm`, not by the MCP server's built-in metadata (API Management routes to the most specific API path). `resource` equals the client URL, so VS Code and Claude Code accept it, and the authorization server is the gateway, not Entra. | `oauth-prm.xml` |
| 5–6 | **Change 2.** APIM publishes authorization-server metadata with its own issuer (`{gateway}/ado-mcp-proxy/oauth`) and endpoints under that path. All tested CLIs fetched it from the path-inserted alias. | `oauth-as-metadata.xml` |
| 7–8 | **Change 3.** Dynamic client registration returns one pre-registered Entra public client, because Entra cannot register clients dynamically. | `oauth-register.xml` |
| 9–11 | **Change 4.** `/authorize` keeps PKCE and the client's parameters, replaces `resource` with `https://mcp.dev.azure.com`, adds the scope if missing, and redirects the browser to Entra. | `oauth-authorize.xml` |
| 12–13 | The user signs in. Entra redirects the browser to the client's loopback/redirect URI with a code. APIM is not involved. | — |
| 14–17 | **Change 5.** `/token` applies the same `resource` translation and forwards to Entra. Entra issues a delegated token for Azure DevOps MCP, returned unchanged. | `oauth-token.xml` |
| 18–20 | MCP traffic carries the user's own token. The MCP server forwards it unchanged and streams the response. Azure DevOps authorizes and audits the real user. | `proxy-mcp.xml` (governance and telemetry only) |

## APIs deployed in API Management

`infra/main.bicep` creates two **MCP servers** (APIM → *APIs → MCP servers*) and, for the
working setup, five small **plain HTTP APIs** that exist only to make sign-in work. It also
creates one backend, `ado-mcp-origin` → `https://mcp.dev.azure.com`, used by both MCP
servers. Every API emits `<trace>` events to Application Insights (see
[Observability](docs/OBSERVABILITY.md)).

**MCP servers** (type MCP, native pass-through, no operations):

| Name (path) | Task | Policy |
|---|---|---|
| **`ado-mcp-native`** (`/ado-mcp-native`) | **Regular setup.** Forwards `/{org}` to `https://mcp.dev.azure.com/{org}`. APIM rewrites the 401 challenge and proxies/rewrites the PRM (`/ado-mcp-native/.well-known/oauth-protected-resource/{org}`) by design, and that PRM names Entra: sign-in fails. | `native-mcp.xml` |
| **`ado-mcp-proxy`** (`/ado-mcp-proxy`), display name *Azure DevOps MCP (working, ado-mcp-proxy)* | **Working setup.** The same feature and backend. Forwards the user's token unchanged and streams the response. The policy checks HTTPS and the organization (allow-list), sets the correlation ID, traces the MCP method and caller, applies the rate limit and the shared backend and response header fragments. No operations, no custom forwarding, no challenge rewrite, no tool argument validation ([why](docs/TOOL-VALIDATION.md)). | `proxy-mcp.xml` |

**Plain HTTP APIs of the working setup** (all under its dedicated path, or path-scoped
aliases; nothing at the gateway root):

| API name (path) | Operations | Task | Policy |
|---|---|---|---|
| **`ado-mcp-proxy-prm`** (`/ado-mcp-proxy/.well-known/oauth-protected-resource`) | `GET /`, `GET /{org}` | Protected-resource metadata (RFC 9728) at exactly the URL the MCP server's 401 names. It takes precedence over the MCP server's built-in metadata (verified in the lab). `resource` = the client URL, `authorization_servers` = `{gateway}/ado-mcp-proxy/oauth`, scope = Azure DevOps MCP. | `oauth-prm.xml` |
| **`ado-mcp-proxy-oauth`** (`/ado-mcp-proxy/oauth`) | `GET /.well-known/oauth-authorization-server`, `GET /.well-known/openid-configuration` | Authorization-server metadata (RFC 8414 / OpenID, path-appended to the issuer): issuer = `{gateway}/ado-mcp-proxy/oauth`, endpoints `…/authorize`, `…/token`, `…/register`, PKCE S256, public clients. | `oauth-as-metadata.xml` |
| | `POST /register` | Dynamic client registration (RFC 7591) compatibility. Returns the pre-registered Entra public client ID, because Entra has no DCR endpoint. | `oauth-register.xml` |
| | `GET /authorize` | Requires PKCE S256, keeps the client's parameters, replaces `resource` with `https://mcp.dev.azure.com`, adds the scope if missing, and redirects the browser (302) to Entra `/authorize`. | `oauth-authorize.xml` |
| | `POST /token` | Same `resource` and scope handling, removes `Origin`, forwards the code/refresh-token exchange to Entra `/token`, and returns the token response unchanged. Nothing is logged. | `oauth-token.xml` |
| **`ado-mcp-proxy-discovery-prm`** (`/.well-known/oauth-protected-resource/ado-mcp-proxy`) | `GET /`, `GET /{org}` | *Discovery alias* (`rootDiscoveryAliases`). The same PRM at the RFC 9728 path-inserted URL, for clients that ignore the 401 header (OpenAI Codex). | `oauth-prm.xml` |
| **`ado-mcp-proxy-discovery-as`** (`/.well-known/oauth-authorization-server/ado-mcp-proxy`) | `GET /oauth` | *Discovery alias.* RFC 8414 path-inserted metadata for the issuer `{gateway}/ado-mcp-proxy/oauth`. | `oauth-as-metadata.xml` |
| **`ado-mcp-proxy-discovery-oidc`** (`/.well-known/openid-configuration/ado-mcp-proxy`) | `GET /oauth` | *Discovery alias.* OpenID path-inserted metadata for the same issuer. | `oauth-as-metadata.xml` |

`echo-api` (APIM's built-in sample API on new instances) is not created or used by this lab.
The deployment output `proxyApiNames` lists the six working-setup names: the MCP server and
the five plain APIs.

The plain APIs apply a CORS policy (any origin, `GET`/`POST`), so browser-based clients such
as MCP Inspector can call discovery, `register` and `token`.

### Isolation: the working setup owns one dedicated path

Everything the working setup needs lives under `{gateway}/ado-mcp-proxy` (parameter
`proxyApiPath`). **Nothing is mounted at the gateway root**: no API with an empty path, and
no `/authorize`, `/token`, `/register`, `/.well-known/oauth-authorization-server` or
`/.well-known/openid-configuration` at the host root. Other APIs on the same API Management
instance (including another product's OAuth endpoints) are therefore never shadowed, and the
working setup is never borrowed by them.

| Route | Purpose | Shared with other APIs? |
|---|---|---|
| `{gateway}/ado-mcp-proxy[/{org}]` | MCP endpoint (client URL), the MCP server | No |
| `{gateway}/ado-mcp-proxy/.well-known/oauth-protected-resource[/{org}]` | PRM, the URL the MCP server's 401 names (API `ado-mcp-proxy-prm`) | No |
| `{gateway}/ado-mcp-proxy/oauth/...` | OAuth metadata, `register`, `authorize`, `token` (API `ado-mcp-proxy-oauth`) | No |
| `{gateway}/.well-known/oauth-protected-resource/ado-mcp-proxy[/{org}]` | Discovery alias (RFC 9728 path insertion) | No: matches only this setup's path suffix |
| `{gateway}/.well-known/oauth-authorization-server/ado-mcp-proxy/oauth` | Discovery alias (RFC 8414 path insertion) | No: same |
| `{gateway}/.well-known/openid-configuration/ado-mcp-proxy/oauth` | Discovery alias (OpenID path insertion) | No: same |

How it works and what to keep in mind:

- API Management routes a request to the API with the **most specific matching path**
  (verified in the lab): `/ado-mcp-proxy/oauth/token` goes to the OAuth API, not to the MCP
  server; `/ado-mcp-proxy/.well-known/oauth-protected-resource/{org}` goes to the PRM API,
  not to the MCP server's built-in metadata; and a
  `/.well-known/oauth-protected-resource/ado-mcp-proxy` API coexists with any other API
  under `/.well-known`.
- The aliases are standard RFC locations that *include* the setup's path, so they can only
  answer for this setup. **Keep them on** (`rootDiscoveryAliases = true`, the default). All
  three CLIs fetched the authorization-server metadata from the path-inserted alias. With the
  aliases removed, OpenAI Codex and Claude Code failed in the lab: they do not try the
  OpenID path-appended URL and fall back to `/register` at the gateway root (`404`). Turn
  them off only for clients you have verified without them.
- An organization literally named `oauth` cannot use the path form
  (`/ado-mcp-proxy/oauth`); use the bare endpoint with `orgName` for it.
- Several working setups can share one instance: deploy again with another `proxyApiPath`
  (API names and display names include the path).
- `tools/mcp_probe.py` checks it on every run: step *client: OAuth endpoints under the MCP
  path (isolation)* fails if any gateway-hosted OAuth endpoint is outside the MCP URL's path.
- **Upgrading from an earlier version** of this lab (OAuth API at the gateway root, or the
  working setup as a plain HTTP API proxy): Bicep deploys incrementally and does not delete
  old APIs, and an API's type cannot change from HTTP to MCP. Delete the old APIs, then make
  clients forget the old issuer (Claude Code cached it and went to the removed root
  `/authorize`): see
  [GETTING-STARTED.md](docs/GETTING-STARTED.md#upgrading-from-an-earlier-version).

Supporting resources: four **policy fragments** (APIM → *APIs → Policy fragments*) and three
**named values** (`mcp-allowed-organizations`, `mcp-readonly`, `mcp-toolsets`; APIM →
*Named values*, editable without redeploying).

How the policies are composed from fragments (details and diagram:
[docs/POLICIES.md](docs/POLICIES.md#how-the-policies-are-composed-fragments)):

| Fragment | What it does | `native-mcp` | `proxy-mcp` | `oauth-prm` | `oauth-token` |
|---|---|---|---|---|---|
| `mcp-org-validation` | Organization from the URL (`{org}` on the PRM operations, the path after the API path on the MCP server); 404 for malformed or not allowed organizations | | ✅ | ✅ | |
| `mcp-caller-identity` | User `oid` and client app ID from the token, for telemetry only | ✅ | ✅ | | |
| `mcp-backend-headers` | Strip spoofable headers; `X-MCP-Readonly` / `X-MCP-Toolsets` | ✅ | ✅ | | |
| `mcp-response-headers` | `Cache-Control: no-store`, `x-apim-request-id` | ✅ | ✅ | | ✅ |

Both MCP servers share the read-only, toolsets, header-hygiene, caller-identity and
response-header fragments. The working setup additionally enforces HTTPS, the organization
allow-list, a per-IP rate limit and an `X-Correlation-ID`; the regular setup stays minimal
because it is the reproduction. For sign-in, the only thing that matters is OAuth discovery.

## What is in this repository

```text
infra/
  main.bicep                       entry point (resource-group scope)
  main.example.bicepparam          copy to main.local.bicepparam (gitignored)
  modules/apim.bicep               optional: create a Developer-tier APIM
  modules/monitoring.bicep         Log Analytics + workspace-based Application Insights
  modules/apim-observability.bicep APIM loggers, diagnostics, diagnostic settings
  modules/mcp-native.bicep         regular setup: native MCP pass-through
  modules/mcp-proxy.bicep          working setup: MCP server + PRM/OAuth compatibility APIs, all under its dedicated path
  modules/policy-fragments.bicep   shared policy fragments + named values (allow-list, read-only, toolsets)
  policies/                        APIM policy XML per API/operation (see diagram 2)
  policies/fragments/              reusable policy fragments included by those policies
scripts/setup-entra.ps1            Entra prerequisites (service principal, public client, client redirect URIs)
tools/mcp_probe.py                 end-to-end probe (origin vs gateway), stdlib only
tools/query_logs.py                run docs/kql/*.kql from the command line
tools/probe.example.json           copy to probe.local.json (gitignored)
tools/tests/                       unit and loopback tests for the probe
docs/GETTING-STARTED.md            deploy step by step, with expected output
http/                              step-by-step .http walkthroughs (REST Client, httpYac, JetBrains)
docs/TESTING.md                    probe, raw protocol, logs, client checklist
docs/clients/                      one guide per MCP client (VS Code, Copilot CLI, Codex, Claude Code, Inspector)
docs/CLIENTS-APIM-CHANGES.md       what APIM changes for each client, and why
docs/POLICIES.md                   every APIM policy, element by element
docs/TOOL-VALIDATION.md            tool argument validation: optional, not deployed; how to add it
docs/OBSERVABILITY.md              where calls and policy events land; KQL guide
docs/GLOSSARY.md                   PRM, DCR, PKCE, resource indicator, AADSTS codes, APIM terms
docs/ANALYSIS.md                   root cause, reference implementation, options, sources
docs/AI-GATEWAY.md                 Azure AI Gateway: requirement matrix, live test, recommendation
infra/aigateway/                   optional AI Gateway lab (federated MCP server, OBO backend)
docs/kql/                          ready-made queries
docs/diagrams/                     diagram sources (.mmd) and SVG / PNG exports
internal/                          git-ignored local notes (never committed)
```

## What about Azure AI Gateway?

Azure AI Gateway (a separate product, GA on 2026-11-17) was tested in the same lab. It keeps
the user's identity natively with an **on-behalf-of** backend, but its MCP endpoints offer
**no OAuth discovery**: VS Code and the CLIs cannot sign in by themselves and need a token
obtained outside MCP. It has tool allow-lists but no argument validation, and it does not
run APIM policies. For interactive MCP clients, this repository's API Management setup
remains the working option. Details: [docs/AI-GATEWAY.md](docs/AI-GATEWAY.md).

## Client compatibility

Tested in the lab with real clients (Copilot CLI 1.0.113, Codex CLI 0.167.0, Claude Code
2.1.322 on 2026-11-18; VS Code and MCP Inspector on 2026-11-17). On the current layout (the
working setup as an APIM MCP server, everything under `/ado-mcp-proxy`), these were verified
again on 2026-11-18: Copilot CLI 1.0.114 signed in and called `core_list_projects`; Codex CLI
0.167.0 signed in; Claude Code 2.1.322 connected. VS Code and MCP Inspector were not re-run
on this layout. Details, commands and log evidence are in
[docs/clients](docs/clients/README.md). What APIM changes for each client, and why, is in
[docs/CLIENTS-APIM-CHANGES.md](docs/CLIENTS-APIM-CHANGES.md).

| Client | Working setup (`/ado-mcp-proxy/<org>`) | Regular setup (`/ado-mcp-native/<org>`) |
|---|---|---|
| VS Code (GitHub Copilot) | ✅ sign-in and tools (not re-run on the current layout) | ❌ `AADSTS9010010` |
| GitHub Copilot CLI | ✅ sign-in, tools | ⚠️ connects in interactive mode through Copilot CLI's own Entra broker (client feature, not the gateway); `-p` reports *requires authentication* |
| OpenAI Codex CLI | ✅ sign-in, tools | ❌ *Dynamic registration failed: HTTP 404*: no metadata, falls back to `/register` at the gateway root, which no longer exists |
| Claude Code | ✅ sign-in, connected, `tools/list` | ❌ *does not support dynamic client registration*; with `--client-id` ❌ `AADSTS9010010` |
| MCP Inspector | ✅ (not re-run on the current layout) | ❌ no DCR, or `AADSTS9010010` with a client ID |

The regular-setup failures are the reported problem. The ⚠️ result does not mean native
pass-through is fixed: it comes from a client-specific Entra integration. (Before the working
setup moved to its own path, Codex also "connected" to the native URL by borrowing the
working setup's root endpoints. The isolation removed that side effect.)

## Get started

[docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) walks through prerequisites, the Entra
setup, parameters, deployment, a first probe run and a first client sign-in, with the
expected output of every command. The short version:

```powershell
az login --tenant <tenant-id>
./scripts/setup-entra.ps1 -TenantId <tenant-id> -GrantAdminConsent -McpUrl https://<apim-name>.azure-api.net/ado-mcp-proxy/<org>, https://<apim-name>.azure-api.net/ado-mcp-native/<org>
Copy-Item infra/main.example.bicepparam infra/main.local.bicepparam   # set apimName, adoOrganization, tenantId, publicClientId
az deployment group create -g <rg> --parameters infra/main.local.bicepparam --query properties.outputs
Copy-Item tools/probe.example.json tools/probe.local.json             # fill in as in GETTING-STARTED step 5
python tools/mcp_probe.py --config tools/probe.local.json --token az
```

## Tool argument validation

Not deployed. Neither setup checks `tools/call` arguments at the gateway; the hosted server
decides, and it accepts `top: "5"`, `top: 500` and unknown arguments. An earlier version of
the lab validated two tools against curated JSON schemas with APIM's `validate-content`. That
policy needs API operations, and MCP servers have none (it made every request fail with
HTTP 500), so it was removed when the working setup became an MCP server. How to add
validation if you need it (an HTTP API in front, policy expressions, or tool allow-lists):
[docs/TOOL-VALIDATION.md](docs/TOOL-VALIDATION.md).

## Observability

Every gateway call is a **request** in Application Insights, the outbound call a
**dependency**, and every policy decision a **trace** (`<trace>` policies: MCP method,
organization, user `oid`, client app, OAuth step, redirect URI).
Resource logs go to Log Analytics (`ApiManagementGatewayLogs`, `ApiManagementGatewayMCPLog`).
No tokens, `Authorization` headers or response bodies are logged. Ready-made KQL is in
`docs/kql/`. Table guide, queries and examples: [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md).

## Security notes on the working setup

- APIM forwards the **user's own** Azure DevOps MCP token. Azure DevOps enforces the user's
  permissions and auditing. There is no shared or service credential.
- The token's audience is Azure DevOps MCP, not APIM. APIM acts as a transparent proxy, so
  this is the token pass-through pattern the MCP security guidance warns about when the proxy
  is a separate resource. Accept that consciously. As optional hardening, add
  `validate-azure-ad-token` (tenant + audience `2a72489c-aab2-4b65-b93a-a91edccf33b8`) to
  reject foreign tokens at the gateway.
- `/register` hands every client the same public client ID. Consent and the redirect-URI
  allow-list therefore belong to that one app registration. Keep its redirect URIs minimal.
- PKCE S256 is enforced at `/authorize`. Entra still validates client, redirect URI and consent.
- The facade relies on API Management routing to the most specific API path: the PRM and
  OAuth APIs are nested under the MCP server's path, where they take precedence over its
  built-in metadata, and the discovery aliases live under `/.well-known`. If APIM changed
  that, the MCP server's built-in PRM (which names Entra) would answer again and sign-in
  would fail as on the regular setup. Re-run the probe, including its isolation check, after
  APIM or client updates.
- No tool arguments are validated at the gateway ([TOOL-VALIDATION.md](docs/TOOL-VALIDATION.md)).
  Use `readOnly` and `toolsets` to limit which tools exist.

## Cost

APIM Developer tier is billed per hour while it exists, even when idle. It has no SLA and is
for non-production use only. Log Analytics and workspace-based Application Insights are billed
by ingested data; this lab produces little. See
[APIM pricing](https://azure.microsoft.com/pricing/details/api-management/) and
[Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/).
Delete the lab resource group when finished.

## Credits

- **[carolga/ado-apim](https://github.com/carolga/ado-apim)**: the original APIM proxy for
  the hosted Azure DevOps MCP server. The working setup keeps its OAuth compatibility idea:
  APIM-hosted PRM and authorization-server metadata, a static `/register`, and `/authorize`
  and `/token` adding the Azure DevOps `resource`. It also reuses the governance policy
  (HTTPS, rate limit, `X-MCP-Readonly`/`X-MCP-Toolsets`, header hygiene, correlation ID) and
  the Entra prerequisites (*Azure DevOps MCP* service principal, public client with VS Code
  redirect URIs). Its HTTP API proxy is no longer used: the working setup now uses APIM's
  native MCP server, like the regular setup. This repository adds:
  - PRM `resource` equal to the client URL, served at the URL the MCP server advertises;
  - `resource` replacement rather than addition;
  - organization-in-path multi-organization support;
  - isolation of every route under one dedicated path;
  - Log Analytics resource logs and KQL;
  - the end-to-end probe;
  - the native pass-through comparison and its root-cause analysis.
  See [docs/ANALYSIS.md](docs/ANALYSIS.md#3-reference-implementation-analysis-carolgaado-apim).
- **[Azure-Samples/AI-Gateway](https://github.com/Azure-Samples/AI-Gateway)**: the
  `apim-streamable-mcp` module showed the `backendId` shape for native MCP pass-through.
  The `mcp-prm-oauth` and `mcp-client-authorization` labs show APIM-hosted PRM and OAuth
  endpoints.
- **[microsoft/azure-devops-mcp](https://github.com/microsoft/azure-devops-mcp)** and its
  issue tracker: server behaviour and the organization-PRM mismatch
  ([#1601](https://github.com/microsoft/azure-devops-mcp/issues/1601)).
- **[Model Context Protocol](https://modelcontextprotocol.io/)** specification, and the
  **[VS Code](https://github.com/microsoft/vscode)** source for client behaviour (RFC 9728
  validation, RFC 8707 `resource` forwarding).
