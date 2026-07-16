param(
    [string]$Distro = "",
    [int]$Port = 3000,
    [string]$Agent = "ACP-Chatbot",
    [string]$AuthMethodId = "",
    [switch]$BindAllInterfaces
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$WslRepoRoot = (& wsl.exe wslpath -a "$RepoRoot").Trim()

$wslArgs = @()
if (-not [string]::IsNullOrWhiteSpace($Distro)) {
    $wslArgs += "-d"
    $wslArgs += $Distro
}

$envVars = @(
    "ACP_PORT=$Port",
    "ACP_AGENT=$Agent"
)

if (-not [string]::IsNullOrWhiteSpace($AuthMethodId)) {
    $envVars += "ACP_AUTH_METHOD_ID=$AuthMethodId"
}

if ($BindAllInterfaces) {
    $envVars += "ACP_BIND_ALL_INTERFACES=true"
} else {
    $envVars += "ACP_BIND_ALL_INTERFACES=false"
}

$bashCommand = "cd '$WslRepoRoot' && env $($envVars -join ' ') ./start-acp.sh"

Write-Host "Starting Copilot ACP server in WSL..." -ForegroundColor Cyan
Write-Host "WSL repo root: $WslRepoRoot"
Write-Host "Port: $Port"
Write-Host "Agent: $Agent"
if (-not [string]::IsNullOrWhiteSpace($AuthMethodId)) {
    Write-Host "Auth method id: $AuthMethodId"
}
Write-Host "Bind all interfaces: $BindAllInterfaces"

& wsl.exe @wslArgs -- bash -lc $bashCommand
