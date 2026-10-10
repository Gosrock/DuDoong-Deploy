#!/bin/sh
# 사용: sh ~/srv/ubuntu/scripts/fetch-env.sh <prod|staging>
# 서버의 EC2 인스턴스 역할로 SSM /dudoong/env/<이름> 을 읽어 ~/srv/ubuntu/.env 를 만든다 (Deploy #28).
# 운영 서버는 prod 만, 스테이징 서버는 staging 만 읽을 수 있다 (infra/server-env-access.yml).
# 서버에 AWS CLI 가 없어서 공식 이미지를 잠깐 띄워 쓴다. 값은 화면에 출력하지 않는다.
# 읽지 못하면(없음·권한·네트워크 등) 옛 값으로 조용히 뜨지 않게 배포를 멈춘다. GitHub ENV_VARS 예비 경로는 없앴다 (Deploy #41).
set -eu
# 만드는 파일(.env.ssm·.env·오류 로그)이 처음부터 본인만 읽게 (Deploy #48)
umask 077

NAME="$1"
DIR="$HOME/srv/ubuntu"
IMAGE="public.ecr.aws/aws-cli/aws-cli:2.17.43"
mask() { sed -E 's/[0-9]{12}/***/g; s/i-[0-9a-f]{8,17}/i-***/g'; }

if ! sudo docker pull -q "$IMAGE" > /dev/null 2> "$DIR/.env.ssm.err"; then
  echo "AWS CLI 이미지를 받지 못해 배포를 멈춘다:"; head -c 300 "$DIR/.env.ssm.err" | mask; echo
  rm -f "$DIR/.env.ssm.err"; exit 1
fi

if sudo docker run --rm --network host "$IMAGE" ssm get-parameter --region ap-northeast-2 \
    --name "/dudoong/env/$NAME" --with-decryption --query Parameter.Value --output text \
    > "$DIR/.env.ssm" 2> "$DIR/.env.ssm.err" && [ -s "$DIR/.env.ssm" ]; then
  mv "$DIR/.env.ssm" "$DIR/.env"
  echo ".env: SSM /dudoong/env/$NAME 사용"
else
  rm -f "$DIR/.env.ssm"
  echo ".env: SSM /dudoong/env/$NAME 읽기 실패 — 배포를 멈춘다. 원인(앞부분):"
  head -c 300 "$DIR/.env.ssm.err" | mask; echo
  rm -f "$DIR/.env.ssm.err"; exit 1
fi
rm -f "$DIR/.env.ssm.err"
chmod 600 "$DIR/.env" 2>/dev/null || true

# 값이 비어 있으면 앱이 설정 없이 뜨므로 배포를 멈춘다
if ! grep -q '^[A-Za-z_][A-Za-z0-9_]*=' "$DIR/.env" 2>/dev/null; then
  echo ".env 가 비어 있다 — SSM /dudoong/env/$NAME 값 확인"
  exit 1
fi
