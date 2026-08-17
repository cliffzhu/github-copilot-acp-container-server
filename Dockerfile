FROM node:20-bookworm-slim

WORKDIR /app

# Tools used by Copilot's allowed toolset and local repository workflows.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates cron expect git ripgrep rsync socat \
	&& rm -rf /var/lib/apt/lists/*

COPY ws-adapter/package.json /app/ws-adapter/package.json
RUN cd /app/ws-adapter && npm install --omit=dev

COPY ws-adapter/adapter.js /app/ws-adapter/adapter.js
COPY ws-adapter/ask-websocket.js /app/ws-adapter/ask-websocket.js

RUN npm install -g @github/copilot@latest

RUN mkdir -p /workspace

# Bake the local document library (workspace/) into the image so deployments
# without an external ACP_WORKDIR_DOC_SOURCE mount still ship with docs.
# Runtime-managed agent files (.github/) are excluded; those are synced by
# bootstrap_default_agent in start-acp.sh instead.
COPY workspace/ /opt/acp-library/
RUN rm -rf /opt/acp-library/.github /opt/acp-library/.gitkeep

COPY start-acp.sh /usr/local/bin/start-acp.sh
COPY ACP-Chatbot.agent.md /usr/local/bin/ACP-Chatbot.agent.md
RUN chmod +x /usr/local/bin/start-acp.sh

EXPOSE 3000
EXPOSE 8080

CMD ["/usr/local/bin/start-acp.sh"]
