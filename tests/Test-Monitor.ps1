$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('resize-monitor-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
$output = Join-Path $directory 'probes.jsonl'
$stop = Join-Path $directory 'stop'
$server = Start-Job -ArgumentList $stop -ScriptBlock {
    param($StopPath)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    Write-Output $listener.LocalEndpoint.Port
    $index = 0
    try {
        while (!(Test-Path -LiteralPath $StopPath)) {
            if (!$listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $buffer = [byte[]]::new(4096)
                $null = $stream.Read($buffer, 0, $buffer.Length)
                $index++
                $status = '200 OK'
                $body = '{"status":"ok","applicationId":"test-app","payloadSha256":"test-hash"}'
                if ($index -eq 3) { $body = '{"status":"unhealthy"}' }
                if ($index -eq 4) { $status = '503 Service Unavailable'; $body = 'unavailable' }
                if ($index -eq 5) { Start-Sleep -Milliseconds 1000 }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("HTTP/1.1 $status`r`nContent-Length: $([System.Text.Encoding]::UTF8.GetByteCount($body))`r`nConnection: close`r`nContent-Type: application/json`r`n`r`n$body")
                try { $stream.Write($bytes, 0, $bytes.Length) } catch [System.IO.IOException] { Write-Verbose 'Expected closed connection after client timeout.' }
            } finally { $client.Dispose() }
        }
    } finally { $listener.Stop() }
}
$process = $null
try {
    $port = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (!$port -and [DateTime]::UtcNow -lt $deadline) {
        $port = Receive-Job $server
        if (!$port) { Start-Sleep -Milliseconds 200 }
    }
    if (!$port) { throw 'Test HTTP server did not start.' }
    $args = @('-NoProfile','-File',"`"$(Join-Path $root 'scripts\Monitor-Http.ps1')`"",'-Url',"http://127.0.0.1:$port/health",'-OutputPath',"`"$output`"",'-StopFile',"`"$stop`"",'-IntervalMs','300','-TimeoutMs','200')
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $args -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6
    New-Item -ItemType File -Path $stop | Out-Null
    if (!$process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw 'Monitor failed to stop successfully.' }
    $rows = @(Get-Content -LiteralPath $output | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($rows | Where-Object success).Count -lt 4) { throw 'Successful response handling failed.' }
    if (!@($rows | Where-Object { $_.statusCode -eq 503 -and !$_.success }).Count) { throw 'HTTP 503 handling failed.' }
    if (!@($rows | Where-Object { $_.error -eq 'Unexpected health response' }).Count) { throw 'Invalid application health was accepted.' }
    if (!@($rows | Where-Object { $null -eq $_.statusCode -and !$_.success }).Count) { throw 'Timeout handling failed.' }
    if (@($rows | Where-Object { $_.elapsedMs -lt 0 -or !$_.startedUtc -or !$_.endedUtc }).Count) { throw 'Invalid timing data.' }
    Write-Output "PASS: success, invalid health, HTTP 503, timeout, timestamps, JSONL persistence and graceful stop ($($rows.Count) samples)."
} finally {
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id }
    Stop-Job $server
    Remove-Job $server
    foreach ($file in @($output, $stop)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
    Remove-Item -LiteralPath $directory
}
