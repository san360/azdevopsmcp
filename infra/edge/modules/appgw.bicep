// Application Gateway in front of API Management (internal mode).
//
//   client --TLS {hostName}--> listener (Key Vault certificate)
//          --path rules-->     backend pool: {hostName}, which the private DNS
//                              zone resolves to APIM's internal IP
//          --TLS {hostName}--> APIM (same custom host name and certificate)
//
// The host name stays the same end to end, so every URL APIM builds from the
// request (the MCP 401 resource_metadata, PRM resource, OAuth issuer) is the
// public one. Only the MCP paths are routed; any other path goes to an empty
// pool (502), so other APIs on the same APIM instance stay unreachable.

param appGatewayName string
param location string = resourceGroup().location

@description('Standard_v2 (autoscale 0-2). Basic is the cheapest v2 SKU (preview; no WAF, autoscale, URL rewrite, mTLS or Private Link). WAF_v2 adds the web application firewall.')
@allowed([
  'Basic'
  'Standard_v2'
  'WAF_v2'
])
param skuName string = 'Standard_v2'

param subnetId string
param identityId string

@description('Public host name of the listener.')
param hostName string

@description('Host App Gateway sends to APIM: the public host (APIM has it as custom host; recommended) or APIM\'s default *.azure-api.net host. With another host, App Gateway rewrites it back in the 401 challenge.')
param backendHostName string = hostName

@description('Versionless Key Vault secret URI of the certificate for hostName.')
param certificateSecretUri string

@description('Paths routed to APIM (App Gateway syntax: exact, or ending in /*).')
param routedPaths array

@description('Seconds App Gateway waits for the backend response. MCP tool calls and SSE streams can be long.')
@minValue(1)
@maxValue(86400)
param backendTimeoutSeconds int = 240

@description('Buffer backend responses before sending them to clients. Off streams SSE events as they arrive.')
param responseBuffering bool = false

@description('Log Analytics workspace for access logs. Empty skips diagnostics.')
param workspaceId string = ''

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${appGatewayName}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

var gwId = resourceId('Microsoft.Network/applicationGateways', appGatewayName)
var rewriteChallenge = toLower(backendHostName) != toLower(hostName)

resource appGateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: appGatewayName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    sku: {
      name: skuName
      tier: skuName
    }
    autoscaleConfiguration: skuName == 'Basic'
      ? null
      : {
          minCapacity: 0
          maxCapacity: 2
        }
    gatewayIPConfigurations: [
      {
        name: 'gateway-ip'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'public'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'https'
        properties: {
          port: 443
        }
      }
    ]
    sslCertificates: [
      {
        name: 'custom-host'
        properties: {
          keyVaultSecretId: certificateSecretUri
        }
      }
    ]
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    backendAddressPools: [
      {
        name: 'apim'
        properties: {
          backendAddresses: [
            {
              fqdn: backendHostName
            }
          ]
        }
      }
      {
        // Default for unrouted paths: no members, so App Gateway answers 502.
        name: 'unrouted'
        properties: {
          backendAddresses: []
        }
      }
    ]
    probes: [
      {
        name: 'apim-status'
        properties: {
          protocol: 'Https'
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'apim-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          // APIM only answers its configured host names (404 otherwise) and
          // builds its 401 challenge URL from this host.
          hostName: backendHostName
          pickHostNameFromBackendAddress: false
          requestTimeout: backendTimeoutSeconds
          probe: {
            id: '${gwId}/probes/apim-status'
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'https'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/public'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/https'
          }
          protocol: 'Https'
          sslCertificate: {
            id: '${gwId}/sslCertificates/custom-host'
          }
          hostName: hostName
          requireServerNameIndication: true
        }
      }
    ]
    urlPathMaps: [
      {
        name: 'mcp-paths'
        properties: {
          defaultBackendAddressPool: {
            id: '${gwId}/backendAddressPools/unrouted'
          }
          defaultBackendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/apim-https'
          }
          pathRules: [
            {
              name: 'mcp'
              properties: {
                paths: routedPaths
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/apim'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/apim-https'
                }
                rewriteRuleSet: {
                  id: '${gwId}/rewriteRuleSets/mcp-headers'
                }
              }
            }
          ]
        }
      }
    ]
    rewriteRuleSets: [
      {
        name: 'mcp-headers'
        properties: {
          rewriteRules: concat(
            [
              {
                // The public host, for the PRM and OAuth metadata policies
                // (named value mcp-trust-forwarded-for). Overrides any client value.
                name: 'forwarded-host'
                ruleSequence: 100
                conditions: []
                actionSet: {
                  requestHeaderConfigurations: [
                    {
                      headerName: 'X-Forwarded-Host'
                      headerValue: '{var_host}'
                    }
                  ]
                  responseHeaderConfigurations: []
                }
              }
            ],
            rewriteChallenge
              ? [
                  {
                    // APIM names its own host in resource_metadata; clients
                    // cannot reach it, so put the public host back.
                    name: 'challenge-host'
                    ruleSequence: 200
                    conditions: [
                      {
                        variable: 'http_resp_WWW-Authenticate'
                        pattern: '(.*)https://${replace(backendHostName, '.', '\\.')}(.*)'
                        ignoreCase: true
                        negate: false
                      }
                    ]
                    actionSet: {
                      requestHeaderConfigurations: []
                      responseHeaderConfigurations: [
                        {
                          headerName: 'WWW-Authenticate'
                          headerValue: '{http_resp_WWW-Authenticate_1}https://{var_host}{http_resp_WWW-Authenticate_2}'
                        }
                      ]
                    }
                  }
                ]
              : []
          )
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'mcp'
        properties: {
          ruleType: 'PathBasedRouting'
          priority: 100
          httpListener: {
            id: '${gwId}/httpListeners/https'
          }
          urlPathMap: {
            id: '${gwId}/urlPathMaps/mcp-paths'
          }
        }
      }
    ]
    globalConfiguration: {
      enableRequestBuffering: true
      enableResponseBuffering: responseBuffering
    }
  }
}

// Resource-specific table AGWAccessLogs (client IP, host, URI, status, timings).
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'appgw-to-log-analytics'
  scope: appGateway
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
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

output publicIpAddress string = publicIp.properties.ipAddress
output appGatewayId string = appGateway.id
