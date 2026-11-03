# 早八 zaoba · Docker 镜像
# 构建:  docker build -t zaoba:latest .
# 运行:  见 docker-compose.yml 或 docs/DOCKER.md
#
# 说明:
# - 容器内只支持「网页类」平台（智谱清言 / MiniMax Code 等）。
#   WorkBuddy / 豆包工作 / Trae / Qoder 等「客户端类」平台需要桌面客户端，容器内不可用。
# - 登录态、配置、报表统一放在 /data（建议挂 volume 持久化）。
# - 镜像内非 root 运行，Playwright Chromium 沙箱可正常工作。

FROM node:20-bookworm-slim

ENV TZ=Asia/Shanghai \
    ZAOBA_PROFILE=/data/profile \
    ZAOBA_HOST=0.0.0.0 \
    ZAOBA_PORT=7788 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    DEBIAN_FRONTEND=noninteractive

# 时区数据 + 最小工具集（tini: 回收 Chromium 僵尸进程）
RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 先装依赖（利用层缓存），再装 Chromium 及其系统库
COPY package.json package-lock.json ./
RUN npm ci \
    && npx playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# 应用代码
COPY src ./src
COPY web ./web
COPY config.example.json ./
COPY docker ./docker

# 非 root 用户（Chromium 沙箱需要）——直接用镜像自带的 node 用户（uid 1000）
RUN mkdir -p /data/profile \
    && chown -R node:node /app /data

USER node
WORKDIR /app

VOLUME /data
EXPOSE 7788

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:7788/api/state').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/app/docker/entrypoint.sh"]
