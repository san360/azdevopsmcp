// Key Vault (RBAC) for the custom-domain certificate, and the user-assigned
// identities Application Gateway and API Management use to read it.
//
// Network: the vault has no open public access.
//   - Private endpoint in the virtual network: App Gateway and APIM read the
//     certificate through it (private endpoint traffic bypasses perimeter rules).
//   - Network security perimeter (publicNetworkAccess = SecuredByPerimeter):
//     admits the operator's IP for the certificate request, merge and renewal,
//     and this subscription's managed identities. Policies that force public
//     access off (publicNetworkAccess = Disabled) accept SecuredByPerimeter.
//     App Gateway could not load the certificate through the perimeter alone
//     (its sslCertificates entry failed); APIM could.

param keyVaultName string
param location string = resourceGroup().location

@description('Principal that creates the certificate request and merges the issued certificate (Key Vault Certificates Officer). Empty skips it.')
param certificateOfficerPrincipalId string = ''

@description('Public IPv4 addresses or CIDRs allowed to reach the vault (certificate request and merge). Empty allows none; remove after the certificate is in place.')
param operatorAddressPrefixes array = []

param appGatewayIdentityName string
param apimIdentityName string

@description('Subnet for the vault\'s private endpoint.')
param privateEndpointSubnetId string

@description('Virtual network linked to the privatelink.vaultcore.azure.net zone.')
param vnetId string

var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultCertificatesOfficer = 'a4417e6f-fecd-4de8-b567-7b0420556985'

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'SecuredByPerimeter'
  }
}

resource perimeter 'Microsoft.Network/networkSecurityPerimeters@2024-07-01' = {
  name: 'nsp-${keyVaultName}'
  location: location
}

resource profile 'Microsoft.Network/networkSecurityPerimeters/profiles@2024-07-01' = {
  parent: perimeter
  name: 'certificates'
}

// Managed identities of resources in this subscription (Application Gateway, APIM).
resource allowSubscription 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2024-07-01' = {
  parent: profile
  name: 'allow-subscription-identities'
  properties: {
    direction: 'Inbound'
    subscriptions: [
      {
        id: subscription().id
      }
    ]
  }
}

resource allowOperator 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2024-07-01' = if (!empty(operatorAddressPrefixes)) {
  parent: profile
  name: 'allow-operator'
  properties: {
    direction: 'Inbound'
    addressPrefixes: operatorAddressPrefixes
  }
}

resource association 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2024-07-01' = {
  parent: perimeter
  name: 'key-vault'
  properties: {
    privateLinkResource: {
      id: vault.id
    }
    profile: {
      id: profile.id
    }
    accessMode: 'Enforced'
  }
  dependsOn: [
    allowSubscription
    allowOperator
  ]
}

resource privateZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

resource privateZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateZone
  name: 'link-edge-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${keyVaultName}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource privateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: privateZone.id
        }
      }
    ]
  }
}

resource appGatewayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appGatewayIdentityName
  location: location
}

resource apimIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: apimIdentityName
  location: location
}

// A certificate's private key is read through its secret.
resource appGatewayReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, appGatewayIdentity.id, keyVaultSecretsUser)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
    principalId: appGatewayIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apimReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, apimIdentity.id, keyVaultSecretsUser)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
    principalId: apimIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource officer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(certificateOfficerPrincipalId)) {
  name: guid(vault.id, certificateOfficerPrincipalId, keyVaultCertificatesOfficer)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCertificatesOfficer)
    principalId: certificateOfficerPrincipalId
  }
}

output vaultUri string = vault.properties.vaultUri
output appGatewayIdentityId string = appGatewayIdentity.id
output apimIdentityId string = apimIdentity.id
output apimIdentityClientId string = apimIdentity.properties.clientId
