#!/usr/bin/env sh

USAGE="Usage: $(basename $0) -d <domain-name> -i <server-ip> -k <ssh-pubkey> -p <trojan-password> -P <ssh-port>"

args=$(getopt -o "d:i:k:p:P:h" -- "$@")
eval set -- "$args"
while [ $# -ge 1 ]; do
  case "$1" in
  --)
    # No more options left.
    shift
    break
    ;;
  -d)
    domain_name="$2"
    shift
    ;;
  -i)
    server_ip="$2"
    shift
    ;;
  -k)
    ssh_pubkey="$2"
    shift
    ;;
  -p)
    trojan_password="$2"
    shift
    ;;
  -P)
    ssh_port="$2"
    shift
    ;;
  -h)
    echo "$USAGE"
    exit 0
    ;;
  esac
  shift
done

if [ -z "$server_ip" ] || [ -z "$domain_name" ] || [ -z "$ssh_pubkey" ] || [ -z "$trojan_password" ]; then
  echo "Error: Missing arguments"
  echo "$USAGE"
  exit 0
fi

if [ -z "$ssh_port" ]; then
  ssh_port="22"
fi

# 安装需要的文件：config.yaml, trojan-go.service, 400.html nginx.conf
# 安装依赖库
apt update -y

if ! apt install -y docker.io docker-compose nginx wget curl jq unzip qrencode sudo cron; then
  echo "部分软件安装失败，请手动安装"
  echo "如果是 docker 安装问题，请考虑使用以下命令进行安装："
  echo "curl -fsSL https://get.docker.com | sh"
  return 1
fi

# 创建用户和用户组
if ! grep -q certusers /etc/group; then
  /usr/sbin/groupadd certusers
else
  echo "用户组 certusers 已存在"
fi

if ! grep -q docker /etc/group; then
  /usr/sbin/groupadd docker
else
  echo "用户组 docker 已存在"
fi

if ! grep -q trojan /etc/passwd; then
  /usr/sbin/useradd -r -M -G certusers trojan
  echo "已创建用户 trojan"
else
  echo "用户 trojan 已存在"
fi

if ! grep -q acme /etc/passwd; then
  /usr/sbin/useradd -r -m -G certusers acme
  echo "已创建用户 acme"
else
  echo "用户组 acme 已存在"
fi

# 创建普通用户
if ! grep -q Alderson /etc/passwd; then
  /usr/sbin/useradd -m -s /bin/bash -G sudo,docker Alderson
  echo "已创建用户 Alderson"
  echo "请输入密码："
  passwd Alderson
else
  echo "用户 Alderson 已存在"
fi

# 加入 sudo 和 docker 组
if ! groups Alderson | grep -q sudo; then
  echo "将 trojan 用户加入 sudo 组"
  usermod -G sudo Alderson
fi

if ! groups Alderson | grep -q docker; then
  echo "将 trojan 用户加入 docker 组"
  usermod -G docker Alderson
fi

# 使用公钥验证登录 SSH
if [ -f /home/Alderson/.ssh/authorized_keys ]; then
  echo "SSH 公钥已存在"
else
  mkdir -p /home/Alderson/.ssh
  echo "$ssh_pubkey" >/home/Alderson/.ssh/authorized_keys
  chown -R Alderson:Alderson /home/Alderson/.ssh/
fi

# 修改 sshd 配置文件
sed -i.bak -e "s/^.*Port .*$/Port $ssh_port/g" \
  -e "s/^.*PermitRootLogin.*yes.*$/PermitRootLogin no/g" \
  -e "s/^.*PubkeyAuthentication.*$/PubkeyAuthentication yes/g" \
  -e "s/^.*AuthorizedKeysFile.*$/AuthorizedKeysFile .ssh\/authorized_keys/g" \
  -e "s/^.*PasswordAuthentication.*yes.*$/PasswordAuthentication no/g" \
  /etc/ssh/sshd_config
ufw disable
systemctl restart sshd
echo "已重新配置 SSH"

# 开启 bbr
if [ "bbr" = "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')" ]; then
  echo "bbr 拥塞控制算法已开启"
else
  echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
  sysctl -p
  echo "bbr 拥塞控制算法未开启，现在已开启"
fi

# 修改 nginx 配置
if [ -f ./nginx.conf ]; then
  rm -f /etc/nginx/sites-available/default
  rm -f /etc/nginx/sites-enabled/default
  sed -e "s/<<server_name>>/$domain_name/g" \
    -e "s/<<ip>>/$server_ip/g" \
    ./nginx.conf >/etc/nginx/sites-available/default
  ln /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
  rm -f ./nginx.conf
fi
mkdir -p /var/www/html/
chown trojan:trojan 400.html
mv -f ./400.html /var/www/html/400.html
systemctl restart nginx
echo "nginx 已经配置完成"

# 配置证书签发
mkdir -p /etc/letsencrypt/live
chown -R acme:acme /etc/letsencrypt/live
nginx_user="$(ps -eo user,command | grep nginx | grep "worker process" | awk '{print $1}')"
usermod -G certusers "$nginx_user"
mkdir -p /var/www/acme-challenge
chown -R acme:certusers /var/www/acme-challenge

sudo -i -u acme bash <<EOF
if [ -e "/home/acme/.acme.sh" ]; then
  echo "acme.sh 已经安装"
else
  echo "安装 acme.sh："
  curl https://get.acme.sh | sh
fi
LE_WORKING_DIR="/home/acme/.acme.sh"
'/home/acme/.acme.sh/acme.sh' --set-default-ca --server letsencrypt
'/home/acme/.acme.sh/acme.sh' --issue -d "$domain_name" -w /var/www/acme-challenge
'/home/acme/.acme.sh/acme.sh' --install-cert -d "$domain_name" --key-file /etc/letsencrypt/live/private.key --fullchain-file /etc/letsencrypt/live/certificate.crt
'/home/acme/.acme.sh/acme.sh' --upgrade  --auto-upgrade
chmod -R 750 /etc/letsencrypt/live
EOF
chown -R acme:certusers /etc/letsencrypt/live

# 安装 Trojan
trojan_version=$(curl --silent "https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest" | jq ".tag_name" | tr -d '"')
if [ "$trojan_version" = "null" ]; then
  exit 1
fi
wget -c -O trojan-go.zip "https://github.com/p4gefau1t/trojan-go/releases/download/$trojan_version/trojan-go-linux-amd64.zip"
unzip -o trojan-go.zip trojan-go
rm -f trojan-go.zip
mkdir -p /usr/local/etc/trojan-go
mv -f trojan-go /usr/local/bin/trojan-go
mv -f config.yaml /usr/local/etc/trojan-go/config.yaml
mv -f trojan-go.service /etc/systemd/system/trojan-go.service
chown trojan:trojan /usr/local/bin/trojan-go
chmod 500 /usr/local/bin/trojan-go
chown root:root /etc/systemd/system/trojan-go.service
chown -R trojan:trojan /usr/local/etc/trojan-go

# 修改 Trojan 配置文件
sed -i.bak -e "s/<<password>>/$trojan_password/g" \
  -e "s/<<server_name>>/$domain_name/g" \
  /usr/local/etc/trojan-go/config.yaml

systemctl daemon-reload
systemctl enable trojan-go
systemctl enable nginx
systemctl restart trojan-go
if systemctl status trojan-go | grep -q "active (running)"; then
  echo "Trojan 成功启动"
else
  echo "Trojan 启动失败"
fi

# 添加计划任务
if ! crontab -u trojan -l 2>/dev/null | grep -q "trojan-go"; then
  echo "没有添加定时重启 Trojan 的计划任务"
  entry="30 4 */3 * * /bin/systemctl restart trojan-go"
  if crontab -u trojan -l 2>&1 | grep -q "no crontab"; then
    echo "$entry" | crontab -u trojan -
  else
    crontab -u trojan -l 2>/dev/null | sed "\$a $entry" | crontab -u trojan -
  fi
  echo "现已添加 Trojan 计划任务"
fi

# 告诉用户启动 docker 容器
echo "安装已经完成，你可以添加 Docker 容器来作为域名主页了"

# 生成 Trojan 分享链接（二维码形式）
qrencode -o - -t ANSI "trojan://$trojan_password@$domain_name:443?sni=$domain_name&allowinsecure=0"

# 拷贝 docker-compose.yml 给 Alderson
cp ./docker-compose.yml /home/Alderson/docker-compose.yml
