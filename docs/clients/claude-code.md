# Claude Code

Tested with Claude Code 2.1.322 on Windows (lab, 2026-11-18).

## How it signs in (observed)

| Step | Behaviour |
|---|---|
| Discovery | `POST initialize` → `resource_metadata` from the `401` (`/ado-mcp-proxy/.well-known/oauth-protected-resource/<org>`) → PRM (checks `resource` = server URL) → authorization-server metadata at the path-inserted alias (`/.well-known/oauth-authorization-server/ado-mcp-proxy/oauth`, observed). Without the alias it falls back to the host root and fails |
| Client ID | Dynamic client registration, `client_name` `Claude Code (<server name>)`; or a fixed one with `--client-id` |
| Redirect URI | `http://localhost:<random port>/callback` (Entra registration: `http://localhost/callback`); fixed port with `--callback-port` |
| `resource` | Sends the gateway URL; APIM replaces it |
| Sign-in trigger | `claude mcp login <name>` (needs a real terminal) or `/mcp` in a session |
| Token storage | Credentials file in the Claude config folder (Windows), keychain (macOS) |

## Configure (scoped to a scratch folder)

`-s local` stores the server only for the current folder:

```powershell
New-Item -ItemType Directory -Force "$env:TEMP\ado-mcp\claude" | Out-Null; Set-Location "$env:TEMP\ado-mcp\claude"
claude mcp add --transport http -s local ado-proxy  https://<gateway>/ado-mcp-proxy/<org>
claude mcp add --transport http -s local ado-native https://<gateway>/ado-mcp-native/<org>
# Regular setup with a pre-registered client (registered in the organization's tenant):
claude mcp add --transport http -s local --client-id <public-client-id> ado-native-clientid https://<gateway>/ado-mcp-native/<org>
claude mcp list
```

Expected `claude mcp list` before sign-in:

```text
ado-native: ... (HTTP) - × Failed to connect — Incompatible auth server: does not support dynamic client registration
ado-proxy: ... (HTTP) - ! Needs authentication
ado-native-clientid: ... (HTTP) - ! Needs authentication
```

## Sign in

```powershell
claude mcp login ado-proxy
# Authenticated with "ado-proxy". Its tools are now available in Claude Code.
claude mcp login ado-native-clientid
# The browser opens https://<gateway>/authorize?response_type=code&client_id=...   (no scope, no resource)
# and the gateway answers 404.                                   <- the native setup cannot sign Claude Code in
claude mcp list        # ado-proxy: ✔ Connected
```

`ado-native-clientid` reads the native PRM, which names Entra. Claude Code then looks for
Entra's metadata at the path-inserted URLs, which Entra does not serve (it only serves
`…/<tenant-id>/v2.0/.well-known/openid-configuration`, which Claude Code does not try). It falls
back to default endpoints on the gateway host and opens `https://<gateway>/authorize`, which a
gateway without this repository's OAuth facade answers with `404` (observed 2026-11-18 on a
plain API Management instance). Earlier lab runs reported `AADSTS9010010` instead, while the
lab still served OAuth endpoints at the gateway root. Either way the native setup cannot sign
Claude Code in. `ado-proxy` goes to the gateway's `/ado-mcp-proxy/oauth/authorize`, which
replaces `resource`.

To sign in with a specific browser profile, run `claude mcp login ado-proxy --no-browser`
in a real terminal and open the printed URL yourself (for example
`msedge.exe --profile-directory="<profile>" "<url>"`); the callback completes on its own.

**Claude Code caches the authorization server it discovered.** After a gateway change
(for example the move of the OAuth endpoints from the root to `/ado-mcp-proxy/oauth`), it
kept using the old issuer and opened the removed root `/authorize` (`404`) until signed out:

```powershell
claude mcp logout ado-proxy     # clears tokens and discovery state
claude mcp login ado-proxy
```

Re-verified 2026-11-18 on the current layout (the working setup as an APIM MCP server,
everything under `/ado-mcp-proxy`): `claude mcp list` → `ado-proxy: ... √ Connected` through
the MCP server, and fresh discovery (`claude mcp login ado-proxy --no-browser`) prints an
authorize URL starting with `https://<gateway>/ado-mcp-proxy/oauth/authorize`.

## Test

```powershell
claude -p "Use only the ado-proxy MCP server. Call core_list_projects with no arguments and print the project names." `
  --allowedTools "mcp__ado-proxy__core_list_projects"
```

*Unverified in the lab:* no Claude model was reachable from the lab network, so the agent
run itself was not executed. Sign-in, connection and `tools/list` through the proxy were
verified in the gateway logs. Expect the project names. The gateway does not validate tool
arguments any more ([TOOL-VALIDATION.md](../TOOL-VALIDATION.md)).

## Logs

`python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name> --param client=claude`
shows `register` (`Claude Code (ado-proxy)`, `localhost:<port>/callback`), `authorize`,
`token`, then `proxy-inbound` with your public client as `clientAppId`.

## Known issues

| Symptom | Cause | Fix |
|---|---|---|
| `stdin isn't a terminal` on `claude mcp login --no-browser` | Login needs an interactive terminal | Run it in a normal terminal |
| `ECONNRESET` for the native server in `claude mcp list` | The native API returned `500 ProtocolViolation: Content length mismatch` to the CLI's first protocol-version probe | Seen on the regular setup. The working setup (same API type) connected on 2026-11-18 |
| `AADSTS900144` (scope missing) | Some versions sent no scope ([claude-code#72440](https://github.com/anthropics/claude-code/issues/72440)) | The gateway adds the scope |
| A configured `Authorization` header disables OAuth | By design | Leave headers out for OAuth servers |
| *Dynamic Client Registration rejected (HTTP 404)* on the proxy URL | The gateway's discovery aliases are missing; Claude Code does not try the OpenID path-appended URL and falls back to the host root (observed) | Redeploy with `rootDiscoveryAliases = true` |
| Browser opens `https://<gateway>/authorize` → `404` | Cached authorization server from an older gateway layout | `claude mcp logout <name>`, then `claude mcp login <name>` |

References: [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).
