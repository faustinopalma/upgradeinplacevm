param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputPath) { throw 'OutputPath must be new: refusing to overwrite a published dataset.' }
$source = (Resolve-Path -LiteralPath $EvidencePath).Path
$identifiers = @{}
$addresses = @{}
$manifest = [System.Collections.Generic.List[object]]::new()

function Convert-PublicationText([string]$Text) {
    $result = [regex]::Replace($Text, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|\b[0-9a-f]{32}\b', {
        param($Match)
        $key = $Match.Value.ToLowerInvariant()
        if (!$identifiers.ContainsKey($key)) { $identifiers[$key] = 'identity-{0:D3}' -f ($identifiers.Count + 1) }
        return $identifiers[$key]
    })
    $result = [regex]::Replace($result, '\b(?:\d{1,3}\.){3}\d{1,3}\b', {
        param($Match)
        $ip = $null
        if (![System.Net.IPAddress]::TryParse($Match.Value, [ref]$ip)) { return $Match.Value }
        if (!$addresses.ContainsKey($Match.Value)) {
            if ($addresses.Count -ge 254) { throw 'Too many addresses for documentation-only IPv4 replacements.' }
            $addresses[$Match.Value] = '192.0.2.{0}' -f ($addresses.Count + 1)
        }
        return $addresses[$Match.Value]
    })
    return $result
}

function Export-JsonFile([string]$Name) {
    $path = Join-Path $source $Name
    if (!(Test-Path -LiteralPath $path)) { throw "Required evidence file missing: $Name" }
    $text = Get-Content -LiteralPath $path -Raw
    $null = $text | ConvertFrom-Json -Depth 100
    (Convert-PublicationText $text).TrimEnd() | Set-Content -LiteralPath (Join-Path $OutputPath $Name) -Encoding utf8NoBOM
    $manifest.Add(@{ name=$Name; sourceSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash })
}

$eventsPath = Join-Path $source 'events.jsonl'
$events = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
if (@($events | Where-Object event -eq 'experiment-completed').Count -ne 2) { throw 'Expected two completed lab experiments.' }
if (@($events | Where-Object event -eq 'cleanup-failed').Count) { throw 'Cannot publish a run with cleanup failures.' }
New-Item -ItemType Directory -Path $OutputPath | Out-Null

foreach ($name in @('legacy-v1','legacy-v2')) {
    foreach ($suffix in @('result.json','probes.jsonl','guest-after.json','os-disk-metadata.json','platform-cpu.json','platform-io.json')) {
        $fileName = "$name-$suffix"
        if ($suffix -eq 'probes.jsonl') {
            $path = Join-Path $source $fileName
            $rows = Get-Content -LiteralPath $path
            foreach ($row in $rows) { $null = $row | ConvertFrom-Json }
            $rows | ForEach-Object { Convert-PublicationText $_ } | Set-Content -LiteralPath (Join-Path $OutputPath $fileName) -Encoding utf8NoBOM
            $manifest.Add(@{ name=$fileName; sourceSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash })
        } else {
            Export-JsonFile $fileName
        }
    }
}
foreach ($file in @('cleanup-final-verification.json','retail-prices-eur.json')) { Export-JsonFile $file }

$curated = foreach ($event in $events) {
    if ($event.event -eq 'azure-command' -and $event.data.arguments[0] -eq 'group' -and $event.data.arguments[1] -eq 'create') {
        [ordered]@{
            utc=$event.utc; event=$event.event
            data=@{ arguments=@('group','create'); exitCode=$event.data.exitCode; elapsedMs=$event.data.elapsedMs }
        }
    } elseif ($event.event -eq 'region-attempt-failed') {
        [ordered]@{
            utc=$event.utc; event=$event.event
            data=@{ experiment=$event.data.experiment; group=$event.data.group; region=$event.data.region; error='SkuNotAvailable' }
        }
        if ($event.data.error -notmatch 'SkuNotAvailable') { throw 'Unexpected regional failure: review it before publishing.' }
    } elseif ($event.event -in @('cleanup-verified','run-finished','exemption-created')) {
        if ($event.event -eq 'run-finished') {
            [ordered]@{ utc=$event.utc; event=$event.event; data=@{experiments=$event.data.experiments;cleanupFailed=$event.data.cleanupFailed} }
        } else {
            $event
        }
    }
}
$curated | ForEach-Object { Convert-PublicationText ($_ | ConvertTo-Json -Depth 30 -Compress) } |
    Set-Content -LiteralPath (Join-Path $OutputPath 'events.jsonl') -Encoding utf8NoBOM
$manifest.Add(@{ name='events.jsonl'; sourceSha256=(Get-FileHash -LiteralPath $eventsPath -Algorithm SHA256).Hash })
foreach ($file in @('validation.txt','validation-timestamp-precision.txt')) {
    $path = Join-Path $source $file
    if (!(Test-Path -LiteralPath $path)) { throw "Required validation evidence missing: $file" }
    (Convert-PublicationText (Get-Content -LiteralPath $path -Raw)).TrimEnd() |
        Set-Content -LiteralPath (Join-Path $OutputPath $file) -Encoding utf8NoBOM
    $manifest.Add(@{ name=$file; sourceSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash })
}
& (Join-Path $PSScriptRoot 'Analyze-Results.ps1') -EvidencePath $OutputPath
$original = Get-Content -LiteralPath (Join-Path $source 'summary.json') -Raw | ConvertFrom-Json
$exported = Get-Content -LiteralPath (Join-Path $OutputPath 'summary.json') -Raw | ConvertFrom-Json
foreach ($name in @('legacy-v1','legacy-v2')) {
    $before = $original.experiments | Where-Object experiment -eq $name
    $after = $exported.experiments | Where-Object experiment -eq $name
    foreach ($field in @('samples','failures','observedDowntimeSeconds','controlPlaneSeconds','baselineLatencyP95Ms','postLatencyP95Ms')) {
        if ($before.$field -ne $after.$field) { throw "Publication changed measurement $name/$field" }
    }
}
[ordered]@{
    schemaVersion=1
    sourceRun=Split-Path $source -Leaf
    language='English'
    dataType='Sanitized measurements from a real Azure experiment; not synthetic.'
    preserved=@('UTC timestamps and precision','probe ordering and outcomes','durations','boot counts','payload SHA-256','identity equality')
    pseudonymized=@('UUIDs and guest machine IDs -> consistent identity labels','IPv4 addresses -> RFC 5737 documentation addresses')
    omitted=@('authentication data','raw account responses','local paths','public/private keys','deployment parameters','governance inventories','full Activity Logs','unfiltered command outputs')
    events='Curated resource-group creation, SKU failure and cleanup events; not the full operational log.'
    historicalFieldNote='The original result hyperVGeneration field contains the image SKU; actual V1 generation is confirmed by the separate OS disk metadata.'
    verification='Published analysis matches source sample counts, failure counts, downtime, control-plane duration and p95 latencies.'
    sourceFiles=$manifest.ToArray()
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputPath 'publication-manifest.json') -Encoding utf8NoBOM
Write-Output "Exported sanitized measured evidence to $OutputPath."
