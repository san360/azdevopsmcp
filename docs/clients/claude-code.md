# Claude Code

Tested with Claude Code 2.1.322 on Windows (lab, 2026-11-18).

## How it signs in (observed)

| Step | Behaviour |
|---|---|
| Discovery | `POST initialize` → `resource_metadata` from the `401` → PRM (checks `resource` = server URL) → authorization-server metadata |
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
# Regular setup with a pre-registered client, to reach Entra and reproduce AADSTS9010010:
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
# Couldn't complete authentication for "ado-native-clientid": AADSTS9010010: The resource parameter provided
# in the request doesn't match with the requested scopes.        <- the reproduction
claude mcp list        # ado-proxy: ✔ Connected
```

`ado-native-clientid` goes straight to Entra
(`login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize`) with
`resource=https://<gateway>/ado-mcp-native/<org>`, and Entra rejects it. `ado-proxy` goes
to the gateway's `/authorize`, which replaces `resource`.

## Test

```powershell
claude -p "Use only the ado-proxy MCP server. Call core_list_projects with no arguments and print the project names. Then call core_list_projects with top set to 500 and print the exact error." `
  --allowedTools "mcp__ado-proxy__core_list_projects"
```

*Unverified in the lab:* no Claude model was reachable from the lab network, so the agent
run itself was not executed. Sign-in, connection and `tools/list` through the proxy were
verified in the gateway logs. Expect the same gateway error text as the other clients.

## Logs

`python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name> --param client=claude`
shows `register` (`Claude Code (ado-proxy)`, `localhost:<port>/callback`), `authorize`,
`token`, then `proxy-inbound` with your public client as `clientAppId`.

## Known issues

| Symptom | Cause | Fix |
|---|---|---|
| `stdin isn't a terminal` on `claude mcp login --no-browser` | Login needs an interactive terminal | Run it in a normal terminal |
| `ECONNRESET` for the native server in `claude mcp list` | The native API returned `500 ProtocolViolation: Content length mismatch` to the CLI's first protocol-version probe | Regular setup only; the proxy is not affected |
| `AADSTS900144` (scope missing) | Some versions sent no scope ([claude-code#72440](https://github.com/anthropics/claude-code/issues/72440)) | The gateway adds the scope |
| A configured `Authorization` header disables OAuth | By design | Leave headers out for OAuth servers |

References: [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).
