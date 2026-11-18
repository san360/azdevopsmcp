# What API Management changes so MCP clients can sign in (and why)

This page is for anyone who has to explain or rebuild the **working setup**, not only
identity experts. It lists every change made in Azure API Management (APIM) so that the
command-line agents **GitHub Copilot CLI**, **OpenAI Codex CLI** and **Claude Code** (and,
for comparison, **VS Code**) can sign in and use the hosted Azure DevOps MCP server through
the gateway. For each change you get:

1. **What the client does**, in plain language.
2. **What breaks without the change**, as observed in the lab.
3. **The exact APIM change**: policy file, element, before/after snippet.
4. **Why it is safe**, and the spec it relates to.
5. **How to verify it**: a command, the expected output, and a KQL query.

The README's Diagram 2 uses the same change numbers. Changes 1–5 are the PRM and OAuth
compatibility policies. Changes 6 and 7 are built into the APIM MCP server and need no
policy; they are listed because clients depend on them. Changes 8–9 are outside the request
path (Entra redirect URIs, diagnostics).

Everything marked *observed* was seen in lab sign-ins on 2026-11-18 with Copilot CLI
1.0.113/1.0.114, Codex CLI 0.167.0 and Claude Code 2.1.322. On the current layout (the
working setup as an APIM MCP server), Copilot CLI signed in and called a tool, Codex signed
in, and Claude Code connected. Anything not seen is marked *unverified*. Hostnames, tenants
and IDs are placeholders. Unfamiliar terms are explained in [the glossary](GLOSSARY.md).
Per-client setup steps are in [docs/clients](clients/README.md).

## The idea in one paragraph

An MCP client that gets `401 Unauthorized` goes on a short treasure hunt. The server tells it
where the **protected-resource metadata** ([PRM](GLOSSARY.md#prm)) is, a small JSON file
that names the API and who issues its keys. The client then reads the **authorization
server metadata** (the key issuer's address book). It gets a **client ID**: either it asks
the issuer to register it ([DCR](GLOSSARY.md#dcr)) or it is told one. It then opens a browser
so the user can sign in, and the browser comes back to a small web server on the user's own
machine (the [redirect URI](GLOSSARY.md#redirect-uri)). Finally it swaps the one-time code
for a token. On every step it says which API the token is for: the
[resource indicator](GLOSSARY.md#resource-indicator). Microsoft Entra issues the keys for
Azure DevOps, but it **has no registration desk** (no DCR) and **refuses a resource name it
does not know**, such as a gateway URL. The working setup lets APIM play the address book
and the registration desk, and translate the resource name, while the user's real Azure
DevOps token flows through untouched.

## Summary: which client needs which change

✅ = the client needs this change and the lab shows it working. ⚪ = not used by this
client. ⚠️ = safety net; the client did not need it in the lab, but versions have needed it
(see the linked issues).

| # | APIM change (file) | Copilot CLI | Codex CLI | Claude Code | VS Code |
|---|---|---|---|---|---|
| 1 | PRM for the exact URL (`oauth-prm.xml`, APIs `ado-mcp-proxy-prm` and alias `ado-mcp-proxy-discovery-prm`) | ✅ | ✅ found via path-inserted URL | ✅ checks `resource` = URL | ✅ checks `resource` = URL |
| 2 | Authorization-server metadata, issuer = gateway (`oauth-as-metadata.xml`) | ✅ | ✅ | ✅ | ✅ |
| 3 | Dynamic client registration answer (`oauth-register.xml`) | ✅ | ✅ | ✅ | ✅ |
| 4 | `/authorize`: replace `resource`, add `scope` if missing, require PKCE (`oauth-authorize.xml`) | ✅ (scope ⚠️) | ✅ (scope ⚠️) | ✅ (scope ⚠️) | ✅ |
| 5 | `/token`: same translation (`oauth-token.xml`) | ✅ | ✅ | ✅ | ✅ |
| 6 | 401 challenge points at the setup's own PRM URL (built into the MCP server; no policy, no `scope` parameter) | ✅ | ⚪ uses well-known URLs | ✅ | ✅ |
| 7 | Body-less `GET`/`DELETE` must not fail (the MCP server answers `405`; no policy) | ⚪ | ✅ | ⚪ | ⚪ |
| 8 | Redirect URIs on the Entra public client (`scripts/setup-entra.ps1`, not APIM) | `http://127.0.0.1/` | `http://127.0.0.1/callback/<id>` per URL | `http://localhost/callback` | `http://127.0.0.1:33418/` |
| 9 | Diagnostics: User-Agent and sign-in details in logs (`mcp-proxy.bicep`, traces) | helps | helps | helps | helps |

What each client does differently, observed in the lab:

| | Copilot CLI | Codex CLI | Claude Code | VS Code |
|---|---|---|---|---|
| First request | `POST initialize` | Body-less `GET` of the MCP URL | `POST initialize` | `POST initialize` |
| Finds PRM via | `WWW-Authenticate` | Path-inserted well-known URL | `WWW-Authenticate` | `WWW-Authenticate` |
| Client ID | DCR (`client_name` "GitHub Copilot CLI") | DCR ("Codex") | DCR ("Claude Code (<server>)") | DCR |
| Redirect URI | `http://127.0.0.1:<random>/` | `http://127.0.0.1:<random>/callback/<id>` | `http://localhost:<random>/callback` | `http://127.0.0.1:33418/` |
| Sends `resource` | Yes (gateway URL) | Yes (gateway URL) | Yes (gateway URL) | Yes (gateway URL) |
| Sign-in command | `/mcp` in interactive mode | `codex mcp login <name>` | `claude mcp login <name>` or `/mcp` | **MCP: List Servers** → start |
| Headless after sign-in (`-p`/`exec`) | ✅ (re-verified on the current layout) | ✅ (on the earlier HTTP proxy layout) | Not run (no model reachable in the lab) | n/a |

## Diagram: where the clients differ

High-resolution exports: [SVG](diagrams/03-client-sign-in-differences.svg) · [PNG](diagrams/03-client-sign-in-differences.png) · [Mermaid source](diagrams/03-client-sign-in-differences.mmd)

The diagram is the working-setup sign-in. Steps are numbered; the coloured notes mark where
a client behaves differently and which APIM change handles it.

```mermaid
sequenceDiagram
    autonumber
    actor U as User (browser)
    participant C as CLI client
    participant P as APIM MCP server<br/>/ado-mcp-proxy/{org}
    participant A as APIM PRM + OAuth APIs<br/>/ado-mcp-proxy/.well-known/...<br/>/ado-mcp-proxy/oauth/...<br/>+ .well-known aliases
    participant E as Microsoft Entra ID
    participant O as Azure DevOps MCP

    alt Codex
        C->>P: GET /ado-mcp-proxy/{org} (no body, no token)
        P-->>C: 405 from the MCP server (change 7: nothing to fix)
        C->>A: GET /.well-known/oauth-protected-resource/ado-mcp-proxy/{org} (alias)
    else Copilot CLI, Claude Code, VS Code
        C->>P: POST initialize (no token)
        P-->>C: 401 resource_metadata={gateway}/ado-mcp-proxy/<br/>.well-known/oauth-protected-resource/{org} (change 6, built in)
        C->>A: GET the resource_metadata URL (API ado-mcp-proxy-prm)
    end
    A-->>C: PRM: resource = the URL the client used,<br/>authorization server = {gateway}/ado-mcp-proxy/oauth (change 1)
    C->>A: GET /.well-known/oauth-authorization-server/ado-mcp-proxy/oauth (alias)
    A-->>C: issuer = {gateway}/ado-mcp-proxy/oauth, its authorize, token, register (change 2)
    C->>A: POST /ado-mcp-proxy/oauth/register {client_name, redirect_uris}
    A-->>C: the pre-registered Entra public client ID (change 3)
    Note over C: Redirect URI differs: Copilot 127.0.0.1:{port}/ ·<br/>Codex 127.0.0.1:{port}/callback/{id} · Claude localhost:{port}/callback
    C->>U: open browser
    U->>A: GET /ado-mcp-proxy/oauth/authorize ... resource={gateway URL}
    A-->>U: 302 to Entra with resource=https://mcp.dev.azure.com,<br/>scope added if missing (change 4)
    U->>E: sign in, Entra checks the redirect URI (change 8)
    E-->>C: code, delivered to the client's local redirect URI
    C->>A: POST /ado-mcp-proxy/oauth/token (code, PKCE verifier, resource={gateway URL})
    A->>E: same request with resource=https://mcp.dev.azure.com (change 5)
    E-->>C: user token, audience Azure DevOps MCP
    C->>P: initialize, tools/list, tools/call + Bearer token
    P->>O: forwarded unchanged by the MCP server, Azure DevOps acts as the user
```

---

## Change 1: protected-resource metadata for the exact URL the client uses

**What the client does.** After a `401`, every client looks for a small JSON document, the
[PRM](GLOSSARY.md#prm) ([RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)). It is
like the sign on a door saying "this room is X, and the key office is Y". VS Code and
Claude Code check that the room name (`resource`) equals the URL they connected to, and
refuse it otherwise. Codex does not read the `401` header (its first request is a body-less
`GET`). It tries the standard addresses instead, starting with
`/.well-known/oauth-protected-resource/<path of the MCP URL>`.

**Without it (observed).** On the native pass-through, the PRM that APIM serves names
**Entra** as the key office. Claude Code then stops with
`Incompatible auth server: does not support dynamic client registration`. A client that is
given a client ID sends the gateway URL to Entra and gets `AADSTS9010010` (Claude Code with
`--client-id`, VS Code). Codex finds no PRM at the standard addresses for the native URL,
because APIM serves it under `/ado-mcp-native/.well-known/...`.

**The change.** The working setup's MCP server advertises
`/ado-mcp-proxy/.well-known/oauth-protected-resource/{org}` in its 401 challenge (change 6),
just as the native one does. Left alone, APIM's built-in metadata would answer that URL and
name Entra, as on the regular setup. Instead, the plain API `ado-mcp-proxy-prm` (path
`/ado-mcp-proxy/.well-known/oauth-protected-resource`) answers it with a PRM for exactly that
MCP URL (`infra/policies/oauth-prm.xml`, `<return-response>`). API Management routes to the
most specific API path, so this API takes precedence over the MCP server's built-in metadata
(verified in the lab). This is the fix. For Codex, which skips the header, the discovery
alias API `ado-mcp-proxy-discovery-prm` serves the same document at the RFC 9728
path-inserted URL `/.well-known/oauth-protected-resource/ado-mcp-proxy/{org}`. Both stay
inside the working setup's path (see
[Isolation](../README.md#isolation-the-working-setup-owns-one-dedicated-path)).

```jsonc
// Before (native pass-through, generated by APIM)
{ "resource": "https://<gateway>/ado-mcp-native/<org>",
  "authorization_servers": [ "https://login.microsoftonline.com/<tenant-id>/v2.0" ],
  "scopes_supported": [ "https://mcp.dev.azure.com/.default" ] }
// After (working setup, oauth-prm.xml)
{ "resource": "https://<gateway>/ado-mcp-proxy/<org>",
  "authorization_servers": [ "https://<gateway>/ado-mcp-proxy/oauth" ],
  "scopes_supported": [ "https://mcp.dev.azure.com/.default" ],
  "bearer_methods_supported": [ "header" ], "resource_name": "Azure DevOps MCP via API Management" }
```

**Why it is safe.** It is public, read-only metadata (RFC 9728 §3). It contains no secrets,
and organization names are validated against the allow-list first.

**Verify.**

```powershell
Invoke-RestMethod https://<gateway>/ado-mcp-proxy/.well-known/oauth-protected-resource/<org> | ConvertTo-Json
Invoke-RestMethod https://<gateway>/.well-known/oauth-protected-resource/ado-mcp-proxy/<org> | ConvertTo-Json   # alias, same document
# resource = https://<gateway>/ado-mcp-proxy/<org>, authorization_servers = [ https://<gateway>/ado-mcp-proxy/oauth ]
```

KQL: [`client-signins.kql`](kql/client-signins.kql) shows step `prm` per client;
[`policy-traces.kql`](kql/policy-traces.kql) shows `oauth: protected-resource metadata served for ...`.

## Change 2: authorization-server metadata with the gateway as issuer

**What the client does.** The PRM says "the key office is
`https://<gateway>/ado-mcp-proxy/oauth`". The client then reads that office's address book
([RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414)): where to register, where to
send the user, where to swap the code. For an issuer with a path, clients try the
path-inserted URLs `/.well-known/oauth-authorization-server/ado-mcp-proxy/oauth` and
`/.well-known/openid-configuration/ado-mcp-proxy/oauth`, then the path-appended
`/ado-mcp-proxy/oauth/.well-known/openid-configuration`
([MCP 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#authorization-server-metadata-discovery)).
Codex was observed to try them in that order. Copilot CLI and Claude Code check that the
`issuer` in the document equals the address they fetched it from
([copilot-cli#4584](https://github.com/github/copilot-cli/issues/4584)).

**Without it.** No address book, so no sign-in: the client cannot find `authorize` or
`token`. A wrong `issuer` makes Copilot CLI stop with *"issuer does not match"*
(*unverified in this lab*; reported in the issue above).

**The change.** `oauth-as-metadata.xml` answers all of these URLs: path-appended in the
OAuth API, path-inserted in the discovery aliases `ado-mcp-proxy-discovery-as` and
`ado-mcp-proxy-discovery-oidc`. The issuer is the request origin plus `/ado-mcp-proxy/oauth`.

```jsonc
// After
{ "issuer": "https://<gateway>/ado-mcp-proxy/oauth",
  "authorization_endpoint": "https://<gateway>/ado-mcp-proxy/oauth/authorize",
  "token_endpoint": "https://<gateway>/ado-mcp-proxy/oauth/token",
  "registration_endpoint": "https://<gateway>/ado-mcp-proxy/oauth/register",
  "code_challenge_methods_supported": [ "S256" ],
  "token_endpoint_auth_methods_supported": [ "none" ],
  "scopes_supported": [ "https://mcp.dev.azure.com/.default" ] }
```

**Why it is safe.** Metadata only. It advertises PKCE S256 and public clients
(`token_endpoint_auth_method: none`), which is what MCP clients are. Because the issuer has
a path, the gateway root stays free for other APIs.

**Verify.** `Invoke-RestMethod https://<gateway>/ado-mcp-proxy/oauth/.well-known/openid-configuration`
and `https://<gateway>/.well-known/oauth-authorization-server/ado-mcp-proxy/oauth`: `issuer`
equals `https://<gateway>/ado-mcp-proxy/oauth` exactly, with no trailing slash. KQL step
`as-metadata`.

## Change 3: a registration desk that hands out one pre-registered client

**What the client does.** All three CLIs (and VS Code) register themselves through
[dynamic client registration](GLOSSARY.md#dcr) ([RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591)):
`POST <registration_endpoint>` (`/ado-mcp-proxy/oauth/register`) with their name and local
redirect URI. Observed `client_name` values:
`GitHub Copilot CLI`, `Codex`, `Claude Code (<server name>)`.

**Without it (observed).** Entra has no registration endpoint. Claude Code reports
`Incompatible auth server: does not support dynamic client registration`. Copilot CLI and
Codex can be configured with a fixed client ID instead (`oauthClientId`,
`--oauth-client-id`), but they then go to Entra directly with the gateway `resource` and
hit `AADSTS9010010`, like Claude Code did with `--client-id` (observed for Claude Code; for
the other two *unverified*).

**The change.** `oauth-register.xml` answers every registration with the same
pre-registered Entra **public client** ID. It echoes the client's `redirect_uris` and logs
`client_name` and `redirect_uris` (not secrets) for troubleshooting.

```json
POST https://<gateway>/ado-mcp-proxy/oauth/register
{"client_name":"Codex","redirect_uris":["http://127.0.0.1:57130/callback/<id>"], ...}

HTTP/1.1 201 Created
{"client_id":"<public-client-id>","client_name":"Codex","application_type":"native",
 "redirect_uris":["http://127.0.0.1:57130/callback/<id>"],
 "grant_types":["authorization_code","refresh_token"],"token_endpoint_auth_method":"none"}
```

**Why it is safe.** The client ID is public; a public client has no secret. Entra still
decides which redirect URIs are allowed (change 8) and asks for consent. The echo does not
register anything in Entra. The trade-off: all clients share one app registration, so
consent and redirect URIs are managed in one place.

**Verify.**

```powershell
Invoke-RestMethod https://<gateway>/ado-mcp-proxy/oauth/register -Method Post -ContentType application/json `
  -Body '{"client_name":"test","redirect_uris":["http://127.0.0.1/"]}'   # client_id = your public client
```

KQL: `client-signins.kql` shows step `register` with `clientName` and `redirect`, one row per
client sign-in.

## Change 4: `/authorize` translates the resource name

**What the client does.** Every client sends the user's browser to `/authorize` with
`resource=<the gateway URL>`, the [resource indicator](GLOSSARY.md#resource-indicator)
([RFC 8707](https://datatracker.ietf.org/doc/html/rfc8707)), together with
`scope=https://mcp.dev.azure.com/.default` (observed for all three CLIs). It is like
writing "deliver to the reception desk" on a parcel addressed to someone in the building.

**Without it (observed).** Entra rejects the gateway URL as resource for an Azure DevOps
scope: `AADSTS9010010: The resource parameter provided in the request doesn't match with the
requested scopes` (Claude Code with `--client-id` on the native URL; VS Code). This is the
customer's error.

**The change.** `oauth-authorize.xml`: require PKCE S256 (else `400`), copy the raw query
string, **drop** `resource`, add `scope` only if the client sent none, append
`resource=https://mcp.dev.azure.com`, and answer `302` to Entra.

```http
# Before (what the client sends to the gateway)
GET https://<gateway>/ado-mcp-proxy/oauth/authorize?client_id=<public-client-id>&redirect_uri=http%3A%2F%2Flocalhost%3A45766%2Fcallback
    &scope=https%3A%2F%2Fmcp.dev.azure.com%2F.default&code_challenge=...&code_challenge_method=S256&state=...
    &resource=https%3A%2F%2F<gateway>%2Fado-mcp-proxy%2F<org>
# After (what APIM sends the browser to)
302 Location: https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize?client_id=<public-client-id>
    &redirect_uri=...&scope=https%3A%2F%2Fmcp.dev.azure.com%2F.default&code_challenge=...&state=...
    &resource=https%3A%2F%2Fmcp.dev.azure.com
```

Adding `scope` when it is missing is a safety net. All three CLIs sent it in the lab, but
Claude Code and Copilot CLI versions have omitted it, and Entra then answers `AADSTS900144`
([claude-code#72440](https://github.com/anthropics/claude-code/issues/72440),
[copilot-cli#4582](https://github.com/github/copilot-cli/issues/4582)). It also covers the
challenge, which no longer names a scope (change 6): clients take the scope from the PRM
(`scopes_supported`), and the gateway adds it if they send none.

**Why it is safe.** The new resource is the one the scope already belongs to, so the token
is exactly what the client asked for: a token for Azure DevOps MCP. Nothing else changes.
PKCE is enforced, and Entra still checks the client ID, the redirect URI and consent.

**Verify.** Run the probe (`python tools/mcp_probe.py --config tools/probe.local.json`): the
line `apim-proxy client: Entra authorize request: sign-in page served (via gateway redirect);
resource=https://mcp.dev.azure.com` passes. KQL step `authorize` shows `clientResource` (what
the client asked for) and `redirect`.

## Change 5: `/token` applies the same translation

**What the client does.** It swaps the one-time code (and later the refresh token) for an
access token at `/token`, again with `resource=<gateway URL>`.

**Without it (expected, *unverified* in this lab).** Entra checks `resource` on the token
request too, so the exchange would fail with the same `AADSTS9010010`.

**The change.** `oauth-token.xml`: rebuild the form without `resource`, add `scope` if
missing, append `resource=https://mcp.dev.azure.com`, delete the `Origin` header (needed for
browser-based MCP Inspector), forward to Entra `/oauth2/v2.0/token`, and return Entra's
answer unchanged. Tokens are never logged; the OAuth API logs no bodies or credentials.

```text
Before: grant_type=authorization_code&code=...&code_verifier=...&redirect_uri=...&resource=https%3A%2F%2F<gateway>%2Fado-mcp-proxy%2F<org>
After:  grant_type=authorization_code&code=...&code_verifier=...&redirect_uri=...&scope=https%3A%2F%2Fmcp.dev.azure.com%2F.default&resource=https%3A%2F%2Fmcp.dev.azure.com
```

**Why it is safe.** Same reasoning as change 4. PKCE ties the code to the client that
started the sign-in, and the token's audience is Azure DevOps MCP, not APIM.

**Verify.** KQL steps `token` and `token-response` (`statusCode` 200). After sign-in,
`proxy-inbound` traces show `clientAppId` = your public client ID and the user's `oid`.

## Change 6: the 401 challenge points at the setup's own PRM URL (built in)

**What the client does.** Copilot CLI, Claude Code and VS Code read the `WWW-Authenticate`
header of the first `401` to find the PRM. Copilot CLI also uses a `scope` parameter there
when one is present
([copilot-cli#4582](https://github.com/github/copilot-cli/issues/4582)).

**Without it.** The origin's challenge points at `mcp.dev.azure.com` metadata whose
`resource` is not the gateway URL, so VS Code and Claude Code reject it.

**The change.** None in a policy. The APIM MCP server generates the challenge itself, exactly
as on the regular setup, with a URL under its own path. What makes the difference is
change 1: on the working setup that URL is answered by the PRM API, not by APIM's built-in
metadata.

```text
Origin:                     Bearer resource_metadata="https://mcp.dev.azure.com/.well-known/oauth-protected-resource/<org>"
Working setup (APIM):       Bearer resource_metadata="https://<gateway>/ado-mcp-proxy/.well-known/oauth-protected-resource/<org>"
Bare endpoint (no <org>):   Bearer resource_metadata="https://<gateway>/ado-mcp-proxy/.well-known/oauth-protected-resource/"
```

The challenge has no `scope` parameter, which
[MCP 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
recommends. That did not matter in the lab: clients took the scope from the PRM, and
`/authorize` and `/token` add it if it is missing (changes 4 and 5). Copilot CLI and Claude
Code signed in with this challenge on 2026-11-18 (Codex does not read it). (Earlier versions of the lab
used a plain HTTP API, which had to rewrite the origin's challenge in `proxy-mcp.xml`
outbound and added `scope`. That rewrite no longer exists.)

**Why it is safe.** It is APIM's standard behaviour and points only at public metadata.

**Verify.** Run an unauthenticated `POST` (see [TESTING.md](TESTING.md#2-curl--powershell-raw-protocol)):
`401` with the header above, then fetch the URL it names: `authorization_servers` must be
`https://<gateway>/ado-mcp-proxy/oauth`, not Entra.

## Change 7: body-less `GET` and `DELETE` must not fail (built in)

**What the client does.** Codex starts with a plain `GET` of the MCP URL, with no body and no
token, to see what the server says (observed). The
[Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#listening-for-messages-from-the-server)
allows `GET` (to open a stream) and `DELETE` (to end a session). A server may answer `405`.

**Without it (observed earlier).** When the working setup was a plain HTTP API, its
tool-validation fragment read the request body without checking that there was one, so APIM
answered `500` to every `GET`/`DELETE`. Codex then stopped: `OAuth metadata discovery failed
for https://<gateway>/ado-mcp-proxy/<org> Caused by: unexpected HTTP status 500 Internal
Server Error`.

**The change.** None any more. The MCP server answers a body-less `GET` with `405` natively,
and the policy reads the body only for telemetry, falling back to the HTTP method when there
is none (`proxy-mcp.xml`, `set-variable mcp-method`). `oauth-token.xml` and
`oauth-register.xml` keep their own null-body guards.

**Why it is safe.** A request without a body carries no MCP message; Codex continues with
the well-known URLs.

**Verify.**

```powershell
(Invoke-WebRequest https://<gateway>/ado-mcp-proxy/<org> -SkipHttpErrorCheck).StatusCode   # 405, not 500
```

The probe checks this as `discovery: GET without token is not 5xx`.

## Change 8: the Entra public client allows each client's redirect URI

This change is in Microsoft Entra, not APIM, but nothing works without it.

**What the client does.** After sign-in, Entra sends the browser back to a tiny web server
the client runs on your machine: the [redirect URI](GLOSSARY.md#redirect-uri). Each client
picks its own address (observed):

| Client | Redirect URI sent | Register on the public client |
|---|---|---|
| Copilot CLI | `http://127.0.0.1:<random port>/` | `http://127.0.0.1/` |
| Codex CLI | `http://127.0.0.1:<random port>/callback/<id>` | `http://127.0.0.1/callback/<id>`, **one per MCP URL**. The `<id>` is derived from the URL (first 9 bytes of its SHA-256, base64url) |
| Claude Code | `http://localhost:<random port>/callback` | `http://localhost/callback` |
| VS Code | `http://127.0.0.1:33418/` | `http://127.0.0.1:33418/` |
| MCP Inspector | `http://localhost:6274/oauth/callback` | as sent, plus the `127.0.0.1` variant |

**Without it.** Entra shows the sign-in page, and **after** the user signs in it stops with
`AADSTS50011: The redirect URI ... does not match the redirect URIs configured for the
application` (observed earlier with MCP Inspector on `127.0.0.1`). Entra checks this only
after sign-in, so a script cannot pre-check it.

**The change.** `scripts/setup-entra.ps1` registers the URIs above. For Codex, pass
`-McpUrl https://<gateway>/ado-mcp-proxy/<org>` (repeatable); the script computes the `<id>`.
Microsoft documents that Entra ignores the port for `localhost`
([redirect URI rules](https://learn.microsoft.com/entra/identity-platform/reply-url#localhost-exceptions)).
In the lab it also ignored the port for `127.0.0.1` (Copilot CLI and Codex used random ports
against port-less registrations). If that ever changes, pin the port: Copilot
`"auth": { "redirectPort": 33418 }`, Codex `mcp_oauth_callback_port`, Claude Code
`--callback-port`.

**Why it is safe.** Loopback redirects never leave the machine
([RFC 8252 §7.3](https://datatracker.ietf.org/doc/html/rfc8252#section-7.3)), and PKCE stops
another local process from using an intercepted code.

**Verify.** `az ad app show --id <public-client-id> --query publicClient.redirectUris`. KQL
`client-signins.kql` shows each client's `redirect` on `register` and `authorize`.

## Change 9: diagnostics that tell clients apart

Not needed to sign in, but essential for troubleshooting:

- The PRM and OAuth compatibility APIs and the discovery aliases log the **`User-Agent`** header (`copilot-cli/<version>`,
  `codex-mcp-client/<version>`, `claude-code/<version>`). Bodies, codes and tokens are
  still never logged (`infra/modules/mcp-proxy.bicep`, `oauthDiagnostics`).
- `register` traces carry `clientName` and `redirectUris`. `authorize` traces carry
  `redirectUri` and `clientResource`. These are what you need to fix `AADSTS50011`.
- `native-inbound` traces carry `clientAppId` (the token's `azp`), which shows which app
  obtained the token.

Run [`docs/kql/client-signins.kql`](kql/client-signins.kql) a few minutes after a sign-in
(`--param client=codex` filters by User-Agent).

## The regular setup with these clients (what you will see)

Nothing above is applied to the native API. Two sets of results:

- **Plain gateway (reference):** a second API Management instance with only a portal-created
  native MCP server for an organization backed by the user's work tenant, and **nothing from
  this repository** deployed. This is what a customer sees. Tested 2026-11-18 on a Windows
  device that is Microsoft Entra joined to that tenant (`dsregcmd /status`: `AzureAdJoined`,
  `AzureAdPrt: YES`).
- **Lab:** this repository's `ado-mcp-native`, organization in the lab tenant, where the
  device has no account.

| Client | Plain gateway (reference) | Lab | Why |
|---|---|---|---|
| VS Code (GitHub Copilot), own MCP client (`mcp.json`) | ✅ connects, no prompt; 43 tools | ❌ `AADSTS9010010` (2026-11-17, older VS Code; difference not isolated) | VS Code log: PRM from the `401`, Entra metadata found at the OpenID path-appended URL (`…/v2.0/.well-known/openid-configuration`), then a token within ~3 s with no prompt and no `AADSTS9010010`: VS Code's built-in Microsoft account sign-in, which does not send the gateway URL as `resource` (see below). Gateway log: `401` + PRM with User-Agent `Visual Studio Code/1.147.0`, then `200` |
| VS Code, Copilot agent host | ✅ after a chat message | not run | VS Code 1.147 runs MCP servers through its Copilot **agent host** (Copilot CLI runtime; User-Agent `vscode-agent-host/1.147.0`), including servers from Copilot CLI's `~/.copilot/mcp-config.json`. Same sign-in as Copilot CLI. *Start Server* before any chat message fails with *Cannot start an MCP server before the session runtime has been created* (not an auth error) |
| Copilot CLI, interactive | ✅ connects, no prompt | ✅ after an account-broker prompt | Logs: Entra metadata at the path-inserted URLs `404`, then *"Signing in with your Microsoft Entra account (account broker)…"*. Tokens carry the client app `aebc6443-996d-45c2-90f0-388ff96faa56`. No `register` or `authorize` call reaches APIM |
| Copilot CLI, headless `-p` | ✅ `tools/call` worked | ❌ *requires authentication* | The broker gets a token **silently** only for an account the device is signed in with. Without one it needs a prompt, which `-p` cannot show |
| Claude Code (default) | ❌ *Incompatible auth server: does not support dynamic client registration* | ❌ same | Entra has no DCR |
| Claude Code `--client-id` | ❌ browser opens `https://<gateway>/authorize` → `404` | ❌ `AADSTS9010010` (while the lab still served OAuth endpoints at its root) | Claude Code finds no Entra metadata (Entra serves only the OpenID path-appended URL, which Claude Code does not try), falls back to default endpoints on the gateway host, and the plain gateway has none |
| Codex CLI | ❌ *Dynamic registration failed: HTTP 404* | ❌ same | No metadata at the addresses Codex tries; falls back to `POST /register` at the gateway root |
| Standard OAuth client (`tools/mcp_probe.py`) | ❌ `AADSTS9010010` | ❌ same | Sends `resource=<gateway URL>` with the Azure DevOps scope: **the reported error** |
| MCP Inspector | not run | ❌ no DCR, or `AADSTS9010010` with a client ID | As Claude Code |

### Why VS Code and Copilot CLI "work" on the native setup

They are Microsoft's own clients. When the authorization server is Microsoft Entra, they
skip standard MCP OAuth (dynamic registration, RFC 8707 `resource`) and ask Entra for the
**scope** `https://mcp.dev.azure.com/.default` through Microsoft's own sign-in (on Windows the
Web Account Manager broker), as the first-party client `aebc6443-…`. Entra has no gateway
`resource` to reject, so `AADSTS9010010` never happens, and APIM forwards a valid Azure
DevOps token. This does not fix the native setup:

- It works only for these clients. Claude Code, Codex, MCP Inspector and any standard OAuth
  client fail.
- Headless runs (`copilot -p`, automation) work only where the device can get a token
  silently, typically a device joined to the organization's tenant. Elsewhere they fail with
  *requires authentication*.
- The client app is Microsoft's, not one you register, so you cannot manage its redirect URIs,
  consent or conditional access per gateway the way you can with the working setup's public
  client.

A side effect seen on the plain gateway: with no gateway policy, nothing sends
`X-MCP-Readonly`, so the server exposed its **write** tools too (for example
`wit_backlog_write`). Both setups in this repository send it through `mcp-backend-headers`.

Two side observations on the native API:

- Claude Code and Copilot CLI first offer protocol version `2026-07-28`, which the Azure
  DevOps server answers with `400`. Both then fall back to an older version. On the earlier
  HTTP-proxy version of the working setup the `400` passed through. On the native API, APIM
  turned it into `500 ProtocolViolation: Content length mismatch` for Claude Code, and
  `claude mcp list` then reported `ECONNRESET` for the native server. The working setup is
  now the same API type; Claude Code connected through it on 2026-11-18, but the status of
  that first request was not re-checked (*unverified*).
- The first `400` you see per session in the logs is this version negotiation, not an error.

## Related

- [docs/clients/](clients/README.md): setup and test steps per client.
- [POLICIES.md](POLICIES.md): every policy explained element by element.
- [GLOSSARY.md](GLOSSARY.md): PRM, DCR, PKCE, resource indicator, redirect URI, AADSTS codes.
