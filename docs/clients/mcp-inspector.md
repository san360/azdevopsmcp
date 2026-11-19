# MCP Inspector

[MCP Inspector](https://github.com/modelcontextprotocol/inspector) is the protocol-level
test client. It runs in the browser, so it also needs CORS on the gateway's OAuth endpoints
(the `ado-mcp-proxy-prm` and `ado-mcp-proxy-oauth` APIs and the discovery aliases allow any
origin) and the `Origin` header removed on `/token` (`oauth-token.xml`). Tested in the lab on
2026-11-17, and re-run on 2026-11-18 with Inspector 2.14.0 against the APIM MCP server layout
on the plain gateway, after clearing stale OAuth state (see
[Start with fresh OAuth state](#start-with-fresh-oauth-state)).

```powershell
npx @modelcontextprotocol/inspector     # npm 12 may need: $env:npm_config_allow_remote='all'
```

## UI with OAuth

**Working setup:** Transport *Streamable HTTP*, URL `https://<gateway>/ado-mcp-proxy/<org>`,
then **Connect**. Inspector calls the gateway's `/register` and redirects to Entra. After
sign-in, use **Tools → List Tools → core_list_projects**. Its redirect URIs are
`http://localhost:6274/oauth/callback` (and `/debug`), or the `127.0.0.1` variants when the
UI was opened on `127.0.0.1`. `setup-entra.ps1` registers all four. A missing one gives
`AADSTS50011` after sign-in.

**Regular setup:** URL `https://<gateway>/ado-mcp-native/<org>`. Expected: *"Incompatible
auth server: does not support dynamic client registration"*, because Entra has no DCR. If
you enter the public client ID under the auth settings, sign-in reaches Entra and fails with
`AADSTS9010010`.

## UI or CLI with a bearer token (data plane only, both setups)

```powershell
$env:npm_config_loglevel = 'warn'   # otherwise npx echoes the command line, including the token
$t = az account get-access-token --scope https://mcp.dev.azure.com/.default --query accessToken -o tsv
npx @modelcontextprotocol/inspector --cli https://<gateway>/ado-mcp-proxy/<org> --transport http `
  --header "Authorization: Bearer $t" --method tools/list
npx @modelcontextprotocol/inspector --cli https://<gateway>/ado-mcp-native/<org> --transport http `
  --header "Authorization: Bearer $t" --method tools/call --tool-name core_list_projects --tool-arg top=5
```

In the UI, paste the token under **Authentication → Bearer Token** instead.

## Start with fresh OAuth state

Inspector 2.x remembers, per server URL, what OAuth discovery returned (issuer,
`authorization_endpoint`, `token_endpoint`), the registered client and the tokens. It keeps
that in `~/.mcp-inspector/storage/oauth.json` (tokens in the OS keychain by default) and
reuses it on the next **Connect** without fetching the metadata again. After the gateway's
OAuth endpoints move, it keeps sending the browser to the old ones.

**Symptom seen in the lab:** after the OAuth endpoints moved from the gateway root to
`/ado-mcp-proxy/oauth`, connecting to `https://<gateway>/ado-mcp-proxy/<org>` gave
*404 Resource not found*. The MCP server returned the expected `401` and the metadata was
correct, but the browser went straight to the old `GET https://<gateway>/authorize`.
`ApiManagementGatewayLogs` shows that request with an empty `ApiId` and
`LastErrorReason = OperationNotFound`, and no `/.well-known/...` requests before it.

Pick one of these:

**Clear one server in the UI.** Select the server and use **Clear stored OAuth state** (or
**Clear OAuth state and disconnect**), then **Connect** again.

**Fresh state on every run (recommended for gateway testing).** Point Inspector at a
throw-away storage folder and keep secrets in memory only. Set the variables in the shell
that starts Inspector; they apply only to that process.

```powershell
$env:MCP_STORAGE_DIR = Join-Path $env:TEMP "mcp-inspector-$(New-Guid)"   # oauth.json goes here
$env:MCP_INSPECTOR_SECRET_STORE = 'memory'   # tokens are never written to disk or keychain
$env:npm_config_loglevel = 'warn'
try { npx -y @modelcontextprotocol/inspector }
finally { Remove-Item -Recurse -Force $env:MCP_STORAGE_DIR -ErrorAction SilentlyContinue }
```

On start Inspector prints *Secrets: Memory (this session only)*. Every **Connect** then runs
discovery, `/register`, and sign-in from scratch. The saved server list
(`~/.mcp-inspector/mcp.json`) is not affected. Keep the default port 6274
(`CLIENT_PORT`): the redirect URIs that `setup-entra.ps1` registers use it, and another
port gives `AADSTS50011` after sign-in.

**Remove stale entries from the default store.** Stop Inspector first. The keys under
`servers` are the exact URLs you connected to.

```powershell
$f = "$env:USERPROFILE\.mcp-inspector\storage\oauth.json"; Copy-Item $f "$f.bak"
$j = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable
$j.servers.Keys                                   # list the cached server URLs
$j.servers.Remove('https://<gateway>/ado-mcp-proxy/<org>')
$j | ConvertTo-Json -Depth 50 | Set-Content $f
```

Deleting `~/.mcp-inspector/storage` clears every server at once.

**Inspector version.** `npx` reuses the copy cached in the npm cache (`_npx`). Use
`@modelcontextprotocol/inspector@latest` to pick up a new release, or pin a version (for
example `@2.14.0`) for repeatable runs. The package cache does not hold OAuth state; clearing
it does not fix the stale endpoints above.
