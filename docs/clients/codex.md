# OpenAI Codex CLI

Tested with Codex CLI 0.167.0 on Windows (lab, 2026-11-18). Sign-in re-verified on the
current layout of the working setup (an APIM MCP server, everything under `/ado-mcp-proxy`):
`Auth: OAuth`, and fresh discovery reaches `https://<gateway>/ado-mcp-proxy/oauth/authorize`.
Tool calls were verified on the earlier HTTP-proxy layout.

## How it signs in (observed)

| Step | Behaviour |
|---|---|
| Discovery | Body-less `GET` of the MCP URL first (expects `401` or `405`), then the path-inserted PRM `/.well-known/oauth-protected-resource/<path>` (served by the gateway's discovery alias), then authorization-server metadata at the path-inserted `/.well-known/oauth-authorization-server/<issuer path>` (observed: `/ado-mcp-proxy/oauth`), falling back to the host root |
| Client ID | Dynamic client registration, `client_name` `Codex` (or `--oauth-client-id`) |
| Redirect URI | `http://127.0.0.1:<random port>/callback/<id>`. The `<id>` is fixed per MCP URL: base64url of the first 9 bytes of the URL's SHA-256 |
| `resource` | Sends the PRM `resource` (gateway URL); APIM replaces it |
| Sign-in trigger | Explicit: `codex mcp login <name>` (`--no-browser` prints the URL) |
| Token storage | OS credential store, or `$CODEX_HOME/.credentials.json` (`mcp_oauth_credentials_store`) |

Because the redirect path contains a per-URL ID, **every MCP URL needs its own redirect URI**
on the Entra public client. `setup-entra.ps1 -McpUrl <url>` computes and registers it. To
see the exact value, run `codex mcp login <name> --no-browser` and read `redirect_uri` in
the printed URL.

## Configure (isolated, nothing written to your normal profile)

```powershell
$env:CODEX_HOME = "$env:TEMP\ado-mcp\codex-home"
New-Item -ItemType Directory -Force $env:CODEX_HOME | Out-Null
codex mcp add ado_proxy  --url https://<gateway>/ado-mcp-proxy/<org>
codex mcp add ado_native --url https://<gateway>/ado-mcp-native/<org>
codex mcp list      # Auth: Unknown until you log in
```

Equivalent `$env:CODEX_HOME\config.toml` (default `~/.codex/config.toml`):

```toml
[mcp_servers.ado_proxy]
url = "https://<gateway>/ado-mcp-proxy/<org>"
default_tools_approval_mode = "approve"   # lets `codex exec` call the tools without prompting
```

Add your model provider settings to the same file as usual (Codex needs a model for
`codex exec`; `codex mcp login` does not).

## Sign in

```powershell
codex mcp login ado_proxy     # browser opens via the gateway's /ado-mcp-proxy/oauth/authorize
# Successfully logged in to MCP server 'ado_proxy'.
codex mcp list                # Auth: OAuth
```

To sign in with a specific browser profile, use `--no-browser`, run it in a real terminal
(it waits for input), and open the printed URL yourself, for example
`msedge.exe --profile-directory="<profile>" "<url>"`. The printed URL must start with
`https://<gateway>/ado-mcp-proxy/oauth/authorize`; the callback completes on its own.

Regular setup: `codex mcp login ado_native` **fails** with *Dynamic registration failed:
HTTP 404*. Codex finds no PRM at the standard addresses for the native URL, falls back to
default endpoints at the host root, and the gateway has none (observed 2026-11-18). Before
the working setup moved under its own path, this fallback borrowed the working setup's root
endpoints and the login "succeeded"; the isolation removed that side effect.
Details:
[the regular setup with these clients](../CLIENTS-APIM-CHANGES.md#the-regular-setup-with-these-clients-what-you-will-see).

## Test headless

```powershell
codex exec --skip-git-repo-check "Use only the ado_proxy MCP server tools (no shell). Call core_list_projects with no arguments and print the project names."
```

Expected: the project names, for example `<project>`. The gateway does not validate tool
arguments any more, so the *-32602 ... Rejected by the API gateway* error of earlier versions
is no longer expected ([TOOL-VALIDATION.md](../TOOL-VALIDATION.md)).

Small models may answer without calling the tool. A stronger model followed the prompt
reliably in the lab.

## Logs

`python tools/query_logs.py docs/kql/client-signins.kql -g <rg> -w log-<apim-name> --param client=codex`
shows the `GET` probe (`405`), `prm`, `as-metadata`, `register` (`Codex`,
`127.0.0.1:<port>/callback/<id>`), `authorize`, `token`, and then `proxy-inbound` with your
public client as `clientAppId`.

## Known issues

| Symptom | Cause | Fix |
|---|---|---|
| `OAuth metadata discovery failed ... unexpected HTTP status 500` | The gateway failed on the body-less `GET` probe (seen with an earlier HTTP-proxy version; the MCP server answers `405`: [change 7](../CLIENTS-APIM-CHANGES.md#change-7-body-less-get-and-delete-must-not-fail-built-in)) | Deploy the current version |
| `AADSTS50011` after sign-in | `http://127.0.0.1/callback/<id>` for this exact URL is not registered | `setup-entra.ps1 -McpUrl <url>` |
| `Missing environment variable` for the model | Model provider configuration, not MCP | Set the provider's key or token |
| *Dynamic registration failed: HTTP 404* on the proxy URL | The gateway's discovery aliases are missing, so Codex falls back to the host root (observed with the aliases removed) | Redeploy with `rootDiscoveryAliases = true` |
| `--no-browser`: *No OAuth callback URL received before input closed* | Run without a terminal (stdin closed) | Run it in a real terminal window |
| Browser goes to `https://<gateway>/authorize` (`404`) after a gateway change | Cached authorization server from an older lab version | `codex mcp logout <name>`, then log in again |

References: [Codex MCP documentation](https://developers.openai.com/codex/mcp),
[openai/codex](https://github.com/openai/codex).
