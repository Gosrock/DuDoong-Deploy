#!/bin/bash
# 서버에 docker 와 docker-compose 가 없으면 설치한다 (배포 때마다 실행, 있으면 아무것도 안 함).
# amd64(t2/t3)·arm64(t4g) 모두 지원 — Deploy #41

# Installing docker engine if not exists
if ! type docker > /dev/null
then
  echo "docker does not exist"
  echo "Start installing docker"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi

# Installing docker-compose if not exists
# 1.29.2(v1)은 arm64 바이너리가 없어서 새 서버에는 v2 단독 실행 파일을 docker-compose 이름으로 설치한다 (명령 호환)
if ! type docker-compose > /dev/null
then
  echo "docker-compose does not exist"
  echo "Start installing docker-compose"
  sudo curl -fL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# 스왑 2GB (없을 때만). 1~2GB 메모리 서버에 컨테이너 6개 + JVM 이라 스왑이 없으면 백엔드 기동이 10분 넘게 걸린다 (Deploy #41)
if ! swapon --show | grep -q /swapfile
then
  echo "swapfile does not exist"
  echo "Start creating 2G swapfile"
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
