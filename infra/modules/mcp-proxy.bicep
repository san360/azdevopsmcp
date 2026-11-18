// Working setup: an APIM MCP server (native pass-through, like the regular
// setup) for the hosted Azure DevOps MCP server, plus the plain APIs MCP clients
// need to sign in through the gateway URL. No HTTP API with MCP operations.
// One deployment serves many organizations.
//
// Isolation: every route lives under the dedicated path {proxyPath}. Nothing is
// mounted at the gateway root, so other APIs on the same APIM instance (and
// their /authorize, /token, /.well-known/... routes) are never shadowed.
//
//   client URL {gw}/{proxyPath}/{org}  ->  https://mcp.dev.azure.com/{org}
//   client URL {gw}/{proxyPath}        ->  https://mcp.dev.azure.com (orgName per tool call)
//
//   MCP client -> POST {gw}/{proxyPath}/{org}            401 + resource_metadata (APIM MCP server)
//              -> GET  {gw}/{proxyPath}/.well-known/oauth-protected-resource/{org}   (PRM API, not APIM's built-in)
//              -> GET  {gw}/.well-known/oauth-authorization-server/{proxyPath}/oauth (issuer {gw}/{proxyPath}/oauth)
//              -> POST {gw}/{proxyPath}/oauth/register   static public client ID (DCR compatibility)
//              -> GET  {gw}/{proxyPath}/oauth/authorize  302 to Entra with resource=https://mcp.dev.azure.com
//              -> POST {gw}/{proxyPath}/oauth/token      forwarded to Entra with resource=https://mcp.dev.azure.com
//              -> POST {gw}/{proxyPath}/{org} + Bearer   forwarded unchanged by the MCP server
//
// Discovery aliases (rootDiscoveryAliases) serve the same metadata at the
// RFC 9728 / RFC 8414 path-inserted locations. Every CLI tested fetched the
// authorization-server metadata there; Codex and Claude Code fail without them.
// Each alias is its own API whose path ends in /{proxyPath}, so it only
// answers for this setup:
//   {gw}/.well-known/oauth-protected-resource/{proxyPath}[/{org}]
//   {gw}/.well-known/oauth-authorization-server/{proxyPath}/oauth
//   {gw}/.well-known/openid-configuration/{proxyPath}/oauth

param apimName string

@description('Backend entity for the bare host https://mcp.dev.azure.com.')
param backendName string
param appInsightsLoggerId string
param loggedHeaders array

@description('Entra tenant that owns the Azure DevOps organizations, or "organizations" when they span tenants.')
param tenantId string

@description('Pre-registered Entra public client returned by /register.')
param clientId string

@description('Dedicated path of the working setup. The MCP proxy, its OAuth endpoints ({proxyPath}/oauth) and its metadata all live under it.')
param proxyPath string

@description('Also serve the metadata at the path-inserted /.well-known/.../{proxyPath} locations. Required by OpenAI Codex and Claude Code; each alias only matches this setup\'s path.')
param rootDiscoveryAliases bool = true

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

// Issuer path of the gateway's OAuth compatibility endpoints, relative to the host.
var oauthPath = '${proxyPath}/oauth'

var oauthValues = {
  TENANT_ID: tenantId
  SCOPE: adoScope
  SCOPE_ENC: uriComponent(adoScope)
  RESOURCE_ENC: uriComponent(adoResource)
  CLIENT_ID: clientId
  PROXY_PATH: proxyPath
  OAUTH_PATH: oauthPath
}

var orgParameter = [
  {
    name: 'org'
    type: 'string'
    required: true
    description: 'Azure DevOps organization name'
  }
]

// ---------------------------------------------------------------- MCP server

// An APIM MCP server (native pass-through, listed under "MCP servers"), like the
// regular setup. APIM answers the 401 itself with
//   resource_metadata="{gw}/{proxyPath}/.well-known/oauth-protected-resource[/{org}]"
// and the more specific HTTP API below serves that URL, so the PRM names the
// gateway's OAuth facade instead of Entra. That one difference makes sign-in work.
resource mcpServer 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: apim
  name: proxyPath
  properties: {
    type: 'mcp'
    displayName: 'Azure DevOps MCP (working, ${proxyPath})'
    description: 'Working setup: APIM native MCP pass-through to the hosted Azure DevOps MCP server, with governance (org allow-list, read-only header, rate limit, header hygiene, telemetry). Sign-in works through the gateway OAuth facade under /${oauthPath}; Azure DevOps sees the signed-in user.'
    path: proxyPath
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

resource mcpServerPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: mcpServer
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: fill(loadTextContent('../policies/proxy-mcp.xml'), {
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

resource mcpServerDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: mcpServer
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

// One API at {proxyPath}/oauth holds every OAuth endpoint. APIM routes to the
// most specific API path, so {proxyPath}/oauth/... never reaches the MCP
// server. (Side effect: an organization literally named "oauth" can
// only be used through the bare endpoint with orgName.)
var prmOperations = [
  {
    name: 'protected-resource-metadata'
    method: 'GET'
    urlTemplate: '/'
    templateParameters: []
    policy: 'oauth-prm'
  }
  {
    name: 'protected-resource-metadata-org'
    method: 'GET'
    urlTemplate: '/{org}'
    templateParameters: orgParameter
    policy: 'oauth-prm'
  }
]

var oauthApis = concat(
  [
    {
      // The URL the MCP server's 401 challenge names (APIM generates it). This
      // more specific API answers it instead of APIM's built-in metadata.
      name: '${proxyPath}-prm'
      path: '${proxyPath}/.well-known/oauth-protected-resource'
      displayName: 'Azure DevOps MCP protected-resource metadata (${proxyPath})'
      description: 'RFC 9728 metadata for {gateway}/${proxyPath}[/{org}]: names the gateway OAuth facade, not Entra, as authorization server.'
      operations: prmOperations
    }
    {
      name: '${proxyPath}-oauth'
      path: oauthPath
      displayName: 'Azure DevOps MCP OAuth compatibility (${proxyPath})'
      description: 'OAuth metadata, client registration, authorize and token endpoints of the working setup, under its dedicated path.'
      operations: [
        // Authorization-server metadata at the issuer's path-appended locations.
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
    }
  ],
  rootDiscoveryAliases
    ? [
        {
          name: '${proxyPath}-discovery-prm'
          path: '.well-known/oauth-protected-resource/${proxyPath}'
          displayName: 'Azure DevOps MCP discovery alias: PRM (${proxyPath})'
          description: 'RFC 9728 path-inserted protected-resource metadata for {gateway}/${proxyPath}[/{org}] only.'
          operations: prmOperations
        }
        {
          name: '${proxyPath}-discovery-as'
          path: '.well-known/oauth-authorization-server/${proxyPath}'
          displayName: 'Azure DevOps MCP discovery alias: OAuth metadata (${proxyPath})'
          description: 'RFC 8414 path-inserted authorization-server metadata for the issuer {gateway}/${oauthPath} only.'
          operations: [
            {
              name: 'authorization-server-metadata'
              method: 'GET'
              urlTemplate: '/oauth'
              templateParameters: []
              policy: 'oauth-as-metadata'
            }
          ]
        }
        {
          name: '${proxyPath}-discovery-oidc'
          path: '.well-known/openid-configuration/${proxyPath}'
          displayName: 'Azure DevOps MCP discovery alias: OpenID metadata (${proxyPath})'
          description: 'OpenID Connect path-inserted metadata for the issuer {gateway}/${oauthPath} only.'
          operations: [
            {
              name: 'openid-configuration'
              method: 'GET'
              urlTemplate: '/oauth'
              templateParameters: []
              policy: 'oauth-as-metadata'
            }
          ]
        }
      ]
    : []
)

resource oauthApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = [
  for api in oauthApis: {
    parent: apim
    name: api.name
    properties: {
      type: 'http'
      displayName: api.displayName
      description: api.description
      path: api.path
      protocols: [
        'https'
      ]
      subscriptionRequired: false
    }
  }
]

resource oauthApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = [
  for (api, i) in oauthApis: {
    parent: oauthApi[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: '<policies><inbound><cors allow-credentials="false"><allowed-origins><origin>*</origin></allowed-origins><allowed-methods><method>GET</method><method>POST</method></allowed-methods><allowed-headers><header>*</header></allowed-headers></cors><base /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
    }
  }
]

var oauthOperations = flatten(map(range(0, length(oauthApis)), i => map(oauthApis[i].operations, op => union(op, { api: i }))))

var oauthPolicies = {
  'oauth-prm': fill(loadTextContent('../policies/oauth-prm.xml'), oauthValues)
  'oauth-as-metadata': fill(loadTextContent('../policies/oauth-as-metadata.xml'), oauthValues)
  'oauth-register': fill(loadTextContent('../policies/oauth-register.xml'), oauthValues)
  'oauth-authorize': fill(loadTextContent('../policies/oauth-authorize.xml'), oauthValues)
  'oauth-token': fill(loadTextContent('../policies/oauth-token.xml'), oauthValues)
}

resource oauthOps 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [
  for op in oauthOperations: {
    parent: oauthApi[op.api]
    name: op.name
    properties: {
      displayName: op.name
      method: op.method
      urlTemplate: op.urlTemplate
      templateParameters: op.templateParameters
    }
    // Parallel writes to one API can fail with PreconditionFailed; write the API policy first.
    dependsOn: [
      oauthApiPolicy
    ]
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
resource oauthDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = [
  for (api, i) in oauthApis: {
    parent: oauthApi[i]
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
]

output proxyBaseUrl string = '${apim.properties.gatewayUrl}/${proxyPath}'
output oauthIssuer string = '${apim.properties.gatewayUrl}/${oauthPath}'
output apiNames array = concat([mcpServer.name], map(oauthApis, api => api.name))
