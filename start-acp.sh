#!/usr/bin/env sh
set -eu

ACP_PORT="${ACP_PORT:-3000}"
ACP_AGENT="${ACP_AGENT:-ACP-Chatbot}"
ACP_WORKDIR="${ACP_WORKDIR:-/workspace}"
ACP_AVAILABLE_TOOLS="${ACP_AVAILABLE_TOOLS:-glob,rg,read_agent,list_agents,view,skill}"
ACP_DISALLOW_TEMP_DIR="${ACP_DISALLOW_TEMP_DIR:-true}"
ACP_DISABLE_BUILTIN_MCPS="${ACP_DISABLE_BUILTIN_MCPS:-true}"
ACP_REQUIRE_LOGIN="${ACP_REQUIRE_LOGIN:-true}"
ACP_LOGIN_STORE_PLAINTEXT="${ACP_LOGIN_STORE_PLAINTEXT:-true}"
ACP_LOGIN_USE_EXPECT="${ACP_LOGIN_USE_EXPECT:-false}"
ACP_COPILOT_SELF_HEAL="${ACP_COPILOT_SELF_HEAL:-true}"
ACP_BIND_ALL_INTERFACES="${ACP_BIND_ALL_INTERFACES:-true}"
ACP_INTERNAL_PORT="${ACP_INTERNAL_PORT:-3001}"
ACP_BOOTSTRAP_DEFAULT_AGENT="${ACP_BOOTSTRAP_DEFAULT_AGENT:-true}"

if ! command -v copilot >/dev/null 2>&1; then
  echo "copilot command not found. Ensure @github/copilot is installed." >&2
  exit 1
fi

# Guard to avoid repeated npm reinstall attempts during auth retry loops.
COPILOT_SELF_HEAL_ATTEMPTED=0

require_command() {
  cmd="$1"
  hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    echo "$hint" >&2
    return 1
  fi
}

ensure_workdir_ready() {
  if [ ! -d "$ACP_WORKDIR" ]; then
    echo "ACP working directory does not exist. Creating: $ACP_WORKDIR"
    if ! mkdir -p "$ACP_WORKDIR"; then
      echo "Failed to create ACP working directory: $ACP_WORKDIR" >&2
      return 1
    fi
  fi

  if [ ! -w "$ACP_WORKDIR" ]; then
    echo "ACP working directory is not writable: $ACP_WORKDIR" >&2
    return 1
  fi
}

preflight_startup() {
  require_command node "Install Node.js (required by Copilot CLI wrapper)." || return 1
  ensure_workdir_ready || return 1

  if [ "$ACP_BIND_ALL_INTERFACES" = "true" ]; then
    require_command socat "Install socat or set ACP_BIND_ALL_INTERFACES=false for loopback-only mode." || return 1
  fi

  if [ "$ACP_COPILOT_SELF_HEAL" = "true" ] && ! command -v npm >/dev/null 2>&1; then
    echo "npm is not available; disabling ACP_COPILOT_SELF_HEAL for this run." >&2
    ACP_COPILOT_SELF_HEAL=false
  fi

  if [ "$ACP_LOGIN_STORE_PLAINTEXT" = "true" ] && ! command -v script >/dev/null 2>&1; then
    echo "Info: 'script' command not found; plaintext-prompt automation fallback is unavailable." >&2
  fi
}

has_auth_token_env() {
  [ -n "${COPILOT_GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]
}

is_copilot_authenticated() {
  copilot -p "Reply with OK only." --allow-all-tools --output-format json >/dev/null 2>&1
}

copilot_arch_package() {
  case "$(node -p 'process.arch' 2>/dev/null || echo unknown)" in
    x64)
      echo "@github/copilot-linux-x64"
      ;;
    arm64)
      echo "@github/copilot-linux-arm64"
      ;;
    *)
      echo ""
      ;;
  esac
}

copilot_native_binary_path() {
  pkg="$(copilot_arch_package)"
  if [ -z "$pkg" ]; then
    echo ""
    return 0
  fi
  echo "/usr/local/lib/node_modules/@github/copilot/node_modules/${pkg}/copilot"
}

copilot_cli_healthy() {
  if ! copilot --version >/dev/null 2>&1; then
    return 1
  fi

  native_bin="$(copilot_native_binary_path)"
  if [ -n "$native_bin" ] && [ -x "$native_bin" ]; then
    "$native_bin" --version >/dev/null 2>&1 || return 1
  fi

  return 0
}

repair_copilot_cli() {
  echo "Attempting one-time Copilot CLI self-heal reinstall..."
  npm uninstall -g @github/copilot >/dev/null 2>&1 || true
  npm install -g @github/copilot@latest >/dev/null 2>&1
}

ensure_copilot_cli_healthy() {
  if copilot_cli_healthy; then
    return 0
  fi

  echo "Copilot CLI health check failed (uname -m: $(uname -m), node arch: $(node -p 'process.arch' 2>/dev/null || echo unknown))." >&2

  if [ "$ACP_COPILOT_SELF_HEAL" = "true" ] && [ "$COPILOT_SELF_HEAL_ATTEMPTED" -eq 0 ]; then
    COPILOT_SELF_HEAL_ATTEMPTED=1
    if repair_copilot_cli && copilot_cli_healthy; then
      echo "Copilot CLI self-heal succeeded."
      return 0
    fi
  fi

  echo "Copilot CLI is unhealthy. If this persists on this VM, rebuild image with no cache and recreate container." >&2
  return 1
}

copilot_login_plain() {
  env TERM=dumb NO_COLOR=1 copilot login
}

attempt_copilot_login() {
  # Prefer direct login to keep device-code output intact and avoid TTY shim issues.
  echo "Attempting direct copilot login..."

  if ! ensure_copilot_cli_healthy; then
    echo "Copilot CLI health check failed; aborting login attempts." >&2
    exit 1
  fi

  if copilot_login_plain; then
    return 0
  fi

  echo "direct login attempt failed; trying fallback methods..."

  if [ "$ACP_LOGIN_STORE_PLAINTEXT" = "true" ] && command -v script >/dev/null 2>&1; then
    echo "Attempting copilot login via script..."
    if printf 'y\n' | script -q -c "env TERM=dumb NO_COLOR=1 copilot login" /dev/null; then
      return 0
    fi
    echo "script login attempt failed."
  fi

  if [ "$ACP_LOGIN_USE_EXPECT" = "true" ] && [ "$ACP_LOGIN_STORE_PLAINTEXT" = "true" ] && command -v expect >/dev/null 2>&1; then
    echo "Attempting copilot login via expect..."
    if expect <<'EOF'
set timeout -1
log_user 1
spawn env TERM=dumb NO_COLOR=1 copilot login
expect {
  -re {System keychain unavailable\. Store token in plaintext config file\? \(y/N\)} {
    send -- "y\r"
    exp_continue
  }
  eof
}
set status [lindex [wait] 3]
exit $status
EOF
    then
      return 0
    fi
    echo "expect login attempt failed."
  fi

  return 1
}

ensure_copilot_auth() {
  if has_auth_token_env; then
    echo "Copilot auth token found in environment."
    return 0
  fi

  if is_copilot_authenticated; then
    echo "Copilot is already authenticated."
    return 0
  fi

  echo "Copilot login is required before starting ACP server."
  echo "A device code and URL will be shown below."
  echo "Complete authorization in your browser, then ACP startup will continue."

  while true; do
    # This command prints GitHub device-flow instructions and waits for completion.
    # In headless containers, Copilot may ask whether plaintext credential storage is allowed.
    if attempt_copilot_login; then
      if is_copilot_authenticated; then
        echo "Copilot authentication successful."
        return 0
      fi
    fi

    echo "Login is not complete yet. Retrying in 5 seconds..."
    sleep 5
  done
}

bootstrap_default_agent() {
  if [ "$ACP_BOOTSTRAP_DEFAULT_AGENT" != "true" ]; then
    return 0
  fi

  if [ "$ACP_AGENT" != "ACP-Chatbot" ]; then
    return 0
  fi

  AGENT_DIR="$ACP_WORKDIR/.github/agents"
  AGENT_FILE="$AGENT_DIR/ACP-Chatbot.agent.md"

  mkdir -p "$AGENT_DIR"

  if [ -f "$AGENT_FILE" ]; then
    return 0
  fi

  cat > "$AGENT_FILE" <<'EOF'
---
name: ACP-Chatbot
description: Use for ACP container server testing, generic Q&A, and repository-aware assistance.
---
You are ACP-Chatbot, a practical assistant for ACP server sessions.

Behavior:
- Give concise, accurate answers first.
- Ask clarifying questions only when necessary.
- Prefer actionable guidance with runnable commands.
- When debugging, explain likely cause and quickest verification step.

Runtime context:
- ACP server port is 3000 unless configured otherwise.
- ACP working directory is /workspace by default.
- Focus on repository-aware answers when files are available.
EOF

  echo "Bootstrapped default custom agent at: $AGENT_FILE"
}

echo "Starting Copilot ACP server"
echo "Working directory: $ACP_WORKDIR"
echo "Port: $ACP_PORT"
echo "Agent: $ACP_AGENT"
echo "Available tools: $ACP_AVAILABLE_TOOLS"

if ! preflight_startup; then
  exit 1
fi

if [ "$ACP_BIND_ALL_INTERFACES" = "true" ]; then
  echo "Public bind mode: enabled (0.0.0.0:$ACP_PORT -> 127.0.0.1:$ACP_INTERNAL_PORT)"
else
  echo "Public bind mode: disabled (Copilot listens directly on 127.0.0.1:$ACP_PORT)"
fi

if [ "$ACP_REQUIRE_LOGIN" = "true" ]; then
  ensure_copilot_auth
fi

bootstrap_default_agent

COPILOT_PORT="$ACP_PORT"
if [ "$ACP_BIND_ALL_INTERFACES" = "true" ]; then
  COPILOT_PORT="$ACP_INTERNAL_PORT"
fi

set -- copilot --acp --port "$COPILOT_PORT" -C "$ACP_WORKDIR" --agent "$ACP_AGENT" --available-tools="$ACP_AVAILABLE_TOOLS"

if [ "$ACP_DISALLOW_TEMP_DIR" = "true" ]; then
  set -- "$@" --disallow-temp-dir
fi

if [ "$ACP_DISABLE_BUILTIN_MCPS" = "true" ]; then
  set -- "$@" --disable-builtin-mcps
fi

if [ "$ACP_BIND_ALL_INTERFACES" = "true" ]; then
  socat "TCP-LISTEN:${ACP_PORT},bind=0.0.0.0,reuseaddr,fork" "TCP:127.0.0.1:${COPILOT_PORT}" &
  SOCAT_PID=$!
  "$@" &
  COPILOT_PID=$!

  wait "$COPILOT_PID"
  EXIT_CODE=$?
  kill "$SOCAT_PID" 2>/dev/null || true
  wait "$SOCAT_PID" 2>/dev/null || true
  exit "$EXIT_CODE"
fi

exec "$@"
