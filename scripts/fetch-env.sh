#!/bin/sh
# 사용: sh ~/srv/ubuntu/scripts/fetch-env.sh <prod|staging>
# 서버의 EC2 인스턴스 역할로 SSM /dudoong/env/<이름> 을 읽어 ~/srv/ubuntu/.env 를 만든다 (Deploy #28).
# 운영 서버는 prod 만, 스테이징 서버는 staging 만 읽을 수 있다 (infra/server-env-access.yml).
# SSM 에 아직 없으면 배포 워크플로가 GitHub ENV_VARS 로 만든 .env 를 그대로 쓴다 (이관 기간용).
# 서버에 AWS CLI 가 없어서 공식 이미지를 잠깐 띄워 쓴다. 값은 화면에 출력하지 않는다.
set -eu

NAME="$1"
DIR="$HOME/srv/ubuntu"
IMAGE="public.ecr.aws/aws-cli/aws-cli:2.17.43"

if sudo docker run --rm --network host "$IMAGE" ssm get-parameter --region ap-northeast-2 \
    --name "/dudoong/env/$NAME" --with-decryption --query Parameter.Value --output text \
    > "$DIR/.env.ssm" 2> "$DIR/.env.ssm.err" && [ -s "$DIR/.env.ssm" ]; then
  mv "$DIR/.env.ssm" "$DIR/.env"
  echo ".env: SSM /dudoong/env/$NAME 사용"
else
  rm -f "$DIR/.env.ssm"
  if grep -q ParameterNotFound "$DIR/.env.ssm.err" 2>/dev/null; then
    echo ".env: SSM /dudoong/env/$NAME 이 아직 없음 → GitHub ENV_VARS 로 만든 .env 사용"
  else
    echo ".env: SSM 읽기 실패 → GitHub ENV_VARS 로 만든 .env 사용. 원인(앞부분):"
    head -c 300 "$DIR/.env.ssm.err" | sed 's/[0-9]\{12\}/***/g'; echo
  fi
fi
rm -f "$DIR/.env.ssm.err"
chmod 600 "$DIR/.env" 2>/dev/null || true

# 둘 다 없으면 앱이 설정 없이 뜨므로 배포를 멈춘다 (ENV_VARS 가 비어 있어도 echo 가 빈 줄을 남기므로 KEY= 줄로 확인)
if ! grep -q '^[A-Za-z_][A-Za-z0-9_]*=' "$DIR/.env" 2>/dev/null; then
  echo ".env 가 비어 있다 — SSM /dudoong/env/$NAME 등록 또는 GitHub ENV_VARS 확인"
  exit 1
fi
