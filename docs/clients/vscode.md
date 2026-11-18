# VS Code (GitHub Copilot agent mode)

VS Code is the reference client: the reproduction of the reported problem and the first working-setup
validation used it (lab, 2026-11-17). It was not re-run after the working setup became an APIM
MCP server (2026-11-18); the PRM it reads is the same document.

## How it signs in

| Step | Behaviour |
|---|---|
| Discovery | `POST initialize` → `resource_metadata` from the `401` (`/ado-mcp-proxy/.well-known/oauth-protected-resource/<org>` on the working setup) → PRM. VS Code **rejects a PRM whose `resource` differs from the server URL** (RFC 9728 §3.3) |
| Client ID | Dynamic client registration when offered; otherwise asks for a client ID |
| Redirect URI | `http://127.0.0.1:33418/` (desktop) or `https://vscode.dev/redirect` |
| `resource` | Sends the PRM `resource` ([microsoft/vscode#314784](https://github.com/microsoft/vscode/pull/314784)); APIM replaces it on the proxy |

## Configure

Command Palette → **MCP: Open User Configuration**:

```json
{
  "servers": {
    "ado-apim-native": { "type": "http", "url": "https://<gateway>/ado-mcp-native/<org>" },
    "ado-apim-proxy":  { "type": "http", "url": "https://<gateway>/ado-mcp-proxy/<org>" }
  }
}
```

Do not add an `oauth` block or `headers`: APIM adds `X-MCP-Readonly` itself. For several
organizations, add one entry per organization (`…/ado-mcp-proxy/contoso`,
`…/ado-mcp-proxy/fabrikam`); they share the sign-in.

## Sign in and test

1. **MCP: List Servers** → start `ado-apim-proxy` → sign in with an account of the
   organization's tenant.
2. In Copilot Chat (**Agent** mode), ask: *"List the Azure DevOps projects I can access."*
3. Start `ado-apim-native`. Expected: the sign-in fails with `AADSTS9010010`. That is the
   reproduction.
4. Logs: **View → Output → MCP** (or the server's *Show Output*). VS Code logs the PRM URL,
   the authorization server and the error.

Reset stale auth state, for example after redeploying with other paths: **MCP: Reset Cached
Tools**, **MCP: Reset Trust**, **Accounts: Sign Out** for the dynamic provider, then
**Developer: Reload Window**. Renaming the server key forces fresh discovery.

Gateway logs: `python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name>`
lists every client's sign-in steps; the `userAgent` column tells the clients apart.
