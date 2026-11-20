<#
.SYNOPSIS
  www.samsung.com 요청만 아카마이 스테이징 IP로 보내 마이페이지 리다이렉트를 검사합니다.

.DESCRIPTION
  www.samsung.com 요청만 입력한 아카마이 스테이징 IP로 보내 마이페이지 리다이렉트를 검사합니다.
  시스템 호스트 파일은 수정하지 않습니다.

.EXAMPLE
  .\Test-AkamaiStaging.ps1 -SiteCode ae -Page myproducts

.EXAMPLE
  .\Test-AkamaiStaging.ps1

.EXAMPLE
  .\Test-AkamaiStaging.ps1 -OpenBrowser

.EXAMPLE
  .\Test-AkamaiStaging.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$SiteCodeFile,
    [string[]]$SiteCode,
    [string[]]$Page,
    [string]$PathContains,
    [switch]$DryRun,
    [switch]$SelfTest,
    [switch]$OpenBrowser,
    [switch]$ShowHosts,
    [switch]$OpenReport,
    [switch]$Insecure,
    [switch]$FailFast,
    [string]$Url,
    [string]$Browser,
    [int]$TimeoutSec = 0,
    [int]$DelayMs = 0
)

$ErrorActionPreference = 'Stop'

function Write-Utf8Bom {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    try {
        return $strict.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Resolve-InputPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $fromCwd = Join-Path (Get-Location) $Path
    if (Test-Path -LiteralPath $fromCwd) { return $fromCwd }
    return (Join-Path $PSScriptRoot $Path)
}

function Get-ConfigValue {
    param($Object, [string]$Name, $Default)
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Expand-Template {
    param([string]$Template, [string]$Code)
    $text = $Template.Replace('{sitecode}', $Code)
    return $text.Replace('{siteCode}', $Code)
}

function ConvertTo-LocationPattern {
    param([string]$Location, [string]$Code)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '' }
    $token = [regex]::Escape($Code)
    return [regex]::Replace($Location, "(?i)/$token(?=/|\?|#|$)", '/{sitecode}')
}

function ConvertTo-StatusList {
    param($Value)
    $items = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Value) {
        foreach ($item in @('301', '302', '303', '307', '308')) { $item }
        return
    }
    $parts = @()
    if ($Value -is [string]) {
        $parts = $Value.Split('|')
    } else {
        $parts = @($Value)
    }
    foreach ($part in $parts) {
        $token = ([string]$part).Trim()
        if ($token) { $token }
    }
}

function Test-ExpectsRedirect {
    param([string[]]$Expected)
    foreach ($item in $Expected) {
        if ($item -eq '3xx') { return $true }
        if ($item -match '^30[12378]$') { return $true }
    }
    return $false
}

function Test-StatusMatch {
    param([string]$Actual, [string[]]$Expected)
    foreach ($item in $Expected) {
        if ($item -eq '3xx' -and $Actual -match '^3\d\d$') { return $true }
        if ($item -eq $Actual) { return $true }
    }
    return $false
}

function Remove-TrailingSlash {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $query = ''
    $path = $Value
    $split = $Value.IndexOf('?')
    if ($split -ge 0) {
        $path = $Value.Substring(0, $split)
        $query = $Value.Substring($split)
    }
    return $path.TrimEnd('/') + $query
}

function Test-PrefixUrl {
    param([string]$Actual, [string]$Expected)
    $actualTrim = $Actual.Trim()
    $expectedTrim = $Expected.Trim().TrimEnd('/')
    if (-not $actualTrim.StartsWith($expectedTrim, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($actualTrim.Length -eq $expectedTrim.Length) { return $true }
    $next = $actualTrim[$expectedTrim.Length]
    return ($next -eq '/' -or $next -eq '?' -or $next -eq '#')
}

function Test-LocationMatch {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$Mode,
        [bool]$RequireAny
    )
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        if ($RequireAny) { return -not [string]::IsNullOrWhiteSpace($Actual) }
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Mode) -or $Mode -eq 'any') { $Mode = 'exact' }
    $actualTrim = $Actual.Trim()
    $expectedTrim = $Expected.Trim()
    switch ($Mode.ToLowerInvariant()) {
        'prefix' { return (Test-PrefixUrl $actualTrim $expectedTrim) }
        'contains' { return ($actualTrim.IndexOf($expectedTrim, [StringComparison]::OrdinalIgnoreCase) -ge 0) }
        'regex' { return ($actualTrim -match $expectedTrim) }
        default {
            $left = Remove-TrailingSlash $actualTrim
            $right = Remove-TrailingSlash $expectedTrim
            return $left.Equals($right, [StringComparison]::OrdinalIgnoreCase)
        }
    }
}

function Read-SiteCodes {
    param([string]$Path)
    $text = Read-TextFile $Path
    $seen = @{}
    foreach ($raw in ($text -split "\r?\n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        $token = ($line -split '\s+')[0]
        if ($token -notmatch '^[A-Za-z0-9_]+$') {
            Write-Warning ('국가 코드 형식이 아니라 건너뜁니다: {0}' -f $line)
            continue
        }
        $key = $token.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $token
    }
}

function Parse-ResponseHeaders {
    param([string]$Text)
    $status = 0
    $headers = @{}
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($raw in ($Text -split "\r?\n")) {
            $line = $raw.TrimEnd("`r")
            if ($line -match '^HTTP/\d(?:\.\d)?\s+(\d{3})\b') {
                $status = [int]$Matches[1]
                $headers = @{}
                continue
            }
            if ($line -match '^([^:\s]+)\s*:\s*(.*)$') {
                $name = $Matches[1].ToLowerInvariant()
                $value = $Matches[2].Trim()
                if ($headers.ContainsKey($name)) {
                    $current = $headers[$name]
                    if ($current -isnot [System.Array]) { $current = @($current) }
                    $headers[$name] = $current + $value
                } else {
                    $headers[$name] = $value
                }
            }
        }
    }
    return [pscustomobject]@{ Status = $status; Headers = $headers }
}

function Get-HeaderValue {
    param($Parsed, [string]$Name)
    $key = $Name.ToLowerInvariant()
    if (-not $Parsed.Headers.ContainsKey($key)) { return '' }
    $value = $Parsed.Headers[$key]
    if ($value -is [System.Array]) { return [string]$value[-1] }
    return [string]$value
}

function Resolve-RedirectUrl {
    param([string]$RequestUrl, [string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '' }
    $Location = $Location.Trim()
    if ($Location.StartsWith('//')) {
        $scheme = ([Uri]$RequestUrl).Scheme
        return ($scheme + ':' + $Location)
    }
    if ($Location -match '^(?i)https?://') { return $Location }
    try {
        $base = New-Object System.Uri $RequestUrl
        $absolute = New-Object System.Uri -ArgumentList @($base, $Location)
        return $absolute.AbsoluteUri
    } catch {
        return $Location
    }
}

function Format-ShortLocation {
    param([string]$Location, [string]$TargetHost)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '-' }
    try {
        $uri = [Uri]$Location
        if ($uri.Host.Equals($TargetHost, [StringComparison]::OrdinalIgnoreCase)) {
            return $uri.PathAndQuery
        }
        return $Location
    } catch {
        return $Location
    }
}

function ConvertTo-QuotedArg {
    param([string]$Argument)
    if ($null -eq $Argument) { $Argument = '' }
    $escaped = $Argument.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function ConvertTo-CommandLine {
    param([string[]]$Arguments)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        [void]$parts.Add((ConvertTo-QuotedArg $argument))
    }
    return ($parts -join ' ')
}

function Get-CurlExe {
    $systemCurl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $systemCurl) { return $systemCurl }
    $command = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [int]$WaitMs)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = ConvertTo-CommandLine $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($WaitMs)
    if (-not $finished) {
        try { $process.Kill() } catch {}
        try { [void]$process.WaitForExit(2000) } catch {}
        return [pscustomobject]@{ ExitCode = 28; Stdout = ''; Stderr = 'timeout' }
    }
    [void]$process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.Result
        Stderr = $stderrTask.Result
    }
}

function Read-CurlMeta {
    param([string]$Text)
    $meta = @{ Code = ''; Remote = ''; Ssl = ''; Time = '' }
    if ($Text -match 'HTTP_CODE:(\S*)') { $meta.Code = $Matches[1] }
    if ($Text -match 'REMOTE_IP:(\S*)') { $meta.Remote = $Matches[1] }
    if ($Text -match 'SSL:(\S*)') { $meta.Ssl = $Matches[1] }
    if ($Text -match 'TIME:([0-9.]+)') { $meta.Time = $Matches[1] }
    return $meta
}

function Get-CurlFailure {
    param([int]$ExitCode, [string]$Stderr)
    switch ($ExitCode) {
        6 { return '호스트를 찾지 못했습니다.' }
        7 { return '스테이징 IP에 연결하지 못했습니다. 외부망에서 실행 중인지 확인하세요.' }
        28 { return '시간 초과. 외부망에서 실행 중인지 확인하세요.' }
        35 { return 'TLS 연결에 실패했습니다.' }
        51 { return '인증서 이름이 요청한 도메인과 다릅니다.' }
        60 { return '인증서 검증에 실패했습니다.' }
        default {
            $detail = ($Stderr -replace '\s+', ' ').Trim()
            if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) }
            if ($detail) { return ('curl 종료 코드 {0}. {1}' -f $ExitCode, $detail) }
            return ('curl 종료 코드 {0}' -f $ExitCode)
        }
    }
}

function Read-BodyPreview {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }
    if ($bytes.Length -gt 65536) {
        $slice = New-Object byte[] 65536
        [Array]::Copy($bytes, $slice, 65536)
        $bytes = $slice
    }
    $encoding = New-Object System.Text.UTF8Encoding $false, $false
    return $encoding.GetString($bytes)
}

function Get-HtmlTitle {
    param([string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    $match = [regex]::Match($Html, '(?is)<title[^>]*>\s*(.*?)\s*</title>')
    if (-not $match.Success) { return '' }
    $title = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
    $title = ($title -replace '\s+', ' ').Trim()
    if ($title.Length -gt 180) { return $title.Substring(0, 180) }
    return $title
}

function Test-TcpPort {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect($Ip, $Port, $null, $null)
        $opened = $wait.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $opened) { return $false }
        $client.EndConnect($wait)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

function Get-SamsungHostsLines {
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hostsPath)) { return }
    $text = Read-TextFile $hostsPath
    foreach ($raw in ($text -split "\r?\n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($line -match '(?i)(^|\s)www\.samsung\.com($|\s)') { $line }
    }
}

function ConvertTo-CsvCell {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $quote = $Value.Contains('"') -or $Value.Contains(',') -or $Value.Contains("`n") -or $Value.Contains("`r")
    if (-not $quote) { return $Value }
    return '"' + $Value.Replace('"', '""') + '"'
}

function ConvertTo-HtmlEncoded {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-BrowserPath {
    param([string]$Choice)
    $chrome = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    $edge = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    $order = $chrome + $edge
    if ($Choice -eq 'edge') { $order = $edge }
    elseif ($Choice -eq 'chrome') { $order = $chrome }
    foreach ($path in $order) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

function Write-ResultFiles {
    param($Rows, $SummaryLines, [string]$OutDir, [string]$TargetHost, [string]$StagingIp)
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvName = 'staging-{0}.csv' -f $stamp
    $htmlName = 'staging-{0}.html' -f $stamp
    $txtName = 'staging-{0}.txt' -f $stamp
    $csvPath = Join-Path $OutDir $csvName
    $htmlPath = Join-Path $OutDir $htmlName
    $txtPath = Join-Path $OutDir $txtName

    $csv = New-Object System.Text.StringBuilder
    [void]$csv.AppendLine('result,sitecode,path,status,location,location_pattern,staging,remote_ip,x_cache,request_id,time_ms,title,reason,url')
    foreach ($row in $Rows) {
        $resultText = 'FAIL'
        if ($row.Pass) { $resultText = 'PASS' }
        $cells = @(
            $resultText, $row.Sitecode, $row.Path, $row.Status, $row.Location, $row.LocationPattern,
            $row.Staging, $row.RemoteIp, $row.Cache, $row.RequestId, $row.TimeMs, $row.Title, $row.Reason, $row.Url
        )
        $encoded = @()
        foreach ($cell in $cells) { $encoded += (ConvertTo-CsvCell ([string]$cell)) }
        [void]$csv.AppendLine(($encoded -join ','))
    }
    Write-Utf8Bom $csvPath $csv.ToString()

    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="ko"><head><meta charset="utf-8">')
    [void]$html.AppendLine('<title>아카마이 스테이징 리다이렉트 검사</title>')
    [void]$html.AppendLine('<style>')
    [void]$html.AppendLine('body{margin:0;font-family:"Segoe UI","Malgun Gothic",sans-serif;color:#142033;background:#f4f6f8}')
    [void]$html.AppendLine('header{background:#1428a0;color:#fff;padding:20px 28px}')
    [void]$html.AppendLine('header p{margin:6px 0 0;opacity:.9}')
    [void]$html.AppendLine('main{padding:20px 28px 40px}')
    [void]$html.AppendLine('table{border-collapse:collapse;width:100%;background:#fff}')
    [void]$html.AppendLine('th,td{border-bottom:1px solid #e4e8ee;padding:8px 10px;text-align:left;vertical-align:top;font-size:13px}')
    [void]$html.AppendLine('th{background:#eef2f7;position:sticky;top:0}')
    [void]$html.AppendLine('td{word-break:break-all}')
    [void]$html.AppendLine('tr.fail td{background:#fdecec}')
    [void]$html.AppendLine('tr.pass td{background:#f3fbf6}')
    [void]$html.AppendLine('.toolbar{display:flex;gap:16px;align-items:center;margin:0 0 16px}')
    [void]$html.AppendLine('input[type=search]{padding:8px 10px;width:360px;border:1px solid #c9d2df;border-radius:4px}')
    [void]$html.AppendLine('</style></head><body>')
    [void]$html.AppendLine('<header><h1>아카마이 스테이징 리다이렉트 검사</h1>')
    foreach ($line in $SummaryLines) {
        [void]$html.AppendLine('<p>' + (ConvertTo-HtmlEncoded $line) + '</p>')
    }
    [void]$html.AppendLine('</header><main>')
    [void]$html.AppendLine('<div class="toolbar"><input id="q" type="search" placeholder="국가코드, 경로, 목적지 검색" oninput="applyFilter()">')
    [void]$html.AppendLine('<label><input id="failOnly" type="checkbox" onchange="applyFilter()"> 실패만</label></div>')
    [void]$html.AppendLine('<table><thead><tr><th>결과</th><th>코드</th><th>경로</th><th>상태</th><th>Location</th><th>스테이징</th><th>IP</th><th>ms</th><th>이유</th></tr></thead><tbody id="rows">')
    foreach ($row in $Rows) {
        $className = 'fail'
        $resultText = 'FAIL'
        $passFlag = '0'
        if ($row.Pass) {
            $className = 'pass'
            $resultText = 'PASS'
            $passFlag = '1'
        }
        [void]$html.AppendLine(('<tr class="{0}" data-pass="{1}">' -f $className, $passFlag))
        $values = @($resultText, $row.Sitecode, $row.Path, $row.Status, $row.Location, $row.Staging, $row.RemoteIp, $row.TimeMs, $row.Reason)
        foreach ($value in $values) {
            [void]$html.AppendLine('<td>' + (ConvertTo-HtmlEncoded ([string]$value)) + '</td>')
        }
        [void]$html.AppendLine('</tr>')
    }
    [void]$html.AppendLine('</tbody></table>')
    [void]$html.AppendLine('<script>')
    [void]$html.AppendLine('function applyFilter(){var q=document.getElementById("q").value.toLowerCase();var failOnly=document.getElementById("failOnly").checked;var rows=document.querySelectorAll("#rows tr");for(var i=0;i<rows.length;i++){var show=rows[i].innerText.toLowerCase().indexOf(q)!==-1;if(failOnly&&rows[i].getAttribute("data-pass")!=="0"){show=false;}rows[i].style.display=show?"":"none";}}')
    [void]$html.AppendLine('</script></main></body></html>')
    Write-Utf8Bom $htmlPath $html.ToString()
    Write-Utf8Bom $txtPath (($SummaryLines -join "`r`n") + "`r`n")
    Copy-Item -LiteralPath $csvPath -Destination (Join-Path $OutDir 'latest.csv') -Force
    Copy-Item -LiteralPath $htmlPath -Destination (Join-Path $OutDir 'latest.html') -Force
    Copy-Item -LiteralPath $txtPath -Destination (Join-Path $OutDir 'latest.txt') -Force
    return [pscustomobject]@{ Csv = $csvPath; Html = $htmlPath; Text = $txtPath }
}

function Assert-That {
    param([string]$Name, $Condition)
    if (-not $Condition) { throw ('SelfTest 실패: {0}' -f $Name) }
}

function Invoke-SelfTest {
    $expanded = Expand-Template 'https://www.samsung.com/{sitecode}/mypage/myproducts/' 'ae'
    Assert-That 'expand' ($expanded -eq 'https://www.samsung.com/ae/mypage/myproducts/')

    $statuses = @(ConvertTo-StatusList '301|302|308')
    Assert-That 'status count' ($statuses.Count -eq 3)
    Assert-That 'status hit' (Test-StatusMatch '302' $statuses)
    Assert-That 'status miss' (-not (Test-StatusMatch '200' $statuses))
    Assert-That 'redirect expected' (Test-ExpectsRedirect $statuses)
    Assert-That '200 is not redirect' (-not (Test-ExpectsRedirect @('200')))

    Assert-That 'any location' (Test-LocationMatch 'https://example/a' '' 'any' $true)
    Assert-That 'missing location' (-not (Test-LocationMatch '' '' 'any' $true))
    Assert-That 'slash exact' (Test-LocationMatch 'https://www.samsung.com/ae/parking/' 'https://www.samsung.com/ae/parking' 'exact' $true)
    Assert-That 'prefix boundary' (-not (Test-PrefixUrl 'https://www.samsung.com/ae/parking-lot/' 'https://www.samsung.com/ae/parking'))
    Assert-That 'prefix ok' (Test-PrefixUrl 'https://www.samsung.com/ae/parking/?x=1' 'https://www.samsung.com/ae/parking/')

    $folded = ConvertTo-LocationPattern 'https://www.samsung.com/ae/parking/?a=1' 'ae'
    Assert-That 'fold ae' ($folded -eq 'https://www.samsung.com/{sitecode}/parking/?a=1')
    $untouched = ConvertTo-LocationPattern 'https://www.samsung.com/ae_ar/parking/' 'ae'
    Assert-That 'fold ae_ar' ($untouched -eq 'https://www.samsung.com/ae_ar/parking/')

    $sample = "HTTP/1.1 100 Continue`r`n`r`nHTTP/1.1 302 Found`r`nLocation: /ae/mypage/`r`nX-Akamai-Staging: ESSL`r`n"
    $parsed = Parse-ResponseHeaders $sample
    Assert-That 'header status' ($parsed.Status -eq 302)
    Assert-That 'header location' ((Get-HeaderValue $parsed 'Location') -eq '/ae/mypage/')
    Assert-That 'header staging' ((Get-HeaderValue $parsed 'X-Akamai-Staging') -eq 'ESSL')
    $absolute = Resolve-RedirectUrl 'https://www.samsung.com/ae/mypage/myproducts/' '/ae/parking/'
    Assert-That 'relative location' ($absolute -eq 'https://www.samsung.com/ae/parking/')

    $tempCodes = Join-Path ([System.IO.Path]::GetTempPath()) ('codes-' + [guid]::NewGuid().ToString('n') + '.txt')
    Write-Utf8Bom $tempCodes "# comment`r`nae`r`n`r`nae`r`nnot-a-code`r`nae_ar`r`n"
    $codes = @(Read-SiteCodes $tempCodes)
    Remove-Item -LiteralPath $tempCodes -Force
    Assert-That 'sitecode count' ($codes.Count -eq 2)
    Assert-That 'sitecode ae' ($codes[0] -eq 'ae' -and $codes[1] -eq 'ae_ar')
}

function Get-RunConfig {
    $configPath = $Config
    if (-not $configPath) { $configPath = Join-Path $PSScriptRoot 'config.json' }
    else { $configPath = Resolve-InputPath $configPath }
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host ('설정 파일이 없습니다: {0}' -f $configPath)
        return $null
    }
    try {
        $config = (Read-TextFile $configPath) | ConvertFrom-Json
    } catch {
        Write-Host ('config.json 을 읽지 못했습니다: {0}' -f $_.Exception.Message)
        return $null
    }
    $targetHost = ([string](Get-ConfigValue $config 'host' '')).Trim()
    $stagingIp = ([string](Get-ConfigValue $config 'stagingIp' '')).Trim()
    if ($targetHost -notmatch '^[A-Za-z0-9.-]+$') {
        Write-Host 'config.json 의 host 를 확인하세요.'
        return $null
    }
    $ipOk = $stagingIp -match '^(?:\d{1,3}\.){3}\d{1,3}$'
    if ($ipOk) {
        foreach ($octet in $stagingIp.Split('.')) {
            $number = 0
            if (-not [int]::TryParse($octet, [ref]$number) -or $number -lt 0 -or $number -gt 255) { $ipOk = $false }
        }
    }
    if (-not $ipOk) {
        Write-Host 'config.json 의 stagingIp 를 확인하세요.'
        return $null
    }
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @($config.patterns)) {
        $text = ([string]$pattern).Trim()
        if (-not $text) { continue }
        if ($text -notmatch '^https://') {
            Write-Host ('패턴은 https:// 로 시작해야 합니다: {0}' -f $text)
            return $null
        }
        if ($text.IndexOf('{sitecode}') -lt 0 -and $text.IndexOf('{siteCode}') -lt 0) {
            Write-Host ('패턴에 {sitecode} 가 없습니다: {0}' -f $text)
            return $null
        }
        [void]$patterns.Add($text)
    }
    if ($patterns.Count -eq 0) {
        Write-Host 'config.json 에 patterns 가 없습니다.'
        return $null
    }
    $codePath = $SiteCodeFile
    if (-not $codePath) { $codePath = [string](Get-ConfigValue $config 'siteCodeFile' 'sitecodes.txt') }
    $codePath = Resolve-InputPath $codePath
    if (-not (Test-Path -LiteralPath $codePath)) {
        Write-Host ('국가 코드 파일이 없습니다: {0}' -f $codePath)
        return $null
    }
    $timeout = 20
    $configuredTimeout = Get-ConfigValue $config 'timeoutSec' 20
    if ($configuredTimeout -match '^\d+$') { $timeout = [int]$configuredTimeout }
    if ($TimeoutSec -gt 0) { $timeout = $TimeoutSec }
    if ($timeout -lt 5) { $timeout = 5 }
    $statuses = @(ConvertTo-StatusList (Get-ConfigValue $config 'expectedStatuses' '301|302|303|307|308'))
    $userAgent = [string](Get-ConfigValue $config 'userAgent' 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
    $pragma = [string](Get-ConfigValue $config 'pragma' 'akamai-x-cache-on, akamai-x-cache-remote-on, akamai-x-check-cacheable, akamai-x-get-request-id')
    $requireStaging = $true
    if ($config.PSObject.Properties['requireStagingHeader']) {
        $requireStaging = [bool]$config.requireStagingHeader
    }
    return [pscustomobject]@{
        TargetHost = $targetHost
        StagingIp = $stagingIp
        Patterns = @($patterns)
        SiteCodePath = $codePath
        TimeoutSec = $timeout
        ExpectedStatuses = $statuses
        ExpectedLocation = [string](Get-ConfigValue $config 'expectedLocation' '')
        LocationMatch = [string](Get-ConfigValue $config 'locationMatch' 'any')
        UserAgent = $userAgent
        Pragma = $pragma
        RequireStagingHeader = $requireStaging
    }
}

function Get-SelectedCodes {
    param([string]$Path)
    $codes = @(Read-SiteCodes $Path)
    $filters = New-Object System.Collections.Generic.List[string]
    foreach ($item in $SiteCode) {
        foreach ($part in ([string]$item).Split(',')) {
            $token = $part.Trim()
            if ($token) { [void]$filters.Add($token) }
        }
    }
    if ($filters.Count -eq 0) { return $codes }
    $want = @{}
    foreach ($filter in $filters) { $want[$filter.ToLowerInvariant()] = $true }
    $selected = @($codes | Where-Object { $want.ContainsKey($_.ToLowerInvariant()) })
    $missing = @()
    foreach ($filter in $filters) {
        $found = $false
        foreach ($code in $selected) {
            if ($code.ToLowerInvariant() -eq $filter.ToLowerInvariant()) { $found = $true }
        }
        if (-not $found) { $missing += $filter }
    }
    if ($missing.Count -gt 0) {
        Write-Host ('sitecodes.txt 에 없는 코드: {0}' -f ($missing -join ', '))
    }
    return $selected
}

function Resolve-PagePaths {
    param([string[]]$Names)
    $map = @{
        'mypage' = '/mypage/'
        'myproducts' = '/mypage/myproducts/'
        'myrepair' = '/mypage/myrepair/'
        'track-repair' = '/mypage/myrepair/track-repair/'
        'trackrepair' = '/mypage/myrepair/track-repair/'
        'getsupport' = '/mypage/getsupport/'
    }
    $seen = @{}
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        foreach ($part in ([string]$name).Split(',')) {
            $token = $part.Trim().ToLowerInvariant()
            if (-not $token) { continue }
            if (-not $map.ContainsKey($token)) {
                [void]$bad.Add($token)
                continue
            }
            $seen[$map[$token]] = $true
        }
    }
    if ($bad.Count -gt 0) {
        Write-Host ('페이지 이름이 아닙니다: {0}' -f (($bad | Select-Object -Unique) -join ', '))
        Write-Host '사용 가능: mypage, myproducts, myrepair, track-repair, getsupport'
        return
    }
    foreach ($path in $seen.Keys) { $path }
}

function Expand-Cases {
    param($Codes, [string[]]$Patterns, [string]$TargetHost)
    foreach ($code in $Codes) {
        foreach ($pattern in $Patterns) {
            $url = Expand-Template $pattern $code
            if ($PathContains -and $url.IndexOf($PathContains, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $uri = [Uri]$url
            $short = $uri.AbsolutePath
            $prefix = '/' + $code
            if ($short.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $short = $short.Substring($prefix.Length)
                if ([string]::IsNullOrEmpty($short)) { $short = '/' }
            }
            if ($script:SelectedPages) {
                $keep = $false
                foreach ($pagePath in $script:SelectedPages) {
                    if ($short -eq $pagePath) { $keep = $true }
                }
                if (-not $keep) { continue }
            }
            [pscustomobject]@{
                Sitecode = $code
                Url = $url
                Path = $short
                Port = $uri.Port
            }
        }
    }
}

function Invoke-Probe {
    param(
        $Case,
        $Settings,
        [string]$CurlExe,
        [string]$WorkDir
    )
    $headerFile = Join-Path $WorkDir 'headers.txt'
    $bodyFile = Join-Path $WorkDir 'body.bin'
    $arguments = New-Object System.Collections.Generic.List[string]
    [void]$arguments.Add('-q')
    if ($Insecure) { [void]$arguments.Add('--insecure') }
    foreach ($argument in @(
            '--noproxy', '*', '-sS', '--ipv4', '--http1.1',
            '--max-redirs', '0', '--connect-timeout', '10', '--max-time', ([string]$Settings.TimeoutSec),
            '--resolve', ('{0}:{1}:{2}' -f $Settings.TargetHost, $Case.Port, $Settings.StagingIp),
            '-D', $headerFile, '-o', $bodyFile, '-A', $Settings.UserAgent,
            '-H', ('Pragma: {0}' -f $Settings.Pragma),
            '-H', 'Cache-Control: no-cache',
            '-H', 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            '-w', 'HTTP_CODE:%{http_code} REMOTE_IP:%{remote_ip} SSL:%{ssl_verify_result} TIME:%{time_total}',
            '--url', $Case.Url
        )) {
        [void]$arguments.Add($argument)
    }
    $curl = Invoke-Native -FilePath $CurlExe -Arguments @($arguments) -WaitMs (($Settings.TimeoutSec + 15) * 1000)
    $meta = Read-CurlMeta $curl.Stdout
    $status = 0
    if ($meta.Code -match '^\d{3}$') { $status = [int]$meta.Code }
    $location = ''
    $stagingHeader = ''
    $cache = ''
    $requestId = ''
    $title = ''
    $headerStatus = 0
    if (Test-Path -LiteralPath $headerFile) {
        $headerText = Read-TextFile $headerFile
        $parsed = Parse-ResponseHeaders $headerText
        $headerStatus = [int]$parsed.Status
        $location = Resolve-RedirectUrl $Case.Url (Get-HeaderValue $parsed 'Location')
        $stagingHeader = Get-HeaderValue $parsed 'X-Akamai-Staging'
        $cache = Get-HeaderValue $parsed 'X-Cache'
        $cacheRemote = Get-HeaderValue $parsed 'X-Cache-Remote'
        if ($cacheRemote) {
            if ($cache) { $cache = $cache + ' | ' + $cacheRemote } else { $cache = $cacheRemote }
        }
        $requestId = Get-HeaderValue $parsed 'X-Akamai-Request-ID'
        if (-not $requestId) { $requestId = Get-HeaderValue $parsed 'Akamai-GRN' }
    }
    if ($headerStatus -gt 0) { $status = $headerStatus }
    $timeMs = 0
    if ($meta.Time) { $timeMs = [int]([double]$meta.Time * 1000) }
    $transport = ''
    if ($curl.ExitCode -ne 0 -or $status -eq 0) {
        $transport = Get-CurlFailure $curl.ExitCode $curl.Stderr
        if ($status -eq 0 -and $curl.ExitCode -eq 0) { $transport = '응답이 없습니다.' }
    } elseif (Test-Path -LiteralPath $bodyFile) {
        $title = Get-HtmlTitle (Read-BodyPreview $bodyFile)
    }
    $reasons = New-Object System.Collections.Generic.List[string]
    $pass = $true
    if ($transport) {
        $pass = $false
        [void]$reasons.Add($transport)
    } else {
        if (-not (Test-StatusMatch ([string]$status) $Settings.ExpectedStatuses)) {
            $pass = $false
            [void]$reasons.Add(('상태코드 {0} (기대 {1})' -f $status, ($Settings.ExpectedStatuses -join '|')))
        }
        $expectedLocation = Expand-Template $Settings.ExpectedLocation $Case.Sitecode
        $requireLocation = (Test-ExpectsRedirect $Settings.ExpectedStatuses) -or -not [string]::IsNullOrWhiteSpace($Settings.ExpectedLocation)
        if (-not (Test-LocationMatch $location $expectedLocation $Settings.LocationMatch $requireLocation)) {
            $pass = $false
            if ([string]::IsNullOrWhiteSpace($location)) {
                [void]$reasons.Add('Location 없음')
            } else {
                [void]$reasons.Add(('Location 불일치: {0}' -f $location))
            }
        }
        if ($Settings.RequireStagingHeader -and [string]::IsNullOrWhiteSpace($stagingHeader)) {
            $pass = $false
            if ($meta.Remote -eq $Settings.StagingIp) {
                [void]$reasons.Add('X-Akamai-Staging 헤더가 없습니다. 접속 IP는 스테이징 IP와 같습니다. 헤더를 빼는 설정이면 config.json 의 requireStagingHeader 를 false 로 두세요.')
            } else {
                [void]$reasons.Add(('X-Akamai-Staging 헤더가 없고 접속 IP가 {0} 입니다. 운영망일 수 있습니다.' -f $meta.Remote))
            }
        }
    }
    $statusText = 'ERR'
    if ($status -gt 0) { $statusText = [string]$status }
    return [pscustomobject]@{
        Sitecode = $Case.Sitecode
        Path = $Case.Path
        Url = $Case.Url
        Pass = $pass
        Status = $statusText
        Location = $location
        LocationPattern = (ConvertTo-LocationPattern $location $Case.Sitecode)
        Staging = $stagingHeader
        RemoteIp = $meta.Remote
        Cache = $cache
        RequestId = $requestId
        Title = $title
        TimeMs = $timeMs
        Reason = ($reasons -join '; ')
    }
}

function Invoke-Main {
    if ($SelfTest) {
        Invoke-SelfTest
        Write-Host 'SelfTest PASS'
        return 0
    }

    $settings = Get-RunConfig
    if (-not $settings) { return 2 }

    if ($ShowHosts) {
        Write-Host '시스템 호스트 파일은 수정하지 않았습니다.'
        Write-Host '수동 확인이 꼭 호스트 파일이어야 할 때만 아래 한 줄을 넣고, 끝나면 지우세요.'
        Write-Host ('{0} {1}' -f $settings.StagingIp, $settings.TargetHost)
        Write-Host '같은 확인을 호스트 파일 없이 하려면: .\Test-AkamaiStaging.ps1 -OpenBrowser'
        return 0
    }

    if ($OpenBrowser) {
        $browserPath = Get-BrowserPath $Browser
        if (-not $browserPath) {
            Write-Host 'Chrome 또는 Edge 를 찾지 못했습니다.'
            return 2
        }
        $openUrl = $Url
        if (-not $openUrl) { $openUrl = ('https://{0}/ae/mypage/myproducts/' -f $settings.TargetHost) }
        $profileDir = Join-Path ([System.IO.Path]::GetTempPath()) 'akamai-staging-browser'
        if (-not (Test-Path -LiteralPath $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir | Out-Null
        }
        $rules = 'MAP {0} {1}' -f $settings.TargetHost, $settings.StagingIp
        $argumentLine = '--user-data-dir="{0}" --host-resolver-rules="{1}" --disable-features=DnsOverHttps --no-first-run --no-default-browser-check --new-window "{2}"' -f $profileDir, $rules, $openUrl
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $browserPath
        $info.Arguments = $argumentLine
        $info.UseShellExecute = $false
        [void][System.Diagnostics.Process]::Start($info)
        Write-Host ('브라우저만 {0} -> {1} 로 엽니다. 평소 쓰던 창은 그대로입니다.' -f $settings.TargetHost, $settings.StagingIp)
        Write-Host $openUrl
        return 0
    }

    $codes = @(Get-SelectedCodes $settings.SiteCodePath)
    if ($codes.Count -eq 0) {
        Write-Host '검사할 국가 코드가 없습니다.'
        return 2
    }
    $script:SelectedPages = @()
    if ($Page) {
        $script:SelectedPages = @(Resolve-PagePaths -Names $Page)
        if ($script:SelectedPages.Count -eq 0) { return 2 }
    }
    $cases = @(Expand-Cases $codes $settings.Patterns $settings.TargetHost)
    if ($cases.Count -eq 0) {
        Write-Host '조건에 맞는 URL이 없습니다.'
        return 2
    }

    Write-Host ('스테이징 매핑: {0} -> {1}' -f $settings.TargetHost, $settings.StagingIp)
    Write-Host '호스트 파일은 변경하지 않습니다. 요청마다 이 IP로 연결합니다.'
    Write-Host ('요청 {0}건 (국가 코드 {1}개, 패턴 {2}개)' -f $cases.Count, $codes.Count, $settings.Patterns.Count)
    if ($codes.Count -gt 1 -and -not $SiteCode) {
        Write-Host '전체를 돌기 전에 샘플: .\Test-AkamaiStaging.ps1 -SiteCode ae -Page myproducts'
    }

    $outDir = Join-Path $PSScriptRoot 'results'
    if ($DryRun) {
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
        $urlLines = @()
        foreach ($case in $cases) { $urlLines += $case.Url }
        $urlFile = Join-Path $outDir 'urls.txt'
        Write-Utf8Bom $urlFile (($urlLines -join "`r`n") + "`r`n")
        Write-Host '연결은 하지 않았습니다.'
        Write-Host $urlFile
        return 0
    }

    $curlExe = Get-CurlExe
    if (-not $curlExe) {
        Write-Host 'curl.exe 를 찾지 못했습니다. Windows 10 이상에 포함된 curl 이 필요합니다.'
        return 2
    }
    if ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:http_proxy -or $env:https_proxy) {
        Write-Host '프록시 환경변수가 있습니다. 이 테스트는 프록시를 타지 않고 스테이징 IP로 직접 연결합니다.'
    }
    $hostHits = @(Get-SamsungHostsLines)
    if ($hostHits.Count -gt 0) {
        Write-Host '이 PC의 hosts 파일에 www.samsung.com 이 이미 있습니다.'
        foreach ($hit in $hostHits) { Write-Host ('  ' + $hit) }
        Write-Host '목록 검사는 --resolve 로 IP를 지정하므로 그대로 진행합니다. 일반 브라우저로 운영망을 보려면 테스트 후 그 줄을 지우세요.'
    }

    Write-Host ('{0}:443 연결 확인 중...' -f $settings.StagingIp)
    if (-not (Test-TcpPort $settings.StagingIp 443 5000)) {
        Write-Host ('{0}:443 에 연결하지 못했습니다.' -f $settings.StagingIp)
        Write-Host '내부망에서는 아카마이 스테이징에 접속되지 않는 경우가 많습니다.'
        Write-Host '이 폴더를 외부망 PC로 옮겨 같은 명령을 실행하세요. 호스트 파일은 바꿀 필요 없습니다.'
        return 2
    }
    Write-Host '연결 확인됨. 요청을 시작합니다.'

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('akamai-staging-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $index = 0
        foreach ($case in $cases) {
            $index++
            $row = Invoke-Probe -Case $case -Settings $settings -CurlExe $curlExe -WorkDir $work
            [void]$rows.Add($row)
            $mark = 'FAIL'
            $color = 'Red'
            if ($row.Pass) { $mark = 'OK'; $color = 'Green' }
            $destination = Format-ShortLocation $row.Location $settings.TargetHost
            $progressLine = '[{0} {1}/{2}] {3} {4} {5} -> {6}' -f $mark, $index, $cases.Count, $row.Status, $row.Sitecode, $row.Path, $destination
            Write-Host $progressLine -ForegroundColor $color
            if ($env:AKAMAI_UI_LOG) {
                [System.IO.File]::AppendAllText($env:AKAMAI_UI_LOG, $progressLine + "`n", (New-Object System.Text.UTF8Encoding $false))
            }
            if ($FailFast -and -not $row.Pass) { break }
            if ($DelayMs -gt 0 -and $index -lt $cases.Count) { Start-Sleep -Milliseconds $DelayMs }
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $passCount = @($rows | Where-Object { $_.Pass }).Count
    $failCount = $rows.Count - $passCount
    $groups = @{}
    foreach ($row in $rows) {
        $key = $row.LocationPattern
        if ([string]::IsNullOrWhiteSpace($key)) { $key = '(Location 없음)' }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = 0 }
        $groups[$key] = $groups[$key] + 1
    }
    $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $summary = New-Object System.Collections.Generic.List[string]
    [void]$summary.Add(('시각: {0}    PC: {1}' -f $when, $env:COMPUTERNAME))
    [void]$summary.Add(('매핑: {0} -> {1}    호스트 파일은 변경하지 않음' -f $settings.TargetHost, $settings.StagingIp))
    [void]$summary.Add(('결과: 총 {0}  성공 {1}  실패 {2}' -f $rows.Count, $passCount, $failCount))
    [void]$summary.Add('리다이렉트 목적지:')
    $sorted = $groups.GetEnumerator() | Sort-Object -Property Value -Descending
    foreach ($group in $sorted) {
        [void]$summary.Add(('  {0,5}  {1}' -f $group.Value, $group.Key))
    }
    $failRows = @($rows | Where-Object { -not $_.Pass })
    if ($failRows.Count -gt 0) {
        [void]$summary.Add('실패:')
        $shown = 0
        foreach ($row in $failRows) {
            $shown++
            if ($shown -gt 40) {
                [void]$summary.Add(('  ... 외 {0}건은 HTML 리포트를 보세요.' -f ($failRows.Count - 40)))
                break
            }
            [void]$summary.Add(('  {0} {1}  status={2}  {3}' -f $row.Sitecode, $row.Path, $row.Status, $row.Reason))
        }
    }
    $connectionFails = @($failRows | Where-Object { $_.Reason -match '연결하지 못했습니다|시간 초과' })
    if ($rows.Count -gt 0 -and $connectionFails.Count -eq $rows.Count) {
        [void]$summary.Insert(3, '모든 요청이 연결에 실패했습니다. 내부망에서는 스테이징 IP에 붙지 않습니다.')
    }

    Write-Host ''
    Write-Host '--------'
    foreach ($line in $summary) { Write-Host $line }

    $written = Write-ResultFiles -Rows $rows -SummaryLines $summary -OutDir $outDir -TargetHost $settings.TargetHost -StagingIp $settings.StagingIp
    Write-Host ''
    Write-Host ('CSV  ' + $written.Csv)
    Write-Host ('HTML ' + $written.Html)
    if ($OpenReport) {
        try { [void][System.Diagnostics.Process]::Start($written.Html) } catch {
            Write-Host 'HTML 리포트를 자동으로 열지 못했습니다. 위 경로를 직접 여세요.'
        }
    }
    if ($failCount -gt 0) { return 1 }
    return 0
}

try {
    $exitCode = Invoke-Main
} catch {
    Write-Host ('오류: {0}' -f $_.Exception.Message)
    $exitCode = 2
}
if ($exitCode -is [System.Array]) { $exitCode = $exitCode[-1] }
$exitCode = [int]$exitCode
$commandArgs = [Environment]::GetCommandLineArgs()
$fileMode = $false
foreach ($commandArg in $commandArgs) {
    if ($commandArg -eq '-File' -or $commandArg -eq '-f') { $fileMode = $true }
}
if ($fileMode) { exit $exitCode }
$global:LASTEXITCODE = $exitCode
