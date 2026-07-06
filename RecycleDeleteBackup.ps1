param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "install-autostart", "uninstall-autostart", "run-daemon")]
    [string]$Action = "start",

    [string[]]$DriveLetter,

    [string]$BackupRoot = "",

    [int]$MaxFileSizeMB = 500,

    [int]$PollSeconds = 2,

    [string]$AutoStartEntryName = "RecycleDeleteBackupWatcher"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Mutex = $null

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $PSScriptRoot "backup"
}

function Get-RuntimeDir {
    $runtimeDir = Join-Path $PSScriptRoot ".runtime"
    Ensure-Directory -Path $runtimeDir
    return $runtimeDir
}

function Get-StatePath {
    return Join-Path (Get-RuntimeDir) "RecycleDeleteBackup.state.json"
}

function Get-SessionPath {
    return Join-Path (Get-RuntimeDir) "RecycleDeleteBackup.session.json"
}

function Get-ConfigPath {
    return Join-Path (Get-RuntimeDir) "RecycleDeleteBackup.config.json"
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-ToSafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $Name.ToCharArray()) {
        if ($invalidChars -contains $char) {
            [void]$builder.Append("_")
        } else {
            [void]$builder.Append($char)
        }
    }

    $value = $builder.ToString().Trim().Trim(".")
    if ([string]::IsNullOrWhiteSpace($value)) {
        return "unnamed"
    }

    if ($value.Length -gt 80) {
        return $value.Substring(0, 80).Trim()
    }

    return $value
}

function Normalize-DriveLetters {
    param(
        [string[]]$InputLetters
    )

    if (-not $InputLetters -or @($InputLetters).Count -eq 0) {
        return @()
    }

    return @($InputLetters | ForEach-Object {
        $raw = $_.Trim()
        if ($raw -match '^[A-Za-z]:\\') {
            throw "Parameter -DriveLetter only accepts a drive letter like D or E. Use -BackupRoot for backup folder paths."
        }

        $value = $raw.TrimEnd(':', '\')
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Invalid drive letter: $_"
        }

        $value.Substring(0, 1).ToUpperInvariant()
    } | Select-Object -Unique)
}

function Get-Layout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot
    )

    $deletedRoot = Join-Path $BackupRoot "deleted"
    $manifestPath = Join-Path $deletedRoot "manifest.jsonl"

    Ensure-Directory -Path $BackupRoot
    Ensure-Directory -Path $deletedRoot

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        New-Item -ItemType File -Path $manifestPath | Out-Null
    }

    return @{
        DeletedRoot = $deletedRoot
        ManifestPath = $manifestPath
    }
}

function Append-ManifestRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Record
    )

    $json = ([pscustomobject]$Record) | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $ManifestPath -Value $json
}

function Get-DriveLetterFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -match '^[A-Za-z]:') {
        return $Path.Substring(0, 1).ToUpperInvariant()
    }

    return $null
}

function Get-RecycleBinItems {
    $shell = New-Object -ComObject Shell.Application
    $bin = $shell.Namespace(10)
    if ($null -eq $bin) {
        return @()
    }

    return @(@($bin.Items()) | ForEach-Object {
        $originalDir = [string]$_.ExtendedProperty("System.Recycle.DeletedFrom")
        $name = [string]$_.Name
        $deletedAt = $_.ExtendedProperty("System.Recycle.DateDeleted")
        $recyclePath = [string]$_.Path
        $originalPath = if ([string]::IsNullOrWhiteSpace($originalDir)) {
            $name
        } else {
            Join-Path $originalDir $name
        }

        [pscustomobject]@{
            Name = $name
            RecyclePath = $recyclePath
            OriginalPath = $originalPath
            DriveLetter = Get-DriveLetterFromPath -Path $originalPath
            DeletedAt = $deletedAt
            IsDirectory = (Test-Path -LiteralPath $recyclePath -PathType Container)
        }
    })
}

function Save-SessionSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$SessionSet
    )

    @($SessionSet.Keys | Sort-Object) | ConvertTo-Json | Set-Content -LiteralPath $SessionPath
}

function Initialize-Baseline {
    param(
        [string[]]$DriveLetters,

        [Parameter(Mandatory = $true)]
        [hashtable]$SessionSet
    )

    $normalized = Normalize-DriveLetters -InputLetters $DriveLetters
    foreach ($item in (Get-RecycleBinItems)) {
        if ([string]::IsNullOrWhiteSpace($item.DriveLetter)) {
            continue
        }

        if (@($normalized).Count -gt 0 -and $normalized -notcontains $item.DriveLetter) {
            continue
        }

        $SessionSet[$item.RecyclePath] = $true
    }
}

function Get-ItemTotalBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
        return [int64](Get-Item -LiteralPath $LiteralPath).Length
    }

    $sum = (Get-ChildItem -LiteralPath $LiteralPath -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) {
        return 0L
    }

    return [int64]$sum
}

function Get-RelativeOriginalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalPath
    )

    if ($OriginalPath -match '^[A-Za-z]:\\(.+)$') {
        return $Matches[1]
    }

    return Convert-ToSafeName -Name $OriginalPath
}

function New-BackupTarget {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Layout,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Item
    )

    $timestamp = if ($Item.DeletedAt) { [datetime]$Item.DeletedAt } else { Get-Date }
    $dateFolder = Join-Path $Layout.DeletedRoot ($timestamp.ToString("yyyy-MM-dd"))
    $driveFolder = Join-Path $dateFolder ($Item.DriveLetter + "_drive")
    $relativePath = Get-RelativeOriginalPath -OriginalPath $Item.OriginalPath
    $parentRelative = Split-Path -Parent $relativePath
    $leafName = Split-Path -Leaf $relativePath

    $destinationDir = if ([string]::IsNullOrWhiteSpace($parentRelative)) {
        $driveFolder
    } else {
        Join-Path $driveFolder $parentRelative
    }

    Ensure-Directory -Path $destinationDir

    $baseName = "{0}-{1}" -f $timestamp.ToString("HHmmss"), (Convert-ToSafeName -Name $leafName)
    $destinationPath = Join-Path $destinationDir $baseName
    $counter = 1

    while (Test-Path -LiteralPath $destinationPath) {
        $destinationPath = Join-Path $destinationDir ("{0}-{1}-{2}" -f $timestamp.ToString("HHmmss"), (Convert-ToSafeName -Name $leafName), $counter)
        $counter++
    }

    return $destinationPath
}

function Backup-RecycledItem {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Item,

        [Parameter(Mandatory = $true)]
        [hashtable]$Layout,

        [Parameter(Mandatory = $true)]
        [int64]$MaxBytes
    )

    if (-not (Test-Path -LiteralPath $Item.RecyclePath)) {
        return @{
            status = "missing"
            reason = "Recycle bin payload disappeared before backup."
        }
    }

    $totalBytes = Get-ItemTotalBytes -LiteralPath $Item.RecyclePath
    if ($totalBytes -gt $MaxBytes) {
        return @{
            status = "skipped_too_large"
            sizeBytes = $totalBytes
            reason = "Item exceeds size limit."
        }
    }

    $destinationPath = New-BackupTarget -Layout $Layout -Item $Item
    if ($Item.IsDirectory) {
        Copy-Item -LiteralPath $Item.RecyclePath -Destination $destinationPath -Recurse -Force
    } else {
        Copy-Item -LiteralPath $Item.RecyclePath -Destination $destinationPath -Force
    }

    return @{
        status = "backed_up"
        sizeBytes = $totalBytes
        backupPath = $destinationPath
    }
}

function Process-RecycleBin {
    param(
        [string[]]$DriveLetters,

        [Parameter(Mandatory = $true)]
        [hashtable]$Layout,

        [Parameter(Mandatory = $true)]
        [hashtable]$SessionSet,

        [Parameter(Mandatory = $true)]
        [int64]$MaxBytes,

        [Parameter(Mandatory = $true)]
        [string]$BackupRoot
    )

    $normalized = Normalize-DriveLetters -InputLetters $DriveLetters

    foreach ($item in (Get-RecycleBinItems)) {
        if ([string]::IsNullOrWhiteSpace($item.DriveLetter)) {
            continue
        }

        if (@($normalized).Count -gt 0 -and $normalized -notcontains $item.DriveLetter) {
            continue
        }

        if ($SessionSet.ContainsKey($item.RecyclePath)) {
            continue
        }

        if ($item.OriginalPath -like ($BackupRoot.TrimEnd('\') + '*')) {
            $SessionSet[$item.RecyclePath] = $true
            Save-SessionSet -SessionPath (Get-SessionPath) -SessionSet $SessionSet
            continue
        }

        $result = Backup-RecycledItem -Item $item -Layout $Layout -MaxBytes $MaxBytes
        $record = @{
            watchedDrive = $item.DriveLetter
            originalPath = $item.OriginalPath
            recyclePath = $item.RecyclePath
            deletedAt = if ($item.DeletedAt) { ([datetime]$item.DeletedAt).ToString("o") } else { $null }
            processedAt = (Get-Date).ToString("o")
            isDirectory = $item.IsDirectory
            status = $result.status
            sizeBytes = if ($result.ContainsKey("sizeBytes")) { $result.sizeBytes } else { $null }
            backupPath = if ($result.ContainsKey("backupPath")) { $result.backupPath } else { $null }
            reason = if ($result.ContainsKey("reason")) { $result.reason } else { $null }
        }

        Append-ManifestRecord -ManifestPath $Layout.ManifestPath -Record $record
        $SessionSet[$item.RecyclePath] = $true
        Save-SessionSet -SessionPath (Get-SessionPath) -SessionSet $SessionSet
    }
}

function Show-Status {
    $statePath = Get-StatePath
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-Host "RecycleDeleteBackup is not running."
        return
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $isRunning = $false

    try {
        $null = Get-Process -Id $state.pid -ErrorAction Stop
        $isRunning = $true
    } catch {
        $isRunning = $false
    }

    $driveLetters = @($state.driveLetters | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    [pscustomobject]@{
        pid = $state.pid
        startedAt = $state.startedAt
        driveLetters = if ($driveLetters.Count -eq 0) { "all drives" } else { ($driveLetters -join ", ") }
        maxFileSizeMB = $state.maxFileSizeMB
        backupRoot = $state.backupRoot
        pollSeconds = $state.pollSeconds
        isRunning = $isRunning
    } | Format-List
}

function Stop-Watcher {
    $statePath = Get-StatePath
    $sessionPath = Get-SessionPath

    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-Host "RecycleDeleteBackup is not running."
        return
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

    try {
        Stop-Process -Id $state.pid -Force -ErrorAction Stop
        Write-Host ("RecycleDeleteBackup stopped. PID: {0}" -f $state.pid)
    } catch {
        Write-Warning ("Could not stop PID {0}: {1}" -f $state.pid, $_.Exception.Message)
    }

    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
}

function Install-AutoStart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,

        [Parameter(Mandatory = $true)]
        [int]$MaxFileSizeMB,

        [Parameter(Mandatory = $true)]
        [int]$PollSeconds,

        [string[]]$DriveLetters
    )

    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Ensure-Directory -Path $BackupRoot

    $args = @(
        "-WindowStyle Hidden",
        "-ExecutionPolicy Bypass",
        ('-File "{0}"' -f $ScriptPath),
        "start",
        ('-BackupRoot "{0}"' -f $BackupRoot),
        ("-MaxFileSizeMB {0}" -f $MaxFileSizeMB),
        ("-PollSeconds {0}" -f $PollSeconds)
    )

    if ($DriveLetters -and @($DriveLetters).Count -gt 0) {
        $args += ('-DriveLetter "{0}"' -f ($DriveLetters -join '","'))
    }

    $command = "powershell.exe " + ($args -join " ")

    if (-not (Test-Path -LiteralPath $runKey)) {
        New-Item -Path $runKey | Out-Null
    }

    Set-ItemProperty -LiteralPath $runKey -Name $EntryName -Value $command

    Write-Host ("Auto-start entry installed: {0}" -f $EntryName)
    Write-Host ("Command: {0}" -f $command)
}

function Uninstall-AutoStart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryName
    )

    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path -LiteralPath $runKey) {
        Remove-ItemProperty -LiteralPath $runKey -Name $EntryName -ErrorAction SilentlyContinue
    }

    Write-Host ("Auto-start entry removed: {0}" -f $EntryName)
}

function Start-Watcher {
    param(
        [string[]]$DriveLetters,
        [string]$BackupRoot,
        [int]$MaxFileSizeMB,
        [int]$PollSeconds
    )

    $statePath = Get-StatePath
    $sessionPath = Get-SessionPath
    $configPath = Get-ConfigPath

    if (Test-Path -LiteralPath $statePath) {
        try {
            $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $null = Get-Process -Id $existingState.pid -ErrorAction Stop
            throw "RecycleDeleteBackup is already running with PID $($existingState.pid)."
        } catch {
            if ($_.Exception.Message -like "RecycleDeleteBackup is already running*") {
                throw
            }

            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue

    $normalized = Normalize-DriveLetters -InputLetters $DriveLetters
    Ensure-Directory -Path $BackupRoot

    $config = @{
        driveLetters = $normalized
        backupRoot = $BackupRoot
        maxFileSizeMB = $MaxFileSizeMB
        pollSeconds = $PollSeconds
    }
    ([pscustomobject]$config | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $configPath

    $arguments = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "run-daemon"
    )
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -PassThru -WindowStyle Hidden

    Start-Sleep -Milliseconds 700

    $state = @{
        pid = $process.Id
        startedAt = (Get-Date).ToString("o")
        driveLetters = $normalized
        maxFileSizeMB = $MaxFileSizeMB
        backupRoot = $BackupRoot
        pollSeconds = $PollSeconds
    }
    ([pscustomobject]$state | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $statePath

    Write-Host ("RecycleDeleteBackup started. PID: {0}" -f $process.Id)
    if (@($normalized).Count -eq 0) {
        Write-Host "Watching drive(s): all drives"
    } else {
        Write-Host ("Watching drive(s): {0}" -f ($normalized -join ", "))
    }
    Write-Host ("Max file size: {0} MB" -f $MaxFileSizeMB)
    Write-Host ("Backup root: {0}" -f $BackupRoot)
}

function Run-Daemon {
    $configPath = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Config file not found: $configPath"
    }

    $mutexCreated = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, "Global\RecycleDeleteBackupWatcher", [ref]$mutexCreated)
    if (-not $mutexCreated) {
        $script:Mutex.Dispose()
        $script:Mutex = $null
        throw "Another RecycleDeleteBackup instance is already running."
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $layout = Get-Layout -BackupRoot $config.backupRoot
    $sessionPath = Get-SessionPath
    $sessionSet = @{}
    Initialize-Baseline -DriveLetters @($config.driveLetters) -SessionSet $sessionSet
    Save-SessionSet -SessionPath $sessionPath -SessionSet $sessionSet

    $state = @{
        pid = $PID
        startedAt = (Get-Date).ToString("o")
        driveLetters = @($config.driveLetters)
        maxFileSizeMB = [int]$config.maxFileSizeMB
        backupRoot = $config.backupRoot
        pollSeconds = [int]$config.pollSeconds
    }
    ([pscustomobject]$state | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Get-StatePath)

    try {
        while ($true) {
            Process-RecycleBin -DriveLetters @($config.driveLetters) -Layout $layout -SessionSet $sessionSet -MaxBytes ([int64]$config.maxFileSizeMB * 1MB) -BackupRoot $config.backupRoot
            Start-Sleep -Seconds ([int]$config.pollSeconds)
        }
    } finally {
        if ($script:Mutex -ne $null) {
            $script:Mutex.ReleaseMutex()
            $script:Mutex.Dispose()
            $script:Mutex = $null
        }
    }
}

switch ($Action) {
    "start" {
        Start-Watcher -DriveLetters $DriveLetter -BackupRoot $BackupRoot -MaxFileSizeMB $MaxFileSizeMB -PollSeconds $PollSeconds
    }
    "stop" {
        Stop-Watcher
    }
    "status" {
        Show-Status
    }
    "install-autostart" {
        Install-AutoStart -EntryName $AutoStartEntryName -ScriptPath $PSCommandPath -BackupRoot $BackupRoot -MaxFileSizeMB $MaxFileSizeMB -PollSeconds $PollSeconds -DriveLetters (Normalize-DriveLetters -InputLetters $DriveLetter)
    }
    "uninstall-autostart" {
        Uninstall-AutoStart -EntryName $AutoStartEntryName
    }
    "run-daemon" {
        Run-Daemon
    }
}
