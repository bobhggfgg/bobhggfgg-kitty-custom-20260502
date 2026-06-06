#!/bin/bash
# 一键配置

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

cloudflare_origin_env_json() {
    local token="$1"
    printf '{\n                    "CF_ORIGIN_CA_KEY": "%s"\n                }' "$(json_escape "$token")"
}

restart_kitty_if_installed() {
    if [[ x"${release}" == x"alpine" ]]; then
        if [[ -f /etc/init.d/kitty ]]; then
            service kitty restart
            return
        fi
    else
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files kitty.service --no-legend 2>/dev/null | grep -q '^kitty.service'; then
            systemctl restart kitty
            return
        fi
    fi
    echo -e "${yellow}未检测到 kitty 服务，请先执行安装；配置文件已生成。${plain}"
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    if [[ x"${release}" == x"centos" ]]; then
        yum install nginx -y >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add nginx >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" || x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install nginx -y >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -S --noconfirm --needed nginx >/dev/null 2>&1
    fi
}

ensure_geo_assets() {
    mkdir -p /etc/kitty
    for asset in geoip.dat geosite.dat; do
        local url=""
        if [[ "$asset" == "geoip.dat" ]]; then
            url="https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
        else
            url="https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
        fi

        local source_file=""
        for path in "/etc/kitty/$asset" "/usr/local/kitty/$asset" "${cur_dir:-$(pwd)}/$asset" "./$asset"; do
            if [[ -s "$path" ]]; then
                source_file="$path"
                break
            fi
        done

        if [[ -z "$source_file" ]]; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --retry 3 -o "/etc/kitty/$asset" "$url" || true
            elif command -v wget >/dev/null 2>&1; then
                wget -qO "/etc/kitty/$asset" "$url" || true
            fi
            if [[ -s "/etc/kitty/$asset" ]]; then
                source_file="/etc/kitty/$asset"
            fi
        fi

        if [[ -n "$source_file" && -s "$source_file" ]]; then
            cp -f "$source_file" "/etc/kitty/$asset"
            chmod 644 "/etc/kitty/$asset"
        else
            echo -e "${yellow}警告：未能准备 $asset，xray/singbox 路由可能无法启动。${plain}"
        fi
    done
}

setup_hy2_443_frontend() {
    local domain="$1"
    local cert_file="$2"
    local key_file="$3"
    local cert_mode="${4:-}"
    local nginx_conf_dir="/etc/nginx/conf.d"
    if [[ x"${release}" == x"alpine" ]]; then
        nginx_conf_dir="/etc/nginx/http.d"
    fi

    install_nginx
    mkdir -p /var/www/techpulse "$nginx_conf_dir"
    cat > /var/www/techpulse/index.html <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>PicShelf 图床</title>
  <style>
    :root { font-family: Inter, "PingFang SC", "Microsoft YaHei", system-ui, sans-serif; color: #17202a; background: #f5f7fb; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #f5f7fb; color: #17202a; }
    header { height: 68px; display: flex; align-items: center; justify-content: space-between; padding: 0 clamp(18px, 5vw, 72px); border-bottom: 1px solid #dbe2ec; background: #fff; }
    .brand { display: flex; gap: 10px; align-items: center; font-size: 22px; font-weight: 800; }
    .mark { width: 34px; height: 34px; border-radius: 8px; display: grid; place-items: center; background: #0f766e; color: #fff; font-weight: 900; }
    nav { display: flex; gap: 18px; color: #64748b; font-size: 14px; }
    main { max-width: 1120px; margin: 0 auto; padding: 30px 18px 56px; }
    .workspace { display: grid; grid-template-columns: 1.1fr .9fr; gap: 22px; }
    .panel, .item { background: #fff; border: 1px solid #dbe2ec; border-radius: 8px; }
    .panel { padding: 22px; }
    h1 { margin: 0 0 10px; font-size: clamp(30px, 5vw, 52px); line-height: 1.05; }
    h2 { margin: 28px 0 14px; font-size: 22px; }
    p { margin: 0; line-height: 1.7; color: #536173; }
    .upload { margin-top: 22px; border: 1px dashed #94a3b8; border-radius: 8px; min-height: 210px; display: grid; place-items: center; text-align: center; background: #f8fafc; overflow: hidden; }
    .upload input { display: none; }
    .upload label { cursor: pointer; display: grid; gap: 10px; justify-items: center; padding: 28px; width: 100%; }
    .upload img { max-width: 100%; max-height: 210px; object-fit: contain; border-radius: 8px; }
    .button { border: 0; border-radius: 8px; padding: 11px 16px; background: #0f766e; color: #fff; font-weight: 700; cursor: pointer; }
    .muted { color: #718096; font-size: 14px; }
    .links { display: grid; gap: 10px; margin-top: 16px; }
    .linkrow { display: grid; grid-template-columns: 1fr auto; gap: 8px; align-items: center; border: 1px solid #e2e8f0; border-radius: 8px; padding: 8px; }
    code { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #334155; }
    .copy { border: 1px solid #cbd5e1; background: #fff; color: #0f766e; border-radius: 8px; padding: 8px 10px; cursor: pointer; }
    .gallery { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
    .item { overflow: hidden; }
    .item img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; display: block; background: #e2e8f0; }
    .caption { padding: 10px 12px; display: flex; justify-content: space-between; gap: 8px; font-size: 13px; color: #64748b; }
    @media (max-width: 820px) { .workspace { grid-template-columns: 1fr; } nav { display: none; } .gallery { grid-template-columns: repeat(2, 1fr); } }
  </style>
</head>
<body>
  <header><div class="brand"><span class="mark">P</span>PicShelf 图床</div><nav><span>上传</span><span>相册</span><span>链接管理</span></nav></header>
  <main>
    <section class="workspace">
      <div class="panel"><h1>快速上传，稳定分发图片链接</h1><p>支持 JPG、PNG、WebP 和 GIF。当前为静态演示页，选择图片后可在本地预览。</p><div class="upload" id="dropzone"><label for="fileInput"><span class="button">选择图片</span><span class="muted">拖放图片到这里，或点击选择文件</span></label><input id="fileInput" type="file" accept="image/*"></div></div>
      <aside class="panel"><h2>最近链接</h2><div class="links"><div class="linkrow"><code>https://i.picshelf.local/2026/sunset.webp</code><button class="copy">复制</button></div><div class="linkrow"><code>https://i.picshelf.local/2026/mockup.png</code><button class="copy">复制</button></div><div class="linkrow"><code>https://i.picshelf.local/2026/avatar.jpg</code><button class="copy">复制</button></div></div></aside>
    </section>
    <h2>公开相册</h2>
    <section class="gallery">
      <div class="item"><img alt="gallery" src="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=600&q=70"><div class="caption"><span>cover.webp</span><span>1.2 MB</span></div></div>
      <div class="item"><img alt="gallery" src="https://images.unsplash.com/photo-1498050108023-c5249f4df085?auto=format&fit=crop&w=600&q=70"><div class="caption"><span>desk.jpg</span><span>860 KB</span></div></div>
      <div class="item"><img alt="gallery" src="https://images.unsplash.com/photo-1516321318423-f06f85e504b3?auto=format&fit=crop&w=600&q=70"><div class="caption"><span>screen.png</span><span>940 KB</span></div></div>
      <div class="item"><img alt="gallery" src="https://images.unsplash.com/photo-1516035069371-29a1b244cc32?auto=format&fit=crop&w=600&q=70"><div class="caption"><span>camera.jpg</span><span>730 KB</span></div></div>
    </section>
  </main>
  <script>
    const input = document.getElementById('fileInput');
    const zone = document.getElementById('dropzone');
    input.addEventListener('change', () => {
      const file = input.files && input.files[0];
      if (!file) return;
      const img = document.createElement('img');
      img.alt = file.name;
      img.src = URL.createObjectURL(file);
      zone.innerHTML = '';
      zone.appendChild(img);
    });
    document.querySelectorAll('.copy').forEach((button) => {
      button.addEventListener('click', async () => {
        const text = button.parentElement.querySelector('code').textContent;
        try { await navigator.clipboard.writeText(text); button.textContent = '已复制'; }
        catch (e) { button.textContent = '复制'; }
      });
    });
  </script>
</body>
</html>
EOF
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf /etc/nginx/http.d/default.conf
    cat > /usr/local/bin/kitty-hy2-nginx-refresh <<EOF
#!/bin/bash
nginx_conf_dir="$nginx_conf_dir"
domain="$domain"
cert_file="$cert_file"
key_file="$key_file"
if [[ -f "\$cert_file" && -f "\$key_file" ]]; then
    cat > "\$nginx_conf_dir/techpulse.conf" <<NGINX
server {
    listen 80;
    server_name \$domain _;
    root /var/www/techpulse;
    index index.html;
    location / { try_files \\\$uri \\\$uri/ /index.html; }
}
server {
    listen 443 ssl http2;
    server_name \$domain _;
    root /var/www/techpulse;
    index index.html;
    ssl_certificate \$cert_file;
    ssl_certificate_key \$key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    location / { try_files \\\$uri \\\$uri/ /index.html; }
}
NGINX
else
    cat > "\$nginx_conf_dir/techpulse.conf" <<NGINX
server {
    listen 80;
    server_name \$domain _;
    root /var/www/techpulse;
    index index.html;
    location / { try_files \\\$uri \\\$uri/ /index.html; }
}
NGINX
fi
EOF
    chmod +x /usr/local/bin/kitty-hy2-nginx-refresh
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        /usr/local/bin/kitty-hy2-nginx-refresh
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nginx >/dev/null 2>&1
            systemctl restart nginx >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add nginx default >/dev/null 2>&1
            service nginx restart >/dev/null 2>&1 || true
        else
            service nginx restart >/dev/null 2>&1 || true
        fi
        echo -e "${green}已配置 nginx TCP/443 PicShelf 图床页；HY2 使用 UDP/443。${plain}"
    elif [[ "$cert_mode" == "http" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop nginx >/dev/null 2>&1 || true
        else
            service nginx stop >/dev/null 2>&1 || true
        fi
        echo -e "${yellow}HTTP 证书模式需要 80 端口，已先释放 nginx；证书签发后会自动启用 TCP/443 网页。${plain}"
    else
        /usr/local/bin/kitty-hy2-nginx-refresh
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nginx >/dev/null 2>&1
            systemctl restart nginx >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add nginx default >/dev/null 2>&1
            service nginx restart >/dev/null 2>&1 || true
        else
            service nginx restart >/dev/null 2>&1 || true
        fi
        echo -e "${yellow}未找到证书文件，已先生成 PicShelf HTTP 图床页；证书生成后会自动启用 TCP/443。${plain}"
    fi
}

wait_for_hy2_frontend() {
    local cert_file="$1"
    local key_file="$2"
    local waited=0
    while [[ $waited -lt 120 ]]; do
        if [[ -f "$cert_file" && -f "$key_file" ]]; then
            /usr/local/bin/kitty-hy2-nginx-refresh >/dev/null 2>&1 || true
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable nginx >/dev/null 2>&1
                systemctl restart nginx >/dev/null 2>&1 || true
            elif command -v rc-update >/dev/null 2>&1; then
                rc-update add nginx default >/dev/null 2>&1
                service nginx restart >/dev/null 2>&1 || true
            else
                service nginx restart >/dev/null 2>&1 || true
            fi
            echo -e "${green}证书已就绪，PicShelf 图床页已启用 HTTPS。${plain}"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo -e "${yellow}暂未等到证书文件，请稍后查看 kitty log；证书成功后可执行 /usr/local/bin/kitty-hy2-nginx-refresh 并重启 nginx。${plain}"
    return 1
}

create_hy2_443_config() {
    hy2_selected=true
    mkdir -p /etc/kitty
    cat <<EOF > /etc/kitty/hy2config.yaml
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: system
masquerade:
  type: proxy
  proxy:
    url: "http://127.0.0.1"
    rewriteHost: false
EOF
    setup_hy2_443_frontend "$certdomain" "/etc/kitty/fullchain.cer" "/etc/kitty/cert.key" "$certmode"
    echo -e "${green}已自动创建 HY2 配置：/etc/kitty/hy2config.yaml${plain}"
    echo -e "${green}HY2 UDP 监听端口将使用面板 server_port；TCP/443 仍用于 nginx 伪装。${plain}"
}

add_node_config() {
    echo -e "${green}请选择节点核心类型：${plain}"
    echo -e "${green}1. xray${plain}"
    echo -e "${green}2. singbox${plain}"
    echo -e "${green}3. hysteria2${plain}"
    echo -e "${green}4. ShadowsocksR${plain}"
    read -rp "请输入：" core_type
    if [ "$core_type" == "1" ]; then
        core="xray"
        core_xray=true
    elif [ "$core_type" == "2" ]; then
        core="sing"
        core_sing=true
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"
        core_hysteria2=true
    elif [ "$core_type" == "4" ]; then
        core="ssr"
        core_ssr=true
    else
        echo "无效的选择。请选择 1 2 3 4。"
        continue
    fi
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        # 判断NodeID是否为正整数
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break  # 输入正确，退出循环
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    if [ "$core" == "ssr" ]; then
        echo -e "${yellow}请选择节点传输协议：${plain}"
        echo -e "${green}1. ShadowsocksR${plain}"
        echo -e "${green}2. Shadowsocks${plain}"
        read -rp "请输入：" NodeType
        case "$NodeType" in
            1 ) NodeType="shadowsocksr" ;;
            2 ) NodeType="shadowsocks" ;;
            * ) NodeType="shadowsocksr" ;;
        esac
    elif [ "$core_hysteria2" = true ] && [ "$core_xray" = false ] && [ "$core_sing" = false ]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}请选择节点传输协议：${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}4. Hysteria${plain}"
            echo -e "${green}5. Hysteria2${plain}"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo -e "${green}5. Hysteria2${plain}"
        fi
        echo -e "${green}6. Trojan${plain}"  
        if [ "$core_sing" == true ]; then
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
        fi
        read -rp "请输入：" NodeType
        case "$NodeType" in
            1 ) NodeType="shadowsocks" ;;
            2 ) NodeType="vless" ;;
            3 ) NodeType="vmess" ;;
            4 ) NodeType="hysteria" ;;
            5 ) NodeType="hysteria2" ;;
            6 ) NodeType="trojan" ;;
            7 ) NodeType="tuic" ;;
            8 ) NodeType="anytls" ;;
            * ) NodeType="shadowsocks" ;;
        esac
    fi
    fastopen=true
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
        fastopen=false
        istls="y"
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    certmode="none"
    certdomain="example.com"
    certemail="kitty@github.com"
    certprovider="cloudflare"
    dns_env_json="{}"
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        echo -e "${yellow}请选择证书申请模式：${plain}"
        echo -e "${green}1. http模式自动申请，节点域名已正确解析${plain}"
        echo -e "${green}2. Cloudflare Origin证书自动申请，不走Let's Encrypt${plain}"
        echo -e "${green}3. self模式，自签证书或提供已有证书文件${plain}"
        read -rp "请输入：" certmode
        case "$certmode" in
            1 ) certmode="http" ;;
            2 ) certmode="cf_origin" ;;
            3 ) certmode="self" ;;
        esac
        read -rp "请输入节点证书域名(example.com)：" certdomain
        read -rp "请输入证书邮箱(回车默认 kitty@github.com)：" certemail
        certemail="${certemail:-kitty@github.com}"
        if [ "$certmode" == "cf_origin" ]; then
            certprovider="cloudflare"
            read -rsp "请输入Cloudflare Origin CA Key（不是面板API Key，也不是DNS API Token）：" cf_origin_ca_key
            echo
            if [[ -z "$cf_origin_ca_key" ]]; then
                echo -e "${red}Cloudflare Origin证书模式必须填写 Origin CA Key。${plain}"
                return 1
            fi
            dns_env_json="$(cloudflare_origin_env_json "$cf_origin_ca_key")"
        elif [ "$certmode" == "self" ]; then
            echo -e "${yellow}self模式为自签证书，客户端需要允许 insecure/跳过证书验证。${plain}"
        fi
    fi
    if [ "$NodeType" == "hysteria2" ]; then
        create_hy2_443_config
    fi
    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi
    enable_proxy_protocol=false
    echo -e "${yellow}是否开启 EnableProxyProtocol？仅中转/负载均衡发送 PROXY protocol 时开启${plain}"
    echo -e "${green}1. 不开启${plain}"
    echo -e "${green}2. 开启${plain}"
    read -rp "请输入：" enable_proxy_protocol_choice
    case "$enable_proxy_protocol_choice" in
        2 ) enable_proxy_protocol=true ;;
        * ) enable_proxy_protocol=false ;;
    esac
    node_config=""
    if [ "$core_type" == "1" ]; then 
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": $enable_proxy_protocol,
            "EnableUot": true,
            "EnableTFO": true,
            "DNSType": "UseIPv4",
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/kitty/fullchain.cer",
                "KeyFile": "/etc/kitty/cert.key",
                "Email": "$certemail",
                "Provider": "$certprovider",
                "DNSEnv": $dns_env_json
            }
        },
EOF
)
    elif [ "$core_type" == "2" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": $enable_proxy_protocol,
            "TCPFastOpen": $fastopen,
            "SniffEnabled": true,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/kitty/fullchain.cer",
                "KeyFile": "/etc/kitty/cert.key",
                "Email": "$certemail",
                "Provider": "$certprovider",
                "DNSEnv": $dns_env_json
            }
        },
EOF
)
    elif [ "$core_type" == "3" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Hysteria2ConfigPath": "/etc/kitty/hy2config.yaml",
            "Timeout": 30,
            "ListenIP": "",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": $enable_proxy_protocol,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/kitty/fullchain.cer",
                "KeyFile": "/etc/kitty/cert.key",
                "Email": "$certemail",
                "Provider": "$certprovider",
                "DNSEnv": $dns_env_json
            }
        },
EOF
)
    elif [ "$core_type" == "4" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": $enable_proxy_protocol,
            "TCPFastOpen": $fastopen,
            "SniffEnabled": true,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/kitty/fullchain.cer",
                "KeyFile": "/etc/kitty/cert.key",
                "Email": "$certemail",
                "Provider": "$certprovider",
                "DNSEnv": $dns_env_json
            }
        },
EOF
)
    fi
    nodes_config+=("$node_config")
}

generate_config_file() {
    echo -e "${yellow}kitty 配置文件生成向导${plain}"
    echo -e "${red}请阅读以下注意事项：${plain}"
    echo -e "${red}1. 生成的配置文件会保存到 /etc/kitty/config.json${plain}"
    echo -e "${red}2. 原来的配置文件会保存到 /etc/kitty/config.json.bak${plain}"
    echo -e "${red}3. 使用此功能生成的配置文件会自带审计，确定继续？(y/n)${plain}"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        exit 0
    fi
    
    nodes_config=()
    first_node=true
    core_xray=false
    core_sing=false
    core_hysteria2=false
    core_ssr=false
    hy2_selected=false
    fixed_api_info=false
    check_api=false
    
    while true; do
        if [ "$first_node" = true ]; then
            read -rp "请输入面板地址/机场网址(例如 https://example.com)：" ApiHost
            read -rp "请输入面板通讯密钥 ApiKey（不是 Cloudflare Key）：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？(y/n)" fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info=true
                echo -e "${red}成功固定地址${plain}"
            fi
            first_node=false
            add_node_config
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" = false ]; then
                read -rp "请输入面板地址/机场网址(例如 https://example.com)：" ApiHost
                read -rp "请输入面板通讯密钥 ApiKey（不是 Cloudflare Key）：" ApiKey
            fi
            add_node_config
        fi
    done

    # 初始化核心配置数组
    cores_config="["

    # 检查并添加xray核心配置
    if [ "$core_xray" = true ]; then
        cores_config+="
    {
        \"Type\": \"xray\",
        \"AssetPath\": \"/etc/kitty/\",
        \"Log\": {
            \"Level\": \"error\",
            \"ErrorPath\": \"/etc/kitty/error.log\"
        },
        \"OutboundConfigPath\": \"/etc/kitty/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/kitty/route.json\"
    },"
    fi

    # 检查并添加sing核心配置
    if [ "$core_sing" = true ]; then
        cores_config+="
    {
        \"Type\": \"sing\",
        \"Log\": {
            \"Level\": \"error\",
            \"Timestamp\": true
        },
        \"NTP\": {
            \"Enable\": false,
            \"Server\": \"time.apple.com\",
            \"ServerPort\": 0
        },
        \"OriginalPath\": \"/etc/kitty/sing_origin.json\"
    },"
    fi

    # 检查并添加hysteria2核心配置
    if [ "$core_hysteria2" = true ]; then
        cores_config+="
    {
        \"Type\": \"hysteria2\",
        \"Log\": {
            \"Level\": \"error\"
        }
    },"
    fi

    # 检查并添加ShadowsocksR核心配置
    if [ "$core_ssr" = true ]; then
        cores_config+="
    {
        \"Type\": \"ssr\"
    },"
    fi

    # 移除最后一个逗号并关闭数组
    cores_config+="]"
    cores_config=$(echo "$cores_config" | sed 's/},]$/}]/')

    mkdir -p /etc/kitty
    ensure_geo_assets

    # 备份旧的配置文件
    if [[ -f /etc/kitty/config.json ]]; then
        cp -f /etc/kitty/config.json /etc/kitty/config.json.bak
    fi
    nodes_config_str="${nodes_config[*]}"
    formatted_nodes_config="${nodes_config_str%,}"

    # 创建 config.json 文件
    cat <<EOF > /etc/kitty/config.json
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": $cores_config,
    "Nodes": [$formatted_nodes_config]
}
EOF
    
    # 创建 custom_outbound.json 文件
    cat <<EOF > /etc/kitty/custom_outbound.json
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv4v6"
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
    
    # 创建 route.json 文件
    cat <<EOF > /etc/kitty/route.json
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "outboundTag": "block",
            "domain": [
                "regexp:(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
                "regexp:(.+.|^)(360|so).(cn|com)",
                "regexp:(Subject|HELO|SMTP)",
                "regexp:(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
                "regexp:(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
                "regexp:(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
                "regexp:(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
                "regexp:(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
                "regexp:(.+.|^)(360).(cn|com|net)",
                "regexp:(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
                "regexp:(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
                "regexp:(.*.||)(netvigator|torproject).(com|cn|net|org)",
                "regexp:(..||)(visa|mycard|gash|beanfun|bank).",
                "regexp:(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
                "regexp:(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
                "regexp:(.*.||)(mycard).(com|tw)",
                "regexp:(.*.||)(gash).(com|tw)",
                "regexp:(.bank.)",
                "regexp:(.*.||)(pincong).(rocks)",
                "regexp:(.*.||)(taobao).(com)",
                "regexp:(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
                "regexp:(flows|miaoko).(pages).(dev)"
            ]
        },
        {
            "outboundTag": "block",
            "ip": [
                "127.0.0.1/32",
                "10.0.0.0/8",
                "fc00::/7",
                "fe80::/10",
                "172.16.0.0/12"
            ]
        },
        {
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
    ipv6_support=$(check_ipv6_support)
    dnsstrategy="ipv4_only"
    if [ "$ipv6_support" -eq 1 ]; then
        dnsstrategy="prefer_ipv4"
    fi
    # 创建 sing_origin.json 文件
    cat <<EOF > /etc/kitty/sing_origin.json
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "$dnsstrategy"
      }
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "domain_regex": [
            "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
            "(.+.|^)(360|so).(cn|com)",
            "(Subject|HELO|SMTP)",
            "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
            "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
            "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
            "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
            "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
            "(.+.|^)(360).(cn|com|net)",
            "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
            "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
            "(.*.||)(netvigator|torproject).(com|cn|net|org)",
            "(..||)(visa|mycard|gash|beanfun|bank).",
            "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
            "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
            "(.*.||)(mycard).(com|tw)",
            "(.*.||)(gash).(com|tw)",
            "(.bank.)",
            "(.*.||)(pincong).(rocks)",
            "(.*.||)(taobao).(com)",
            "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
            "(flows|miaoko).(pages).(dev)"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": [
          "udp","tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

    echo -e "${green}kitty 配置文件生成完成，正在尝试重新启动 kitty 服务${plain}"
    restart_kitty_if_installed
    if [ "$hy2_selected" = true ]; then
        wait_for_hy2_frontend "/etc/kitty/fullchain.cer" "/etc/kitty/cert.key"
    fi
}
