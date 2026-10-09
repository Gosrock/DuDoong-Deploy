#!/usr/bin/env bash
# 두둥 설정값·시크릿을 AWS SSM Parameter Store 에 등록한다 (Deploy #28).
# AWS CloudShell(관리자 계정)에서 실행. 리소스 ID 는 자동으로 찾고, .env 값은 화면에 출력하지 않는다.
#
# 사용:
#   bash infra/bootstrap-ssm.sh --email <알림 메일> [--prod-env 파일] [--staging-env 파일] [--batch-env 파일]
#
#   --prod-env     운영 서버 ~/srv/ubuntu/.env 를 받아 둔 파일     → /dudoong/env/prod
#   --staging-env  스테이징 서버 ~/srv/ubuntu/.env 를 받아 둔 파일 → /dudoong/env/staging
#   --batch-env    센터 서버 /root/dudoong/.env.prod 를 받아 둔 파일 → /dudoong/env/batch
#   .env 는 필요한 것만 골라 여러 번 나눠 실행해도 된다. 이미 있는 값은 덮어쓴다.
set -euo pipefail

REGION=ap-northeast-2
EMAIL=""
declare -A ENV_FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --prod-env) ENV_FILES[prod]="$2"; shift 2 ;;
    --staging-env) ENV_FILES[staging]="$2"; shift 2 ;;
    --batch-env) ENV_FILES[batch]="$2"; shift 2 ;;
    *) echo "알 수 없는 옵션: $1"; exit 1 ;;
  esac
done

aws() { command aws --region "$REGION" "$@"; }
put() { aws ssm put-parameter --name "$1" --type "$2" --value "$3" --overwrite > /dev/null; echo "  등록: $1 = $3"; }
exists() { aws ssm get-parameter --name "$1" > /dev/null 2>&1; }
# 같은 Name 태그가 여러 대면 엉뚱한 서버가 잡히므로 정확히 1대일 때만 쓴다
instance_id() {
  ids=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  n=$(echo "$ids" | wc -w | tr -d ' ')
  if [ "$n" != "1" ]; then echo "Name=$1 인 인스턴스가 $n 대 — 1대여야 한다" >&2; exit 1; fi
  echo "$ids"
}

echo "== 인프라 설정값 (/dudoong/infra/*)"
vpc=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
subnets=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" Name=default-for-az,Values=true \
  Name=availability-zone,Values=ap-northeast-2a,ap-northeast-2c --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
rds_sg=$(aws ec2 describe-security-groups --filters Name=group-name,Values=dudoong-rds --query 'SecurityGroups[0].GroupId' --output text)
prod=$(instance_id Dudoong-Production)
staging=$(instance_id Dudoong-staging)
for v in "$vpc" "$subnets" "$rds_sg" "$prod" "$staging"; do
  if [ -z "$v" ] || [ "$v" = "None" ]; then echo "리소스를 찾지 못함 (VPC·서브넷·RDS 보안그룹·인스턴스 Name 태그 확인)"; exit 1; fi
done
put /dudoong/infra/vpc-id String "$vpc"
put /dudoong/infra/batch-subnet-ids StringList "$subnets"
put /dudoong/infra/rds-sg-id String "$rds_sg"
put /dudoong/infra/prod-instance-id String "$prod"
put /dudoong/infra/staging-instance-id String "$staging"

if [ -n "$EMAIL" ]; then
  put /dudoong/infra/alert-email String "$EMAIL"
elif ! exists /dudoong/infra/alert-email; then
  echo "--email 이 필요하다 (배치 실패 알림 받을 메일)"; exit 1
fi
# 운영 중에 바꾸는 값은 처음 한 번만 기본값으로 만든다 (이미 있으면 그대로 둔다)
exists /dudoong/infra/batch-schedules-state || put /dudoong/infra/batch-schedules-state String DISABLED
exists /dudoong/infra/batch-image-tag || put /dudoong/infra/batch-image-tag String 1.0.5-1
exists /dudoong/infra/staging-auto-stop-state || put /dudoong/infra/staging-auto-stop-state String DISABLED
# 상태 값은 대문자 ENABLED / DISABLED 만 쓴다 (오타면 스택 반영이 실패하고 롤백된다)

for name in "${!ENV_FILES[@]}"; do
  file="${ENV_FILES[$name]}"
  [ -f "$file" ] || { echo "파일 없음: $file"; exit 1; }
  size=$(wc -c < "$file")
  tier=Standard; [ "$size" -gt 4096 ] && tier=Advanced
  lines=$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file" || true)
  odd=$(grep -vE '^[[:space:]]*($|#|[A-Za-z_][A-Za-z0-9_]*=)' "$file" | wc -l | tr -d ' ')
  echo "== /dudoong/env/$name ($size 바이트, 변수 $lines 개, $tier)"
  if [ "$odd" != "0" ]; then
    echo "  ⚠️ 변수로 쓰이지 않는 줄 $odd 개 ('=' 없음 또는 키에 점·대시). 배치에서는 건너뛰므로 확인할 것 (내용은 출력하지 않음)"
  fi
  if [ "$name" != "staging" ] && ! grep -q '^PROFILE=prod$' "$file"; then
    echo "  ⚠️ PROFILE=prod 줄이 없다. 이미지 기본값(dev 등)으로 뜰 수 있으니 확인할 것"
  fi
  aws ssm put-parameter --name "/dudoong/env/$name" --type SecureString --tier "$tier" \
    --value "file://$file" --overwrite > /dev/null
  echo "  등록 (값은 출력하지 않음)"
done

echo
echo "완료. GitHub 에는 리포지토리 secret AWS_ACCOUNT_ID 하나만 넣는다:"
echo "  AWS_ACCOUNT_ID = $(aws sts get-caller-identity --query Account --output text)"
echo "받아 둔 .env 파일은 지운다: rm -f ${ENV_FILES[*]:-}"
