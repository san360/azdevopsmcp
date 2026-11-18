// "Regular" setup: the hosted Azure DevOps MCP server exposed through APIM's
// native MCP pass-through ("expose an existing MCP server"). APIM rewrites the
// backend's WWW-Authenticate resource_metadata URL and the PRM "resource" to the
// gateway by design; policies cannot override it.
//
// APIM appends the client's path below {gateway}/{apiPath} to the backend URL:
//   backend https://mcp.dev.azure.com/{org}, client {gateway}/{apiPath}
//   backend https://mcp.dev.azure.com,       client {gateway}/{apiPath}/{org}

param apimName string
param apiName string
param apiPath string
param displayName string

@description('Shown in the APIM portal next to the MCP server.')
param apiDescription string = ''

param backendName string
param appInsightsLoggerId string
param loggedHeaders array

@description('Path the client appends to {gateway}/{apiPath}, for example "/{organization}" for a bare-host backend.')
param clientPathSuffix string = ''

@minValue(0)
@maxValue(8192)
param requestBodyBytes int

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// The ARM schema for 2025-09-01-preview omits backendId, but the service and
// the Azure-Samples AI-Gateway apim-streamable-mcp module use it to forward to
// an existing MCP server. A live GET confirms it persists.
resource mcp 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: apim
  name: apiName
  properties: {
    type: 'mcp'
    displayName: displayName
    description: apiDescription
    path: apiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    #disable-next-line BCP037
    backendId: backendName
    mcpProperties: {
      transportType: 'streamable'
    }
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: mcp
  name: 'policy'
  properties: {
    format: 'rawxml'
    // Shared steps come from policy fragments (policy-fragments.bicep).
    value: loadTextContent('../policies/native-mcp.xml')
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

resource diagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: mcp
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

output url string = '${apim.properties.gatewayUrl}/${apiPath}${clientPathSuffix}'
