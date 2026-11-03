#!/bin/sh
# 早八 zaoba · 容器入口
# 职责:
#   1. 把所有可变状态（config.json / data/）软链到 /data，配合 volume 持久化
#   2. 启动 Web 控制台（0.0.0.0:7788）
#   3. 启动内置定时器（替代 macOS launchd / Windows 计划任务）
set -e

APP=/app
DATA=/data

# /data 可写检查（绑定挂载宿主机目录时常见权限问题，给出明确指引而不是无限重启）
if ! mkdir -p "$DATA/data" "$DATA/profile" 2>/dev/null; then
  echo "[entrypoint] ❌ 无法写入 /data（权限不足）"
  echo "[entrypoint] 若你把宿主机目录挂载到 /data，请在宿主机执行："
  echo "[entrypoint]   chown -R 1000:1000 <挂载的宿主机目录>"
  echo "[entrypoint] （容器内以 uid 1000 的 node 用户运行）"
  exit 1
fi

# config.json: 不存在则生成默认配置（软链进 /app，改配置即落盘到 /data）
if [ ! -f "$DATA/config.json" ]; then
  if [ -f "$APP/config.example.json" ]; then
    cp "$APP/config.example.json" "$DATA/config.json"
    echo "[entrypoint] 已从示例生成 /data/config.json"
  fi
fi
ln -sf "$DATA/config.json" "$APP/config.json"

# 若上一步没有示例可复制，用程序生成完整默认配置
node -e "import('$APP/src/config.js').then(m => m.loadConfig()).catch(e => { console.error(e.message); process.exit(0); })" || true

# data/（报表 / 日志 / 截图）也放进 /data
ln -sfn "$DATA/data" "$APP/data"

# 由 scheduler 统一拉起 Web 控制台并管理子进程（保证 docker stop 时一起退出）
echo "[entrypoint] 启动 zaoba（Web 控制台 + 内置定时器）"
exec node "$APP/docker/scheduler.js"
