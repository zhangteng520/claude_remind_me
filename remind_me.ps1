param(
    [int]$PinSeconds = 2
)

<#
.SYNOPSIS
Claude Code Stop hook：捕获一轮对话中「用户最后一条输入」，
保存到本地文件，并调用 D:\pythonSripts\terminal_pin_notice.py 弹出提示

说明：Stop 事件的 payload（stdin 传入的 JSON）里没有用户消息，
只有 transcript_path —— 本会话的 JSONL 转录文件路径。
用户输入保存在转录文件中 type=user 的行里；
其中 content 为工具结果（tool_result）或斜杠命令（以 < 开头）的行不算用户输入。
#>

# 读取 stdin 全部内容，按 UTF-8 解码（避免中文按本地代码页解析成乱码）
$stdinStream = [Console]::OpenStandardInput()
$reader = [System.IO.StreamReader]::new($stdinStream, [System.Text.Encoding]::UTF8)
$rawInput = $reader.ReadToEnd()
$reader.Dispose()

# 去掉调用方可能带上的 UTF-8 BOM（可能不止一个）和首尾空白
$rawInput = $rawInput.TrimStart([char]0xFEFF).Trim()

if (-not $rawInput) {
    Write-Error "[Hook Stop] 未收到 stdin 输入"
    exit 1
}

try {
    $payload = $rawInput | ConvertFrom-Json
} catch {
    Write-Error "[Hook Stop] JSON 解析失败：$($_.Exception.Message)"
    exit 1
}

$transcript = $payload.transcript_path -replace '^~', $env:USERPROFILE
if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) {
    Write-Error "[Hook Stop] 找不到 transcript 文件：$transcript"
    exit 1
}

# 从转录文件末尾向前找最后一条真正的用户输入
$userText = $null
$lines = @(Get-Content -LiteralPath $transcript -Encoding UTF8 -Tail 5000)
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    try { $line = $lines[$i] | ConvertFrom-Json } catch { continue }
    if ($line.type -ne 'user' -or $line.isSidechain -eq $true -or $line.isMeta -eq $true) { continue }
    if (-not $line.message) { continue }
    $content = $line.message.content
    if ($null -eq $content) { continue }

    if ($content -is [string]) {
        $text = $content
    } else {
        # 工具结果行不是用户输入，跳过；只拼接文本块
        if (@($content | Where-Object { $_.type -eq 'tool_result' }).Count -gt 0) { continue }
        $text = (@($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n")
    }

    $text = $text.Trim()
    if (-not $text) { continue }
    if ($text.StartsWith('<')) { continue }   # 斜杠命令 / 本地命令输出等系统注入，不算用户输入
    $userText = $text
    break
}

if (-not $userText) {
    Write-Error "[Hook Stop] 没有找到用户输入"
    exit 0
}

# 输出到 stderr（在 transcript 模式 Ctrl-R 里可见）
Write-Error "`n==== 用户最后一条输入 ====`n$userText"

# 保存到本地文件（按需要改成你自己的路径）
$outFile = "C:\workspace\last_user_input.txt"
$outDir = Split-Path -Parent $outFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$userText | Out-File -FilePath $outFile -Encoding utf8
Write-Error "`n✅ 已保存至：$outFile"

# 最后一行：调用通知脚本，把用户输入作为 --message 参数传入
# 用 Start-Process 异步启动，避免弹窗（最长驻留 15 秒）阻塞 hook
try {
    $escaped = $userText -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    $noticeScript = Join-Path $PSScriptRoot 'terminal_pin_notice.py'
    $argLine = '"' + $noticeScript + '" --seconds ' + $PinSeconds + ' --message "' + $escaped + '"'
    Start-Process -FilePath python -ArgumentList $argLine -WindowStyle Hidden -ErrorAction Stop
} catch {
    Write-Error "[Hook Stop] 通知脚本启动失败：$($_.Exception.Message)"
}

exit 0
