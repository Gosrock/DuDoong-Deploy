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
  리포지토리 secret AWS_ACCOUNT_ID   (그 밖의 Secrets/Variables 불필요)
  Environment DuDoong-Infra          (secret 없음, 승인 관문만: 필수 승인자 + main 브랜치만)
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

- 운영·스테이징은 **지금 서버에 실제로 쓰이는 파일**을 그대로 올린다
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
cf dudoong-tls-cert-access    tls-cert-access.yml        # 서버가 자기 도메인 _acme-challenge TXT 만 고치는 권한 (HTTPS 인증서)

# ③ 받은 파일 지우기 (CloudShell 홈은 계속 남는 저장소다)
rm -f ~/prod.env ~/staging.env ~/batch.env && ls ~/*.env 2>/dev/null || echo "지움"
```

- 서버 `.env` 읽기·스테이징 제어 권한은 **IMDSv2 로 받은 자격 증명만** 허용한다 (`ec2:RoleDelivery`). 서버의 AWS CLI v2·백엔드 AWS SDK v2 는 IMDSv2 를 쓰므로 그대로 동작하고, IMDSv1 경로(SSRF 등)로 새는 자격 증명으로는 `.env` 를 못 읽는다. 운영 서버 IMDSv2 강제는 Deploy #27

①의 마지막 줄에 나온 계정 ID 를 다음 단계에 쓴다. 내 컴퓨터의 `.env` 3개도 지운다.

## 3. GitHub (DuDoong-Deploy)

1. Settings → Secrets and variables → Actions → **Repository secrets** → `AWS_ACCOUNT_ID` = 계정 ID
2. Settings → Environments → **`DuDoong-Infra`** 만들기 (secret 은 넣지 않는다)
   - **Required reviewers** 1명 이상, Deployment branches = **`main` 만**
   - 배치 반영·수동 실행(정산은 호스트에게 메일·알림톡을 실제로 보낸다)·이미지 복사가 승인 뒤에만 돈다
3. (권장) Settings → Branches → `main` 보호: PR 리뷰 필수

## 4. 확인

- 다음 배포 로그에 `.env: SSM /dudoong/env/staging 사용`, `... /dudoong/env/prod 사용` 이 나오면 서버 이관 끝
- 스테이징 자동 종료 켜기: SSM `/dudoong/infra/staging-auto-stop-state` = `ENABLED` (대문자) → `cf dudoong-staging-control staging-control.yml` 다시 실행
- SSM 값만 바꾸면 자동 반영되지 않는다: 앱 `.env` 는 다음 배포 때, 배치 값은 Actions "Infra Deploy (batch)" 수동 실행, 그 밖의 스택은 `cf ...` 다시 실행
- 스테이징 켜기·끄기는 Actions → "Staging Power" (status / start / stop) 에서만. start 는 켠 뒤 main 최신 버전을 배포한다. Deployment(main 머지)는 스테이징이 꺼져 있으면 스테이징 배포를 건너뛴다
- 배치: `infra/BATCH-RUNBOOK.md`
- 내부 어드민 스테이징 버튼: 운영 .env(SSM `/dudoong/env/prod`)에 `STAGING_INSTANCE_ID=<스테이징 인스턴스 ID>` 줄을 추가하고 백엔드 새 버전 배포 (dev → v2 DDL 먼저)

## 5. 이미지 비공개 저장소 ECR (Deploy #59)

Docker Hub 공개 이미지 대신 ECR 비공개 저장소에서 받는다. VPC 엔드포인트 없이 IAM 으로만 막는다 (비용: 저장 용량만, 월 $1 안팎).

```bash
# CloudShell (관리자 계정)
cf dudoong-ecr ecr.yml   # 저장소 6개 + 서버 pull 정책 + 리포별 push 역할
```

1. Backend·Admin-Front·Front·dudoong-frontend-v2 리포에도 Repository secret `AWS_ACCOUNT_ID` 등록 (각 리포가 자기 push 역할을 맡는다)
2. Actions → **Image Copy (Docker Hub → ECR)** 를 입력 없이 실행 → compose 가 쓰는 태그를 전부 복사
3. 그 뒤 compose 를 ECR 주소로 바꾼 PR 을 머지

| 저장소 | 올리는 곳 | 태그 |
|---|---|---|
| dudoong-api | Backend `Api-v*` | 덮어쓰기 불가 |
| dudoong-batch (batch.yml) | Backend `Batch-v*` | 덮어쓰기 불가 |
| dudoong-nginx | Deploy `Nginx-v*` | 덮어쓰기 불가 |
| dudoong-internal-admin | Admin-Front `AdminFront-v*`·`dev` | `dev` 만 덮어쓰기 |
| dudoong-ticket, dudoong-admin | Front `Ticket-v*`·`Admin-v*`·`dev` | `dev` 만 덮어쓰기 |
| dudoong-front | v2 프론트(`dudoong-frontend-v2`) `v*`·`main`(→ `dev`) (#84) | `dev` 만 덮어쓰기 |

- 저장소마다 태그 있는 이미지 최근 10개만 남고, 태그 없는 이미지(덮어쓴 옛 `dev`)는 7일 뒤 지워진다
- 아직 Docker Hub 에만 올리는 리포가 있으면, 배포 전에 Image Copy 에 `dudoong-ticket:1.3.2` 처럼 넣어 복사한다
- 버전 태그는 덮어쓸 수 없어 **먼저 올린 이미지가 그 버전이 된다** → 각 리포 Settings → Rules 에 태그 ruleset (`Api-v*`·`Batch-v*`·`AdminFront-v*`·`Nginx-v*`·`Ticket-v*`·`Admin-v*` 생성은 관리자만)
- 서버에서 compose 를 직접 다룰 때는 레지스트리 값을 같이 넘긴다 (없으면 compose 가 바로 실패):
  `sudo env ECR_REGISTRY=$(sh ~/srv/ubuntu/scripts/ecr-login.sh) docker-compose -f ~/srv/ubuntu/docker-compose.prod.yml logs -f backend`
- 배치는 Backend 가 ECR `dudoong-batch` 에 바로 올린다 (Backend #825)
