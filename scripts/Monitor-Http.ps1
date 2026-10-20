param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$StopFile,
    [int]$IntervalMs = 1000,
    [int]$TimeoutMs = 800,
    [int]$MaxMinutes = 90
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
$writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$next = 0L
try {
    while (!(Test-Path -LiteralPath $StopFile) -and $clock.Elapsed.TotalMinutes -lt $MaxMinutes) {
        $started = [DateTimeOffset]::UtcNow
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $status = $null
        $body = $null
        $errorText = $null
        $success = $false
        try {
            $response = $client.GetAsync($Url).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($status -eq 200) {
                    $health = $body | ConvertFrom-Json
                    $success = $health.status -eq 'ok' -and !!$health.applicationId -and !!$health.payloadSha256
                    if (!$success) { $errorText = 'Unexpected health response' }
                } else { $errorText = "HTTP $status" }
            } finally { $response.Dispose() }
        } catch {
            $errorText = $_.Exception.GetBaseException().Message
        }
        $timer.Stop()
        $row = [ordered]@{
            startedUtc = $started.ToString('o')
            endedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            elapsedMs = [math]::Round($timer.Elapsed.TotalMilliseconds, 3)
            success = $success
            statusCode = $status
            error = $errorText
            body = $body
            monotonicMs = $clock.ElapsedMilliseconds
            scheduleLagMs = [math]::Max(0, $clock.ElapsedMilliseconds - $timer.ElapsedMilliseconds - $next)
        }
        $writer.WriteLine(($row | ConvertTo-Json -Compress))
        $next += $IntervalMs
        $wait = $next - $clock.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
} finally {
    $writer.Dispose()
    $client.Dispose()
    $handler.Dispose()
}
