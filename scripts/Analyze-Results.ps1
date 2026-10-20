param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [ValidateRange(1, 10)][int]$ExpectedExperiments = 2
)
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp($Value) {
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if (!$Values.Count) { return $null }
    $ordered = @($Values | Sort-Object)
    return $ordered[[math]::Max(0, [math]::Ceiling($Percentile * $ordered.Count) - 1)]
}

$summaries = foreach ($file in Get-ChildItem -LiteralPath $EvidencePath -Filter '*-result.json') {
    $result = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $samples = @(Get-Content -LiteralPath (Join-Path $EvidencePath $result.probesFile) | ForEach-Object { $_ | ConvertFrom-Json })
    if (!$samples.Count) { throw "No probes for $($result.experiment)" }
    $resizeStart = Get-UtcTimestamp $result.resizeStartUtc
    $controlEnd = Get-UtcTimestamp $result.controlPlaneEndUtc
    $baseline = @($samples | Where-Object { (Get-UtcTimestamp $_.startedUtc) -lt $resizeStart })
    $post = @($samples | Where-Object { (Get-UtcTimestamp $_.startedUtc) -ge $controlEnd -and $_.success })
    $failures = @($samples | Where-Object { !$_.success })
    $windows = [System.Collections.Generic.List[object]]::new()
    $firstFailure = -1
    $maximumSampleGap = 0.0
    $invalidIdentity = 0
    for ($i = 0; $i -lt $samples.Count; $i++) {
        $sample = $samples[$i]
        if ($i -gt 0) {
            $gap = ((Get-UtcTimestamp $sample.startedUtc) - (Get-UtcTimestamp $samples[$i-1].startedUtc)).TotalMilliseconds
            $maximumSampleGap = [math]::Max($maximumSampleGap, $gap)
        }
        if ($sample.success) {
            $health = $sample.body | ConvertFrom-Json
            if ($health.applicationId -ne $result.beforeHealth.applicationId -or $health.payloadSha256 -ne $result.beforeHealth.payloadSha256) {
                $invalidIdentity++
            }
        }
        if (!$sample.success -and $firstFailure -lt 0) { $firstFailure = $i }
        if ($sample.success -and $firstFailure -ge 0) {
            $first = $samples[$firstFailure]
            $lastFailure = $samples[$i-1]
            $lastGood = if ($firstFailure -gt 0) { $samples[$firstFailure-1] } else { $null }
            $windows.Add([pscustomobject]@{
                firstFailedProbeUtc = (Get-UtcTimestamp $first.startedUtc).ToString('o')
                lastFailedProbeUtc = (Get-UtcTimestamp $lastFailure.startedUtc).ToString('o')
                firstRecoveredProbeUtc = (Get-UtcTimestamp $sample.startedUtc).ToString('o')
                lastSuccessfulProbeBeforeUtc = if ($lastGood) { (Get-UtcTimestamp $lastGood.startedUtc).ToString('o') } else { $null }
                failedProbes = $i - $firstFailure
                observedFailureToRecoverySeconds = ((Get-UtcTimestamp $sample.startedUtc) - (Get-UtcTimestamp $first.startedUtc)).TotalSeconds
                lastGoodToFirstGoodSeconds = if ($lastGood) { ((Get-UtcTimestamp $sample.startedUtc) - (Get-UtcTimestamp $lastGood.startedUtc)).TotalSeconds } else { $null }
            })
            $firstFailure = -1
        }
    }
    if ($firstFailure -ge 0) { throw "Monitoring ended during an outage: $($result.experiment)" }
    if ($invalidIdentity) { throw "Application identity/hash mismatch in $invalidIdentity probes." }
    if (@($baseline | Where-Object { !$_.success }).Count) { throw 'Baseline includes failed requests.' }
    if ($post.Count -lt 30) { throw 'Insufficient successful post-control-plane probes.' }
    [pscustomobject]@{
        experiment = $result.experiment
        region = $result.region
        source = $result.source
        target = $result.target
        targetInOriginalCluster = $result.targetInOriginalCluster
        samples = $samples.Count
        failures = $failures.Count
        sampleSuccessPercent = [math]::Round(100 * ($samples.Count - $failures.Count) / $samples.Count, 3)
        monitorStartUtc = (Get-UtcTimestamp $samples[0].startedUtc).ToString('o')
        monitorEndUtc = (Get-UtcTimestamp $samples[-1].endedUtc).ToString('o')
        monitorDurationSeconds = ((Get-UtcTimestamp $samples[-1].endedUtc) - (Get-UtcTimestamp $samples[0].startedUtc)).TotalSeconds
        controlPlaneSeconds = ($controlEnd - $resizeStart).TotalSeconds
        firstFailureDelaySeconds = if ($windows.Count) { ((Get-UtcTimestamp $windows[0].firstFailedProbeUtc) - $resizeStart).TotalSeconds } else { $null }
        observedDowntimeSeconds = ($windows | Measure-Object observedFailureToRecoverySeconds -Sum).Sum
        maximumSampleGapMs = $maximumSampleGap
        maxScheduleLagMs = ($samples | Measure-Object scheduleLagMs -Maximum).Maximum
        baselineCount = $baseline.Count
        baselineLatencyP50Ms = Get-Percentile @($baseline | Where-Object success | ForEach-Object elapsedMs) 0.5
        baselineLatencyP95Ms = Get-Percentile @($baseline | Where-Object success | ForEach-Object elapsedMs) 0.95
        baselineLatencyP99Ms = Get-Percentile @($baseline | Where-Object success | ForEach-Object elapsedMs) 0.99
        postControlPlaneCount = $post.Count
        postLatencyP50Ms = Get-Percentile @($post | ForEach-Object elapsedMs) 0.5
        postLatencyP95Ms = Get-Percentile @($post | ForEach-Object elapsedMs) 0.95
        postLatencyP99Ms = Get-Percentile @($post | ForEach-Object elapsedMs) 0.99
        operations = $result.operations
        windows = $windows.ToArray()
        identitiesAndPayloadPreserved = $invalidIdentity -eq 0
        beforeBootCount = $result.beforeHealth.bootCount
        afterBootCount = $result.afterHealth.bootCount
    }
}
if (@($summaries).Count -ne $ExpectedExperiments) { throw "Expected $ExpectedExperiments completed experiments." }
$events = @(Get-Content -LiteralPath (Join-Path $EvidencePath 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
$created = @($events | Where-Object { $_.event -eq 'azure-command' -and $_.data.arguments[0] -eq 'group' -and $_.data.arguments[1] -eq 'create' -and $_.data.exitCode -eq 0 })
$cleaned = @($events | Where-Object event -eq 'cleanup-verified')
if ($created.Count -ne $cleaned.Count -or @($events | Where-Object event -eq 'cleanup-failed').Count) { throw 'Cleanup evidence is incomplete.' }
$output = [ordered]@{
    analysisVersion = 1
    experiments = @($summaries)
    cleanup = @{ createdGroups=$created.Count; deletedAndVerifiedGroups=$cleaned.Count }
    regionFailures = @($events | Where-Object event -eq 'region-attempt-failed' | ForEach-Object data)
    exemptions = @($events | Where-Object event -eq 'exemption-created' | ForEach-Object data)
}
$output | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $EvidencePath 'summary.json')
$summaries | Select-Object experiment,region,source,target,controlPlaneSeconds,observedDowntimeSeconds,samples,failures,baselineLatencyP95Ms,postLatencyP95Ms | Format-Table -AutoSize
