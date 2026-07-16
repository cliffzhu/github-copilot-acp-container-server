param(
    [string]$ServerHost = "127.0.0.1",
    [int]$Port = 3000,
    [string]$Cwd = ".",
    [string]$Agent = "ACP-Chatbot",
    [string]$AuthMethodId,
    [string]$SessionId,
    [string]$Question,
    [switch]$Interactive,
    [switch]$DenyPermissions
)

$ErrorActionPreference = "Stop"

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

if ([string]::IsNullOrWhiteSpace($AuthMethodId)) {
    $AuthMethodId = $env:ACP_AUTH_METHOD_ID
}
if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = $env:ACP_SESSION_ID
}

function Send-AcpJson {
    param(
        [System.IO.StreamWriter]$Writer,
        [hashtable]$Payload
    )

    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    $Writer.WriteLine($json)
    $Writer.Flush()
}

function Write-AcpResponseError {
    param(
        [System.IO.StreamWriter]$Writer,
        [object]$RequestId,
        [int]$Code,
        [string]$Message
    )

    Send-AcpJson -Writer $Writer -Payload @{
        jsonrpc = "2.0"
        id = $RequestId
        error = @{
            code = $Code
            message = $Message
        }
    }
}

function Invoke-AcpRequest {
    param(
        [System.IO.StreamWriter]$Writer,
        [System.IO.StreamReader]$Reader,
        [string]$Method,
        [hashtable]$Params,
        [ref]$NextId,
        [switch]$DenyPermissions
    )

    $requestId = [string]$NextId.Value
    $NextId.Value = $NextId.Value + 1

    Send-AcpJson -Writer $Writer -Payload @{
        jsonrpc = "2.0"
        id = $requestId
        method = $Method
        params = $Params
    }

    while ($true) {
        $line = $Reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

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
            Send-AcpJson -Writer $Writer -Payload @{
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
            Write-AcpResponseError -Writer $Writer -RequestId $msg.id -Code -32601 -Message "Method not found: $($msg.method)"
        }
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

function Invoke-AcpAuthenticateIfRequested {
    param(
        [System.IO.StreamWriter]$Writer,
        [System.IO.StreamReader]$Reader,
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

    [void](Invoke-AcpRequest -Writer $Writer -Reader $Reader -Method "authenticate" -Params @{
        methodId = $MethodId
    } -NextId $NextId -DenyPermissions:$DenyPermissions)

    return $true
}

if (-not $Interactive -and [string]::IsNullOrWhiteSpace($Question)) {
    Write-Error "Provide -Question for one-shot mode, or use -Interactive."
    exit 1
}

$resolvedCwd = (Resolve-Path $Cwd).Path
$tcpClient = New-Object System.Net.Sockets.TcpClient
$tcpClient.Connect($ServerHost, $Port)

$stream = $tcpClient.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

$nextId = 1
$initResult = $null
$authenticated = $false
$supportsLogout = $false

try {
    $initResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "initialize" -Params @{
        protocolVersion = 1
        clientCapabilities = @{}
    } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

    if ($null -eq $initResult.protocolVersion) {
        throw "Initialize returned no protocolVersion."
    }

    $authenticated = Invoke-AcpAuthenticateIfRequested -Writer $writer -Reader $reader -InitializeResult $initResult -MethodId $AuthMethodId -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions
    $supportsLogout = Test-AcpLogoutCapability -InitializeResult $initResult
    $supportsLoadSession = Test-AcpLoadSessionCapability -InitializeResult $initResult

    $sessionIdToUse = $null
    $resumed = $false
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        if ($supportsLoadSession) {
            try {
                $loadResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/load" -Params @{
                    sessionId = $SessionId
                    cwd = $resolvedCwd
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
                $resumeResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/resume" -Params @{
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
        $sessionResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/new" -Params @{
            cwd = $resolvedCwd
            mcpServers = @()
        } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

        if ([string]::IsNullOrWhiteSpace($sessionResult.sessionId)) {
            throw "session/new did not return sessionId."
        }

        $sessionIdToUse = $sessionResult.sessionId
        $resumed = $false
    }

    $setAgentResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/set_config_option" -Params @{
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
        $promptResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/prompt" -Params @{
            sessionId = $sessionIdToUse
            prompt = @(@{ type = "text"; text = $Question })
        } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

        Write-Host ""
        Write-Host "stopReason: $($promptResult.stopReason)"
        Write-Host "effectiveSessionId: $sessionIdToUse"
        if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
            $mode = if ($resumed) { "resumed" } else { "new" }
            Write-Host "sessionMode: $mode"
        }
        if ($authenticated -and $supportsLogout) {
            [void](Invoke-AcpRequest -Writer $writer -Reader $reader -Method "logout" -Params @{} -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions)
        }
        exit 0
    }

    Write-Host "Connected to ACP server on $ServerHost`:$Port"
    Write-Host "SessionId: $sessionIdToUse"
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $mode = if ($resumed) { "resumed" } else { "new" }
        Write-Host "Session mode: $mode (input sessionId)"
    }
    Write-Host "Agent: $Agent"
    if ($authenticated) {
        Write-Host "Auth: authenticate($AuthMethodId)"
    }
    Write-Host "Type /exit to quit."

    while ($true) {
        $q = Read-Host ">"
        if ([string]::IsNullOrWhiteSpace($q)) {
            continue
        }
        if ($q -eq "/exit") {
            break
        }

        $promptResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/prompt" -Params @{
            sessionId = $sessionIdToUse
            prompt = @(@{ type = "text"; text = $q })
        } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

        Write-Host ""
        Write-Host "stopReason: $($promptResult.stopReason)"
    }

    if ($authenticated -and $supportsLogout) {
        [void](Invoke-AcpRequest -Writer $writer -Reader $reader -Method "logout" -Params @{} -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions)
    }
}
finally {
    $writer.Dispose()
    $reader.Dispose()
    $stream.Dispose()
    $tcpClient.Close()
}
