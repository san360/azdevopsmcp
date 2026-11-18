// MCP tool-argument validation: one APIM schema resource per vetted tool (JSON-RPC
// tools/call envelope + curated argument schema) and a policy fragment that selects the
// schema by tool name and answers violations with a JSON-RPC error.
//
// To vet another tool: add infra/schemas/tools/<tool>.json and one entry to `tools`.

param apimName string

@description('Reject tools/call for tools without a gateway schema (true) or let them through (false).')
param denyUnlistedTools bool

@description('Lab-only: include the raw validate-content errors in rejection responses. Never enable in production: errors can echo submitted values.')
param debugRawErrors bool = false

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

var tools = [
  {
    name: 'core_list_projects'
    arguments: loadJsonContent('../schemas/tools/core_list_projects.json')
  }
  {
    name: 'wit_work_item'
    arguments: loadJsonContent('../schemas/tools/wit_work_item.json')
  }
]

resource schemas 'Microsoft.ApiManagement/service/schemas@2024-05-01' = [
  for tool in tools: {
    parent: apim
    name: 'mcp-tool-${replace(tool.name, '_', '-')}'
    properties: {
      schemaType: 'json'
      description: 'JSON-RPC tools/call request for ${tool.name} with curated arguments'
      document: {
        '$schema': 'http://json-schema.org/draft-07/schema#'
        type: 'object'
        required: [
          'jsonrpc'
          'id'
          'method'
          'params'
        ]
        properties: {
          jsonrpc: {
            const: '2.0'
          }
          id: {
            type: [
              'string'
              'integer'
            ]
          }
          method: {
            const: 'tools/call'
          }
          params: {
            type: 'object'
            additionalProperties: false
            required: [
              'name'
            ]
            properties: {
              name: {
                const: tool.name
              }
              arguments: tool.arguments
              _meta: {
                type: 'object'
              }
            }
          }
        }
      }
    }
  }
]

var branches = join(
  map(
    tools,
    tool =>
      '<when condition="@((string)context.Variables[&quot;mcp-tool&quot;] == &quot;${tool.name}&quot;)"><validate-content unspecified-content-type-action="ignore" max-size="65536" size-exceeded-action="detect" errors-variable-name="mcp-validation-errors"><content-type-map any-content-type-value="application/json" /><content type="application/json" validate-as="json" schema-id="mcp-tool-${replace(tool.name, '_', '-')}" action="detect" /></validate-content></when>'
  ),
  ''
)

resource fragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'mcp-tool-validation'
  properties: {
    description: 'Validates MCP tools/call arguments against curated schemas'
    format: 'rawxml'
    value: replace(
      replace(
        replace(
          replace(loadTextContent('../policies/fragments/tool-validation.xml'), '__TOOL_BRANCHES__', branches),
          '__VETTED_TOOLS__',
          join(map(tools, t => t.name), ',')
        ),
        '__DENY_UNLISTED__',
        denyUnlistedTools ? 'true' : 'false'
      ),
      '__DEBUG_RAW__',
      debugRawErrors
        ? ', new JProperty(&quot;raw&quot;, JArray.Parse(JsonConvert.SerializeObject(context.Variables.GetValueOrDefault&lt;object&gt;(&quot;mcp-validation-errors&quot;))))'
        : ''
    )
  }
  dependsOn: [
    schemas
  ]
}

output fragmentName string = fragment.name
output vettedTools array = map(tools, t => t.name)
