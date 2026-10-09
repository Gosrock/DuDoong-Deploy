#!/bin/sh
# 사용: sh ~/srv/ubuntu/scripts/tls-cert.sh <prod|staging>
# nginx 가 HTTPS 를 직접 처리할 인증서를 Let's Encrypt 에서 발급·갱신한다 (Deploy #37, WorkBook EP09 5단계).
# - DNS 검증(Route 53): 서버 인스턴스 역할로 자기 도메인의 _acme-challenge TXT 만 고친다 (infra/tls-cert-access.yml)
# - 만료 30일 전이 되기 전에는 아무것도 하지 않는다 → 배포 때마다, 매일 cron 으로 불러도 된다
# - 인증서는 ~/tls 에 둔다 (~/srv/ubuntu 는 배포 rsync --delete 대상이라 지워진다)
# - 발급에 실패해도 배포는 멈추지 않는다. 쓰던 인증서가 없을 때만 임시 자체 서명 인증서를 만들어 nginx 가 뜨게 한다
#   (만료 임박은 .github/workflows/tls-check.yml 이 매일 확인해 알린다)
set -eu

NAME="${1:-}"
case "$NAME" in
  prod)    DOMAINS="dudoong.com internal-admin.dudoong.com" ;;
  staging) DOMAINS="staging.dudoong.com staging-internal-admin.dudoong.com" ;;
  *) echo "사용: tls-cert.sh <prod|staging>"; exit 1 ;;
esac

TLS="$HOME/tls"
LE="$TLS/letsencrypt"   # certbot 상태 (계정·발급 이력)
OUT="$TLS/certs"        # nginx 가 읽는 파일 (docker-compose 에서 /etc/nginx/certs 로 마운트)
IMAGE="certbot/dns-route53:v5.8.0"
SCRIPT="$HOME/srv/ubuntu/scripts/tls-cert.sh"

mkdir -p "$TLS"
sudo install -d -m 700 "$LE" "$OUT"

# 매일 갱신 + 재부팅 직후 한 번 (스테이징은 평소 꺼져 있어 켜질 때 확인한다)
CRON="# Deploy #37 — Let's Encrypt 갱신 (scripts/tls-cert.sh)
23 4 * * * $USER sh $SCRIPT $NAME >> $TLS/cron.log 2>&1
@reboot $USER sleep 90 && sh $SCRIPT $NAME >> $TLS/cron.log 2>&1"
if [ "$(sudo cat /etc/cron.d/dudoong-tls 2>/dev/null || true)" != "$CRON" ]; then
  printf '%s\n' "$CRON" | sudo tee /etc/cron.d/dudoong-tls > /dev/null
  sudo chmod 644 /etc/cron.d/dudoong-tls
fi

args=""
for d in $DOMAINS; do args="$args -d $d"; done
changed=0

# shellcheck disable=SC2086
if sudo docker run --rm --network host -v "$LE:/etc/letsencrypt" "$IMAGE" certonly \
    --dns-route53 --non-interactive --agree-tos --register-unsafely-without-email \
    --cert-name dudoong --keep-until-expiring --expand $args > "$TLS/certbot.log" 2>&1; then
  live="$LE/live/dudoong"
  if ! sudo cmp -s "$live/fullchain.pem" "$OUT/fullchain.pem"; then
    sudo cp -L "$live/privkey.pem" "$OUT/privkey.pem.new"
    sudo cp -L "$live/fullchain.pem" "$OUT/fullchain.pem.new"
    sudo chmod 600 "$OUT/privkey.pem.new" "$OUT/fullchain.pem.new"
    sudo mv "$OUT/privkey.pem.new" "$OUT/privkey.pem"
    sudo mv "$OUT/fullchain.pem.new" "$OUT/fullchain.pem"
    changed=1
  fi
  echo "인증서: Let's Encrypt ($DOMAINS), 만료 $(sudo openssl x509 -enddate -noout -in "$OUT/fullchain.pem" | cut -d= -f2)"
else
  echo "인증서 발급·갱신 실패 — 쓰던 인증서로 계속 동작한다. 원인(마지막 줄):"
  tail -3 "$TLS/certbot.log"
  if ! sudo test -s "$OUT/fullchain.pem"; then
    first=${DOMAINS%% *}
    sudo openssl req -x509 -nodes -newkey rsa:2048 -days 7 -subj "/CN=$first" \
      -keyout "$OUT/privkey.pem" -out "$OUT/fullchain.pem" 2> /dev/null
    sudo chmod 600 "$OUT/privkey.pem" "$OUT/fullchain.pem"
    echo "인증서가 없어 임시 자체 서명 인증서(7일)를 만들었다 — HTTPS 직접 접속은 브라우저 경고가 난다"
    changed=1
  fi
fi

# 바뀌었으면 떠 있는 nginx 에 반영 (안 떠 있으면 다음 기동 때 읽는다)
if [ "$changed" = 1 ]; then
  c=$(sudo docker ps -q -f name=nginx)
  if [ -n "$c" ]; then sudo docker exec "$c" nginx -s reload && echo "nginx reload"; fi
fi
