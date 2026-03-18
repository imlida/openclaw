# OpenClaw 统一容器部署方案

本目录包含 OpenClaw 的完整容器化部署解决方案，支持多种容器运行时。

## 支持的容器运行时

| 运行时 | 说明 | 适用场景 |
|--------|------|----------|
| Docker | 标准 Docker 部署 | 大多数用户 |
| DinD | Docker-in-Docker | 需要完全隔离沙盒的环境 |
| Podman | Rootless 容器 | 更注重安全的用户 |
| Apple Container | Apple 原生容器 (macOS) | 需要开机自启和进程守护的 macOS 用户 |

## 快速开始

### 一键部署（自动检测运行时）

```bash
./deploy/unified-compose.sh setup
```

### 指定运行时部署

```bash
# Docker (默认)
./deploy/unified-compose.sh --docker setup

# Docker-in-Docker
./deploy/unified-compose.sh --dind setup

# Podman
./deploy/unified-compose.sh --podman setup

# Apple Container (macOS) - 基础部署
./deploy/unified-compose.sh --apple-container setup

# Apple Container (macOS) - 带开机自启
./deploy/unified-compose.sh --apple-container install
```

### 自定义依赖包

```bash
# 安装额外的系统包
export OPENCLAW_DOCKER_APT_PACKAGES="ffmpeg curl jq"
./deploy/unified-compose.sh --dind setup
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `unified-compose.sh` | 统一入口脚本，支持所有运行时 |
| `setup-dind.sh` | DinD 专用设置脚本 |
| `setup-apple-container.sh` | Apple Container 专用脚本（含自启和守护功能） |
| `apple-container-daemon.sh` | Apple Container 守护进程脚本（监控和自动重启） |
| `Dockerfile.dind` | DinD 版本 Dockerfile |
| `docker-compose.dind.yml` | DinD 版本 Compose 配置 |
| `dind-entrypoint.sh` | DinD 容器入口脚本 |
| `.env.example` | 环境变量示例 |

## 与主仓库的关系

- 本目录独立于主仓库代码
- 通过相对路径引用主仓库 Dockerfile
- 构建时以仓库根目录为 context
- 不修改主仓库任何文件

## Apple Container 详细说明 (macOS)

Apple Container 部署方案专为 macOS 设计，提供以下特性：

### 功能特性

- **开机自启**：使用 macOS LaunchAgent，登录时自动启动服务
- **进程守护**：自动监控容器健康状态，异常退出时自动重启
- **健康检查**：定期检测 Gateway 健康状态，失败时触发重启
- **日志记录**：详细的守护进程和容器日志记录
- **速率限制**：智能重启策略，避免频繁重启

### 管理命令

```bash
# 安装并启用开机自启
./deploy/unified-compose.sh --apple-container install

# 启动服务
./deploy/unified-compose.sh --apple-container start

# 停止服务
./deploy/unified-compose.sh --apple-container stop

# 重启服务
./deploy/unified-compose.sh --apple-container restart

# 查看状态
./deploy/unified-compose.sh --apple-container status

# 查看日志
./deploy/unified-compose.sh --apple-container logs

# 卸载自启配置（数据保留）
./deploy/unified-compose.sh --apple-container uninstall
```

### 文件说明

| 文件 | 说明 |
|------|------|
| `setup-apple-container.sh` | Apple Container 专用设置脚本，支持自启和守护 |
| `apple-container-daemon.sh` | 守护进程脚本，负责监控和自动重启 |
| `~/Library/LaunchAgents/ai.openclaw.gateway.plist` | LaunchAgent 配置文件（自动生成） |
| `~/.openclaw/logs/` | 日志目录（包含守护进程和容器日志） |

### LaunchAgent 配置

安装后，系统会创建一个 LaunchAgent 服务：

```bash
# 查看服务状态
launchctl list | grep openclaw

# 手动加载
launchctl load ~/Library/LaunchAgents/ai.openclaw.gateway.plist

# 手动卸载
launchctl unload ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

### 环境变量

```bash
# 自定义配置示例
export OPENCLAW_GATEWAY_PORT=8080
export OPENCLAW_GATEWAY_BIND=loopback
export OPENCLAW_CONTAINER_NAME=my-openclaw
export OPENCLAW_HEALTH_INTERVAL=60
export OPENCLAW_MAX_RESTART=10

./deploy/unified-compose.sh --apple-container install
```

## 更多文档

- [Docker 部署](../../docs/install/docker.md)
- [Podman 部署](../../docs/install/podman.md)
- [主仓库 README](../../README.md)
