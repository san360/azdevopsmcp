using './main.bicep'

// Copy to main.local.bicepparam (gitignored) and fill in real values.
param apimName = 'apim-mcp-internal-example'
param publisherEmail = 'admin@example.com'
param customHostName = 'mcp.example.com'
param keyVaultName = 'kv-mcp-example'
// Your user object ID (az ad signed-in-user show --query id -o tsv).
param certificateOfficerPrincipalId = '00000000-0000-0000-0000-000000000000'
// Your public IP (for example from https://api.ipify.org) while you create and merge the certificate; [] afterwards.
param operatorAddressPrefixes = []
// Stage 1: leave empty. Stage 2: the Key Vault certificate name for customHostName.
param certificateName = ''
param appGatewaySku = 'Standard_v2'
param backendTimeoutSeconds = 240
param responseBuffering = false
// Log Analytics workspace resource ID (output workspaceId of infra/main.bicep).
param workspaceId = ''
