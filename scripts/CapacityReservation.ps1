function Get-LabReservation([string]$Group, [string]$ReservationGroup, [string]$ReservationName) {
    $response = Invoke-Az @('capacity','reservation','show','-g',$Group,'-c',$ReservationGroup,'-n',$ReservationName,'--instance-view','-o','json')
    return $response.Text | ConvertFrom-Json -Depth 30
}

function Assert-ReservedCapacity($Reservation, [string]$Region, [string]$TargetSize, [int]$RequiredSlots) {
    if ($RequiredSlots -lt 1) { throw 'At least one reserved slot is required.' }
    if ($Reservation.provisioningState -ne 'Succeeded' -or $Reservation.sku.name -ne $TargetSize -or
        $Reservation.location -ne $Region -or @($Reservation.zones | Where-Object { $_ }).Count -gt 0) {
        throw 'NO-GO: reservation state, size, region or zone does not match this regional lab.'
    }
    $utilization = $Reservation.instanceView.utilizationInfo
    if ($null -eq $utilization.currentCapacity -or $null -eq $Reservation.sku.capacity) {
        throw 'NO-GO: reservation runtime capacity is missing.'
    }
    $allocated = @($utilization.virtualMachinesAllocated | Where-Object { $_.id })
    $free = [math]::Min([int]$Reservation.sku.capacity, [int]$utilization.currentCapacity) - $allocated.Count
    if ($free -lt $RequiredSlots) { throw "NO-GO: $free free reserved slots; $RequiredSlots required." }
}

function Get-LabPowerState([string]$Group, [string]$Name) {
    $response = Invoke-Az @('vm','get-instance-view','-g',$Group,'-n',$Name,'--query',"instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]",'-o','tsv')
    return $response.Text.Trim()
}

function New-LabTargetReservation([string]$Group, [string]$Region, [string]$TargetSize, [int]$Quantity) {
    $crg = (Invoke-Az @('capacity','reservation','group','create','-g',$Group,'-n','resize-capacity','-l',$Region,'-o','json')).Text | ConvertFrom-Json
    $null = Invoke-Az @('capacity','reservation','create','-g',$Group,'-c','resize-capacity','-n','target-slots','--sku',$TargetSize,'--capacity',"$Quantity",'-l',$Region,'-o','json')
    $reservation = Get-LabReservation $Group 'resize-capacity' 'target-slots'
    if (!$crg.id -or $reservation.id -ne "$($crg.id)/capacityReservations/target-slots") {
        throw 'NO-GO: newly created reservation does not belong to the expected group.'
    }
    Assert-ReservedCapacity $reservation $Region $TargetSize $Quantity
    Write-Event 'all-target-capacity-reserved' @{quantity=$Quantity;reservation=$reservation}
    return [pscustomobject]@{id=$crg.id;verifiedUtc=[DateTimeOffset]::UtcNow}
}

function Wait-LabReservedAllocation(
    [string]$Group, [string]$Name, [string]$VmId, [string]$ReservationGroup, [string]$ReservationName
) {
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(2)
    do {
        $allocated = Get-LabReservation $Group $ReservationGroup $ReservationName
        $ids = @($allocated.instanceView.utilizationInfo.virtualMachinesAllocated | ForEach-Object id)
        if ($VmId -in $ids) { break }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'VM did not appear in reserved-capacity runtime allocation.' }
        Start-Sleep -Seconds 5
    } while ($true)
    if ((Get-LabPowerState $Group $Name) -ne 'PowerState/running') { throw 'Target VM is not running.' }
    Write-Event 'reserved-allocation-verified' @{vm=$Name;reservation=$allocated}
}

function Invoke-CapacityReservedResize(
    [string]$Group, [string]$Name, [string]$Region, [string]$TargetSize,
    [string]$ReservationGroup, [string]$ReservationName, [string]$ReservationGroupId,
    [int]$RequiredSlots
) {
    $model = (Invoke-Az @('vm','show','-g',$Group,'-n',$Name,'-o','json')).Text | ConvertFrom-Json
    if ($model.location -ne $Region -or @($model.zones | Where-Object { $_ }).Count -gt 0 -or $model.availabilitySet -or
        $model.host -or $model.proximityPlacementGroup -or $model.priority -eq 'Spot' -or
        $model.capacityReservation.capacityReservationGroup.id) {
        throw 'NO-GO: this helper requires an unassociated, regional, standalone regular VM.'
    }
    if ($model.hardwareProfile.vmSize -eq $TargetSize) { throw 'NO-GO: source and target sizes are identical.' }
    if ((Get-LabPowerState $Group $Name) -ne 'PowerState/running') { throw 'NO-GO: source VM is not running.' }
    $reservation = Get-LabReservation $Group $ReservationGroup $ReservationName
    if ($reservation.id -ne "$ReservationGroupId/capacityReservations/$ReservationName") {
        throw 'NO-GO: reservation group identity mismatch.'
    }
    Assert-ReservedCapacity $reservation $Region $TargetSize $RequiredSlots
    Write-Event 'capacity-gate-passed' @{ vm=$Name; requiredSlots=$RequiredSlots; reservation=$reservation }
    $operations = [System.Collections.Generic.List[object]]::new()
    $started = [DateTimeOffset]::UtcNow
    foreach ($step in @(
        @{name='deallocate'; arguments=@('vm','deallocate','-g',$Group,'-n',$Name)},
        @{name='resize'; arguments=@('vm','resize','-g',$Group,'-n',$Name,'--size',$TargetSize)},
        @{name='associate'; arguments=@('vm','update','-g',$Group,'-n',$Name,'--capacity-reservation-group',$ReservationGroupId)}
    )) {
        $op = Invoke-Az $step.arguments
        $operations.Add([pscustomobject]@{name=$step.name;elapsedMs=$op.ElapsedMs;exitCode=$op.ExitCode})
    }
    $updated = (Invoke-Az @('vm','show','-g',$Group,'-n',$Name,'-o','json')).Text | ConvertFrom-Json
    if ($updated.id -ne $model.id -or $updated.hardwareProfile.vmSize -ne $TargetSize -or
        $updated.capacityReservation.capacityReservationGroup.id -ne $ReservationGroupId -or
        (Get-LabPowerState $Group $Name) -ne 'PowerState/deallocated') {
        throw 'Reserved start blocked: target size, association, identity or deallocated state is incorrect.'
    }
    $op = Invoke-Az @('vm','start','-g',$Group,'-n',$Name)
    $operations.Add([pscustomobject]@{name='start';elapsedMs=$op.ElapsedMs;exitCode=$op.ExitCode})
    $controlEnd = [DateTimeOffset]::UtcNow
    Wait-LabReservedAllocation $Group $Name $model.id $ReservationGroup $ReservationName
    return [pscustomobject]@{
        resizeStartUtc=$started.ToString('o'); controlPlaneEndUtc=$controlEnd.ToString('o')
        operations=$operations.ToArray()
    }
}

function Remove-LabReservation(
    [string]$Group, [string]$ReservationGroup, [string]$ReservationName, [string[]]$Names
) {
    $null = Invoke-Az @('capacity','reservation','update','-g',$Group,'-c',$ReservationGroup,'-n',$ReservationName,'--capacity','0','-o','json')
    $reservation = Get-LabReservation $Group $ReservationGroup $ReservationName
    if ($reservation.sku.capacity -ne 0) { throw 'Reservation release did not set the quantity to zero.' }
    Write-Event 'reservation-capacity-released' @{reservation=$reservation.id;capacity=0}
    foreach ($name in $Names) {
        $null = Invoke-Az @('vm','update','-g',$Group,'-n',$name,'--capacity-reservation-group','None','-o','json')
        $vm = (Invoke-Az @('vm','show','-g',$Group,'-n',$name,'-o','json')).Text | ConvertFrom-Json
        if ($vm.capacityReservation.capacityReservationGroup.id -or (Get-LabPowerState $Group $name) -ne 'PowerState/running') {
            throw "VM did not remain running and unassociated after reservation release: $name"
        }
    }
    $null = Invoke-Az @('capacity','reservation','delete','-g',$Group,'-c',$ReservationGroup,'-n',$ReservationName,'--yes')
    $remaining = (Invoke-Az @('capacity','reservation','list','-g',$Group,'-c',$ReservationGroup,'-o','json')).Text | ConvertFrom-Json
    if (@($remaining | Where-Object { $_ }).Count -ne 0) { throw 'Capacity reservation still exists after deletion.' }
    $null = Invoke-Az @('capacity','reservation','group','delete','-g',$Group,'-n',$ReservationGroup,'--yes')
    $groups = (Invoke-Az @('capacity','reservation','group','list','-g',$Group,'-o','json')).Text | ConvertFrom-Json
    if (@($groups | Where-Object name -eq $ReservationGroup).Count) { throw 'Capacity reservation group still exists.' }
    Write-Event 'reservation-deletion-verified' @{group=$ReservationGroup;exists=$false}
}
