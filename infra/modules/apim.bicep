// Optional: creates a Developer-tier APIM instance. Skip it (createApim=false in
// main.bicep) to adopt an existing instance by name without redeploying it.

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

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: skuName
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'None'
    publicNetworkAccess: 'Enabled'
  }
}

output gatewayUrl string = apim.properties.gatewayUrl
