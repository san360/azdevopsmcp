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
| Entra as authorization server | On the native URL the PRM names Microsoft Entra. VS Code 1.147 finds Entra's metadata at the OpenID path-appended URL and signs in with its built-in **Microsoft account** sign-in instead of standard MCP OAuth, without the gateway `resource`. On a plain API Management instance with an organization in the device's own work tenant, the native server connected with no prompt (2026-11-18, VS Code log and gateway log). In the lab (organization in another tenant, earlier VS Code) it failed with `AADSTS9010010` (2026-11-17) |
| Who runs the server | VS Code 1.147 runs MCP servers through its Copilot **agent host** (Copilot CLI runtime, User-Agent `vscode-agent-host/<version>`) as well as its own client (User-Agent `Visual Studio Code/<version>`, or another extension's if one overrides it). The agent host also loads Copilot CLI's `~/.copilot/mcp-config.json` |

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

**Servers you did not add here.** VS Code's Copilot agent host also loads GitHub Copilot
CLI's `~/.copilot/mcp-config.json` (observed 2026-11-18 with VS Code 1.147: a server added
only with `copilot mcp add` appeared in VS Code's MCP list under the same name, run by the
agent host). The definition is shared; each run still signs in on its own. For an isolated
test, define the server in VS Code's `mcp.json` under its own name.

## Sign in and test

1. **MCP: List Servers** → start `ado-apim-proxy` → sign in with an account of the
   organization's tenant.
2. In Copilot Chat (**Agent** mode), ask: *"List the Azure DevOps projects I can access."*
3. Start `ado-apim-native`. Expected in the lab: the sign-in fails with `AADSTS9010010`. That
   is the reproduction. If VS Code already has a Microsoft account session for the
   organization's tenant (typically your work account on a joined device), it may connect
   instead through its built-in Microsoft sign-in: Microsoft's own client, not a fix of the
   native setup ([why](../CLIENTS-APIM-CHANGES.md#why-vs-code-and-copilot-cli-work-on-the-native-setup)).
   To reproduce the failure anyway, use an organization in another tenant, or a clean
   profile (`code --user-data-dir <temp folder>`) and sign out of that account.
4. Logs: **View → Output → MCP** (or the server's *Show Output*). VS Code logs the PRM URL,
   the authorization server and the error.

Reset stale auth state, for example after redeploying with other paths: **MCP: Reset Cached
Tools**, **MCP: Reset Trust**, **Accounts: Sign Out** for the dynamic provider, then
**Developer: Reload Window**. Renaming the server key forces fresh discovery.

Gateway logs: `python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name>`
lists every client's sign-in steps; the `userAgent` column tells the clients apart.

## Observed on the native setup (plain gateway, 2026-11-18)

VS Code's own MCP log for a native server (organization in the device's work tenant):

```text
[info] Discovered resource metadata at https://<gateway>/ado-mcp-native/.well-known/oauth-protected-resource/<org>
[info] Using auth server metadata url: https://login.microsoftonline.com/<tenant-id>/v2.0
[warning] Error fetching authorization server metadata: ... /.well-known/oauth-authorization-server/<tenant-id>/v2.0: 404
[warning] Error fetching authorization server metadata: ... /.well-known/openid-configuration/<tenant-id>/v2.0: 404
[info] Discovered authorization server metadata at https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration
[info] Waiting for server to respond to `initialize` request...
[info] Discovered 43 tools
```

No prompt and no `AADSTS9010010`: VS Code signed in with the Microsoft account it already
had. This is a Microsoft-client feature, not a fix of the native setup
([why](../CLIENTS-APIM-CHANGES.md#why-vs-code-and-copilot-cli-work-on-the-native-setup)). The
43 tools include write tools, because a gateway without this repository's policies sends no
`X-MCP-Readonly`.

## Known issues

| Symptom | Cause | Fix |
|---|---|---|
| `Server '<name>' failed: Cannot start an MCP server before the session runtime has been created. Send a message first.` | The server runs in VS Code's Copilot agent host, which starts servers only once a chat session exists | Send a chat message (Agent mode) first; not an authentication error |
| A server you never added to VS Code appears in its MCP list | The agent host loads Copilot CLI's `~/.copilot/mcp-config.json` | Use distinct names per client, or remove it from Copilot CLI's config |
