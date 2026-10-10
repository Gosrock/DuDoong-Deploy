#!/bin/bash
# GitHub Actions 러너에서 실행: 서버에 SSM Run Command 로 배포를 시키고 끝날 때까지 기다린다. Deploy #50
# 사용: bash scripts/ssm-deploy.sh <인스턴스 ID> <prod|staging> <커밋 SHA>
# 서버는 이 리포(공개)의 해당 커밋을 GitHub 에서 받아 scripts/remote-deploy.sh 를 실행한다 → SSH·22번 포트 불필요
set -euo pipefail

IID="$1"; NAME="$2"; SHA="$3"
case "$NAME" in prod|staging) ;; *) echo "잘못된 대상: $NAME"; exit 1 ;; esac
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "잘못된 커밋 SHA"; exit 1; }
mask() { sed -E 's/[0-9]{12}/***/g; s/i-[0-9a-f]{8,17}/i-***/g; s/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g'; }

SCRIPT="set -euo pipefail; T=\$(mktemp -d); trap 'rm -rf \"\$T\"' EXIT; \
curl -fsSL https://codeload.github.com/Gosrock/DuDoong-Deploy/tar.gz/$SHA | tar -xz -C \"\$T\" --strip-components=1; \
bash \"\$T/scripts/remote-deploy.sh\" $NAME \"\$T\""
PARAMS=$(jq -n --arg c "sudo -u ubuntu -H bash -c $(printf '%q' "$SCRIPT")" '{commands:[$c], executionTimeout:["1800"]}')

# 막 켜진 서버는 SSM 에이전트가 등록될 때까지 몇십 초 걸린다 → 최대 5분 재시도
for i in $(seq 1 30); do
  if CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
        --comment "deploy $NAME ${SHA:0:7}" --parameters "$PARAMS" \
        --query Command.CommandId --output text 2> send.err); then break; fi
  grep -q InvalidInstanceId send.err || { mask < send.err; exit 1; }
  echo "SSM 에이전트 대기 ($i)"; sleep 10; CID=""
done
[ -n "$CID" ] || { echo "SSM 에 등록되지 않은 서버"; exit 1; }
echo "SSM 명령 보냄: ${NAME} ${SHA:0:7}"

while :; do
  st=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)
  case "$st" in Pending|InProgress|Delayed) sleep 10 ;; *) break ;; esac
done
aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query StandardOutputContent --output text | mask
err=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query StandardErrorContent --output text | tail -20 | mask)
[ "$st" = Success ] && { echo "배포 성공 ($NAME)"; exit 0; }
echo "배포 실패 ($NAME): $st"; echo "$err"; exit 1
