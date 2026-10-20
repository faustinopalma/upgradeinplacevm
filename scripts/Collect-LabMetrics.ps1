param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [Parameter(Mandatory)][string]$ConfigDir
)
$ErrorActionPreference = 'Stop'
$env:AZURE_CONFIG_DIR = $ConfigDir
$completed = [System.Collections.Generic.HashSet[string]]::new()
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(60)
$eventFile = Join-Path $EvidencePath 'events.jsonl'
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $events = @(Get-Content -LiteralPath $eventFile | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
    foreach ($event in @($events | Where-Object event -eq 'experiment-completed')) {
        $name = $event.data.experiment
        if ($completed.Contains($name)) { continue }
        $end = [DateTimeOffset]::UtcNow
        $runStarted = ($events | Where-Object event -eq 'run-started' | Select-Object -First 1).utc
        $start = ([DateTimeOffset]$runStarted).ToUniversalTime()
        $resourceId = $event.data.beforeIdentity.resourceId
        foreach ($metricSet in @(
            @{ name='cpu'; metrics=@('Percentage CPU'); aggregation=@('Average','Maximum','Minimum') },
            @{ name='io'; metrics=@('Network In Total','Network Out Total','Disk Read Bytes','Disk Write Bytes'); aggregation=@('Total') }
        )) {
            $arguments = @('monitor','metrics','list','--resource',$resourceId,'--metric') + $metricSet.metrics + @('--interval','PT1M','--aggregation') + $metricSet.aggregation + @('--start-time',$start.ToString('o'),'--end-time',$end.ToString('o'),'--only-show-errors','-o','json')
            $text = (& az @arguments 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
            $exitCode = $LASTEXITCODE
            $text | Set-Content -LiteralPath (Join-Path $EvidencePath "$name-platform-$($metricSet.name).json")
            @{
                experiment=$name; startedUtc=$start.ToString('o'); endedUtc=$end.ToString('o')
                collectedUtc=[DateTimeOffset]::UtcNow.ToString('o'); exitCode=$exitCode
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidencePath "$name-platform-$($metricSet.name)-status.json")
            Write-Output "Metrics collection for $name/$($metricSet.name) completed with exit code $exitCode."
            if ($exitCode -ne 0) { throw "Azure metrics collection failed: $text" }
        }
        $null = $completed.Add($name)
    }
    if (@($events | Where-Object event -eq 'run-finished').Count) {
        Write-Output "Run finished; collected $($completed.Count) metric datasets."
        return
    }
    Start-Sleep -Seconds 5
}
throw 'Metrics collection exceeded its time limit.'
