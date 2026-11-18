using './main.bicep'

// Copy to main.local.bicepparam (gitignored) and fill in real values.
param gatewayName = 'aigw-mcp-lab-example'
param location = 'swedencentral'
param adoOrganization = 'example-organization'
// Object ID of the user who calls the MCP servers (az ad signed-in-user show --query id -o tsv).
param callerPrincipalId = '00000000-0000-0000-0000-000000000000'
