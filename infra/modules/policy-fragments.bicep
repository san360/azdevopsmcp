// Shared policy building blocks for both setups: named values (settings an operator
// can change in the portal without redeploying) and the policy fragments that read
// them. Policies include a fragment with <include-fragment fragment-id="..." />.
//
//   fragment               used by                                  reads named value
//   mcp-org-validation     proxy-mcp.xml, oauth-prm.xml             mcp-allowed-organizations
//   mcp-caller-identity    proxy-mcp.xml, native-mcp.xml            -
//   mcp-backend-headers    proxy-mcp.xml, native-mcp.xml            mcp-readonly, mcp-toolsets
//   mcp-response-headers   proxy-mcp.xml, native-mcp.xml, oauth-token.xml

param apimName string

@description('Organizations accepted in {gateway}/{api}/{org}. Empty accepts any well-formed name.')
param allowedOrganizations array

@description('Send X-MCP-Readonly: true to Azure DevOps.')
param readOnly bool

@description('Comma-separated X-MCP-Toolsets; empty sends no header.')
param toolsets string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// Named values cannot be empty, so "*" means "no restriction".
var namedValues = [
  {
    name: 'mcp-allowed-organizations'
    value: empty(allowedOrganizations) ? '*' : join(allowedOrganizations, ',')
  }
  {
    name: 'mcp-readonly'
    value: readOnly ? 'true' : 'false'
  }
  {
    name: 'mcp-toolsets'
    value: empty(toolsets) ? '*' : toolsets
  }
]

resource settings 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [
  for nv in namedValues: {
    parent: apim
    name: nv.name
    properties: {
      displayName: nv.name
      value: nv.value
      secret: false
      tags: [
        'ado-mcp'
      ]
    }
  }
]

var fragments = [
  {
    name: 'mcp-org-validation'
    description: 'Reads {org} from the URL and rejects malformed or not allowed organizations with 404'
    value: loadTextContent('../policies/fragments/org-validation.xml')
  }
  {
    name: 'mcp-caller-identity'
    description: 'Sets caller-oid and caller-app-id from the bearer token claims, for telemetry only'
    value: loadTextContent('../policies/fragments/caller-identity.xml')
  }
  {
    name: 'mcp-backend-headers'
    description: 'Strips spoofable headers and adds X-MCP-Readonly / X-MCP-Toolsets'
    value: loadTextContent('../policies/fragments/backend-headers.xml')
  }
  {
    name: 'mcp-response-headers'
    description: 'Adds Cache-Control: no-store and x-apim-request-id to responses'
    value: loadTextContent('../policies/fragments/response-headers.xml')
  }
]

resource fragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = [
  for f in fragments: {
    parent: apim
    name: f.name
    properties: {
      description: f.description
      format: 'rawxml'
      value: f.value
    }
    // Fragments reference named values, which must exist first.
    dependsOn: [
      settings
    ]
  }
]

output fragmentNames array = [for (f, i) in fragments: fragment[i].name]
