<#
.SYNOPSIS
  Interactive setup for eolink-push: generate eolink.config.json and test connectivity.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$configPath = Join-Path $scriptDir 'eolink.config.json'

$cfg = @{
    baseUrl        = 'https://api.eolink.com'
    spaceId        = ''
    projectId      = ''
    eoSecretKey    = ''
    defaultGroup   = '默认分组'
    projectDir     = ''
    sqlCommentsPath = ''
    specPath       = 'specs/openapi.json'
    aiIde          = 'trae'
}

if (Test-Path -LiteralPath $configPath) {
    try {
        $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            $v = $existing.$k
            if ($null -ne $v -and "$v" -ne '') { $cfg[$k] = $v }
        }
        Write-Host "Loaded existing config: $configPath"
    } catch {
        Write-Host "WARN: cannot parse existing config: $($_.Exception.Message)"
    }
}

function Invoke-EolinkSetupRequest {
    param([string]$BaseUrl, [string]$SecretKey, [string]$Path, [hashtable]$Body)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }
    $base = $BaseUrl.TrimEnd('/')
    $url = $base + '/' + $Path.TrimStart('/')
    $payload = ($Body | ConvertTo-Json -Compress -Depth 20)
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Accept = 'application/json'
    $req.Timeout = 30000
    $req.AllowAutoRedirect = $false
    $req.Headers.Add('Eo-Secret-Key', $SecretKey)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }
    $code = [int]$resp.StatusCode
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    $obj = $null
    if ($text) { try { $obj = $text | ConvertFrom-Json } catch { } }
    return [pscustomobject]@{ StatusCode = $code; Body = $text; Data = $obj }
}

Write-Host ''
Write-Host '== eolink-push setup ==' -ForegroundColor Cyan
Write-Host 'Credentials are stored locally in eolink.config.json (git-ignored).' -ForegroundColor DarkGray
Write-Host ''

# --- 从项目 URL 解析 spaceId / projectId ---
Write-Host 'Paste your Eolink project URL, e.g.:' -ForegroundColor DarkGray
Write-Host '  https://xxx.w.eolink.com/home/api-studio/inside/.../api/12345/list?spaceKey=xxx' -ForegroundColor DarkGray
$input = Read-Host "Project URL (or press Enter to keep current: spaceId='$($cfg.spaceId)' projectId='$($cfg.projectId)')"
if ($input) {
    $url = $input.Trim()
    # 解析 spaceId: 优先从 spaceKey 参数取，其次从域名前缀取
    $parsedSpace = ''
    if ($url -match '[?&]spaceKey=([^&]+)') {
        $parsedSpace = $Matches[1]
    } elseif ($url -match 'https?://([^.]+)\.w\.eolink\.com') {
        $parsedSpace = $Matches[1]
    }
    # 解析 projectId: 从路径中 /api/数字/ 取
    $parsedProject = ''
    if ($url -match '/api/(\d+)') {
        $parsedProject = $Matches[1]
    }
    if ($parsedSpace) {
        $cfg.spaceId = $parsedSpace
        Write-Host "  spaceId  = $parsedSpace" -ForegroundColor Green
    } else {
        Write-Host "  WARN: cannot parse spaceId from URL, please input manually." -ForegroundColor Yellow
        $input2 = Read-Host "  spaceId"
        if ($input2) { $cfg.spaceId = $input2.Trim() }
    }
    if ($parsedProject) {
        $cfg.projectId = $parsedProject
        Write-Host "  projectId = $parsedProject" -ForegroundColor Green
    } else {
        Write-Host "  WARN: cannot parse projectId from URL, will select after connection test." -ForegroundColor Yellow
    }
}

# baseUrl 固定为 SaaS 地址
$cfg.baseUrl = 'https://api.eolink.com'

$input = Read-Host "eoSecretKey (Eolink 空间设置 -> 开放 API -> Open API 令牌)"
if ($input) { $cfg.eoSecretKey = $input.Trim() }

# connectivity check
if (-not $cfg.spaceId -or -not $cfg.eoSecretKey) {
    Write-Host 'ERROR: spaceId/eoSecretKey are required.' -ForegroundColor Red
    exit 2
}

Write-Host ''
Write-Host 'Testing connection ...' -ForegroundColor Cyan
$projects = @()
try {
    $r = Invoke-EolinkSetupRequest -BaseUrl $cfg.baseUrl -SecretKey $cfg.eoSecretKey -Path 'v2/api_studio/management/project/search' -Body @{ space_id = $cfg.spaceId }
    if (-not $r.Data -or $r.Data.status -ne 'success') {
        Write-Host "ERROR: connection failed (HTTP $($r.StatusCode)): $($r.Body)" -ForegroundColor Red
        Write-Host 'Hints: check eoSecretKey and spaceId. baseUrl is fixed to https://api.eolink.com (SaaS).' -ForegroundColor Yellow
        exit 2
    }
    $projects = @($r.Data.result)
} catch {
    Write-Host "ERROR: cannot reach Eolink: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}

# 如果 URL 中已解析到 projectId，验证其存在性
if ($cfg.projectId) {
    $found = $projects | Where-Object { "$($_.project_id)" -eq "$($cfg.projectId)" } | Select-Object -First 1
    if ($found) {
        Write-Host "Project confirmed: $($found.project_name) (id: $($cfg.projectId))" -ForegroundColor Green
    } else {
        Write-Host "WARN: projectId '$($cfg.projectId)' not found in space, please select:" -ForegroundColor Yellow
        $cfg.projectId = ''
    }
}

# 如果没有 projectId（URL 未解析到或验证失败），列出项目供选择
if (-not $cfg.projectId) {
    Write-Host "Found $($projects.Count) project(s)."
    for ($i = 0; $i -lt $projects.Count; $i++) {
        Write-Host ("  [{0}] {1}  (id: {2})" -f ($i + 1), $projects[$i].project_name, $projects[$i].project_id)
    }
    if ($projects.Count -eq 0) {
        Write-Host 'No project found. Create one in Eolink first.' -ForegroundColor Yellow
        $input = Read-Host 'projectId (manual)'
        if ($input) { $cfg.projectId = $input.Trim() }
    } else {
        $input = Read-Host 'Select project number or paste projectId'
        if ($input) {
            $n = 0
            if ([int]::TryParse($input, [ref]$n) -and $n -ge 1 -and $n -le $projects.Count) {
                $cfg.projectId = "$($projects[$n - 1].project_id)"
            } else {
                $cfg.projectId = $input.Trim()
            }
        }
    }
}

if ($cfg.projectId) {
    try {
        $r = Invoke-EolinkSetupRequest -BaseUrl $cfg.baseUrl -SecretKey $cfg.eoSecretKey -Path 'v2/api_studio/management/api/get_group_list' -Body @{ space_id = $cfg.spaceId; project_id = $cfg.projectId }
        if ($r.Data -and $r.Data.status -eq 'success') {
            $groupCount = @($r.Data.result).Count
            Write-Host "Project access OK ($groupCount top-level group(s))." -ForegroundColor Green
        } else {
            Write-Host "WARN: cannot load groups (HTTP $($r.StatusCode)): $($r.Body)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "WARN: cannot load groups: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$input = Read-Host "defaultGroup (default: $($cfg.defaultGroup))"
if ($input) { $cfg.defaultGroup = $input.Trim() }

Write-Host ''
Write-Host 'Which AI IDE are you using?' -ForegroundColor Cyan
Write-Host '  [1] Trae (Recommended)'
Write-Host '  [2] Codex'
Write-Host '  [3] Both'
$input = Read-Host "Select (default: 1)"
$aiIde = 'trae'
if ($input -eq '2') { $aiIde = 'codex' }
elseif ($input -eq '3') { $aiIde = 'both' }
$cfg.aiIde = $aiIde

$repoRoot = Split-Path $scriptDir -Parent
# 验证 eolink-push 仓库内的源文件（这些是部署的源，不是目标）
if ($aiIde -eq 'trae' -or $aiIde -eq 'both') {
    $traeRule = Join-Path $repoRoot '.trae\rules\eolink-push.md'
    $traeCmd  = Join-Path $repoRoot '.trae\commands\api.md'
    if ((Test-Path -LiteralPath $traeRule) -and (Test-Path -LiteralPath $traeCmd)) {
        Write-Host "Trae source files OK (will deploy to your project later)." -ForegroundColor Green
    } else {
        Write-Host "WARN: Trae source files incomplete in $repoRoot" -ForegroundColor Yellow
    }
}
if ($aiIde -eq 'codex' -or $aiIde -eq 'both') {
    $agentsMd = Join-Path $repoRoot 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsMd) {
        Write-Host "Codex source file OK (will deploy to your project later)." -ForegroundColor Green
    } else {
        Write-Host "WARN: AGENTS.md not found in $repoRoot" -ForegroundColor Yellow
    }
}

# projectDir 固定为 eolink-push 的父目录
$parentDir = Split-Path $repoRoot -Parent
if ($parentDir) {
    $cfg.projectDir = $parentDir
    $hasPom = Test-Path -LiteralPath (Join-Path $parentDir 'pom.xml')
    $hasGradle = (Test-Path -LiteralPath (Join-Path $parentDir 'build.gradle')) -or (Test-Path -LiteralPath (Join-Path $parentDir 'build.gradle.kts'))
    if ($hasPom -or $hasGradle) {
        Write-Host "projectDir = $parentDir (Spring Boot project detected)" -ForegroundColor Green
    } else {
        Write-Host "projectDir = $parentDir (WARN: no pom.xml/build.gradle found, /api may not work)" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARN: cannot determine parent directory, projectDir left empty." -ForegroundColor Yellow
}

$input = Read-Host "sqlCommentsPath (optional SQL file for column comments fallback, default: '$($cfg.sqlCommentsPath)')"
if ($input) { $cfg.sqlCommentsPath = $input.Trim() }

$out = [ordered]@{
    baseUrl        = $cfg.baseUrl
    spaceId        = $cfg.spaceId
    projectId      = $cfg.projectId
    eoSecretKey    = $cfg.eoSecretKey
    defaultGroup   = $cfg.defaultGroup
    projectDir     = $cfg.projectDir
    sqlCommentsPath = $cfg.sqlCommentsPath
    specPath       = $cfg.specPath
    aiIde          = $cfg.aiIde
}

try {
    $json = ($out | ConvertTo-Json -Depth 5)
    Set-Content -LiteralPath $configPath -Value $json -Encoding UTF8
    Write-Host ''
    Write-Host "Saved: $configPath" -ForegroundColor Green

    # --- 自动部署规则/命令到用户项目 ---
    $targetDir = $cfg.projectDir
    if ($targetDir) { $targetDir = [System.IO.Path]::GetFullPath($targetDir) }
    $repoRootFull = [System.IO.Path]::GetFullPath($repoRoot)

    if ($targetDir -and $targetDir -eq $repoRootFull) {
        Write-Host ''
        Write-Host "WARN: projectDir is the eolink-push repo itself, skip deploying (rules already here)." -ForegroundColor Yellow
        Write-Host "  Set projectDir to your Spring Boot project root to enable auto-deploy." -ForegroundColor Yellow
    } elseif ($targetDir -and (Test-Path -LiteralPath $targetDir)) {
        Write-Host ''
        Write-Host "Deploying AI rules/commands to: $targetDir" -ForegroundColor Cyan

        if ($aiIde -eq 'trae' -or $aiIde -eq 'both') {
            # 复制斜杠命令
            $srcCmd = Join-Path $repoRoot '.trae\commands\api.md'
            $dstCmdDir = Join-Path $targetDir '.trae\commands'
            if (Test-Path -LiteralPath $srcCmd) {
                if (-not (Test-Path -LiteralPath $dstCmdDir)) { New-Item -ItemType Directory -Path $dstCmdDir -Force | Out-Null }
                Copy-Item -LiteralPath $srcCmd -Destination (Join-Path $dstCmdDir 'api.md') -Force
                Write-Host "  [OK] .trae/commands/api.md" -ForegroundColor Green
            }
            # 复制项目规则
            $srcRule = Join-Path $repoRoot '.trae\rules\eolink-push.md'
            $dstRuleDir = Join-Path $targetDir '.trae\rules'
            if (Test-Path -LiteralPath $srcRule) {
                if (-not (Test-Path -LiteralPath $dstRuleDir)) { New-Item -ItemType Directory -Path $dstRuleDir -Force | Out-Null }
                Copy-Item -LiteralPath $srcRule -Destination (Join-Path $dstRuleDir 'eolink-push.md') -Force
                Write-Host "  [OK] .trae/rules/eolink-push.md" -ForegroundColor Green
            }
        }
        if ($aiIde -eq 'codex' -or $aiIde -eq 'both') {
            $srcAgents = Join-Path $repoRoot 'AGENTS.md'
            if (Test-Path -LiteralPath $srcAgents) {
                Copy-Item -LiteralPath $srcAgents -Destination (Join-Path $targetDir 'AGENTS.md') -Force
                Write-Host "  [OK] AGENTS.md" -ForegroundColor Green
            }
        }
    } elseif ($targetDir) {
        Write-Host "WARN: projectDir '$targetDir' does not exist, skip deploying rules." -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host "WARN: projectDir is empty, skip deploying rules." -ForegroundColor Yellow
        Write-Host "  Set projectDir in config and re-run setup to deploy /api command to your project." -ForegroundColor Yellow
    }

    Write-Host ''
    if ($cfg.aiIde -eq 'trae' -or $cfg.aiIde -eq 'both') {
        Write-Host 'Next: open your project in Trae and type:  /api <接口描述>' -ForegroundColor Cyan
    }
    if ($cfg.aiIde -eq 'codex' -or $cfg.aiIde -eq 'both') {
        Write-Host 'Next: open your project in Codex and type:  /api <接口描述>' -ForegroundColor Cyan
    }
    Write-Host 'Or push manually:  powershell -NoProfile -ExecutionPolicy Bypass -File eolink\eolink.ps1 list'
    exit 0
} catch {
    Write-Host "ERROR: cannot write config: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
