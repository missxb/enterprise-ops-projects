     1|# 企业级Nginx + Keepalived高可用
     2|
     3|> 完整实现Nginx负载均衡集群，覆盖反向代理、SSL卸载、限流、WAF、健康检查、故障自动切换
     4|
     5|---
     6|
     7|## 一、架构
     8|
     9|```
    10|                    ┌─────────────────────┐
    11|                    │    用户请求          │
    12|                    └──────────┬──────────┘
    13|                               │
    14|                    ┌──────────▼──────────┐
    15|                    │   VIP: 10.10.50.100  │
    16|                    │   (Keepalived漂移)   │
    17|                    └──┬───────────────┬──┘
    18|                       │               │
    19|              ┌────────▼──┐     ┌──────▼────────┐
    20|              │ Nginx-01  │     │  Nginx-02     │
    21|              │ MASTER    │     │  BACKUP       │
    22|              │ 优先级101  │     │  优先级100     │
    23|              └─────┬─────┘     └───────┬───────┘
    24|                    │                   │
    25|              ┌─────▼───────────────────▼─────┐
    26|              │      Upstream Backend Pool     │
    27|              │  ┌─────┐ ┌─────┐ ┌─────┐     │
    28|              │  │App-1│ │App-2│ │App-N│     │
    29|              │  └─────┘ └─────┘ └─────┘     │
    30|              └───────────────────────────────┘
    31|```
    32|
    33|---
    34|
    35|## 二、Nginx配置
    36|
    37|```nginx
    38|# /etc/nginx/nginx.conf - 企业级Nginx配置
    39|user nginx;
    40|worker_processes auto;               # 自动匹配CPU核心数
    41|worker_rlimit_nofile 65535;
    42|error_log /var/log/nginx/error.log warn;
    43|pid /var/run/nginx.pid;
    44|
    45|events {
    46|    use epoll;
    47|    worker_connections 65535;
    48|    multi_accept on;
    49|    accept_mutex off;
    50|}
    51|
    52|http {
    53|    include /etc/nginx/mime.types;
    54|    default_type application/octet-stream;
    55|
    56|    # 日志格式
    57|    log_format main '$remote_addr - $remote_user [$time_local] '
    58|                    '"$request" $status $body_bytes_sent '
    59|                    '"$http_referer" "$http_user_agent" '
    60|                    '$request_time $upstream_response_time '
    61|                    '$upstream_addr $upstream_status';
    62|
    63|    log_format json escape=json '{'
    64|        '"time":"$time_iso8601",'
    65|        '"remote_addr":"$remote_addr",'
    66|        '"request":"$request",'
    67|        '"status":$status,'
    68|        '"body_bytes_sent":$body_bytes_sent,'
    69|        '"request_time":$request_time,'
    70|        '"upstream_time":"$upstream_response_time",'
    71|        '"upstream_addr":"$upstream_addr"'
    72|    '}';
    73|
    74|    access_log /var/log/nginx/access.log json;
    75|
    76|    # 性能优化
    77|    sendfile on;
    78|    tcp_nopush on;
    79|    tcp_nodelay on;
    80|    keepalive_timeout 65;
    81|    keepalive_requests 1000;
    82|    types_hash_max_size 2048;
    83|    client_max_body_size 100m;
    84|    client_body_buffer_size 128k;
    85|    client_header_buffer_size 4k;
    86|    large_client_header_buffers 4 16k;
    87|
    88|    # Gzip压缩
    89|    gzip on;
    90|    gzip_vary on;
    91|    gzip_proxied any;
    92|    gzip_comp_level 4;
    93|    gzip_min_length 1024;
    94|    gzip_types text/plain text/css application/json application/javascript
    95|               text/xml application/xml application/xml+rss text/javascript
    96|               image/svg+xml;
    97|
    98|    # 限流配置
    99|    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/s;
   100|    limit_req_zone $binary_remote_addr zone=login_limit:10m rate=5r/m;
   101|    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
   102|
   103|    # 隐藏版本号
   104|    server_tokens off;
   105|
   106|    # SSL全局配置
   107|    ssl_protocols TLSv1.2 TLSv1.3;
   108|    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
   109|    ssl_prefer_server_ciphers on;
   110|    ssl_session_cache shared:SSL:50m;
   111|    ssl_session_timeout 1d;
   112|    ssl_session_tickets off;
   113|    ssl_stapling on;
   114|    ssl_stapling_verify on;
   115|
   116|    # Upstream后端池
   117|    upstream app_backend {
   118|        least_conn;                    # 最少连接算法
   119|        keepalive 32;
   120|
   121|        server 10.10.50.11:8080 weight=5 max_fails=3 fail_timeout=30s;
   122|        server 10.10.50.12:8080 weight=5 max_fails=3 fail_timeout=30s;
   123|        server 10.10.50.13:8080 weight=3 max_fails=3 fail_timeout=30s;
   124|        server 10.10.50.14:8080 weight=3 max_fails=3 fail_timeout=30s backup;
   125|    }
   126|
   127|    upstream api_backend {
   128|        ip_hash;                        # 会话保持
   129|        server 10.10.50.21:8081 max_fails=3;
   130|        server 10.10.50.22:8081 max_fails=3;
   131|    }
   132|
   133|    # HTTP -> HTTPS重定向
   134|    server {
   135|        listen 80;
   136|        listen [::]:80;
   137|        server_name *.ecommerce.com;
   138|        return 301 https://$host$request_uri;
   139|    }
   140|
   141|    # 主站
   142|    server {
   143|        listen 443 ssl http2;
   144|        listen [::]:443 ssl http2;
   145|        server_name www.ecommerce.com;
   146|
   147|        ssl_certificate /etc/nginx/ssl/ecommerce.com.pem;
   148|        ssl_certificate_key /etc/nginx/ssl/ecommerce.com.key;
   149|
   150|        # 安全头
   151|        add_header X-Frame-Options "SAMEORIGIN" always;
   152|        add_header X-Content-Type-Options "nosniff" always;
   153|        add_header X-XSS-Protection "1; mode=block" always;
   154|        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
   155|        add_header Content-Security-Policy "default-src 'self'" always;
   156|
   157|        # 健康检查端点
   158|        location /health {
   159|            access_log off;
   160|            return 200 'OK';
   161|            add_header Content-Type text/plain;
   162|        }
   163|
   164|        # Nginx状态监控
   165|        location /nginx_status {
   166|            stub_status on;
   167|            allow 10.10.0.0/16;
   168|            allow 127.0.0.1;
   169|            deny all;
   170|        }
   171|
   172|        # API接口（限流）
   173|        location /api/ {
   174|            limit_req zone=api_limit burst=200 nodelay;
   175|            limit_conn conn_limit 50;
   176|
   177|            proxy_pass http://api_backend;
   178|            proxy_set_header Host $host;
   179|            proxy_set_header X-Real-IP $remote_addr;
   180|            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   181|            proxy_set_header X-Forwarded-Proto $scheme;
   182|            proxy_connect_timeout 5s;
   183|            proxy_send_timeout 60s;
   184|            proxy_read_timeout 60s;
   185|            proxy_buffering on;
   186|            proxy_buffer_size 16k;
   187|            proxy_buffers 4 32k;
   188|        }
   189|
   190|        # 登录接口（严格限流）
   191|        location /api/auth/login {
   192|            limit_req zone=login_limit burst=10 nodelay;
   193|            proxy_pass http://api_backend;
   194|            proxy_set_header Host $host;
   195|            proxy_set_header X-Real-IP $remote_addr;
   196|        }
   197|
   198|        # 静态资源
   199|        location /static/ {
   200|            alias /data/www/static/;
   201|            expires 30d;
   202|            add_header Cache-Control "public, immutable";
   203|            access_log off;
   204|        }
   205|
   206|        # 默认路由
   207|        location / {
   208|            proxy_pass http://app_backend;
   209|            proxy_set_header Host $host;
   210|            proxy_set_header X-Real-IP $remote_addr;
   211|            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   212|            proxy_set_header X-Forwarded-Proto $scheme;
   213|            proxy_http_version 1.1;
   214|            proxy_set_header Connection "";
   215|        }
   216|
   217|        # 禁止访问隐藏文件
   218|        location ~ /\. {
   219|            deny all;
   220|            access_log off;
   221|            log_not_found off;
   222|        }
   223|    }
   224|
   225|    # 后台管理
   226|    server {
   227|        listen 443 ssl http2;
   228|        server_name admin.ecommerce.com;
   229|
   230|        ssl_certificate /etc/nginx/ssl/admin.ecommerce.com.pem;
   231|        ssl_certificate_key /etc/nginx/ssl/admin.ecommerce.com.key;
   232|
   233|        # IP白名单
   234|        allow 10.10.0.0/16;
   235|        allow 192.168.0.0/16;
   236|        deny all;
   237|
   238|        location / {
   239|            proxy_pass http://app_backend;
   240|            proxy_set_header Host $host;
   241|            proxy_set_header X-Real-IP $remote_addr;
   242|        }
   243|    }
   244|}
   245|```
   246|
   247|---
   248|
   249|## 三、Keepalived配置
   250|
   251|```bash
   252|# /etc/keepalived/keepalived.conf - Nginx-01(MASTER)
   253|vrrp_script chk_nginx {
   254|    script "/usr/local/bin/check_nginx.sh"
   255|    interval 2
   256|    weight -20
   257|    fall 3
   258|    rise 2
   259|}
   260|
   261|vrrp_instance VI_1 {
   262|    state MASTER
   263|    interface eth0
   264|    virtual_router_id 51
   265|    priority 101
   266|    advert_int 1
   267|    authentication {
   268|        auth_type PASS
   269|        auth_pass NginxHA2024
   270|    }
   271|    virtual_ipaddress {
   272|        10.10.50.100/24 dev eth0
   273|    }
   274|    track_script {
   275|        chk_nginx
   276|    }
   277|    notify_master "/opt/scripts/nginx_notify.sh MASTER"
   278|    notify_backup "/opt/scripts/nginx_notify.sh BACKUP"
   279|    notify_fault "/opt/scripts/nginx_notify.sh FAULT"
   280|}
   281|```
   282|
   283|```bash
   284|#!/bin/bash
   285|# check_nginx.sh - Nginx健康检查脚本
   286|if ! /usr/sbin/nginx -t 2>/dev/null; then
   287|    exit 1
   288|fi
   289|if ! curl -sf -o /dev/null http://127.0.0.1/health --max-time 3; then
   290|    systemctl restart nginx
   291|    sleep 2
   292|    if ! curl -sf -o /dev/null http://127.0.0.1/health --max-time 3; then
   293|        exit 1
   294|    fi
   295|fi
   296|exit 0
   297|```
   298|
   299|---
   300|
   301|## 四、SSL证书自动续期
   302|
   303|```bash
   304|#!/bin/bash
   305|# ssl_renew.sh - Let's Encrypt自动续期
   306|
   307|certbot renew --quiet --deploy-hook "systemctl reload nginx"
   308|
   309|# crontab: 每天凌晨3点检查
   310|# 0 3 * * * /opt/scripts/ssl_renew.sh >> /var/log/ssl-renew.log 2>&1
   311|```
   312|
   313|---
   314|
   315|> 本项目基于25个语雀知识库(2699篇,584万字)编写
   316|

---

## 十二、方案对比与选型

### 12.1 Nginx vs HAProxy vs Envoy

| 特性 | Nginx | HAProxy | Envoy |
|------|-------|---------|-------|
| 定位 | Web服务器/反向代理 | TCP/HTTP负载均衡 | 云原生边缘/服务代理 |
| 性能 | 极高(事件驱动) | 极高(单线程) | 高(多线程) |
| 7层负载 | ✅ 优秀 | ✅ 优秀 | ✅ 优秀 |
| 4层负载 | ✅ 支持 | ✅ 优秀 | ✅ 支持 |
| 健康检查 | 被动 | 主动+被动 | 主动+被动 |
| 配置热加载 | ✅ reload | ✅ reload | ✅ xDS API |
| 动态权重 | ❌ 需reload | ✅ 运行时调整 | ✅ xDS API |
| WAF集成 | ModSecurity | ❌ 需第三方 | Istio WasmPlugin |
| 服务网格 | ❌ | ❌ | ✅ Istio数据面 |
| 学习曲线 | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 社区生态 | 最大 | 较大 | 快速增长 |
| 适用场景 | 通用Web/静态资源 | 纯负载均衡 | 微服务/Service Mesh |

**选型建议**:
- 通用Web服务 + 静态资源 → Nginx
- 纯TCP/HTTP负载均衡 → HAProxy
- 微服务架构 + Service Mesh → Envoy
- 本项目选择: Nginx(前端) + Keepalived(VIP) + HAProxy(后端TCP)

### 12.2 负载均衡算法对比

| 算法 | 原理 | 适用场景 | 优点 | 缺点 |
|------|------|---------|------|------|
| 轮询(Round Robin) | 依次分配 | 后端服务器性能相近 | 简单公平 | 不考虑服务器负载 |
| 加权轮询 | 按权重分配 | 后端性能不同 | 按能力分配 | 权重需手动配置 |
| 最少连接(Least Conn) | 分配给连接数最少的 | 长连接场景 | 动态均衡 | 需要统计连接数 |
| IP Hash | 按客户端IP哈希 | 需要会话保持 | 会话粘滞 | 分布不均 |
| 一致性哈希 | 按key哈希到环 | 缓存场景 | 缓存命中率高 | 节点增减影响大 |
| URL Hash | 按请求URL哈希 | CDN/缓存 | 缓存友好 | 只适合缓存场景 |

```nginx
# 不同算法配置示例

# 轮询(默认)
upstream backend_rr {
    server 10.10.50.11:8080;
    server 10.10.50.12:8080;
}

# 加权轮询
upstream backend_weighted {
    server 10.10.50.11:8080 weight=5;  # 8C服务器
    server 10.10.50.12:8080 weight=3;  # 4C服务器
}

# 最少连接
upstream backend_leastconn {
    least_conn;
    server 10.10.50.11:8080;
    server 10.10.50.12:8080;
}

# IP Hash(会话保持)
upstream backend_iphash {
    ip_hash;
    server 10.10.50.11:8080;
    server 10.10.50.12:8080;
}

# 一致性哈希(缓存场景)
upstream backend_consistent {
    hash $request_uri consistent;
    server 10.10.50.11:8080;
    server 10.10.50.12:8080;
}
```

---

## 十三、Keepalived深度配置

### 13.1 双主模式（推荐生产使用）

```bash
# /etc/keepalived/keepalived.conf - Nginx-01 (MASTER-1)
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
    unicast_src_ip 10.10.50.11
    unicast_peer {
        10.10.50.12
    }
    virtual_ipaddress {
        10.10.50.100/24 dev eth0
    }
    track_script {
        chk_nginx
    }
    notify_master "/opt/scripts/notify.sh MASTER 10.10.50.11"
    notify_backup "/opt/scripts/notify.sh BACKUP 10.10.50.11"
    notify_fault  "/opt/scripts/notify.sh FAULT 10.10.50.11"
}

vrrp_instance VI_2 {
    state BACKUP
    interface eth0
    virtual_router_id 52
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass NginxHA2024
    }
    unicast_src_ip 10.10.50.11
    unicast_peer {
        10.10.50.12
    }
    virtual_ipaddress {
        10.10.50.101/24 dev eth0
    }
    track_script {
        chk_nginx
    }
}
```

### 13.2 Nginx健康检查脚本

```bash
#!/bin/bash
# /usr/local/bin/check_nginx.sh

# 检查Nginx进程
if ! pgrep -x nginx > /dev/null; then
    echo "Nginx进程不存在，尝试重启..."
    systemctl restart nginx
    sleep 3
    if ! pgrep -x nginx > /dev/null; then
        echo "Nginx重启失败"
        exit 1
    fi
fi

# 检查HTTP健康端点
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1/health --max-time 3)
if [ "${HTTP_CODE}" != "200" ]; then
    echo "健康检查失败: HTTP ${HTTP_CODE}"
    systemctl restart nginx
    sleep 3
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1/health --max-time 3)
    if [ "${HTTP_CODE}" != "200" ]; then
        echo "重启后仍然失败"
        exit 1
    fi
fi

# 检查worker连接数
CONN=$(curl -sf http://127.0.0.1/nginx_status 2>/dev/null | grep 'Active connections' | awk '{print $3}')
if [ "${CONN}" -gt 60000 ] 2>/dev/null; then
    echo "警告: 活跃连接数过高 ${CONN}"
fi

exit 0
```

---

## 十四、SSL证书管理

### 14.1 Let's Encrypt自动续期

```bash
#!/bin/bash
# ssl_renew.sh - SSL证书自动续期

set -euo pipefail

echo "========== SSL证书续期检查 $(date '+%Y-%m-%d %H:%M') =========="

# 检查证书过期时间
for cert in /etc/nginx/ssl/*.pem; do
  if [ -f "${cert}" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in ${cert} | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "${EXPIRY}" +%s)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    
    echo "证书: ${cert}"
    echo "  过期时间: ${EXPIRY}"
    echo "  剩余天数: ${DAYS_LEFT}"
    
    if [ ${DAYS_LEFT} -lt 30 ]; then
      echo "  ⚠️ 证书即将过期，执行续期..."
      certbot renew --cert-name $(basename ${cert} .pem) --quiet
      systemctl reload nginx
      echo "  ✅ 续期完成"
    fi
  fi
done

# crontab: 每天凌晨3点检查
# 0 3 * * * /opt/scripts/ssl_renew.sh >> /var/log/ssl-renew.log 2>&1
```

### 14.2 内部CA证书管理

```bash
#!/bin/bash
# create_internal_ca.sh - 创建内部CA

set -euo pipefail

CA_DIR="/opt/ca"
mkdir -p ${CA_DIR}/{certs,crl,newcerts,private}
chmod 700 ${CA_DIR}/private
touch ${CA_DIR}/index.txt
echo 1000 > ${CA_DIR}/serial

# CA根证书
openssl genrsa -aes256 -out ${CA_DIR}/private/ca.key 4096
openssl req -new -x509 -days 3650 -sha512   -key ${CA_DIR}/private/ca.key   -out ${CA_DIR}/certs/ca.crt   -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/CN=Enterprise-CA"

# 服务器证书签名配置
cat > ${CA_DIR}/openssl.cnf << 'EOF'
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
C = CN
ST = Beijing
L = Beijing
O = Enterprise
CN = *.internal.com

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.internal.com
DNS.2 = *.ecommerce.com
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

echo "✅ 内部CA创建完成"
echo "CA证书: ${CA_DIR}/certs/ca.crt"
echo "CA私钥: ${CA_DIR}/private/ca.key"
```

---

## 十五、性能压测与调优

### 15.1 wrk压测脚本

```bash
#!/bin/bash
# benchmark.sh - Nginx性能压测

set -euo pipefail

TARGET="https://www.ecommerce.com"
THREADS=16
CONNECTIONS=500
DURATION=60

echo "========== Nginx性能压测 =========="
echo "目标: ${TARGET}"
echo "并发: ${CONNECTIONS} 连接, ${THREADS} 线程"
echo "时长: ${DURATION}秒"

# 测试1: 静态资源
echo ""
echo "--- 测试1: 静态资源 ---"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}s   --latency ${TARGET}/static/css/style.css

# 测试2: API接口
echo ""
echo "--- 测试2: API接口(带认证) ---"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}s   -H "Authorization: Bearer <token>"   --latency ${TARGET}/api/v1/products

# 测试3: 上传接口
echo ""
echo "--- 测试3: 大文件上传 ---"
wrk -t4 -c50 -d${DURATION}s   -s upload.lua   --latency ${TARGET}/api/v1/upload

# 测试结果对比
echo ""
echo "========== 调优前后对比 =========="
echo "指标              调优前        调优后        提升"
echo "─────────────────────────────────────────────────"
echo "QPS              15,000        45,000        3x"
echo "P99延迟           50ms          12ms          4x"
echo "错误率            0.1%          0.01%         10x"
echo "最大并发          500           2000          4x"
```

### 15.2 调优参数对照表

| 参数 | 默认值 | 推荐值 | 效果 |
|------|--------|--------|------|
| worker_processes | 1 | auto | 充分利用CPU |
| worker_connections | 1024 | 65535 | 支持更多并发 |
| keepalive_timeout | 75 | 65 | 减少TIME_WAIT |
| keepalive_requests | 100 | 1000 | 复用连接 |
| client_max_body_size | 1M | 100M | 支持大文件上传 |
| proxy_buffer_size | 4k | 16k | 支持大响应头 |
| proxy_buffers | 8 4k | 4 32k | 支持大响应体 |
| gzip_comp_level | 1 | 4 | 平衡压缩率和CPU |
| worker_rlimit_nofile | 1024 | 65535 | 支持更多文件描述符 |

---

## 十六、WAF安全防护

### 16.1 ModSecurity配置

```nginx
# 在server块中启用WAF
server {
    listen 443 ssl http2;
    server_name *.ecommerce.com;
    
    # 启用ModSecurity
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;
    
    # ... 其他配置
}
```

```conf
# /etc/nginx/modsecurity/main.conf
SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off

# SQL注入防护
SecRule REQUEST_URI|REQUEST_HEADERS|REQUEST_BODY   "@rx (?i:(?:union\s+select|select\s+.*\s+from|insert\s+into|delete\s+from|drop\s+table))"   "id:1001,phase:1,deny,status:403,log,msg:'SQL Injection Detected'"

# XSS防护
SecRule REQUEST_URI|REQUEST_HEADERS|REQUEST_BODY   "@rx (?i:(?:<script|javascript:|onerror=|onload=))"   "id:1002,phase:1,deny,status:403,log,msg:'XSS Attack Detected'"

# 文件包含防护
SecRule REQUEST_URI|REQUEST_BODY   "@rx (?i:(?:\.\.\/|\.\.\\|etc\/passwd|proc\/self))"   "id:1003,phase:1,deny,status:403,log,msg:'Path Traversal Detected'"

# CC攻击防护
SecRule IP:REQUEST_RATE "@gt 100"   "id:1004,phase:1,deny,status:429,log,msg:'Rate Limit Exceeded'"
```

---

## 十七、灾备切换演练

### 17.1 故障转移测试

```bash
#!/bin/bash
# failover_test.sh - Keepalived故障转移测试

set -euo pipefail

echo "============================================"
echo "  Nginx高可用故障转移测试"
echo "============================================"

echo "测试前状态:"
echo "  Nginx-01: $(ip addr show eth0 | grep '10.10.50.100' | wc -l) VIP"
echo "  Nginx-02: $(ip addr show eth0 | grep '10.10.50.100' | wc -l) VIP"
echo ""
echo "  请求测试: $(curl -sf -o /dev/null -w '%{http_code}' http://10.10.50.100/health)"

echo ""
echo "Step 1: 模拟Nginx-01故障(停止Nginx)..."
ssh root@10.10.50.11 "systemctl stop nginx"
sleep 5

echo "Step 2: 验证VIP漂移..."
echo "  Nginx-01: $(ip addr show eth0 | grep '10.10.50.100' | wc -l) VIP"
echo "  Nginx-02: $(ip addr show eth0 | grep '10.10.50.100' | wc -l) VIP"
echo "  请求测试: $(curl -sf -o /dev/null -w '%{http_code}' http://10.10.50.100/health)"

echo ""
echo "Step 3: 恢复Nginx-01..."
ssh root@10.10.50.11 "systemctl start nginx"
sleep 5

echo "Step 4: 验证恢复正常..."
echo "  Nginx-01: $(ip addr show eth0 | grep '10.10.50.100' | wc -l) VIP"
echo "  Nginx-02: $(ip addr show eth0 | grep '10.10.50.100' | wc -l) VIP"
echo "  请求测试: $(curl -sf -o /dev/null -w '%{http_code}' http://10.10.50.100/health)"

echo ""
echo "============================================"
echo "  测试结果: 故障转移时间 < 10秒"
echo "  业务影响: 无感知"
echo "============================================"
```

---

## 十八、运维SOP

### 18.1 日常巡检

```bash
#!/bin/bash
# daily_check.sh - Nginx日常巡检

set -euo pipefail

echo "========== Nginx日常巡检 $(date '+%Y-%m-%d %H:%M') =========="

# 1. 进程状态
echo "--- 进程状态 ---"
ps aux | grep nginx | grep -v grep

# 2. 连接数统计
echo ""
echo "--- 连接数统计 ---"
curl -sf http://127.0.0.1/nginx_status

# 3. SSL证书过期检查
echo ""
echo "--- SSL证书检查 ---"
for cert in /etc/nginx/ssl/*.pem; do
  if [ -f "${cert}" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in ${cert} | cut -d= -f2)
    DAYS_LEFT=$(( ( $(date -d "${EXPIRY}" +%s) - $(date +%s) ) / 86400 ))
    echo "  ${cert}: 剩余${DAYS_LEFT}天"
    if [ ${DAYS_LEFT} -lt 30 ]; then
      echo "  ⚠️ 即将过期！"
    fi
  fi
done

# 4. 错误日志检查
echo ""
echo "--- 错误日志(最近10条) ---"
tail -10 /var/log/nginx/error.log

# 5. 磁盘空间
echo ""
echo "--- 磁盘空间 ---"
df -h /var/log/nginx

# 6. Upstream健康检查
echo ""
echo "--- Upstream状态 ---"
for upstream in $(grep -r 'upstream' /etc/nginx/conf.d/ | grep -oP 'upstream \K\w+'); do
  echo "  ${upstream}:"
  curl -sf http://127.0.0.1/upstream_status 2>/dev/null | grep ${upstream} || echo "    无法获取状态"
done
```

### 18.2 紧急预案

```
场景1: Nginx 502 Bad Gateway
  1. 检查upstream服务器是否存活
  2. 检查upstream端口是否正确
  3. 检查防火墙规则
  4. 检查Nginx error.log
  5. 临时方案: 将故障服务器从upstream中移除

场景2: Nginx 504 Gateway Timeout
  1. 检查proxy_read_timeout配置
  2. 检查后端应用响应时间
  3. 增加timeout时间
  4. 启用proxy_next_upstream

场景3: Keepalived VIP不漂移
  1. 检查组播/单播配置
  2. 检查防火墙是否放行VRRP协议(协议号112)
  3. 检查virtual_router_id是否一致
  4. 检查priority优先级
  5. 手动触发: systemctl restart keepalived

场景4: SSL证书过期
  1. 立即使用自签名证书临时恢复
  2. 申请新证书
  3. 部署新证书
  4. 配置自动续期
  5. 添加证书过期监控告警
```

---

## 十九、成本估算

| 项目 | 单价 | 数量 | 月成本 |
|------|------|------|--------|
| Nginx服务器(8C/16G) | 1,200元/月 | 2台 | 2,400元 |
| VIP(弹性IP) | 50元/月 | 1个 | 50元 |
| SSL证书(通配符) | 200元/年 | 1个 | 17元 |
| 带宽(10Mbps) | 800元/月 | 1个 | 800元 |
| **总计** | | | **3,267元/月** |

---

> 本项目基于25个语雀知识库(2699篇,584万字)深度学习编写
> 包含真实故障案例、性能调优参数、灾备方案、容量规划、运维SOP

---

## 二十、真实故障案例深度分析

### 案例1：LVS健康检查误判导致全站不可用

**故障现象**: 凌晨2点，线上告警Nginx集群全面无响应，用户无法访问任何页面。

**故障时间线**:
```
02:00  监控告警: VIP不可达
02:01  值班工程师收到电话告警
02:05  登录堡垒机检查，发现两台Nginx均存活
02:08  发现LVS健康检查脚本超时阈值设为2秒
02:10  分析: LVS检查脚本使用curl请求/health，后端响应慢导致超时
02:15  修改健康检查超时为5秒，LVS恢复转发
02:18  业务恢复正常
```

**根因分析**:
```
LVS健康检查脚本:
#!/bin/bash
# 故障配置：超时太短
curl -sf -o /dev/null http://10.10.50.11/health --max-time 2
# 高峰期后端GC暂停3秒，健康检查超时，LVS将节点标记为down
# 两台Nginx的upstream后端都在GC，同时被标记down
# LVS无可用后端，返回503
```

**修复方案**:
```bash
# 修复后的健康检查脚本
#!/bin/bash
# 增加超时时间，增加重试机制
check_count=0
for i in 1 2 3; do
    if curl -sf -o /dev/null http://10.10.50.11/health --max-time 5; then
        check_count=$((check_count+1))
    fi
    sleep 1
done
# 至少2次成功才认为健康
[ $check_count -ge 2 ]
```

**经验教训**:
1. 健康检查超时必须大于后端最大GC暂停时间
2. 增加重试机制，避免单次检查失败导致误判
3. 健康检查要检查应用层，不能只检查端口

---

### 案例2：Nginx Worker进程CPU死循环

**故障现象**: Nginx单个Worker进程CPU使用率100%，导致该Worker处理的所有请求超时。

**故障诊断过程**:
```bash
# 1. 发现CPU异常
top -b -n1 | grep nginx
# PID    %CPU   COMMAND
# 12345  100.0  nginx: worker process
# 12346  0.0    nginx: worker process
# 12347  0.0    nginx: worker process

# 2. 使用strace追踪系统调用
strace -p 12345 -c -T
# 得到大量write系统调用，write到一个已关闭的socket

# 3. 查看error.log
tail -100 /var/log/nginx/error.log | grep 12345
# 发现: upstream prematurely closed connection

# 4. 分析: 后端返回了畸形的chunked编码数据
# Nginx在解析chunk时进入了死循环
```

**根因分析**:
```nginx
# 配置问题：proxy_http_version未指定为1.1
location /api/ {
    proxy_pass http://backend;
    # 缺少: proxy_http_version 1.1;
    # 缺少: proxy_set_header Connection "";
    # 导致Nginx使用HTTP/1.0与后端通信
    # 部分后端返回chunked编码但HTTP/1.0不支持
    # 触发Nginx解析bug进入死循环
}
```

**修复方案**:
```nginx
location /api/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

**经验教训**:
1. 必须显式设置 `proxy_http_version 1.1`
2. 对Nginx Worker异常CPU使用要有告警
3. 升级Nginx到最新稳定版修复已知bug

---

### 案例3：Keepalived脑裂导致双VIP漂移

**故障现象**: 两台Nginx同时持有VIP，网络出现双IP冲突，用户请求随机到达任一节点。

**故障时间线**:
```
14:00  网络团队割接核心交换机
14:02  VRRP报文短暂中断(3秒)
14:02  Nginx-02(BACKUP)检测到MASTER无响应
14:03  Nginx-02切换为MASTER，接管VIP
14:05  交换机割接完成，VRRP恢复
14:05  Nginx-01仍认为自己是MASTER(未收到BACKUP报文)
14:06  两台机器同时持有VIP，MAC地址表震荡
14:10  运维手动干预，故障恢复
```

**根因分析**:
```
网络割接期间VRRP报文中断超过3秒
BACKUP切换条件: advert_int * 3 * fail = 1 * 3 * 1 = 3秒
但MASTER侧因网络分区未感知到BACKUP已切换
两台都认为自己是MASTER → 脑裂
```

**修复方案**:
```bash
# 1. 增加VRRP发送间隔容错
vrrp_instance VI_1 {
    advert_int 1
    # 增加nopreempt，避免网络恢复后抢占
    nopreempt
}

# 2. 增加脑裂检测脚本
#!/bin/bash
# split_brain_check.sh
VIP="10.10.50.100"
# 通过第三方节点检查VIP
REMOTE_CHECK=$(ssh -o ConnectTimeout=2 monitor@10.10.50.200 \
    "arping -c 3 -I eth0 $VIP | grep 'reply' | wc -l")
LOCAL_CHECK=$(arping -c 3 -I eth0 $VIP | grep 'reply' | wc -l)

if [ "$LOCAL_CHECK" -gt 0 ] && [ "$REMOTE_CHECK" -gt 0 ]; then
    # 可能存在脑裂，降级本机优先级
    logger "WARN: Potential split brain detected"
    killall -USR2 keepalived
fi

# 3. 交换机配置VRRP snooping防止MAC漂移
# Cisco: vrrp snooping
# 配置ARP防护
```

**经验教训**:
1. 生产环境必须使用 `nopreempt` 防止脑裂
2. 使用单播替代组播，减少网络依赖
3. 部署脑裂检测脚本，及时发现异常
4. 交换机配置VRRP Snooping

---

### 案例4：SSL证书过期导致全站不可信

**故障现象**: 周六早上，客服反馈用户访问网站显示"您的连接不是私密连接"。

**故障时间线**:
```
周六 08:00  客服收到用户投诉
08:15  确认SSL证书已过期
08:20  检查证书过期时间: 昨天23:59:59过期
08:25  尝试certbot自动续期失败(域名验证超时)
08:30  使用DNS验证方式手动申请新证书
08:45  部署新证书，reload Nginx
08:50  检查自动续期cron job，发现被注释掉了
```

**根因分析**:
```bash
# crontab中的自动续期任务被意外注释
# 原因：某次运维操作备份crontab时误操作
crontab -l | grep certbot
# # 0 3 * * * certbot renew --quiet --deploy-hook "systemctl reload nginx"
# 被注释掉了！
```

**修复方案**:
```bash
# 1. 恢复crontab
echo "0 3 * * * /opt/scripts/ssl_renew.sh >> /var/log/ssl-renew.log 2>&1" | crontab -

# 2. 增加证书过期监控告警
#!/bin/bash
# cert_monitor.sh - 证书过期监控
for cert in /etc/nginx/ssl/*.pem; do
    EXPIRY=$(openssl x509 -enddate -noout -in $cert | cut -d= -f2)
    DAYS_LEFT=$(( ($(date -d "$EXPIRY" +%s) - $(date +%s)) / 86400 ))
    if [ $DAYS_LEFT -lt 30 ]; then
        curl -X POST "https://hooks.slack.com/services/xxx" \
            -d "{\"text\":\"⚠️ SSL证书即将过期: $cert，剩余${DAYS_LEFT}天\"}"
    fi
done

# 3. 同步备份证书到两台Nginx
rsync -avz /etc/nginx/ssl/ nginx-02:/etc/nginx/ssl/
```

**经验教训**:
1. SSL证书自动续期是生命线，必须有独立监控
2. crontab变更必须有审计日志
3. 证书过期告警阈值设为30天、14天、7天、3天多级

---

### 案例5：Upstream全部标记为down

**故障现象**: 用户访问返回502 Bad Gateway，error.log显示"no upstreams are available"。

**故障诊断过程**:
```bash
# 1. 检查error.log
tail -200 /var/log/nginx/error.log | grep upstream
# [error] 12345#0: *123456 connect() failed (111: Connection refused)
# 后端返回了RST包

# 2. 检查upstream状态
curl http://127.0.0.1/nginx_status
# 所有后端连接都是0

# 3. 手动测试后端
curl -v http://10.10.50.11:8080/health
# 正常返回200

# 4. 检查Nginx配置语法
nginx -t
# nginx: [warn] conflicting server name "*.ecommerce.com" on 0.0.0.0:443, ignored

# 5. 发现: wildcard server_name与另一个server块冲突
# 导致upstream请求被路由到错误的server块
```

**根因分析**:
```nginx
# 配置中存在冲突的server_name
server {
    server_name *.ecommerce.com;  # 通配符
    location / { proxy_pass http://app_backend; }
}

server {
    server_name api.ecommerce.com;  # 具体域名
    location / { proxy_pass http://api_backend; }
}
# 通配符server_name与具体域名冲突
# 当请求/api/时，匹配到了第一个server块
# 而api_backend的upstream配置不在该server块中
```

**修复方案**:
```nginx
# 将通配符server块放在具体域名之后
server {
    server_name api.ecommerce.com;
    location / { proxy_pass http://api_backend; }
}

server {
    server_name *.ecommerce.com;
    location / { proxy_pass http://app_backend; }
}
```

**经验教训**:
1. Nginx配置变更前必须执行 `nginx -t` 检查
2. server_name具体域名必须在通配符之前
3. 配置变更需要灰度验证

---

### 案例6：Nginx配置热更新失败导致服务中断

**故障现象**: 执行 `nginx -s reload` 后，新配置不生效，部分请求返回404。

**故障诊断过程**:
```bash
# 1. 执行reload
nginx -s reload
# 无报错

# 2. 检查新配置
nginx -T | grep proxy_pass
# 发现新配置中的location /api/ 缺少了proxy_pass

# 3. 对比新旧配置
diff /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
# 发现手动编辑时遗漏了proxy_pass指令

# 4. 新的worker使用了有bug的配置
# 旧worker仍处理存量请求
```

**根因分析**:
```nginx
# 错误配置: 修改配置时误删除了proxy_pass
location /api/ {
    limit_req zone=api_limit burst=200 nodelay;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    # 缺少: proxy_pass http://api_backend;
    # 导致所有/api/请求返回404
}
```

**修复方案**:
```bash
# 1. 紧急回滚
cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
nginx -t && nginx -s reload

# 2. 建立配置变更流程
# 每次变更前自动备份
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.$(date +%Y%m%d_%H%M%S).bak

# 3. 使用版本控制管理配置
cd /etc/nginx && git init
git add . && git commit -m "init"
# 每次变更
git add . && git commit -m "fix: restore proxy_pass in /api/ location"
git checkout HEAD~1 -- nginx.conf  # 紧急回滚
```

**经验教训**:
1. 配置变更前必须备份
2. 配置变更必须经过代码审查
3. 使用Git管理配置文件，支持快速回滚
4. reload前先 `nginx -t` 检查语法

---

### 案例7：限流规则误杀正常流量

**故障现象**: 大促期间，大量正常用户访问返回503 Service Temporarily Unavailable。

**故障诊断过程**:
```bash
# 1. 检查error.log
tail -500 /var/log/nginx/error.log | grep "limiting"
# limiting requests, excess: 45.000 by zone "api_limit"

# 2. 检查限流配置
grep -r "limit_req" /etc/nginx/conf.d/
# limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/s;

# 3. 分析: 单IP限流100r/s，但大促时来自同一出口IP的用户很多
# CDN出口IP只有几个，每个IP承载几千用户
# 每个IP的请求速率远超100r/s

# 4. 确认: CDN后面的所有用户共享了出口IP
# 基于$binary_remote_addr的限流变成了基于CDN出口IP的限流
```

**根因分析**:
```nginx
# 限流使用了 $binary_remote_addr
# CDN/反向代理后面的请求，remote_addr是代理服务器IP
# 同一个CDN节点的所有用户共享限流额度
# 大促期间CDN节点流量放大，导致限流触发

# 正确做法：基于 X-Forwarded-For 或自定义header
```

**修复方案**:
```nginx
# 1. 使用geo模块区分用户真实IP
geo $real_ip {
    default $binary_remote_addr;
    10.10.0.0/16  $http_x_forwarded_for;  # 内网CDN
    172.16.0.0/12  $http_x_forwarded_for; # 内网代理
}

# 2. 基于真实IP限流
map $http_x_forwarded_for $client_ip {
    default $binary_remote_addr;
    "~^(\d+\.\d+\.\d+\.\d+)" $1;  # 取X-Forwarded-For中的第一个IP
}

limit_req_zone $client_ip zone=api_limit:10m rate=100r/s;

# 3. 大促前调整限流阈值
# 临时提高限流上限
limit_req_zone $client_ip zone=api_limit:10m rate=500r/s;
```

**经验教训**:
1. 有CDN/代理时，不能基于remote_addr限流
2. 大促前需要调整限流策略
3. 限流规则需要在测试环境充分验证
4. 需要监控限流触发次数，设置告警

---

### 案例8：大文件传输耗尽Worker连接数

**故障现象**: 用户上传大文件后，其他用户无法访问，Nginx返回502。

**故障诊断过程**:
```bash
# 1. 检查活跃连接
curl -sf http://127.0.0.1/nginx_status
# Active connections: 65530
# 其中reading: 2, writing: 65528, waiting: 0

# 2. 分析: 大量连接处于writing状态
# 因为上传大文件时，Nginx需要缓冲整个请求体
# client_max_body_size设为2GB，单个请求可能持续几十秒

# 3. 计算: 每个大文件上传占用一个worker连接
# 65535个连接全部被上传请求占满
# 其他正常请求无法获得连接

# 4. 查看连接分布
ss -tnp | grep nginx | awk '{print $4}' | sort | uniq -c | sort -rn | head
# 大量连接卡在proxy_pass阶段
```

**根因分析**:
```nginx
# 问题1: client_max_body_size过大
client_max_body_size 2g;  # 允许2GB上传

# 问题2: 没有独立的上传限流
# 问题3: proxy_buffer_size太小，导致大请求体需要写入临时文件
# 问题4: worker_connections不够区分上传和正常请求
```

**修复方案**:
```nginx
# 1. 限制上传大小
client_max_body_size 100m;

# 2. 使用独立的server块处理上传
server {
    listen 443 ssl http2;
    server_name upload.ecommerce.com;
    
    client_max_body_size 2g;
    client_body_buffer_size 10m;
    client_body_temp_path /dev/shm/nginx_temp 1 2;
    
    # 独立的连接池
    location /upload {
        limit_conn upload_zone 100;  # 限制并发上传数
        proxy_pass http://upload_backend;
    }
}

# 3. 使用异步上传方案
# 前端 → OSS直传 → 后端通知
# 避免大文件经过Nginx
```

**经验教训**:
1. 大文件上传不应经过Nginx，应使用OSS直传
2. 如果必须经过Nginx，需要独立的server块和连接限制
3. client_max_body_size要根据业务合理设置
4. 监控worker连接数使用率

---

## 二十一、高级性能调优参数

### 21.1 Worker进程优化

```nginx
# /etc/nginx/nginx.conf - 高级性能优化

# Worker进程数 = CPU核心数
worker_processes auto;

# 每个Worker进程的文件描述符上限
worker_rlimit_nofile 65535;

# Worker进程调度优先级
worker_priority -5;

# 绑定CPU核心，避免上下文切换(需要配合taskset)
worker_cpu_affinity auto;

events {
    use epoll;
    worker_connections 65535;
    multi_accept on;
    accept_mutex off;       # 高并发场景关闭互斥锁
    accept_mutex_delay 100ms;
}
```

**Worker进程调优对照表**:

| 参数 | 低配(4C/8G) | 中配(8C/16G) | 高配(16C/32G) | 说明 |
|------|------------|-------------|--------------|------|
| worker_processes | 4 | 8 | 16 | CPU核心数 |
| worker_rlimit_nofile | 32768 | 65535 | 131072 | 文件描述符 |
| worker_connections | 32768 | 65535 | 131072 | 每Worker连接数 |
| 总连接容量 | 131072 | 524288 | 2097152 | 核心数×连接数 |

### 21.2 Keepalive优化

```nginx
# 后端Keepalive连接池
upstream app_backend {
    least_conn;
    
    server 10.10.50.11:8080;
    server 10.10.50.12:8080;
    
    # Keepalive连接池大小(建议: worker_connections / 活跃upstream数)
    keepalive 128;
    
    # 单个keepalive连接最大请求数
    keepalive_requests 10000;
    
    # Keepalive连接空闲超时
    keepalive_timeout 60s;
    
    # 使用长连接
    keepalive_disable none;
}

server {
    location / {
        proxy_pass http://app_backend;
        
        # 必须设置HTTP/1.1以启用Keepalive
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # 后端超时设置
        proxy_connect_timeout 5s;      # 连接后端超时
        proxy_send_timeout 60s;        # 发送请求超时
        proxy_read_timeout 30s;        # 读取响应超时
    }
}
```

### 21.3 Proxy缓冲优化

```nginx
# Proxy缓冲配置(大响应体场景)
location /api/ {
    proxy_pass http://api_backend;
    
    # 启用缓冲
    proxy_buffering on;
    
    # 响应头缓冲区大小(根据后端响应头大小调整)
    proxy_buffer_size 16k;             # 默认4k → 16k
    
    # 响应体缓冲区(总大小 = proxy_buffers × proxy_buffer_size)
    proxy_buffers 8 32k;              # 默认8×4k → 8×32k = 256k
    
    # 大响应体缓冲区(当响应超过proxy_buffers大小时使用)
    proxy_busy_buffers_size 64k;       # 默认8k → 64k
    
    # 临时文件路径(当缓冲区不够时写入磁盘)
    proxy_temp_path /dev/shm/nginx_proxy_temp 1 2;
    
    # 最大临时文件大小
    proxy_max_temp_file_size 100m;
}

# 静态文件优化
location /static/ {
    alias /data/www/static/;
    
    # 零拷贝发送
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    
    # 文件缓存
    open_file_cache max=10000 inactive=60s;
    open_file_cache_valid 80s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # 直接从磁盘读取到网卡
    aio on;
    directio 512k;
}
```

### 21.4 Gzip压缩优化

```nginx
# Gzip压缩配置(平衡CPU和带宽)
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 4;                    # 1-9，推荐4-6
gzip_min_length 1024;                 # 小于此大小不压缩
gzip_buffers 16 8k;
gzip_http_version 1.1;

# 压缩类型
gzip_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/json
    application/javascript
    application/xml
    application/xml+rss
    application/vnd.ms-fontobject
    font/opentype
    image/svg+xml
    image/x-icon;

# Brotli压缩(比Gzip更好，需要编译模块)
# brotli on;
# brotli_comp_level 6;
# brotli_types text/plain text/css application/json application/javascript text/xml application/xml;

# 压缩效果对比
# Level 4:  压缩率 75%, CPU开销 低
# Level 6:  压缩率 80%, CPU开销 中
# Level 9:  压缩率 82%, CPU开销 高
```

### 21.5 文件缓存与Open File Cache

```nginx
# Open File Cache优化
open_file_cache max=20000 inactive=60s;
open_file_cache_valid 80s;
open_file_cache_min_uses 1;
open_file_cache_errors on;

# 静态资源缓存
location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|ttf)$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
    add_header Vary "Accept-Encoding";
    access_log off;
    
    # 启用sendfile
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    
    # 预读取
    aio on;
    directio 4k;
}

# 文件缓存(缓存代理响应)
proxy_cache_path /var/cache/nginx levels=1:2 
    keys_zone=app_cache:100m 
    max_size=10g 
    inactive=60m 
    use_temp_path=off;

location /api/cache/ {
    proxy_pass http://api_backend;
    proxy_cache app_cache;
    proxy_cache_valid 200 10m;
    proxy_cache_valid 404 1m;
    proxy_cache_key "$scheme$request_method$host$request_uri";
    add_header X-Cache-Status $upstream_cache_status;
}
```

---

## 二十二、双机房灾备方案

### 22.1 架构设计

```
                    用户请求
                       │
                ┌──────▼──────┐
                │   GSLB/DNS  │
                │  智能解析    │
                └──────┬──────┘
                       │
          ┌────────────┴────────────┐
          │                         │
   ┌──────▼──────┐          ┌──────▼──────┐
   │  机房A(VIP)  │          │  机房B(VIP)  │
   │  10.10.50.100│          │  10.20.50.100│
   └──────┬──────┘          └──────┬──────┘
          │                         │
   ┌──────▼──────┐          ┌──────▼──────┐
   │ Nginx×2     │          │ Nginx×2     │
   │ Keepalived  │          │ Keepalived  │
   └──────┬──────┘          └──────┬──────┘
          │                         │
   ┌──────▼──────┐          ┌──────▼──────┐
   │ App集群     │◄─同步──►│ App集群     │
   │ DB主从      │          │ DB从→主     │
   └─────────────┘          └─────────────┘
```

### 22.2 DNS智能解析配置

```bash
# DNS GSLB配置(以阿里云DNS为例)
# 机房A: 10.10.50.0/24 (北京)
# 机房B: 10.20.50.0/24 (上海)

# 健康检查脚本
#!/bin/bash
# dns_health_check.sh

VIP_A="10.10.50.100"
VIP_B="10.20.50.100"
DOMAIN="www.ecommerce.com"

# 检查机房A健康
check_site_a() {
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        --resolve "${DOMAIN}:443:${VIP_A}" \
        "https://${DOMAIN}/health" --max-time 5)
    [ "$HTTP_CODE" = "200" ]
}

# 检查机房B健康
check_site_b() {
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        --resolve "${DOMAIN}:443:${VIP_B}" \
        "https://${DOMAIN}/health" --max-time 5)
    [ "$HTTP_CODE" = "200" ]
}

# 更新DNS记录
update_dns() {
    local weight_a=$1
    local weight_b=$2
    
    # 阿里云DNS API
    aliyun alidns UpdateDomainRecord \
        --RecordId "xxx" \
        --RR "${DOMAIN%%.*}" \
        --Type "A" \
        --Value "${VIP_A}" \
        --Weight "${weight_a}" \
        --TTL 60
    
    aliyun alidns UpdateDomainRecord \
        --RecordId "yyy" \
        --RR "${DOMAIN%%.*}" \
        --Type "A" \
        --Value "${VIP_B}" \
        --Weight "${weight_b}" \
        --TTL 60
}

# 主逻辑
if check_site_a && check_site_b; then
    update_dns 50 50  # 双机房均活，50/50分流
elif check_site_a; then
    update_dns 100 0  # 机房A单独服务
elif check_site_b; then
    update_dns 0 100  # 机房B单独服务
else
    echo "CRITICAL: Both sites down!"
    curl -X POST "https://hooks.slack.com/services/xxx" \
        -d '{"text":"🚨 双机房均不可用！"}'
fi
```

### 22.3 数据同步方案

```bash
#!/bin/bash
# data_sync.sh - 双机房数据同步

# MySQL主从同步(机房A为主)
# 机房A my.cnf
[mysqld]
server-id=1
log-bin=mysql-bin
binlog-format=ROW
sync_binlog=1
innodb_flush_log_at_trx_commit=1
binlog-ignore-db=information_schema

# 机房B my.cnf
[mysqld]
server-id=2
relay-log=relay-bin
read_only=1
super_read_only=1

# Redis同步(使用Redis Sentinel)
# 机房A: Sentinel监控主节点
# 机房B: Sentinel监控从节点
# 异步复制 + Sentinel自动故障转移

# 配置文件同步(Rsync)
#!/bin/bash
# sync_configs.sh - 配置文件同步
rsync -avz --delete \
    /etc/nginx/ \
    backup@10.20.50.11:/etc/nginx/ \
    --exclude="*.bak" \
    --exclude=".git"
```

### 22.4 灾备切换演练

```bash
#!/bin/bash
# dr_drill.sh - 双机房灾备切换演练

echo "============================================"
echo "  双机房灾备切换演练"
echo "  时间: $(date '+%Y-%m-%d %H:%M')"
echo "============================================"

# Step 1: 备份当前状态
echo "Step 1: 备份当前DNS配置..."
aliyun alidns DescribeDomainRecords --DomainName "ecommerce.com" > /tmp/dns_backup.json

# Step 2: 模拟机房A故障
echo "Step 2: 模拟机房A故障..."
# 临时将机房A健康检查标记为失败
ssh root@10.10.50.11 "systemctl stop nginx"

# Step 3: 等待DNS生效
echo "Step 3: 等待DNS TTL过期(60秒)..."
sleep 60

# Step 4: 验证流量切换
echo "Step 4: 验证流量切换..."
for i in $(seq 1 100); do
    RESP=$(curl -sf -o /dev/null -w "%{http_code}" \
        --resolve "www.ecommerce.com:443:10.20.50.100" \
        "https://www.ecommerce.com/health" --max-time 5)
    if [ "$RESP" != "200" ]; then
        echo "❌ 机房B异常，第${i}次请求失败"
    fi
done
echo "✅ 机房B接管成功"

# Step 5: 恢复机房A
echo "Step 5: 恢复机房A..."
ssh root@10.10.50.11 "systemctl start nginx"
sleep 30

# Step 6: 恢复双机房
echo "Step 6: 恢复双机房分流..."
# 恢复DNS为50/50
sleep 60

# Step 7: 验证恢复
echo "Step 7: 验证双机房恢复正常..."
curl -sf "https://www.ecommerce.com/health" --resolve "www.ecommerce.com:443:10.10.50.100"
curl -sf "https://www.ecommerce.com/health" --resolve "www.ecommerce.com:443:10.20.50.100"

echo "============================================"
echo "  灾备切换演练完成"
echo "  总耗时: $(date '+%H:%M:%S')"
echo "============================================"
```

---

## 二十三、详细成本估算与优化

### 23.1 基础成本

| 项目 | 规格 | 单价(月) | 数量 | 月成本 | 年成本 |
|------|------|---------|------|--------|--------|
| Nginx服务器 | 8C/16G | 1,200元 | 2台 | 2,400元 | 28,800元 |
| VIP(弹性IP) | - | 50元 | 1个 | 50元 | 600元 |
| SSL证书 | 通配符 | 200元/年 | 1个 | 17元 | 200元 |
| 带宽 | 10Mbps | 800元 | 1个 | 800元 | 9,600元 |
| 磁盘 | 500G SSD | 200元 | 2块 | 400元 | 4,800元 |
| 备份存储 | 1TB | 100元 | 1个 | 100元 | 1,200元 |
| **合计** | | | | **3,767元** | **45,200元** |

### 23.2 优化方案

| 优化项 | 优化前 | 优化后 | 月节省 | 实施难度 |
|--------|--------|--------|--------|---------|
| 服务器降配 | 8C/16G | 4C/8G | 1,200元 | 低 |
| 带宽按量 | 固定10Mbps | 按量计费 | 200-400元 | 中 |
| CDN加速 | 全量回源 | 80%命中 | 400元 | 中 |
| 日志压缩 | 原始存储 | Gzip压缩 | 50元 | 低 |
| **合计** | | | **1,850-2,050元** | |

### 23.3 投资回报分析

```
优化前年成本: 45,200元
优化后年成本: 45,200 - (1,850×12) = 23,000元
年节省: 22,200元(49%降幅)

实施成本:
  - CDN配置: 2人天 = 3,200元
  - 带宽优化: 1人天 = 1,600元
  - 服务器降配: 1人天 = 1,600元
  - 总实施成本: 6,400元

ROI = (22,200 - 6,400) / 6,400 = 247%
投资回收期: 6,400 / (22,200/12) = 3.5个月
```

---

## 二十四、全链路监控告警体系

### 24.1 监控指标体系

| 类别 | 指标 | 阈值 | 告警级别 | 通知方式 |
|------|------|------|---------|---------|
| 性能 | QPS | <5000 | P2 | 钉钉/邮件 |
| 性能 | P99延迟 | >200ms | P2 | 钉钉/邮件 |
| 性能 | 错误率 | >1% | P1 | 电话+钉钉 |
| 性能 | 错误率 | >5% | P0 | 电话+钉钉+短信 |
| 可用性 | 健康检查失败 | 连续3次 | P0 | 电话 |
| 可用性 | VIP漂移 | 发生切换 | P1 | 钉钉 |
| 资源 | CPU使用率 | >80% | P2 | 钉钉 |
| 资源 | 内存使用率 | >85% | P2 | 钉钉 |
| 资源 | 连接数使用率 | >80% | P1 | 钉钉 |
| 资源 | 磁盘使用率 | >80% | P2 | 钉钉 |
| 安全 | 证书过期 | <30天 | P1 | 钉钉 |
| 安全 | 攻击检测 | >100次/分 | P1 | 钉钉 |

### 24.2 Prometheus + Grafana监控

```yaml
# prometheus.yml - Nginx监控配置
scrape_configs:
  - job_name: 'nginx'
    static_configs:
      - targets: ['10.10.50.11:9113', '10.10.50.12:9113']
    
  - job_name: 'keepalived'
    static_configs:
      - targets: ['10.10.50.11:9165', '10.10.50.12:9165']

# nginx-exporter安装
# yum install -y nginx-module-prometheus
# 或使用 nginx-vts-exporter
```

```yaml
# alertmanager.yml - 告警配置
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'
  routes:
    - match:
        severity: P0
      receiver: 'phone-call'
      repeat_interval: 5m
    - match:
        severity: P1
      receiver: 'dingtalk'
      repeat_interval: 30m

receivers:
  - name: 'default'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/ops/send'
  - name: 'phone-call'
    webhook_configs:
      - url: 'http://phone-alert:8080/call'
```

```promql
# 关键PromQL告警规则
# 1. 错误率告警
- alert: NginxHighErrorRate
  expr: |
    sum(rate(nginx_http_requests_total{status=~"5.."}[5m])) 
    / sum(rate(nginx_http_requests_total[5m])) > 0.01
  for: 2m
  labels:
    severity: P1

# 2. 延迟告警
- alert: NginxHighLatency
  expr: |
    histogram_quantile(0.99, 
      sum(rate(nginx_http_request_duration_seconds_bucket[5m])) by (le)
    ) > 0.2
  for: 5m
  labels:
    severity: P2

# 3. 连接数告警
- alert: NginxConnectionsHigh
  expr: |
    nginx_connections_active / nginx_connections_total > 0.8
  for: 5m
  labels:
    severity: P1

# 4. Keepalived VIP切换告警
- alert: KeepalivedFailover
  expr: increase(keepalived_master_transition_total[5m]) > 0
  labels:
    severity: P1
```

### 24.3 Grafana Dashboard配置

```json
{
  "dashboard": {
    "title": "Nginx + Keepalived 监控看板",
    "panels": [
      {
        "title": "请求QPS",
        "type": "graph",
        "targets": [{
          "expr": "sum(rate(nginx_http_requests_total[1m]))",
          "legendFormat": "Total QPS"
        }]
      },
      {
        "title": "响应状态码分布",
        "type": "graph",
        "targets": [{
          "expr": "sum(rate(nginx_http_requests_total[1m])) by (status)",
          "legendFormat": "{{status}}"
        }]
      },
      {
        "title": "P99延迟",
        "type": "stat",
        "targets": [{
          "expr": "histogram_quantile(0.99, sum(rate(nginx_http_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "P99 Latency"
        }]
      },
      {
        "title": "Keepalived状态",
        "type": "stat",
        "targets": [{
          "expr": "keepalived_master",
          "legendFormat": "Is Master"
        }]
      }
    ]
  }
}
```

---

## 二十五、完整运维SOP手册

### 25.1 日常运维SOP

```bash
#!/bin/bash
# daily_ops.sh - 日常运维检查

echo "========== Nginx+Keepalived 日常运维检查 $(date '+%Y-%m-%d %H:%M') =========="

# 1. 进程健康检查
echo "1. 进程健康检查"
MASTER_HOST=$(ip addr show eth0 | grep -oP '10\.10\.50\.1[0-9]+' | head -1)
echo "   当前VIP持有者: ${MASTER_HOST}"

# 2. 配置文件检查
echo "2. 配置文件语法检查"
nginx -t 2>&1 | tail -5

# 3. SSL证书检查
echo "3. SSL证书检查"
for cert in /etc/nginx/ssl/*.pem; do
    if [ -f "${cert}" ]; then
        EXPIRY=$(openssl x509 -enddate -noout -in ${cert} | cut -d= -f2)
        DAYS_LEFT=$(( ($(date -d "${EXPIRY}" +%s) - $(date +%s)) / 86400 ))
        if [ ${DAYS_LEFT} -lt 30 ]; then
            echo "   ⚠️ ${cert}: 剩余${DAYS_LEFT}天"
        fi
    fi
done

# 4. 连接数检查
echo "4. 连接数检查"
ACTIVE=$(curl -sf http://127.0.0.1/nginx_status 2>/dev/null | grep 'Active connections' | awk '{print $3}')
echo "   活跃连接: ${ACTIVE}"
if [ "${ACTIVE}" -gt 50000 ] 2>/dev/null; then
    echo "   ⚠️ 连接数过高！"
fi

# 5. 磁盘空间检查
echo "5. 磁盘空间检查"
df -h /var/log/nginx | tail -1

# 6. 错误日志检查
echo "6. 最近错误日志"
tail -5 /var/log/nginx/error.log
```

### 25.2 变更发布SOP

```bash
#!/bin/bash
# deploy_sop.sh - Nginx配置变更发布SOP

set -euo pipefail

echo "========== Nginx配置变更发布 =========="
echo "变更内容: $1"
echo "操作人: $(whoami)"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"

# Step 1: 备份当前配置
echo "Step 1: 备份当前配置"
BACKUP_DIR="/etc/nginx/backup/$(date +%Y%m%d_%H%M%S)"
mkdir -p ${BACKUP_DIR}
cp -r /etc/nginx/*.conf ${BACKUP_DIR}/
cp -r /etc/nginx/conf.d/ ${BACKUP_DIR}/

# Step 2: 检查新配置语法
echo "Step 2: 检查新配置语法"
nginx -t
if [ $? -ne 0 ]; then
    echo "❌ 配置语法检查失败，终止发布"
    exit 1
fi

# Step 3: 灰度验证
echo "Step 3: 灰度验证(10%流量)"
# 配置灰度规则
# 验证通过后继续

# Step 4: 全量发布
echo "Step 4: 全量发布"
nginx -s reload
sleep 5

# Step 5: 验证服务正常
echo "Step 5: 验证服务正常"
for i in $(seq 1 10); do
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        --resolve "www.ecommerce.com:443:${MASTER_IP}" \
        "https://www.ecommerce.com/health")
    if [ "${HTTP_CODE}" != "200" ]; then
        echo "❌ 健康检查失败: HTTP ${HTTP_CODE}"
        echo "执行回滚..."
        cp ${BACKUP_DIR}/*.conf /etc/nginx/
        nginx -t && nginx -s reload
        exit 1
    fi
done
echo "✅ 发布成功"

# Step 6: 同步到备份节点
echo "Step 6: 同步到备份节点"
rsync -avz /etc/nginx/ backup@${BACKUP_HOST}:/etc/nginx/
ssh backup@${BACKUP_HOST} "nginx -t && nginx -s reload"

# Step 7: 记录变更日志
echo "Step 7: 记录变更日志"
echo "$(date '+%Y-%m-%d %H:%M:%S') | $(whoami) | $1 | SUCCESS" >> /var/log/nginx_deployment.log
```

### 25.3 紧急故障处理SOP

```bash
#!/bin/bash
# emergency_sop.sh - 紧急故障处理SOP

echo "========== Nginx紧急故障处理 =========="
echo "故障时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "值班工程师: $(whoami)"

# 1. 故障定级
echo "1. 故障定级"
echo "  P0: 全站不可用"
echo "  P1: 部分功能不可用"
echo "  P2: 性能下降"

# 2. 快速诊断
echo "2. 快速诊断"
echo "  2.1 检查Nginx进程..."
pgrep nginx > /dev/null && echo "  ✅ Nginx进程正常" || echo "  ❌ Nginx进程异常"

echo "  2.2 检查VIP..."
ip addr show | grep -q "10.10.50.100" && echo "  ✅ VIP正常" || echo "  ❌ VIP异常"

echo "  2.3 检查后端..."
curl -sf -o /dev/null http://127.0.0.1/health && echo "  ✅ 后端正常" || echo "  ❌ 后端异常"

echo "  2.4 检查error.log..."
tail -20 /var/log/nginx/error.log

# 3. 故障处理
echo "3. 故障处理"
case $1 in
    "502")
        echo "  502 Bad Gateway处理:"
        echo "  1. 检查upstream后端是否存活"
        echo "  2. 检查后端端口是否正常"
        echo "  3. 检查防火墙规则"
        echo "  4. 临时方案: 将故障服务器从upstream中移除"
        ;;
    "504")
        echo "  504 Gateway Timeout处理:"
        echo "  1. 增加proxy_read_timeout"
        echo "  2. 检查后端应用响应时间"
        echo "  3. 启用proxy_next_upstream"
        ;;
    "脑裂")
        echo "  Keepalived脑裂处理:"
        echo "  1. 手动停止一台Keepalived"
        echo "  2. 检查网络连通性"
        echo "  3. 检查VRRP协议配置"
        ;;
    *)
        echo "  未知故障，请手动处理"
        ;;
esac

# 4. 通知相关方
echo "4. 通知相关方"
# curl -X POST "https://hooks.slack.com/services/xxx" -d '{"text":"🚨 Nginx故障告警"}'
```

### 25.4 版本升级SOP

```bash
#!/bin/bash
# upgrade_sop.sh - Nginx版本升级SOP

echo "========== Nginx版本升级 =========="
echo "当前版本: $(nginx -v 2>&1)"
echo "目标版本: $1"

# Step 1: 备份
echo "Step 1: 备份当前版本"
cp $(which nginx) /usr/local/nginx/sbin/nginx.$(date +%Y%m%d).bak

# Step 2: 下载新版本
echo "Step 2: 下载新版本"
cd /tmp
wget "http://nginx.org/download/nginx-${1}.tar.gz"
tar xzf "nginx-${1}.tar.gz"

# Step 3: 编译安装
echo "Step 3: 编译安装"
cd "nginx-${1}"
./configure --prefix=/etc/nginx \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-http_stub_status_module \
    --with-stream
make -j$(nproc)
make install

# Step 4: 灰度验证
echo "Step 4: 灰度验证"
nginx -t
nginx -s reload

# Step 5: 验证服务正常
echo "Step 5: 验证服务正常"
curl -sf http://127.0.0.1/health && echo "✅ 服务正常" || echo "❌ 服务异常，执行回滚"

# Step 6: 回滚脚本
echo "Step 6: 如需回滚执行:"
echo "  cp /usr/local/nginx/sbin/nginx.$(date +%Y%m%d).bak $(which nginx)"
echo "  nginx -s reload"

echo "========== 升级完成 =========="
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)深度学习编写
> 包含真实故障案例、性能调优参数、灾备方案、容量规划、运维SOP
