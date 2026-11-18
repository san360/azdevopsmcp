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
  (JSON-RPC method, tool, client, session for native MCP APIs).
- **No secrets in logs.** Only an allow-list of headers is logged: `Content-Type`, `Accept`,
  `MCP-Protocol-Version`, `WWW-Authenticate`, `User-Agent`, `traceparent`, `x-mcp-test-run`,
  `X-Correlation-ID` and `x-apim-request-id`. `Authorization`, cookies and
  `Mcp-Session-Id` are never logged. **Response bodies are never logged**, because body
  logging buffers SSE and breaks MCP streaming
  ([expose-existing-mcp-server](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server)).
  The OAuth compatibility API logs only `User-Agent` (no other headers, no bodies), and masks `code`/`state`.
- Every APIM response carries `x-apim-request-id`. That is the `CorrelationId` in Log
  Analytics, and the probe prints it for each step.

## Where to find the calls in Application Insights

APIM writes **each gateway call as request telemetry**, not as a trace. Look in these places:

| Application Insights table (workspace table) | What APIM writes there | Example |
|---|---|---|
| `requests` (`AppRequests`) | One row per call to the gateway: name, URL, status, duration, logged headers/request body. Native MCP calls also carry `gen_ai.operation.name` / `gen_ai.tool.name`. | `POST /ado-mcp-proxy/<org>` 200, `GET /authorize` 302 |
| `dependencies` (`AppDependencies`) | The outbound call APIM made for that request (Azure DevOps MCP, or Entra `/token`). | `POST https://mcp.dev.azure.com/<org>` 200 |
| `traces` (`AppTraces`) | **Only** events emitted by `<trace>` policies. Every API here emits them: `proxy-inbound` (MCP method, organization, user `oid`, client app ID), `tool-validation` (tool, result, violated field and rule), `proxy-outbound`, `prm`, `as-metadata`, `register` (client name, redirect URIs), `authorize` (redirect URI, requested resource), `token`, `token-response`, `native-inbound` (token client app), `native-outbound`. | `proxy inbound: tools/call org=<org> auth=bearer` |
| `exceptions` (`AppExceptions`) | Gateway/policy errors. | — |

In the portal, open **Application Insights → Transaction search** and select the event types
*Request*, *Dependency* and *Trace*. Click a request to see the **end-to-end transaction**:
the request, its dependency and its traces share one `operation_Id` (the W3C trace ID the
probe prints). Data arrives after 2–5 minutes. Without the `<trace>` policies, `traces`
stays empty even though every call is visible under `requests`.

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
| `tool-validation.kql` | Tool-argument validation decisions (tool, field, rule) and proof that rejected calls never reached Azure DevOps |
| `client-signins.kql` | Each MCP client's sign-in, step by step: User-Agent, `register`/`authorize`/`token`, redirect URI, the token's client app |

```powershell
python tools/query_logs.py docs/kql/www-authenticate-rewrite.kql -g <rg> -w log-<apim-name>
```
