// Optional: creates a Developer-tier APIM instance. Skip it (createApim=false in
// main.bicep) to adopt an existing instance by name without redeploying it.
// infra/edge/main.bicep also uses it for an instance injected into a virtual
// network in internal mode, with a custom gateway host name from Key Vault.

param apimName string
param location string = resourceGroup().location

@secure()
param publisherEmail string
param publisherName string

@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
])
param skuName string = 'Developer'

@description('None (public), External or Internal. External/Internal need subnetId (Developer or Premium only).')
@allowed([
  'None'
  'External'
  'Internal'
])
param virtualNetworkType string = 'None'

@description('Subnet for virtual network injection; required unless virtualNetworkType is None.')
param subnetId string = ''

@description('User-assigned identity that reads the custom-domain certificate from Key Vault. Empty uses none.')
param userAssignedIdentityId string = ''

@description('Client ID of userAssignedIdentityId, used for the Key Vault certificate.')
param userAssignedIdentityClientId string = ''

@description('Custom gateway host name (for example mcp.example.com). Empty keeps only the default *.azure-api.net host.')
param customHostName string = ''

@description('Versionless Key Vault secret URI of the custom host certificate (https://<vault>.vault.azure.net/secrets/<name>).')
param certificateSecretUri string = ''

var useIdentity = !empty(userAssignedIdentityId)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: skuName
    capacity: 1
  }
  identity: useIdentity
    ? {
        type: 'SystemAssigned, UserAssigned'
        userAssignedIdentities: {
          '${userAssignedIdentityId}': {}
        }
      }
    : {
        type: 'SystemAssigned'
      }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: virtualNetworkType
    virtualNetworkConfiguration: virtualNetworkType == 'None'
      ? null
      : {
          subnetResourceId: subnetId
        }
    publicNetworkAccess: 'Enabled'
    hostnameConfigurations: empty(customHostName)
      ? null
      : [
          {
            type: 'Proxy'
            hostName: '${apimName}.azure-api.net'
            negotiateClientCertificate: false
            defaultSslBinding: false
            certificateSource: 'BuiltIn'
          }
          {
            type: 'Proxy'
            hostName: customHostName
            keyVaultId: certificateSecretUri
            identityClientId: userAssignedIdentityClientId
            negotiateClientCertificate: false
            defaultSslBinding: true
            certificateSource: 'KeyVault'
          }
        ]
  }
}

output gatewayUrl string = apim.properties.gatewayUrl
output privateIpAddress string = virtualNetworkType == 'None' ? '' : apim.properties.privateIPAddresses[0]
