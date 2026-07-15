param(
    [int]$Port = 3000,
    [string]$Agent = "ACP-Chatbot"
)

$ErrorActionPreference = "Stop"

# Use the repository containing this script as the working directory root.
$RepoRoot = $PSScriptRoot

Write-Host "Starting Copilot ACP server..." -ForegroundColor Cyan
Write-Host "Working directory: $RepoRoot"
Write-Host "Port: $Port"
Write-Host "Agent: $Agent"
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
