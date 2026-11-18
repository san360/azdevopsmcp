// Application Gateway in front of API Management (internal mode).
//
//   client --TLS {hostName}--> listener (Key Vault certificate)
//          --path rules-->     backend pool: {backendHostName}, which a private
//                              DNS zone resolves to APIM's internal IP
//          --TLS {backendHostName}--> APIM
//
// One listener, backend pool, backend setting, path map, rewrite set and
// routing rule per entry of `sites`, so hosts with different backend hosts run
// side by side:
//   backendHostName = hostName (APIM has it as custom host): every URL APIM
//     builds from the request (MCP 401 resource_metadata, PRM resource, OAuth
//     issuer) is already the public one.
//   backendHostName = <apim>.azure-api.net (no custom domain on APIM): App
//     Gateway puts the public host back into the 401 challenge, and the
//     policies build their URLs from X-Forwarded-Host.
// Only the MCP paths are routed; any other path goes to an empty pool (502), so
// other APIs on the same APIM instance stay unreachable.

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

@description('Public hosts, one listener and routing rule each. hostName: public host (listener, SNI). backendHostName: Host sent to APIM, either hostName itself (APIM has it as custom host; recommended) or APIM\'s default *.azure-api.net host (App Gateway then rewrites it back in the 401 challenge). certificateSecretUri: versionless Key Vault secret URI of the certificate for hostName. The first entry keeps the original resource names.')
@minLength(1)
param sites site[]

@export()
type site = {
  hostName: string
  backendHostName: string
  certificateSecretUri: string
}

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

// The first site keeps the names of the single-host template, so existing
// gateways update in place.
func suffix(i int) string => i == 0 ? '' : '-${i + 1}'

func challengeRule(backendHostName string) object => {
  // APIM names the host it was called on in resource_metadata; clients cannot
  // reach it, so put the public host back.
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

var forwardedHostRule = {
  // The host the client used, for the PRM and OAuth metadata policies (named
  // value mcp-trust-forwarded-for). Overrides any client value.
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

var sitePools = [
  for (s, i) in sites: {
    name: 'apim${suffix(i)}'
    properties: {
      backendAddresses: [
        {
          fqdn: s.backendHostName
        }
      ]
    }
  }
]

var unroutedPool = {
  // Default for unrouted paths: no members, so App Gateway answers 502.
  name: 'unrouted'
  properties: {
    backendAddresses: []
  }
}

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
      for (s, i) in sites: {
        name: i == 0 ? 'custom-host' : 'host${suffix(i)}'
        properties: {
          keyVaultSecretId: s.certificateSecretUri
        }
      }
    ]
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    backendAddressPools: concat(sitePools, [unroutedPool])
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
      for (s, i) in sites: {
        name: 'apim-https${suffix(i)}'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          // APIM only answers its configured host names (404 otherwise) and
          // builds its 401 challenge URL from this host.
          hostName: s.backendHostName
          pickHostNameFromBackendAddress: false
          requestTimeout: backendTimeoutSeconds
          probe: {
            id: '${gwId}/probes/apim-status'
          }
        }
      }
    ]
    httpListeners: [
      for (s, i) in sites: {
        name: 'https${suffix(i)}'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/public'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/https'
          }
          protocol: 'Https'
          sslCertificate: {
            id: '${gwId}/sslCertificates/${i == 0 ? 'custom-host' : 'host${suffix(i)}'}'
          }
          hostName: s.hostName
          requireServerNameIndication: true
        }
      }
    ]
    urlPathMaps: [
      for (s, i) in sites: {
        name: 'mcp-paths${suffix(i)}'
        properties: {
          defaultBackendAddressPool: {
            id: '${gwId}/backendAddressPools/unrouted'
          }
          defaultBackendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/apim-https${suffix(i)}'
          }
          pathRules: [
            {
              name: 'mcp'
              properties: {
                paths: routedPaths
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/apim${suffix(i)}'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/apim-https${suffix(i)}'
                }
                rewriteRuleSet: {
                  id: '${gwId}/rewriteRuleSets/mcp-headers${suffix(i)}'
                }
              }
            }
          ]
        }
      }
    ]
    // X-Forwarded-Host on every site; the challenge rewrite only where APIM is
    // called on another host than the client used.
    rewriteRuleSets: [
      for (s, i) in sites: {
        name: 'mcp-headers${suffix(i)}'
        properties: {
          rewriteRules: toLower(s.backendHostName) == toLower(s.hostName)
            ? [forwardedHostRule]
            : [forwardedHostRule, challengeRule(s.backendHostName)]
        }
      }
    ]
    requestRoutingRules: [
      for (s, i) in sites: {
        name: 'mcp${suffix(i)}'
        properties: {
          ruleType: 'PathBasedRouting'
          priority: 100 + 10 * i
          httpListener: {
            id: '${gwId}/httpListeners/https${suffix(i)}'
          }
          urlPathMap: {
            id: '${gwId}/urlPathMaps/mcp-paths${suffix(i)}'
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
