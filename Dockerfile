FROM node:20-bookworm-slim

WORKDIR /app

# Tools used by Copilot's allowed toolset and local repository workflows.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates expect git ripgrep socat \
	&& rm -rf /var/lib/apt/lists/*

COPY ws-adapter/package.json /app/ws-adapter/package.json
RUN cd /app/ws-adapter && npm install --omit=dev

COPY ws-adapter/adapter.js /app/ws-adapter/adapter.js
COPY ws-adapter/ask-websocket.js /app/ws-adapter/ask-websocket.js

RUN npm install -g @github/copilot@latest

RUN mkdir -p /workspace

COPY start-acp.sh /usr/local/bin/start-acp.sh
COPY ACP-Chatbot.agent.md /usr/local/bin/ACP-Chatbot.agent.md
RUN chmod +x /usr/local/bin/start-acp.sh

EXPOSE 3000
EXPOSE 8080

CMD ["/usr/local/bin/start-acp.sh"]
