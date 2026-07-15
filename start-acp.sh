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
ACP_BIND_ALL_INTERFACES="${ACP_BIND_ALL_INTERFACES:-true}"
ACP_INTERNAL_PORT="${ACP_INTERNAL_PORT:-3001}"
ACP_BOOTSTRAP_DEFAULT_AGENT="${ACP_BOOTSTRAP_DEFAULT_AGENT:-true}"

if ! command -v copilot >/dev/null 2>&1; then
  echo "copilot command not found. Ensure @github/copilot is installed." >&2
  exit 1
fi

if [ ! -d "$ACP_WORKDIR" ]; then
  echo "ACP working directory does not exist: $ACP_WORKDIR" >&2
  exit 1
fi

has_auth_token_env() {
  [ -n "${COPILOT_GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]
}

is_copilot_authenticated() {
  copilot -p "Reply with OK only." --allow-all-tools --output-format json >/dev/null 2>&1
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
    if [ "$ACP_LOGIN_STORE_PLAINTEXT" = "true" ] && command -v expect >/dev/null 2>&1; then
      if expect <<'EOF'
set timeout -1
log_user 1
spawn copilot login
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
        if is_copilot_authenticated; then
          echo "Copilot authentication successful."
          return 0
        fi
      fi
    elif [ "$ACP_LOGIN_STORE_PLAINTEXT" = "true" ] && command -v script >/dev/null 2>&1; then
      if printf 'y\n' | script -q -c "copilot login" /dev/null; then
        if is_copilot_authenticated; then
          echo "Copilot authentication successful."
          return 0
        fi
      fi
    elif copilot login; then
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
