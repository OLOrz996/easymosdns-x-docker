# easymosdns-x Docker

这个仓库用于构建一个 Docker 镜像，在容器中集成：

- 最新 `mosdns-x`
- 官方 `easymosdns`

设计目标很简单：

1. 第一次启动时自动初始化 `easymosdns`
2. 后续保留用户自己修改过的配置
3. 自动更新规则
4. 提供本地健康检查

## 最小使用方式

大多数情况下，你只需要这两个可选环境变量：

- `TZ`
- `RULES_UPDATE_CRON`

当前 [docker-compose.yml](C:/Users/john2/Documents/repo/easymosdns-v5/docker-compose.yml) 默认行为是：

- `/etc/mosdns` 持久化
- 首次启动自动初始化 `easymosdns`
- 后续不覆盖用户配置
- 每天凌晨 `03:00` 自动更新规则
- 规则更新方式默认走 `cdn`
- 自带本地 DNS 健康检查

直接启动：

```bash
docker compose up -d
```

## 推荐 Compose

```yaml
services:
  easymosdns:
    build:
      context: .
      dockerfile: Dockerfile
    image: easymosdns-x:latest
    container_name: easymosdns
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
      RULES_UPDATE_MODE: cdn
      RULES_UPDATE_CRON: "0 3 * * *"
    volumes:
      - easymosdns-workdir:/etc/mosdns

volumes:
  easymosdns-workdir:
```

## 初始化策略

容器要求 `mosdns` 工作目录持久化挂载到 `/etc/mosdns`。

镜像会在该目录里写一个隐藏初始化标记文件：

```bash
/etc/mosdns/.easymosdns-initialized
```

启动逻辑如下：

1. 如果 `/etc/mosdns` 没有挂载持久卷，容器直接退出
2. 如果标记文件不存在，就下载官方 `easymosdns`
3. 写入 `config.yaml`、`hosts.txt`、`ecs_*.txt`、`rules/`
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

## 健康检查

镜像内置了 `healthcheck`，逻辑分两层：

1. 检查 `mosdns` 进程是否存在
2. 对 `127.0.0.1:53` 发起一次 `localhost A` 查询，并要求返回 `127.0.0.1`

这样做的好处是：

- 不依赖外网
- 不依赖上游 DNS 是否暂时可达
- 能同时确认“进程还活着”和“本地解析功能正常”

健康检查脚本在 [docker/healthcheck.sh](C:/Users/john2/Documents/repo/easymosdns-v5/docker/healthcheck.sh)。

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

下面这些变量保留支持，但普通使用场景一般不需要改：

`FORCE_REINIT`
: 强制重新初始化 `easymosdns`

`BACKUP_ON_REINIT`
: 重初始化前是否自动备份

`MOSDNS_X_REF`
: 固定 `mosdns-x` 版本

`EASYMOSDNS_REF`
: 固定 `easymosdns` 版本

`RULES_UPDATE_TIME`
: 用每天固定时间更新规则，例如 `03:00`

`RULES_UPDATE_INTERVAL`
: 用固定间隔更新规则

`GITHUB_TOKEN`
: 提高 GitHub API 限额

## 运行示例

普通运行：

```bash
docker run -d \
  --name easymosdns \
  -p 53:53/udp \
  -p 53:53/tcp \
  -p 9080:9080/tcp \
  -v easymosdns-data:/etc/mosdns \
  -e TZ=Asia/Shanghai \
  -e RULES_UPDATE_MODE=cdn \
  -e RULES_UPDATE_CRON="0 3 * * *" \
  easymosdns-x:latest
```

强制重初始化：

```bash
docker run -d \
  --name easymosdns \
  -p 53:53/udp \
  -p 53:53/tcp \
  -p 9080:9080/tcp \
  -v easymosdns-data:/etc/mosdns \
  -e FORCE_REINIT=true \
  easymosdns-x:latest
```

## 注意事项

- 当前镜像默认面向常见 Linux 架构自动选取 `mosdns-x` 二进制
- `RULES_UPDATE_CRON` 使用容器内 `TZ` 时区
- `easymosdns` 初始化后，后续不会自动升级配置模板，除非显式开启 `FORCE_REINIT=true`
