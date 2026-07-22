param(
    [string]$WsHost = "127.0.0.1",
    [int]$Port = 8080,
    [string]$Url,
    [string]$User,
    [string]$Token,
    [string]$Cwd = "/workspace",
    [string]$Agent = "ACP-Chatbot",
    [string]$AuthMethodId,
    [string]$SessionId,
    [string]$Question,
    [switch]$Interactive,
    [switch]$DenyPermissions
)

$ErrorActionPreference = "Stop"

$script:WsLineBuffer = ""

$scriptDir = $PSScriptRoot
$envFile = Join-Path $scriptDir ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            return
        }

        $pair = $line -split "=", 2
        if ($pair.Count -eq 2) {
            $name = $pair[0].Trim()
            $value = $pair[1].Trim()
            if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($name))) {
                [System.Environment]::SetEnvironmentVariable($name, $value)
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($User)) {
    $User = if ([string]::IsNullOrWhiteSpace($env:WEBSOCKET_USER)) { "token" } else { $env:WEBSOCKET_USER }
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = $env:WEBSOCKET_TOKEN
}
if ([string]::IsNullOrWhiteSpace($AuthMethodId)) {
    $AuthMethodId = $env:ACP_AUTH_METHOD_ID
}
if ([string]::IsNullOrWhiteSpace($Url)) {
    if (-not [string]::IsNullOrWhiteSpace($env:ACP_WEBSOCKET_PORT) -and $PSBoundParameters.ContainsKey('Port') -eq $false) {
        $Port = [int]$env:ACP_WEBSOCKET_PORT
    }
    $Url = "ws://${WsHost}:${Port}"
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Error "Missing websocket token. Set WEBSOCKET_TOKEN in .env or pass -Token."
    exit 1
}

function Send-AcpWsJson {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [hashtable]$Payload
    )

    $json = ($Payload | ConvertTo-Json -Depth 20 -Compress) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)
    $WebSocket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Write-AcpWsResponseError {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [object]$RequestId,
        [int]$Code,
        [string]$Message
    )

    Send-AcpWsJson -WebSocket $WebSocket -Payload @{
        jsonrpc = "2.0"
        id = $RequestId
        error = @{
            code = $Code
            message = $Message
        }
    }
}

function Read-AcpWsLine {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket
    )

    while ($true) {
        if (-not [string]::IsNullOrEmpty($script:WsLineBuffer)) {
            $newlineIndex = $script:WsLineBuffer.IndexOf("`n")
            if ($newlineIndex -ge 0) {
                $line = $script:WsLineBuffer.Substring(0, $newlineIndex).TrimEnd("`r")
                $script:WsLineBuffer = $script:WsLineBuffer.Substring($newlineIndex + 1)
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    return $line
                }
                continue
            }
        }

        $chunkBuffer = New-Object byte[] 4096
        $segment = [ArraySegment[byte]]::new($chunkBuffer)
        $builder = New-Object System.Text.StringBuilder

        do {
            $result = $WebSocket.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw "WebSocket closed by remote endpoint."
            }

            if ($result.Count -gt 0) {
                [void]$builder.Append([System.Text.Encoding]::UTF8.GetString($chunkBuffer, 0, $result.Count))
            }
        } while (-not $result.EndOfMessage)

        $script:WsLineBuffer += $builder.ToString()
    }
}

function Test-AcpLogoutCapability {
    param([object]$InitializeResult)

    return ($null -ne $InitializeResult.agentCapabilities -and
        $null -ne $InitializeResult.agentCapabilities.auth -and
        $null -ne $InitializeResult.agentCapabilities.auth.logout)
}

function Test-AcpLoadSessionCapability {
    param([object]$InitializeResult)

    return ($null -ne $InitializeResult.agentCapabilities -and
        $null -ne $InitializeResult.agentCapabilities.loadSession)
}

function Test-AcpMethodNotFoundError {
    param(
        [string]$ErrorMessage,
        [string]$MethodName
    )

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        return $false
    }

    return ($ErrorMessage -match "\[-32601\]" -and $ErrorMessage.Contains($MethodName))
}

function Invoke-AcpWsRequest {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Method,
        [hashtable]$Params,
        [ref]$NextId,
        [switch]$DenyPermissions
    )

    $requestId = [string]$NextId.Value
    $NextId.Value = $NextId.Value + 1

    Send-AcpWsJson -WebSocket $WebSocket -Payload @{
        jsonrpc = "2.0"
        id = $requestId
        method = $Method
        params = $Params
    }

    while ($true) {
        $line = Read-AcpWsLine -WebSocket $WebSocket
        $msg = $line | ConvertFrom-Json

        if ($null -ne $msg.id -and $null -eq $msg.method) {
            if ([string]$msg.id -ne $requestId) {
                continue
            }

            if ($null -ne $msg.error) {
                throw "ACP error for ${Method}: [$($msg.error.code)] $($msg.error.message)"
            }

            return $msg.result
        }

        if ($msg.method -eq "session/update") {
            $update = $msg.params.update
            if ($null -ne $update -and $update.sessionUpdate -eq "agent_message_chunk") {
                if ($null -ne $update.content -and $update.content.type -eq "text" -and $null -ne $update.content.text) {
                    Write-Host -NoNewline $update.content.text
                }
            }
            continue
        }

        if ($msg.method -eq "session/request_permission") {
            $outcome = if ($DenyPermissions) { "cancelled" } else { "approved" }
            Send-AcpWsJson -WebSocket $WebSocket -Payload @{
                jsonrpc = "2.0"
                id = $msg.id
                result = @{
                    outcome = @{
                        outcome = $outcome
                    }
                }
            }
            continue
        }

        if ($null -ne $msg.id -and $null -ne $msg.method) {
            Write-AcpWsResponseError -WebSocket $WebSocket -RequestId $msg.id -Code -32601 -Message "Method not found: $($msg.method)"
        }
    }
}

function Invoke-AcpWsAuthenticateIfRequested {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [object]$InitializeResult,
        [string]$MethodId,
        [ref]$NextId,
        [switch]$DenyPermissions
    )

    if ([string]::IsNullOrWhiteSpace($MethodId)) {
        return $false
    }

    $authMethods = @()
    if ($null -ne $InitializeResult.authMethods) {
        $authMethods = @($InitializeResult.authMethods)
    }

    $match = $authMethods | Where-Object { $_.id -eq $MethodId } | Select-Object -First 1
    if ($null -eq $match) {
        throw "ACP auth method '$MethodId' was not advertised by initialize."
    }

    [void](Invoke-AcpWsRequest -WebSocket $WebSocket -Method "authenticate" -Params @{
        methodId = $MethodId
    } -NextId $NextId -DenyPermissions:$DenyPermissions)

    return $true
}

function Invoke-AcpWsPrompt {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$SessionId,
        [string]$Text,
        [ref]$NextId,
        [switch]$DenyPermissions
    )

    $promptResult = Invoke-AcpWsRequest -WebSocket $WebSocket -Method "session/prompt" -Params @{
        sessionId = $SessionId
        prompt = @(@{ type = "text"; text = $Text })
    } -NextId $NextId -DenyPermissions:$DenyPermissions

    Write-Host ""
    Write-Host "stopReason: $($promptResult.stopReason)"
}

function Start-AcpWsChatLoop {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$SessionId,
        [ref]$NextId,
        [switch]$DenyPermissions
    )

    Write-Host "Type a message and press Enter. Use Ctrl+C to stop."

    while ($true) {
        $q = Read-Host ">"
        if ([string]::IsNullOrWhiteSpace($q)) {
            continue
        }

        Invoke-AcpWsPrompt -WebSocket $WebSocket -SessionId $SessionId -Text $q -NextId $NextId -DenyPermissions:$DenyPermissions
    }
}

$auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$User`:$Token"))
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.Options.SetRequestHeader("Authorization", "Basic $auth")
$ws.ConnectAsync([Uri]$Url, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

$nextId = 1
$initResult = $null
$authenticated = $false
$supportsLogout = $false
$sessionIdToUse = $null
$resumed = $false

try {
    $initResult = Invoke-AcpWsRequest -WebSocket $ws -Method "initialize" -Params @{
        protocolVersion = 1
        clientCapabilities = @{}
    } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

    if ($null -eq $initResult.protocolVersion) {
        throw "Initialize returned no protocolVersion."
    }

    $authenticated = Invoke-AcpWsAuthenticateIfRequested -WebSocket $ws -InitializeResult $initResult -MethodId $AuthMethodId -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
    $supportsLogout = Test-AcpLogoutCapability -InitializeResult $initResult
    $supportsLoadSession = Test-AcpLoadSessionCapability -InitializeResult $initResult

    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        if ($supportsLoadSession) {
            try {
                $loadResult = Invoke-AcpWsRequest -WebSocket $ws -Method "session/load" -Params @{
                    sessionId = $SessionId
                    cwd = $Cwd
                    mcpServers = @()
                } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
                $sessionIdToUse = if ([string]::IsNullOrWhiteSpace($loadResult.sessionId)) { $SessionId } else { $loadResult.sessionId }
                $resumed = $true
            }
            catch {
                Write-Warning "Failed to load sessionId '$SessionId' via session/load ($($_.Exception.Message)); trying session/resume."
            }
        }

        try {
            if ([string]::IsNullOrWhiteSpace($sessionIdToUse)) {
                $resumeResult = Invoke-AcpWsRequest -WebSocket $ws -Method "session/resume" -Params @{
                    sessionId = $SessionId
                } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
                $sessionIdToUse = if ([string]::IsNullOrWhiteSpace($resumeResult.sessionId)) { $SessionId } else { $resumeResult.sessionId }
                $resumed = $true
            }
        }
        catch {
            $message = $_.Exception.Message
            if ($supportsLoadSession -and (Test-AcpMethodNotFoundError -ErrorMessage $message -MethodName "session/resume")) {
                Write-Warning "ACP server does not implement session/resume and session/load already failed; creating a new session."
            }
            else {
                Write-Warning "Failed to resume sessionId '$SessionId' ($message); creating a new session."
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($sessionIdToUse)) {
        $sessionResult = Invoke-AcpWsRequest -WebSocket $ws -Method "session/new" -Params @{
            cwd = $Cwd
            mcpServers = @()
        } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

        if ([string]::IsNullOrWhiteSpace($sessionResult.sessionId)) {
            throw "session/new did not return sessionId."
        }

        $sessionIdToUse = $sessionResult.sessionId
        $resumed = $false
    }

    $setAgentResult = Invoke-AcpWsRequest -WebSocket $ws -Method "session/set_config_option" -Params @{
        sessionId = $sessionIdToUse
        configId = "agent"
        value = $Agent
    } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

    $agentOption = $null
    if ($null -ne $setAgentResult.configOptions) {
        foreach ($opt in $setAgentResult.configOptions) {
            if ($opt.id -eq "agent") {
                $agentOption = $opt
                break
            }
        }
    }
    if ($null -eq $agentOption -or $agentOption.currentValue -ne $Agent) {
        throw "Failed to set ACP session agent to '$Agent'."
    }

    if (-not [string]::IsNullOrWhiteSpace($Question)) {
        Invoke-AcpWsPrompt -WebSocket $ws -SessionId $sessionIdToUse -Text $Question -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
        Write-Host "effectiveSessionId: $sessionIdToUse"
        if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
            $mode = if ($resumed) { "resumed" } else { "new" }
            Write-Host "sessionMode: $mode"
        }
        Start-AcpWsChatLoop -WebSocket $ws -SessionId $sessionIdToUse -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
    }

    Write-Host "Connected to ACP websocket $Url"
    Write-Host "SessionId: $sessionIdToUse"
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $mode = if ($resumed) { "resumed" } else { "new" }
        Write-Host "Session mode: $mode (input sessionId)"
    }
    Write-Host "Agent: $Agent"
    if ($authenticated) {
        Write-Host "Auth: authenticate($AuthMethodId)"
    }

    Start-AcpWsChatLoop -WebSocket $ws -SessionId $sessionIdToUse -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
}
finally {
    if ($authenticated -and $supportsLogout) {
        try {
            [void](Invoke-AcpWsRequest -WebSocket $ws -Method "logout" -Params @{} -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions)
        }
        catch {
            Write-Warning "logout failed ($($_.Exception.Message))"
        }
    }

    if ($null -ne $ws) {
        try {
            if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -or $ws.State -eq [System.Net.WebSockets.WebSocketState]::CloseReceived) {
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "client closing", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            }
        }
        catch {
            # Ignore close errors while terminating.
        }
        $ws.Dispose()
    }
}
