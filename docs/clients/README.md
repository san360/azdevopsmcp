# Client guides

Step-by-step setup and test instructions for each MCP client, against both lab URLs:

| Setup | URL | Expected |
|---|---|---|
| Regular (native pass-through) | `https://<gateway>/ado-mcp-native/<org>` | Sign-in fails (the reproduction), except where noted |
| Working (proxy) | `https://<gateway>/ado-mcp-proxy/<org>` | Sign-in and tool calls work |

| Client | Guide | Proxy | Native | Evidence |
|---|---|---|---|---|
| GitHub Copilot CLI 1.0.113 | [copilot-cli.md](copilot-cli.md) | ✅ sign-in, `tools/list`, `tools/call`, validation error shown | ⚠️ connects in interactive mode through its own Entra broker; `-p` reports *requires authentication* | Lab, 2026-11-18 |
| OpenAI Codex CLI 0.167.0 | [codex.md](codex.md) | ✅ sign-in, `tools/call`, validation error shown | ⚠️ connects **only** because the lab's OAuth endpoints are on the same gateway host | Lab, 2026-11-18 |
| Claude Code 2.1.322 | [claude-code.md](claude-code.md) | ✅ sign-in, connected, `tools/list` | ❌ *no DCR*; with `--client-id` ❌ `AADSTS9010010` | Lab, 2026-11-18. Agent `tools/call` not run (no model reachable from the lab) |
| VS Code (GitHub Copilot agent mode) | [vscode.md](vscode.md) | ✅ | ❌ `AADSTS9010010` | Lab, 2026-11-17 |
| MCP Inspector | [mcp-inspector.md](mcp-inspector.md) | ✅ | ❌ *no DCR*, or `AADSTS9010010` with a client ID | Lab, 2026-11-17 |

Why each client behaves this way, and what APIM changes make the working setup work for it:
[CLIENTS-APIM-CHANGES.md](../CLIENTS-APIM-CHANGES.md).

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

> List the Azure DevOps projects I can access. Then call core_list_projects with top set to
> 500 and show me the exact error.

The first part proves sign-in and `tools/call`. The second part shows the gateway's
[tool argument validation](../TOOL-VALIDATION.md): on the proxy the agent receives
`Invalid arguments for tool core_list_projects: top violates maximum. Rejected by the API
gateway before reaching the server.` On the native URL, the server accepts `top: 500`.
