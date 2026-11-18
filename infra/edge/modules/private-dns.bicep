// Split-horizon DNS: inside the virtual network a host name resolves to APIM's
// internal load balancer.
//   Custom host (recommended): zone = the public host itself, record '@', so no
//     other name of the public domain is shadowed in this network.
//   Default host: zone azure-api.net, record = the APIM instance name.

param zoneName string
param recordName string = '@'
param apimPrivateIp string
param vnetId string

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
}

resource record 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: recordName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: apimPrivateIp
      }
    ]
  }
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'link-edge-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}
