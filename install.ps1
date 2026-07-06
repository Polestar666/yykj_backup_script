param(
    [string]$InstallDir = "",
    [string]$BackupRoot = "",
    [string[]]$DriveLetter,
    [int]$MaxFileSizeMB = 500,
    [int]$PollSeconds = 2,
    [string]$Branch = "main",
    [switch]$SkipAutoStart,
    [switch]$SkipStart,
    [string]$SourceRootOverride = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-DefaultInstallDir {
    if (Test-Path -LiteralPath "D:\") {
        return "D:\RecycleDeleteBackup"
    }

    return (Join-Path $env:LOCALAPPDATA "RecycleDeleteBackup")
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

function Get-SourceBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }

    return "https://raw.githubusercontent.com/Polestar666/yykj_backup_script/$BranchName"
}

function Get-SourceText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ($Base -match '^https?://') {
        $uri = ($Base.TrimEnd('/') + "/" + $RelativePath)
        return (Invoke-RestMethod -Uri $uri)
    }

    $localPath = Join-Path $Base $RelativePath
    return (Get-Content -LiteralPath $localPath -Raw)
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Build-MainScriptArgs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $true)]
        [int]$SizeLimitMB,

        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds,

        [string[]]$DriveLetters
    )

    $args = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath,
        $Action,
        "-BackupRoot", $BackupDirectory,
        "-MaxFileSizeMB", $SizeLimitMB.ToString(),
        "-PollSeconds", $IntervalSeconds.ToString()
    )

    if ($DriveLetters -and @($DriveLetters).Count -gt 0) {
        $args += "-DriveLetter"
        $args += ($DriveLetters -join ",")
    }

    return ,$args
}

function Invoke-MainScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $true)]
        [int]$SizeLimitMB,

        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds,

        [string[]]$DriveLetters
    )

    $args = Build-MainScriptArgs -Action $Action -ScriptPath $ScriptPath -BackupDirectory $BackupDirectory -SizeLimitMB $SizeLimitMB -IntervalSeconds $IntervalSeconds -DriveLetters $DriveLetters
    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "Action '$Action' failed with exit code $LASTEXITCODE."
    }
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Resolve-DefaultInstallDir
}

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $InstallDir "backup"
}

$sourceBase = Get-SourceBase -BranchName $Branch -Override $SourceRootOverride

Ensure-Directory -Path $InstallDir
Ensure-Directory -Path $BackupRoot

$mainScriptPath = Join-Path $InstallDir "RecycleDeleteBackup.ps1"
$readmePath = Join-Path $InstallDir "README.md"
$gitignorePath = Join-Path $InstallDir ".gitignore"

Write-Host "Downloading files..."
Write-Utf8File -Path $mainScriptPath -Content (Get-SourceText -Base $sourceBase -RelativePath "RecycleDeleteBackup.ps1")
Write-Utf8File -Path $readmePath -Content (Get-SourceText -Base $sourceBase -RelativePath "README.md")
Write-Utf8File -Path $gitignorePath -Content (Get-SourceText -Base $sourceBase -RelativePath ".gitignore")

try {
    Invoke-MainScript -Action "stop" -ScriptPath $mainScriptPath -BackupDirectory $BackupRoot -SizeLimitMB $MaxFileSizeMB -IntervalSeconds $PollSeconds -DriveLetters $DriveLetter | Out-Null
} catch {
}

if (-not $SkipAutoStart) {
    Write-Host "Installing auto-start..."
    Invoke-MainScript -Action "install-autostart" -ScriptPath $mainScriptPath -BackupDirectory $BackupRoot -SizeLimitMB $MaxFileSizeMB -IntervalSeconds $PollSeconds -DriveLetters $DriveLetter
}

if (-not $SkipStart) {
    Write-Host "Starting watcher..."
    try {
        Invoke-MainScript -Action "start" -ScriptPath $mainScriptPath -BackupDirectory $BackupRoot -SizeLimitMB $MaxFileSizeMB -IntervalSeconds $PollSeconds -DriveLetters $DriveLetter
    } catch {
        Write-Warning ("Install finished, but watcher did not start immediately: {0}" -f $_.Exception.Message)
        Write-Warning "If another instance is already running, stop it first and then start the new install manually."
    }
}

Write-Host ""
Write-Host "Install completed."
Write-Host ("Install directory: {0}" -f $InstallDir)
Write-Host ("Backup directory:  {0}" -f $BackupRoot)
Write-Host ("Main script:       {0}" -f $mainScriptPath)
Write-Host ""
Write-Host "Examples:"
Write-Host ('  powershell -ExecutionPolicy Bypass -File "{0}" status' -f $mainScriptPath)
Write-Host ('  powershell -ExecutionPolicy Bypass -File "{0}" stop' -f $mainScriptPath)
