# Client guides

Step-by-step setup and test instructions for each MCP client, against both lab URLs:

| Setup | URL | Expected |
|---|---|---|
| Regular (native pass-through) | `https://<gateway>/ado-mcp-native/<org>` | Sign-in fails (the reproduction), except where noted |
| Working (MCP server + PRM/OAuth compatibility APIs) | `https://<gateway>/ado-mcp-proxy/<org>` | Sign-in and tool calls work |

| Client | Guide | Proxy | Native | Evidence |
|---|---|---|---|---|
| GitHub Copilot CLI 1.0.113 | [copilot-cli.md](copilot-cli.md) | ✅ sign-in, `tools/list`, `tools/call` | ⚠️ connects through its Entra account broker; `-p` works only where the broker signs in silently (device joined to the tenant), else *requires authentication* | Lab, 2026-11-18. Re-verified with 1.0.114 on the current layout (MCP server): `/mcp` sign-in, then `copilot -p` called `core_list_projects`. Native on a plain gateway (device-joined tenant): interactive and `-p` both worked, 2026-11-18 |
| OpenAI Codex CLI 0.167.0 | [codex.md](codex.md) | ✅ sign-in, `tools/call` | ❌ *Dynamic registration failed: HTTP 404* | Lab and plain gateway, 2026-11-18. Sign-in re-verified on the current layout (`Auth: OAuth`; fresh discovery reaches `/ado-mcp-proxy/oauth/authorize`); `tools/call` was verified on the earlier HTTP-proxy layout |
| Claude Code 2.1.322 | [claude-code.md](claude-code.md) | ✅ sign-in, connected, `tools/list` | ❌ *no DCR*; with `--client-id` the browser opens `<gateway>/authorize` → `404` | Lab and plain gateway, 2026-11-18. Re-verified on the current layout: `claude mcp list` → connected; fresh discovery reaches `/ado-mcp-proxy/oauth/authorize` (needed `claude mcp logout` first). Agent `tools/call` not run (no model reachable from the lab) |
| VS Code (GitHub Copilot agent mode) | [vscode.md](vscode.md) | ✅ | ⚠️ built-in Microsoft account sign-in when VS Code has a session for the tenant; else ❌ `AADSTS9010010` | Lab, 2026-11-17 (❌); plain gateway with a device-joined tenant, VS Code 1.147, 2026-11-18 (connected; VS Code log and gateway log). Proxy not re-run on the current layout |
| MCP Inspector | [mcp-inspector.md](mcp-inspector.md) | ✅ | ❌ *no DCR*, or `AADSTS9010010` with a client ID | Lab, 2026-11-17; not re-run on the current layout |

Why each client behaves this way, and what APIM changes make the working setup work for it:
[CLIENTS-APIM-CHANGES.md](../CLIENTS-APIM-CHANGES.md).

**Behind Application Gateway** (custom domain, APIM in internal mode,
[APP-GATEWAY.md](../APP-GATEWAY.md)): use `https://<host>/ado-mcp-proxy/<org>` and
`https://<host>/ado-mcp-native/<org>` in place of the gateway URLs, and register the Codex
redirect URIs for them (`setup-entra.ps1 -McpUrl`). Verified so far: OpenAI Codex CLI signs
in to the working setup; on the regular setup it fails with *OAuth metadata discovery failed
... 502* instead of *registration 404* (App Gateway answers unrouted root paths). VS Code,
Copilot CLI, Claude Code and MCP Inspector through App Gateway are **pending** (manual runs).

## Before you start (all clients)

1. The lab is deployed ([GETTING-STARTED.md](../GETTING-STARTED.md)).
2. The Entra public client lists each client's redirect URI. `scripts/setup-entra.ps1`
   registers all of them; for Codex pass every MCP URL with `-McpUrl` (the redirect path
   depends on the URL):

   ```powershell
   ./scripts/setup-entra.ps1 -TenantId <tenant-id> -GrantAdminConsent `
     -McpUrl https://<gateway>/ado-mcp-proxy/<org>, https://<gateway>/ado-mcp-native/<org>
   ```

   Add `-AppName <name>` only if your public client exists under another name than the
   default `ado-mcp-apim-client`; otherwise the script creates a new app. Rerunning keeps
   redirect URIs that are already registered.
3. Sign in with an account of the tenant that backs the Azure DevOps organization.
4. Keep test configuration out of your normal setup. Each guide shows how to use a scratch
   folder or a session-only config. Never commit client config files with real URLs.

## Verify any client in the logs

Run this 2–5 minutes after a sign-in or a tool call:

```powershell
python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name> --param client=copilot   # or codex, claude
```

Each row is one policy trace of a gateway request, with the client's `User-Agent`, the sign-in step
(`prm`, `as-metadata`, `register`, `authorize`, `token`, `proxy-inbound`, `native-inbound`),
the `client_name` and redirect URI it registered, and the client app (`azp`) of the token it
then used. See [OBSERVABILITY.md](../OBSERVABILITY.md) for the tables behind it.

## A good first prompt

> List the Azure DevOps projects I can access.

It proves sign-in and `tools/call`. Earlier versions of these guides also asked for
`core_list_projects` with `top` set to 500 and showed the gateway's validation error. That
error is no longer expected: the gateway does not validate tool arguments, and the server
accepts `top: 500` and returns projects, on both setups
([TOOL-VALIDATION.md](../TOOL-VALIDATION.md)).
