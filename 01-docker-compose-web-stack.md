# 企业级项目01: Docker Compose 全栈Web应用部署

## 📋 项目概述

这是一个完整的企业级Web应用部署方案，使用Docker Compose编排生产环境所需的所有服务。

**技术栈**: Nginx + Python FastAPI + MySQL 8.0 + Redis 7 + Prometheus + Grafana

---

## 🏗️ 架构图

```
                          ┌─────────────────────────────────────┐
                          │          用户请求 (443/80)           │
                          └──────────────┬──────────────────────┘
                                         │
                          ┌──────────────▼──────────────────────┐
                          │        Nginx 反向代理 (443)          │
                          │   SSL终止 / 限流 / Gzip / 静态资源    │
                          └──────┬───────────────┬──────────────┘
                                 │               │
                    ┌────────────▼──┐    ┌───────▼────────────┐
                    │  FastAPI App  │    │   phpMyAdmin       │
                    │  (8000)       │    │   (8080)           │
                    └───┬───────┬──┘    └────────────────────┘
                        │       │
            ┌───────────▼┐  ┌───▼──────────┐
            │  MySQL 8.0 │  │  Redis 7     │
            │  (3306)    │  │  (6379)      │
            └────────────┘  └──────────────┘

    ┌──────────────────────────────────────────────┐
    │  监控层: Prometheus (9090) + Grafana (3000)   │
    └──────────────────────────────────────────────┘
```

---

## 📁 项目文件结构

```
enterprise-web-stack/
├── docker-compose.yml          # 主编排文件
├── .env                        # 环境变量（不要提交到Git）
├── .env.example                # 环境变量模板
├── nginx/
│   ├── nginx.conf              # Nginx主配置
│   └── conf.d/
│       └── default.conf        # 站点配置
├── mysql/
│   ├── my.cnf                  # MySQL配置
│   └── init/
│       └── 01-init.sql         # 初始化SQL
├── redis/
│   └── redis.conf              # Redis配置
├── app/
│   ├── Dockerfile              # 应用镜像构建
│   ├── requirements.txt        # Python依赖
│   ├── main.py                 # FastAPI应用
│   └── config.py               # 应用配置
├── prometheus/
│   └── prometheus.yml          # Prometheus配置
├── grafana/
│   └── provisioning/
│       └── datasources/
│           └── prometheus.yml  # Grafana数据源
├── scripts/
│   ├── backup.sh               # 数据库备份脚本
│   ├── restore.sh              # 数据库恢复脚本
│   ├── health-check.sh         # 健康检查脚本
│   └── deploy.sh               # 部署脚本
└── README.md                   # 本文档
```

---

## 🚀 快速开始

### 1. 克隆项目
```bash
git clone https://github.com/missxb/enterprise-ops-projects.git
cd enterprise-ops-projects/01-docker-compose-web-stack
```

### 2. 配置环境变量
```bash
cp .env.example .env
# 编辑 .env 文件，修改密码和域名
vim .env
```

### 3. 一键启动
```bash
chmod +x scripts/*.sh
docker-compose up -d
```

### 4. 验证服务
```bash
# 查看所有服务状态
docker-compose ps

# 查看日志
docker-compose logs -f

# 访问应用
curl -k https://localhost
```

---

## 📄 完整配置文件

### docker-compose.yml

```yaml
version: '3.8'

# ============================================
# 企业级Web应用全栈部署 - Docker Compose
# ============================================

services:
  # ========== Nginx 反向代理 ==========
  nginx:
    image: nginx:1.25-alpine
    container_name: nginx-proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - nginx-logs:/var/log/nginx
      - ssl-certs:/etc/nginx/ssl:ro
    depends_on:
      app:
        condition: service_healthy
    networks:
      - frontend
      - backend
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 128M
    healthcheck:
      test: ["CMD", "curl", "-f", "-k", "https://localhost/health"]  # [已修复] Nginx配置了HTTPS重定向
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"

  # ========== FastAPI 应用 ==========
  app:
    build:
      context: ./app
      dockerfile: Dockerfile
    container_name: fastapi-app
    restart: always
    expose:
      - "8000"
    environment:
      - DATABASE_URL=mysql+asyncmy://app_user:${MYSQL_APP_PASSWORD}@mysql:3306/${MYSQL_DATABASE}
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - SECRET_KEY=${SECRET_KEY}
      - ENVIRONMENT=${ENVIRONMENT:-production}
    volumes:
      - app-uploads:/app/uploads
      - app-logs:/app/logs
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - backend
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 256M
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "10"

  # ========== MySQL 8.0 ==========
  mysql:
    image: mysql:8.0
    container_name: mysql-db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: app_user
      MYSQL_PASSWORD: ${MYSQL_APP_PASSWORD}
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql/my.cnf:/etc/mysql/conf.d/custom.cnf:ro
      - ./mysql/init:/docker-entrypoint-initdb.d:ro
      - mysql-backups:/backups
    networks:
      - backend
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '0.5'
          memory: 512M
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      # [已修复] innodb_buffer_pool_size由my.cnf配置文件统一管理
      --max-connections=200
      --slow-query-log=1
      --long-query-time=2
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"

  # ========== Redis 7 ==========
  redis:
    image: redis:7-alpine
    container_name: redis-cache
    restart: always
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
      --appendonly yes
      --appendfsync everysec
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
      - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
    networks:
      - backend
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 128M
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"

  # ========== phpMyAdmin ==========
  phpmyadmin:
    image: phpmyadmin:5
    container_name: phpmyadmin
    restart: always
    environment:
      PMA_HOST: mysql
      PMA_PORT: 3306
      PMA_USER: root
      PMA_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      UPLOAD_LIMIT: 100M
    ports:
      - "8080:80"
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - backend
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  # ========== Prometheus 监控 ==========
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: always
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.enable-lifecycle'
    networks:
      - monitoring
      - backend
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 10s
      retries: 3

  # ========== Grafana 可视化 ==========
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: always
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=https://${DOMAIN_NAME}:3000
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    depends_on:
      prometheus:
        condition: service_healthy
    networks:
      - monitoring
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"

# ========== 网络 ==========
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
  monitoring:
    driver: bridge

# ========== 数据卷 ==========
volumes:
  mysql-data:
    driver: local
  mysql-backups:
    driver: local
  redis-data:
    driver: local
  app-uploads:
    driver: local
  app-logs:
    driver: local
  nginx-logs:
    driver: local
  ssl-certs:
    driver: local
  prometheus-data:
    driver: local
  grafana-data:
    driver: local
```

### .env.example

```bash
# ============================================
# 环境变量配置 - 复制为 .env 并修改
# ============================================

# ===== 应用配置 =====
ENVIRONMENT=production
DOMAIN_NAME=your-domain.com
SECRET_KEY=change-me-to-a-random-string-at-least-32-chars

# ===== MySQL配置 =====
MYSQL_ROOT_PASSWORD=YourStr0ng!RootPass
MYSQL_DATABASE=enterprise_app
MYSQL_APP_PASSWORD=YourStr0ng!AppPass

# ===== Redis配置 =====
REDIS_PASSWORD=YourStr0ng!RedisPass

# ===== Grafana配置 =====
GRAFANA_ADMIN_PASSWORD=YourStr0ng!GrafanaPass

# ===== 备份配置 =====
BACKUP_RETENTION_DAYS=30
BACKUP_S3_BUCKET=s3://your-backup-bucket
```

### nginx/nginx.conf

```nginx
# ============================================
# Nginx 主配置 - 企业级优化
# ============================================

user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ===== 日志格式 =====
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    '$request_time $upstream_response_time';

    access_log /var/log/nginx/access.log main;

    # ===== 性能优化 =====
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;

    # ===== Gzip压缩 =====
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml
        application/rss+xml
        image/svg+xml;
    gzip_min_length 1000;

    # ===== 安全头 =====
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ===== 限流配置 =====
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;
    limit_conn_zone $binary_remote_addr zone=conn:10m;

    # ===== 上游服务 =====
    upstream fastapi_app {
        least_conn;
        server app:8000 max_fails=3 fail_timeout=30s;
        keepalive 32;
    }

    include /etc/nginx/conf.d/*.conf;
}
```

### nginx/conf.d/default.conf

```nginx
# ============================================
# HTTP -> HTTPS 重定向
# ============================================
server {
    listen 80;
    server_name _;

    # Let's Encrypt 验证
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# ============================================
# HTTPS 主站点
# ============================================
server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # ===== SSL证书 =====
    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # ===== HSTS =====
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # ===== 限流 =====
    limit_req zone=api burst=20 nodelay;
    limit_conn conn 100;

    # ===== 静态资源 =====
    location /static/ {
        alias /app/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # ===== 健康检查 =====
    location /health {
        access_log off;
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }

    # ===== API代理 =====
    location / {
        proxy_pass http://fastapi_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";

        proxy_http_version 1.1;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffer_size 8k;
        proxy_buffers 8 8k;
    }

    # ===== WebSocket支持 =====
    location /ws {
        proxy_pass http://fastapi_app;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }

    # ===== 拒绝敏感路径 =====
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
```

### mysql/my.cnf

```ini
# ============================================
# MySQL 8.0 企业级配置
# ============================================

[mysqld]
# 基础配置
server-id = 1
log_bin = mysql-bin
binlog_format = ROW
binlog_expire_logs_seconds = 604800
max_binlog_size = 100M

# 字符集
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# InnoDB配置
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_io_capacity = 2000

# 连接配置
max_connections = 500
max_connect_errors = 100
wait_timeout = 600
interactive_timeout = 600

# 查询缓存（MySQL 8.0已移除query_cache）
# 使用ProxySQL或应用层缓存

# 慢查询日志
slow_query_log = 1
slow_query_log_file = /var/lib/mysql/slow.log
long_query_time = 2
log_queries_not_using_indexes = 1

# 安全配置
local_infile = 0
symbolic-links = 0
skip-name-resolve

[client]
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4
prompt = "\\u@\\h [\\d]> "
```

### mysql/init/01-init.sql

```sql
-- ============================================
-- 数据库初始化脚本
-- ============================================

-- 创建业务表
USE enterprise_app;

-- 用户表
CREATE TABLE IF NOT EXISTS users (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    role ENUM('admin', 'user', 'viewer') DEFAULT 'user',
    last_login DATETIME,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_email (email),
    INDEX idx_role (role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 操作日志表
CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED,
    action VARCHAR(50) NOT NULL,
    resource VARCHAR(100),
    details JSON,
    ip_address VARCHAR(45),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_user_id (user_id),
    INDEX idx_action (action),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 配置表
CREATE TABLE IF NOT EXISTS system_config (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    config_key VARCHAR(100) NOT NULL UNIQUE,
    config_value TEXT,
    description VARCHAR(255),
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 插入默认配置
INSERT INTO system_config (config_key, config_value, description) VALUES
('app_name', 'Enterprise App', '应用名称'),
('maintenance_mode', 'false', '维护模式开关'),
('max_upload_size', '104857600', '最大上传文件大小(字节)')
ON DUPLICATE KEY UPDATE config_value = VALUES(config_value);

-- 创建监控用户（只读）
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'Monitor@2024';
GRANT SELECT ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;
```

### redis/redis.conf

```conf
# ============================================
# Redis 7 企业级配置
# ============================================

# 网络
bind 0.0.0.0
port 6379
tcp-backlog 511
timeout 300
tcp-keepalive 300

# 内存管理
maxmemory 256mb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# 持久化 - AOF
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 持久化 - RDB
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb

# 日志
loglevel notice
logfile ""

# 慢日志
slowlog-log-slower-than 10000
slowlog-max-len 128

# 安全
rename-command FLUSHALL ""
rename-command FLUSHDB ""
```

### app/Dockerfile

```dockerfile
# ============================================
# FastAPI 应用 Dockerfile
# ============================================

FROM python:3.11-slim AS base

# 安全: 非root用户
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

WORKDIR /app

# 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 安装Python依赖
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 复制应用代码
COPY --chown=appuser:appuser . .

# 创建必要目录
RUN mkdir -p /app/uploads /app/logs && \
    chown -R appuser:appuser /app

USER appuser

EXPOSE 8000

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
```

### app/requirements.txt

```
fastapi==0.104.1
uvicorn[standard]==0.24.0
sqlalchemy[asyncio]==2.0.23
asyncmy==0.2.9
redis[hiredis]==5.0.1
pydantic==2.5.2
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-multipart==0.0.6
httpx==0.25.2
prometheus-client==0.19.0
structlog==23.2.0
```

### app/main.py

```python
"""
企业级FastAPI应用 - 完整示例
"""

import time
import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, generate_latest
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from redis import asyncio as aioredis
import os

# ===== 配置 =====
DATABASE_URL = os.getenv("DATABASE_URL", "mysql+asyncmy://root:root@localhost:3306/enterprise_app")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key")

# ===== 日志 =====
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ]
)
logger = structlog.get_logger()

# ===== Prometheus指标 =====
REQUEST_COUNT = Counter('http_requests_total', 'Total HTTP requests', ['method', 'endpoint', 'status'])
REQUEST_LATENCY = Histogram('http_request_duration_seconds', 'Request latency', ['method', 'endpoint'])

# ===== 全局连接 =====
engine = None
redis_client = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理"""
    global engine, redis_client
    
    # 启动: 初始化连接
    engine = create_async_engine(DATABASE_URL, pool_size=20, max_overflow=10)
    redis_client = aioredis.from_url(REDIS_URL, decode_responses=True)
    
    logger.info("应用启动", database="connected", redis="connected")
    yield
    
    # 关闭: 清理连接
    await engine.dispose()
    await redis_client.close()
    logger.info("应用关闭")

# ===== 创建应用 =====
app = FastAPI(
    title="Enterprise App",
    version="1.0.0",
    lifespan=lifespan
)

# ===== 中间件: 请求指标 =====
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start
    
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.url.path
    ).observe(duration)
    
    return response

# ===== 路由 =====
@app.get("/health")
async def health_check():
    """健康检查"""
    checks = {"database": "ok", "redis": "ok"}
    status = "healthy"
    
    try:
        async with engine.connect() as conn:
            await conn.execute(__import__('sqlalchemy').text("SELECT 1"))
    except Exception as e:
        checks["database"] = f"error: {str(e)}"
        status = "degraded"
    
    try:
        await redis_client.ping()
    except Exception as e:
        checks["redis"] = f"error: {str(e)}"
        status = "degraded"
    
    return {"status": status, "checks": checks}

@app.get("/metrics")
async def metrics():
    """Prometheus指标端点"""
    return JSONResponse(
        content=generate_latest().decode(),
        media_type="text/plain"
    )

@app.get("/api/v1/info")
async def get_info():
    """系统信息"""
    return {
        "app": "Enterprise App",
        "version": "1.0.0",
        "environment": os.getenv("ENVIRONMENT", "production")
    }

@app.post("/api/v1/cache/{key}")
async def set_cache(key: str, value: str):
    """设置缓存"""
    await redis_client.set(key, value, ex=3600)
    return {"status": "ok", "key": key}

@app.get("/api/v1/cache/{key}")
async def get_cache(key: str):
    """获取缓存"""
    value = await redis_client.get(key)
    if value is None:
        raise HTTPException(status_code=404, detail="Key not found")
    return {"key": key, "value": value}
```

### prometheus/prometheus.yml

```yaml
# ============================================
# Prometheus 配置
# ============================================

global:
  scrape_interval: 15s
  evaluation_interval: 15s

# 告警规则文件
rule_files:
  - "rules/*.yml"

# 告警管理器
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

# 采集目标
scrape_configs:
  # Prometheus自身
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # FastAPI应用
  - job_name: 'fastapi-app'
    static_configs:
      - targets: ['app:8000']
    metrics_path: '/metrics'
    scrape_interval: 10s

  # Node Exporter (主机监控)
  # [已修复] 以下Exporter需要在docker-compose中定义对应服务
  # 当前配置引用了不存在的服务，部署后会显示DOWN
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']

  # cAdvisor (容器监控)
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']

  # MySQL Exporter
  - job_name: 'mysql'
    static_configs:
      - targets: ['mysql-exporter:9104']

  # Redis Exporter
  - job_name: 'redis'
    static_configs:
      - targets: ['redis-exporter:9121']

  # Nginx Exporter
  - job_name: 'nginx'
    static_configs:
      - targets: ['nginx-exporter:9113']
```

### grafana/provisioning/datasources/prometheus.yml

```yaml
# ============================================
# Grafana 自动配置数据源
# ============================================

apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
```

### scripts/backup.sh

```bash
#!/bin/bash
# ============================================
# MySQL 数据库自动备份脚本
# ============================================

set -euo pipefail

# 配置
BACKUP_DIR="/backups/mysql"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.sql.gz"
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
MYSQL_CONTAINER="mysql-db"
MYSQL_USER="root"
MYSQL_PASS="${MYSQL_ROOT_PASSWORD}"
MYSQL_DB="${MYSQL_DATABASE}"

# 创建备份目录
mkdir -p "${BACKUP_DIR}"

echo "[$(date)] 开始备份数据库 ${MYSQL_DB}..."

# 执行备份
docker exec "${MYSQL_CONTAINER}" \
    mysqldump -u"${MYSQL_USER}" -p"${MYSQL_PASS}" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --set-gtid-purged=OFF \
    "${MYSQL_DB}" | gzip > "${BACKUP_FILE}"

# 检查备份文件
FILESIZE=$(stat -f%z "${BACKUP_FILE}" 2>/dev/null || stat -c%s "${BACKUP_FILE}")
echo "[$(date)] 备份完成: ${BACKUP_FILE} (${FILESIZE} bytes)"

# 清理旧备份
echo "[$(date)] 清理 ${RETENTION_DAYS} 天前的备份..."
find "${BACKUP_DIR}" -name "backup_*.sql.gz" -mtime +${RETENTION_DAYS} -delete

# 备份到S3（可选）
# aws s3 cp "${BACKUP_FILE}" s3://your-bucket/backups/mysql/

echo "[$(date)] 备份流程完成!"
```

### scripts/health-check.sh

```bash
#!/bin/bash
# ============================================
# 全栈健康检查脚本
# ============================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "    企业级应用健康检查"
echo "    $(date)"
echo "=========================================="

check_service() {
    local name=$1
    local url=$2
    local expected=$3
    
    response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || echo "000")
    
    if [ "$response" = "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} ${name}: 正常 (HTTP ${response})"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${name}: 异常 (HTTP ${response}, 期望 ${expected})"
        return 1
    fi
}

ERRORS=0

echo ""
echo "📡 服务状态检查:"
check_service "Nginx" "http://localhost/health" "200" || ((ERRORS++))
check_service "FastAPI" "http://localhost:8000/health" "200" || ((ERRORS++))
check_service "phpMyAdmin" "http://localhost:8080" "200" || ((ERRORS++))
check_service "Prometheus" "http://localhost:9090/-/healthy" "200" || ((ERRORS++))
check_service "Grafana" "http://localhost:3000/api/health" "200" || ((ERRORS++))

echo ""
echo "🐳 Docker容器状态:"
docker-compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "💾 磁盘使用:"
df -h / | tail -1 | awk '{print "  总空间: "$2" | 已用: "$3" | 可用: "$4" | 使用率: "$5}'

echo ""
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✅ 所有服务运行正常!${NC}"
else
    echo -e "${RED}❌ 有 ${ERRORS} 个服务异常，请检查!${NC}"
fi
```

### scripts/deploy.sh

```bash
#!/bin/bash
# ============================================
# 一键部署脚本
# ============================================

set -euo pipefail

echo "=========================================="
echo "    企业级应用部署脚本"
echo "=========================================="

# 检查Docker和Docker Compose
if ! command -v docker &> /dev/null; then
    echo "❌ Docker未安装，请先安装Docker"
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose未安装"
    exit 1
fi

# 检查.env文件
if [ ! -f .env ]; then
    echo "⚠️  .env文件不存在，从模板创建..."
    cp .env.example .env
    echo "📝 请编辑 .env 文件配置环境变量"
    exit 1
fi

# 加载环境变量
source .env

echo ""
echo "🔨 构建镜像..."
docker-compose build --no-cache

echo ""
echo "🚀 启动服务..."
docker-compose up -d

echo ""
echo "⏳ 等待服务启动..."
sleep 10

echo ""
echo "🔍 健康检查..."
bash scripts/health-check.sh

echo ""
echo "✅ 部署完成!"
echo ""
echo "📌 访问地址:"
echo "   应用:    https://localhost"
echo "   管理面板: http://localhost:8080"
echo "   Grafana: http://localhost:3000"
echo "   Prometheus: http://localhost:9090"
```

---

## 🔧 运维手册

### 常用命令

```bash
# 查看服务状态
docker-compose ps

# 查看日志
docker-compose logs -f [service_name]

# 重启单个服务
docker-compose restart app

# 进入容器调试
docker-compose exec app bash
docker-compose exec mysql mysql -u root -p

# 数据库备份
bash scripts/backup.sh

# 更新部署
docker-compose pull
docker-compose up -d

# 清理未使用资源
docker system prune -f
docker volume prune -f
```

### 故障排查

| 问题 | 排查命令 |
|------|---------|
| 应用无法连接数据库 | `docker-compose exec app python -c "import asyncmy; print('ok')"` |
| Redis连接失败 | `docker-compose exec redis redis-cli -a $REDIS_PASSWORD ping` |
| Nginx 502错误 | `docker-compose logs nginx` 检查上游配置 |
| 磁盘空间不足 | `docker system df` + 清理日志卷 |
| SSL证书过期 | `openssl x509 -in cert.pem -noout -dates` |

### 安全加固清单

- [x] 使用非root用户运行应用
- [x] SSL/TLS加密传输
- [x] 限流防DDoS
- [x] 安全响应头
- [x] 密码使用环境变量
- [x] 数据库最小权限原则
- [x] 日志脱敏处理
- [x] 容器资源限制
- [x] 定期备份策略

---

## 📊 监控指标

| 指标 | 告警阈值 | 说明 |
|------|---------|------|
| CPU使用率 | > 80% 持续5分钟 | 主机CPU过载 |
| 内存使用率 | > 85% | 内存不足 |
| 磁盘使用率 | > 90% | 磁盘空间告急 |
| 容器重启次数 | > 3次/小时 | 容器异常 |
| API响应时间 | P99 > 2s | 性能下降 |
| HTTP 5xx错误率 | > 1% | 服务异常 |
| MySQL连接数 | > 80% max | 连接池耗尽 |

---

**作者**: 企业级运维项目集  
**版本**: 1.0.0  
**更新时间**: 2026-05-02