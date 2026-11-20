# 브라우저에서 국가/페이지를 고르고 스테이징 검사를 돌립니다.
# 이 창을 닫으면 페이지도 같이 종료됩니다.
$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Akamai staging test' } catch {}

$root = $PSScriptRoot
$testScript = Join-Path $root 'Test-AkamaiStaging.ps1'
$siteFile = Join-Path $root 'sitecodes.txt'
$allowedPages = @('mypage', 'myproducts', 'myrepair', 'track-repair', 'getsupport')

function Read-SiteCodes {
    $codes = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $siteFile)) { return @() }
    foreach ($raw in [System.IO.File]::ReadAllLines($siteFile)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        $token = ($line -split '\s+')[0]
        if ($token -match '^[A-Za-z0-9_]+$') { [void]$codes.Add($token) }
    }
    return @($codes)
}

function ConvertTo-QuotedArg([string]$Argument) {
    if ($null -eq $Argument) { $Argument = '' }
    return '"' + ($Argument.Replace('\', '\\').Replace('"', '\"')) + '"'
}

function Write-Bytes($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.Close()
}

function Write-Text($Context, [int]$Status, [string]$ContentType, [string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Write-Bytes $Context $Status $ContentType $bytes
}

function Write-JsonBody($Context, $Object, [int]$Status) {
    $json = $Object | ConvertTo-Json -Depth 6 -Compress
    Write-Text $Context $Status 'application/json; charset=utf-8' $json
}

function ConvertTo-JsonString([string]$Value) {
    if ($null -eq $Value) { return '""' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
    return '"' + $escaped + '"'
}

function Write-StatusJson($Context) {
    Update-RunState
    $pass = 0
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('{"running":')
    if ($script:running) { [void]$builder.Append('true') } else { [void]$builder.Append('false') }
    [void]$builder.Append(',"total":')
    [void]$builder.Append([int]$script:total)
    [void]$builder.Append(',"done":')
    [void]$builder.Append([int]$script:done)
    [void]$builder.Append(',"message":')
    [void]$builder.Append((ConvertTo-JsonString $script:message))
    [void]$builder.Append(',"rows":[')
    $first = $true
    foreach ($row in @($script:rows.ToArray())) {
        if (-not $first) { [void]$builder.Append(',') }
        $first = $false
        if ($row.result -eq 'OK') { $pass++ }
        [void]$builder.Append('{"result":')
        [void]$builder.Append((ConvertTo-JsonString $row.result))
        [void]$builder.Append(',"status":')
        [void]$builder.Append((ConvertTo-JsonString $row.status))
        [void]$builder.Append(',"sitecode":')
        [void]$builder.Append((ConvertTo-JsonString $row.sitecode))
        [void]$builder.Append(',"path":')
        [void]$builder.Append((ConvertTo-JsonString $row.path))
        [void]$builder.Append(',"location":')
        [void]$builder.Append((ConvertTo-JsonString $row.location))
        [void]$builder.Append('}')
    }
    [void]$builder.Append('],"pass":')
    [void]$builder.Append($pass)
    [void]$builder.Append(',"fail":')
    [void]$builder.Append(($script:rows.Count - $pass))
    [void]$builder.Append('}')
    Write-Text $Context 200 'application/json; charset=utf-8' $builder.ToString()
}

function Get-BodyObject($Request) {
    $length = [int]$Request.ContentLength64
    if ($length -le 0) { return $null }
    if ($length -gt 1000000) { return $null }
    $buffer = New-Object byte[] $length
    $async = $Request.InputStream.BeginRead($buffer, 0, $length, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(2000)) { return $null }
    $read = $Request.InputStream.EndRead($async)
    if ($read -lt $length) {
        while ($read -lt $length) {
            $more = $Request.InputStream.BeginRead($buffer, $read, ($length - $read), $null, $null)
            if (-not $more.AsyncWaitHandle.WaitOne(2000)) { break }
            $count = $Request.InputStream.EndRead($more)
            if ($count -le 0) { break }
            $read += $count
        }
    }
    if ($read -le 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-StringList($Value) {
    if ($null -eq $Value) { return @() }
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        foreach ($part in ([string]$item).Split(',')) {
            $token = $part.Trim()
            if ($token) { [void]$items.Add($token) }
        }
    }
    return @($items)
}

$script:gate = New-Object System.Object
$script:pending = New-Object System.Collections.Generic.List[string]
$script:rows = New-Object System.Collections.Generic.List[object]
$script:running = $false
$script:total = 0
$script:done = 0
$script:logLines = 0
$script:logPath = ''
$script:message = '국가와 페이지를 고른 다음 검사를 누르세요.'
$script:proc = $null
$script:reader = $null

function Add-PendingLine([string]$Line) {
    [System.Threading.Monitor]::Enter($script:gate)
    try { [void]$script:pending.Add($Line) } finally { [System.Threading.Monitor]::Exit($script:gate) }
}

function Pop-PendingLines {
    $batch = @()
    [System.Threading.Monitor]::Enter($script:gate)
    try {
        $batch = @($script:pending.ToArray())
        $script:pending.Clear()
    } finally { [System.Threading.Monitor]::Exit($script:gate) }
    return $batch
}

function Add-ResultLine([string]$Line) {
    $clean = $Line -replace '\x1b\[[0-9;]*m', ''
    if ($clean -match '^\[(OK|FAIL) (\d+)/(\d+)\] (\S+) (\S+) (\S+) -> (.*)$') {
        $script:total = [int]$Matches[3]
        $script:done = [int]$Matches[2]
        [void]$script:rows.Add([pscustomobject]@{
            result = $Matches[1]
            status = $Matches[4]
            sitecode = $Matches[5]
            path = $Matches[6]
            location = $Matches[7].Trim()
        })
        return $true
    }
    return $false
}

function Read-NewLogLines {
    $path = $script:logPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
        try {
            $stream = New-Object System.IO.FileStream($path, 'Open', 'Read', 'ReadWrite')
            $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding $false))
            $text = $reader.ReadToEnd()
            $reader.Close()
            $lines = @()
            if (-not [string]::IsNullOrEmpty($text)) {
                $lines = @($text.Split([char[]]@([char]13, [char]10), [System.StringSplitOptions]::RemoveEmptyEntries))
            }
        } catch {
            return
        }
    for ($i = $script:logLines; $i -lt $lines.Count; $i++) {
        Add-ResultLine $lines[$i] | Out-Null
    }
    $script:logLines = $lines.Count
}

function Update-RunState {
    Read-NewLogLines
    foreach ($raw in @(Pop-PendingLines)) {
        $line = ([string]$raw) -replace '\x1b\[[0-9;]*m', ''
        if ($line -match '^\[(OK|FAIL) ') { continue }
        if ($line.Trim().Length -gt 0) { $script:message = $line.Trim() }
    }
    $proc = $script:proc
    if ($script:running -and $proc -and $proc.HasExited) {
        $script:running = $false
        if ($proc.ExitCode -eq 2 -and $script:rows.Count -eq 0) {
            $script:message = '검사를 시작하지 못했습니다. 국가, 페이지, 스테이징 연결을 확인하세요.'
        } elseif ($script:rows.Count -gt 0) {
            $pass = @($script:rows | Where-Object { $_.result -eq 'OK' }).Count
            $script:message = ('끝. 성공 {0} / 실패 {1}' -f $pass, ($script:rows.Count - $pass))
        }
    }
}

function Start-TestRun($Sites, $Pages) {
    if ($script:running) { return '이미 검사가 진행 중입니다.' }
    $argText = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $testScript
        '-SiteCode'
        ($Sites -join ',')
        '-Page'
        ($Pages -join ',')
    ) | ForEach-Object { ConvertTo-QuotedArg $_ }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = ($argText -join ' ')
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $script:rows = New-Object System.Collections.Generic.List[object]
    $script:pending = New-Object System.Collections.Generic.List[string]
    $script:logPath = Join-Path ([System.IO.Path]::GetTempPath()) ('akamai-ui-' + [guid]::NewGuid().ToString('n') + '.log')
    $script:logLines = 0
    [System.IO.File]::WriteAllText($script:logPath, '')
    $info.EnvironmentVariables['AKAMAI_UI_LOG'] = $script:logPath
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $info
    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $script:total = 0
    $script:done = 0
    $script:message = '검사 시작'
    $script:proc = $proc
    $script:running = $true
    return $null
}

function Stop-TestRun {
    $proc = $script:proc
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch {}
    }
}

function Get-StatusObject {
    Update-RunState
    $pass = @($script:rows | Where-Object { $_.result -eq 'OK' }).Count
    return [pscustomobject]@{
        running = [bool]$script:running
        total = [int]$script:total
        done = [int]$script:done
        pass = [int]$pass
        fail = [int]($script:rows.Count - $pass)
        message = [string]$script:message
        rows = @($script:rows)
    }
}

$html = @'
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>아카마이 스테이징 검사</title>
<style>
  body { margin: 0; font-family: "Segoe UI", "Malgun Gothic", sans-serif; background: #f4f6f8; color: #142033; }
  header { background: #1428a0; color: #fff; padding: 16px 22px; }
  header h1 { margin: 0; font-size: 20px; font-weight: 650; }
  header p { margin: 6px 0 0; opacity: .9; font-size: 13px; }
  main { display: grid; grid-template-columns: 300px 1fr; gap: 16px; padding: 16px; }
  section { background: #fff; border-radius: 8px; padding: 14px; }
  h2 { margin: 0 0 10px; font-size: 15px; }
  input[type=search] { width: 100%; box-sizing: border-box; padding: 8px 10px; border: 1px solid #c9d2df; border-radius: 4px; }
  .rowbtns { display: flex; gap: 8px; margin: 8px 0; }
  button { border: 0; border-radius: 4px; padding: 8px 12px; background: #e8edf5; cursor: pointer; }
  button.primary { background: #1428a0; color: #fff; }
  button:disabled { opacity: .5; cursor: default; }
  #sites { max-height: 68vh; overflow: auto; border-top: 1px solid #e4e8ee; }
  #sites label { display: flex; gap: 8px; align-items: center; padding: 5px 2px; }
  .pages { display: flex; flex-wrap: wrap; gap: 8px 14px; margin-bottom: 12px; }
  .pages label { display: flex; gap: 6px; align-items: center; }
  .status { min-height: 22px; margin: 8px 0; font-size: 14px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { border-bottom: 1px solid #e4e8ee; padding: 7px 8px; text-align: left; font-size: 13px; vertical-align: top; }
  th { background: #eef2f7; position: sticky; top: 0; }
  td { word-break: break-all; }
  tr.FAIL td { background: #fdecec; }
  tr.OK td { background: #f3fbf6; }
  #tablewrap { max-height: 62vh; overflow: auto; }
  @media (max-width: 800px) { main { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<header>
  <h1>아카마이 스테이징 검사</h1>
  <p>www.samsung.com 을 입력한 스테이징 IP로 붙여 리다이렉트를 확인합니다.</p>
</header>
<main>
  <section>
    <h2>국가</h2>
    <input id="q" type="search" placeholder="코드 검색. 예: ae, sec, us">
    <div class="rowbtns">
      <button type="button" id="all">보이는 것 선택</button>
      <button type="button" id="none">선택 해제</button>
    </div>
    <div id="picked">선택 0</div>
    <div id="sites"></div>
  </section>
  <section>
    <h2>페이지</h2>
    <div class="pages" id="pages"></div>
    <div class="rowbtns">
      <button type="button" class="primary" id="run">검사</button>
      <button type="button" id="stop" disabled>중지</button>
    </div>
    <div class="status" id="status">불러오는 중...</div>
    <div id="tablewrap">
      <table>
        <thead><tr><th>결과</th><th>국가</th><th>경로</th><th>상태</th><th>Location</th></tr></thead>
        <tbody id="rows"></tbody>
      </table>
    </div>
  </section>
</main>
<script>
var pageMeta = [
  ["mypage", "마이페이지"],
  ["myproducts", "내 제품"],
  ["myrepair", "수리"],
  ["track-repair", "수리 추적"],
  ["getsupport", "지원"]
];
var pollTimer = null;

function selectedSites() {
  return Array.prototype.map.call(document.querySelectorAll("#sites input:checked"), function (el) { return el.value; });
}
function selectedPages() {
  return Array.prototype.map.call(document.querySelectorAll("#pages input:checked"), function (el) { return el.value; });
}
function updatePicked() {
  document.getElementById("picked").textContent = "선택 " + selectedSites().length;
}
function visibleInputs() {
  var labels = document.querySelectorAll("#sites label");
  var list = [];
  for (var i = 0; i < labels.length; i++) {
    if (labels[i].style.display !== "none") list.push(labels[i].querySelector("input"));
  }
  return list;
}
function esc(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, function (ch) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[ch];
  });
}
function renderRows(data) {
  var rows = data.rows || [];
  if (!Array.isArray(rows)) rows = [rows];
  var body = document.getElementById("rows");
  var html = "";
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    html += "<tr class='" + esc(row.result) + "'><td>" + esc(row.result) + "</td><td>" + esc(row.sitecode) +
      "</td><td>" + esc(row.path) + "</td><td>" + esc(row.status) + "</td><td>" + esc(row.location) + "</td></tr>";
  }
  body.innerHTML = html;
  var box = document.getElementById("tablewrap");
  box.scrollTop = box.scrollHeight;
}
function renderStatus(data) {
  var text = data.message || "";
  if (data.total) text += "  (" + data.done + "/" + data.total + ", 성공 " + data.pass + ", 실패 " + data.fail + ")";
  document.getElementById("status").textContent = text;
  document.getElementById("run").disabled = !!data.running;
  document.getElementById("stop").disabled = !data.running;
  renderRows(data);
}
function poll() {
  fetch("/api/status").then(function (r) { return r.json(); }).then(function (data) {
    renderStatus(data);
    if (data.running) pollTimer = setTimeout(poll, 400);
  }).catch(function () {
    document.getElementById("status").textContent = "페이지와 연결이 끊겼습니다. Open-TestUi.vbs 를 다시 실행하세요.";
  });
}
function startPoll() {
  if (pollTimer) clearTimeout(pollTimer);
  poll();
}

fetch("/api/options").then(function (r) { return r.json(); }).then(function (data) {
  var sites = data.sites || [];
  var host = document.getElementById("sites");
  var html = "";
  for (var i = 0; i < sites.length; i++) {
    html += "<label data-code='" + sites[i] + "'><input type='checkbox' value='" + sites[i] + "'> " + sites[i] + "</label>";
  }
  host.innerHTML = html;
  host.addEventListener("change", updatePicked);
  var pages = document.getElementById("pages");
  var pageHtml = "";
  for (var j = 0; j < pageMeta.length; j++) {
    pageHtml += "<label><input type='checkbox' value='" + pageMeta[j][0] + "'> " + pageMeta[j][1] + " (" + pageMeta[j][0] + ")</label>";
  }
  pages.innerHTML = pageHtml;
  document.getElementById("status").textContent = "국가와 페이지를 고른 다음 검사를 누르세요.";
});

document.getElementById("q").oninput = function () {
  var q = this.value.trim().toLowerCase();
  var labels = document.querySelectorAll("#sites label");
  for (var i = 0; i < labels.length; i++) {
    labels[i].style.display = labels[i].getAttribute("data-code").indexOf(q) === -1 ? "none" : "";
  }
};
document.getElementById("all").onclick = function () {
  var list = visibleInputs();
  for (var i = 0; i < list.length; i++) list[i].checked = true;
  updatePicked();
};
document.getElementById("none").onclick = function () {
  var inputs = document.querySelectorAll("#sites input");
  for (var i = 0; i < inputs.length; i++) inputs[i].checked = false;
  updatePicked();
};
document.getElementById("run").onclick = function () {
  var sites = selectedSites();
  var pages = selectedPages();
  if (!sites.length || !pages.length) {
    document.getElementById("status").textContent = "국가와 페이지를 하나 이상 고르세요.";
    return;
  }
  fetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sites: sites, pages: pages })
  }).then(function (r) { return r.json(); }).then(function (data) {
    if (data.error) document.getElementById("status").textContent = data.error;
    startPoll();
  });
};
document.getElementById("stop").onclick = function () {
  fetch("/api/stop", { method: "POST" }).then(function () { startPoll(); });
};
</script>
</body>
</html>
'@

function Handle-Request($Context) {
    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod
    if ($path -eq '/favicon.ico') {
        Write-Text $Context 204 'text/plain' ''
        return
    }
    if ($method -eq 'GET' -and $path -eq '/') {
        Write-Text $Context 200 'text/html; charset=utf-8' $html
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/options') {
        Write-JsonBody $Context ([pscustomobject]@{
            sites = @(Read-SiteCodes)
            pages = $allowedPages
        }) 200
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/status') {
        Write-StatusJson $Context
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/stop') {
        Stop-TestRun
        $script:message = '중지했습니다.'
        Write-StatusJson $Context
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/run') {
        $body = Get-BodyObject $request
        $sites = @(Get-StringList $body.sites)
        $pages = @(Get-StringList $body.pages)
        $known = @{}
        foreach ($code in @(Read-SiteCodes)) { $known[$code.ToLowerInvariant()] = $code }
        $cleanSites = New-Object System.Collections.Generic.List[string]
        foreach ($site in $sites) {
            $key = $site.ToLowerInvariant()
            if (-not $known.ContainsKey($key)) {
                Write-JsonBody $Context ([pscustomobject]@{ error = ('없는 국가 코드: ' + $site) }) 400
                return
            }
            [void]$cleanSites.Add($known[$key])
        }
        $cleanPages = New-Object System.Collections.Generic.List[string]
        foreach ($page in $pages) {
            $token = $page.ToLowerInvariant()
            if ($allowedPages -notcontains $token) {
                Write-JsonBody $Context ([pscustomobject]@{ error = ('없는 페이지: ' + $page) }) 400
                return
            }
            [void]$cleanPages.Add($token)
        }
        if ($cleanSites.Count -eq 0 -or $cleanPages.Count -eq 0) {
            Write-JsonBody $Context ([pscustomobject]@{ error = '국가와 페이지를 하나 이상 고르세요.' }) 400
            return
        }
        $errorText = Start-TestRun @($cleanSites) @($cleanPages)
        if ($errorText) {
            Write-JsonBody $Context ([pscustomobject]@{ error = $errorText }) 409
            return
        }
        Write-StatusJson $Context
        return
    }
    Write-Text $Context 404 'text/plain; charset=utf-8' 'not found'
}

function Test-UiAlreadyRunning {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect('127.0.0.1', 8765, $null, $null)
        if (-not $wait.AsyncWaitHandle.WaitOne(400)) { return $false }
        $client.EndConnect($wait)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

if (Test-UiAlreadyRunning) {
    Start-Process 'http://127.0.0.1:8765/'
    exit 0
}

$listener = $null
$port = 0
for ($candidate = 8765; $candidate -le 8775; $candidate++) {
    $tryListener = New-Object System.Net.HttpListener
    $tryListener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $candidate))
    try {
        $tryListener.Start()
        $listener = $tryListener
        $port = $candidate
        break
    } catch {
        $tryListener.Close()
    }
}
if (-not $listener) { throw '8765-8775 포트를 열 수 없습니다.' }

$url = 'http://127.0.0.1:{0}/' -f $port
Write-Host ('열림: ' + $url)
Write-Host '이 창을 닫으면 검사 페이지도 종료됩니다.'
Start-Process $url

try {
    while ($listener.IsListening) {
        $context = $null
        try {
            $context = $listener.GetContext()
            Handle-Request $context
        } catch {
            if (-not $listener.IsListening) { break }
            Write-Host ('요청 처리 오류: ' + $_.Exception.Message)
            if ($context) {
                try { Write-Text $context 500 'text/plain; charset=utf-8' $_.Exception.Message } catch {}
            }
        }
    }
} finally {
    Stop-TestRun
    if ($listener) { $listener.Stop(); $listener.Close() }
}
