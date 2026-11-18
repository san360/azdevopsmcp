<#
.SYNOPSIS
  Prepares Microsoft Entra for the Azure DevOps MCP + APIM lab. Idempotent.

.DESCRIPTION
  1. Ensures the "Azure DevOps MCP" enterprise application (service principal)
     exists in the tenant. Without it the hosted server accepts the token but
     fails every MCP request with HTTP 500.
  2. Creates or updates a public client app registration used by:
       - the APIM /register compatibility endpoint (working setup),
       - tools/mcp_probe.py --token browser,
       - MCP Inspector's OAuth flow.
     Redirect URIs (Entra matches scheme, host and path exactly; the port is
     ignored for loopback addresses, so one entry covers random ports):
       VS Code            http://127.0.0.1:33418/ and https://vscode.dev/redirect
       GitHub Copilot CLI http://127.0.0.1/
       Claude Code        http://localhost/callback
       OpenAI Codex CLI   http://127.0.0.1/callback/<id>, one per MCP URL (-McpUrl)
       MCP Inspector      http://localhost:6274/oauth/callback (+ /debug, + 127.0.0.1)
       mcp_probe.py       http://localhost (--token browser)
     Delegated permission: Azure DevOps MCP / Ado.Mcp.Tools. On rerun, redirect URIs
     that are already registered are kept.
  3. Optionally grants tenant-wide admin consent.

  Requires Azure CLI signed in to the tenant with Application Administrator,
  Cloud Application Administrator or Global Administrator.

.PARAMETER TenantId
  Tenant that backs the Azure DevOps organizations. Azure CLI must be signed in to it.

.PARAMETER AppName
  Display name of the public client app registration. Default ado-mcp-apim-client. Pass the
  existing name if your public client was created under another name; otherwise a new app
  is created.

.PARAMETER GrantAdminConsent
  Grant tenant-wide admin consent for Ado.Mcp.Tools, so users are not prompted.

.PARAMETER McpUrl
  MCP URLs users connect to with OpenAI Codex CLI, for example
  https://<gateway>/ado-mcp-proxy/<org>. Codex appends a callback ID derived
  from the URL (base64url of the first 9 bytes of its SHA-256) to its redirect
  path, so each URL needs its own redirect URI.

.EXAMPLE
  ./scripts/setup-entra.ps1 -TenantId <tenant-guid> -GrantAdminConsent `
    -McpUrl https://<gateway>/ado-mcp-proxy/<org>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [string] $AppName = 'ado-mcp-apim-client',
    [string[]] $McpUrl = @(),
    [switch] $GrantAdminConsent
)

$ErrorActionPreference = 'Stop'
$adoMcpAppId = '2a72489c-aab2-4b65-b93a-a91edccf33b8'
$redirectUris = @(
    'http://127.0.0.1:33418/'                      # VS Code (desktop)
    'https://vscode.dev/redirect'                  # VS Code (web / fallback)
    'http://localhost'                             # tools/mcp_probe.py --token browser (any port)
    'http://localhost:6274/oauth/callback'         # MCP Inspector
    'http://localhost:6274/oauth/callback/debug'   # MCP Inspector auth debugger
    'http://127.0.0.1:6274/oauth/callback'         # MCP Inspector opened on 127.0.0.1
    'http://127.0.0.1:6274/oauth/callback/debug'
    'http://127.0.0.1/'                            # GitHub Copilot CLI (random port)
    'http://localhost/callback'                    # Claude Code (random port)
)
function Get-CodexCallbackId([string] $Url) {
    # Mirrors Codex: base64url (no padding) of the first 9 bytes of SHA-256(url).
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Url))
    [Convert]::ToBase64String($hash[0..8]).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
foreach ($url in $McpUrl) {
    $redirectUris += "http://127.0.0.1/callback/$(Get-CodexCallbackId $url.TrimEnd('/'))"   # OpenAI Codex CLI
}

function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $output
}

$current = Invoke-Az account show --query tenantId -o tsv
if ($current -ne $TenantId) { throw "Azure CLI is signed in to tenant $current; run: az login --tenant $TenantId" }

Write-Host '1/3 Azure DevOps MCP enterprise application'
$sp = & az ad sp show --id $adoMcpAppId --query id -o tsv 2>$null
if (-not $sp) {
    Invoke-Az ad sp create --id $adoMcpAppId --query appId -o tsv | Out-Null
    Write-Host '    created service principal for Azure DevOps MCP'
} else {
    Write-Host '    already present'
}
$scopeId = Invoke-Az ad sp show --id $adoMcpAppId --query "oauth2PermissionScopes[?value=='Ado.Mcp.Tools'].id | [0]" -o tsv
if (-not $scopeId) { throw 'Ado.Mcp.Tools scope not found on the Azure DevOps MCP service principal' }

Write-Host "2/3 Public client app '$AppName'"
$appId = Invoke-Az ad app list --display-name $AppName --query '[0].appId' -o tsv
$access = ConvertTo-Json -Depth 5 -InputObject @(@{
        resourceAppId  = $adoMcpAppId
        resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
    })
$accessFile = New-TemporaryFile
try {
    Set-Content -LiteralPath $accessFile -Value $access -Encoding utf8
    if (-not $appId) {
        $appId = Invoke-Az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg `
            --is-fallback-public-client true --public-client-redirect-uris @redirectUris `
            --required-resource-accesses "@$accessFile" --query appId -o tsv
        Write-Host "    created $appId"
    } else {
        # Keep redirect URIs that are already registered (for example other Codex URLs).
        $existing = @(Invoke-Az ad app show --id $appId --query 'publicClient.redirectUris' -o json | ConvertFrom-Json)
        $redirectUris = @($redirectUris + $existing | Where-Object { $_ } | Select-Object -Unique)
        Invoke-Az ad app update --id $appId --is-fallback-public-client true `
            --public-client-redirect-uris @redirectUris --required-resource-accesses "@$accessFile" | Out-Null
        Write-Host "    updated $appId"
    }
} finally {
    Remove-Item -LiteralPath $accessFile -ErrorAction SilentlyContinue
}
if (-not (& az ad sp show --id $appId --query id -o tsv 2>$null)) {
    Invoke-Az ad sp create --id $appId --query appId -o tsv | Out-Null
}

Write-Host '3/3 Consent'
if ($GrantAdminConsent) {
    Start-Sleep -Seconds 10   # allow the new service principal to replicate
    Invoke-Az ad app permission admin-consent --id $appId | Out-Null
    Write-Host '    admin consent granted for Ado.Mcp.Tools'
} else {
    Write-Host '    skipped: users consent at first sign-in, or rerun with -GrantAdminConsent'
}

Write-Host ''
Write-Host "publicClientId = '$appId'   (put this in infra/main.local.bicepparam and tools/probe.local.json)"
