# MCP Inspector

[MCP Inspector](https://github.com/modelcontextprotocol/inspector) is the protocol-level
test client. It runs in the browser, so it also needs CORS on the gateway's OAuth endpoints
(the `ado-mcp-oauth-compat` API allows any origin) and the `Origin` header removed on
`/token` (`oauth-token.xml`).

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
