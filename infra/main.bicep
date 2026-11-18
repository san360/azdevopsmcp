targetScope = 'resourceGroup'

// Azure DevOps remote MCP server behind Azure API Management.
//   Regular setup  : native APIM MCP pass-through                     - reproduces the issue.
//   Working setup  : APIM HTTP proxy + OAuth compatibility endpoints     - works with VS Code.
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

@description('Request body bytes logged for MCP JSON-RPC calls (0 disables). Response bodies are never logged.')
@minValue(0)
@maxValue(8192)
param mcpRequestBodyBytes int = 4096

@description('Validate tools/call arguments of vetted tools (infra/schemas/tools) on the working setup (HTTP proxy).')
param toolValidation bool = true

@description('What happens to tools/call for tools without a gateway schema: allow (pass through) or deny (JSON-RPC error).')
@allowed([
  'allow'
  'deny'
])
param unlistedToolAction string = 'allow'

@description('Lab-only: echo raw validate-content errors in rejections (may contain submitted values).')
param toolValidationDebug bool = false

@description('Native pass-through API path. Clients connect to {gateway}/{path}/{organization}.')
param nativeApiPath string = 'ado-mcp-native'
param proxyApiPath string = 'ado-mcp-proxy'

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

module toolValidationModule 'modules/mcp-tool-validation.bicep' = if (toolValidation) {
  name: 'mcp-tool-validation'
  params: {
    apimName: apimName
    denyUnlistedTools: unlistedToolAction == 'deny'
    debugRawErrors: toolValidationDebug
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
  }
  dependsOn: [
    apimService
  ]
}

var toolValidationPolicy = toolValidation ? '<include-fragment fragment-id="${toolValidationModule!.outputs.fragmentName}" />' : ''
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
    backendName: backend.name
    clientPathSuffix: '/${adoOrganization}'
    // Not toolValidationPolicy: validate-content needs an API operation; native MCP APIs have none,
    // and including it makes every native request fail with HTTP 500 (see README).
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
    toolValidationPolicy: toolValidationPolicy
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
output appInsightsName string = monitoring.outputs.appInsightsName
output workspaceId string = monitoring.outputs.workspaceId
output validatedTools array = toolValidation ? toolValidationModule!.outputs.vettedTools : []
