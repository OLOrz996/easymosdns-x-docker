# easymosdns-x Docker

这个仓库用于构建一个 Docker 镜像，在容器中集成：

- 最新 `mosdns-x`
- 官方 `easymosdns`

设计目标很简单：

1. 首次启动时自动初始化 `easymosdns`
2. 后续保留用户自己修改过的配置
3. 自动更新规则
4. 提供本地健康检查
5. 支持 GitHub Actions 自动校验构建，并在正式 tag 时推送到 Docker Hub
6. 支持将 Docker Hub 短描述与完整说明从仓库自动同步过去

## 最小使用方式

大多数情况下，你只需要关注两个环境变量：

- `TZ`
- `RULES_UPDATE_CRON`

当前 `docker-compose.yml` 默认行为是：

- `/etc/mosdns` 持久化
- 首次启动自动初始化 `easymosdns`
- 后续不覆盖用户配置
- `mosdns-x` 与 `easymosdns` 默认通过 CDN 下载
- 每天凌晨 `03:00` 自动更新规则
- 规则更新方式默认为 `cdn`
- 自带本地 DNS 健康检查

直接启动：

```bash
docker compose up -d
```

## 推荐 Compose

```yaml
services:
  easymosdns-x:
    build:
      context: .
      dockerfile: Dockerfile
    image: easymosdns-x-docker:latest
    container_name: easymosdns-x
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/usr/local/bin/healthcheck.sh"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    ports:
      - "53:53/udp"
      - "53:53/tcp"
      - "9080:9080/tcp"
    environment:
      TZ: Asia/Shanghai
      RULES_UPDATE_CRON: "0 3 * * *"
    volumes:
      - easymosdns-x-workdir:/etc/mosdns

volumes:
  easymosdns-x-workdir:
```

## 初始化策略

容器要求 `mosdns` 工作目录持久化挂载到 `/etc/mosdns`。

镜像会在该目录里写入隐藏初始化标记文件：

```bash
/etc/mosdns/.easymosdns-initialized
```

启动逻辑如下：

1. 如果 `/etc/mosdns` 没有持久化挂载，容器直接退出
2. 如果标记文件不存在，就通过 CDN 下载官方 `easymosdns`
3. 写入 `config.yaml`、`hosts.txt`、`ecs_*.txt` 和 `rules/`
4. 写入标记文件
5. 后续启动如果标记文件存在，就跳过初始化，避免覆盖用户修改

## 规则自动更新

容器默认会：

- 启动后先更新一次规则
- 运行中按计划自动更新规则

推荐直接使用标准 5 段 cron 表达式：

```bash
RULES_UPDATE_CRON="0 3 * * *"
```

如果你不想走 CDN，可以把：

```bash
RULES_UPDATE_MODE=cdn
```

改成：

```bash
RULES_UPDATE_MODE=direct
```

也可以设为：

```bash
RULES_UPDATE_MODE=none
```

## 启动资源下载

容器在首次启动时会下载：

- `mosdns-x` 二进制
- `easymosdns` 配置模板

默认会通过 CDN 拉取这些 GitHub 资源，更适合国内网络环境。

当前启动下载不再依赖 `api.github.com`，而是直接使用 GitHub release/archive 地址，更适合国内网络环境。

如果你想改回直连，可以设置：

```bash
BOOTSTRAP_DOWNLOAD_MODE=direct
```

## 健康检查

镜像内置了 `healthcheck`，逻辑分两层：

1. 检查 `mosdns` 进程是否存在
2. 对 `127.0.0.1:53` 发起一次 `localhost A` 查询，并要求返回 `127.0.0.1`

这样做的好处是：

- 不依赖外网
- 不依赖上游 DNS 是否暂时可达
- 能同时确认“进程还活着”和“本地解析功能正常”

健康检查脚本位于 `docker/healthcheck.sh`。

## GitHub Actions 构建并推送 Docker Hub

仓库已经带了 workflow：

- `.github/workflows/docker-publish.yml`

它会在以下场景自动运行：

- push 到 `main`
- push `v*` 标签
- 手动触发 `workflow_dispatch`

其中：

- `main` 和手动触发默认只做构建校验，不推送 Docker Hub
- 只有 `v*` 标签会正式推送镜像并同步 Docker Hub 描述

### 最小配置

workflow 现在采用最小配置，镜像名直接写死为：

```text
olorz/easymosdns-x-docker
```

所以 GitHub 仓库里只需要配置 2 个 `Repository secrets`：

`DOCKERHUB_USERNAME`
: Docker Hub 用户名

`DOCKERHUB_TOKEN`
: Docker Hub Access Token

不再需要额外配置：

- `DOCKERHUB_NAMESPACE`
- `DOCKERHUB_IMAGE`

此外，Docker Hub 的说明文字现在也支持从仓库自动同步：

- 短描述：`dockerhub/short-description.txt`
- 完整说明：仓库根目录 `README.md`

### 推送标签策略

正式发布时，workflow 会推送这些标签：

- `latest`
  跟随最新正式版本更新
- `vX.Y.Z`
  例如推送 Git 标签 `v1.0.0` 时生成 `v1.0.0`
- `X.Y`
  例如推送 Git 标签 `v1.0.0` 时，同时生成 `1.0`

### 多架构

workflow 默认构建：

- `linux/amd64`
- `linux/arm64`

### 描述同步失败时的表现

workflow 会把“构建校验”和“正式发布”分开总结：

- 非 tag 运行时，只显示校验构建成功，Docker Hub 推送会被跳过
- tag 发布时，如果镜像推送成功，但描述同步失败
- Actions Summary 会明确提示是描述同步失败
- job 也会在最后显式失败，方便第一时间发现问题

## 更安全的重初始化方式

如果你想恢复官方默认配置，不推荐手工删除标记文件。

可以临时设置：

```bash
FORCE_REINIT=true
```

重初始化前默认会自动备份当前配置，备份目录类似：

```bash
/etc/mosdns/.backup-20260627T123456Z
```

## 高级环境变量

下面这些变量仍然支持，但普通使用场景通常不需要改：

`FORCE_REINIT`
: 强制重新初始化 `easymosdns`

`BACKUP_ON_REINIT`
: 重初始化前是否自动备份

`MOSDNS_X_REF`
: 固定 `mosdns-x` 版本

`EASYMOSDNS_REF`
: 固定 `easymosdns` 版本

`BOOTSTRAP_DOWNLOAD_MODE`
: 控制 `mosdns-x` 与 `easymosdns` 下载方式，支持 `cdn` 或 `direct`

`RULES_UPDATE_TIME`
: 用每天固定时间更新规则，例如 `03:00`

`RULES_UPDATE_INTERVAL`
: 用固定间隔更新规则

`GITHUB_TOKEN`
: 在 `BOOTSTRAP_DOWNLOAD_MODE=direct` 时用于访问 GitHub，默认 CDN 模式不会使用它

## 运行示例

普通运行：

```bash
docker run -d \
  --name easymosdns-x \
  -p 53:53/udp \
  -p 53:53/tcp \
  -p 9080:9080/tcp \
  -v easymosdns-x-data:/etc/mosdns \
  -e TZ=Asia/Shanghai \
  -e RULES_UPDATE_CRON="0 3 * * *" \
  olorz/easymosdns-x-docker:latest
```

强制重初始化：

```bash
docker run -d \
  --name easymosdns-x \
  -p 53:53/udp \
  -p 53:53/tcp \
  -p 9080:9080/tcp \
  -v easymosdns-x-data:/etc/mosdns \
  -e FORCE_REINIT=true \
  olorz/easymosdns-x-docker:latest
```

## 注意事项

- 当前镜像默认面向常见 Linux 架构自动选择 `mosdns-x` 二进制
- `RULES_UPDATE_CRON` 使用容器内 `TZ` 时区
- `easymosdns` 初始化后，后续不会自动升级配置模板，除非显式开启 `FORCE_REINIT=true`
