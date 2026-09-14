[CmdletBinding()]
param(
    [switch]$SkipFrontendInstall,
    [switch]$SkipFrontendBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BuildDirectory = $PSScriptRoot
$ProjectDirectory = Split-Path -Parent $BuildDirectory
$FrontendDirectory = Join-Path $ProjectDirectory 'frontend'
$OutputFile = Join-Path $BuildDirectory 'codex2api'
$BuildOutputFile = Join-Path $BuildDirectory 'codex2api.build.exe'

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Command '$Name' was not found. Install it and add it to PATH."
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Write-Host ''
    Write-Host ('> ' + $Command + ' ' + ($Arguments -join ' ')) -ForegroundColor Cyan
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code: $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

try {
    Assert-Command 'go'
    if (-not $SkipFrontendBuild) {
        Assert-Command 'npm'
    }

    if (-not (Test-Path (Join-Path $ProjectDirectory 'go.mod'))) {
        throw "go.mod was not found in project directory: $ProjectDirectory"
    }

    if (-not (Test-Path (Join-Path $FrontendDirectory 'package.json'))) {
        throw "package.json was not found in frontend directory: $FrontendDirectory"
    }

    if (-not $SkipFrontendInstall) {
        if (-not (Test-Path (Join-Path $FrontendDirectory 'package-lock.json'))) {
            throw 'frontend/package-lock.json was not found. npm ci requires this lock file.'
        }
        Invoke-Step 'npm' @('ci', '--no-audit', '--no-fund') $FrontendDirectory
    }

    if (-not $SkipFrontendBuild) {
        Invoke-Step 'npm' @('run', 'build') $FrontendDirectory
    }

    $FrontendDist = Join-Path $FrontendDirectory 'dist'
    if (-not (Test-Path $FrontendDist)) {
        throw "Frontend build directory was not found: $FrontendDist"
    }

    $Commit = 'unknown'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $GitCommit = (& git -C $ProjectDirectory rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $GitCommit) { $Commit = $GitCommit.Trim() }
    }

    $PreviousGoOs = $env:GOOS
    $PreviousGoArch = $env:GOARCH
    $PreviousCgoEnabled = $env:CGO_ENABLED
    try {
        $env:GOOS = 'linux'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'

        # Remove the previous artifact so a failed build cannot leave a stale file.
        if (Test-Path $OutputFile) {
            Remove-Item -LiteralPath $OutputFile -Force
        }
        if (Test-Path $BuildOutputFile) {
            Remove-Item -LiteralPath $BuildOutputFile -Force
        }

        Invoke-Step 'go' @(
            'build',
            '-trimpath',
            '-o',
            $BuildOutputFile,
            '.'
        ) $ProjectDirectory

        if (-not (Test-Path $BuildOutputFile)) {
            throw "Go build completed but temporary output file was not found: $BuildOutputFile"
        }

        # Go on Windows is more reliable when its output path has an .exe suffix.
        # Rename it afterwards so the Linux server receives the expected name.
        Move-Item -LiteralPath $BuildOutputFile -Destination $OutputFile -Force
    }
    finally {
        $env:GOOS = $PreviousGoOs
        $env:GOARCH = $PreviousGoArch
        $env:CGO_ENABLED = $PreviousCgoEnabled
    }

    if (-not (Test-Path $OutputFile)) {
        throw "Build completed but output file was not found: $OutputFile"
    }

    $FileInfo = Get-Item $OutputFile
    Write-Host ''
    Write-Host 'Build completed.' -ForegroundColor Green
    Write-Host "File: $($FileInfo.FullName)"
    Write-Host "Size: $([math]::Round($FileInfo.Length / 1MB, 2)) MB"
    Write-Host 'Target: Linux amd64'
    Write-Host "Commit: $Commit"
    Write-Host ('Upload example: scp "' + $FileInfo.FullName + '" user@server:/srv/codex2api-build/codex2api')
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
