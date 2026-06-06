#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

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

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启kitty" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version
    else
        version=$2
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/install.sh) $version
    if [[ $? == 0 ]]; then
        echo -e "${green}更新完成，已自动重启 kitty，请使用 kitty log 查看运行日志${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "kitty在修改配置后会自动尝试重启"
    vi /etc/kitty/config.json
    sleep 2
    restart
    check_status
    case $? in
        0)
            echo -e "kitty状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动kitty或kitty自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -rp "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "kitty状态: ${red}未安装${plain}"
    esac
}

uninstall() {
    confirm "确定要卸载 kitty 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service kitty stop
        rc-update del kitty
        rm /etc/init.d/kitty -f
    else
        systemctl stop kitty
        systemctl disable kitty
        rm /etc/systemd/system/kitty.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi
    rm /etc/kitty/ -rf
    rm /usr/local/kitty/ -rf

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/kitty -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}kitty已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service kitty start
        else
            systemctl start kitty
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}kitty 启动成功，请使用 kitty log 查看运行日志${plain}"
        else
            echo -e "${red}kitty可能启动失败，请稍后使用 kitty log 查看日志信息${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service kitty stop
    else
        systemctl stop kitty
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}kitty 停止成功${plain}"
    else
        echo -e "${red}kitty停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        if [[ ! -f /etc/init.d/kitty ]]; then
            echo -e "${yellow}未检测到 kitty 服务，请先执行 kitty install 安装。${plain}"
            return
        fi
        service kitty restart
    else
        if ! command -v systemctl >/dev/null 2>&1 || ! systemctl list-unit-files kitty.service --no-legend 2>/dev/null | grep -q '^kitty.service'; then
            echo -e "${yellow}未检测到 kitty.service，请先执行 kitty install 安装。${plain}"
            return
        fi
        systemctl restart kitty
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}kitty 重启成功，请使用 kitty log 查看运行日志${plain}"
    else
        echo -e "${red}kitty可能启动失败，请稍后使用 kitty log 查看日志信息${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service kitty status
    else
        systemctl status kitty --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add kitty
    else
        systemctl enable kitty
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}kitty 设置开机自启成功${plain}"
    else
        echo -e "${red}kitty 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del kitty
    else
        systemctl disable kitty
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}kitty 取消开机自启成功${plain}"
    else
        echo -e "${red}kitty 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo -e "${red}alpine系统暂不支持日志查看${plain}\n" && exit 1
    else
        journalctl -u kitty.service -e --no-pager -f
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

install_bbr() {
    bash <(curl -L -s https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh)
}

update_shell() {
    wget -O /usr/bin/kitty -N --no-check-certificate https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/kitty.sh
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/kitty
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
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

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep kitty)
        if [[ x"${temp}" == x"" ]]; then
            return 1
        else
            return 0
        fi
    else
        temp=$(systemctl is-enabled kitty)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1;
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}kitty已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装kitty${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "kitty状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "kitty状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "kitty状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

generate_x25519_key() {
    echo -n "正在生成 x25519 密钥："
    /usr/local/kitty/kitty x25519
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_kitty_version() {
    echo -n "kitty 版本："
    /usr/local/kitty/kitty version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
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
                "type": "field",
                "outboundTag": "block",
                "ip": [
                    "geoip:private"
                ]
            },
            {
                "type": "field",
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
                "type": "field",
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
                "type": "field",
                "outboundTag": "block",
                "protocol": [
                    "bittorrent"
                ]
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

    echo -e "${green}kitty 配置文件生成完成，正在重新启动 kitty 服务${plain}"
    restart 0
    if [ "$hy2_selected" = true ]; then
        wait_for_hy2_frontend "/etc/kitty/fullchain.cer" "/etc/kitty/cert.key"
    fi
    before_show_menu
}

# 放开防火墙端口
open_ports() {
    systemctl stop firewalld.service 2>/dev/null
    systemctl disable firewalld.service 2>/dev/null
    setenforce 0 2>/dev/null
    ufw disable 2>/dev/null
    iptables -P INPUT ACCEPT 2>/dev/null
    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -P OUTPUT ACCEPT 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -t mangle -F 2>/dev/null
    iptables -F 2>/dev/null
    iptables -X 2>/dev/null
    netfilter-persistent save 2>/dev/null
    echo -e "${green}放开防火墙端口成功！${plain}"
}

show_usage() {
    echo "kitty 管理脚本使用方法: "
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
    echo "kitty update x.x.x - 安装 kitty 指定版本"
    echo "kitty install      - 安装 kitty"
    echo "kitty uninstall    - 卸载 kitty"
    echo "kitty version      - 查看 kitty 版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}kitty 后端管理脚本，${plain}${red}不适用于docker${plain}
--- https://github.com/bobhggfgg/bobhggfgg-kitty-custom-20260502 ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 kitty
  ${green}2.${plain} 更新 kitty
  ${green}3.${plain} 卸载 kitty
————————————————
  ${green}4.${plain} 启动 kitty
  ${green}5.${plain} 停止 kitty
  ${green}6.${plain} 重启 kitty
  ${green}7.${plain} 查看 kitty 状态
  ${green}8.${plain} 查看 kitty 日志
————————————————
  ${green}9.${plain} 设置 kitty 开机自启
  ${green}10.${plain} 取消 kitty 开机自启
————————————————
  ${green}11.${plain} 一键安装 bbr (最新内核)
  ${green}12.${plain} 查看 kitty 版本
  ${green}13.${plain} 生成 X25519 密钥
  ${green}14.${plain} 升级 kitty 维护脚本
  ${green}15.${plain} 生成 kitty 配置文件
  ${green}16.${plain} 放行 VPS 的所有网络端口
  ${green}17.${plain} 退出脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -rp "请输入选择 [0-17]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) install_bbr ;;
        12) check_install && show_kitty_version ;;
        13) check_install && generate_x25519_key ;;
        14) update_shell ;;
        15) generate_config_file ;;
        16) open_ports ;;
        17) exit ;;
        *) echo -e "${red}请输入正确的数字 [0-16]${plain}" ;;
    esac
}


if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "update") check_install 0 && update 0 $2 ;;
        "config") config $* ;;
        "generate") generate_config_file ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "x25519") check_install 0 && generate_x25519_key 0 ;;
        "version") check_install 0 && show_kitty_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage
    esac
else
    show_menu
fi
