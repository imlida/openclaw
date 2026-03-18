# OpenClaw 统一容器部署方案

本目录包含 OpenClaw 的完整容器化部署解决方案，支持多种容器运行时。

## 支持的容器运行时

| 运行时 | 说明 | 适用场景 |
|--------|------|----------|
| Docker | 标准 Docker 部署 | 大多数用户 |
| DinD | Docker-in-Docker | 需要完全隔离沙盒的环境 |
| Podman | Rootless 容器 | 更注重安全的用户 |
| Apple Container | Apple 原生容器 | macOS 用户 |

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

# Apple Container (macOS)
./deploy/unified-compose.sh --apple-container setup
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
| `setup-apple-container.sh` | Apple Container 专用脚本 |
| `Dockerfile.dind` | DinD 版本 Dockerfile |
| `docker-compose.dind.yml` | DinD 版本 Compose 配置 |
| `dind-entrypoint.sh` | DinD 容器入口脚本 |
| `.env.example` | 环境变量示例 |

## 与主仓库的关系

- 本目录独立于主仓库代码
- 通过相对路径引用主仓库 Dockerfile
- 构建时以仓库根目录为 context
- 不修改主仓库任何文件

## 更多文档

- [Docker 部署](../../docs/install/docker.md)
- [Podman 部署](../../docs/install/podman.md)
- [主仓库 README](../../README.md)
