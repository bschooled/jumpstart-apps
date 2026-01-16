@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Azure Container Registry name (must be globally unique, 5-50 alphanumeric).')
param registryName string

@description('ACR SKU tier.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Basic'

@description('Enable the ACR admin user (not recommended for production).')
param adminUserEnabled bool = false

@description('Enable the ACR dedicated data endpoint. Required for connected registries; will be forced to true when a connected registry is configured.')
param dataEndpointEnabled bool = false

@description('Object ID of the user principal to grant Owner on the registry.')
param userPrincipalObjectId string

@description('Connected registry name (5-50 alphanumeric). Leave empty to skip creating a connected registry.')
param connectedRegistryName string = ''

@description('Connected registry mode.')
@allowed([
  'ReadWrite'
  'ReadOnly'
  'Mirror'
])
param connectedRegistryMode string = 'ReadWrite'

@description('Optional parent connected registry resource ID. Leave empty to use the cloud registry as the parent (top-level connected registry).')
param connectedRegistryParentId string = ''

@description('Token name used by the connected registry for sync (5-50 alphanumeric). Required when connectedRegistryName is set.')
param connectedRegistryTokenName string = ''

@description('Scope map name for the connected registry token (5-50 alphanumeric, - and _ allowed). Required when connectedRegistryName is set.')
param connectedRegistryScopeMapName string = ''

@description('Scope map actions for connected registry token.')
param connectedRegistryScopeMapActions array = [
  'repositories/*/content/read'
  'repositories/*/content/delete'
  'repositories/*/metadata/read'
  'repositories/*/content/write'
  'repositories/*/metadata/write'
]

@description('Sync message TTL for connected registry (ISO8601 duration).')
param connectedRegistryMessageTtl string = 'P1D'

@description('Optional tags to apply to all resources.')
param tags object = {}

// Placeholder parameters for future AKS integration
@description('AKS cluster name (reserved for future use).')
param aksName string = ''

@description('AKS node resource group name (reserved for future use).')
param aksNodeResourceGroup string = ''

var enableConnectedRegistry = !empty(connectedRegistryName)
var effectiveRegistrySku = enableConnectedRegistry ? 'Premium' : registrySku
var effectiveDataEndpointEnabled = enableConnectedRegistry ? true : dataEndpointEnabled

var connectedRegistryGatewayActions = enableConnectedRegistry ? [
  'gateway/${toLower(connectedRegistryName)}/config/read'
  'gateway/${toLower(connectedRegistryName)}/config/write'
  'gateway/${toLower(connectedRegistryName)}/message/read'
  'gateway/${toLower(connectedRegistryName)}/message/write'
] : []

var connectedRegistryRequiredRepoActions = enableConnectedRegistry
  ? (connectedRegistryMode == 'ReadOnly'
      ? [
          'repositories/*/content/read'
          'repositories/*/metadata/read'
        ]
      : [
          'repositories/*/content/read'
          'repositories/*/content/write'
          'repositories/*/content/delete'
          'repositories/*/metadata/read'
          'repositories/*/metadata/write'
        ])
  : []

var connectedRegistryScopeMapEffectiveActions = concat(connectedRegistryScopeMapActions, connectedRegistryRequiredRepoActions, connectedRegistryGatewayActions)

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: effectiveRegistrySku
  }
  properties: {
    adminUserEnabled: adminUserEnabled
    dataEndpointEnabled: effectiveDataEndpointEnabled
  }
}

resource connectedRegistryScopeMap 'Microsoft.ContainerRegistry/registries/scopeMaps@2022-12-01' = if (enableConnectedRegistry) {
  name: connectedRegistryScopeMapName
  parent: acr
  properties: {
    description: 'Scope map for connected registry token.'
    actions: connectedRegistryScopeMapEffectiveActions
  }
}

resource connectedRegistryToken 'Microsoft.ContainerRegistry/registries/tokens@2022-12-01' = if (enableConnectedRegistry) {
  name: connectedRegistryTokenName
  parent: acr
  properties: {
    scopeMapId: connectedRegistryScopeMap.id
    status: 'enabled'
  }
}

resource connectedRegistry 'Microsoft.ContainerRegistry/registries/connectedRegistries@2023-08-01-preview' = if (enableConnectedRegistry) {
  name: connectedRegistryName
  parent: acr
  properties: {
    mode: connectedRegistryMode
    parent: empty(connectedRegistryParentId)
      ? {
          syncProperties: {
            tokenId: connectedRegistryToken.id
            messageTtl: connectedRegistryMessageTtl
          }
        }
      : {
          id: connectedRegistryParentId
          syncProperties: {
            tokenId: connectedRegistryToken.id
            messageTtl: connectedRegistryMessageTtl
          }
        }
  }
}

resource acrOwnerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, userPrincipalObjectId, 'acr-owner')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    principalId: userPrincipalObjectId
    principalType: 'User'
  }
}

output acrId string = acr.id
output acrLoginServer string = acr.properties.loginServer
output connectedRegistryId string = enableConnectedRegistry ? connectedRegistry.id : ''
