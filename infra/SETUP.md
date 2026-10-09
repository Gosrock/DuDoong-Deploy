# 인프라 설정 (처음 한 번)

> WorkBook EP09 · Deploy #28 · 퍼블릭 리포라 실제 ID·시크릿은 여기 적지 않는다

설정값과 시크릿은 **AWS SSM Parameter Store** 에 두고, GitHub 에는 **AWS 계정 ID 하나**만 둔다.

```
SSM Parameter Store (서울 리전)
  /dudoong/infra/*        인프라 설정값 — bootstrap-ssm.sh 가 자동으로 찾아 등록
  /dudoong/env/prod       운영 .env      (SecureString) ← 운영 서버가 배포 때 직접 읽음
  /dudoong/env/staging    스테이징 .env  (SecureString) ← 스테이징 서버가 배포 때 직접 읽음
  /dudoong/env/batch      배치 .env      (SecureString) ← ECS 가 배치 태스크에 직접 넣음
GitHub
  리포지토리 secret AWS_ACCOUNT_ID   (그 밖의 Secrets/Variables·새 Environment 불필요)
```

값을 바꿀 때: AWS 콘솔 → Systems Manager → Parameter Store 에서 수정 → 앱은 다음 배포, 인프라는 스택 다시 배포.

---

## 1. .env 파일 3개 받아 두기 (내 컴퓨터)

서버 키(`~/Desktop/두둥/*.pem`)로 받는다. 받은 파일은 다 쓰고 바로 지운다.

```bash
scp -i <운영 키>     ubuntu@<운영 IP>:~/srv/ubuntu/.env ./prod.env
scp -i <스테이징 키> ubuntu@<스테이징 IP>:~/srv/ubuntu/.env ./staging.env
ssh -i <센터 키> ubuntu@<센터 IP> 'sudo cat /root/dudoong/.env.prod' > ./batch.env
```

- 운영·스테이징은 **지금 서버에 실제로 쓰이는 파일**을 그대로 올린다 (GitHub `ENV_VARS` 원문과 다를 수 있다 — 서버 파일이 기준)
- 배치 파일의 Redis 줄은 그대로 둬도 된다 (태스크가 사이드카로 덮어쓴다)

## 2. AWS CloudShell (관리자 계정)

콘솔 위쪽 **CloudShell(>_)** → **Actions → Upload file** 로 위 3개 파일을 올린 뒤:

```bash
git clone https://github.com/Gosrock/DuDoong-Deploy.git && cd DuDoong-Deploy

# ① SSM 등록: 인프라 ID 자동 탐색 + .env 3개 (값은 화면에 안 나온다)
bash infra/bootstrap-ssm.sh --email <배치 실패 알림 메일> \
  --prod-env ~/prod.env --staging-env ~/staging.env --batch-env ~/batch.env

# ② 스택 (파라미터 없음 — 값은 SSM 에서 읽는다)
cf() { aws cloudformation deploy --stack-name "$1" --template-file "infra/$2" --capabilities CAPABILITY_NAMED_IAM; }
cf dudoong-github-deploy-role  github-deploy-role.yml     # 배포 파이프라인 역할 + GitHub OIDC 공급자
cf dudoong-server-env-access   server-env-access.yml      # 서버가 자기 .env 만 SSM 에서 읽는 권한
cf dudoong-staging-control     staging-control.yml        # 어드민 스테이징 켜기/끄기 + 02:00 자동 종료(처음엔 꺼짐)
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com || true   # ECS 처음 사용
cf dudoong-github-batch-role   github-batch-role.yml      # 배치 워크플로 역할 + 권한 경계

# ③ 받은 파일 지우기
rm -f ~/prod.env ~/staging.env ~/batch.env
```

①의 마지막 줄에 나온 계정 ID 를 다음 단계에 쓴다. 내 컴퓨터의 `.env` 3개도 지운다.

## 3. GitHub (DuDoong-Deploy)

1. Settings → Secrets and variables → Actions → **Repository secrets** → `AWS_ACCOUNT_ID` = 계정 ID
2. (권장) Settings → Branches → `main` 보호: PR 리뷰 필수, 관리자 우회 금지 — 배치 반영 역할은 main 에서만 쓸 수 있다

## 4. 확인

- 다음 배포 로그에 `.env: SSM /dudoong/env/staging 사용`, `... /dudoong/env/prod 사용` 이 나오면 서버 이관 끝
- 확인되면 GitHub Environment `DuDoong-Staging`·`DuDoong-Production` 의 `ENV_VARS` secret 을 지운다 (그 전까지는 SSM 이 없을 때 대신 쓰인다)
- 스테이징 자동 종료 켜기: SSM `/dudoong/infra/staging-auto-stop-state` = `ENABLED` → `cf dudoong-staging-control staging-control.yml` 다시 실행
- 배치: `infra/BATCH-RUNBOOK.md`
- 내부 어드민 스테이징 버튼: 운영 .env(SSM `/dudoong/env/prod`)에 `STAGING_INSTANCE_ID=<스테이징 인스턴스 ID>` 줄을 추가하고 백엔드 새 버전 배포 (dev → v2 DDL 먼저)
