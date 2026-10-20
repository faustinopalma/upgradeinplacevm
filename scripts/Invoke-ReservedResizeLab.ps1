param(
    [Parameter(Mandatory)][string]$ConfigDir,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateRange(1, 10)][int]$Quantity,
    [switch]$TargetAllocationOnly,
    [string[]]$Regions = @('westeurope', 'southafricanorth'),
    [ValidateSet('Standard_D1', 'Standard_D2_v2', 'Standard_D2s_v3')][string]$SourceSize = 'Standard_D2_v2',
    [ValidateRange(30, 3600)][int]$BaselineSeconds = 60,
    [ValidateRange(30, 3600)][int]$RecoverySeconds = 60
)
$ErrorActionPreference = 'Stop'
$TargetSize = 'Standard_D2ds_v5'
if (!$Regions.Count -or @($Regions | Where-Object { $_ -notmatch '^[a-z0-9]+$' }).Count) { throw 'Explicit Azure region names are required.' }
$env:AZURE_CONFIG_DIR = (Resolve-Path -LiteralPath $ConfigDir).Path
$root = Split-Path $PSScriptRoot -Parent
$mode = if ($TargetAllocationOnly) { 'reserved-allocation' } else { 'reserved-resize' }
$runId = $mode + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$evidence = Join-Path $root "evidence\$runId"
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'Lab-Common.ps1') -EvidencePath $evidence -AzureSubscriptionId $SubscriptionId
. (Join-Path $PSScriptRoot 'CapacityReservation.ps1')
$groups = [System.Collections.Generic.List[string]]::new()
$monitors = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$keyDir = Join-Path ([System.IO.Path]::GetTempPath()) $runId
$key = Join-Path $keyDir 'id_rsa'
$completed = $false

function Remove-OwnedLabGroup([string]$Group) {
    if ($Group -notin $groups) { throw 'Refusing to delete an unowned resource group.' }
    $exists = Invoke-Az @('group','exists','-n',$Group,'-o','tsv')
    if ($exists.Text.Trim() -eq 'true') {
        $null = Invoke-Az @('group','delete','-n',$Group,'--yes')
    } elseif ($exists.Text.Trim() -ne 'false') { throw 'Cannot determine whether the resource group exists.' }
    $exists = Invoke-Az @('group','exists','-n',$Group,'-o','tsv')
    if ($exists.Text.Trim() -ne 'false') { throw "Resource group still exists: $Group" }
    Write-Event 'cleanup-verified' @{group=$Group;exists=$false}
    $null = $groups.Remove($Group)
}

try {
    $account = (Invoke-Az @('account','show','-o','json')).Text | ConvertFrom-Json
    if ($account.id -ne $SubscriptionId) { throw 'Unexpected active subscription: no resources created.' }
    $null = Invoke-Az @('account','get-access-token','--query','expiresOn','-o','tsv')
    $null = Invoke-Az @('bicep','build','--file',(Join-Path $root 'infra\main.bicep'),'--outfile',(Join-Path $evidence 'compiled-template.json'))
    $monitorIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    if ([System.Net.IPAddress]::Parse($monitorIp).AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'An IPv4 monitoring source is required.'
    }
    New-Item -ItemType Directory -Path $keyDir | Out-Null
    & ssh-keygen -t rsa -b 2048 -N '""' -f $key -q
    if ($LASTEXITCODE -ne 0) { throw 'Temporary SSH key generation failed.' }
    $publicKey = (Get-Content -LiteralPath "$key.pub" -Raw).Trim()
    Write-Event 'run-started' @{
        runId=$runId;testType=$mode;quantity=$Quantity;source=if($TargetAllocationOnly){$null}else{$SourceSize};target=$TargetSize;regions=$Regions
        observer=@{os='Windows';runtime=$PSVersionTable.PSVersion.ToString();hosting='Execution host; not provisioned by this lab'}
    }
    foreach ($region in $Regions) {
        $group = "rg-$runId-$region"
        $resizeStarted = $false
        try {
            $exists = Invoke-Az @('group','exists','-n',$group,'-o','tsv')
            if ($exists.Text.Trim() -ne 'false') { throw 'Refusing to reuse an existing or unverifiable resource group.' }
            $groups.Add($group)
            $null = Invoke-Az @('group','create','-n',$group,'-l',$region,'--tags',"labId=$runId",'purpose=temporary-reserved-resize-laboratory','-o','json')
            $skus = (Invoke-Az @('vm','list-skus','-l',$region,'--resource-type','virtualMachines','--size',$TargetSize,'--all','-o','json')).Text | ConvertFrom-Json
            $sku = @($skus | Where-Object name -eq $TargetSize)
            if ($sku.Count -ne 1 -or !@($sku[0].capabilities | Where-Object { $_.name -eq 'CapacityReservationSupported' -and $_.value -eq 'True' }).Count) {
                throw 'Target SKU does not advertise CapacityReservationSupported in this region.'
            }
            $image = (Invoke-Az @('vm','image','show','-l',$region,'--urn','Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest','-o','json')).Text | ConvertFrom-Json
            $reservationGroup = 'resize-capacity'
            $reservationName = 'target-slots'
            if ($TargetAllocationOnly) { $crg = New-LabTargetReservation $group $region $TargetSize $Quantity }
            $vms = [System.Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le $Quantity; $i++) {
                $name = 'reserved-{0:D2}' -f $i
                $parameters = @{
                    location=@{value=$region};vmName=@{value=$name};vmSize=@{value=if($TargetAllocationOnly){$TargetSize}else{$SourceSize}}
                    monitorCidr=@{value="$monitorIp/32"};sshPublicKey=@{value=$publicKey}
                    labId=@{value=$runId};imageVersion=@{value=$image.name}
                }
                if ($TargetAllocationOnly) {
                    $reservation = Get-LabReservation $group $reservationGroup $reservationName
                    Assert-ReservedCapacity $reservation $region $TargetSize ($Quantity - $i + 1)
                    $parameters.capacityReservationGroupId = @{value=$crg.id}
                }
                $parameterFile = Join-Path $evidence "$region-$name-parameters.json"
                $parameters | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterFile
                $deploy = Invoke-Az @('deployment','group','create','-g',$group,'-n',$name,'--template-file',(Join-Path $root 'infra\main.bicep'),'--parameters',"@$parameterFile",'-o','json')
                $url = ($deploy.Text | ConvertFrom-Json).properties.outputs.healthUrl.value
                $vms.Add([pscustomobject]@{
                    name=$name;url=$url;beforeHealth=(Wait-Health $url);beforeIdentity=(Get-Identity $group $name)
                })
                if ($TargetAllocationOnly) {
                    Wait-LabReservedAllocation $group $name $vms[$i - 1].beforeIdentity.resourceId $reservationGroup $reservationName
                }
            }
            if (!$TargetAllocationOnly) { $crg = New-LabTargetReservation $group $region $TargetSize $Quantity }
            $reservedUtc = $crg.verifiedUtc
            foreach ($vm in $vms) {
                $stopFile = Join-Path $evidence "$($vm.name)-monitor.stop"
                $probeFile = Join-Path $evidence "$($vm.name)-probes.jsonl"
                $monitorArguments = @(
                    '-NoProfile','-File',"`"$(Join-Path $PSScriptRoot 'Monitor-Http.ps1')`"",
                    '-Url',"`"$($vm.url)`"",'-OutputPath',"`"$probeFile`"",'-StopFile',"`"$stopFile`""
                )
                $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $monitorArguments -PassThru -WindowStyle Hidden
                $monitors.Add([pscustomobject]@{process=$process;stopFile=$stopFile;probeFile=$probeFile;name=$vm.name})
            }
            Start-Sleep -Seconds $BaselineSeconds
            foreach ($monitor in $monitors) {
                if ($monitor.process.HasExited -or !(Test-Path -LiteralPath $monitor.probeFile)) { throw 'Observer did not remain active.' }
                $samples = @(Get-Content -LiteralPath $monitor.probeFile | ForEach-Object { $_ | ConvertFrom-Json })
                if (@($samples | Where-Object success).Count -lt 20 -or @($samples | Where-Object { !$_.success }).Count) {
                    throw 'NO-GO: observer baseline is unhealthy or incomplete.'
                }
            }
            for ($i = 0; $i -lt $vms.Count; $i++) {
                $vm = $vms[$i]
                if ($TargetAllocationOnly) {
                    $result = [ordered]@{
                        experiment=$vm.name;testType=$mode;region=$region;target=$TargetSize;capacityReservationUsed=$true
                        identity=$vm.beforeIdentity;afterHealth=$vm.beforeHealth
                    }
                    $results.Add($result)
                    $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence "$($vm.name)-allocation.json")
                    Write-Event 'target-allocation-completed' $result
                    continue
                }
                $health = Wait-Health $vm.url
                if ($health.applicationId -ne $vm.beforeHealth.applicationId -or $health.payloadSha256 -ne $vm.beforeHealth.payloadSha256) {
                    throw 'NO-GO: source application identity or payload changed.'
                }
                $resizeStarted = $true
                $timing = Invoke-CapacityReservedResize $group $vm.name $region $TargetSize $reservationGroup $reservationName $crg.id ($Quantity - $i)
                $afterHealth = Wait-Health $vm.url
                $afterIdentity = Get-Identity $group $vm.name
                foreach ($field in @('resourceId','vmId','osDiskId','nicId','publicIp','hyperVGeneration')) {
                    if ($vm.beforeIdentity.$field -ne $afterIdentity.$field) { throw "Persistent Azure identity changed: $field" }
                }
                foreach ($field in @('applicationId','machineId','payloadSha256')) {
                    if ($vm.beforeHealth.$field -ne $afterHealth.$field) { throw "Persistent guest identity/data changed: $field" }
                }
                if ($afterIdentity.size -ne $TargetSize -or $afterHealth.bootId -eq $vm.beforeHealth.bootId -or
                    $afterHealth.bootCount -le $vm.beforeHealth.bootCount) { throw 'Target size or reboot verification failed.' }
                $result = [ordered]@{
                    experiment=$vm.name;region=$region;source=$SourceSize;target=$TargetSize
                    targetInOriginalCluster=$null;capacityReservationUsed=$true
                    beforeIdentity=$vm.beforeIdentity;afterIdentity=$afterIdentity
                    beforeHealth=$vm.beforeHealth;afterHealth=$afterHealth
                    resizeStartUtc=$timing.resizeStartUtc;controlPlaneEndUtc=$timing.controlPlaneEndUtc
                    operations=$timing.operations;probesFile="$($vm.name)-probes.jsonl"
                }
                $results.Add($result)
                $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence "$($vm.name)-result.json")
                Write-Event 'experiment-completed' $result
            }
            Start-Sleep -Seconds $RecoverySeconds
            foreach ($vm in $vms) {
                $health = Get-Health $vm.url
                $expected = ($results | Where-Object experiment -eq $vm.name).afterHealth
                if (!$health) { throw 'Application is not healthy: retaining capacity until lab cleanup.' }
                foreach ($field in @('applicationId','machineId','payloadSha256','bootId')) {
                    if ($health.$field -ne $expected.$field) { throw "Application acceptance failed before release: $field" }
                }
            }
            Remove-LabReservation $group $reservationGroup $reservationName @($vms | ForEach-Object name)
            Write-Event 'reservation-lifetime' @{fromUtc=$reservedUtc.ToString('o');toUtc=[DateTimeOffset]::UtcNow.ToString('o');quantity=$Quantity}
            Start-Sleep -Seconds $RecoverySeconds
            foreach ($vm in $vms) {
                $health = Wait-Health $vm.url
                if ($health.bootId -ne ($results | Where-Object experiment -eq $vm.name).afterHealth.bootId) {
                    throw 'Reservation release unexpectedly restarted the guest.'
                }
                if ($health.applicationId -ne $vm.beforeHealth.applicationId -or $health.payloadSha256 -ne $vm.beforeHealth.payloadSha256) {
                    throw 'Application identity or payload changed after reservation release.'
                }
            }
            $completed = $true
            break
        } catch {
            Write-Event 'region-attempt-failed' @{region=$region;group=$group;resizeStarted=$resizeStarted;error=$_.Exception.Message}
            if ($resizeStarted -or $_.Exception.Message -notmatch 'SkuNotAvailable|AllocationFailed|OverconstrainedAllocationRequest|NotAvailableForSubscription') { throw }
            Remove-OwnedLabGroup $group
        }
    }
    if (!$completed) { throw 'No region completed the reserved resize experiment.' }
} catch {
    Write-Event 'run-failed' @{message=$_.Exception.Message;stack=$_.ScriptStackTrace}
    throw
} finally {
    $cleanupFailed = $false
    foreach ($monitor in $monitors) {
        try {
            if (!$monitor.process.HasExited) {
                New-Item -ItemType File -Path $monitor.stopFile -Force | Out-Null
                if (!$monitor.process.WaitForExit(10000)) {
                    Stop-Process -Id $monitor.process.Id
                    throw 'Observer required forced termination.'
                }
            }
            if ($monitor.process.ExitCode -ne 0) { throw "Observer failed for $($monitor.name)." }
        } catch {
            $cleanupFailed = $true
            Write-Event 'cleanup-failed' @{observer=$monitor.name;error=$_.Exception.Message}
        }
    }
    foreach ($group in @($groups)) {
        try { Remove-OwnedLabGroup $group } catch {
            $cleanupFailed = $true
            Write-Event 'cleanup-failed' @{group=$group;error=$_.Exception.Message}
        }
    }
    foreach ($path in @($key, "$key.pub")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $keyDir) { Remove-Item -LiteralPath $keyDir }
    Write-Event 'run-finished' @{evidence=$evidence;experiments=$results.Count;completed=$completed;cleanupFailed=$cleanupFailed}
    if ($cleanupFailed) { throw 'Cleanup incomplete: inspect cleanup-failed events.' }
}
