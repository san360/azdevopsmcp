# Tool argument validation (optional, not deployed)

**The lab does not validate tool arguments at the gateway.** Both setups forward
`tools/call` unchanged, and the hosted Azure DevOps MCP server decides what to do with the
arguments. This page explains what an earlier version of the lab did, why it is not on the
current working setup, and how to add argument validation if your organization requires it.

Security teams often require the gateway to check tool arguments against a vetted
manifest (types, ranges, enumerations), the way APIM validates REST payloads. APIM has no
built-in dynamic validation that learns schemas from `tools/list`. Static, curated
validation is possible, but not on an APIM MCP server as it is.

## Status

| | Today |
|---|---|
| Working setup (`/ado-mcp-proxy/<org>`) | No argument validation. `tools/call` reaches Azure DevOps unchanged |
| Regular setup (`/ado-mcp-native/<org>`) | No argument validation |
| What the server does with bad input | It **accepts** `top: "5"` (a string), `top: 500` and unknown properties such as `query` or `wiql`. It reports other mistakes only after it has run the tool |
| Probe | The `validationCases` still run and print `INFO ... not validated at the gateway; server answered ...` for both setups |
| Tool restrictions that are deployed | `X-MCP-Readonly` and `X-MCP-Toolsets` (option C below): they decide which tools exist, not which arguments are allowed |

## Why it is not on the MCP server

- APIM's [`validate-content`](https://learn.microsoft.com/azure/api-management/validate-content-policy)
  policy checks only content types that the **API operation** declares as request
  representations.
- An APIM MCP server (the native pass-through API type that both setups now use) has **no
  operations**. Including `validate-content` in its policy made **every** request fail with
  HTTP 500 (`OperationNotFound`). This was observed on the regular setup; the working setup
  is now the same API type (no operations), so the same applies.
- The working setup was switched to an MCP server so that both setups appear under APIM's
  **MCP servers** and use the same APIM feature. Validation was removed with that change.

## The removed implementation (design of option A)

Until commit `3cc79ae`, the working setup was a plain HTTP API proxy, and it validated two
tools:

| Tool | What the gateway enforced (beyond the server's own schema) |
|---|---|
| `core_list_projects` | `top` integer 1–100, `skip` integer 0–100000, `stateFilter` enum of project states, `continuationToken` ≤ 2048 chars, `orgName` pattern; no other properties |
| `wit_work_item` | `action` required, enum of the 7 read actions; `id`/`workItemId` integers ≥ 1; `ids` 1–200 integers; `top` 1–200; `project` 1–64 chars without reserved characters; `expand`/`type` enums; `fields` names; `asOf` date format; per-action required fields (`get` → `id`, `get_batch` → `ids`, `list_comments`/`list_revisions` → `workItemId`, all except `get`/`get_batch` → `project`, `get_type` → `workItemType`); no other properties |

### How it worked

```text
POST /ado-mcp-proxy/{org}  tools/call  (HTTP API, operation POST /{org} declares application/json)
  └─ proxy-mcp.xml  <include-fragment fragment-id="mcp-tool-validation" />
       1. parse JSON-RPC: method == tools/call?  tool = params.name (case-insensitive)
          JSON-RPC batch (array) → rejected (batching was removed in MCP 2025-06-18)
       2. tool vetted?  → <validate-content action="detect" schema-id="mcp-tool-{tool}">
          not vetted    → pass through (unlistedToolAction=allow) or reject (deny)
       3. errors?      → <trace> tool + field + rule, then <return-response> JSON-RPC error
                         (no forward-request: Azure DevOps never sees the call)
          no errors    → <trace> passed, continue to Azure DevOps
```

- **Schemas** lived in `infra/schemas/tools/<tool>.json`; each described only the tool's
  `arguments`. `modules/mcp-tool-validation.bicep` wrapped each one in a JSON-RPC
  `tools/call` envelope (`jsonrpc` 2.0, `id`, exact `params.name`) and deployed it as an APIM
  **schema resource** (`mcp-tool-core-list-projects`, `mcp-tool-wit-work-item`), referenced
  by `schema-id`.
- **One `choose` branch per tool** selected the schema. `validate-content` cannot pick a
  schema at run time, so Bicep generated the branches from the tool list.
- **`detect` instead of `prevent`.** `prevent` answers with APIM's own
  `400 {"statusCode":400,"message":"Body of the request does not conform…"}`. That is not a
  JSON-RPC response, and it includes the submitted value. `detect` stores the errors in a
  variable. The fragment then turned them into a JSON-RPC answer with only the field name
  and the violated rule.
- **The operation must declare `application/json`.** Without that declaration
  `validate-content` silently skipped every request (or, with `prevent`, rejected all of
  them as "Unspecified content type"). The HTTP proxy declared it on its POST operations.
- **Body-less requests.** OpenAI Codex probes the MCP URL with a body-less `GET`. The
  fragment had to check `context.Request.Body == null` before reading it, or APIM answered
  `500` and Codex stopped.
- Parameters: `toolValidation` (on/off), `unlistedToolAction` (`allow` or `deny`),
  `toolValidationDebug` (lab only: echo raw errors). Output: `validatedTools`.

### Error format (and why)

| Negotiated `MCP-Protocol-Version` | Response | Basis |
|---|---|---|
| `2025-06-18` (what the hosted server negotiates today) | HTTP 200, JSON-RPC error `-32602` *Invalid params* | [2025-06-18 tools spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling): invalid arguments are protocol errors |
| `2025-11-25` or later | HTTP 200, `result.isError: true` with the same text | [2025-11-25 tools spec](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#error-handling): input validation errors are tool execution errors, so the model can correct itself |

HTTP 200 and not 400: under the
[Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#sending-messages-to-the-server),
a server answers a JSON-RPC *request* with a JSON-RPC response. HTTP error statuses are for
input the server cannot accept at all. Every rejection carried the response header
`x-mcp-gateway-validation: rejected` (or `denied`) and echoed the request `id`.

Example (lab, HTTP proxy version):

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

With that version, GitHub Copilot CLI and OpenAI Codex CLI showed this message to the model
verbatim.

### Limitations

- **Static schemas must track the server.** The gateway does not read `tools/list`. When
  Azure DevOps changes a tool, update the JSON file. A stricter gateway schema can reject
  calls the server would accept (intended), and a removed tool simply stops matching.
- **Requests only.** Tool *results* cannot be validated. Reading the streamed response body
  in a policy would buffer SSE and break MCP streaming.
- **APIM logs the raw validation message.** `validate-content` also writes its full error
  text to Application Insights **exceptions** (`ProblemId` `ContentInvalid`), even in
  `detect` mode, and that text can contain submitted values (for example
  `String 'a/b' does not match regex…`). Restrict access to the exceptions table and its
  retention if tool arguments can be sensitive.
- **`deny` does not hide tools from `tools/list`.** Clients still see unvetted tools; their
  calls fail. Pair it with `X-MCP-Toolsets` (the `toolsets` parameter) or an `X-MCP-Tools`
  header to align discovery.
- Bodies over 64 KB were rejected for vetted tools, and the JSON-RPC envelope had to be a
  single object.

## How to add validation

Pick one option. None of them is deployed by this repository.

| Option | Where it runs | Validates arguments | Effort | Tested in this lab |
|---|---|---|---|---|
| A. HTTP API in front with `validate-content` | An HTTP API with operations instead of the MCP server | Yes, against JSON schemas | Medium: code exists in git history | Yes, as the earlier HTTP proxy version |
| B. Policy expressions in the MCP server policy | The MCP server's inbound policy | Yes, hand-written C# rules | High per rule | No |
| C. Tool allow-lists only | The Azure DevOps server, by header | No (which tools, not which arguments) | None: deployed | Yes |

### Option A: an HTTP API with `validate-content` (from git history)

The complete working implementation is in this repository's history at commit `3cc79ae`:

| File at `3cc79ae` | What it holds |
|---|---|
| `infra/modules/mcp-tool-validation.bicep` | Schema resources and the `mcp-tool-validation` fragment, generated per tool |
| `infra/policies/fragments/tool-validation.xml` | The fragment: parse, choose, `validate-content`, JSON-RPC answer |
| `infra/schemas/tools/core_list_projects.json`, `infra/schemas/tools/wit_work_item.json` | The curated argument schemas |
| `infra/modules/mcp-proxy.bicep` | The HTTP proxy API (`type: 'http'`), its operations `POST`/`GET`/`DELETE` on `/` and `/{org}` with an `application/json` request representation on `POST`, and its policy |
| `infra/policies/proxy-mcp.xml` | The HTTP proxy policy: `TOOL_VALIDATION` slot, `<forward-request buffer-response="false">`, `401` challenge rewrite |
| `infra/main.bicep` | Parameters `toolValidation`, `unlistedToolAction`, `toolValidationDebug`; output `validatedTools` |
| `http/03-tool-validation.http`, `docs/kql/tool-validation.kql` | Walkthrough and log query |

Look at them, or restore the files that no longer exist:

```powershell
git show 3cc79ae:infra/policies/fragments/tool-validation.xml
git show 3cc79ae:infra/modules/mcp-proxy.bicep
git checkout 3cc79ae -- infra/modules/mcp-tool-validation.bicep infra/policies/fragments/tool-validation.xml infra/schemas/tools http/03-tool-validation.http docs/kql/tool-validation.kql
```

Do **not** check out `infra/modules/mcp-proxy.bicep`, `infra/policies/proxy-mcp.xml` or
`infra/main.bicep` from `3cc79ae` as a whole. That commit predates the isolation: it mounts
the OAuth API at the gateway root (`ado-mcp-oauth-compat`). Merge by hand instead:

1. In `mcp-proxy.bicep`, replace the MCP server (`type: 'mcp'`) with the HTTP proxy API,
   its operations and policy from `3cc79ae`. Keep the current PRM, OAuth and discovery-alias
   APIs.
2. In `proxy-mcp.xml`, add the `TOOL_VALIDATION` slot, the `<forward-request>` backend and
   the `401` challenge rewrite from `3cc79ae`. An HTTP API does not generate a challenge, so
   the policy must rewrite the origin's. Point it at the current PRM URL
   `https://<gateway>/ado-mcp-proxy/.well-known/oauth-protected-resource[/<org>]` (served by
   `ado-mcp-proxy-prm`). Keep the `Body == null` guard.
3. In `main.bicep`, add the `mcp-tool-validation` module, its parameters and the
   `validatedTools` output, and pass the fragment to the proxy module.
4. An API's type cannot change in place. Delete the MCP server first:
   `az apim api delete -g <rg> -n <apim-name> --api-id ado-mcp-proxy --yes`, then deploy.
5. Set `"toolValidation": "enforced"` on the `apim-proxy` target in
   `tools/probe.local.json` and run the probe: the invalid cases must report
   `gateway JSON-RPC error -32602`.

Trade-off: `/ado-mcp-proxy` is then an **HTTP API with MCP Streamable HTTP operations, not
an APIM MCP server**. It is not listed under *MCP servers*, and the two setups no longer use
the same APIM feature. The combination of the `3cc79ae` HTTP proxy with the current
PRM/OAuth layout was not re-tested.

### Option B: policy expressions in the MCP server policy (not implemented or tested in this lab)

Policy expressions run on MCP servers, because they need no operation. Add a check to the
inbound section of `proxy-mcp.xml` after the organization check: parse the JSON-RPC body,
check `params.name` and `params.arguments` with C# expressions, and answer a violation
yourself with `return-response`. A sketch for one rule (shown unescaped; inside an XML
attribute, write `"` as `&quot;` and `<` as `&lt;`):

```xml
<set-variable name="mcp-violation" value="@{
    JToken body;
    try { body = context.Request.Body?.As<JToken>(preserveContent: true); } catch { return "request:invalid-json"; }
    if (body == null) { return ""; }                          // body-less GET/DELETE
    if (body is JArray) { return "request:batch-not-allowed"; }
    if ((string)body["method"] != "tools/call") { return ""; }
    var tool = ((string)body["params"]?["name"] ?? "").Trim().ToLowerInvariant();
    var args = body["params"]?["arguments"] as JObject ?? new JObject();
    if (tool == "core_list_projects") {
        var top = args["top"];
        if (top != null && top.Type != JTokenType.Integer) { return "top:type"; }
        if (top != null && ((long)top < 1 || (long)top > 100)) { return "top:maximum"; }
    }
    return "";
}" />
<choose>
    <when condition="@((string)context.Variables["mcp-violation"] != "")">
        <return-response>
            <set-status code="200" reason="OK" />
            <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
            <set-body>@{
                var body = context.Request.Body.As<JToken>(preserveContent: true) as JObject;
                var parts = ((string)context.Variables["mcp-violation"]).Split(':');
                return new JObject(
                    new JProperty("jsonrpc", "2.0"),
                    new JProperty("id", body?["id"]),
                    new JProperty("error", new JObject(
                        new JProperty("code", -32602),
                        new JProperty("message", parts[0] + " violates " + parts[1] + ". Rejected by the API gateway.")))).ToString();
            }</set-body>
        </return-response>
    </when>
</choose>
```

Keep in mind:

- Every rule is hand-written C#. There is no schema file and no `validate-content`, so keep
  the rule set small and review it like code.
- Name only the field and the rule in the answer, never the submitted value.
- Read only the **request** body, with `preserveContent: true`, so it can still be forwarded.
  Never read `context.Response.Body`: it would buffer the SSE stream.
- Answer batches and unparsable bodies explicitly, or a batch can hide a call from the check.
- Test on a non-production instance first. APIM's behaviour for `return-response` with a
  JSON-RPC body on an MCP server was not tested in this lab.

### Option C: tool allow-lists only (deployed)

The named values `mcp-readonly` and `mcp-toolsets` (parameters `readOnly` and `toolsets`)
make both setups send `X-MCP-Readonly` and `X-MCP-Toolsets` to the hosted server. The server
then lists and runs only read-only tools, or only the named tool groups. This restricts
**which tools exist**, not their arguments. The server also honours `X-MCP-Tools` (a list of
tool names); add it in the fragment `mcp-backend-headers` if you need a tool-level
allow-list.

## Add a tool (option A)

1. Copy the tool's `inputSchema` from `tools/list` (MCP Inspector **Tools → List Tools**, or the
   raw `tools/list` call in [TESTING.md](TESTING.md#2-curl--powershell-raw-protocol)) into
   `infra/schemas/tools/<tool>.json`. Add `type`, ranges, enums, `required` and
   `"additionalProperties": false`.
2. Add `{ name: '<tool>', arguments: loadJsonContent('../schemas/tools/<tool>.json') }` to
   `tools` in `infra/modules/mcp-tool-validation.bicep`.
3. Add valid and invalid cases to `validationCases` in `tools/probe.local.json`, redeploy,
   run the probe, and check `docs/kql/tool-validation.kql` (restored from `3cc79ae`).
