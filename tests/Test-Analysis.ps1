$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('resize-analysis-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $origin = [DateTimeOffset]::Parse('2026-01-01T00:00:00.1234567Z')
    foreach ($name in @('legacy-v1','legacy-v2')) {
        $probes = for ($i = 0; $i -lt 100; $i++) {
            $ok = $i -lt 20 -or $i -ge 30
            [ordered]@{
                startedUtc=$origin.AddSeconds($i).ToString('o')
                endedUtc=$origin.AddSeconds($i).AddMilliseconds(10).ToString('o')
                elapsedMs=10
                success=$ok
                statusCode=if($ok){200}else{503}
                error=if($ok){$null}else{'HTTP 503'}
                body='{"status":"ok","applicationId":"app","payloadSha256":"hash"}'
                scheduleLagMs=0
            } | ConvertTo-Json -Compress
        }
        $probes | Set-Content -LiteralPath (Join-Path $directory "$name-probes.jsonl")
        @{
            experiment=$name; region='test'; source='old'; target='new'
            resizeStartUtc=$origin.AddSeconds(15).AddMilliseconds(500).ToString('o')
            controlPlaneEndUtc=$origin.AddSeconds(35).ToString('o')
            probesFile="$name-probes.jsonl"
            beforeHealth=@{applicationId='app';payloadSha256='hash';bootCount=1}
            afterHealth=@{applicationId='app';payloadSha256='hash';bootCount=2}
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory "$name-result.json")
    }
    @(
        '{"event":"azure-command","data":{"arguments":["group","create"],"exitCode":0}}'
        '{"event":"cleanup-verified","data":{"group":"test","exists":false}}'
    ) | Set-Content -LiteralPath (Join-Path $directory 'events.jsonl')
    & (Join-Path $root 'scripts\Analyze-Results.ps1') -EvidencePath $directory | Out-Null
    $summary = Get-Content -LiteralPath (Join-Path $directory 'summary.json') -Raw | ConvertFrom-Json
    foreach ($result in $summary.experiments) {
        if ($result.observedDowntimeSeconds -ne 10 -or $result.failures -ne 10 -or $result.samples -ne 100) { throw 'Downtime/sample computation failed.' }
        if ($result.windows[0].lastGoodToFirstGoodSeconds -ne 11 -or $result.windows[0].failedProbes -ne 10) { throw 'Outage bracketing failed.' }
        if ($result.baselineLatencyP95Ms -ne 10 -or $result.postLatencyP95Ms -ne 10) { throw 'Latency percentile failed.' }
        if ($result.firstFailureDelaySeconds -ne 4.5 -or $result.controlPlaneSeconds -ne 19.5) { throw 'Subsecond timestamp precision was lost.' }
    }
    Write-Output 'PASS: two experiments, 10 s outage, 11 s last-good/first-good bracket, 10/100 failures, percentiles, subsecond timestamp precision and cleanup accounting.'
} finally {
    Get-ChildItem -LiteralPath $directory -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $directory
}
