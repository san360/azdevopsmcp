# Analysis: Azure DevOps MCP behind Azure API Management

Assessment date: 2026-11-17. Live results come from an isolated lab: APIM Developer tier in
West Europe, an Entra-backed Azure DevOps organization, and the hosted Azure DevOps MCP server.

## 1. Problem statement

An enterprise platform team wants Azure API Management (their AI gateway) in front of the
**hosted Azure DevOps MCP server**. They want gateway governance (routing, rate limits,
telemetry, tool restrictions) **and** to keep each user's identity end to end: Azure DevOps
must authorize every call as the signed-in user.

With APIM's native MCP pass-through, interactive sign-in from MCP clients fails. The team
reported this sequence:

1. The origin returns `401` with `WWW-Authenticate: Bearer resource_metadata=…`.
2. APIM rewrites that URL and the PRM `resource` to the gateway frontend URL. It leaves
   `scopes_supported` (Azure DevOps) and `authorization_servers` (Entra) unchanged.
3. The client sends `resource=<gateway URL>` with `scope=<Azure DevOps scope>` to Entra,
   and Entra rejects the pair.

They raised three follow-up questions. First, can APIM proxy the OAuth exchange and strip or
replace `resource`? Second, does Credential Manager help? Its standard pattern yields a
gateway-level token, which loses the user context. Third, can APIM validate `tools/call`
arguments against each tool's `inputSchema`?

## 2. Reproduction and root cause (verified live)

| # | Finding | Evidence |
|---|---|---|
| 1 | Native pass-through rewrites the challenge and the PRM `resource` to the gateway URL and keeps the Azure DevOps scope | `www-authenticate-rewrite.kql`; probe `apim-native` discovery lines |
| 2 | Entra rejects `resource=<gateway URL>` + `scope=https://mcp.dev.azure.com/.default` with **`AADSTS9010010 invalid_target`** before sign-in | Probe `client: Entra authorize request` (XFAIL) |
| 3 | Entra accepts only the Azure DevOps MCP app's identifier URIs as `resource`: `https://mcp.dev.azure.com`, `https://mcp.dev.azure.com/`, `api://2a72489c-aab2-4b65-b93a-a91edccf33b8`, the app ID | Service principal `servicePrincipalNames`; probe `origin-bare` passes |
| 4 | The data plane works through native pass-through. With a valid delegated token, `initialize`, `tools/list` and `tools/call` succeed, and Azure DevOps sees the user | Probe `apim-native` mcp lines |
| 5 | The hosted server's own **organization** PRM has the same mismatch: `resource=https://mcp.dev.azure.com/<org>` gets `AADSTS9010010` from spec-strict clients. The bare URL is consistent | Probe `origin` (XFAIL); public issue [microsoft/azure-devops-mcp#1601](https://github.com/microsoft/azure-devops-mcp/issues/1601) |
| 6 | VS Code checks that PRM `resource` equals the server URL ([RFC 9728 §3.3](https://datatracker.ietf.org/doc/html/rfc9728#section-3.3)) and forwards `resource` to Entra through MSAL (since May 2026) | VS Code source: `src/vs/base/common/oauth.ts` (`fetchResourceMetadata`), `extensions/microsoft-authentication/src/node/flows.ts`, [#314784](https://github.com/microsoft/vscode/pull/314784); open issue [#321249](https://github.com/microsoft/vscode/issues/321249) reports the same error |
| 7 | APIM's rewrite is by design and cannot be overridden by policy (`on-error`/`outbound` `set-header` has no effect) | Public report [Azure-Samples/AI-Gateway#408](https://github.com/Azure-Samples/AI-Gateway/issues/408); Microsoft Learn does not document the rewrite |
| 8 | Native pass-through appends the client path to the backend URL. With the organization in the backend URL, the advertised PRM URL becomes `…/<org>/.well-known/oauth-protected-resource/<org>` → **404**. Use a bare backend with `/<org>` in the client URL | Probe; `backend-url-mapping.kql` |
| 9 | A missing *Azure DevOps MCP* service principal in the tenant makes the hosted server return **500** for every authenticated call | Lab: 500 before `az ad sp create`, 200 after |

**Root cause:** in MCP's OAuth design, the protected resource must be the URL the client
connects to. Entra requires `resource` and `scope` to belong to the same app registration.
The gateway URL cannot be an identifier URI of Microsoft's Azure DevOps MCP app. Any
transparent gateway that publishes its own URL as the resource, while keeping the Azure
DevOps scope, therefore produces an inconsistent pair. The fix must change what Entra
receives as `resource`, or make the gateway a different resource with its own token exchange.

## 3. Reference implementation analysis: [carolga/ado-apim](https://github.com/carolga/ado-apim)

A public reference repository. It deploys APIM with a **plain HTTP API proxy** to
`https://mcp.dev.azure.com/<org>` and an **OAuth compatibility API** on the APIM root path.
It also includes a native-MCP "experiment" for comparison.

How it works:

- **Proxy policy.** HTTPS enforcement, per-IP rate limit, `X-MCP-Readonly`/`X-MCP-Toolsets`,
  removal of spoofable forwarding headers, GUID correlation ID, unbuffered forwarding. On
  `401` it rewrites `WWW-Authenticate` to APIM-hosted metadata.
- **OAuth compatibility.** APIM serves the PRM (`resource=https://mcp.dev.azure.com`,
  `authorization_servers=[gateway]`), authorization-server metadata, a static
  `/register` returning a tenant public client, and `/authorize` and `/token`. Those two
  forward to Entra and **add** `scope` and `resource=https://mcp.dev.azure.com` when missing.
- The user's delegated token (audience Azure DevOps MCP) is forwarded unchanged. Azure DevOps
  authorizes the user.

Assessment:

| Topic | Observation |
|---|---|
| Core idea | Sound: make Entra see an Azure DevOps identifier as `resource`, keep the user's token |
| PRM `resource` | `https://mcp.dev.azure.com` ≠ the proxy URL. VS Code rejects that PRM (RFC 9728) and **falls back** to treating the server origin as the authorization server. That works only because the facade sits on the root path and `/authorize` adds `resource` when missing. It is fragile against client changes |
| This repo's change | PRM `resource` = the client URL, so VS Code accepts it first time. `/authorize` and `/token` **replace** any client `resource` with `https://mcp.dev.azure.com`, so both the PRM path and the fallback path work. `/register` echoes the client's redirect URIs. The data plane uses APIM's native MCP server instead of an HTTP API proxy; a plain API answers the PRM URL that the MCP server advertises, and every route lives under one dedicated path |
| Organizations | The reference fixes one organization in the API `serviceUrl`. This repo uses a bare backend with `/<org>` in the client URL, per-URL PRM, an allow-list and name validation. One deployment serves many organizations, and `tenantId = organizations` is the route to several tenants (needs a multi-tenant public client; not tested in the lab) |
| Native experiment | Configured `mcpProperties.endpoints` as an object with `uriTemplate: /<org>`. APIM ignored it and forwarded to `https://mcp.dev.azure.com/mcp`, so Azure DevOps treated `mcp` as the organization and `tools/call` failed with `VS30063`. Its conclusion that "native MCP does not preserve the delegated token" is not supported. In this lab the token is preserved, and the failure was the backend path. The real native limitation is sign-in (finding 2) |
| Observability | App Insights only, verbosity `error`, no headers. This repo adds Log Analytics resource tables (`ApiManagementGatewayLogs`, `ApiManagementGatewayMCPLog`), a safe header allow-list and request IDs, which is how findings 1 and 8 were proven |
| Validation | Static PowerShell checks only. This repo adds a live probe with expected-failure tracking |

## 4. Options

| Option | Per-user identity at Azure DevOps | Works with VS Code today | Notes |
|---|---|---|---|
| Direct to `https://mcp.dev.azure.com` (bare) | Yes | Yes | No gateway governance. Pass the organization per tool call |
| **Native APIM MCP pass-through** (regular setup) | Yes (data plane) | **No**, sign-in fails `AADSTS9010010` | MCP-aware logs and tool views. PRM rewrite not configurable |
| **APIM MCP server + PRM/OAuth compatibility APIs** (working setup) | **Yes** | **Yes** | Custom OAuth policies under the setup's own path. Shared public client ID. Same API type as the regular setup |
| APIM-owned Entra resource + OBO exchange | Yes (OBO) | Yes, if the client is pre-authorized | Needs an app with an identifier URI equal to the gateway URL (verified custom domain) and a confidential client. APIM has no native OBO policy, so it needs `send-request` to Entra and token caching |
| Credential Manager, managed connection | **No**, one shared identity | Yes (with any inbound auth) | Documented pattern in [Secure access to MCP servers](https://learn.microsoft.com/azure/api-management/secure-mcp-servers). Loses user attribution |
| Credential Manager, user-delegated connections | Partly | No | [`get-authorization-context identity-type="jwt"`](https://learn.microsoft.com/azure/api-management/get-authorization-context-policy) needs a token for audience `https://azure-api.net/authorization-manager` and a per-user consent link. Standard MCP clients cannot do this. Limits: [credentials overview](https://learn.microsoft.com/azure/api-management/credentials-overview) |
| External authorization broker | Yes | Yes | Most control (consent, storage, refresh), but you build and operate it |
| **Azure AI Gateway**, OBO backend (GA 2026-11-17) | **Yes** (native OBO, tested) | **No**: no 401 challenge, PRM or DCR; clients need a pre-acquired gateway token | Federated MCP server with `ado_`-prefixed tools, allow-lists, typed policies; no argument validation, no policy XML. See [AI-GATEWAY.md](AI-GATEWAY.md) |
| Azure AI Gateway, managed identity or API key | **No** | No (key works in a header) | Managed identity is not an Azure DevOps user (`VS30063`); OBO with a key fails (`502`) |
| APIM OAuth facade in front of AI Gateway (not built) | Yes (OBO in AI Gateway) | Expected yes | `/authorize` translates `resource` to `https://ai.gateway.azure.com` (Entra accepts it, tested); one more hop |

**Recommendation.** For VS Code / GitHub Copilot users who must keep per-user identity
through APIM today, use the **working setup** with the hardening in the README. Keep native
pass-through for clients that can be given a token another way, and re-test it when APIM
documents a way to preserve or configure upstream PRM. Do not use Credential Manager if user
attribution is required.

**Tool-schema validation (possible as an optional add-on, not deployed).** APIM has no
built-in *dynamic* validation of `tools/call` arguments against `tools/list` schemas. Static
validation works on an HTTP API: an earlier version of this repo stored a curated JSON schema
per vetted tool as an APIM schema resource, selected it by `params.name` and ran
`validate-content` in `detect` mode. It answered with a JSON-RPC `-32602` (or `isError` for
protocol `2025-11-25`), naming only the field and the violated rule, and never forwarded the
call. Lab findings:
- The hosted server itself **accepts** wrongly typed (`top: "5"`), out-of-range (`top: 500`)
  and unknown arguments (`query`, `wiql`), so a gateway check adds real control.
- `validate-content` only checks content types that the operation declares as request
  representations.
- On MCP servers, which have no operations, the policy makes every request fail with 500.
  Both setups are now MCP servers, so the lab deploys no validation.
- `validate-content` writes its raw message, which can include submitted values, to App
  Insights exceptions.
- Response validation is out of scope, because reading response bodies breaks streaming.

Options: an HTTP API in front with `validate-content` (the earlier implementation),
hand-written policy-expression checks in the MCP server policy, server-side restrictions
(`X-MCP-Readonly`, `X-MCP-Toolsets`, `X-MCP-Tools`), or a validation service behind APIM for
dynamic schemas. Details are in [TOOL-VALIDATION.md](TOOL-VALIDATION.md).

## 5. Facts about the hosted Azure DevOps MCP server

- URL `https://mcp.dev.azure.com/<org>` (or bare, with the organization per tool call). Streamable HTTP, SSE responses, protocol `2025-06-18`, server `AzureDevOps.Mcp`.
- Entra only; PATs are not supported. Entra app *Azure DevOps MCP* `2a72489c-aab2-4b65-b93a-a91edccf33b8`, delegated scope `Ado.Mcp.Tools`, requested as `https://mcp.dev.azure.com/.default`. Classic Azure DevOps tokens (`499b84ac-…`) are not accepted.
- Headers: `X-MCP-Readonly`, `X-MCP-Toolsets`, `X-MCP-Tools`, `X-MCP-Insiders` ([remote server docs](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server)).
- Supported clients per [troubleshooting](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting): VS Code, Visual Studio, Foundry, Copilot Studio, GitHub Copilot (including the CLI and app). Others need DCR, which Entra lacks.
- An Azure CLI token (`az account get-access-token --scope https://mcp.dev.azure.com/.default`) is accepted once the service principal exists. That makes it convenient for tests.

## 6. Client findings (command-line agents, lab 2026-11-18)

Tested with GitHub Copilot CLI 1.0.113, OpenAI Codex CLI 0.167.0 and Claude Code 2.1.322.
The full evidence, with commands and log queries, is in [CLIENTS-APIM-CHANGES.md](CLIENTS-APIM-CHANGES.md)
and [clients/](clients/README.md).

- **All three send RFC 8707 `resource` = the gateway URL**, use DCR when offered, and use PKCE
  S256. The working setup's `resource` translation is required for every one of them.
- **Redirect URIs differ**: Copilot CLI `http://127.0.0.1:<port>/`, Codex
  `http://127.0.0.1:<port>/callback/<id per MCP URL>`, Claude Code `http://localhost:<port>/callback`.
  Entra ignored the port for both `localhost` and `127.0.0.1` registrations. Codex needs one
  registration per MCP URL.
- **Codex probes with a body-less `GET`** before discovery. On the earlier HTTP-proxy
  version, a policy that read the missing body returned `500`, and Codex aborted (*OAuth
  metadata discovery failed*). The MCP server now answers `405` natively; the probe checks it.
- **Native pass-through:** Claude Code fails (no DCR; with a client ID it falls back to the
  gateway's `/authorize`, `404` on a gateway without this repository's facade). Codex fails
  (`POST /register` `404`). VS Code and Copilot CLI connect through Microsoft's own account
  sign-in (account broker) and never send the gateway URL as `resource`; headless Copilot CLI
  works only where the broker signs in silently. These are Microsoft-client features, not a
  fix: confirmed on a second, plain API Management instance with nothing from this
  repository deployed. Any client that uses standard MCP OAuth fails, and the root cause
  stands: Entra rejects the gateway URL as `resource` for the Azure DevOps scope.
- **Version negotiation:** Copilot CLI and Claude Code first offer MCP `2026-07-28`. The server
  answers `400`, and both fall back. The native API turned one such `400` into
  `500 ProtocolViolation: Content length mismatch`; the earlier HTTP proxy passed it through
  unchanged.
- **Tool validation (earlier HTTP-proxy version):** Copilot CLI and Codex surfaced the gateway's `-32602` message to the
  model verbatim.

## 7. Open questions for the product groups

1. APIM: will native MCP pass-through offer a way to keep the upstream PRM (`resource`,
   `resource_metadata`) or override it by policy?
2. APIM: native OBO / user-scoped downstream tokens for MCP backends; timeline?
3. APIM: dynamic `tools/call` argument validation against `tools/list` schemas, and
   `validate-content` (or an equivalent) on native MCP APIs?
4. Azure DevOps: the organization PRM advertises `resource=https://mcp.dev.azure.com/<org>`, which is not an identifier URI of the app. Will the PRM or the app registration be aligned?
5. Azure DevOps: is the `500` for a missing service principal expected? A `401`/`403` with guidance would help.
6. AI Gateway: will MCP endpoints support RFC 9728 discovery (401 challenge with
   `resource_metadata`, PRM, authorization-server metadata) so that VS Code and other MCP
   clients can sign in interactively? Any PRM must use a `resource` Entra accepts with the
   `Data.All` scope (`https://ai.gateway.azure.com`); the gateway URL fails with `AADSTS9010010`.
7. AI Gateway: tool-argument validation against `inputSchema`, and request headers alongside
   OBO (for `X-MCP-Readonly`), today rejected as "token authentication and supplemental headers".
8. AI Gateway: the published 2026-11-01 spec omits `grantType: tokenExchange`, which the service
   requires for OBO.

## Sources

- MCP authorization (2025-06-18): <https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization>
- MCP security best practices: <https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices>
- RFC 9728 (protected-resource metadata): <https://datatracker.ietf.org/doc/html/rfc9728>
- RFC 8707 (resource indicators): <https://datatracker.ietf.org/doc/html/rfc8707>
- RFC 8414 (authorization-server metadata): <https://datatracker.ietf.org/doc/html/rfc8414>
- APIM MCP overview: <https://learn.microsoft.com/azure/api-management/mcp-server-overview>
- Expose an existing MCP server: <https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server>
- Secure access to MCP servers: <https://learn.microsoft.com/azure/api-management/secure-mcp-servers>
- Monitor MCP servers: <https://learn.microsoft.com/azure/api-management/monitor-mcp-servers>
- Manage MCP servers with the REST API: <https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api>
- Credential Manager overview: <https://learn.microsoft.com/azure/api-management/credentials-overview>
- `get-authorization-context` policy: <https://learn.microsoft.com/azure/api-management/get-authorization-context-policy>
- `forward-request` policy (buffering): <https://learn.microsoft.com/azure/api-management/forward-request-policy>
- APIM resource logs (`ApiManagementGatewayMCPLog`): <https://learn.microsoft.com/azure/azure-monitor/reference/tables/apimanagementgatewaymcplog>
- Remote Azure DevOps MCP server: <https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server>
- Remote server troubleshooting: <https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting>
- microsoft/azure-devops-mcp issues [#1601](https://github.com/microsoft/azure-devops-mcp/issues/1601), [#1717](https://github.com/microsoft/azure-devops-mcp/issues/1717), [#1767](https://github.com/microsoft/azure-devops-mcp/issues/1767)
- Azure-Samples/AI-Gateway: [issue #408](https://github.com/Azure-Samples/AI-Gateway/issues/408), [apim-streamable-mcp module](https://github.com/Azure-Samples/AI-Gateway/tree/main/modules/apim-streamable-mcp), [mcp-prm-oauth lab](https://github.com/Azure-Samples/AI-Gateway/tree/main/labs/mcp-prm-oauth), [mcp-client-authorization lab](https://github.com/Azure-Samples/AI-Gateway/tree/main/labs/mcp-client-authorization)
- Reference implementation: <https://github.com/carolga/ado-apim>
- VS Code: [#314784](https://github.com/microsoft/vscode/pull/314784), [#321249](https://github.com/microsoft/vscode/issues/321249)
