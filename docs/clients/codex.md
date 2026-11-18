# OpenAI Codex CLI

Tested with Codex CLI 0.167.0 on Windows (lab, 2026-11-18).

## How it signs in (observed)

| Step | Behaviour |
|---|---|
| Discovery | Body-less `GET` of the MCP URL first (expects `401` or `405`), then the path-inserted PRM `/.well-known/oauth-protected-resource/<path>`, then authorization-server metadata (path-inserted variants, then the host root) |
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
codex mcp login ado_proxy     # browser opens via the gateway's /authorize
# Successfully logged in to MCP server 'ado_proxy'.
codex mcp list                # Auth: OAuth
```

Regular setup: `codex mcp login ado_native` **also succeeds in the lab**. Codex finds no PRM
at the standard addresses for the native URL and falls back to the authorization server at
the host root. That is the working setup's endpoint on the same APIM instance. A gateway
without the working setup gives Codex no metadata, so it cannot sign in (*unverified*).
Details:
[the regular setup with these clients](../CLIENTS-APIM-CHANGES.md#the-regular-setup-with-these-clients-what-you-will-see).

## Test headless

```powershell
codex exec --skip-git-repo-check "Use only the ado_proxy MCP server tools (no shell). Call core_list_projects with no arguments and print the project names. Then call core_list_projects with top set to 500 and print the exact error."
```

Expected (lab):

```text
Step 1: <project>
Step 2: tool call error: tool call failed for `ado_proxy/core_list_projects`
Caused by:
    Mcp error: -32602: Invalid arguments for tool core_list_projects: top violates maximum. Rejected by the API gateway
    before reaching the server.({"tool":"core_list_projects","violations":[{"field":"top","rule":"maximum"}],"source":"api-gateway"})
```

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
| `OAuth metadata discovery failed ... unexpected HTTP status 500` | The gateway failed on the body-less `GET` probe (fixed: [change 7](../CLIENTS-APIM-CHANGES.md#change-7-body-less-get-and-delete-must-not-crash-the-gateway)) | Redeploy the current policies |
| `AADSTS50011` after sign-in | `http://127.0.0.1/callback/<id>` for this exact URL is not registered | `setup-entra.ps1 -McpUrl <url>` |
| `Missing environment variable` for the model | Model provider configuration, not MCP | Set the provider's key or token |

References: [Codex MCP documentation](https://developers.openai.com/codex/mcp),
[openai/codex](https://github.com/openai/codex).
