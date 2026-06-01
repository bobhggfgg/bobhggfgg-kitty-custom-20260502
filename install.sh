#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/kitty/kitty ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service kitty status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status kitty | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
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
        for path in "/usr/local/kitty/$asset" "/etc/kitty/$asset" "$cur_dir/$asset" "./$asset"; do
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

write_techpulse_site() {
    mkdir -p /var/www/techpulse
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
    header { height: 68px; display: flex; align-items: center; justify-content: space-between; padding: 0 clamp(18px, 5vw, 72px); border-bottom: 1px solid #dbe2ec; background: #ffffff; }
    .brand { display: flex; gap: 10px; align-items: center; font-size: 22px; font-weight: 800; }
    .mark { width: 34px; height: 34px; border-radius: 8px; display: grid; place-items: center; background: #0f766e; color: #fff; font-weight: 900; }
    nav { display: flex; gap: 18px; color: #64748b; font-size: 14px; }
    main { max-width: 1120px; margin: 0 auto; padding: 30px 18px 56px; }
    .workspace { display: grid; grid-template-columns: 1.1fr .9fr; gap: 22px; align-items: stretch; }
    .panel { background: #fff; border: 1px solid #dbe2ec; border-radius: 8px; padding: 22px; }
    h1 { margin: 0 0 10px; font-size: clamp(30px, 5vw, 52px); line-height: 1.05; }
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
    h2 { margin: 28px 0 14px; font-size: 22px; }
    .gallery { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
    .item { background: #fff; border: 1px solid #dbe2ec; border-radius: 8px; overflow: hidden; }
    .item img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; display: block; background: #e2e8f0; }
    .caption { padding: 10px 12px; display: flex; justify-content: space-between; gap: 8px; font-size: 13px; color: #64748b; }
    @media (max-width: 820px) { .workspace { grid-template-columns: 1fr; } nav { display: none; } .gallery { grid-template-columns: repeat(2, 1fr); } }
  </style>
</head>
<body>
  <header><div class="brand"><span class="mark">P</span>PicShelf 图床</div><nav><span>上传</span><span>相册</span><span>链接管理</span></nav></header>
  <main>
    <section class="workspace">
      <div class="panel">
        <h1>快速上传，稳定分发图片链接</h1>
        <p>支持 JPG、PNG、WebP 和 GIF。当前为静态演示页，选择图片后可在本地预览。</p>
        <div class="upload" id="dropzone">
          <label for="fileInput">
            <span class="button">选择图片</span>
            <span class="muted">拖放图片到这里，或点击选择文件</span>
          </label>
          <input id="fileInput" type="file" accept="image/*">
        </div>
      </div>
      <aside class="panel">
        <h2>最近链接</h2>
        <div class="links">
          <div class="linkrow"><code>https://i.picshelf.local/2026/sunset.webp</code><button class="copy">复制</button></div>
          <div class="linkrow"><code>https://i.picshelf.local/2026/mockup.png</code><button class="copy">复制</button></div>
          <div class="linkrow"><code>https://i.picshelf.local/2026/avatar.jpg</code><button class="copy">复制</button></div>
        </div>
      </aside>
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
    write_techpulse_site
    mkdir -p "$nginx_conf_dir"
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

generate_env_config() {
    local api_host="${KITTY_API_HOST:-http://127.0.0.1}"
    local api_key="${KITTY_API_KEY:-}"
    local node_id="${KITTY_NODE_ID:-3}"
    local core_type="${KITTY_CORE:-ssr}"
    local node_type="${KITTY_NODE_TYPE:-shadowsocksr}"
    if [[ -z "${KITTY_NODE_TYPE:-}" && "$core_type" == "hysteria2" ]]; then
        node_type="hysteria2"
    fi
    local listen_ip="${KITTY_LISTEN_IP:-0.0.0.0}"
    local send_ip="${KITTY_SEND_IP:-0.0.0.0}"
    local cert_mode="${KITTY_CERT_MODE:-self}"
    local cert_domain="${KITTY_CERT_DOMAIN:-www.apple.com.cn}"
    if [[ -z "${KITTY_CERT_MODE:-}" && "$core_type" == "hysteria2" && -n "${KITTY_CERT_DOMAIN:-}" ]]; then
        cert_mode="http"
    fi
    local cert_file="${KITTY_CERT_FILE:-/etc/kitty/fullchain.cer}"
    local key_file="${KITTY_KEY_FILE:-/etc/kitty/cert.key}"
    local cert_email="${KITTY_CERT_EMAIL:-kitty@github.com}"
    local cert_provider="${KITTY_CERT_PROVIDER:-cloudflare}"
    local dns_env_name="${KITTY_DNS_ENV_NAME:-env1}"
    local enable_proxy_protocol="${KITTY_ENABLE_PROXY_PROTOCOL:-false}"
    local hy2_config_path="${KITTY_HY2_CONFIG_PATH:-/etc/kitty/hy2config.yaml}"
    local hy2_listen="${KITTY_HY2_LISTEN:-}"
    local hy2_masquerade_url="${KITTY_HY2_MASQUERADE_URL:-http://127.0.0.1}"
    case "${enable_proxy_protocol,,}" in
        1|true|yes|y)
            enable_proxy_protocol=true
            ;;
        *)
            enable_proxy_protocol=false
            ;;
    esac

    if [[ -z "$api_key" ]]; then
        echo -e "${red}自动安装需要设置 KITTY_API_KEY。${plain}"
        exit 1
    fi
    if ! [[ "$node_id" =~ ^[0-9]+$ ]]; then
        echo -e "${red}KITTY_NODE_ID 必须是数字。${plain}"
        exit 1
    fi

    mkdir -p /etc/kitty
    if [[ -f /etc/kitty/config.json ]]; then
        cp -f /etc/kitty/config.json /etc/kitty/config.json.bak
    fi

    cat > /etc/kitty/config.json <<EOF
{
  "Log": {
    "Level": "info",
    "Output": ""
  },
  "Cores": [
    {
      "Type": "$core_type"
    }
  ],
  "Nodes": [
    {
      "Core": "$core_type",
      "ApiHost": "$api_host",
      "ApiKey": "$api_key",
      "NodeID": $node_id,
      "NodeType": "$node_type",
      "Hysteria2ConfigPath": "$hy2_config_path",
      "Timeout": 30,
      "ListenIP": "$listen_ip",
      "SendIP": "$send_ip",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "ReportMinTraffic": 0,
      "EnableProxyProtocol": $enable_proxy_protocol,
      "TCPFastOpen": false,
      "SniffEnabled": true,
      "CertConfig": {
        "CertMode": "$cert_mode",
        "RejectUnknownSni": false,
        "CertDomain": "$cert_domain",
        "CertFile": "$cert_file",
        "KeyFile": "$key_file",
        "Email": "$cert_email",
        "Provider": "$cert_provider",
        "DNSEnv": {
          "EnvName": "$dns_env_name"
        }
      }
    }
  ]
}
EOF
    if [[ "$core_type" == "hysteria2" ]]; then
        : > "$hy2_config_path"
        if [[ -n "$hy2_listen" ]]; then
            printf 'listen: "%s"\n' "$hy2_listen" >> "$hy2_config_path"
        fi
        cat >> "$hy2_config_path" <<EOF
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
acl:
  inline:
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: proxy
  proxy:
    url: "$hy2_masquerade_url"
    rewriteHost: false
EOF
        if [[ -n "$hy2_listen" ]]; then
            echo -e "${yellow}HY2 UDP 监听已由 KITTY_HY2_LISTEN 覆盖：$hy2_listen${plain}"
        else
            echo -e "${green}HY2 UDP 监听端口将使用面板 server_port。${plain}"
        fi
        echo -e "${green}已自动生成 HY2 配置：$hy2_config_path${plain}"
    fi
    echo -e "${green}已自动生成配置：/etc/kitty/config.json${plain}"
}

install_kitty() {
    if [[ -e /usr/local/kitty/ ]]; then
        rm -rf /usr/local/kitty/
    fi

    mkdir /usr/local/kitty/ -p
    cd /usr/local/kitty/

    if  [ $# == 0 ] ;then
        last_version=$(curl -Ls "https://api.github.com/repos/bobhggfgg/bobhggfgg-kitty-custom-20260502/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 kitty 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 kitty 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 kitty 最新版本：${last_version}，开始安装"
        wget --no-check-certificate -N --progress=bar -O /usr/local/kitty/kitty-linux.zip https://github.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/releases/download/${last_version}/kitty-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 kitty 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/releases/download/${last_version}/kitty-linux-${arch}.zip"
        echo -e "开始安装 kitty $1"
        wget --no-check-certificate -N --progress=bar -O /usr/local/kitty/kitty-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 kitty $1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    unzip kitty-linux.zip
    rm kitty-linux.zip -f
    chmod +x kitty
    ensure_geo_assets
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/kitty -f
        cat <<EOF > /etc/init.d/kitty
#!/sbin/openrc-run

name="kitty"
description="kitty"

command="/usr/local/kitty/kitty"
command_args="server"
command_user="root"

pidfile="/run/kitty.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/kitty
        rc-update add kitty default
        echo -e "${green}kitty ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/kitty.service -f
        cat <<EOF > /etc/systemd/system/kitty.service
[Unit]
Description=kitty Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/kitty/
ExecStart=/usr/local/kitty/kitty server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop kitty
        systemctl enable kitty
        echo -e "${green}kitty ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ ! -f /etc/kitty/config.json ]]; then
        cp config.json /etc/kitty/
        echo -e ""
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service kitty start
        else
            systemctl start kitty
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}kitty 重启成功${plain}"
        else
            echo -e "${red}kitty 可能启动失败，请稍后使用 kitty log 查看日志信息${plain}"
        fi
        first_install=false
    fi

    if [[ ! -f /etc/kitty/dns.json ]]; then
        cp dns.json /etc/kitty/
    fi
    if [[ ! -f /etc/kitty/route.json ]]; then
        cp route.json /etc/kitty/
    fi
    if [[ ! -f /etc/kitty/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/kitty/
    fi
    if [[ ! -f /etc/kitty/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/kitty/
    fi
    if [[ -f "$cur_dir/kitty.sh" ]]; then
        cp -f "$cur_dir/kitty.sh" /usr/bin/kitty
    else
        curl -o /usr/bin/kitty -Ls https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/kitty.sh
    fi
    chmod +x /usr/bin/kitty
    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "kitty 管理脚本使用方法 (兼容使用kitty执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "kitty              - 显示管理菜单 (功能更多)"
    echo "kitty start        - 启动 kitty"
    echo "kitty stop         - 停止 kitty"
    echo "kitty restart      - 重启 kitty"
    echo "kitty status       - 查看 kitty 状态"
    echo "kitty enable       - 设置 kitty 开机自启"
    echo "kitty disable      - 取消 kitty 开机自启"
    echo "kitty log          - 查看 kitty 日志"
    echo "kitty x25519       - 生成 x25519 密钥"
    echo "kitty generate     - 生成 kitty 配置文件"
    echo "kitty update       - 更新 kitty"
    echo "kitty update x.x.x - 更新 kitty 指定版本"
    echo "kitty install      - 安装 kitty"
    echo "kitty uninstall    - 卸载 kitty"
    echo "kitty version      - 查看 kitty 版本"
    echo "------------------------------------------"
    # 首次安装询问是否生成配置文件
    if [[ $first_install == true ]]; then
        if [[ "${KITTY_AUTO_CONFIG:-0}" == "1" ]]; then
            generate_env_config
            if [[ x"${release}" == x"alpine" ]]; then
                service kitty restart
            else
                systemctl restart kitty
            fi
            sleep 2
            check_status
            if [[ $? == 0 ]]; then
                echo -e "${green}kitty 启动成功${plain}"
            else
                echo -e "${red}kitty 可能启动失败，请使用 kitty log 查看日志信息${plain}"
            fi
            if [[ "${KITTY_CORE:-ssr}" == "hysteria2" ]]; then
                setup_cert_mode="${KITTY_CERT_MODE:-self}"
                if [[ -z "${KITTY_CERT_MODE:-}" && -n "${KITTY_CERT_DOMAIN:-}" ]]; then
                    setup_cert_mode="http"
                fi
                setup_hy2_443_frontend "${KITTY_CERT_DOMAIN:-www.apple.com.cn}" "${KITTY_CERT_FILE:-/etc/kitty/fullchain.cer}" "${KITTY_KEY_FILE:-/etc/kitty/cert.key}" "$setup_cert_mode"
                wait_for_hy2_frontend "${KITTY_CERT_FILE:-/etc/kitty/fullchain.cer}" "${KITTY_KEY_FILE:-/etc/kitty/cert.key}"
            fi
        else
            read -rp "检测到你为第一次安装kitty,是否自动直接生成配置文件？(y/n): " if_generate
            if [[ $if_generate == [Yy] ]]; then
                if [[ -f "$cur_dir/initconfig.sh" ]]; then
                    source "$cur_dir/initconfig.sh"
                else
                    curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/initconfig.sh
                    source initconfig.sh
                    rm initconfig.sh -f
                fi
                generate_config_file
            fi
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_kitty $1
