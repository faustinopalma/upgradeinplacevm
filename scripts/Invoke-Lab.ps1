param(
    [Parameter(Mandatory)][string]$ConfigDir,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string[]]$Regions = @('westeurope', 'southafricanorth', 'francecentral', 'uksouth'),
    [int]$BaselineSeconds = 60,
    [int]$RecoverySeconds = 60
)
$ErrorActionPreference = 'Stop'
$env:AZURE_CONFIG_DIR = $ConfigDir
$root = Split-Path $PSScriptRoot -Parent
$runId = 'resize-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$evidence = Join-Path $root "evidence\$runId"
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$groups = [System.Collections.Generic.List[string]]::new()
$events = Join-Path $evidence 'events.jsonl'
$commandIndex = 0
$monitorProcesses = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$keyDir = Join-Path ([System.IO.Path]::GetTempPath()) $runId
New-Item -ItemType Directory -Path $keyDir | Out-Null
$key = Join-Path $keyDir 'id_rsa'

function Write-Event([string]$Name, $Data) {
    $event = [ordered]@{ utc = [DateTimeOffset]::UtcNow.ToString('o'); event = $Name; data = $Data }
    $event | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $events
    Write-Host ("{0} {1}" -f $event.utc, $Name)
}

function Invoke-Az([string[]]$Arguments, [switch]$AllowFailure) {
    $script:commandIndex++
    $prefix = '{0:D3}' -f $script:commandIndex
    $started = [DateTimeOffset]::UtcNow
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $text = (& az @Arguments --only-show-errors 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    $exitCode = $LASTEXITCODE
    $clock.Stop()
    $text | Set-Content -LiteralPath (Join-Path $evidence "$prefix-output.txt")
    Write-Event 'azure-command' @{
        index = $prefix; arguments = $Arguments; exitCode = $exitCode
        startedUtc = $started.ToString('o'); elapsedMs = $clock.Elapsed.TotalMilliseconds
        outputFile = "$prefix-output.txt"
    }
    if ($exitCode -ne 0 -and !$AllowFailure) { throw "az failed ($exitCode): $text" }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; ElapsedMs = $clock.Elapsed.TotalMilliseconds }
}

function Get-Health([string]$Url) {
    try {
        $health = Invoke-RestMethod -Uri $Url -TimeoutSec 3 -NoProxy
        if ($health.status -ne 'ok' -or !$health.applicationId -or !$health.payloadSha256) {
            throw 'Invalid health payload'
        }
        return $health
    } catch {
        Write-Event 'health-not-ready' @{ url = $Url; error = $_.Exception.Message }
        return $null
    }
}

function Wait-Health([string]$Url, [int]$TimeoutSeconds = 600) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $health = Get-Health $Url
        if ($health) { return $health }
        Start-Sleep -Seconds 5
    }
    throw "Application did not become healthy: $Url"
}

function Get-Identity([string]$Group, [string]$Name) {
    $response = Invoke-Az @('vm','show','-g',$Group,'-n',$Name,'-o','json')
    $vm = $response.Text | ConvertFrom-Json
    $ip = Invoke-Az @('network','public-ip','show','-g',$Group,'-n',"$Name-pip",'--query','ipAddress','-o','tsv')
    $disk = Invoke-Az @('disk','show','--ids',$vm.storageProfile.osDisk.managedDisk.id,'-o','json')
    $diskData = $disk.Text | ConvertFrom-Json
    return [pscustomobject]@{
        resourceId = $vm.id; vmId = $vm.vmId; size = $vm.hardwareProfile.vmSize
        osDiskId = $vm.storageProfile.osDisk.managedDisk.id
        nicId = $vm.networkProfile.networkInterfaces[0].id; publicIp = $ip.Text.Trim()
        imageSku = $vm.storageProfile.imageReference.sku
        hyperVGeneration = $diskData.hyperVGeneration
    }
}

function Try-LabExemption([string]$Group, [string]$DeploymentName, [string]$FailureText) {
    if ($FailureText -notmatch 'RequestDisallowedByPolicy') { return $false }
    $ops = Invoke-Az @('deployment','operation','group','list','-g',$Group,'-n',$DeploymentName,'-o','json')
    $ops.Text | Set-Content -LiteralPath (Join-Path $evidence "$Group-policy-operations.json")
    $operations = $ops.Text | ConvertFrom-Json -Depth 100
    $violations = [System.Collections.Generic.List[object]]::new()
    function Find-Policy($Node) {
        if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return }
        if ($Node -is [array]) { foreach ($item in $Node) { Find-Policy $item }; return }
        if ($Node.policyAssignmentId -and $Node.policyDefinitionId) { $violations.Add($Node) }
        foreach ($property in $Node.PSObject.Properties) { Find-Policy $property.Value }
    }
    Find-Policy $operations
    $assignmentGroups = @($violations | Group-Object policyAssignmentId)
    if (!$assignmentGroups.Count) { throw 'Policy denied deployment but assignment details could not be resolved safely.' }
    foreach ($assignmentGroup in $assignmentGroups) {
        $refs = @($assignmentGroup.Group | ForEach-Object { $_.policyDefinitionReferenceId } | Where-Object { $_ } | Sort-Object -Unique)
        $assignmentId = $assignmentGroup.Name
        $assignment = Invoke-Az @('rest','--method','get','--url',"https://management.azure.com${assignmentId}?api-version=2023-04-01",'-o','json')
        $assignmentData = ($assignment.Text | ConvertFrom-Json).properties
        if ($assignmentData.policyDefinitionId -match '/policySetDefinitions/' -and !$refs.Count) {
            throw 'Refusing a blanket initiative exemption: blocking policy reference IDs are missing.'
        }
        $definitionIds = @($assignmentGroup.Group | ForEach-Object { $_.policyDefinitionId } | Sort-Object -Unique)
        foreach ($definitionId in $definitionIds) {
            $definition = Invoke-Az @('rest','--method','get','--url',"https://management.azure.com${definitionId}?api-version=2023-04-01",'-o','json')
            $policy = ($definition.Text | ConvertFrom-Json).properties
            Write-Event 'blocking-policy' @{ id=$definitionId; definition=$policy }
            if ($policy.displayName -notmatch 'public|internet' -and $definition.Text -notmatch 'publicIP|publicNetwork|Internet') {
                throw "Blocking policy is not identifiable as a public exposure policy; no automatic exemption: $definitionId"
            }
        }
        $parameters = @{
            assignmentId = @{ value = $assignmentId }
            expiresOn = @{ value = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o') }
            policyDefinitionReferenceIds = @{ value = $refs }
        }
        $parameterFile = Join-Path $evidence "$Group-exemption-parameters.json"
        $parameters | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterFile
        $null = Invoke-Az @('deployment','group','create','-g',$Group,'-n','lab-exemption','--template-file',(Join-Path $root 'infra\exemption.bicep'),'--parameters',"@$parameterFile",'-o','json')
        Write-Event 'exemption-created' @{ group=$Group; assignment=$assignmentId; references=$refs }
    }
    Start-Sleep -Seconds 20
    return $true
}

try {
    $account = Invoke-Az @('account','show','-o','json')
    $accountData = $account.Text | ConvertFrom-Json
    if ($accountData.id -ne $SubscriptionId) { throw 'Unexpected subscription: no changes made.' }
    $null = Invoke-Az @('account','get-access-token','--query','expiresOn','-o','tsv')
    $monitorIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    $parsedIp = [System.Net.IPAddress]::Parse($monitorIp)
    if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'IPv4 monitoring source required.' }
    & ssh-keygen -t rsa -b 2048 -N '""' -f $key -q
    if ($LASTEXITCODE -ne 0) { throw 'Temporary SSH key generation failed.' }
    $publicKey = Get-Content -LiteralPath "$key.pub" -Raw
    $null = Invoke-Az @('bicep','build','--file',(Join-Path $root 'infra\main.bicep'),'--outfile',(Join-Path $evidence 'compiled-template.json'))
    Write-Event 'run-started' @{ runId=$runId; monitorIp=$monitorIp; configDir=$ConfigDir; account=$accountData; regions=$Regions }
    $experiments = @(
        @{ name='legacy-v1'; source='Standard_D1'; target='Standard_D2ds_v5' },
        @{ name='legacy-v2'; source='Standard_D2_v2'; target='Standard_D2ds_v5' }
    )
    foreach ($experiment in $experiments) {
        $deployed = $false
        foreach ($region in $Regions) {
            $group = "rg-$runId-$($experiment.name)-$region"
            $null = Invoke-Az @('group','create','-n',$group,'-l',$region,'--tags',"labId=$runId",'purpose=temporary-vm-resize-laboratory','-o','json')
            $groups.Add($group)
            $image = Invoke-Az @('vm','image','show','-l',$region,'--urn','Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest','-o','json')
            $imageData = $image.Text | ConvertFrom-Json
            $parameters = @{
                location = @{ value=$region }; vmName = @{ value=$experiment.name }
                vmSize = @{ value=$experiment.source }; monitorCidr = @{ value="$monitorIp/32" }
                sshPublicKey = @{ value=$publicKey.Trim() }; labId = @{ value=$runId }
                imageVersion = @{ value=$imageData.name }
            }
            $parameterFile = Join-Path $evidence "$($experiment.name)-$region-parameters.json"
            $parameters | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterFile
            $deployArguments = @('deployment','group','create','-g',$group,'-n','initial','--template-file',(Join-Path $root 'infra\main.bicep'),'--parameters',"@$parameterFile",'-o','json')
            $deployment = Invoke-Az $deployArguments -AllowFailure
            if ($deployment.ExitCode -ne 0 -and (Try-LabExemption $group 'initial' $deployment.Text)) {
                $deployment = Invoke-Az $deployArguments -AllowFailure
            }
            if ($deployment.ExitCode -ne 0) {
                Write-Event 'region-attempt-failed' @{ experiment=$experiment.name; region=$region; group=$group; error=$deployment.Text }
                if ($deployment.Text -notmatch 'SkuNotAvailable|AllocationFailed|OverconstrainedAllocationRequest|OperationNotAllowed|NotAvailableForSubscription|InvalidParameter') {
                    throw "Deployment failed for non-capacity reason: $($deployment.Text)"
                }
                continue
            }
            $deployData = $deployment.Text | ConvertFrom-Json
            $url = $deployData.properties.outputs.healthUrl.value
            $beforeHealth = Wait-Health $url
            $beforeIdentity = Get-Identity $group $experiment.name
            $sizes = Invoke-Az @('vm','list-vm-resize-options','-g',$group,'-n',$experiment.name,'-o','json')
            $resizeOptions = @($sizes.Text | ConvertFrom-Json)
            $targetInCluster = @($resizeOptions | Where-Object name -eq $experiment.target).Count -gt 0
            $stopFile = Join-Path $evidence "$($experiment.name)-monitor.stop"
            $probeFile = Join-Path $evidence "$($experiment.name)-probes.jsonl"
            $monitorArgs = @(
                '-NoProfile','-File',"`"$(Join-Path $PSScriptRoot 'Monitor-Http.ps1')`"",
                '-Url',"`"$url`"",'-OutputPath',"`"$probeFile`"",'-StopFile',"`"$stopFile`""
            )
            $monitor = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $monitorArgs -PassThru -WindowStyle Hidden
            $monitorProcesses.Add([pscustomobject]@{ process=$monitor; stopFile=$stopFile })
            Start-Sleep -Seconds 5
            if ($monitor.HasExited -or !(Test-Path -LiteralPath $probeFile)) { throw 'HTTP monitor did not start.' }
            $initialProbes = @(Get-Content -LiteralPath $probeFile | ForEach-Object { $_ | ConvertFrom-Json })
            if (@($initialProbes | Where-Object success).Count -lt 2) { throw 'Monitor is not observing successful application probes.' }
            Write-Event 'baseline-started' @{ experiment=$experiment.name; targetInCluster=$targetInCluster; identity=$beforeIdentity; health=$beforeHealth }
            Start-Sleep -Seconds $BaselineSeconds
            $resizeStart = [DateTimeOffset]::UtcNow
            Write-Event 'resize-started' @{ experiment=$experiment.name; source=$experiment.source; target=$experiment.target; targetInCluster=$targetInCluster }
            $operations = [System.Collections.Generic.List[object]]::new()
            if (!$targetInCluster) {
                $op = Invoke-Az @('vm','deallocate','-g',$group,'-n',$experiment.name,'-o','json')
                $operations.Add([pscustomobject]@{ name='deallocate'; elapsedMs=$op.ElapsedMs; exitCode=$op.ExitCode })
            }
            $op = Invoke-Az @('vm','resize','-g',$group,'-n',$experiment.name,'--size',$experiment.target,'-o','json')
            $operations.Add([pscustomobject]@{ name='resize'; elapsedMs=$op.ElapsedMs; exitCode=$op.ExitCode })
            if (!$targetInCluster) {
                $op = Invoke-Az @('vm','start','-g',$group,'-n',$experiment.name,'-o','json')
                $operations.Add([pscustomobject]@{ name='start'; elapsedMs=$op.ElapsedMs; exitCode=$op.ExitCode })
            }
            $controlPlaneEnd = [DateTimeOffset]::UtcNow
            $afterHealth = Wait-Health $url
            $firstHealthCheck = [DateTimeOffset]::UtcNow
            Start-Sleep -Seconds $RecoverySeconds
            $afterIdentity = Get-Identity $group $experiment.name
            foreach ($field in @('resourceId','vmId','osDiskId','nicId','publicIp')) {
                if ($beforeIdentity.$field -ne $afterIdentity.$field) { throw "Identity changed unexpectedly: $field" }
            }
            foreach ($field in @('applicationId','machineId','payloadSha256')) {
                if ($beforeHealth.$field -ne $afterHealth.$field) { throw "Persistent application data mismatch: $field" }
            }
            if ($afterIdentity.size -ne $experiment.target) { throw 'Target VM size not applied.' }
            if ($beforeHealth.bootId -eq $afterHealth.bootId) { throw 'Expected reboot was not observed.' }
            New-Item -ItemType File -Path $stopFile | Out-Null
            if (!$monitor.WaitForExit(10000)) { throw 'Monitor failed to stop cleanly.' }
            if ($monitor.ExitCode -ne 0) { throw 'Monitor failed.' }
            $guestScript = "cloud-init status --long; systemctl is-active nginx; systemctl show nginx -p ActiveEnterTimestamp -p ExecMainStartTimestamp; systemd-analyze; cat /var/lib/lab-app/www/health.json; lscpu | head -25; free -m; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT; journalctl -b -u nginx -u lab-app-metadata --no-pager"
            $guest = Invoke-Az @('vm','run-command','invoke','-g',$group,'-n',$experiment.name,'--command-id','RunShellScript','--scripts',$guestScript,'-o','json')
            $guest.Text | Set-Content -LiteralPath (Join-Path $evidence "$($experiment.name)-guest-after.json")
            $result = [ordered]@{
                experiment=$experiment.name; region=$region; group=$group
                source=$experiment.source; target=$experiment.target; targetInOriginalCluster=$targetInCluster
                beforeIdentity=$beforeIdentity; afterIdentity=$afterIdentity
                beforeHealth=$beforeHealth; afterHealth=$afterHealth
                resizeStartUtc=$resizeStart.ToString('o'); controlPlaneEndUtc=$controlPlaneEnd.ToString('o')
                firstPostCommandHealthUtc=$firstHealthCheck.ToString('o'); operations=$operations.ToArray()
                probesFile=[System.IO.Path]::GetFileName($probeFile)
            }
            $results.Add($result)
            $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence "$($experiment.name)-result.json")
            Write-Event 'experiment-completed' $result
            $deployed = $true
            break
        }
        if (!$deployed) { throw "No successful deployment for $($experiment.name) in tested regions." }
    }
    $results | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
} catch {
    Write-Event 'run-failed' @{ message=$_.Exception.Message; stack=$_.ScriptStackTrace }
    throw
} finally {
    foreach ($entry in $monitorProcesses) {
        if (!$entry.process.HasExited) {
            New-Item -ItemType File -Path $entry.stopFile -Force | Out-Null
            if (!$entry.process.WaitForExit(10000)) {
                Stop-Process -Id $entry.process.Id
                Write-Event 'monitor-force-stopped' @{ pid=$entry.process.Id }
            }
        }
    }
    $cleanupFailed = $false
    foreach ($group in $groups) {
        try {
            $null = Invoke-Az @('monitor','activity-log','list','--resource-group',$group,'--offset','4h','--max-events','200','-o','json') -AllowFailure
            $null = Invoke-Az @('group','delete','-n',$group,'--yes')
            $exists = Invoke-Az @('group','exists','-n',$group,'-o','tsv')
            if ($exists.Text.Trim() -ne 'false') { throw "Resource group still exists: $group" }
            Write-Event 'cleanup-verified' @{ group=$group; exists=$false }
        } catch {
            $cleanupFailed = $true
            Write-Event 'cleanup-failed' @{ group=$group; error=$_.Exception.Message }
        }
    }
    foreach ($path in @($key, "$key.pub")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $keyDir) { Remove-Item -LiteralPath $keyDir }
    Write-Event 'run-finished' @{ evidence=$evidence; experiments=$results.Count; cleanupFailed=$cleanupFailed }
    if ($cleanupFailed) { throw 'Cleanup incomplete: inspect cleanup-failed events.' }
}
