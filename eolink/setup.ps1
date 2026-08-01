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

$input = Read-Host "Eolink base URL (default: $($cfg.baseUrl))"
if ($input) { $cfg.baseUrl = $input.Trim() }

$input = Read-Host "spaceId (workspace domain identifier; empty keeps '$($cfg.spaceId)')"
if ($input) { $cfg.spaceId = $input.Trim() }

$input = Read-Host "eoSecretKey (Eolink 空间设置 -> 开放 API -> Open API 令牌)"
if ($input) { $cfg.eoSecretKey = $input.Trim() }

# connectivity + project selection
if (-not $cfg.baseUrl -or -not $cfg.spaceId -or -not $cfg.eoSecretKey) {
    Write-Host 'ERROR: baseUrl/spaceId/eoSecretKey are required.' -ForegroundColor Red
    exit 2
}

Write-Host ''
Write-Host 'Testing connection and loading projects ...' -ForegroundColor Cyan
$projects = @()
try {
    $r = Invoke-EolinkSetupRequest -BaseUrl $cfg.baseUrl -SecretKey $cfg.eoSecretKey -Path 'v2/api_studio/management/project/search' -Body @{ space_id = $cfg.spaceId }
    if (-not $r.Data -or $r.Data.status -ne 'success') {
        Write-Host "ERROR: connection failed (HTTP $($r.StatusCode)): $($r.Body)" -ForegroundColor Red
        Write-Host 'Hints: baseUrl should be like https://api.eolink.com (SaaS); spaceId is the workspace domain identifier; eoSecretKey is the Open API token.' -ForegroundColor Yellow
        exit 2
    }
    $projects = @($r.Data.result)
} catch {
    Write-Host "ERROR: cannot reach Eolink: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}

Write-Host "Found $($projects.Count) project(s)."
$currentProject = $cfg.projectId
for ($i = 0; $i -lt $projects.Count; $i++) {
    $marker = if ("$($projects[$i].project_id)" -eq "$currentProject") { ' *' } else { '' }
    Write-Host ("  [{0}] {1}  (id: {2}){3}" -f ($i + 1), $projects[$i].project_name, $projects[$i].project_id, $marker)
}
if ($projects.Count -eq 0) {
    Write-Host 'No project found. Create one in Eolink first.' -ForegroundColor Yellow
    $input = Read-Host 'projectId (manual)'
    if ($input) { $cfg.projectId = $input.Trim() }
} else {
    $input = Read-Host "Select project number, or paste projectId (keep '$currentProject' by pressing Enter)"
    if ($input) {
        $n = 0
        if ([int]::TryParse($input, [ref]$n) -and $n -ge 1 -and $n -le $projects.Count) {
            $cfg.projectId = "$($projects[$n - 1].project_id)"
        } else {
            $cfg.projectId = $input.Trim()
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

$input = Read-Host "projectDir (path to your Spring Boot project, default: '$($cfg.projectDir)')"
if ($input) { $cfg.projectDir = $input.Trim() }

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
}

try {
    $json = ($out | ConvertTo-Json -Depth 5)
    Set-Content -LiteralPath $configPath -Value $json -Encoding UTF8
    Write-Host ''
    Write-Host "Saved: $configPath" -ForegroundColor Green
    Write-Host 'Next: open this repository in Codex and type:  /api <接口描述>' -ForegroundColor Cyan
    Write-Host 'Or push manually:  powershell -NoProfile -ExecutionPolicy Bypass -File eolink\eolink.ps1 list'
    exit 0
} catch {
    Write-Host "ERROR: cannot write config: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
