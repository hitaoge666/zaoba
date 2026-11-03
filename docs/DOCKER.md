# 早八 zaoba · Docker 部署指南

把「早八」打包成 Docker 镜像，跑在 NAS / 家庭服务器 / 任意 Linux 主机上，不依赖 macOS launchd 或 Windows 计划任务——镜像内置了定时器和 Web 控制台。

## 镜像地址

| 仓库 | 地址 | 说明 |
| --- | --- | --- |
| **Docker Hub** | `hitaoge/zaoba` | 国内拉取推荐 |
| GitHub GHCR | `ghcr.io/hitaoge666/zaoba` | 与 Docker Hub 内容完全相同 |

标签规则：`latest`（最新稳定）、`main`（main 分支构建）、`sha-xxxxxxx`（具体提交）。

> 本仓库每天北京时间 09:30 自动检查上游 [BorisSun0424-boop/zaoba](https://github.com/BorisSun0424-boop/zaoba) 更新并合并重建镜像，`latest` 始终与上游保持同步（合并冲突时会自动开 issue 提醒，在 Actions 页面也可随时手动触发检查）。

## ⚠️ 先看：容器里能跑哪些平台

| 类型 | 平台 | 容器内可用 |
| --- | --- | --- |
| 网页类 | 智谱清言、MiniMax Code | ✅ 可用（需登录态，见下文） |
| 客户端类 | WorkBuddy、豆包工作、Trae CN、Qoder CN | ❌ **不可用**（需要桌面客户端 + CDP 接管，容器里没有 GUI 和客户端） |

客户端类平台请在配置里保持停用（默认即停用，无需处理）。

## 快速开始

### 方式 A：直接拉现成镜像（推荐）

```bash
docker pull hitaoge/zaoba:latest
docker run -d --name zaoba -p 7788:7788 -v zaoba-data:/data -e TZ=Asia/Shanghai --restart unless-stopped hitaoge/zaoba:latest
```

### 方式 B：从源码自己构建

```bash
git clone https://github.com/hitaoge666/zaoba.git
cd zaoba
docker compose up -d --build
```

打开控制台：`http://<宿主机IP>:7788`（本机即 `http://localhost:7788`）。

镜像做的事：

- 启动 Web 控制台（监听 `0.0.0.0:7788`）
- 启动内置定时器：按 `config.json` 的 `schedule`（默认主跑 `08:00`、补跑 `12:30`、随机延迟 0~5 分钟）自动执行签到
- 容器晚于计划时间启动时**自动补跑**（当天已签过的平台会跳过，幂等）
- 所有可变状态（登录态 / `config.json` / 报表 / 日志）都在 `/data`，挂 volume 即可持久化

## 登录态怎么进容器（关键一步）

容器里没有图形界面，`npm run login` 打不开浏览器窗口。两种办法：

### 办法一：在宿主机登录一次，再把登录态拷进容器（推荐）

```bash
# 1. 宿主机上装一份并登录（只需做这一次）
#    macOS / Linux:  ~/.zaoba/profile
#    Windows:        %USERPROFILE%\.zaoba\profile

# 2. 拷进容器（container_name 默认 zaoba）
docker cp ~/.zaoba/profile/. zaoba:/data/profile/

# 3. 验证登录态
docker exec -it zaoba node src/index.js dry-run
```

### 办法二：直接挂载宿主机的登录态目录

`docker-compose.yml` 里改用绑定挂载：

```yaml
    volumes:
      - ./docker-data:/data          # 配置、报表等
      # macOS / Linux 宿主机:
      - ~/.zaoba/profile:/data/profile
      # Windows 宿主机 (Docker Desktop):
      # - C:\Users\<你>\.zaoba\profile:/data/profile
```

> ⚠️ **不要让宿主机和容器同时跑同一份 profile**：Chromium 用户数据目录有单实例锁，两边同时签到会互相冲突。选一边跑。

## 常用操作

```bash
docker compose up -d --build      # 构建 + 启动
docker compose logs -f            # 看实时日志
docker exec -it zaoba node src/index.js dry-run    # 演练（不真签）
docker exec -it zaoba node src/index.js run --skip-if-done   # 手动签一次
docker exec -it zaoba node src/index.js report     # 看今日日报
docker exec -it zaoba node src/auth-check.js       # 登录态自检
docker compose down               # 停止
```

修改运行时间：直接在 Web 控制台右上角改（立即生效，容器内定时器每 30 秒读一次配置），或改 `/data/config.json` 的 `schedule` 字段。

## 数据目录结构

```
/data
├── config.json          # 配置（Web 控制台的修改都落在这里）
├── profile/             # Playwright 登录态（cookie 等）
├── data/                # 报表 / 日志 / 截图 / 运行记录
└── scheduler-state.json # 内置定时器的"今天跑没跑"状态
```

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 时区，直接影响定时执行的判断 |
| `ZAOBA_PORT` | `7788` | 容器内监听端口 |
| `CHECKIN_ONLY` | — | 只跑指定平台，如 `zhipu,minimax` |
| `CHECKIN_NO_DELAY` | — | 设为 `1` 关闭随机延迟 |
| `CHECKIN_DRY_RUN` | — | 设为 `1` 演练模式 |

## 备份 / 迁移

```bash
# 备份
docker run --rm -v zaoba-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/zaoba-data.tgz -C /data .

# 恢复
docker run --rm -v zaoba-data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/zaoba-data.tgz -C /data
```

## 已知限制

1. **客户端类平台不可用**（见开头表格）——这是产品形态决定的，不是 bug。
2. **Linux 宿主机绑定挂载 `/data` 时注意权限**：容器内以 uid 1000（镜像自带 `node` 用户）运行，宿主机目录需要 `chown -R 1000:1000`，或直接用命名卷。
3. 智谱清言会话有效期较短，失效后在宿主机重新 `npm run login` 并同步 profile 即可。
4. 镜像约 1.5~1.8GB（含 Chromium 及其系统依赖）。
