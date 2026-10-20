$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('resize-common-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
$SubscriptionId = 'expected-active-subscription'
$script:lastArguments = @()
$script:mockExitCode = 0

function az {
    $script:lastArguments = @($args)
    $global:LASTEXITCODE = $script:mockExitCode
    if ($script:mockExitCode) { 'Simulated Azure CLI error' } else { '{"ok":true}' }
}

try {
    . (Join-Path $root 'scripts\Lab-Common.ps1') -EvidencePath $directory
    if ($SubscriptionId -ne 'expected-active-subscription') { throw 'Shared helper overwrote the caller subscription.' }
    $response = Invoke-Az @('vm','show','-g','test','-n','test','-o','json')
    if ($response.ExitCode -ne 0 -or !($response.Text | ConvertFrom-Json).ok -or '--subscription' -in $script:lastArguments) {
        throw 'Legacy caller behavior changed.'
    }
    . (Join-Path $root 'scripts\Lab-Common.ps1') -EvidencePath $directory -AzureSubscriptionId 'explicit-subscription'
    $null = Invoke-Az @('group','list','-o','json')
    $index = [array]::IndexOf($script:lastArguments, '--subscription')
    if ($index -lt 0 -or $script:lastArguments[$index + 1] -ne 'explicit-subscription') { throw 'Explicit subscription was not applied.' }
    $null = Invoke-Az @('account','show','-o','json')
    if ('--subscription' -in $script:lastArguments) { throw 'Active-account verification was redirected to a supplied subscription.' }
    $script:mockExitCode = 7
    $failed = $false
    try { $null = Invoke-Az @('vm','show','-g','test','-n','test') } catch {
        if ($_.Exception.Message -notmatch 'az failed \(7\)') { throw }
        $failed = $true
    }
    if (!$failed) { throw 'Azure CLI failure was hidden.' }
    $response = Invoke-Az @('vm','show','-g','test','-n','test') -AllowFailure
    if ($response.ExitCode -ne 7) { throw 'Allowed failure lost its actual exit code.' }
    $entries = @(Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($entries.Count -ne 5 -or @($entries | Where-Object { $_.data.exitCode -eq 7 }).Count -ne 2) {
        throw 'Azure CLI failure evidence was not persisted.'
    }
    Write-Output 'PASS: legacy subscription preservation, explicit resource scoping, active-account guard, command evidence and Azure CLI error propagation.'
} finally {
    foreach ($file in Get-ChildItem -LiteralPath $directory -File) { Remove-Item -LiteralPath $file.FullName }
    Remove-Item -LiteralPath $directory
}
