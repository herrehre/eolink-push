<#
.SYNOPSIS
  Update eolink-push to the latest version from GitHub.
  Config (eolink.config.json) and specs are preserved (gitignored).
  Rules/commands are re-deployed to the parent project after update.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File eolink\update.ps1
#>
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path $scriptDir -Parent
$configPath = Join-Path $scriptDir 'eolink.config.json'

# PowerShell 5 compatible relative path ([System.IO.Path]::GetRelativePath requires PowerShell 6+/.NET Core)
function Get-RelativePathCompat {
    param([string]$BasePath, [string]$TargetPath)
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    if ($baseFull.TrimEnd('\') -ieq $targetFull.TrimEnd('\')) { return '.' }
    try {
        $baseUri = New-Object System.Uri($baseFull.TrimEnd('\') + '\')
        $targetUri = New-Object System.Uri($targetFull)
        $rel = $baseUri.MakeRelativeUri($targetUri).ToString()
        if ($rel -match ':') { return $targetFull } # cannot make relative (e.g. different drive)
        return [System.Uri]::UnescapeDataString($rel)
    } catch {
        return $targetFull
    }
}

Write-Host ''
Write-Host '== eolink-push update ==' -ForegroundColor Cyan
Write-Host ''

# --- read existing config ---
$cfg = $null
if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "Config loaded: $configPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "WARN: failed to read config: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARN: no config found at $configPath" -ForegroundColor Yellow
    Write-Host "  Run setup.ps1 first if you haven't configured yet." -ForegroundColor Yellow
}

# --- check git repo ---
$gitDir = Join-Path $repoRoot '.git'
if (-not (Test-Path -LiteralPath $gitDir)) {
    Write-Host "ERROR: $repoRoot is not a git repository." -ForegroundColor Red
    Write-Host "  If you downloaded via ZIP, delete this folder and re-clone:" -ForegroundColor Yellow
    Write-Host "  git clone https://github.com/herrehre/eolink-push.git" -ForegroundColor Yellow
    exit 1
}

# --- show current version ---
$oldHash = ''
try {
    $oldHash = & git -C $repoRoot rev-parse --short HEAD 2>$null
    if ($oldHash) { Write-Host "Current version: $oldHash" -ForegroundColor DarkGray }
} catch {}

# --- git pull ---
Write-Host ''
Write-Host 'Pulling latest from GitHub ...' -ForegroundColor Cyan
try {
    $pullOutput = & git -C $repoRoot pull origin main 2>&1
    $pullStr = "$pullOutput"
    Write-Host $pullStr -ForegroundColor DarkGray

    if ($pullStr -match 'Already up to date') {
        Write-Host ''
        Write-Host 'Already up to date, no changes.' -ForegroundColor Green
    } else {
        $newHash = & git -C $repoRoot rev-parse --short HEAD 2>$null
        Write-Host ''
        Write-Host "Updated: $oldHash -> $newHash" -ForegroundColor Green
    }
} catch {
    Write-Host "ERROR: git pull failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Try manually: cd $repoRoot ; git pull origin main" -ForegroundColor Yellow
    exit 1
}

# --- re-deploy rules/commands ---
$aiIde = if ($cfg -and $cfg.aiIde) { [string]$cfg.aiIde } else { 'trae' }
$projectDir = if ($cfg -and $cfg.projectDir) { [string]$cfg.projectDir } else { '' }
$targetDir = $null

if ($projectDir) {
    if ([System.IO.Path]::IsPathRooted($projectDir)) {
        $targetDir = $projectDir
    } else {
        $targetDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $projectDir))
    }
} else {
    # fallback: parent directory
    $parentDir = Split-Path $repoRoot -Parent
    if ($parentDir -and (Test-Path -LiteralPath (Join-Path $parentDir 'pom.xml') -ErrorAction SilentlyContinue)) {
        $targetDir = $parentDir
    }
}

$repoRootFull = [System.IO.Path]::GetFullPath($repoRoot)

if ($targetDir -and $targetDir -eq $repoRootFull) {
    Write-Host ''
    Write-Host "projectDir is the eolink-push repo itself, skip deploying." -ForegroundColor DarkGray
} elseif ($targetDir -and (Test-Path -LiteralPath $targetDir)) {
    Write-Host ''
    Write-Host "Re-deploying AI rules/commands to: $targetDir" -ForegroundColor Cyan

    $relRepo = (Get-RelativePathCompat -BasePath $targetDir -TargetPath $repoRootFull).Replace('\', '/')
    if ($relRepo -eq '.') { $relRepo = '' }

    if ($aiIde -eq 'trae' -or $aiIde -eq 'both') {
        $srcCmd = Join-Path $repoRoot '.trae\commands\api.md'
        $dstCmdDir = Join-Path $targetDir '.trae\commands'
        if (Test-Path -LiteralPath $srcCmd) {
            if (-not (Test-Path -LiteralPath $dstCmdDir)) { New-Item -ItemType Directory -Path $dstCmdDir -Force | Out-Null }
            $content = Get-Content -LiteralPath $srcCmd -Raw -Encoding UTF8
            if ($relRepo) { $content = $content -replace '(?<![\w/-])eolink/', "$relRepo/eolink/" }
            [System.IO.File]::WriteAllText((Join-Path $dstCmdDir 'api.md'), $content, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  [OK] .trae/commands/api.md" -ForegroundColor Green
        }
        $srcRule = Join-Path $repoRoot '.trae\rules\eolink-push.md'
        $dstRuleDir = Join-Path $targetDir '.trae\rules'
        if (Test-Path -LiteralPath $srcRule) {
            if (-not (Test-Path -LiteralPath $dstRuleDir)) { New-Item -ItemType Directory -Path $dstRuleDir -Force | Out-Null }
            $content = Get-Content -LiteralPath $srcRule -Raw -Encoding UTF8
            if ($relRepo) { $content = $content -replace '(?<![\w/-])eolink/', "$relRepo/eolink/" }
            [System.IO.File]::WriteAllText((Join-Path $dstRuleDir 'eolink-push.md'), $content, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  [OK] .trae/rules/eolink-push.md" -ForegroundColor Green
        }
    }
    if ($aiIde -eq 'codex' -or $aiIde -eq 'both') {
        $srcAgents = Join-Path $repoRoot 'AGENTS.md'
        if (Test-Path -LiteralPath $srcAgents) {
            $content = Get-Content -LiteralPath $srcAgents -Raw -Encoding UTF8
            if ($relRepo) { $content = $content -replace '(?<![\w/-])eolink/', "$relRepo/eolink/" }
            [System.IO.File]::WriteAllText((Join-Path $targetDir 'AGENTS.md'), $content, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  [OK] AGENTS.md" -ForegroundColor Green
        }
    }
} else {
    Write-Host ''
    Write-Host "WARN: cannot determine target project dir, skip deploying rules." -ForegroundColor Yellow
    Write-Host "  Run setup.ps1 to configure projectDir." -ForegroundColor Yellow
}

Write-Host ''
Write-Host '== update complete ==' -ForegroundColor Green
Write-Host ''
