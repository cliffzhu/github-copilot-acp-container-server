# github-copilot-acp-container-server

Container launcher for GitHub Copilot CLI in ACP server mode.

The container runs the real `copilot --acp` server process. It does not proxy requests through a custom Express server.

Reference concept for Windows is in [start-acp.ps1](start-acp.ps1). Linux/container startup is implemented by [start-acp.sh](start-acp.sh).
Windows via WSL is supported by [start-acp-wsl.ps1](start-acp-wsl.ps1) and the same [start-acp.sh](start-acp.sh) bootstrap script.

## What starts in the container

Container entrypoint:

```bash
/usr/local/bin/start-acp.sh
```

That script launches:

```bash
copilot --acp --port <ACP_PORT> -C <ACP_WORKDIR> --agent <ACP_AGENT> --available-tools=<ACP_AVAILABLE_TOOLS> [--disallow-temp-dir] [--disable-builtin-mcps]
```

## Prerequisites

- Docker 24+ (for container workflows)
- Docker Compose v2

## Terminal Baseline (Match This VM)

To run with the same terminal behavior as this VM, use a Linux POSIX shell with plain/no-color output:

```bash
export TERM=dumb
export NO_COLOR=1
export BUILDKIT_PROGRESS=plain
```

Run project commands from `sh` (not PowerShell/cmd), for example:

```bash
sh -lc 'docker compose up -d --build'
sh -lc 'docker compose logs -f acp-server'
```

For in-container diagnostics, keep the same shell style:

```bash
sudo docker exec -i github-copilot-acp-container-server-acp-server-1 sh -lc 'copilot --version'
```

For native host run (without Docker), see Native Linux Run below.

## Native Windows via WSL

You can run the server natively on Windows through WSL instead of Docker.

Requirements:

- Windows 11 with WSL2 enabled
- A Linux distro installed in WSL (for example Ubuntu)
- Node.js and npm available inside WSL
- Git inside WSL
- `ripgrep`, `socat`, `util-linux`, and `expect` inside WSL
- GitHub Copilot CLI installed inside WSL: `sudo npm install -g @github/copilot@latest`

Quick start from Windows PowerShell:

```powershell
git clone https://github.com/cliffzhu/github-copilot-acp-container-server.git
cd github-copilot-acp-container-server
Copy-Item .env.example .env
.\start-acp-wsl.ps1
```

Or run the same project directly from inside WSL:

```bash
cd /path/to/github-copilot-acp-container-server
cp .env.example .env
./start-acp.sh
```

WSL notes:

- The startup script now reads a repo-local `.env` when present.
- If `/workspace` is not available, the startup script defaults `ACP_WORKDIR` to `<repo>/workspace`.
- Use `ACP_BIND_ALL_INTERFACES=false` for loopback-only mode, or `true` if you want the WSL process to bind publicly on the port.

## Native Linux Run (No Docker)

You can run the same startup script directly on a Linux host:

1. Install runtime dependencies:

```bash
# Debian/Ubuntu example
sudo apt-get update
sudo apt-get install -y ca-certificates git ripgrep socat util-linux expect
sudo npm install -g @github/copilot@latest
```

2. Prepare workspace and environment:

```bash
mkdir -p ./workspace
export ACP_WORKDIR="$PWD/workspace"
export ACP_PORT=3000
export ACP_AGENT=ACP-Chatbot
```

3. Start loopback-only mode (no socat required):

```bash
ACP_BIND_ALL_INTERFACES=false ./start-acp.sh
```

4. Start public-bind mode (requires socat):

```bash
ACP_BIND_ALL_INTERFACES=true ./start-acp.sh
```

Startup pre-checks now validate required commands and create `ACP_WORKDIR` if missing.

## Readable Build Output (PuTTY / Dark Consoles)

If Docker build output is hard to read (for example dark-blue BuildKit UI in PuTTY), use plain/no-color mode:

Linux/macOS:

BUILDKIT_PROGRESS=plain NO_COLOR=1 TERM=dumb docker compose build

Or use the repository helper script:

./build-plain.sh

Windows PowerShell:

$env:BUILDKIT_PROGRESS = "plain"
$env:NO_COLOR = "1"
docker compose build

## Install on Linux (from GitHub)

1. Install Docker Engine and Docker Compose plugin on your Linux host.

2. Clone this repository:

```bash
git clone https://github.com/cliffzhu/github-copilot-acp-container-server.git
cd github-copilot-acp-container-server
```

3. Create runtime folders used by bind mounts:

```bash
mkdir -p workspace copilot-home
```

4. Create environment file:

```bash
cp .env.example .env
```

5. Build and start the ACP container:

```bash
BUILDKIT_PROGRESS=plain NO_COLOR=1 TERM=dumb docker compose up -d --build
```

6. Watch startup logs and complete GitHub device authorization when prompted:

```bash
docker compose logs -f acp-server
```

7. Verify from the host:

```bash
./ask-acp.sh --question "Say your agent name in one sentence."
```

Expected outcome:

- ACP server reachable at `tcp://localhost:3000`
- Response succeeds without custom-agent-not-found errors

## Install on Windows (from GitHub)

1. Install Docker Desktop (with Docker Compose v2) and Git for Windows.

2. Open PowerShell and clone this repository:

```powershell
git clone https://github.com/cliffzhu/github-copilot-acp-container-server.git
cd github-copilot-acp-container-server
```

3. Create runtime folders used by bind mounts:

```powershell
New-Item -ItemType Directory -Force -Path workspace, copilot-home | Out-Null
```

4. Create environment file:

```powershell
Copy-Item .env.example .env
```

5. Build and start the ACP container:

```powershell
docker compose up -d --build
```

6. Watch startup logs and complete GitHub device authorization when prompted:

```powershell
docker compose logs -f acp-server
```

7. Verify from the host with the PowerShell client:

```powershell
./ask-acp.ps1 -Question "Say your agent name in one sentence."
```

Expected outcome:

- ACP server reachable at `tcp://localhost:3000`
- Response succeeds without custom-agent-not-found errors

## Quick start (container)

1. Create environment file:

```bash
cp .env.example .env
```

2. Optional: adjust `.env` values (agent name, tool allow-list, port).

3. Start the server:

```bash
mkdir -p workspace
docker compose up --build
```

4. ACP server will listen on:

```text
tcp://localhost:3000
```

## Upgrade / restart

After pulling latest changes from GitHub:

```bash
git pull
docker compose up -d --build
```

To stop services:

```bash
docker compose down
```

## Configuration

All runtime values are environment variables loaded from `.env`.

| Variable | Default | Description |
|---|---|---|
| `ACP_PORT` | `3000` | ACP TCP port passed to `copilot --acp`. |
| `ACP_AGENT` | `ACP-Chatbot` | Agent passed to `--agent`. |
| `ACP_WORKDIR` | `/workspace` | Working directory passed to `-C`. Created automatically at startup when missing. |
| `ACP_AVAILABLE_TOOLS` | `glob,rg,read_agent,list_agents,view,skill` | Explicit allow-list passed to `--available-tools`. |
| `ACP_DISALLOW_TEMP_DIR` | `true` | Adds `--disallow-temp-dir` when true. |
| `ACP_DISABLE_BUILTIN_MCPS` | `true` | Adds `--disable-builtin-mcps` when true. |
| `ACP_REQUIRE_LOGIN` | `true` | When true, container startup runs `copilot login` first, prints GitHub device-flow code/instructions, and starts ACP only after successful authorization. |
| `COPILOT_GITHUB_TOKEN` | _unset_ | Optional GitHub token auth, including fine-grained PATs with the required Copilot access. When set, startup skips device sign-in and uses the token instead. |
| `GH_TOKEN` | _unset_ | Optional GitHub token auth, including fine-grained PATs with the required Copilot access. Same behavior as `COPILOT_GITHUB_TOKEN`. |
| `GITHUB_TOKEN` | _unset_ | Optional GitHub token auth, including fine-grained PATs with the required Copilot access. Same behavior as `COPILOT_GITHUB_TOKEN`. |
| `ACP_LOGIN_STORE_PLAINTEXT` | `true` | Enables fallback automation for the plaintext token confirmation prompt in headless environments if direct login fails. |
| `ACP_LOGIN_USE_EXPECT` | `false` | Optional fallback path. When true, startup may use `expect` as a last resort after direct and `script` login attempts fail. |
| `ACP_COPILOT_SELF_HEAL` | `true` | On startup, runs a Copilot CLI health check and performs a one-time `@github/copilot` reinstall if the native binary fails to execute on that VM. |
| `ACP_BIND_ALL_INTERFACES` | `true` | When true, startup uses `socat` to open `0.0.0.0:$ACP_PORT` and forward to Copilot's loopback listener. |
| `ACP_INTERNAL_PORT` | `3001` | Internal loopback port used by Copilot when interface binding proxy mode is enabled. |
| `ACP_BOOTSTRAP_DEFAULT_AGENT` | `true` | When `ACP_AGENT=ACP-Chatbot`, startup writes a sample `ACP-Chatbot.agent.md` into `$ACP_WORKDIR/.github/agents/` if missing, so the custom agent is always available. |

Login output note:

- Startup forces plain terminal output (`TERM=dumb`, `NO_COLOR=1`) during `copilot login` so device-code instructions are more likely to be visible via `docker compose logs -f acp-server`.
- If any of `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or `GITHUB_TOKEN` is set, startup skips device sign-in and uses token-based auth instead. Fine-grained PATs work the same way as long as they have the required Copilot permissions.

Token auth and device sign-in also apply to WSL runs because the same `start-acp.sh` bootstrap is used there.

Example token auth setup:

```bash
export COPILOT_GITHUB_TOKEN="<your-token>"
./start-acp.sh
```

## Authentication Modes

The startup script supports two auth flows:

1. Device sign-in:

```bash
unset COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN
./start-acp.sh
```

2. Token sign-in:

```bash
export COPILOT_GITHUB_TOKEN="<your-token>"
./start-acp.sh
```

Token precedence:

- `COPILOT_GITHUB_TOKEN` is checked first.
- If it is unset, `GH_TOKEN` is checked next.
- If that is unset, `GITHUB_TOKEN` is checked last.
- Any of the three can be a fine-grained Personal Access Token, as long as it includes the required Copilot permissions.

## Windows concept script

[start-acp.ps1](start-acp.ps1) is the proof script for Windows local testing and uses the same conceptual server startup.

## Client script

[ask-acp.ps1](ask-acp.ps1) is a PowerShell ACP client that can initialize session, set agent, and send prompts.

Custom agent:

- `ACP-Chatbot` is the default startup/client agent.
- Startup also bootstraps `ACP-Chatbot` into `$ACP_WORKDIR/.github/agents/ACP-Chatbot.agent.md` when missing, using a sample system prompt.
- A repository sample template is included at [.github/agents/ACP-Chatbot.agent.md](.github/agents/ACP-Chatbot.agent.md).

Linux equivalent:

[ask-acp.sh](ask-acp.sh) provides the same ACP session flow for Linux/macOS shells.

Example:

```bash
./ask-acp.sh --question "What is the capital of France?"
```

## Build image only

```bash
docker build -t github-copilot-acp-container-server:local .
```

## Publish a standalone image on GitHub (GHCR)

This repository includes a publish workflow at [.github/workflows/publish-image.yml](.github/workflows/publish-image.yml).

What it does:

- Builds and pushes `ghcr.io/<owner>/<repo>` on every push to `main`
- Pushes version tags (for example `v1.0.0`) when you push git tags
- Maintains `latest` for the default branch

How to use it:

1. Ensure GitHub Actions is enabled for the repository.

2. Push to `main` (or push a version tag):

```bash
git checkout main
git pull
git tag v1.0.0
git push origin main --tags
```

3. Pull and run from GHCR on any host/platform:

```bash
docker pull ghcr.io/cliffzhu/github-copilot-acp-container-server:latest
```

## Deploy directly to serverless container apps

Use image:

```text
ghcr.io/cliffzhu/github-copilot-acp-container-server:latest
```

Minimum required environment variables:

- `ACP_PORT=3000`
- `ACP_BIND_ALL_INTERFACES=true`
- `ACP_WORKDIR=/workspace`
- `COPILOT_GITHUB_TOKEN=<your token>` (or `GH_TOKEN` / `GITHUB_TOKEN`)

Recommended variables for non-interactive serverless platforms:

- `ACP_REQUIRE_LOGIN=false`
- `ACP_LOGIN_STORE_PLAINTEXT=false`

Container port to expose:

- `3000`

Notes for serverless:

- The image now creates `/workspace` internally, so host volume mounts are optional.
- If your platform supports persistent volume mounts, mounting storage to `/workspace` and `/root/.copilot` can preserve runtime state between restarts.

### Azure Container Apps

Prerequisites:

- Azure CLI (`az`) installed
- Logged in: `az login`

Create resource group and Container Apps environment:

```bash
az group create --name <resource-group> --location <location>

az containerapp env create \
	--name <containerapp-env> \
	--resource-group <resource-group> \
	--location <location>
```

Deploy from GHCR image:

```bash
az containerapp create \
	--name <app-name> \
	--resource-group <resource-group> \
	--environment <containerapp-env> \
	--image ghcr.io/cliffzhu/github-copilot-acp-container-server:latest \
	--target-port 3000 \
	--ingress external \
	--env-vars ACP_PORT=3000 ACP_BIND_ALL_INTERFACES=true ACP_WORKDIR=/workspace ACP_REQUIRE_LOGIN=false ACP_LOGIN_STORE_PLAINTEXT=false \
	--secrets copilotToken=<your-copilot-token> \
	--env-vars COPILOT_GITHUB_TOKEN=secretref:copilotToken
```

Get app URL:

```bash
az containerapp show \
	--name <app-name> \
	--resource-group <resource-group> \
	--query properties.configuration.ingress.fqdn \
	-o tsv
```

### AWS App Runner (via ECR)

App Runner works best with ECR images. Mirror GHCR image into ECR, then deploy.

Prerequisites:

- AWS CLI configured (`aws configure`)
- Region selected (example uses `<region>`)

Create ECR repo and push image:

```bash
aws ecr create-repository --repository-name github-copilot-acp-container-server --region <region>

aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com

docker pull ghcr.io/cliffzhu/github-copilot-acp-container-server:latest
docker tag ghcr.io/cliffzhu/github-copilot-acp-container-server:latest <account-id>.dkr.ecr.<region>.amazonaws.com/github-copilot-acp-container-server:latest
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/github-copilot-acp-container-server:latest
```

Create App Runner service:

```bash
aws apprunner create-service \
	--service-name github-copilot-acp-container-server \
	--region <region> \
	--source-configuration '{
		"AuthenticationConfiguration": {"AccessRoleArn": "<apprunner-ecr-access-role-arn>"},
		"ImageRepository": {
			"ImageIdentifier": "<account-id>.dkr.ecr.<region>.amazonaws.com/github-copilot-acp-container-server:latest",
			"ImageRepositoryType": "ECR",
			"ImageConfiguration": {
				"Port": "3000",
				"RuntimeEnvironmentVariables": {
					"ACP_PORT": "3000",
					"ACP_BIND_ALL_INTERFACES": "true",
					"ACP_WORKDIR": "/workspace",
					"ACP_REQUIRE_LOGIN": "false",
					"ACP_LOGIN_STORE_PLAINTEXT": "false"
				},
				"RuntimeEnvironmentSecrets": {
					"COPILOT_GITHUB_TOKEN": "<secrets-manager-or-ssm-arn>"
				}
			}
		},
		"AutoDeploymentsEnabled": true
	}'
```

Get service URL:

```bash
aws apprunner list-services --region <region>
```

## Notes

- The container installs `@github/copilot` and starts `copilot --acp` directly.
- Volume `./workspace:/workspace` is mounted by default and used as server working directory.
- Volume `./copilot-home:/root/.copilot` is mounted by default to persist Copilot login/session state across restarts.
- Port mapping in compose is `3000:3000`.

## License

MIT License. See [LICENSE](LICENSE).
