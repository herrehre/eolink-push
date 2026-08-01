<#
.SYNOPSIS
  eolink-push CLI: validate / push / list APIs from an OpenAPI 3.0 JSON spec to Eolink Apikit.

.DESCRIPTION
  - validate : local structure check (summary + Chinese field descriptions required)
  - push     : idempotent sync (create/update/skip by method+path, auto-create groups)
  - list     : list projects/groups/APIs of the configured space/project

  stdout is pure JSON (machine readable); human logs go to stderr.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File eolink.ps1 validate -Spec specs/openapi.json
  powershell -NoProfile -ExecutionPolicy Bypass -File eolink.ps1 push -Spec specs/openapi.json -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File eolink.ps1 list
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('validate', 'push', 'list', 'project', 'help')]
    [string]$Command = 'help',

    [string]$Spec,
    [string]$Project,
    [string]$Group,
    [string]$Dir,
    [switch]$DryRun,
    [switch]$FullImport,
    [switch]$Clean,
    [string]$Config
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    [Console]::Error.WriteLine("[eolink] $Message")
}

function Exit-Json {
    param([int]$Code, [object]$Payload)
    $Payload | ConvertTo-Json -Compress -Depth 50 | Write-Output
    exit $Code
}

function Resolve-ScriptDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

function Get-Config {
    param([string]$ConfigPath)
    $scriptDir = Resolve-ScriptDir
    $candidate = if ($ConfigPath) { $ConfigPath } else { Join-Path $scriptDir 'eolink.config.json' }

    $cfg = @{
        baseUrl       = 'https://api.eolink.com'
        spaceId       = ''
        projectId     = ''
        eoSecretKey   = ''
        defaultGroup  = '默认分组'
        projectDir    = ''
        sqlCommentsPath = ''
        specPath      = 'specs/openapi.json'
    }

    if (Test-Path -LiteralPath $candidate) {
        try {
            $file = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                $v = $file.$k
                if ($null -ne $v -and "$v" -ne '') { $cfg[$k] = $v }
            }
        } catch {
            Write-Log "WARN: failed to parse config '$candidate': $($_.Exception.Message)"
        }
    }

    if ($env:EOLINK_BASE_URL)   { $cfg.baseUrl = $env:EOLINK_BASE_URL }
    if ($env:EOLINK_SPACE_ID)   { $cfg.spaceId = $env:EOLINK_SPACE_ID }
    if ($env:EOLINK_PROJECT_ID) { $cfg.projectId = $env:EOLINK_PROJECT_ID }
    if ($env:EOLINK_SECRET_KEY) { $cfg.eoSecretKey = $env:EOLINK_SECRET_KEY }

    return $cfg
}

function Invoke-Eolink {
    param(
        [hashtable]$Config,
        [string]$Path,
        [hashtable]$Body,
        [bool]$Write = $false,
        [string]$FormData = ''
    )
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    $base = ([string]$Config.baseUrl).TrimEnd('/')
    $prefix = if ($Write) { '/index.php' } else { '' }
    $url = $base + $prefix + '/' + $Path.TrimStart('/')
    $payload = if ($FormData -ne '') { $FormData } else { ($Body | ConvertTo-Json -Compress -Depth 50) }
    $contentType = if ($FormData -ne '') { 'application/x-www-form-urlencoded' } else { 'application/json' }

    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'POST'
    $req.ContentType = $contentType
    $req.Accept = 'application/json'
    $req.Timeout = 30000
    $req.AllowAutoRedirect = $false
    $req.Headers.Add('Eo-Secret-Key', [string]$Config.eoSecretKey)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }

    $code = [int]$resp.StatusCode
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()

    $obj = $null
    if ($text) {
        try { $obj = $text | ConvertFrom-Json } catch { $obj = $null }
    }
    return [pscustomobject]@{ StatusCode = $code; Body = $text; Data = $obj }
}

function Test-EolinkOk {
    param($Response)
    return ($Response.Data -and $Response.Data.status -eq 'success')
}

function Get-EolinkFailure {
    param($Response, [string]$Action)
    $body = $Response.Body
    if ($Response.StatusCode -eq 401 -or $Response.StatusCode -eq 403) {
        return "$Action failed (HTTP $($Response.StatusCode)): auth error, check eoSecretKey / permissions. body=$body"
    }
    if ($Response.StatusCode -eq 302) {
        return "$Action failed: gateway returned 302 with body=$body"
    }
    return "$Action failed (HTTP $($Response.StatusCode)): $body"
}

# ---------------------------------------------------------------------------
# Eolink Open API wrappers
# ---------------------------------------------------------------------------
function Get-EolinkProjects {
    param([hashtable]$Config)
    $r = Invoke-Eolink -Config $Config -Path 'v2/api_studio/management/project/search' -Body @{ space_id = $Config.spaceId }
    if (-not (Test-EolinkOk $r)) { throw (Get-EolinkFailure $r 'list projects') }
    return @($r.Data.result)
}

function Get-EolinkGroups {
    param([hashtable]$Config)
    $r = Invoke-Eolink -Config $Config -Path 'v2/api_studio/management/api/get_group_list' -Body @{
        space_id = $Config.spaceId; project_id = $Config.projectId
    }
    if (-not (Test-EolinkOk $r)) { throw (Get-EolinkFailure $r 'list groups') }
    $flat = @()
    function Flatten-Groups {
        param($Nodes)
        foreach ($g in @($Nodes)) {
            $flat += [pscustomobject]@{
                group_id = $g.group_id; group_name = $g.group_name; parent_group_id = $g.parent_group_id
            }
            if ($g.group_child_list) { Flatten-Groups -Nodes $g.group_child_list }
        }
    }
    Flatten-Groups -Nodes $r.Data.result
    return $flat
}

function Add-EolinkGroup {
    param([hashtable]$Config, [string]$GroupName, [int]$ParentGroupId = 0)
    $form = "space_id=$([uri]::EscapeDataString([string]$Config.spaceId))&project_id=$([uri]::EscapeDataString([string]$Config.projectId))&group_name=$([uri]::EscapeDataString($GroupName))&parent_group_id=$ParentGroupId"
    $r = Invoke-Eolink -Config $Config -Path 'v2/api_studio/management/api/add_group' -FormData $form
    if (-not (Test-EolinkOk $r)) { throw (Get-EolinkFailure $r "create group '$GroupName'") }
    $id = $null
    if ($r.Data.data) {
        if ($null -ne $r.Data.data.group_id) { $id = $r.Data.data.group_id }
        elseif ($null -ne $r.Data.data.groupID) { $id = $r.Data.data.groupID }
    }
    if ($null -eq $id) { $id = $r.Data.group_id }
    if ($null -eq $id) { $id = $r.Data.groupID }
    return $id
}

function Search-EolinkApis {
    param([hashtable]$Config)
    $r = Invoke-Eolink -Config $Config -Path 'v2/api_studio/management/api/search' -Body @{
        space_id = $Config.spaceId; project_id = $Config.projectId
    }
    if (-not (Test-EolinkOk $r)) { throw (Get-EolinkFailure $r 'search APIs') }
    return @($r.Data.result)
}

function Get-EolinkApiInfo {
    param([hashtable]$Config, $ApiId)
    $r = Invoke-Eolink -Config $Config -Path 'v2/api_studio/management/api/api_info' -Body @{
        space_id = $Config.spaceId; project_id = $Config.projectId; api_id = $ApiId
    }
    if (-not (Test-EolinkOk $r)) { throw (Get-EolinkFailure $r "get api_info $ApiId") }
    return $r.Data.api_info
}

function Save-EolinkApi {
    param([hashtable]$Config, [hashtable]$Body)
    $r = Invoke-Eolink -Config $Config -Path 'v2/api_studio/management/api/create_or_update_http_api' -Body $Body -Write $true
    if (-not (Test-EolinkOk $r)) { throw (Get-EolinkFailure $r "save API '$($Body.api_name)'") }
    $id = $null
    if ($r.Data.data) {
        if ($null -ne $r.Data.data.apiID) { $id = $r.Data.data.apiID }
        elseif ($null -ne $r.Data.data.api_id) { $id = $r.Data.data.api_id }
    }
    return $id
}

# ---------------------------------------------------------------------------
# spec -> operations
# ---------------------------------------------------------------------------
function Resolve-Schema {
    param($Spec, $Schema)
    $seen = @{}
    while ($Schema -and $Schema.'$ref') {
        $ref = [string]$Schema.'$ref'
        if ($seen.ContainsKey($ref)) { break }
        $seen[$ref] = $true
        if ($ref -like '#/components/schemas/*') {
            $name = $ref.Substring('#/components/schemas/'.Length)
            $Schema = $Spec.components.schemas.$name
        } elseif ($ref -like '#/definitions/*') {
            $name = $ref.Substring('#/definitions/'.Length)
            $Schema = $Spec.definitions.$name
        } else { break }
    }
    return $Schema
}

function Convert-ToEolinkType {
    param([string]$Type)
    switch -Regex ($Type.ToLower()) {
        'int|long|integer'           { return '3' }
        'float|double|decimal|number' { return '4' }
        'boolean|bool'               { return '8' }
        'file'                       { return '1' }
        'object|array'               { return '2' }
        'date$'                      { return '6' }
        'date-time|datetime'         { return '7' }
        default                      { return '0' }
    }
}

function Convert-SchemaFields {
    param($Spec, $Schema, [string[]]$RequiredNames)
    $fields = @()
    if (-not $Schema) { return $fields }
    $schema = Resolve-Schema -Spec $Spec -Schema $Schema
    if (-not $schema -or -not $schema.properties) { return $fields }
    $req = @()
    if ($RequiredNames) { $req = @($RequiredNames) }
    elseif ($schema.required) { $req = @($schema.required) }
    foreach ($p in $schema.properties.PSObject.Properties) {
        $fieldSchema = Resolve-Schema -Spec $Spec -Schema $p.Value
        $type = if ($fieldSchema.type) { [string]$fieldSchema.type } else { 'string' }
        $example = $null
        if ($fieldSchema.example -ne $null) { $example = "$($fieldSchema.example)" }
        elseif ($fieldSchema.default -ne $null) { $example = "$($fieldSchema.default)" }
        $fields += [pscustomobject]@{
            key      = $p.Name
            chinese  = if ($fieldSchema.description) { [string]$fieldSchema.description } else { '' }
            type     = $type
            required = ($req -contains $p.Name)
            example  = $example
        }
    }
    return $fields
}

function Convert-SpecToOperations {
    param($Spec, [hashtable]$Config)
    $ops = @()
    $paths = $Spec.paths
    if (-not $paths) { return $ops }
    foreach ($pathProp in $paths.PSObject.Properties) {
        $path = $pathProp.Name
        $pathItem = $pathProp.Value
        foreach ($m in @('get', 'post', 'put', 'delete', 'patch', 'head', 'options')) {
            $opItem = $pathItem.$m
            if ($null -eq $opItem) { continue }
            $summary = [string]$opItem.summary
            $desc = [string]$opItem.description
            if ([string]::IsNullOrWhiteSpace($summary)) { $summary = $desc }
            if ([string]::IsNullOrWhiteSpace($summary)) { $summary = "$($m.ToUpper()) $path" }
            $tags = if ($opItem.tags -and @($opItem.tags).Count -gt 0) { @($opItem.tags) } else { @([string]$Config.defaultGroup) }
            $tag = [string]$tags[0]
            if ([string]::IsNullOrWhiteSpace($tag)) { $tag = [string]$Config.defaultGroup }

            $query = @(); $rest = @()
            if ($opItem.parameters) {
                foreach ($pm in @($opItem.parameters)) {
                    $loc = [string]$pm.in
                    $fieldSchema = Resolve-Schema -Spec $Spec -Schema $pm.schema
                    $type = if ($fieldSchema.type) { [string]$fieldSchema.type } else { 'string' }
                    $chinese = if ($pm.description) { [string]$pm.description } else { '' }
                    $required = [bool]$pm.required
                    $item = [pscustomobject]@{
                        key = [string]$pm.name; chinese = $chinese; type = $type
                        required = $required; example = $pm.example
                    }
                    if ($loc -eq 'query') { $query += $item }
                    elseif ($loc -eq 'path') { $rest += $item }
                }
            }

            $requestFields = @()
            if ($opItem.requestBody) {
                $schema = $opItem.requestBody.content.'application/json'.schema
                if (-not $schema) { $schema = $opItem.requestBody.content.'application/x-www-form-urlencoded'.schema }
                if ($schema) {
                    $requestFields = Convert-SchemaFields -Spec $Spec -Schema $schema
                }
            }

            $responseFields = @()
            $responseMock = ''
            foreach ($code in @('200', '201', '202', '204', 'default')) {
                $resp = $opItem.responses.$code
                if (-not $resp) { continue }
                $schema = $resp.content.'application/json'.schema
                if ($schema) {
                    $responseFields = Convert-SchemaFields -Spec $Spec -Schema $schema
                }
                break
            }
            if ($responseFields.Count -gt 0) {
                $mockObj = [ordered]@{}
                foreach ($f in $responseFields) {
                    $mockObj[$f.key] = if ($f.example -ne $null) { $f.example } else { '' }
                }
                $responseMock = ($mockObj | ConvertTo-Json -Compress -Depth 10)
            }

            $ops += [pscustomobject]@{
                path       = ($path -replace '^/+', '' -replace '/+$', '')
                rawPath    = $path
                method     = $m.ToLower()
                summary    = $summary
                description = $desc
                tag        = $tag
                query      = $query
                rest       = $rest
                requestFields = $requestFields
                responseFields = $responseFields
                responseMock = $responseMock
            }
        }
    }
    return $ops
}

# ---------------------------------------------------------------------------
# eolink payload building / normalization
# ---------------------------------------------------------------------------
function New-EolinkParam {
    param($Field)
    $p = [ordered]@{ param_key = $Field.key }
    if ($Field.chinese) { $p.param_name = $Field.chinese }
    $p.param_type = Convert-ToEolinkType -Type $Field.type
    $p.param_not_null = if ($Field.required) { '1' } else { '0' }
    if ($null -ne $Field.example -and "$($Field.example)" -ne '') { $p.param_value = "$($Field.example)" }
    return $p
}

function New-EolinkApiBody {
    param($Op, $GroupId)
    $body = [ordered]@{
        api_name         = $Op.summary
        api_url          = $Op.path
        group_id         = $GroupId
        api_request_type = $Op.method
        api_protocol     = 'http'
        api_status       = 'enable'
    }
    $note = if ($Op.description -and $Op.description -ne $Op.summary) { $Op.description } else { $Op.summary }
    if ($note) { $body.api_note = $note }
    if (@($Op.query).Count -gt 0) {
        $body.api_url_param = @(@($Op.query) | ForEach-Object { New-EolinkParam -Field $_ })
    }
    if (@($Op.rest).Count -gt 0) {
        $body.api_restful_param = @(@($Op.rest) | ForEach-Object { New-EolinkParam -Field $_ })
    }
    if (@($Op.requestFields).Count -gt 0) {
        $body.api_request_param = @(@($Op.requestFields) | ForEach-Object { New-EolinkParam -Field $_ })
    }
    if ($Op.responseMock) { $body.api_success_mock = $Op.responseMock }
    return $body
}

function Normalize-EolinkParam {
    param($P)
    $r = [ordered]@{}
    $key = $null
    foreach ($cand in @('param_key', 'key', 'name')) { if ($P.PSObject.Properties[$cand] -and $null -ne $P.$cand) { $key = $P.$cand; break } }
    if ($null -eq $key) { return $null }
    $r.param_key = $key
    foreach ($cand in @('param_name', 'note', 'description')) {
        if ($P.PSObject.Properties[$cand] -and $null -ne $P.$cand -and "$($P.$cand)" -ne '') { $r.param_name = $P.$cand; break }
    }
    $type = $null
    foreach ($cand in @('param_type', 'type')) {
        if ($P.PSObject.Properties[$cand] -and $null -ne $P.$cand) { $type = [string]$P.$cand; break }
    }
    $r.param_type = if ($null -eq $type -or $type -eq '') { '0' } else { $type }
    $notNull = $null
    foreach ($cand in @('param_not_null', 'not_null', 'is_required')) {
        if ($P.PSObject.Properties[$cand] -and $null -ne $P.$cand) { $notNull = [string]$P.$cand; break }
    }
    if ($notNull -match '^(true|1)$') { $r.param_not_null = '1' } else { $r.param_not_null = '0' }
    foreach ($cand in @('param_value', 'value')) {
        if ($P.PSObject.Properties[$cand] -and $null -ne $P.$cand -and "$($P.$cand)" -ne '') { $r.param_value = $P.$cand; break }
    }
    foreach ($cand in @('param_note', 'remark')) {
        if ($P.PSObject.Properties[$cand] -and $null -ne $P.$cand -and "$($P.$cand)" -ne '') { $r.param_note = $P.$cand; break }
    }
    return $r
}

function Convert-ApiInfoToBody {
    param($Info)
    $base = $Info.base_info
    $body = [ordered]@{}
    if ($base.api_name) { $body.api_name = [string]$base.api_name }
    if ($base.api_url) { $body.api_url = ([string]$base.api_url -replace '^/+', '' -replace '/+$', '') }
    if ($null -ne $base.group_id) { $body.group_id = $base.group_id }
    if ($base.api_request_type) { $body.api_request_type = ([string]$base.api_request_type).ToLower() }
    if ($base.api_protocol) { $body.api_protocol = [string]$base.api_protocol }
    if ($base.api_status) { $body.api_status = [string]$base.api_status }
    if ($base.api_note) { $body.api_note = [string]$base.api_note }
    if ($base.api_success_mock) { $body.api_success_mock = $base.api_success_mock }
    if ($Info.url_param) {
        $arr = @()
        foreach ($p in @($Info.url_param)) { $n = Normalize-EolinkParam $p; if ($n) { $arr += $n } }
        if ($arr.Count) { $body.api_url_param = $arr }
    }
    if ($Info.restful_param) {
        $arr = @()
        foreach ($p in @($Info.restful_param)) { $n = Normalize-EolinkParam $p; if ($n) { $arr += $n } }
        if ($arr.Count) { $body.api_restful_param = $arr }
    }
    if ($Info.request_info) {
        $items = if ($Info.request_info -is [System.Collections.IEnumerable] -and $Info.request_info -isnot [string]) { @($Info.request_info) } else { @($Info.request_info) }
        $arr = @()
        foreach ($p in $items) { $n = Normalize-EolinkParam $p; if ($n) { $arr += $n } }
        if ($arr.Count) { $body.api_request_param = $arr }
    }
    return $body
}

function ConvertTo-Canonical {
    param($Value)
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject]) {
        $props = @{}
        foreach ($p in $Value.PSObject.Properties) {
            if ($null -ne $p.Value -and "$($p.Value)" -ne '') { $props[$p.Name] = $p.Value }
        }
        $ordered = [ordered]@{}
        foreach ($k in ($props.Keys | Sort-Object)) { $ordered[$k] = ConvertTo-Canonical -Value $props[$k] }
        return $ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-Canonical -Value $_ })
    }
    return $Value
}

function Get-CanonicalJson {
    param($Value)
    return (ConvertTo-Canonical -Value $Value | ConvertTo-Json -Compress -Depth 50)
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
function Invoke-Validate {
    param([hashtable]$Config, [string]$SpecPath)
    if ([string]::IsNullOrWhiteSpace($SpecPath)) {
        $SpecPath = Join-Path (Resolve-ScriptDir) ([string]$Config.specPath)
    }
    if (-not (Test-Path -LiteralPath $SpecPath)) {
        Exit-Json -Code 1 -Payload @{ ok = $false; command = 'validate'; error = "spec not found: $SpecPath" }
    }
    $spec = $null
    try { $spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Exit-Json -Code 1 -Payload @{ ok = $false; command = 'validate'; error = "invalid JSON: $($_.Exception.Message)" }
    }
    if (-not $spec.paths -or -not $spec.openapi) {
        Exit-Json -Code 1 -Payload @{ ok = $false; command = 'validate'; error = 'missing openapi/paths; only OpenAPI 3.0 JSON is supported' }
    }

    $ops = @(Convert-SpecToOperations -Spec $spec -Config $Config)
    $issues = @()
    foreach ($op in $ops) {
        $loc = "$($op.method.ToUpper()) /$($op.path)"
        if ([string]::IsNullOrWhiteSpace($op.summary)) { $issues += "$loc : missing summary" }
        foreach ($pm in @($op.query)) {
            if ([string]::IsNullOrWhiteSpace($pm.chinese)) { $issues += "$loc : query param '$($pm.key)' missing description (Chinese name)" }
        }
        foreach ($pm in @($op.rest)) {
            if ([string]::IsNullOrWhiteSpace($pm.chinese)) { $issues += "$loc : path param '$($pm.key)' missing description (Chinese name)" }
        }
        foreach ($f in @($op.requestFields)) {
            if ([string]::IsNullOrWhiteSpace($f.chinese)) { $issues += "$loc : request field '$($f.key)' missing description (Chinese name)" }
        }
        foreach ($f in @($op.responseFields)) {
            if ([string]::IsNullOrWhiteSpace($f.chinese)) { $issues += "$loc : response field '$($f.key)' missing description (Chinese name)" }
        }
    }
    Exit-Json -Code $(if ($issues.Count) { 1 } else { 0 }) -Payload @{
        ok = ($issues.Count -eq 0); command = 'validate'; spec = $SpecPath
        operationCount = $ops.Count; issueCount = $issues.Count; issues = $issues
    }
}

function Get-GroupId {
    param([hashtable]$Config, [System.Collections.ArrayList]$Groups, [string]$GroupName, [bool]$DryRun)
    $hit = $Groups | Where-Object { $_.group_name -eq $GroupName } | Select-Object -First 1
    if ($hit) { return $hit.group_id }
    if ($DryRun) { return -1 }
    Write-Log "creating group '$GroupName' ..."
    $id = Add-EolinkGroup -Config $Config -GroupName $GroupName
    if ($null -eq $id) {
        throw "create group '$GroupName' returned no group_id; please create it manually in Eolink"
    }
    $Groups.Add([pscustomobject]@{ group_id = $id; group_name = $GroupName; parent_group_id = 0 }) | Out-Null
    return $id
}

function Invoke-Push {
    param([hashtable]$Config, [string]$SpecPath, [string]$ProjectOverride, [bool]$DryRun, [bool]$FullImport, [bool]$Clean)
    if ($FullImport) {
        Exit-Json -Code 4 -Payload @{ ok = $false; command = 'push'; error = '-FullImport is not supported in v1 (Eolink import endpoint is not publicly documented)' }
    }
    if ($Clean) {
        Exit-Json -Code 4 -Payload @{ ok = $false; command = 'push'; error = '-Clean is not supported in v1 (Eolink delete endpoint is not publicly documented)' }
    }
    if ($ProjectOverride) { $Config.projectId = $ProjectOverride }
    if ([string]::IsNullOrWhiteSpace($Config.projectId)) {
        Exit-Json -Code 2 -Payload @{ ok = $false; command = 'push'; error = 'projectId is required; run setup.ps1 or pass -Project' }
    }
    if ([string]::IsNullOrWhiteSpace($Config.spaceId) -or [string]::IsNullOrWhiteSpace($Config.eoSecretKey)) {
        Exit-Json -Code 2 -Payload @{ ok = $false; command = 'push'; error = 'spaceId/eoSecretKey are required; run setup.ps1' }
    }
    if ([string]::IsNullOrWhiteSpace($SpecPath)) {
        $SpecPath = Join-Path (Resolve-ScriptDir) ([string]$Config.specPath)
    }
    if (-not (Test-Path -LiteralPath $SpecPath)) {
        Exit-Json -Code 1 -Payload @{ ok = $false; command = 'push'; error = "spec not found: $SpecPath" }
    }
    $spec = $null
    try { $spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Exit-Json -Code 1 -Payload @{ ok = $false; command = 'push'; error = "invalid JSON: $($_.Exception.Message)" }
    }
    if (-not $spec.paths) {
        Exit-Json -Code 1 -Payload @{ ok = $false; command = 'push'; error = 'spec has no paths' }
    }

    $ops = @(Convert-SpecToOperations -Spec $spec -Config $Config)
    if ($ops.Count -eq 0) {
        Exit-Json -Code 0 -Payload @{ ok = $true; command = 'push'; spec = $SpecPath; created = 0; updated = 0; skipped = 0; apis = @() }
    }

    Write-Log "loading project $($Config.projectId) groups/APIs ..."
    $groups = New-Object System.Collections.ArrayList
    try { $groups.AddRange(@(Get-EolinkGroups -Config $Config)) } catch {
        Exit-Json -Code 3 -Payload @{ ok = $false; command = 'push'; error = $_.Exception.Message }
    }
    $existing = @()
    try { $existing = Search-EolinkApis -Config $Config } catch {
        Exit-Json -Code 3 -Payload @{ ok = $false; command = 'push'; error = $_.Exception.Message }
    }
    $byKey = @{}
    foreach ($a in $existing) {
        $m = ([string]$a.method).ToLower().Trim()
        $p = ([string]$a.api_path -replace '^/+', '' -replace '/+$', '')
        $k = "$m|$p"
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = $a }
    }

    $results = @()
    $created = 0; $updated = 0; $skipped = 0
    $failed = @()
    foreach ($op in $ops) {
        $key = "$($op.method)|$($op.path)"
        $existingApi = $byKey[$key]
        $result = [ordered]@{ name = $op.summary; method = $op.method.ToUpper(); path = "/$($op.path)"; group = $op.tag; action = '' }
        try {
            $groupId = Get-GroupId -Config $Config -Groups $groups -GroupName $op.tag -DryRun $DryRun
            $body = New-EolinkApiBody -Op $op -GroupId $groupId
            if ($existingApi) {
                if ($DryRun) {
                    $result.action = 'would-update'; $updated++
                } else {
                    $info = Get-EolinkApiInfo -Config $Config -ApiId $existingApi.api_id
                    $oldBody = Convert-ApiInfoToBody -Info $info
                    if ((Get-CanonicalJson $oldBody) -eq (Get-CanonicalJson $body)) {
                        $result.action = 'skipped'; $skipped++
                    } else {
                        $b = @{}
                        foreach ($p in $body.PSObject.Properties) { $b[$p.Name] = $p.Value }
                        $b.api_id = [int]$existingApi.api_id
                        Save-EolinkApi -Config $Config -Body $b | Out-Null
                        $result.action = 'updated'; $updated++
                    }
                }
            } else {
                if ($DryRun) {
                    $result.action = 'would-create'; $created++
                } else {
                    Save-EolinkApi -Config $Config -Body $body | Out-Null
                    $result.action = 'created'; $created++
                }
            }
        } catch {
            $result.action = 'failed'
            $result.error = $_.Exception.Message
            $failed += $result
        }
        $results += $result
    }

    $code = if ($failed.Count) { 4 } else { 0 }
    Exit-Json -Code $code -Payload @{
        ok = ($failed.Count -eq 0); command = 'push'; spec = $SpecPath
        dryRun = $DryRun; created = $created; updated = $updated; skipped = $skipped
        failedCount = $failed.Count; apis = $results
    }
}

function Invoke-List {
    param([hashtable]$Config, [string]$ProjectOverride)
    if ([string]::IsNullOrWhiteSpace($Config.spaceId) -or [string]::IsNullOrWhiteSpace($Config.eoSecretKey)) {
        Exit-Json -Code 2 -Payload @{ ok = $false; command = 'list'; error = 'spaceId/eoSecretKey are required; run setup.ps1' }
    }
    if ($ProjectOverride) { $Config.projectId = $ProjectOverride }
    $out = @{ ok = $true; command = 'list'; projects = @(); groups = @(); apis = @() }
    try { $out.projects = Get-EolinkProjects -Config $Config } catch {
        Exit-Json -Code 3 -Payload @{ ok = $false; command = 'list'; error = $_.Exception.Message }
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.projectId)) {
        try {
            $out.groups = @(Get-EolinkGroups -Config $Config)
            $out.apis = @(Search-EolinkApis -Config $Config)
        } catch {
            Exit-Json -Code 3 -Payload @{ ok = $false; command = 'list'; error = $_.Exception.Message }
        }
    }
    Exit-Json -Code 0 -Payload $out
}

function Test-SpringBootProject {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    $hasPom = Test-Path -LiteralPath (Join-Path $Dir 'pom.xml')
    $hasGradle = (Test-Path -LiteralPath (Join-Path $Dir 'build.gradle')) -or (Test-Path -LiteralPath (Join-Path $Dir 'build.gradle.kts'))
    $hasJavaSrc = Test-Path -LiteralPath (Join-Path $Dir 'src\main\java')
    return (($hasPom -or $hasGradle) -and $hasJavaSrc)
}

function Invoke-Project {
    param([hashtable]$Config, [string]$DirOverride)
    $scriptDir = Resolve-ScriptDir
    $cwd = (Get-Location).Path
    $candidates = New-Object System.Collections.ArrayList
    if ($DirOverride) { $candidates.Add($DirOverride) | Out-Null }
    $candidates.Add($cwd) | Out-Null
    if ($Config.projectDir) {
        $p = [string]$Config.projectDir
        $repoRoot = Split-Path $scriptDir -Parent
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $repoRoot $p }
        $candidates.Add($p) | Out-Null
    }

    $resolved = $null
    foreach ($c in $candidates) {
        if (Test-SpringBootProject -Dir $c) { $resolved = $c; break }
    }
    if (-not $resolved) {
        Exit-Json -Code 2 -Payload @{
            ok = $false; command = 'project'
            error = 'no Spring Boot project found (checked: current workspace and config projectDir)'
            hint = 'run setup.ps1 to set projectDir, or open Codex in the project directory'
        }
    }
    Exit-Json -Code 0 -Payload @{ ok = $true; command = 'project'; projectDir = [System.IO.Path]::GetFullPath($resolved) }
}

function Show-Help {
    $text = @'
eolink-push CLI

USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File eolink.ps1 <command> [options]

COMMANDS
  validate [-Spec <path>]            check spec structure (summary + Chinese descriptions)
  push [-Spec <path>] [-Project <id>] [-DryRun] [-FullImport] [-Clean]
                                     idempotent sync of spec APIs to Eolink
  list [-Project <id>]               list projects / groups / APIs
  project [-Dir <path>]              resolve the Spring Boot project (current workspace first)
  help                               show this help

EXIT CODES
  0 success | 1 validation | 2 config/auth | 3 network | 4 partial/unsupported
'@
    $text | Write-Output
    exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if ($Command -eq 'help') { Show-Help }
$cfg = Get-Config -ConfigPath $Config
switch ($Command) {
    'validate' { Invoke-Validate -Config $cfg -SpecPath $Spec }
    'push'     { Invoke-Push -Config $cfg -SpecPath $Spec -ProjectOverride $Project -DryRun $DryRun -FullImport $FullImport -Clean $Clean }
    'list'     { Invoke-List -Config $cfg -ProjectOverride $Project }
    'project'  { Invoke-Project -Config $cfg -DirOverride $Dir }
    default    { Show-Help }
}
