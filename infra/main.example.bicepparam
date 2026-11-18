using './main.bicep'

// Copy to main.local.bicepparam (gitignored) and fill in real values.
param apimName = 'apim-mcp-lab-example'
param adoOrganization = 'example-organization'
param tenantId = '00000000-0000-0000-0000-000000000000'
// Output of scripts/setup-entra.ps1. Leave empty to deploy only the native pass-through.
param publicClientId = ''
param createApim = false
param readOnly = true
param toolsets = ''
param mcpRequestBodyBytes = 4096
// Working setup: validate tools/call arguments of vetted tools (infra/schemas/tools/*.json).
param toolValidation = true
// 'allow' lets tools without a gateway schema through; 'deny' rejects them.
param unlistedToolAction = 'allow'
// Working setup: organizations accepted in {gateway}/ado-mcp-proxy/{org}; [] accepts any.
param allowedOrganizations = [
  'example-organization'
]
