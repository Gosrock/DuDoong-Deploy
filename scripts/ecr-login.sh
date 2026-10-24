#!/bin/sh
# 사용: REGISTRY=$(sh ~/srv/ubuntu/scripts/ecr-login.sh)
# 서버의 EC2 인스턴스 역할로 ECR 비공개 저장소에 docker 로그인하고, 레지스트리 주소를 출력한다 (Deploy #59).
# 받기 권한은 infra/ecr.yml (운영 이미지 저장소 읽기만). 로그인은 12시간 유효 — 배포 때마다 새로 한다.
# 계정 ID 가 들어간 레지스트리 주소는 퍼블릭 리포에 적지 않고 여기서 만든다. 서버에 AWS CLI 가 없어서 fetch-env.sh 와 같은 이미지를 쓴다.
set -eu
umask 077

REGION=ap-northeast-2
IMAGE="public.ecr.aws/aws-cli/aws-cli:2.17.43"
ERR=$(mktemp)
: > "$ERR"
trap 'rm -f "$ERR"' EXIT
mask() { sed -E 's/[0-9]{12}/***/g; s/i-[0-9a-f]{8,17}/i-***/g'; }
fail() { echo "$1 — 배포를 멈춘다. 원인(앞부분):" >&2; head -c 300 "$ERR" | mask >&2; echo >&2; exit 1; }

aws() { sudo docker run --rm --network host "$IMAGE" --region "$REGION" "$@"; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2> "$ERR") || fail "AWS 계정 확인 실패"
case "$ACCOUNT" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) fail "AWS 계정 ID 형식 이상" ;; esac
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# 비밀번호는 파이프로만 넘긴다 (명령줄·로그에 남지 않게)
aws ecr get-login-password 2>> "$ERR" | sudo docker login --username AWS --password-stdin "$REGISTRY" > /dev/null 2>> "$ERR" \
  || fail "ECR 로그인 실패"

echo "$REGISTRY"
