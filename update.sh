#!/usr/bin/env sh

trojan_version=$(curl --silent "https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest" | jq ".tag_name" | tr -d '"')
installed_version=$(/usr/local/bin/trojan-go -version | grep "Trojan-Go v" | awk '{print $2}')

if [ "$trojan_version" != "$installed_version" ]; then
  echo "Trojan 现有版本为 $trojan_version，需要升级到版本 $installed_version"
  wget -c -O trojan-go.zip "https://github.com/p4gefau1t/trojan-go/releases/download/$trojan_version/trojan-go-linux-amd64.zip"
  unzip -o trojan-go.zip trojan-go
  rm -f trojan-go.zip
  mv -f trojan-go /usr/local/bin/trojan-go
  systemctl restart trojan-go
  echo "Trojan 升级完成"
else
  echo "Trojan 已经是最新的版本"
fi
