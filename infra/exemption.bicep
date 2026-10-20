targetScope = 'resourceGroup'

param assignmentId string
param expiresOn string
param policyDefinitionReferenceIds array = []

resource exemption 'Microsoft.Authorization/policyExemptions@2022-07-01-preview' = {
  name: 'resize-lab-${uniqueString(assignmentId)}'
  properties: {
    displayName: 'Temporary VM resize laboratory'
    description: 'Temporary laboratory measuring in-place resize of legacy VMs and HTTP downtime. The endpoint contains no sensitive data; NSG ingress is restricted to the monitoring IP. Resources and exemptions are removed after the experiment.'
    exemptionCategory: 'Waiver'
    policyAssignmentId: assignmentId
    policyDefinitionReferenceIds: policyDefinitionReferenceIds
    expiresOn: expiresOn
  }
}
