param(
    [string]$Host = "127.0.0.1",
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
    [switch]$DenyPermissions,
    [string]$AdapterImage
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

if ([string]::IsNullOrWhiteSpace($User)) {
    $User = if ([string]::IsNullOrWhiteSpace($env:WEBSOCKET_USER)) { "token" } else { $env:WEBSOCKET_USER }
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = $env:WEBSOCKET_TOKEN
}
if ([string]::IsNullOrWhiteSpace($AuthMethodId)) {
    $AuthMethodId = $env:ACP_AUTH_METHOD_ID
}
if ([string]::IsNullOrWhiteSpace($AdapterImage)) {
    $AdapterImage = if ([string]::IsNullOrWhiteSpace($env:ACP_WEBSOCKET_ADAPTER_IMAGE)) { "acp-websocket-adapter:local" } else { $env:ACP_WEBSOCKET_ADAPTER_IMAGE }
}
if ([string]::IsNullOrWhiteSpace($Url)) {
    if (-not [string]::IsNullOrWhiteSpace($env:ACP_WEBSOCKET_PORT) -and $PSBoundParameters.ContainsKey('Port') -eq $false) {
        $Port = [int]$env:ACP_WEBSOCKET_PORT
    }
    $Url = "ws://${Host}:${Port}"
}

if (-not $Interactive -and [string]::IsNullOrWhiteSpace($Question)) {
    Write-Error "Provide -Question for one-shot mode, or use -Interactive."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Error "Missing websocket token. Set WEBSOCKET_TOKEN in .env or pass -Token."
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "docker command not found."
    exit 1
}

$imageNeedsBuild = $false
docker image inspect $AdapterImage *> $null
if ($LASTEXITCODE -ne 0) {
    $imageNeedsBuild = $true
}
else {
    docker run --rm $AdapterImage sh -lc "test -f /app/ask-websocket.js && grep -q 'ACP_SESSION_ID' /app/ask-websocket.js && grep -q 'effectiveSessionId' /app/ask-websocket.js && grep -q 'session/load' /app/ask-websocket.js" *> $null
    if ($LASTEXITCODE -ne 0) {
        $imageNeedsBuild = $true
    }
}

if ($imageNeedsBuild) {
    Write-Host "Building adapter image: $AdapterImage"
    docker build -f (Join-Path $scriptDir "Dockerfile.websocket-adapter") -t $AdapterImage $scriptDir *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build adapter image '$AdapterImage'."
        exit 1
    }
}

$dockerArgs = @(
    "run", "--rm", "-i", "--network", "host",
    "-e", "ACP_WS_URL=$Url",
    "-e", "ACP_WS_USER=$User",
    "-e", "ACP_WS_TOKEN=$Token",
    "-e", "ACP_CWD=$Cwd",
    "-e", "ACP_AGENT=$Agent",
    "-e", "ACP_AUTH_METHOD_ID=$AuthMethodId",
    "-e", "ACP_SESSION_ID=$SessionId",
    "-e", "ACP_QUESTION=$Question",
    "-e", "ACP_INTERACTIVE=$($Interactive.IsPresent.ToString().ToLower())",
    "-e", "ACP_DENY_PERMISSIONS=$($DenyPermissions.IsPresent.ToString().ToLower())",
    $AdapterImage,
    "node", "/app/ask-websocket.js"
)

& docker @dockerArgs
exit $LASTEXITCODE
