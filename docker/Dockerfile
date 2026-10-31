# Isolated, disposable machine to run loop-kit (see docs/isolation.md).
#   docker build -f docker/Dockerfile -t loop-kit .
#   docker run -d --name myapp -v loopkit-home:/home/loop -v "$PWD/myapp:/work" -p 8090:8090 -p 3000:3000 loop-kit
#   docker exec -it myapp bash          # then: claude (log in once), loopkit init /work, plan, run
FROM debian:trixie-slim

ARG NODE_MAJOR=22
ARG PLAYWRIGHT=1
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq tmux python3 procps less nano unzip build-essential util-linux \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && if [ "$PLAYWRIGHT" = 1 ]; then npx -y playwright install-deps chromium; fi \
    && rm -rf /var/lib/apt/lists/* /root/.npm

COPY . /opt/loop-kit
RUN ln -s /opt/loop-kit/loopkit /usr/local/bin/loopkit \
    && useradd -m -s /bin/bash loop && mkdir -p /work && chown loop: /work

USER loop
WORKDIR /work
RUN git config --global user.name loop && git config --global user.email loop@localhost \
    && git config --global --add safe.directory '*'
# Keeps the container alive; you work inside it with docker exec
CMD ["sleep", "infinity"]
