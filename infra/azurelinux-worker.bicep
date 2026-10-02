targetScope = 'resourceGroup'

@description('Azure region for the worker resources.')
param location string = resourceGroup().location

@description('Existing virtual network name.')
param virtualNetworkName string = 'vnet-zava-rehearsal-wus2'

@description('Existing workload subnet name.')
param subnetName string = 'snet-zava-workload'

@description('Azure Linux worker VM name.')
param vmName string = 'azurelinux-worker'

@description('Static private address reserved for the Azure Linux worker.')
param privateIpAddress string = '192.168.90.15'

@description('Administrator account used by the private management VM.')
param adminUsername string = 'estate'

@secure()
@description('SSH public key derived from the private management VM key.')
param sshPublicKey string

@description('Cobalt 200 VM size.')
param vmSize string = 'Standard_D2ps_v7'

@description('Pinned Azure Linux Marketplace image version. Use latest only during image qualification.')
param imageVersion string = '4.0.2026092502'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: subnetName
}

resource workerNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: subnet.id
          }
        }
      }
    ]
  }
}

resource workerVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: {
      securityType: 'Standard'
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'ImageDefault'
          patchMode: 'ImageDefault'
        }
        ssh: {
          publicKeys: [
            {
              keyData: sshPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftAzureLinux'
        offer: 'azurelinux-4'
        sku: '4-arm64'
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: workerNic.id
          properties: {
            deleteOption: 'Delete'
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmId string = workerVm.id
output nicId string = workerNic.id
output privateIpAddress string = privateIpAddress
output imageUrn string = 'MicrosoftAzureLinux:azurelinux-4:4-arm64:${imageVersion}'
