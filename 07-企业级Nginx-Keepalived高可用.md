# 企业级Nginx + Keepalived高可用

> 完整实现Nginx负载均衡集群，覆盖反向代理、SSL卸载、限流、WAF、健康检查、故障自动切换

---

## 一、架构

```
                    ┌─────────────────────┐
                    │    用户请求          │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │   VIP: 10.10.50.100  │
                    │   (Keepalived漂移)   │
                    └──┬───────────────┬──┘
                       │               │
              ┌────────▼──┐     ┌──────▼────────┐
              │ Nginx-01  │     │  Nginx-02     │
              │ MASTER    │     │  BACKUP       │
              │ 优先级101  │     │  优先级100     │
              └─────┬─────┘     └───────┬───────┘
                    │                   │
              ┌─────▼───────────────────▼─────┐
              │      Upstream Backend Pool     │
              │  ┌─────┐ ┌─────┐ ┌─────┐     │
              │  │App-1│ │App-2│ │App-N│     │
              │  └─────┘ └─────┘ └─────┘     │
              └───────────────────────────────┘
```

---

## 二、Nginx配置

```nginx
# /etc/nginx/nginx.conf - 企业级Nginx配置
user nginx;
worker_processes auto;               # 自动匹配CPU核心数
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    use epoll;
    worker_connections 65535;
    multi_accept on;
    accept_mutex off;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 日志格式
    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    '$request_time $upstream_response_time '
                    '$upstream_addr $upstream_status';

    log_format json escape=json '{'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"request":"$request",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_time":"$upstream_response_time",'
        '"upstream_addr":"$upstream_addr"'
    '}';

    access_log /var/log/nginx/access.log json;

    # 性能优化
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    client_max_body_size 100m;
    client_body_buffer_size 128k;
    client_header_buffer_size 4k;
    large_client_header_buffers 4 16k;

    # Gzip压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml;

    # 限流配置
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/s;
    limit_req_zone $binary_remote_addr zone=login_limit:10m rate=5r/m;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    # 隐藏版本号
    server_tokens off;

    # SSL全局配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    # Upstream后端池
    upstream app_backend {
        least_conn;                    # 最少连接算法
        keepalive 32;

        server 10.10.50.11:8080 weight=5 max_fails=3 fail_timeout=30s;
        server 10.10.50.12:8080 weight=5 max_fails=3 fail_timeout=30s;
        server 10.10.50.13:8080 weight=3 max_fails=3 fail_timeout=30s;
        server 10.10.50.14:8080 weight=3 max_fails=3 fail_timeout=30s backup;
    }

    upstream api_backend {
        ip_hash;                        # 会话保持
        server 10.10.50.21:8081 max_fails=3;
        server 10.10.50.22:8081 max_fails=3;
    }

    # HTTP -> HTTPS重定向
    server {
        listen 80;
        listen [::]:80;
        server_name *.ecommerce.com;
        return 301 https://$host$request_uri;
    }

    # 主站
    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name www.ecommerce.com;

        ssl_certificate /etc/nginx/ssl/ecommerce.com.pem;
        ssl_certificate_key /etc/nginx/ssl/ecommerce.com.key;

        # 安全头
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header Content-Security-Policy "default-src 'self'" always;

        # 健康检查端点
        location /health {
            access_log off;
            return 200 'OK';
            add_header Content-Type text/plain;
        }

        # Nginx状态监控
        location /nginx_status {
            stub_status on;
            allow 10.10.0.0/16;
            allow 127.0.0.1;
            deny all;
        }

        # API接口（限流）
        location /api/ {
            limit_req zone=api_limit burst=200 nodelay;
            limit_conn conn_limit 50;

            proxy_pass http://api_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_connect_timeout 5s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
            proxy_buffering on;
            proxy_buffer_size 16k;
            proxy_buffers 4 32k;
        }

        # 登录接口（严格限流）
        location /api/auth/login {
            limit_req zone=login_limit burst=10 nodelay;
            proxy_pass http://api_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # 静态资源
        location /static/ {
            alias /data/www/static/;
            expires 30d;
            add_header Cache-Control "public, immutable";
            access_log off;
        }

        # 默认路由
        location / {
            proxy_pass http://app_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }

        # 禁止访问隐藏文件
        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }
    }

    # 后台管理
    server {
        listen 443 ssl http2;
        server_name admin.ecommerce.com;

        ssl_certificate /etc/nginx/ssl/admin.ecommerce.com.pem;
        ssl_certificate_key /etc/nginx/ssl/admin.ecommerce.com.key;

        # IP白名单
        allow 10.10.0.0/16;
        allow 192.168.0.0/16;
        deny all;

        location / {
            proxy_pass http://app_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
```

---

## 三、Keepalived配置

```bash
# /etc/keepalived/keepalived.conf - Nginx-01(MASTER)
vrrp_script chk_nginx {
    script "/usr/local/bin/check_nginx.sh"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass NginxHA2024
    }
    virtual_ipaddress {
        10.10.50.100/24 dev eth0
    }
    track_script {
        chk_nginx
    }
    notify_master "/opt/scripts/nginx_notify.sh MASTER"
    notify_backup "/opt/scripts/nginx_notify.sh BACKUP"
    notify_fault "/opt/scripts/nginx_notify.sh FAULT"
}
```

```bash
#!/bin/bash
# check_nginx.sh - Nginx健康检查脚本
if ! /usr/sbin/nginx -t 2>/dev/null; then
    exit 1
fi
if ! curl -sf -o /dev/null http://127.0.0.1/health --max-time 3; then
    systemctl restart nginx
    sleep 2
    if ! curl -sf -o /dev/null http://127.0.0.1/health --max-time 3; then
        exit 1
    fi
fi
exit 0
```

---

## 四、SSL证书自动续期

```bash
#!/bin/bash
# ssl_renew.sh - Let's Encrypt自动续期

certbot renew --quiet --deploy-hook "systemctl reload nginx"

# crontab: 每天凌晨3点检查
# 0 3 * * * /opt/scripts/ssl_renew.sh >> /var/log/ssl-renew.log 2>&1
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)编写
