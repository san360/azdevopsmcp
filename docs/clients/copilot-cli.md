# GitHub Copilot CLI

Tested with Copilot CLI 1.0.113 on Windows (lab, 2026-11-18).

## How it signs in (observed)

| Step | Behaviour |
|---|---|
| Discovery | `POST initialize` → reads `resource_metadata` and `scope` from the `401` `WWW-Authenticate` header |
| Client ID | Dynamic client registration, `client_name` `GitHub Copilot CLI` |
| Redirect URI | `http://127.0.0.1:<random port>/` (Entra registration: `http://127.0.0.1/`) |
| `resource` | Sends the gateway URL; APIM replaces it ([change 4](../CLIENTS-APIM-CHANGES.md#change-4-authorize-translates-the-resource-name)) |
| Sign-in trigger | Interactive only: `/mcp` → select the server → sign in. `copilot -p` skips servers that still need sign-in (*Browser-based OAuth required*) |
| Token storage | OS credential store (`copilot-mcp-oauth`) |
| Entra as authorization server | When the PRM names Microsoft Entra directly (native URL), Copilot CLI uses its **own Entra account broker** instead of DCR |

## Configure (session-only, nothing written to your settings)

Create a file outside the repository, for example `%TEMP%\ado-mcp\copilot-mcp.json`:

```json
{
  "mcpServers": {
    "ado_proxy":  { "type": "http", "url": "https://<gateway>/ado-mcp-proxy/<org>",  "tools": ["*"] },
    "ado_native": { "type": "http", "url": "https://<gateway>/ado-mcp-native/<org>", "tools": ["*"] }
  }
}
```

Load it with `--additional-mcp-config` (the option goes **before** any subcommand):

```powershell
copilot --additional-mcp-config "@$env:TEMP\ado-mcp\copilot-mcp.json" mcp list   # both servers listed
```

To keep it permanently, use `copilot mcp add --transport http ado_proxy https://<gateway>/ado-mcp-proxy/<org>`
instead (writes `~/.copilot/mcp-config.json`). Do not add an `Authorization` header: that
turns OAuth off.

## Sign in

```powershell
copilot --additional-mcp-config "@$env:TEMP\ado-mcp\copilot-mcp.json"
```

1. Type `/mcp`, select `ado_proxy` and sign in. The browser opens Microsoft Entra **via the
   gateway's `/authorize`**. Sign in with the organization's tenant account.
   Expected: `ado_proxy — connected`.
2. Optional, regular setup: select `ado_native` and sign in. Expected in the lab:
   `Signing in with your Microsoft Entra account (account broker)…` then connected. This is
   Copilot CLI's built-in Entra support, not the gateway (see
   [the regular setup with these clients](../CLIENTS-APIM-CHANGES.md#the-regular-setup-with-these-clients-what-you-will-see)).
3. Ask: *"List the Azure DevOps projects I can access."* Then `/exit`.

## Test headless (after one interactive sign-in)

```powershell
copilot --additional-mcp-config "@$env:TEMP\ado-mcp\copilot-mcp.json" --disable-builtin-mcps `
  -p "Use only the ado_proxy MCP server. Call core_list_projects with no arguments and print the project names. Then call core_list_projects with top set to 500 and print the exact error." `
  --allow-tool ado_proxy
```

Expected (lab):

```text
● core_list_projects  [{"id":"<project-id>","name":"<project>",...
✗ core_list_projects  MCP server 'ado_proxy': Invalid arguments for tool core_list_projects: top violates maximum.
  Rejected by the API gateway before reaching the server.
```

With `ado_native` in `-p` mode the lab returned *MCP server "ado_native" requires
authentication*: the broker sign-in is not reused headless.

## Logs

- Gateway: `python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name> --param client=copilot`.
  You should see `register` with `clientName` `GitHub Copilot CLI` and a `127.0.0.1` redirect,
  then `proxy-inbound` rows with your public client as `clientAppId`.
- Client: `copilot --log-level debug --log-dir <folder> ...` writes discovery and OAuth
  details (`rt_mcp_oauth`, `session_authorizer`).

## Known issues

| Symptom | Cause | Fix |
|---|---|---|
| First authenticated `POST` gets `400` in the logs | The CLI offers protocol `2026-07-28`; the server refuses; the CLI falls back | None needed |
| `AADSTS50011` after sign-in | Redirect URI not registered | Rerun `setup-entra.ps1`, or pin the port: `"auth": { "redirectPort": 33418 }` in the server entry |
| `AADSTS900144` (scope missing) | Older CLI versions sent no scope ([copilot-cli#4582](https://github.com/github/copilot-cli/issues/4582)) | The gateway adds the scope; for direct Entra use `oauthScopes` |
| *issuer does not match* | Metadata `issuer` differs from the URL it was fetched from ([#4584](https://github.com/github/copilot-cli/issues/4584)) | The gateway sets `issuer` from the request URL; check custom domains |

References: [Copilot CLI: add MCP servers](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers),
[CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference).
