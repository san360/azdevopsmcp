// Service-wide telemetry for the APIM instance.
// Defaults never log bodies or credential-bearing headers. MCP responses are
// streamed (SSE), and response-body logging forces buffering, so response body
// bytes stay at 0 here. Request bodies are enabled only on the MCP APIs.

param apimName string
param appInsightsId string
param workspaceId string

@description('Request/response headers that are safe to log. Never add Authorization, Cookie or Mcp-Session-Id.')
param loggedHeaders array

@minValue(0)
@maxValue(100)
param samplingPercentage int = 100

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(appInsightsId, '/'))
}

resource aiLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for MCP gateway telemetry'
    resourceId: appInsights.id
    isBuffered: true
    credentials: {
      connectionString: appInsights.properties.ConnectionString
    }
  }
}

var headersOnly = {
  headers: loggedHeaders
  body: {
    bytes: 0
  }
}

resource aiDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: aiLogger.id
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: false
    metrics: true
    operationNameFormat: 'Name'
    sampling: {
      samplingType: 'fixed'
      percentage: samplingPercentage
    }
    frontend: {
      request: headersOnly
      response: headersOnly
    }
    backend: {
      request: headersOnly
      response: headersOnly
    }
  }
}

resource azureMonitorLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    isBuffered: true
  }
}

resource azureMonitorDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerId: azureMonitorLogger.id
    alwaysLog: 'allErrors'
    logClientIp: false
    verbosity: 'information'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: headersOnly
      response: headersOnly
    }
    backend: {
      request: headersOnly
      response: headersOnly
    }
  }
}

// Resource-specific tables: ApiManagementGatewayLogs and ApiManagementGatewayMCPLog.
resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'mcp-lab-to-log-analytics'
  scope: apim
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayMCPLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output appInsightsLoggerId string = aiLogger.id
output azureMonitorLoggerId string = azureMonitorLogger.id
