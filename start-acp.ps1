param(
    [int]$Port = 3000,
  [string]$Agent = "ACP-Chatbot",
  [string]$AuthMethodId = ""
)

$ErrorActionPreference = "Stop"

# Use the repository containing this script as the working directory root.
$RepoRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($AuthMethodId)) {
  $envFile = Join-Path $RepoRoot ".env"
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
  $AuthMethodId = $env:ACP_AUTH_METHOD_ID
}

if (-not [string]::IsNullOrWhiteSpace($AuthMethodId)) {
  $env:ACP_AUTH_METHOD_ID = $AuthMethodId
}

Write-Host "Starting Copilot ACP server..." -ForegroundColor Cyan
Write-Host "Working directory: $RepoRoot"
Write-Host "Port: $Port"
Write-Host "Agent: $Agent"
if (-not [string]::IsNullOrWhiteSpace($AuthMethodId)) {
  Write-Host "Auth method id: $AuthMethodId"
}
Write-Host "Mode: read-only (tool access limited to safe read/search tools)"

# Notes:
# - -C sets the process working directory.
# - --available-tools uses explicit, valid read/search tool names.
# - --disallow-temp-dir prevents automatic temp-directory access.
# - No --allow-all-paths flag is used, so path verification remains enabled.
# - --disable-builtin-mcps keeps the server focused on local knowledge files.

copilot --acp --port $Port `
  -C "$RepoRoot" `
  --agent "$Agent" `
  --available-tools="glob,rg,read_agent,read_powershell,list_agents,list_powershell,view,skill" `
  --disallow-temp-dir `
  --disable-builtin-mcps
