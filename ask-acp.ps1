param(
    [string]$ServerHost = "127.0.0.1",
    [int]$Port = 3000,
    [string]$Cwd = ".",
    [string]$Agent = "ACP-Chatbot",
    [string]$Question,
    [switch]$Interactive,
    [switch]$DenyPermissions
)

$ErrorActionPreference = "Stop"

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

try {
    $initResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "initialize" -Params @{
        protocolVersion = 1
        clientCapabilities = @{}
    } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

    if ($null -eq $initResult.protocolVersion) {
        throw "Initialize returned no protocolVersion."
    }

    $sessionResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/new" -Params @{
        cwd = $resolvedCwd
        mcpServers = @()
    } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

    if ([string]::IsNullOrWhiteSpace($sessionResult.sessionId)) {
        throw "session/new did not return sessionId."
    }

    $sessionId = $sessionResult.sessionId

    # ACP sessions do not reliably inherit --agent from server startup.
    # Explicitly pin the session to the requested custom agent.
    $setAgentResult = Invoke-AcpRequest -Writer $writer -Reader $reader -Method "session/set_config_option" -Params @{
        sessionId = $sessionId
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
            sessionId = $sessionId
            prompt = @(@{ type = "text"; text = $Question })
        } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

        Write-Host ""
        Write-Host "stopReason: $($promptResult.stopReason)"
        exit 0
    }

    Write-Host "Connected to ACP server on $ServerHost`:$Port"
    Write-Host "SessionId: $sessionId"
    Write-Host "Agent: $Agent"
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
            sessionId = $sessionId
            prompt = @(@{ type = "text"; text = $q })
        } -NextId ([ref]$nextId) -DenyPermissions:$DenyPermissions

        Write-Host ""
        Write-Host "stopReason: $($promptResult.stopReason)"
    }
}
finally {
    $writer.Dispose()
    $reader.Dispose()
    $stream.Dispose()
    $tcpClient.Close()
}
