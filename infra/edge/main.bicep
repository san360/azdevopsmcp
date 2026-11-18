targetScope = 'resourceGroup'

// Private edge for the MCP gateway: Application Gateway (public, custom domain)
// in front of a Developer-tier API Management instance in INTERNAL virtual
// network mode. Deploy the MCP APIs into that instance afterwards with
// infra/main.bicep (createApim = false). See docs/APP-GATEWAY.md.
//
//   Stage 1 (certificateName empty): virtual network, Key Vault, identities,
//            APIM injected in internal mode. Create the certificate in Key
//            Vault meanwhile (APIM takes 30-45 minutes).
//   Stage 2 (certificateName set): APIM custom host name from Key Vault,
//            private DNS zone for that host, Application Gateway.
//
// defaultHostListeners adds more public hosts to the same Application Gateway
// that are forwarded to APIM's default *.azure-api.net host (no custom domain
// on APIM for them), side by side with customHostName.

param location string = resourceGroup().location

@description('New APIM instance (created in internal mode).')
param apimName string

@secure()
param publisherEmail string
param publisherName string = 'MCP gateway lab'

@description('Public host name clients use, for example mcp.example.com. Also the APIM custom gateway host.')
param customHostName string

@description('Key Vault certificate for customHostName. Empty deploys stage 1 only.')
param certificateName string = ''

@description('Globally unique Key Vault name (3-24 characters).')
param keyVaultName string

@description('Principal that creates and merges the certificate in Key Vault (your user object ID). Empty skips the role assignment.')
param certificateOfficerPrincipalId string = ''

@description('Public IPv4 addresses/CIDRs allowed to reach Key Vault for the certificate request and merge. Empty after the certificate is in place.')
param operatorAddressPrefixes array = []

param vnetName string = 'vnet-${apimName}'
param addressPrefix string = '10.60.0.0/22'
param appGatewaySubnetPrefix string = '10.60.0.0/24'

@description('At least /29 for one Developer unit in internal mode.')
param apimSubnetPrefix string = '10.60.1.0/27'

param privateEndpointSubnetPrefix string = '10.60.2.0/27'

param appGatewayName string = 'agw-${apimName}'

@description('Standard_v2 (default), WAF_v2, or Basic (preview; failed to provision in the lab subscription). See docs/APP-GATEWAY.md.')
@allowed([
  'Basic'
  'Standard_v2'
  'WAF_v2'
])
param appGatewaySku string = 'Standard_v2'

@minValue(1)
@maxValue(86400)
param backendTimeoutSeconds int = 240

param responseBuffering bool = false

@description('Host App Gateway sends to APIM. custom: the public host, also configured on APIM (recommended; URLs APIM builds are public as is). apim-default: APIM\'s *.azure-api.net host; App Gateway rewrites the 401 challenge and the policies use X-Forwarded-Host (needs trustForwardedFor in infra/main.bicep). See docs/APP-GATEWAY.md.')
@allowed([
  'custom'
  'apim-default'
])
param appGatewayBackendHost string = 'custom'

@description('Configure customHostName on APIM (certificate from Key Vault). Needed for appGatewayBackendHost = custom.')
param apimCustomDomain bool = true

@description('Public host forwarded to APIM\'s default *.azure-api.net host.')
type defaultHostListener = {
  @description('Public host name, for example mcp2.example.com.')
  hostName: string

  @description('Key Vault certificate for hostName, in keyVaultName.')
  certificateName: string
}

@description('Extra public hosts on the same Application Gateway, forwarded to APIM\'s default *.azure-api.net host instead of a custom host on APIM. App Gateway rewrites the 401 challenge for them, and the policies build their URLs from X-Forwarded-Host (needs trustForwardedFor = true in infra/main.bicep). Stage 2 only. See docs/APP-GATEWAY.md.')
param defaultHostListeners defaultHostListener[] = []

@description('Log Analytics workspace resource ID for Application Gateway logs. Empty skips them.')
param workspaceId string = ''

@description('Must match proxyApiPath in infra/main.bicep.')
param proxyApiPath string = 'ado-mcp-proxy'

@description('Must match nativeApiPath in infra/main.bicep.')
param nativeApiPath string = 'ado-mcp-native'

var stage2 = !empty(certificateName)
var useApimCustomDomain = stage2 && apimCustomDomain
var apimDefaultHost = '${apimName}.azure-api.net'
var backendHost = appGatewayBackendHost == 'custom' ? customHostName : apimDefaultHost
var useDefaultHost = stage2 && (appGatewayBackendHost == 'apim-default' || !empty(defaultHostListeners))

// Everything either setup serves, nothing else. The native discovery locations
// are routed too, so clients get APIM's 404 there exactly as without a proxy.
var routedPaths = [
  '/${proxyApiPath}'
  '/${proxyApiPath}/*'
  '/${nativeApiPath}'
  '/${nativeApiPath}/*'
  '/.well-known/oauth-protected-resource/${proxyApiPath}'
  '/.well-known/oauth-protected-resource/${proxyApiPath}/*'
  '/.well-known/oauth-authorization-server/${proxyApiPath}/*'
  '/.well-known/openid-configuration/${proxyApiPath}/*'
  '/.well-known/oauth-protected-resource/${nativeApiPath}'
  '/.well-known/oauth-protected-resource/${nativeApiPath}/*'
  '/.well-known/oauth-authorization-server/${nativeApiPath}/*'
  '/.well-known/openid-configuration/${nativeApiPath}/*'
]

module network 'modules/network.bicep' = {
  name: 'edge-network'
  params: {
    vnetName: vnetName
    location: location
    addressPrefix: addressPrefix
    appGatewaySubnetPrefix: appGatewaySubnetPrefix
    apimSubnetPrefix: apimSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
  }
}

module vault 'modules/keyvault.bicep' = {
  name: 'edge-keyvault'
  params: {
    keyVaultName: keyVaultName
    location: location
    certificateOfficerPrincipalId: certificateOfficerPrincipalId
    operatorAddressPrefixes: operatorAddressPrefixes
    appGatewayIdentityName: 'id-${appGatewayName}'
    apimIdentityName: 'id-${apimName}'
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    vnetId: network.outputs.vnetId
  }
}

var certificateSecretUri = stage2 ? '${vault.outputs.vaultUri}secrets/${certificateName}' : ''

module apim '../modules/apim.bicep' = {
  name: 'edge-apim'
  params: {
    apimName: apimName
    location: location
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'Internal'
    subnetId: network.outputs.apimSubnetId
    userAssignedIdentityId: vault.outputs.apimIdentityId
    userAssignedIdentityClientId: vault.outputs.apimIdentityClientId
    customHostName: useApimCustomDomain ? customHostName : ''
    certificateSecretUri: useApimCustomDomain ? certificateSecretUri : ''
  }
}

module dns 'modules/private-dns.bicep' = if (useApimCustomDomain) {
  name: 'edge-private-dns'
  params: {
    zoneName: customHostName
    apimPrivateIp: apim.outputs.privateIpAddress
    vnetId: network.outputs.vnetId
  }
}

// A zone named after the instance's gateway host, not azure-api.net: other
// *.azure-api.net names (other APIM instances, this instance's portal and
// management hosts) keep resolving through public DNS in the network.
module dnsDefaultHost 'modules/private-dns.bicep' = if (useDefaultHost) {
  name: 'edge-private-dns-default-host'
  params: {
    zoneName: apimDefaultHost
    apimPrivateIp: apim.outputs.privateIpAddress
    vnetId: network.outputs.vnetId
  }
}

module appGateway 'modules/appgw.bicep' = if (stage2) {
  name: 'edge-appgw'
  params: {
    appGatewayName: appGatewayName
    location: location
    skuName: appGatewaySku
    subnetId: network.outputs.appGatewaySubnetId
    identityId: vault.outputs.appGatewayIdentityId
    sites: concat(
      [
        {
          hostName: customHostName
          backendHostName: backendHost
          certificateSecretUri: certificateSecretUri
        }
      ],
      map(defaultHostListeners, l => {
        hostName: l.hostName
        backendHostName: apimDefaultHost
        certificateSecretUri: '${vault.outputs.vaultUri}secrets/${l.certificateName}'
      })
    )
    routedPaths: routedPaths
    backendTimeoutSeconds: backendTimeoutSeconds
    responseBuffering: responseBuffering
    workspaceId: workspaceId
  }
  // The backend host must resolve to APIM before the first health probe.
  dependsOn: [
    dns
    dnsDefaultHost
  ]
}

output apimPrivateIp string = apim.outputs.privateIpAddress
output keyVaultUri string = vault.outputs.vaultUri
output appGatewayPublicIp string = stage2 ? appGateway!.outputs.publicIpAddress : ''
output publicBaseUrl string = 'https://${customHostName}'
output defaultHostBaseUrls string[] = map(defaultHostListeners, l => 'https://${l.hostName}')
