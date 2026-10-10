#!/bin/bash
# 서버에서 실행되는 배포 (SSM Run Command → ubuntu 사용자). Deploy #50
# 사용: bash remote-deploy.sh <prod|staging> <내려받은 소스 디렉터리>
# 예전 SSH 배포(rsync → fetch-env → tls-cert → compose → 헬스체크)와 같은 순서다.
set -euo pipefail

NAME="${1:-}"; SRC="${2:-}"
DIR="$HOME/srv/ubuntu"
case "$NAME" in
  prod)    COMPOSE=docker-compose.prod.yml ;;
  staging) COMPOSE=docker-compose.staging.yml ;;
  *) echo "사용: remote-deploy.sh <prod|staging> <소스 디렉터리>"; exit 1 ;;
esac
[ -f "$SRC/$COMPOSE" ] || { echo "소스가 없다: $SRC"; exit 1; }

echo "== 소스 반영 ($NAME)"
mkdir -p "$DIR"
# .env 는 fetch-env.sh 가 SSM 에서 만든다 — 소스에 없으니 지우지 않게 제외
rsync -a --delete --exclude .env "$SRC"/ "$DIR"/

sh "$DIR/docker-install.sh"
sh "$DIR/scripts/fetch-env.sh" "$NAME"
sh "$DIR/scripts/tls-cert.sh" "$NAME"

echo "== docker-compose up"
sudo docker-compose -f "$DIR/$COMPOSE" pull -q
sudo docker-compose -f "$DIR/$COMPOSE" --env-file "$DIR/.env" up -d
sudo docker system prune --all -f > /dev/null

echo "== 헬스체크 (최대 10분)"
for i in $(seq 1 60); do
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://localhost/api/v1/examples/health || true)
  echo "try $i: $code"
  [ "$code" = "200" ] && exit 0
  sleep 10
done
echo "$NAME health check failed"
sudo docker ps --format '{{.Names}}\t{{.Status}}'
exit 1
