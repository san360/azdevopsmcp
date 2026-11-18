# Tool argument validation (working setup)

The gateway checks the arguments of selected MCP tools before the call reaches Azure DevOps.
This page explains the design, the error format, the limits, and how to add a tool. Test steps
are in [TESTING.md](TESTING.md#5-tool-argument-validation-working-setup); the policy is walked
through element by element in [POLICIES.md](POLICIES.md).

Security teams often require the gateway to check tool arguments against a vetted
manifest (types, ranges, enumerations), the way APIM validates REST payloads. APIM has no
built-in dynamic validation that learns schemas from `tools/list`. This repository
implements **static, curated validation** for two tools on the working setup.

| Tool | What the gateway enforces (beyond the server's own schema) |
|---|---|
| `core_list_projects` | `top` integer 1–100, `skip` integer 0–100000, `stateFilter` enum of project states, `continuationToken` ≤ 2048 chars, `orgName` pattern; no other properties |
| `wit_work_item` | `action` required, enum of the 7 read actions; `id`/`workItemId` integers ≥ 1; `ids` 1–200 integers; `top` 1–200; `project` 1–64 chars without reserved characters; `expand`/`type` enums; `fields` names; `asOf` date format; per-action required fields (`get` → `id`, `get_batch` → `ids`, `list_comments`/`list_revisions` → `workItemId`, all except `get`/`get_batch` → `project`, `get_type` → `workItemType`); no other properties |

Why it matters, measured in the lab: **without the gateway, the server accepts** `top: "5"`
(a string), `top: 500`, and unknown properties such as `query` or `wiql`. It only reports
other mistakes after it has already run the tool.

## How it works

```text
POST /ado-mcp-proxy/{org}  tools/call  (body readable: request bodies are buffered, responses are not)
  └─ proxy-mcp.xml  <include-fragment fragment-id="mcp-tool-validation" />
       1. parse JSON-RPC: method == tools/call?  tool = params.name (case-insensitive)
          JSON-RPC batch (array) → rejected (batching was removed in MCP 2025-06-18)
       2. tool vetted?  → <validate-content action="detect" schema-id="mcp-tool-{tool}">
          not vetted    → pass through (unlistedToolAction=allow) or reject (deny)
       3. errors?      → <trace> tool + field + rule, then <return-response> JSON-RPC error
                         (no forward-request: Azure DevOps never sees the call)
          no errors    → <trace> passed, continue to Azure DevOps
```

- **Schemas** live in `infra/schemas/tools/<tool>.json`; each describes only the tool's
  `arguments`. `modules/mcp-tool-validation.bicep` wraps each one in a JSON-RPC `tools/call`
  envelope (`jsonrpc` 2.0, `id`, exact `params.name`) and deploys it as an APIM **schema
  resource** (`Microsoft.ApiManagement/service/schemas`), referenced by `schema-id`.
- **One `choose` branch per tool** selects the schema. `validate-content` can't pick a
  schema dynamically, so Bicep generates the branches from the tool list.
- **`detect` instead of `prevent`.** `prevent` would answer with APIM's own
  `400 {"statusCode":400,"message":"Body of the request does not conform…"}`. That is not a
  JSON-RPC response, and it includes the submitted value. `detect` stores the errors in a
  variable. The fragment then turns them into a JSON-RPC answer containing only the field
  name and the violated rule.
- **The operation must declare `application/json`.** `validate-content` only checks content
  types listed in the operation's request representations. Without that declaration it
  silently skipped every request (or, with `prevent`, rejected all of them as
  "Unspecified content type"). `mcp-proxy.bicep` declares it on the POST operations.

## Error format (and why)

| Negotiated `MCP-Protocol-Version` | Response | Basis |
|---|---|---|
| `2025-06-18` (what the hosted server negotiates today) | HTTP 200, JSON-RPC error `-32602` *Invalid params* | [2025-06-18 tools spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling): invalid arguments are protocol errors |
| `2025-11-25` or later | HTTP 200, `result.isError: true` with the same text | [2025-11-25 tools spec](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#error-handling): input validation errors are tool execution errors, so the model can correct itself |

HTTP 200 and not 400: under the
[Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#sending-messages-to-the-server),
a server answers a JSON-RPC *request* with a JSON-RPC response. HTTP error statuses are for
input the server cannot accept at all. Every rejection carries the response header
`x-mcp-gateway-validation: rejected` (or `denied`) and echoes the request `id`.

Example (lab):

```http
POST https://<gateway>/ado-mcp-proxy/<org>
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"core_list_projects","arguments":{"top":"5","query":1}}}

HTTP/1.1 200 OK
Content-Type: application/json
x-mcp-gateway-validation: rejected

{"jsonrpc":"2.0","id":11,"error":{"code":-32602,
 "message":"Invalid arguments for tool core_list_projects: top violates type; query violates additionalProperties. Rejected by the API gateway before reaching the server.",
 "data":{"tool":"core_list_projects","violations":[{"field":"top","rule":"type"},{"field":"query","rule":"additionalProperties"}],"source":"api-gateway"}}}
```

## Limitations

- **Static schemas must track the server.** The gateway does not read `tools/list`. When
  Azure DevOps changes a tool, update the JSON file. A stricter gateway schema can reject
  calls the server would accept (intended), and a removed tool simply stops matching.
- **Requests only.** Tool *results* are not validated. Reading the streamed response body
  in a policy would buffer SSE and break MCP streaming.
- **Not on the native MCP API.** Native pass-through APIs have no operations, so they have
  no request representations. Including `validate-content` there made **every** native
  request fail with HTTP 500 (`OperationNotFound`). The regular setup is therefore left
  without validation. The probe records what the server does with the same invalid input
  (`INFO` lines).
- **APIM logs the raw validation message.** `validate-content` also writes its full error
  text to Application Insights **exceptions** (`ProblemId` `ContentInvalid`), even in
  `detect` mode, and that text can contain submitted values (for example
  `String 'a/b' does not match regex…`). This repository's traces and responses carry only
  field and rule. Restrict access to the exceptions table and its retention if tool
  arguments can be sensitive.
- **`deny` does not hide tools from `tools/list`.** Clients still see unvetted tools; their
  calls fail. Pair it with `X-MCP-Toolsets` (the `toolsets` parameter) or an `X-MCP-Tools` header (add it in `proxy-mcp.xml`) to align discovery.
- Bodies over 64 KB are rejected for vetted tools, and the JSON-RPC envelope must be a
  single object.

## Add a tool

1. Copy the tool's `inputSchema` from `tools/list` (MCP Inspector **Tools → List Tools**, or the
   raw `tools/list` call in [TESTING.md](TESTING.md#2-curl--powershell-raw-protocol)) into `infra/schemas/tools/<tool>.json`. Add `type`, ranges, enums, `required`
   and `"additionalProperties": false`.
2. Add `{ name: '<tool>', arguments: loadJsonContent('../schemas/tools/<tool>.json') }` to
   `tools` in `infra/modules/mcp-tool-validation.bicep`.
3. Add valid and invalid cases to `validationCases` in `tools/probe.local.json`, redeploy,
   run the probe, and check `docs/kql/tool-validation.kql`.
