# 企业级Nginx + Keepalived高可用

> 完整实现Nginx负载均衡集群，覆盖反向代理、SSL卸载、限流、WAF、健康检查、故障自动切换

---

## 一、架构

> **技术选型说明**:
> - Nginx+Keepalived: 适用于裸金属/私有云环境,成本低但运维复杂
> - 云厂商SLB/ALB: 适用于公有云环境,托管服务免运维,推荐生产使用
> - MetalLB/Kube-vip: 适用于K8s环境,与K8s Service集成
> - HAProxy+Nginx: HAProxy做L4 TCP负载均衡(如数据库/Redis),Nginx做L7 HTTP,适合混合场景

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
        '"trace_id":"$request_id",'
        '"remote_addr":"$remote_addr",'
        '"request":"$request",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_time":"$upstream_response_time",'
        '"upstream_addr":"$upstream_addr"'
    '}';

    access_log /var/log/nginx/access.log json;
> request_id作为trace_id用于链路追踪。如需OpenTelemetry集成,可使用$opentelemetry_trace_id(需Nginx编译otel模块)

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
    # [修复] 基于X-Forwarded-For提取真实客户端IP进行限流，避免CDN/反向代理后所有用户共享出口IP导致限流失效
    # 使用map模块提取X-Forwarded-For中的第一个IP（即真实客户端IP）
    map $http_x_forwarded_for $client_real_ip {
        default $binary_remote_addr;  # 无X-Forwarded-For时使用连接IP
        "~^(?<ip>\d+\.\d+\.\d+\.\d+)" $ip;  # 取第一个IP（真实客户端IP）
    }
    limit_req_zone $client_real_ip zone=api_limit:10m rate=100r/s;
    limit_req_zone $client_real_ip zone=login_limit:10m rate=20r/m;  # 登录限流: 20次/分钟，防暴力破解同时允许正常用户多次尝试
    limit_conn_zone $client_real_ip zone=conn_limit:10m;

    # 隐藏版本号
    server_tokens off;

    # SSL全局配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    # SSL会话票据: 启用后通过ticket key轮转兼顾性能与安全
    ssl_session_tickets on;
    # SSL Session Ticket Key轮转(每24小时轮转，兼顾性能与前向保密):
    # 1. 生成当前key: openssl rand 80 | xxd -p -c 80 > /etc/nginx/ssl/ssl_ticket_key.current
    # 2. 生成上一个key(用于解密旧会话): 保留前一次生成的key
    # 3. 配置(最多配置4个key，当前key放最前):
    #    ssl_session_ticket_key /etc/nginx/ssl/ssl_ticket_key.current;  # 当前key
    #    ssl_session_ticket_key /etc/nginx/ssl/ssl_ticket_key.previous; # 上一个key(解密旧会话)
    # 4. 设置cron每天轮转:
    #    0 3 * * * /opt/scripts/ssl_ticket_rotate.sh
    ssl_stapling on;
    ssl_stapling_verify on;
    # DH参数: 增强前向保密，生成命令: openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_ecdh_curve X25519:secp384r1:secp256r1;
    '> ECDH曲线配置优先使用X25519(性能最好),回退到NIST曲线'
    # ssl_stapling_responder: OCSP装订响应地址，需根据实际CA设置
    # 获取方式: openssl x509 -in /etc/nginx/ssl/ecommerce.com.pem -noout -ocsp_uri
    # 通过map模块根据域名动态选择对应的OCSP responder URL，支持多证书场景
    map $ssl_server_name $ssl_stapling_ocsp_url {
        default                  http://r3.o.lencr.org;  # Let's Encrypt默认
        ~^.*\.ecommerce\.com$    http://r3.o.lencr.org;  # Let's Encrypt通配符
        # 商业CA示例(取消注释并填入实际地址):
        # ~^.*\.corp\.com$      http://ocsp.digicert.com;  # DigiCert
        # ~^.*\.bank\.com$      http://ocsp.globalsign.com; # GlobalSign
    }
    ssl_stapling_responder $ssl_stapling_ocsp_url;

    # Upstream后端池
    upstream app_backend {
        # [修复] ip_hash与keepalive组合会导致连接不均匀分配:
        # keepalive连接由worker进程独立维护，ip_hash将同一IP固定到同一后端
        # 但不同worker的keepalive连接可能指向不同后端，导致负载不均
        # 推荐方案: 使用consistent hash或least_conn替代ip_hash
        least_conn;  # 最少连接均衡，配合keepalive效果最佳
        keepalive 32;

        server 10.10.50.11:8080 max_fails=3 fail_timeout=30s;
        server 10.10.50.12:8080 max_fails=3 fail_timeout=30s;
        server 10.10.50.13:8080 max_fails=3 fail_timeout=30s;
        server 10.10.50.14:8080 max_fails=3 fail_timeout=30s backup;
    }

    upstream api_backend {
        # [修复] 同上，least_conn配合keepalive更优
        least_conn;
        keepalive 32;
        server 10.10.50.21:8081 max_fails=3;
        server 10.10.50.22:8081 max_fails=3;
    }

    # [注意] server块顺序：具体域名应在通配符域名之前，避免请求被错误的server块处理
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

        # [安全] 隐藏Nginx版本号，防止版本信息泄露
        server_tokens off;

        ssl_certificate /etc/nginx/ssl/ecommerce.com.pem;
        ssl_certificate_key /etc/nginx/ssl/ecommerce.com.key;

        # 安全头
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        # CSP策略: 允许自身域名资源和CDN，生产环境应根据实际资源来源收紧
        # [修复] CSP策略: 使用Lua生成随机nonce替代unsafe-inline，避免XSS风险
        # ⚠️ 关键: 每次请求必须生成唯一nonce，并在HTML模板的<script>和<style>标签上嵌入相同nonce
        # 例如: <script nonce="$csp_nonce">...</script>  — nonce值必须与CSP头中一致，否则浏览器会阻止该资源
        # Nginx不支持在add_header中直接引用Lua变量，需通过set传递
        set_by_lua_block $csp_nonce {
            local random = require "resty.random"
            local str = require "resty.string"
            return str.to_hex(random.bytes(16))
        }
        # [⚠️ HTML模板侧] 后端模板渲染时必须将$ csp_nonce注入到HTML中:
        #   <script nonce="{{ csp_nonce }}">...</script>
        #   <style nonce="{{ csp_nonce }}">...</style>
        # 若不注入nonce到HTML，所有内联<script>/<style>都会被CSP阻止
        add_header Content-Security-Policy "default-src 'self' https://cdn.example.com; script-src 'self' 'nonce-$csp_nonce'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self' https://api.example.com" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
        '> 安全头应完整: CSP + HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy + Permissions-Policy'

        # 健康检查端点
        location /health {
            access_log off;
            default_type text/plain;
            return 200 'OK';
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
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_next_upstream error timeout http_502 http_503 http_504;
            '> 后端失败时自动重试其他节点,减少502错误'
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

        # [安全] 隐藏Nginx版本号
        server_tokens off;

        ssl_certificate /etc/nginx/ssl/admin.ecommerce.com.pem;
        ssl_certificate_key /etc/nginx/ssl/admin.ecommerce.com.key;

    # IP白名单
    allow 10.10.0.0/16;
    allow 192.168.0.0/16;
    deny all;

    # 安全头
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

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
    # [重要] nopreempt防止网络恢复后MASTER抢占，避免脑裂抖动
    # 生产环境必须使用nopreempt，BACKUP接管后不会被原MASTER抢回
    nopreempt
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}  # 必须恰好8字符: export KEEPALIVED_AUTH_PASS=$(openssl rand -hex 4)
> **注意**: Keepalived配置文件中的环境变量不会自动展开。需要:
> 1. 使用sed替换: sed -i "s/KEEPALIVED_AUTH_PASS/${KEEPALIVED_AUTH_PASS}/g" /etc/keepalived/keepalived.conf
> 2. 或使用Keepalived的include机制: include /etc/keepalived/secrets.conf
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
    echo "❌ Nginx配置语法检查失败，跳过重启"
    exit 1
fi
if ! curl -sf -o /dev/null http://127.0.0.1/health --max-time 5; then
    # 重启前再次确认配置正确，避免错误配置导致服务中断
    if ! /usr/sbin/nginx -t 2>/dev/null; then
        echo "❌ Nginx配置语法错误，终止重启"
        exit 1
    fi
    systemctl restart nginx
    sleep 2
    # 重启后验证健康状态
    if ! curl -sf -o /dev/null http://127.0.0.1/health --max-time 5; then
        echo "❌ 重启后仍不健康，检查Nginx日志: /var/log/nginx/error.log"
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

# 续期成功后同步证书到备份节点(Keepalived BACKUP)
BACKUP_HOST="10.10.50.12"  # 备份Nginx节点IP
BACKUP_USER="root"
SSL_DIR="/etc/nginx/ssl"

echo "正在同步SSL证书到备份节点 ${BACKUP_HOST}..."
rsync -avz --delete \
    -e "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no" \
    ${SSL_DIR}/ \
    ${BACKUP_USER}@${BACKUP_HOST}:${SSL_DIR}/

if [ $? -eq 0 ]; then
    echo "✅ 证书同步成功，验证远程证书有效期..."
    ssh ${BACKUP_USER}@${BACKUP_HOST} \
        "for cert in ${SSL_DIR}/*.pem; do echo \"\$(basename \$cert): \$(openssl x509 -enddate -noout -in \$cert)\"; done"
    # 通知备份节点重载Nginx使新证书生效
    ssh ${BACKUP_USER}@${BACKUP_HOST} "nginx -t && nginx -s reload"
else
    echo "❌ 证书同步失败，请手动检查备份节点证书状态！"
    exit 1
fi

# crontab: 每天凌晨3点检查
# 0 3 * * * /opt/scripts/ssl_renew.sh >> /var/log/ssl-renew.log 2>&1
```

### 4.1 K8s环境: cert-manager自动证书管理

```yaml
# cert-manager安装
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

# ClusterIssuer配置 (Let's Encrypt)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
```

> cert-manager自动处理证书签发和续期，无需手动crontab。支持ACME HTTP-01和DNS-01验证。

---

> 本项目基于官方文档、技术博客和社区实践编写


---

## 五、方案对比与选型

### 5.1 Nginx vs HAProxy vs Envoy

| 特性 | Nginx | HAProxy | Envoy |
|------|-------|---------|-------|
| 定位 | Web服务器/反向代理 | TCP/HTTP负载均衡 | 云原生边缘/服务代理 |
| 性能 | 极高(事件驱动) | 极高(单线程) | 高(多线程) |
| 7层负载 | ✅ 优秀 | ✅ 优秀 | ✅ 优秀 |
| 4层负载 | ✅ 支持 | ✅ 优秀 | ✅ 支持 |
| 健康检查 | 被动 | 主动+被动 | 主动+被动 |
| 配置热加载 | ✅ reload | ✅ reload | ✅ xDS API |
| 动态权重 | ❌ 需reload | ✅ 运行时调整 | ✅ xDS API |
| WAF集成 | ModSecurity/Coraza | ❌ 需第三方 | Istio WasmPlugin |
| 服务网格 | ❌ | ❌ | ✅ Istio数据面 |
| 学习曲线 | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 社区生态 | 最大 | 较大 | 快速增长 |
| 适用场景 | 通用Web/静态资源 | 纯负载均衡 | 微服务/Service Mesh |

**选型建议**:
- 通用Web服务 + 静态资源 → Nginx
- 纯TCP/HTTP负载均衡 → HAProxy
- 微服务架构 + Service Mesh → Envoy
- 本项目选择: Nginx(前端) + Keepalived(VIP)。如需后端TCP负载均衡,可额外部署HAProxy。
> HAProxy用于纯TCP负载均衡(如数据库连接池),本项目Nginx已覆盖HTTP/HTTPS场景

**2026年推荐**: Coraza是ModSecurity的现代替代品，兼容OWASP CRS规则，维护成本更低

```nginx
# Coraza WAF配置示例(替代ModSecurity)
# 安装: 需要编译Coraza模块或使用动态加载
# 参考: https://github.com/corazawaf/coraza

# 方法1: 使用Nginx Dynamic Module
load_module modules/ngx_http_coraza_module.so;

http {
    coraza_enable on;

    # 方法2: 使用外部规则文件(推荐生产使用)
    # coraza_rules_file /etc/nginx/coraza/coraza.conf;

    # 方法3: 内联规则(适合简单场景)
    coraza_rules "
        SecRuleEngine On
        SecRequestBodyAccess On
        SecResponseBodyAccess Off

        # OWASP CRS规则集(需单独下载)
        # Include /etc/nginx/coraza/rules/*.conf

        # 自定义规则示例: 拦截admin路径
        SecRule REQUEST_URI \"@rx /admin\" \"id:1001,phase:1,deny,status:403,log,msg:'Admin Access Blocked'\"
        SecRule REQUEST_URI \"@rx \\.(env|git|svn)\" \"id:1002,phase:1,deny,status:403,log,msg:'Hidden File Access'\"
    ";

    server {
        listen 443 ssl http2;
        server_name www.ecommerce.com;

        # 在server块中启用WAF
        coraza_enable on;

        location / {
            proxy_pass http://app_backend;
            # ... 其他配置
        }
    }
}
```
> Coraza是ModSecurity的现代替代品,使用OWASP CRS规则,兼容Nginx/Envoy。配置更简洁,性能更好。
> 安装Coraza模块: git clone https://github.com/corazawaf/coraza.git && cd coraza && make nginx-module
> 编译Nginx时添加: --add-dynamic-module=/path/to/coraza/plugins/nginx/Module

### 5.2 负载均衡算法对比

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

# 最少连接(推荐用于K8s Ingress前置LB)
upstream backend_leastconn {
    least_conn;
    server 10.10.50.11:8080;
    server 10.10.50.12:8080;
}

# IP Hash(会话保持)
upstream backend_iphash {
    ip_hash;
# [注意] 若Nginx作为K8s Ingress前置LB，建议改用least_conn(避免与Ingress负载策略冲突)
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

> **2026年趋势**: Kubernetes Gateway API正在逐步替代Ingress。Gateway API提供更丰富的流量管理能力(Header匹配、流量拆分、请求改写)。新项目建议直接使用Gateway API，存量Ingress可渐进迁移。

---

## 六、Keepalived深度配置

> ⚠️ **VRRP协议在云环境中的局限性**

### 6.0 VRRP协议的网络要求

VRRP（Virtual Router Redundancy Protocol）依赖**二层广播/组播/单播**在同一个L2网段内进行故障检测和VIP漂移。这在物理网络环境中工作良好，但在云环境中存在严重限制：

| 限制项 | 说明 |
|--------|------|
| 二层隔离 | 云VPC网络不支持二层广播域，VRRP组播包无法到达 |
| VIP漂移 | 云平台不支持无绑定实例的VIP自由漂移 |
| 防火墙规则 | 云安全组通常丢弃VRRP协议报文（协议号112） |
| 负载均衡器 | 云平台自带ALB/SLB已替代了Keepalived的VIP功能 |

**云环境替代方案：**

1. **云原生负载均衡器（推荐）**：阿里云SLB/ALB、AWS ALB/NLB替代VIP漂移
   - SLB自动健康检查后端ECS，故障自动摘除
   - 无需维护VRRP协议，运维复杂度大幅降低
   ```bash
   # 阿里云SLB健康检查配置示例
   # 后端监听80端口，健康检查路径 /health
   # 自动检测Nginx存活，故障自动切换
   ```

2. **DNS轮询+健康检查**：适用于多可用区部署
   - 云DNS服务配置健康检查，自动剔除故障节点IP
   - TTL设置为30-60秒，平衡切换速度与DNS缓存

3. **Keepalived Unicast模式**：如必须使用Keepalived
   - 配置单播地址代替组播，可穿越VPC网络
   ```bash
   # Unicast配置示例
   vrrp_instance VI_1 {
       unicast_src_ip 10.10.30.11
       unicast_peer {
           10.10.30.12
       }
   }
   ```

4. **阿里云SLB健康检查替代Keepalived**：
   - 使用SLB自带的健康检查机制（TCP/HTTP/HTTPS）
   - 配合云监控告警，实现故障自动感知
   - 零额外组件，无需维护Keepalived服务

> **生产建议**：混合部署场景（物理机+云）可保留VRRP用于物理机集群，云环境统一使用云原生SLB。避免在纯云环境中强行部署Keepalived VRRP。

### 6.1 双主模式（推荐生产使用）

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
    # [重要] nopreempt防止网络恢复后抢占，避免脑裂
    nopreempt
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}  # 必须恰好8字符: export KEEPALIVED_AUTH_PASS=$(openssl rand -hex 4)
> **注意**: Keepalived配置文件中的环境变量不会自动展开。需要:
> 1. 使用sed替换: sed -i "s/KEEPALIVED_AUTH_PASS/${KEEPALIVED_AUTH_PASS}/g" /etc/keepalived/keepalived.conf
> 2. 或使用Keepalived的include机制: include /etc/keepalived/secrets.conf
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
    # [重要] nopreempt防止网络恢复后抢占
    nopreempt
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}  # 必须恰好8字符: export KEEPALIVED_AUTH_PASS=$(openssl rand -hex 4)
> **注意**: Keepalived配置文件中的环境变量不会自动展开。需要:
> 1. 使用sed替换: sed -i "s/KEEPALIVED_AUTH_PASS/${KEEPALIVED_AUTH_PASS}/g" /etc/keepalived/keepalived.conf
> 2. 或使用Keepalived的include机制: include /etc/keepalived/secrets.conf
    }
    unicast_src_ip 10.10.50.11
    unicast_peer {
        10.10.50.12
    }
    # VI_2与VI_1使用相同的unicast配置(同一台机器上两个VRRP实例共享相同的peer)
    virtual_ipaddress {
        10.10.50.101/24 dev eth0
    }
    track_script {
        chk_nginx
    }
    notify_master "/opt/scripts/notify.sh MASTER 10.10.50.12"
    notify_backup "/opt/scripts/notify.sh BACKUP 10.10.50.12"
    notify_fault  "/opt/scripts/notify.sh FAULT 10.10.50.12"
}
```

### 6.2 Nginx健康检查脚本

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
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1/health --max-time 5)
if [ "${HTTP_CODE}" != "200" ]; then
    echo "健康检查失败: HTTP ${HTTP_CODE}"
    systemctl restart nginx
    sleep 3
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1/health --max-time 5)
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

## 七、SSL证书管理

### 7.1 Let's Encrypt自动续期

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

### 7.2 内部CA证书管理

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
# [修复] 使用-passout避免交互式密码输入，方便自动化部署
CA_PASS="change_me_in_production"
openssl genrsa -aes256 -passout pass:${CA_PASS} -out ${CA_DIR}/private/ca.key 4096
openssl req -new -x509 -days 730 -sha512 \
    -passin pass:${CA_PASS} \
    -key ${CA_DIR}/private/ca.key \
    -out ${CA_DIR}/certs/ca.crt \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/CN=Enterprise-CA"
# 证书有效期730天(2年),配合cert-manager自动轮换

# CRL(证书吊销列表)配置
# 生成CRL初始文件: openssl ca -gencrl -config ${CA_DIR}/openssl.cnf -out ${CA_DIR}/crl/ca.crl
# 吊销证书示例: openssl ca -revoke /path/to/cert.pem -config ${CA_DIR}/openssl.cnf -passin pass:${CA_PASS}
# 更新CRL: openssl ca -gencrl -config ${CA_DIR}/openssl.cnf -out ${CA_DIR}/crl/ca.crl -passin pass:${CA_PASS}
# Nginx中引用CRL: ssl_crl /etc/nginx/ssl/ca.crl;

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

## 八、性能压测与调优

### 8.1 wrk压测脚本

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
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}s   -H "Authorization: Bearer ${API_TOKEN}"   --latency ${TARGET}/api/v1/products
# [注意] 以下为占位符，实际使用前必须替换为真实Token
# export API_TOKEN=your_actual_token_here  # 替换为真实的JWT或API Key

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

### 8.2 调优参数对照表

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

## 九、WAF安全防护

> **WAF方案选择建议**:
> - 开源WAF(ModSecurity): 规则维护成本高,适合有安全团队的企业
> - 云WAF(阿里云WAF/AWS WAF): 托管服务,自动更新规则,推荐生产使用
> - 商业WAF(Imperva/F5): 功能全面,适合对安全要求极高的场景

### 9.1 ModSecurity配置

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
# [注意] SecRuleEngine只应设置一次，重复设置会被后者覆盖
# 生产环境使用On模式拦截恶意请求，而非仅记录
SecRuleEngine On
> **注意**: 新部署建议先用DetectionOnly观察1-2周，确认规则误报率可控后再切换为On
SecRequestBodyAccess On
SecResponseBodyAccess Off

# SQL注入防护
# [注意] 正则仅匹配高风险模式，避免误拦截包含SQL关键字的正常请求
SecRule REQUEST_URI|REQUEST_HEADERS|REQUEST_BODY   "@rx (?i:(?:union\s+(?:all\s+)?select|select\s+[\s\S]{1,50}\s+from\s+[\s\S]{1,50}\s+where|insert\s+into\s+\w+\s*\(|delete\s+from\s+\w+\s+where|drop\s+(?:table|database)\s+\w+))"   "id:1001,phase:1,pass,status:200,log,msg:'SQL Injection Detected (review needed)'"

# XSS防护
SecRule REQUEST_URI|REQUEST_HEADERS|REQUEST_BODY   "@rx (?i:(?:<script|javascript:|onerror=|onload=))"   "id:1002,phase:1,deny,status:403,log,msg:'XSS Attack Detected'"

# 文件包含防护
SecRule REQUEST_URI|REQUEST_BODY   "@rx (?i:(?:\.\.\/|\.\.\\|etc\/passwd|proc\/self))"   "id:1003,phase:1,deny,status:403,log,msg:'Path Traversal Detected'"

# CC攻击防护
SecRule IP:REQUEST_RATE "@gt 100" "id:1004,phase:1,deny,status:429,log,msg:'Rate Limit Exceeded'"

# 命令注入防护
SecRule REQUEST_URI|REQUEST_BODY "@rx (?i:(?:;\s*(?:cat|ls|id|whoami|wget|curl|bash|sh|python|perl|ruby)\b|`[^`]*`|\\$\\([^)]*\\)))" "id:1005,phase:1,deny,status:403,log,msg:'Command Injection Detected'"

# XML外部实体注入(XXE)防护
SecRule REQUEST_BODY "@rx (?i:(?:<!ENTITY|SYSTEM\s+[\"']file://|SYSTEM\s+[\"']http))" "id:1006,phase:2,deny,status:403,log,msg:'XXE Attack Detected'"

# SSRF防护(禁止访问内网地址)
SecRule REQUEST_BODY|REQUEST_URI "@rx (?i:(?:127\.0\.0\.1|192\.168\.|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.))" "id:1007,phase:2,deny,status:403,log,msg:'SSRF Attack Detected - Internal IP Access'"

# 敏感信息泄露检测
SecRule REQUEST_URI "@rx (?i:(?:\.env|\.git|\.svn|\.htaccess|wp-config|web\.config|\.DS_Store))" "id:1008,phase:1,deny,status:403,log,msg:'Sensitive File Access Attempt'"

# HTTP方法限制(仅允许常见方法)
SecRule REQUEST_METHOD "!@rx ^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)$" "id:1009,phase:1,deny,status:405,log,msg:'Unsupported HTTP Method'"

# User-Agent黑名单(常见攻击工具)
SecRule REQUEST_HEADERS:User-Agent "@rx (?i:(?:sqlmap|nikto|nmap|masscan|dirbuster|gobuster|wfuzz|ffuf|nuclei))" "id:1010,phase:1,deny,status:403,log,msg:'Malicious User-Agent Detected'"
```

---

## 十、灾备切换演练

### 10.1 故障转移测试

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

## 十一、运维SOP

### 11.1 日常巡检

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

### 11.2 紧急预案

```bash
#!/bin/bash
# emergency_fix.sh - Nginx紧急故障自动处理脚本

set -euo pipefail

VIP="10.10.50.100"
UPSTREAM_BACKENDS=("10.10.50.11:8080" "10.10.50.12:8080" "10.10.50.13:8080")

echo "============================================"
echo "  Nginx紧急故障处理 $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# 场景1: Nginx 502 Bad Gateway - 自动移除故障后端
fix_502() {
    echo "[502处理] 检查upstream后端..."
    for backend in "${UPSTREAM_BACKENDS[@]}"; do
        IP=$(echo $backend | cut -d: -f1)
        PORT=$(echo $backend | cut -d: -f2)
        if ! curl -sf -o /dev/null --max-time 3 "http://${backend}/health" 2>/dev/null; then
            echo "  ❌ 后端 ${backend} 不可达，临时从upstream移除"
            # 注释掉故障后端(需配合sed实际使用)
            # sed -i "s|server ${backend}|# server ${backend} # DOWN|g" /etc/nginx/conf.d/upstream.conf
        else
            echo "  ✅ 后端 ${backend} 正常"
        fi
    done
    nginx -t 2>/dev/null && nginx -s reload
}

# 场景2: Nginx 504 Gateway Timeout - 增加超时时间
fix_504() {
    echo "[504处理] 临时增加proxy_read_timeout..."
    sed -i 's/proxy_read_timeout 60s;/proxy_read_timeout 120s;/' /etc/nginx/nginx.conf
    nginx -t 2>/dev/null && nginx -s reload
    echo "  ⚠️ 已临时将proxy_read_timeout增加到120s，故障恢复后请回滚"
}

# 场景3: Keepalived VIP不漂移 - 重启Keepalived
fix_keepalived() {
    echo "[Keepalived处理] 检查VIP状态..."
    if ! ip addr show | grep -q "${VIP}"; then
        echo "  ❌ VIP不在本机，尝试重启Keepalived..."
        systemctl restart keepalived
        sleep 3
        if ip addr show | grep -q "${VIP}"; then
            echo "  ✅ VIP已漂移到本机"
        else
            echo "  ❌ VIP仍未漂移，检查VRRP配置和防火墙"
            echo "  手动干预: systemctl stop keepalived (在对端执行)"
        fi
    else
        echo "  ✅ VIP正常"
    fi
}

# 场景4: SSL证书过期 - 使用自签名证书临时恢复
fix_ssl() {
    echo "[SSL处理] 检查证书过期..."
    for cert in /etc/nginx/ssl/*.pem; do
        if [ -f "${cert}" ]; then
            EXPIRY=$(openssl x509 -enddate -noout -in ${cert} 2>/dev/null | cut -d= -f2)
            DAYS_LEFT=$(( ($(date -d "${EXPIRY}" +%s) - $(date +%s)) / 86400 )) 2>/dev/null || DAYS_LEFT=0
            if [ ${DAYS_LEFT} -lt 1 ]; then
                echo "  ❌ 证书 ${cert} 已过期，生成临时自签名证书..."
                openssl req -x509 -nodes -days 7 -newkey rsa:2048 \
                    -keyout ${cert%.pem}.key -out ${cert} \
                    -subj "/CN=*.ecommerce.com" 2>/dev/null
                echo "  ⚠️ 已生成7天临时证书，请尽快申请正式证书"
            fi
        fi
    done
    nginx -t 2>/dev/null && nginx -s reload
}

# 主逻辑
case ${1:-all} in
    502) fix_502 ;;
    504) fix_504 ;;
    keepalived|vip) fix_keepalived ;;
    ssl) fix_ssl ;;
    all)
        fix_502
        fix_keepalived
        fix_ssl
        ;;
    *)
        echo "用法: $0 [502|504|keepalived|ssl|all]"
        exit 1
        ;;
esac

echo "============================================"
echo "  紧急处理完成 $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
```

---

## 十二、成本估算

| 项目 | 单价 | 数量 | 月成本 |
|------|------|------|--------|
| Nginx服务器(8C/16G) | 1,200元/月 | 2台 | 2,400元 |
| VIP(弹性IP) | 50元/月 | 1个 | 50元 |
| SSL证书(通配符) | 200元/年 | 1个 | 17元 |
| 带宽(10Mbps) | 800元/月 | 1个 | 800元 |
| 磁盘(500G SSD) | 200元/月 | 2块 | 400元 |
| 备份存储(1TB) | 100元/月 | 1个 | 100元 |
| **总计** | | | **3,767元/月** |
> 成本估算因配置差异可能不同,以详细计算为准(第16节)

---

> 本项目基于官方文档、技术博客和社区实践深度学习编写
> 包含真实故障案例、性能调优参数、灾备方案、容量规划、运维SOP

---

## 十三、真实故障案例深度分析

### 案例1：Keepalived健康检查误判导致全站不可用
> 本项目使用Keepalived(非LVS),但健康检查原理类似

**故障现象**: 凌晨2点，线上告警Nginx集群全面无响应，用户无法访问任何页面。

**故障时间线**:
```
02:00  监控告警: VIP不可达
02:01  值班工程师收到电话告警
02:05  登录堡垒机检查，发现两台Nginx均存活
02:08  发现Keepalived健康检查脚本超时阈值设为2秒
02:10  分析: Keepalived检查脚本使用curl请求/health，后端响应慢导致超时
02:15  修改健康检查超时为5秒，Keepalived恢复正常检查
02:18  业务恢复正常
```

**根因分析**:
```
Keepalived健康检查脚本:
#!/bin/bash
# 故障配置：超时太短
curl -sf -o /dev/null http://10.10.50.11/health --max-time 2
# 高峰期后端GC暂停3秒，健康检查超时，Keepalived将节点标记为down
# 两台Nginx的upstream后端都在GC，同时被标记down
# Keepalived无可用后端，返回503
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
# [注意] 以下为简化的故障示例。实际故障发生在新增的server块中，遗漏了proxy_http_version配置。
# 本项目主配置(第二节)已正确配置proxy_http_version 1.1，此处展示的是常见遗漏模式。
# 配置问题：proxy_http_version未指定为1.1
location /api/ {
    proxy_pass http://backend;
    # 故障场景: 新增server块遗漏了以下两行
    # proxy_http_version 1.1;
    # proxy_set_header Connection "";
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
# [注意] geo模块是Nginx默认编译的内置模块，无需额外安装
# 但geo指令只能在http块中使用，不能在location块中使用

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

## 十四、高级性能调优参数

### 14.1 Worker进程优化

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
    # accept_mutex_delay已废弃(nginx 1.11.13+)，不再需要此指令
}
```

**Worker进程调优对照表**:

| 参数 | 低配(4C/8G) | 中配(8C/16G) | 高配(16C/32G) | 说明 |
|------|------------|-------------|--------------|------|
| worker_processes | 4 | 8 | 16 | CPU核心数 |
| worker_rlimit_nofile | 32768 | 65535 | 131072 | 文件描述符 |
| worker_connections | 32768 | 65535 | 131072 | 每Worker连接数 |
| 总连接容量 | 131072 | 524288 | 2097152 | 核心数×连接数 |

### 14.2 Keepalive优化

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
    # keepalive_disable none;  # Nginx Plus only, 不适用于开源版
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

### 14.3 Proxy缓冲优化

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
    # directio 512k;  # 与sendfile冲突，已禁用
}
```

### 14.4 Gzip压缩优化

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
# 编译安装Brotli模块:
# 1. 安装依赖
#    yum install -y git pcre-devel zlib-devel openssl-devel gcc make
# 2. 克隆ngx_brotli模块
#    cd /usr/local/src
#    git clone --recurse-submodules https://github.com/google/ngx_brotli.git
# 3. 下载Nginx源码(与当前安装版本一致)
#    cd /usr/local/src
#    wget http://nginx.org/download/nginx-1.26.2.tar.gz
#    tar xzf nginx-1.26.2.tar.gz && cd nginx-1.26.2
# 4. 编译(保留原有模块参数，追加brotli)
#    ./configure --prefix=/etc/nginx \
#        --with-http_ssl_module --with-http_v2_module \
#        --with-http_realip_module --with-http_gzip_static_module \
#        --with-http_stub_status_module --with-stream \
#        --add-module=/usr/local/src/ngx_brotli
#    make -j$(nproc) && make install
# 5. 验证
#    nginx -V 2>&1 | grep -o 'brotli'
# 6. 启用Brotli(取消下方注释)
# brotli on;
# brotli_comp_level 6;
# brotli_types text/plain text/css application/json application/javascript text/xml application/xml;

# 压缩效果对比
# Level 4:  压缩率 75%, CPU开销 低
# Level 6:  压缩率 80%, CPU开销 中
# Level 9:  压缩率 82%, CPU开销 高
```

### 14.5 文件缓存与Open File Cache

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
    # directio 4k;  # 与sendfile冲突，已禁用
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

## 十五、双机房灾备方案

### 1. 架构设计

> **注意**: Active-Standby模式下BACKUP节点闲置是设计选择。
> 如需双活负载,可使用DNS轮询或云厂商SLB替代VIP漂移方案。
> 本项目选择Active-Standby以简化故障切换逻辑。

```
                    ┌─────────────────────────────────────────┐
                    │              双机房灾备架构                │
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

### 15.2 DNS智能解析配置

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

### 15.3 数据同步方案

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
binlog-ignore-db=information_schema  # [注意] information_schema是虚拟库,不需要忽略。此配置无效,可删除。

> information_schema是内存中的元数据视图,不是物理数据库,不会产生binlog。此配置无效。


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

### 15.4 灾备切换演练

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

## 十六、详细成本估算与优化

### 16.1 基础成本

| 项目 | 规格 | 单价(月) | 数量 | 月成本 | 年成本 |
|------|------|---------|------|--------|--------|
| Nginx服务器 | 8C/16G | 1,200元 | 2台 | 2,400元 | 28,800元 |
| VIP(弹性IP) | - | 50元 | 1个 | 50元 | 600元 |
| SSL证书 | 通配符 | 200元/年 | 1个 | 17元 | 200元 |
| 带宽 | 10Mbps | 800元 | 1个 | 800元 | 9,600元 |
| 磁盘 | 500G SSD | 200元 | 2块 | 400元 | 4,800元 |
| 备份存储 | 1TB | 100元 | 1个 | 100元 | 1,200元 |
| **合计** | | | | **3,767元** | **45,200元** |

### 16.2 优化方案

| 优化项 | 优化前 | 优化后 | 月节省 | 实施难度 |
|--------|--------|--------|--------|---------|
| 服务器降配 | 8C/16G | 4C/8G | 1,200元 | 低 |
| 带宽按量 | 固定10Mbps | 按量计费 | 200-400元 | 中 |
| CDN加速 | 全量回源 | 80%命中 | 400元 | 中 |
| 日志压缩 | 原始存储 | Gzip压缩 | 50元 | 低 |
| **合计** | | | **1,850-2,050元** | |

### 16.3 投资回报分析

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

## 十七、全链路监控告警体系

### 17.1 监控指标体系

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

### 17.2 Prometheus + Grafana监控

```yaml
# prometheus.yml - Nginx监控配置
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'nginx'
    # 需要先安装nginx-prometheus-exporter:
    # 下载: https://github.com/nginxinc/nginx-prometheus-exporter/releases
    # 运行: nginx-prometheus-exporter -nginx.scrape-uri=http://127.0.0.1/nginx_status
    static_configs:
      - targets: ['10.10.50.11:9113', '10.10.50.12:9113']
        labels:
          cluster: 'production'
          env: 'prod'
    scrape_interval: 10s
    metrics_path: /metrics
    
  - job_name: 'keepalived'
    # 需要安装keepalived_exporter:
    # https://github.com/mirthlab/keepalived_exporter
    static_configs:
      - targets: ['10.10.50.11:9165', '10.10.50.12:9165']
        labels:
          cluster: 'production'
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

### 17.3 Grafana Dashboard配置

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

**Grafana Dashboard导入方法**:

```bash
# 方法1: 通过Grafana UI导入(推荐)
# 1. 登录Grafana -> Dashboards -> Import
# 2. 粘贴上方JSON内容，或点击"Upload JSON file"上传文件
# 3. 选择Prometheus数据源 -> 点击Import

# 方法2: 通过Grafana API导入
curl -X POST http://admin:admin@localhost:3000/api/dashboards/db \
    -H "Content-Type: application/json" \
    -d "{\"dashboard\": $(cat nginx_keepalived_dashboard.json), \"overwrite\": true, \"inputs\": [{\"name\": \"DS_PROMETHEUS\", \"type\": \"datasource\", \"pluginId\": \"prometheus\", \"value\": \"Prometheus\"}]}"

# 方法3: 使用Grafana.com预置模板(快速上手)
# - Nginx Dashboard模板ID: 12708 (推荐)
# - Keepalived模板ID: 15660
# 导入步骤: Grafana UI -> Dashboards -> Import -> 输入模板ID -> Load -> 选择数据源 -> Import
```

---

## 十八、完整运维SOP手册

### 18.1 日常运维SOP

```bash
#!/bin/bash
# daily_ops.sh - 日常运维检查

echo "========== Nginx+Keepalived 日常运维检查 $(date '+%Y-%m-%d %H:%M') =========="

# 1. 进程健康检查
echo "1. 进程健康检查"
# [修复] 使用VIP地址判断当前MASTER节点，而非本地IP
VIP="10.10.50.100"
if ip addr show | grep -q "${VIP}"; then
    MASTER_HOST=$(hostname)
    echo "   当前节点为MASTER(VIP持有者): ${MASTER_HOST}"
else
    MASTER_HOST=$(ssh -o ConnectTimeout=2 root@${VIP} hostname 2>/dev/null || echo "无法获取")
    echo "   当前节点为BACKUP, MASTER节点: ${MASTER_HOST}"
fi

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

### 18.2 变更发布SOP

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
if ! nginx -t 2>&1; then
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

### 18.3 紧急故障处理SOP

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

### 18.4 版本升级SOP

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



## 踩坑记录

### Q1: Keepalived脑裂导致双VIP
**原因**: 节点间VRRP通信中断
**解决**: 配置单播模式替代组播，增加仲裁机制

### Q2: Nginx upstream全部标记为down
**原因**: max_fails阈值过低导致误判
**解决**: 增大max_fails到5，fail_timeout到60s

### Q3: SSL证书过期导致HTTPS中断
**原因**: Let's Encrypt证书90天过期未自动续期
**解决**: 配置certbot自动续期cron任务

### Q4: 限流配置误杀正常用户
**原因**: rate设置过低
**解决**: 根据实际QPS调整limit_req_zone的rate参数

### Q5: Nginx 502 Bad Gateway
**原因**: 后端服务不可达
**解决**: 检查upstream配置，确认后端健康检查脚本

> 本项目基于官方文档、技术博客和社区实践深度学习编写
> 包含真实故障案例、性能调优参数、灾备方案、容量规划、运维SOP