param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$AzureSubscriptionId
)
$evidence = $EvidencePath
$events = Join-Path $evidence 'events.jsonl'
$commandIndex = 0
$labSubscriptionId = $AzureSubscriptionId

function Write-Event([string]$Name, $Data) {
    $event = [ordered]@{ utc = [DateTimeOffset]::UtcNow.ToString('o'); event = $Name; data = $Data }
    $event | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $events
    Write-Host ("{0} {1}" -f $event.utc, $Name)
}

function Invoke-Az([string[]]$Arguments, [switch]$AllowFailure) {
    if ($labSubscriptionId -and $Arguments[0] -notin @('account', 'bicep')) {
        $Arguments += @('--subscription', $labSubscriptionId)
    }
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
