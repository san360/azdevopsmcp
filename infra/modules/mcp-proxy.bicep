// Working setup: APIM as a governed HTTP proxy for the hosted Azure DevOps MCP
// server, plus the OAuth compatibility endpoints MCP clients need to sign in
// through the gateway URL. One deployment serves many organizations:
//
//   client URL {gw}/{proxyPath}/{org}  ->  https://mcp.dev.azure.com/{org}
//   client URL {gw}/{proxyPath}        ->  https://mcp.dev.azure.com (orgName per tool call)
//
//   MCP client -> POST {gw}/{proxyPath}/{org}            401 + resource_metadata (APIM)
//              -> GET  {gw}/.well-known/oauth-protected-resource/{proxyPath}/{org}
//              -> GET  {gw}/.well-known/oauth-authorization-server
//              -> POST {gw}/register      static public client ID (DCR compatibility)
//              -> GET  {gw}/authorize     302 to Entra with resource=https://mcp.dev.azure.com
//              -> POST {gw}/token         forwarded to Entra with resource=https://mcp.dev.azure.com
//              -> POST {gw}/{proxyPath}/{org} + Bearer   forwarded unchanged

param apimName string

@description('Backend entity for the bare host https://mcp.dev.azure.com.')
param backendName string
param appInsightsLoggerId string
param loggedHeaders array

@description('Entra tenant that owns the Azure DevOps organizations, or "organizations" when they span tenants.')
param tenantId string

@description('Pre-registered Entra public client returned by /register.')
param clientId string

param proxyPath string

@description('Policy XML that includes the tool-validation fragment; empty disables validation.')
param toolValidationPolicy string = ''

param rateLimitCalls int
param rateLimitPeriod int

@minValue(0)
@maxValue(8192)
param requestBodyBytes int

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

var adoResource = 'https://mcp.dev.azure.com'
var adoScope = 'https://mcp.dev.azure.com/.default'

func fill(template string, values object) string =>
  reduce(items(values), template, (acc, item) => replace(acc, '__${item.key}__', item.value))

var oauthValues = {
  TENANT_ID: tenantId
  SCOPE: adoScope
  SCOPE_ENC: uriComponent(adoScope)
  RESOURCE_ENC: uriComponent(adoResource)
  CLIENT_ID: clientId
}

var orgParameter = [
  {
    name: 'org'
    type: 'string'
    required: true
    description: 'Azure DevOps organization name'
  }
]

// ---------------------------------------------------------------- MCP proxy

resource proxyApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: proxyPath
  properties: {
    type: 'http'
    displayName: 'Azure DevOps MCP (HTTP proxy)'
    description: 'Transparent HTTP pass-through to the hosted Azure DevOps MCP server; organization in the path.'
    path: proxyPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

var proxyOperations = [
  for item in flatten(map(['POST', 'GET', 'DELETE'], m => [
    { method: m, org: false }
    { method: m, org: true }
  ])): {
    name: 'mcp-${toLower(item.method)}${item.org ? '-org' : ''}'
    method: item.method
    urlTemplate: item.org ? '/{org}' : '/'
    templateParameters: item.org ? orgParameter : []
  }
]

resource proxyOps 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [
  for op in proxyOperations: {
    parent: proxyApi
    name: op.name
    properties: {
      displayName: 'MCP Streamable HTTP ${op.method} ${op.urlTemplate}'
      method: op.method
      urlTemplate: op.urlTemplate
      templateParameters: op.templateParameters
      // validate-content only checks content types that the operation declares.
      request: op.method == 'POST'
        ? {
            representations: [
              {
                contentType: 'application/json'
              }
            ]
          }
        : null
    }
  }
]

resource proxyPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: proxyApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: fill(loadTextContent('../policies/proxy-mcp.xml'), {
      BACKEND_ID: backendName
      SCOPE: adoScope
      TOOL_VALIDATION: toolValidationPolicy
      RATE_LIMIT_CALLS: string(rateLimitCalls)
      RATE_LIMIT_PERIOD: string(rateLimitPeriod)
    })
  }
}

var requestLogging = {
  headers: loggedHeaders
  body: {
    bytes: requestBodyBytes
  }
}
var responseLogging = {
  headers: loggedHeaders
  body: {
    bytes: 0
  }
}

resource proxyDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: proxyApi
  name: 'applicationinsights'
  properties: {
    loggerId: appInsightsLoggerId
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: false
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: requestLogging
      response: responseLogging
    }
    backend: {
      request: requestLogging
      response: responseLogging
    }
  }
}

// ---------------------------------------------------------------- OAuth compatibility

resource oauthApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'ado-mcp-oauth-compat'
  properties: {
    type: 'http'
    displayName: 'Azure DevOps MCP OAuth compatibility'
    description: 'OAuth discovery, client registration, authorize and token endpoints for MCP clients using the APIM host.'
    path: ''
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource oauthApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: oauthApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><cors allow-credentials="false"><allowed-origins><origin>*</origin></allowed-origins><allowed-methods><method>GET</method><method>POST</method></allowed-methods><allowed-headers><header>*</header></allowed-headers></cors><base /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

var oauthOperations = [
  {
    name: 'protected-resource-metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource/${proxyPath}'
    templateParameters: []
    policy: 'oauth-prm'
  }
  {
    name: 'protected-resource-metadata-org'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource/${proxyPath}/{org}'
    templateParameters: orgParameter
    policy: 'oauth-prm'
  }
  {
    name: 'authorization-server-metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-authorization-server'
    templateParameters: []
    policy: 'oauth-as-metadata'
  }
  {
    name: 'openid-configuration'
    method: 'GET'
    urlTemplate: '/.well-known/openid-configuration'
    templateParameters: []
    policy: 'oauth-as-metadata'
  }
  {
    name: 'register'
    method: 'POST'
    urlTemplate: '/register'
    templateParameters: []
    policy: 'oauth-register'
  }
  {
    name: 'authorize'
    method: 'GET'
    urlTemplate: '/authorize'
    templateParameters: []
    policy: 'oauth-authorize'
  }
  {
    name: 'token'
    method: 'POST'
    urlTemplate: '/token'
    templateParameters: []
    policy: 'oauth-token'
  }
]

var oauthPolicies = {
  'oauth-prm': fill(loadTextContent('../policies/oauth-prm.xml'), oauthValues)
  'oauth-as-metadata': fill(loadTextContent('../policies/oauth-as-metadata.xml'), oauthValues)
  'oauth-register': fill(loadTextContent('../policies/oauth-register.xml'), oauthValues)
  'oauth-authorize': fill(loadTextContent('../policies/oauth-authorize.xml'), oauthValues)
  'oauth-token': fill(loadTextContent('../policies/oauth-token.xml'), oauthValues)
}

resource oauthOps 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [
  for op in oauthOperations: {
    parent: oauthApi
    name: op.name
    properties: {
      displayName: op.name
      method: op.method
      urlTemplate: op.urlTemplate
      templateParameters: op.templateParameters
    }
  }
]

resource oauthOpPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = [
  for (op, i) in oauthOperations: {
    parent: oauthOps[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: oauthPolicies[op.policy]
    }
  }
]

var noPayload = {
  headers: []
  body: {
    bytes: 0
  }
}

// Authorization and token traffic carries codes, verifiers and tokens: log no
// headers or bodies, and hide the code/state query values.
resource oauthDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: oauthApi
  name: 'applicationinsights'
  properties: {
    loggerId: appInsightsLoggerId
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: false
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        // User-Agent identifies the MCP client (Codex, Claude Code, Copilot CLI, VS Code) per sign-in step.
        headers: [
          'User-Agent'
        ]
        body: {
          bytes: 0
        }
        dataMasking: {
          queryParams: [
            {
              value: 'code'
              mode: 'Hide'
            }
            {
              value: 'state'
              mode: 'Hide'
            }
          ]
        }
      }
      response: noPayload
    }
    backend: {
      request: noPayload
      response: noPayload
    }
  }
}

output proxyBaseUrl string = '${apim.properties.gatewayUrl}/${proxyPath}'
