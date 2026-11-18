// Azure AI Gateway (Microsoft.ApiManagement/aigateways) in front of the hosted Azure DevOps MCP
// server, for comparison with the APIM lab (infra/main.bicep). Deploy into its own resource group:
//
//   az group create -n <rg> -l swedencentral
//   az deployment group create -g <rg> --parameters infra/aigateway/main.local.bicepparam
//
// AI Gateway federates MCP servers: clients call <gateway>/default/toolservers/<name>/mcp and see the
// backend's tools as <namespace>_<tool>. Clients authenticate to the gateway (Entra token for
// https://ai.gateway.azure.com, or a runtime API key). The gateway authenticates to each backend
// separately. This template registers the Azure DevOps MCP server once per backend credential:
//   ado-none : no backend credential (what a plain pass-through does)
//   ado-mi   : the gateway's managed identity (app-only token)
//   ado-obo  : OAuth 2.0 on-behalf-of the signed-in caller (per-user), when an exchange app is set
// See docs/AI-GATEWAY.md.
targetScope = 'resourceGroup'

@description('Gateway name: first label of the runtime host name (letters, numbers, hyphens; max 24).')
@maxLength(24)
param gatewayName string

@description('Region where AI Gateway is available.')
param location string = resourceGroup().location

@description('Azure DevOps organization behind the MCP backend.')
param adoOrganization string

@description('Object ID of a user or group that may call the MCP servers (AI Gateway Tools User).')
param callerPrincipalId string = ''

@allowed([
  'User'
  'Group'
])
param callerPrincipalType string = 'User'

@description('Register the backend with the gateway managed identity as well (ado-mi).')
param includeManagedIdentityBackend bool = true

@description('OBO: client ID of the token exchange app registration (see docs/AI-GATEWAY.md). Empty skips ado-obo.')
param oboExchangeAppId string = ''

@description('Tool allow-list for every server (namespace-prefixed patterns). ["*"] publishes all tools.')
param allowList array = [
  '*'
]

var adoUrl = 'https://mcp.dev.azure.com/${adoOrganization}'
var toolsUserRoleId = 'dce03f8d-857f-4e40-a90d-67770fa6ecd2' // AI Gateway Tools User

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${gatewayName}'
  location: location
}

#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' = {
  name: gatewayName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {}
}

#disable-next-line BCP081
resource workspace 'Microsoft.ApiManagement/aigateways/workspaces@2026-11-01' existing = {
  parent: gateway
  name: 'default'
}

// Stable 2026-11-01 schema: endpoints[].mcp.endpoint.url and endpoints[].authentication.
func adoEndpoint(url string, authentication object) object => union({
  id: 'ado'
  namespace: 'ado'
  kind: 'mcp'
  mcp: {
    endpoint: {
      url: url
    }
    transport: 'streamableHttp'
  }
  mode: 'failClosed'
}, empty(authentication) ? {} : { authentication: authentication })

#disable-next-line BCP081
resource adoNone 'Microsoft.ApiManagement/aigateways/workspaces/toolServers@2026-11-01' = {
  parent: workspace
  name: 'ado-none'
  properties: {
    displayName: 'Azure DevOps MCP (no backend credential)'
    description: 'Hosted Azure DevOps MCP server registered without a backend credential.'
    toolServerType: 'mcp'
    allowList: allowList
    endpoints: [
      adoEndpoint(adoUrl, {})
    ]
  }
}

#disable-next-line BCP081
resource adoMi 'Microsoft.ApiManagement/aigateways/workspaces/toolServers@2026-11-01' = if (includeManagedIdentityBackend) {
  parent: workspace
  name: 'ado-mi'
  properties: {
    displayName: 'Azure DevOps MCP (gateway managed identity)'
    description: 'Hosted Azure DevOps MCP server called with the gateway identity (app-only).'
    toolServerType: 'mcp'
    allowList: allowList
    endpoints: [
      adoEndpoint(adoUrl, {
        managedIdentity: {
          resource: 'https://mcp.dev.azure.com'
          clientId: identity.properties.clientId
        }
      })
    ]
  }
}

#disable-next-line BCP081
resource adoObo 'Microsoft.ApiManagement/aigateways/workspaces/toolServers@2026-11-01' = if (!empty(oboExchangeAppId)) {
  parent: workspace
  name: 'ado-obo'
  properties: {
    displayName: 'Azure DevOps MCP (on behalf of the caller)'
    description: 'Hosted Azure DevOps MCP server called with a per-user token from an on-behalf-of exchange.'
    toolServerType: 'mcp'
    allowList: allowList
    endpoints: [
      // The gateway exchanges the caller's AI Gateway token (Data.All) for an Azure DevOps MCP token
      // on behalf of the user. The exchange app authenticates with the gateway's managed identity
      // (federated credential); it holds the delegated Ado.Mcp.Tools permission.
      // Static headers (for example X-MCP-Readonly) cannot be added here: the service rejects
      // "token authentication and supplemental headers" together. Use allowList instead.
      adoEndpoint(adoUrl, {
        oauth2: {
          // grantType tokenExchange is required (the portal writes it), although the published
          // 2026-11-01 spec lists only clientCredentials and authorizationCode. With it, the service
          // rejects clientId, client secret and endpoint fields: the exchange app below is the client.
          grantType: 'tokenExchange'
          tokenExchange: {
            profile: 'entraOnBehalfOf'
            federatedClientApplication: {
              applicationId: oboExchangeAppId
              appCredential: {
                type: 'userAssignedManagedIdentity'
                clientId: identity.properties.clientId
              }
            }
            scopes: [
              'https://mcp.dev.azure.com/Ado.Mcp.Tools'
            ]
          }
        }
      })
    ]
  }
}

resource toolsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(callerPrincipalId)) {
  name: guid(gateway.id, callerPrincipalId, toolsUserRoleId)
  scope: gateway
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', toolsUserRoleId)
    principalId: callerPrincipalId
    principalType: callerPrincipalType
  }
}

output gatewayUrl string = 'https://${gateway.properties.frontend.defaultHostname}'
output mcpEndpointNone string = 'https://${gateway.properties.frontend.defaultHostname}/default/toolservers/ado-none/mcp'
output mcpEndpointManagedIdentity string = includeManagedIdentityBackend ? 'https://${gateway.properties.frontend.defaultHostname}/default/toolservers/ado-mi/mcp' : ''
output mcpEndpointOnBehalfOf string = empty(oboExchangeAppId) ? '' : 'https://${gateway.properties.frontend.defaultHostname}/default/toolservers/ado-obo/mcp'
output identityClientId string = identity.properties.clientId
output identityPrincipalId string = identity.properties.principalId
