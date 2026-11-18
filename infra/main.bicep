targetScope = 'resourceGroup'

// Azure DevOps remote MCP server behind Azure API Management, as two APIM MCP servers.
//   Regular setup  : native APIM MCP pass-through                                   - reproduces the issue.
//   Working setup  : native APIM MCP pass-through + PRM/OAuth compatibility APIs    - works with VS Code and the CLIs.
// Both share Application Insights + Log Analytics telemetry. See README.md.

@description('APIM instance name. Adopted when createApim is false.')
param apimName string

@description('Create a new Developer-tier APIM instance (takes 30-45 minutes).')
param createApim bool = false

@secure()
@description('Publisher email; only used when createApim is true.')
param publisherEmail string = ''
param publisherName string = 'MCP gateway lab'

param location string = resourceGroup().location

@description('Primary Azure DevOps organization (not the URL); used for output URLs. Must be Entra-backed.')
param adoOrganization string

@description('Working setup: organizations accepted in {gateway}/{proxyApiPath}/{org}. Empty accepts any well-formed name; Azure DevOps still enforces the user\'s permissions.')
param allowedOrganizations array = []

@description('Entra tenant ID that backs the organizations, or "organizations" if they span tenants.')
param tenantId string

@description('Public client app ID returned by /register (see scripts/setup-entra.ps1). Empty skips the working setup.')
param publicClientId string = ''

@description('Send X-MCP-Readonly: true so only read-only tools are exposed.')
param readOnly bool = true

@description('Comma-separated X-MCP-Toolsets sent by both setups (empty = server default).')
param toolsets string = ''

@minValue(1)
param rateLimitCalls int = 60

@minValue(1)
param rateLimitPeriod int = 60

@description('Behind a reverse proxy such as Application Gateway: rate-limit by the client IP in the last X-Forwarded-For entry (the one the proxy appended), and build PRM/OAuth metadata URLs from the last X-Forwarded-Host. Keep false when clients reach APIM directly, because clients could then set these headers.')
param trustForwardedFor bool = false

@description('Working setup rate-limit key: client-ip, or user (the token oid; a caller can invent oids unless the gateway validates tokens).')
@allowed([
  'client-ip'
  'user'
])
param rateLimitKey string = 'client-ip'

@description('Request body bytes logged for MCP JSON-RPC calls (0 disables). Response bodies are never logged.')
@minValue(0)
@maxValue(8192)
param mcpRequestBodyBytes int = 4096

@description('Native pass-through API path. Clients connect to {gateway}/{path}/{organization}.')
param nativeApiPath string = 'ado-mcp-native'

@description('Working setup dedicated path. Clients connect to {gateway}/{path}/{organization}; its OAuth endpoints live under {gateway}/{path}/oauth. Nothing is mounted at the gateway root.')
param proxyApiPath string = 'ado-mcp-proxy'

@description('Working setup: also serve its metadata at the path-inserted /.well-known/.../{proxyApiPath} URLs (RFC 9728/8414). Required by OpenAI Codex and Claude Code (they fail without it); each alias matches only this setup\'s path.')
param rootDiscoveryAliases bool = true

param workspaceName string = 'log-${apimName}'
param appInsightsName string = 'appi-${apimName}'

// Safe to log. Never add Authorization, Cookie, Set-Cookie or Mcp-Session-Id.
var loggedHeaders = [
  'Content-Type'
  'Accept'
  'MCP-Protocol-Version'
  'WWW-Authenticate'
  'User-Agent'
  'traceparent'
  'x-mcp-test-run'
  'X-Correlation-ID'
  'x-apim-request-id'
  // Behind Application Gateway: the public host the client used (APIM may be called on its default host).
  'X-Forwarded-Host'
]

module apimService 'modules/apim.bicep' = if (createApim) {
  name: 'apim-service'
  params: {
    apimName: apimName
    location: location
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    workspaceName: workspaceName
    appInsightsName: appInsightsName
    location: location
  }
}

module observability 'modules/apim-observability.bicep' = {
  name: 'apim-observability'
  params: {
    apimName: apimName
    appInsightsId: monitoring.outputs.appInsightsId
    workspaceId: monitoring.outputs.workspaceId
    loggedHeaders: loggedHeaders
  }
  dependsOn: [
    apimService
  ]
}

// One bare-host backend serves both setups. Clients put the organization in the
// path ({gateway}/{api}/{org}); APIM appends it to the backend URL.
resource backend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'ado-mcp-origin'
  properties: {
    description: 'Hosted Azure DevOps remote MCP server (organization comes from the client path)'
    protocol: 'http'
    url: 'https://mcp.dev.azure.com'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [
    apimService
  ]
}

// Shared fragments and the named values they read (allow-list, read-only, toolsets).
module fragments 'modules/policy-fragments.bicep' = {
  name: 'mcp-policy-fragments'
  params: {
    apimName: apimName
    allowedOrganizations: allowedOrganizations
    readOnly: readOnly
    toolsets: toolsets
    trustForwardedFor: trustForwardedFor
    rateLimitKey: rateLimitKey
  }
  dependsOn: [
    apimService
  ]
}

// Native pass-through with the organization in the client path: discovery and tool calls work through APIM;
// only the rewritten PRM "resource" breaks Entra sign-in. (With the organization in the backend URL instead,
// APIM's advertised PRM URL returns 404.)
module native 'modules/mcp-native.bicep' = {
  name: 'mcp-native'
  params: {
    apimName: apimName
    apiName: nativeApiPath
    apiPath: nativeApiPath
    displayName: 'Azure DevOps MCP (native pass-through)'
    apiDescription: 'Regular setup (reproduction): APIM native MCP pass-through to the hosted Azure DevOps MCP server, with read-only header and telemetry. Tool calls work with a token; client sign-in fails with AADSTS9010010 because the PRM APIM serves names Entra as authorization server for the gateway URL. Use ado-mcp-proxy for a working sign-in.'
    backendName: backend.name
    clientPathSuffix: '/${adoOrganization}'
    appInsightsLoggerId: observability.outputs.appInsightsLoggerId
    loggedHeaders: loggedHeaders
    requestBodyBytes: mcpRequestBodyBytes
  }
  // The policy includes fragments, which must exist before it is saved.
  dependsOn: [
    fragments
  ]
}

module proxy 'modules/mcp-proxy.bicep' = if (!empty(publicClientId)) {
  name: 'mcp-proxy'
  params: {
    apimName: apimName
    backendName: backend.name
    appInsightsLoggerId: observability.outputs.appInsightsLoggerId
    loggedHeaders: loggedHeaders
    tenantId: tenantId
    clientId: publicClientId
    proxyPath: proxyApiPath
    rootDiscoveryAliases: rootDiscoveryAliases
    rateLimitCalls: rateLimitCalls
    rateLimitPeriod: rateLimitPeriod
    requestBodyBytes: mcpRequestBodyBytes
  }
  dependsOn: [
    fragments
  ]
}

output originUrl string = 'https://mcp.dev.azure.com/${adoOrganization}'
output nativeMcpUrl string = native.outputs.url
output proxyMcpUrl string = empty(publicClientId) ? '' : '${proxy!.outputs.proxyBaseUrl}/${adoOrganization}'
output proxyOAuthIssuer string = empty(publicClientId) ? '' : proxy!.outputs.oauthIssuer
output proxyApiNames array = empty(publicClientId) ? [] : proxy!.outputs.apiNames
output appInsightsName string = monitoring.outputs.appInsightsName
output workspaceId string = monitoring.outputs.workspaceId
