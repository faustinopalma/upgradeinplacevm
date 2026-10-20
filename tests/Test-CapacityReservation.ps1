$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\CapacityReservation.ps1')
$crgId = '/subscriptions/test/resourceGroups/lab/providers/Microsoft.Compute/capacityReservationGroups/resize-capacity'
$vmId = '/subscriptions/test/resourceGroups/lab/providers/Microsoft.Compute/virtualMachines/test-vm'

function New-TestState {
    $script:reservation = [pscustomobject]@{
        id="$crgId/capacityReservations/target-slots";location='westeurope';zones=$null;provisioningState='Succeeded'
        sku=[pscustomobject]@{name='Standard_D2ds_v5';capacity=2}
        instanceView=[pscustomobject]@{utilizationInfo=[pscustomobject]@{currentCapacity=2;virtualMachinesAllocated=@()}}
    }
    $script:model = [pscustomobject]@{
        id=$vmId;location='westeurope';zones=$null;availabilitySet=$null;host=$null;proximityPlacementGroup=$null
        priority='Regular';hardwareProfile=[pscustomobject]@{vmSize='Standard_D2_v2'}
        capacityReservation=[pscustomobject]@{capacityReservationGroup=[pscustomobject]@{id=$null}}
    }
    $script:powerState = 'PowerState/running'
    $script:calls = [System.Collections.Generic.List[string]]::new()
    $script:eventNames = [System.Collections.Generic.List[string]]::new()
    $script:failStart = $false
    $script:ignoreAssociation = $false
    $script:ignoreRelease = $false
    $script:reservationDeleted = $false
    $script:groupDeleted = $false
    $script:failReservationCreate = $false
}

function Write-Event([string]$Name, $Data) { $script:eventNames.Add($Name) }

function Invoke-Az([string[]]$Arguments) {
    $verb = ($Arguments | Select-Object -First 3) -join ' '
    $script:calls.Add($Arguments -join ' ')
    $data = $null
    switch ($verb) {
        'vm show -g' { $data = $script:model }
        'vm get-instance-view -g' { return [pscustomobject]@{Text=$script:powerState;ElapsedMs=1;ExitCode=0} }
        'capacity reservation show' { $data = $script:reservation }
        'capacity reservation create' {
            if ($script:failReservationCreate) { throw 'Simulated reservation capacity failure.' }
            $script:reservation.sku.capacity = [int]$Arguments[[array]::IndexOf($Arguments, '--capacity') + 1]
        }
        'vm deallocate -g' { $script:powerState = 'PowerState/deallocated' }
        'vm resize -g' { $script:model.hardwareProfile.vmSize = $Arguments[[array]::IndexOf($Arguments, '--size') + 1] }
        'vm update -g' {
            $id = $Arguments[[array]::IndexOf($Arguments, '--capacity-reservation-group') + 1]
            if (!$script:ignoreAssociation) {
                $script:model.capacityReservation.capacityReservationGroup.id = if ($id -eq 'None') { $null } else { $id }
            }
        }
        'vm start -g' {
            if ($script:failStart) { throw 'Simulated allocation failure despite reservation.' }
            if ($script:model.capacityReservation.capacityReservationGroup.id -ne $crgId) { throw 'Test detected unreserved start.' }
            $script:powerState = 'PowerState/running'
            $script:reservation.instanceView.utilizationInfo.virtualMachinesAllocated = @([pscustomobject]@{id=$vmId})
        }
        'capacity reservation update' { if (!$script:ignoreRelease) { $script:reservation.sku.capacity = 0 } }
        'capacity reservation delete' { $script:reservationDeleted = $true }
        'capacity reservation list' { $data = @() }
        'capacity reservation group' {
            if ($Arguments[3] -eq 'create') { $data = @{id=$crgId} }
            elseif ($Arguments[3] -eq 'delete') { $script:groupDeleted = $true }
            elseif ($Arguments[3] -eq 'list') { $data = @() }
            else { throw "Unexpected test call: $($Arguments -join ' ')" }
        }
        default { throw "Unexpected test call: $($Arguments -join ' ')" }
    }
    return [pscustomobject]@{Text=(ConvertTo-Json -InputObject $data -Depth 30 -Compress);ElapsedMs=1;ExitCode=0}
}

function Invoke-TestResize {
    Invoke-CapacityReservedResize 'lab' 'test-vm' 'westeurope' 'Standard_D2ds_v5' 'resize-capacity' 'target-slots' $crgId 2
}

function Assert-BlockedBeforeStop([scriptblock]$Arrange) {
    New-TestState
    & $Arrange
    $failed = $false
    try { $null = Invoke-TestResize } catch {
        $failed = $true
        if ($_.Exception.Message -notmatch 'NO-GO') { throw }
    }
    if (!$failed) { throw 'Invalid preflight was accepted.' }
    if (@($script:calls | Where-Object { $_ -match '^vm (deallocate|resize|update|start) ' }).Count) {
        throw 'Source VM was modified before the capacity gate passed.'
    }
}

Assert-BlockedBeforeStop { $script:reservation.provisioningState = 'Failed' }
Assert-BlockedBeforeStop { $script:reservation.sku.name = 'Standard_D4ds_v5' }
Assert-BlockedBeforeStop { $script:reservation.location = 'southafricanorth' }
Assert-BlockedBeforeStop { $script:reservation.zones = @('1') }
Assert-BlockedBeforeStop { $script:reservation.sku.capacity = 1 }
Assert-BlockedBeforeStop { $script:reservation.instanceView.utilizationInfo.currentCapacity = 1 }
Assert-BlockedBeforeStop { $script:reservation.instanceView.utilizationInfo.currentCapacity = $null }
Assert-BlockedBeforeStop { $script:reservation.instanceView.utilizationInfo.virtualMachinesAllocated = @([pscustomobject]@{id='another-vm'}) }
Assert-BlockedBeforeStop { $script:reservation.id = '/wrong/group/reservation' }
Assert-BlockedBeforeStop { $script:model.availabilitySet = @{id='unsupported-availability-set'} }
Assert-BlockedBeforeStop { $script:model.zones = @('1') }
Assert-BlockedBeforeStop { $script:model.capacityReservation.capacityReservationGroup.id = '/existing/group' }
Assert-BlockedBeforeStop { $script:powerState = 'PowerState/deallocated' }

New-TestState
$created = New-LabTargetReservation 'lab' 'westeurope' 'Standard_D2ds_v5' 2
if ($created.id -ne $crgId -or 'all-target-capacity-reserved' -notin $script:eventNames -or
    @($script:calls | Where-Object { $_ -match '^vm ' }).Count) { throw 'Target reservation creation did not precede VM operations.' }
New-TestState
$script:failReservationCreate = $true
$failed = $false
try { $null = New-LabTargetReservation 'lab' 'westeurope' 'Standard_D2ds_v5' 2 } catch {
    if ($_.Exception.Message -notmatch 'Simulated reservation capacity failure') { throw }
    $failed = $true
}
if (!$failed -or @($script:calls | Where-Object { $_ -match '^vm ' }).Count) { throw 'Reservation creation failure was hidden or modified a VM.' }

New-TestState
$timing = Invoke-TestResize
$mutations = @($script:calls | Where-Object { $_ -match '^vm (deallocate|resize|update|start) ' })
if ($mutations.Count -ne 4 -or $mutations[0] -notmatch '^vm deallocate ' -or $mutations[1] -notmatch '^vm resize ' -or
    $mutations[2] -notmatch '^vm update .*--capacity-reservation-group ' -or $mutations[3] -notmatch '^vm start ') {
    throw 'Incorrect reserved resize order.'
}
if ($timing.operations.Count -ne 4 -or 'reserved-allocation-verified' -notin $script:eventNames) { throw 'Runtime allocation was not verified.' }

New-TestState
$script:ignoreAssociation = $true
$failed = $false
try { $null = Invoke-TestResize } catch {
    if ($_.Exception.Message -notmatch 'Reserved start blocked') { throw }
    $failed = $true
}
if (!$failed -or @($script:calls | Where-Object { $_ -match '^vm start ' }).Count) { throw 'Unassociated VM was started.' }

New-TestState
$script:failStart = $true
$failed = $false
try { $null = Invoke-TestResize } catch {
    if ($_.Exception.Message -notmatch 'Simulated allocation failure') { throw }
    $failed = $true
}
if (!$failed -or @($script:calls | Where-Object { $_ -match '^capacity reservation (update|delete) ' }).Count) {
    throw 'A failed resize must propagate without releasing its recovery capacity.'
}

New-TestState
$null = Invoke-TestResize
$script:calls.Clear()
Remove-LabReservation 'lab' 'resize-capacity' 'target-slots' @('test-vm')
if (!$script:reservationDeleted -or !$script:groupDeleted -or $script:powerState -ne 'PowerState/running') {
    throw 'Reservation release/deletion failed.'
}
if (@($script:calls | Where-Object { $_ -match '^vm (deallocate|resize|start) ' }).Count) { throw 'Release interrupted the VM.' }
if ($script:calls[0] -notmatch '^capacity reservation update .*--capacity 0') { throw 'Release order is incorrect.' }

New-TestState
$script:ignoreRelease = $true
$failed = $false
try { Remove-LabReservation 'lab' 'resize-capacity' 'target-slots' @('test-vm') } catch {
    if ($_.Exception.Message -notmatch 'quantity to zero') { throw }
    $failed = $true
}
if (!$failed -or $script:reservationDeleted -or @($script:calls | Where-Object { $_ -match '^vm update ' }).Count) {
    throw 'Unverified release should not proceed to disassociation or deletion.'
}
Write-Output 'PASS: 13 fail-closed preflights; reserve-before-create and reservation failure; two-slot gate; deallocate/resize/associate/start ordering; runtime allocation; association/start failures; non-disruptive release; release failure propagation.'
