# Task-file helpers for Settings harnesses. No process, window or input access.
Set-StrictMode -Version Latest

# `bench_trace.SettingsOpenStage` and `bench_trace.SettingsCreationStage`.
$script:SettingsOutcomeStages = @('f9_keydown','f9_before_core_initialized','open_config_action',
    'settings_open_enter','settings_open_ok','settings_open_error')
$script:SettingsCreationStages = @('create_begin','create_config','create_frame','create_theme','create_fonts',
    'create_rail','create_form','create_actions','create_annotate','create_refresh','create_layout',
    'create_show','create_end')

function Write-SettingsOpenReceipt {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowNull()] $Value)
    # The caller owns a NEW output directory and is its sole writer.
    # Keep the flushed temporary sibling if publication fails.
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 16))
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) {
        # Move(overwrite) fails on an open Windows target even with delete sharing.
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    } else { [IO.File]::Move($temporary, $Path) }
}

function Read-StartupAttempt {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Json')][AllowEmptyString()][string] $Json
    )
    $result = [ordered]@{ stage = 'missing'; reason = 'ledger-missing'; attemptCount = 0; latest = $null }
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        try {
            if (-not [IO.File]::Exists($Path)) { return [pscustomobject]$result }
            # The product atomically replaces this ledger while startup advances.
            # Do not deny its writes or replacement during a readiness poll.
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                if ($stream.Length -gt 128KB) {
                    $result.stage = 'invalid'; $result.reason = 'ledger-size-limit'
                    return [pscustomobject]$result
                }
                $reader = [IO.StreamReader]::new($stream)
                try { $Json = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
        } catch {
            $result.stage = 'unreadable'; $result.reason = 'ledger-read-failed'
            return [pscustomobject]$result
        }
    }
    try { $record = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch {
        $result.stage = 'malformed'; $result.reason = 'ledger-json-invalid'
        return [pscustomobject]$result
    }
    $result.stage = 'invalid'; $result.reason = 'ledger-schema-invalid'
    if ($null -eq $record -or -not $record.PSObject.Properties['schema_version'] -or
        $record.schema_version -ne 1 -or -not $record.PSObject.Properties['attempts'] -or
        $record.attempts -isnot [Array]) { return [pscustomobject]$result }
    $attempts = @($record.attempts)
    $result.attemptCount = $attempts.Count
    if ($attempts.Count -gt 16) { $result.reason = 'ledger-attempt-limit'; return [pscustomobject]$result }
    if ($attempts.Count -eq 0) {
        $result.stage = 'empty'; $result.reason = 'ledger-has-no-attempts'
        return [pscustomobject]$result
    }
    $previous = $null
    foreach ($attempt in $attempts) {
        [uint64]$started = 0
        if ($null -eq $attempt -or -not $attempt.PSObject.Properties['started_at_unix_ms'] -or
            -not [uint64]::TryParse([string]$attempt.started_at_unix_ms, [ref]$started)) {
            $result.reason = 'attempt-start-invalid'; return [pscustomobject]$result
        }
        if ($null -ne $previous -and $started -lt $previous) {
            $result.reason = 'attempts-out-of-order'; return [pscustomobject]$result
        }
        $previous = $started
    }
    $latest = $attempts[-1]
    $phase = if ($latest.PSObject.Properties['phase']) { [string]$latest.phase } else { 'init' }
    if ($phase -notin 'init','window_created','ready','ready_persist_failed') {
        $result.reason = 'attempt-phase-invalid'; return [pscustomobject]$result
    }
    $ready = $null
    if ($latest.PSObject.Properties['ready_at_unix_ms'] -and $null -ne $latest.ready_at_unix_ms) {
        [uint64]$parsedReady = 0
        if (-not [uint64]::TryParse([string]$latest.ready_at_unix_ms, [ref]$parsedReady)) {
            $result.reason = 'attempt-ready-invalid'; return [pscustomobject]$result
        }
        $ready = $parsedReady
    }
    $result.stage = 'observed'; $result.reason = 'latest-attempt-read'
    $result.latest = [pscustomobject]@{ started_at_unix_ms = [uint64]$latest.started_at_unix_ms
        phase = $phase; ready_at_unix_ms = $ready }
    return [pscustomobject]$result
}

function Get-NewReadyAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Alias('BaselineStartedAt')][Nullable[uint64]] $PreviousStartedAt
    )
    $result = [ordered]@{ ready = $false; stage = 'startup-' + $State.stage; reason = $State.reason
        previousStartedAt = $PreviousStartedAt; attempt = $State.latest; attemptCount = $State.attemptCount }
    if ($State.stage -ne 'observed') { return [pscustomobject]$result }
    if ($null -ne $PreviousStartedAt -and $State.latest.started_at_unix_ms -le $PreviousStartedAt) {
        $result.stage = 'startup-stale'; $result.reason = 'no-distinct-new-attempt'
    } elseif ($State.latest.phase -ne 'ready') {
        $result.stage = 'startup-pending'; $result.reason = 'new-attempt-not-ready'
    } elseif ($null -eq $State.latest.ready_at_unix_ms) {
        $result.stage = 'startup-pending'; $result.reason = 'new-attempt-has-no-ready-timestamp'
    } elseif ($State.latest.ready_at_unix_ms -lt $State.latest.started_at_unix_ms) {
        $result.stage = 'startup-invalid'; $result.reason = 'ready-before-start'
    } else {
        $result.ready = $true; $result.stage = 'startup-ready'; $result.reason = 'distinct-new-ready-attempt'
    }
    return [pscustomobject]$result
}

function ConvertFrom-SettingsOpenTrace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $summary = [ordered]@{ bytes = [Text.Encoding]::UTF8.GetByteCount($Text); rows = 0; invalidRows = 0
        pendingFinalLine = $false; readable = $true; tags = @{}; records = [Collections.Generic.List[object]]::new() }
    if ($summary.bytes -gt 128KB) {
        $summary.readable = $false; $summary.reason = 'summary-size-limit; full trace retained'
        return $summary
    }
    $lastNewline = $Text.LastIndexOf("`n", [StringComparison]::Ordinal)
    $summary.pendingFinalLine = $Text.Length -gt 0 -and $lastNewline -ne $Text.Length - 1
    if ($summary.pendingFinalLine) { $summary.reason = 'trace-final-line-pending; retry fresh snapshot' }
    # The product commits a record with its newline. Never treat an unfinished final line as invalid.
    $lines = if ($lastNewline -ge 0) { $Text.Substring(0, $lastNewline).Split("`n") } else { @() }
    foreach ($line in $lines) {
        if ($summary.rows -ge 1024) { $summary.reason = 'summary-row-limit; full trace retained'; break }
        $summary.rows++
        try {
            $row = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            [uint64]$tick = 0
            [uint64]$qpc = 0
            $names = @($row.PSObject.Properties.Name)
            # Outcome records carry the tick; the window's creation steps, written
            # after the open returns, add the performance counter in microseconds.
            $creation = $names.Count -eq 3 -and $row.stage -in $script:SettingsCreationStages
            if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 128 -or
                -not [uint64]::TryParse([string]$row.tick_ms, [ref]$tick) -or
                $(if ($creation) {
                    ($names -join ',') -cne 'tick_ms,stage,qpc_us' -or -not [uint64]::TryParse([string]$row.qpc_us, [ref]$qpc)
                } else {
                    $names.Count -ne 2 -or $row.stage -notin $script:SettingsOutcomeStages
                })) { throw 'trace-schema-invalid' }
            $tag = [string]$row.stage
            if (-not $summary.tags.ContainsKey($tag)) { $summary.tags[$tag] = 0 }
            $summary.tags[$tag]++
            $record = [ordered]@{ stage = $tag; tick_ms = $tick }
            if ($creation) { $record.qpc_us = $qpc }
            $summary.records.Add($record)
        } catch { $summary.invalidRows++ }
    }
    return $summary
}

function Test-SettingsOpenTraceParser {
    # Persisted pure regression checks: no file access, processes, desktops or input queries.
    [CmdletBinding()]
    param()
    $checks = 0
    $tags = @('f9_keydown','f9_before_core_initialized','open_config_action',
        'settings_open_enter','settings_open_ok','settings_open_error')
    foreach ($tag in $tags) {
        $result = ConvertFrom-SettingsOpenTrace -Text ('{"tick_ms":42,"stage":"' + $tag + '"}' + "`n")
        if ($result.invalidRows -ne 0 -or $result.records.Count -ne 1 -or
            $result.records[0].stage -cne $tag -or $result.records[0].tick_ms -ne 42) { throw "Trace tag regression: $tag" }
        $checks++
    }
    foreach ($tag in $script:SettingsCreationStages) {
        $result = ConvertFrom-SettingsOpenTrace -Text ('{"tick_ms":42,"stage":"' + $tag + '","qpc_us":1234567}' + "`n")
        if ($result.invalidRows -ne 0 -or $result.records.Count -ne 1 -or $result.records[0].stage -cne $tag -or
            $result.records[0].tick_ms -ne 42 -or $result.records[0].qpc_us -ne 1234567) { throw "Creation tag regression: $tag" }
        $checks++
    }
    foreach ($invalid in @('{"tick_ms":1,"stage":"create_form"}', '{"tick_ms":1,"stage":"settings_open_ok","qpc_us":5}',
        '{"tick_ms":1,"stage":"create_form","qpc_us":-5}', '{"tick_ms":1,"stage":"create_form","pid":5}',
        '{"qpc_us":5,"tick_ms":1,"stage":"create_form"}')) {
        $result = ConvertFrom-SettingsOpenTrace -Text ($invalid + "`n")
        if ($result.invalidRows -ne 1 -or $result.records.Count -ne 0) { throw "Invalid creation row accepted: $invalid" }
        $checks++
    }
    $committed = '{"tick_ms":1,"stage":"open_config_action"}' + "`n"
    foreach ($partial in @('{"tick_ms":2,"stage":"settings_open_', '{"tick_ms":2,"stage":"settings_open_ok"}')) {
        $result = ConvertFrom-SettingsOpenTrace -Text ($committed + $partial)
        if (-not $result.pendingFinalLine -or $result.rows -ne 1 -or $result.invalidRows -ne 0 -or
            $result.records.Count -ne 1 -or $result.tags.ContainsKey('settings_open_ok')) { throw 'Partial final line must remain pending' }
        $checks++
    }
    $result = ConvertFrom-SettingsOpenTrace -Text ($committed + '{"tick_ms":2,"stage":"settings_open_ok"}' + "`n")
    if ($result.pendingFinalLine -or $result.records.Count -ne 2 -or $result.tags.settings_open_ok -ne 1) { throw 'Completed retry must accept final record' }
    $checks++
    foreach ($invalid in @('{', '{"tick_ms":1,"stage":"app_initialized"}',
        '{"tick_ms":1,"stage":"f9_keydown","pid":42}', '{"stage":"f9_keydown"}',
        '{"tick_ms":-1,"stage":"f9_keydown"}', ('{"tick_ms":1,"stage":"f9_keydown"}' + (' ' * 128)))) {
        $result = ConvertFrom-SettingsOpenTrace -Text ($invalid + "`n")
        if ($result.pendingFinalLine -or $result.invalidRows -ne 1 -or $result.records.Count -ne 0) { throw 'Invalid committed row must be rejected' }
        $checks++
    }
    $result = ConvertFrom-SettingsOpenTrace -Text ''
    if ($result.pendingFinalLine -or $result.rows -ne 0 -or $result.records.Count -ne 0) { throw 'Empty trace regression' }
    $checks++
    $result = ConvertFrom-SettingsOpenTrace -Text ('{' )
    if (-not $result.pendingFinalLine -or $result.rows -ne 0 -or $result.invalidRows -ne 0) { throw 'Initial partial line regression' }
    $checks++
    $result = ConvertFrom-SettingsOpenTrace -Text ($committed * 1025)
    if ($result.rows -ne 1024 -or $result.records.Count -ne 1024 -or $result.reason -notlike 'summary-row-limit*') { throw 'Trace row cap regression' }
    $checks++
    $result = ConvertFrom-SettingsOpenTrace -Text (' ' * (128KB + 1))
    if ($result.readable -or $result.records.Count -ne 0 -or $result.reason -notlike 'summary-size-limit*') { throw 'Trace byte cap regression' }
    $checks++
    "Settings open trace parser PASS ($checks checks; no files, runtime or input queries)."
}

Export-ModuleMember -Function Read-StartupAttempt, Get-NewReadyAttempt, ConvertFrom-SettingsOpenTrace, Test-SettingsOpenTraceParser, Write-SettingsOpenReceipt
