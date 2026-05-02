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

generate_env_config() {
    local api_host="${KITTY_API_HOST:-http://127.0.0.1}"
    local api_key="${KITTY_API_KEY:-}"
    local node_id="${KITTY_NODE_ID:-3}"
    local core_type="${KITTY_CORE:-ssr}"
    local node_type="${KITTY_NODE_TYPE:-shadowsocksr}"
    local listen_ip="${KITTY_LISTEN_IP:-0.0.0.0}"
    local send_ip="${KITTY_SEND_IP:-0.0.0.0}"
    local cert_mode="${KITTY_CERT_MODE:-self}"
    local cert_domain="${KITTY_CERT_DOMAIN:-www.apple.com.cn}"
    local cert_file="${KITTY_CERT_FILE:-/etc/kitty/fullchain.cer}"
    local key_file="${KITTY_KEY_FILE:-/etc/kitty/cert.key}"
    local cert_email="${KITTY_CERT_EMAIL:-kitty@github.com}"
    local cert_provider="${KITTY_CERT_PROVIDER:-cloudflare}"
    local dns_env_name="${KITTY_DNS_ENV_NAME:-env1}"

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
      "Timeout": 30,
      "ListenIP": "$listen_ip",
      "SendIP": "$send_ip",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "ReportMinTraffic": 0,
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
    mkdir /etc/kitty/ -p
    cp geoip.dat /etc/kitty/
    cp geosite.dat /etc/kitty/
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
    curl -o /usr/bin/kitty -Ls https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/kitty.sh
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
        else
            read -rp "检测到你为第一次安装kitty,是否自动直接生成配置文件？(y/n): " if_generate
            if [[ $if_generate == [Yy] ]]; then
            curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/bobhggfgg/bobhggfgg-kitty-custom-20260502/main/initconfig.sh
            source initconfig.sh
            rm initconfig.sh -f
            generate_config_file
            fi
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_kitty $1
