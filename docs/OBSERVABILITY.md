# Observability

Where every gateway call, policy decision and sign-in step ends up, and how to query it.
Every query file is in [docs/kql](kql/) and runs with
`python tools/query_logs.py docs/kql/<file>.kql -g <rg> -w log-<apim-name>`, or pasted into
**Application Insights → Logs** / **Log Analytics → Logs**. Allow 2–5 minutes for ingestion.

## What is deployed

Deployed by `modules/monitoring.bicep` and `modules/apim-observability.bicep`:

- **Application Insights logger** and service-wide diagnostics (W3C correlation, 100 % sampling, errors always logged).
- **Diagnostic settings** to Log Analytics, resource-specific tables: `ApiManagementGatewayLogs`
  (every request, including backend URL and headers) and `ApiManagementGatewayMCPLog`
  (JSON-RPC method, tool, client, session for native MCP APIs; both setups are APIM MCP servers).
- **No secrets in logs.** Only an allow-list of headers is logged: `Content-Type`, `Accept`,
  `MCP-Protocol-Version`, `WWW-Authenticate`, `User-Agent`, `traceparent`, `x-mcp-test-run`,
  `X-Correlation-ID` and `x-apim-request-id`. `Authorization`, cookies and
  `Mcp-Session-Id` are never logged. **Response bodies are never logged**, because body
  logging buffers SSE and breaks MCP streaming
  ([expose-existing-mcp-server](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server)).
  The OAuth, PRM and discovery-alias APIs log only `User-Agent` (no other headers, no bodies), and mask `code`/`state`.
- Every APIM response carries `x-apim-request-id`. That is the `CorrelationId` in Log
  Analytics, and the probe prints it for each step.

## Where to find the calls in Application Insights

APIM writes **each gateway call as request telemetry**, not as a trace. Look in these places:

| Application Insights table (workspace table) | What APIM writes there | Example |
|---|---|---|
| `requests` (`AppRequests`) | One row per call to the gateway: name, URL, status, duration, logged headers/request body. Native MCP calls also carry `gen_ai.operation.name` / `gen_ai.tool.name`. | `POST /ado-mcp-proxy/<org>` 200, `GET /ado-mcp-proxy/oauth/authorize` 302 |
| `dependencies` (`AppDependencies`) | The outbound call APIM made for that request (Azure DevOps MCP, or Entra `/token`). | `POST https://mcp.dev.azure.com/<org>` 200 |
| `traces` (`AppTraces`) | **Only** events emitted by `<trace>` policies. Every API here emits them: `proxy-inbound` (MCP method, organization, user `oid`, client app ID), `proxy-outbound`, `prm`, `as-metadata`, `register` (client name, redirect URIs), `authorize` (redirect URI, requested resource), `token`, `token-response`, `native-inbound` (token client app), `native-outbound`. | `proxy inbound: tools/call org=<org> auth=bearer` |
| `exceptions` (`AppExceptions`) | Gateway/policy errors. | — |

In the portal, open **Application Insights → Transaction search** and select the event types
*Request*, *Dependency* and *Trace*. Click a request to see the **end-to-end transaction**:
the request, its dependency and its traces share one `operation_Id`. Data arrives after
2–5 minutes. Without the `<trace>` policies, `traces` stays empty even though every call is
visible under `requests`.

### Why a session shows up as many separate transactions

This is expected. Application Insights groups telemetry by **operation** (`operation_Id`, the
W3C trace ID). APIM starts a new operation for every incoming HTTP call unless the caller
sends a `traceparent` header. MCP clients (VS Code, Copilot CLI, Codex, Claude Code) send
none, and the Azure DevOps MCP server issues no `Mcp-Session-Id`. So each sign-in step
(`401`, PRM, metadata, `register`, `authorize`, `token`) and each MCP message (`initialize`,
`tools/list`, `tools/call`, ...) is its own end-to-end transaction. Inside each one,
correlation is complete (verified in the lab): request → dependency (`mcp.dev.azure.com` or
Entra `/token`) → its policy traces.

| You want to see | Use |
|---|---|
| One call in full (request, backend call, policy steps) | Transaction search → click the request (end-to-end transaction) |
| A whole client session as one timeline (sign-in, then every MCP message, with user, client app and backend status) | [`session-timeline.kql`](kql/session-timeline.kql) `--param client=copilot` (or `codex`, `claude`, `Bun`, `vscode`; `--param user-oid=<oid>` for one user) |
| One probe run as one transaction | The probe sends a `traceparent` on its MCP calls, so all MCP-server calls of a run share one `operation_Id`: [`requests-by-run.kql`](kql/requests-by-run.kql). Its discovery and OAuth requests are separate operations |

Sign-in steps before the token carry no user (`oid` is empty until the client has a
token), so follow them by client (User-Agent) and the MCP calls after sign-in by user.
Claude Code sends its OAuth requests with the User-Agent `Bun/<version>` and its MCP calls
with `claude-code/<version>`.

The user is recorded only as the pseudonymous Entra object ID (`oid`) plus the client app
ID, never as a name, token or UPN.

| Query (`docs/kql/`) | Shows |
|---|---|
| `requests-by-run.kql` | All requests of one probe run (App Insights) |
| `gateway-by-request-id.kql` | One request in full: backend URL, headers, timings, errors |
| `www-authenticate-rewrite.kql` | Origin challenge next to the challenge APIM returned (the rewrite) |
| `backend-url-mapping.kql` | Gateway URL → backend URL per API (path mapping mistakes) |
| `mcp-methods.kql` | JSON-RPC methods, tools, clients (native MCP log) |
| `mcp-calls-app-insights.kql` | Calls, failures and p95 latency per MCP method/tool |
| `errors.kql` | Failures with the APIM pipeline stage that raised them |
| `auth-summary.kql` | Requests per API, auth type and status |
| `policy-traces.kql` | `<trace>` policy events (MCP method, organization, user oid, OAuth steps) with their request |
| `client-signins.kql` | Each MCP client's sign-in, step by step: User-Agent, `register`/`authorize`/`token`, redirect URI, the token's client app |
| `session-timeline.kql` | One client's (or user's) whole session as a single timeline across the separate transactions |

```powershell
python tools/query_logs.py docs/kql/www-authenticate-rewrite.kql -g <rg> -w log-<apim-name>
```
