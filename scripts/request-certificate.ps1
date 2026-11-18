<#
.SYNOPSIS
  Issues or renews the custom-domain certificate in Key Vault with Let's Encrypt.

.DESCRIPTION
  The private key never leaves Key Vault:
    1. Key Vault creates a new key and a certificate signing request (CSR),
       or the pending request is reused.
    2. Posh-ACME asks Let's Encrypt for a certificate for that CSR and proves
       control of the domain with a DNS-01 TXT record (_acme-challenge.<host>)
       that it writes into the Azure DNS zone, then removes.
    3. The issued chain is merged into the Key Vault certificate. Application
       Gateway and APIM reference the versionless secret, so they pick up the
       new version automatically (App Gateway polls every 4 hours; see
       docs/APP-GATEWAY.md).
  Rerun before expiry to renew (Let's Encrypt certificates last about 90 days).

  Requires: Azure CLI signed in to both subscriptions (Key Vault and DNS), the
  Posh-ACME module (Install-Module Posh-ACME -Scope CurrentUser), Key Vault
  Certificates Officer on the vault and network access to it (see
  operatorAddressPrefixes in infra/edge/main.bicep), DNS Zone Contributor on the
  zone.

.PARAMETER KeyVaultName
  Vault that holds the certificate.

.PARAMETER CertificateName
  Key Vault certificate name, for example mcp-example-com.

.PARAMETER HostName
  Host name to certify, for example mcp.example.com.

.PARAMETER KeyVaultSubscriptionId
  Subscription of the vault.

.PARAMETER DnsSubscriptionId
  Subscription of the public Azure DNS zone (may be in another tenant).

.PARAMETER Staging
  Use the Let's Encrypt staging directory (untrusted certificates, generous rate limits).

.EXAMPLE
  ./scripts/request-certificate.ps1 -KeyVaultName <vault> -CertificateName mcp-example-com `
    -HostName mcp.example.com -KeyVaultSubscriptionId <sub> -DnsSubscriptionId <dns-sub>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $KeyVaultName,
    [Parameter(Mandatory)] [string] $CertificateName,
    [Parameter(Mandatory)] [string] $HostName,
    [Parameter(Mandatory)] [string] $KeyVaultSubscriptionId,
    [Parameter(Mandatory)] [string] $DnsSubscriptionId,
    [switch] $Staging
)

$ErrorActionPreference = 'Stop'
Import-Module Posh-ACME

function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $output
}

$kv = @('--vault-name', $KeyVaultName, '--name', $CertificateName, '--subscription', $KeyVaultSubscriptionId)

Write-Host '1/3 Certificate signing request in Key Vault'
$pending = & az keyvault certificate pending show @kv --query csr -o tsv 2>$null
if ($pending) {
    Write-Host '    reusing the pending request'
} else {
    $exists = & az keyvault certificate show @kv --query id -o tsv 2>$null
    if ($exists) {
        # A new version with the stored policy (issuer Unknown) creates a fresh key and CSR.
        $policy = Invoke-Az keyvault certificate show @kv --query policy -o json
    } else {
        $policy = ConvertTo-Json -Depth 5 -InputObject @{
            issuerParameters          = @{ name = 'Unknown' }
            keyProperties             = @{ exportable = $true; keyType = 'RSA'; keySize = 2048; reuseKey = $false }
            secretProperties          = @{ contentType = 'application/x-pkcs12' }
            x509CertificateProperties = @{
                subject                 = "CN=$HostName"
                subjectAlternativeNames = @{ dnsNames = @($HostName) }
                validityInMonths        = 3
                keyUsage                = @('digitalSignature', 'keyEncipherment')
                ekus                    = @('1.3.6.1.5.5.7.3.1')
            }
        }
    }
    $policyFile = New-TemporaryFile
    try {
        Set-Content -LiteralPath $policyFile -Value $policy -Encoding utf8
        Invoke-Az keyvault certificate create @kv --policy "@$policyFile" --query status -o tsv | Out-Null
    } finally {
        Remove-Item -LiteralPath $policyFile -ErrorAction SilentlyContinue
    }
    $pending = Invoke-Az keyvault certificate pending show @kv --query csr -o tsv
    Write-Host '    created a new key and request'
}

$work = Join-Path ([IO.Path]::GetTempPath()) "acme-$CertificateName"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$csrPath = Join-Path $work 'request.csr'
$body = ($pending -replace '\s', '') -split '(.{64})' | Where-Object { $_ }
Set-Content -LiteralPath $csrPath -Encoding ascii -Value (@('-----BEGIN CERTIFICATE REQUEST-----') + $body + @('-----END CERTIFICATE REQUEST-----'))

Write-Host "2/3 Let's Encrypt order (DNS-01 in subscription $DnsSubscriptionId)"
Set-PAServer ($Staging ? 'LE_STAGE' : 'LE_PROD')
if (-not (Get-PAAccount)) { New-PAAccount -AcceptTOS | Out-Null }
$token = Invoke-Az account get-access-token --subscription $DnsSubscriptionId --resource https://management.azure.com/ --query accessToken -o tsv
$pluginArgs = @{ AZSubscriptionId = $DnsSubscriptionId; AZAccessTokenSecure = (ConvertTo-SecureString $token -AsPlainText -Force) }
$cert = New-PACertificate -CSRPath $csrPath -Plugin Azure -PluginArgs $pluginArgs -Force
if (-not $cert) { throw 'Let''s Encrypt did not return a certificate' }

Write-Host '3/3 Merge into Key Vault'
Invoke-Az keyvault certificate pending merge @kv --file $cert.FullChainFile --query id -o tsv | Out-Null
$issued = Invoke-Az keyvault certificate show @kv --query '{thumbprint:x509ThumbprintHex, expires:attributes.expires, version:id}' -o json | ConvertFrom-Json
Write-Host "    thumbprint $($issued.thumbprint), expires $($issued.expires)"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
