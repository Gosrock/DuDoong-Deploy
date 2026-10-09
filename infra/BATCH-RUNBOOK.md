# 배치 이전 런북: 센터(Jenkins) → ECS Fargate

> WorkBook EP09 4단계 · Deploy #25 · 퍼블릭 리포라 리소스 ID·시크릿은 적지 않는다

## 무엇이 바뀌나

| | 지금 | 이후 |
|---|---|---|
| 실행 위치 | 센터 EC2 (상시 켜짐, 월 ~$15) | ECS Fargate (실행할 때만, 월 $1 미만) |
| 스케줄 | Jenkins cron | EventBridge Scheduler (`infra/batch.yml`) |
| 이미지 | `water0641/dudoong-batch:latest` (=1.0.5-1) | ECR `dudoong-batch:1.0.5-1` (같은 이미지, 태그 고정) |
| env | 센터 `/root/dudoong/.env.prod` | 비공개 S3 버킷 `batch.env` (같은 파일) |
| Redis | 센터 redis 컨테이너 | 같은 태스크의 Redis 사이드카 (`REDIS_HOST=localhost`) |
| 수동 실행 | Jenkins "Build" | Actions "Batch Run (manual)" |
| 인프라 변경 | 콘솔·서버 | `infra/batch.yml` PR → 머지 시 반영 (GitOps) |

| job | 스케줄 (KST) | 파라미터 |
|---|---|---|
| `이벤트_자동만료` | 19~22시 0·30분 | `version=$RUN_ID` (실행마다 epoch 초) |
| `슬랙유저통계` | 매일 21:30 | `date=$TODAY` (KST yyyy-MM-dd) |

## 1. 준비 (1회)

1. **OIDC 공급자**가 있어야 한다 → `infra/github-deploy-role.yml` 스택(Deploy #22)을 먼저 배포
2. 배치용 역할 스택
   ```bash
   aws cloudformation deploy --stack-name dudoong-github-batch-role \
     --template-file infra/github-batch-role.yml --capabilities CAPABILITY_NAMED_IAM
   aws cloudformation describe-stacks --stack-name dudoong-github-batch-role --query 'Stacks[0].Outputs'
   ```
3. GitHub → Settings → Environments → **`DuDoong-Infra`** 만들고 Variables 등록
   | 변수 | 값 |
   |---|---|
   | `AWS_ROLE_ARN` | 출력 `GitHubRoleArn` |
   | `CFN_EXEC_ROLE_ARN` | 출력 `CfnExecutionRoleArn` |
   | `BATCH_VPC_ID` | default VPC ID |
   | `BATCH_SUBNET_IDS` | 퍼블릭 서브넷 2개 이상, 쉼표로 (예: 2a,2c) |
   | `RDS_SECURITY_GROUP_ID` | RDS 보안그룹 (`dudoong-rds`) ID |
   | `BATCH_SCHEDULES_STATE` | 처음엔 `DISABLED` |
   | `BATCH_ALERT_EMAIL` | 실패 알림 받을 메일 (선택) |
4. Actions **"Infra Deploy (batch)"** 수동 실행 → `dudoong-batch` 스택 생성
   - 알림 메일을 넣었으면 SNS 구독 확인 메일의 링크를 누른다
5. env 파일 올리기 (센터의 파일 그대로)
   ```bash
   scp -i <센터 키> ubuntu@<센터>:/tmp/batch.env ./batch.env   # 센터에서 먼저: sudo cp /root/dudoong/.env.prod /tmp/batch.env && sudo chown ubuntu /tmp/batch.env
   aws s3 cp ./batch.env s3://<출력 EnvBucketName>/batch.env --sse AES256
   rm ./batch.env                                               # 센터 /tmp/batch.env 도 지운다
   ```
   - `PROFILE=prod` 가 들어 있어야 한다 (없으면 이미지 기본값 dev)
   - `REDIS_HOST/PORT/PASSWORD` 는 태스크 정의가 덮어쓴다 (사이드카)
6. Actions **"Batch Image Copy"** 실행 (tag `1.0.5-1`)

## 2. 확인 (스케줄 꺼진 상태)

Actions **"Batch Run (manual)"**
- `이벤트_자동만료` 실행 → exit code 0, Slack "공연 자동 만료 알림" 도착. 이미 닫힌 공연은 다시 닫지 않아 몇 번 돌려도 안전
- `슬랙유저통계` 는 날짜마다 한 번만 성공한다(Spring Batch 같은 파라미터 재실행 불가). 오늘 21:30 Jenkins가 이미 돌았으면 실패하는 게 정상 → **아직 안 돈 날짜**로 시험하면 그 날짜 통계가 Slack에 한 번 더 올라간다
- CloudWatch Logs `/dudoong/batch` 에서 로그 확인 (Actions 로그에는 배치 로그를 찍지 않는다)
- `BATCH_JOB_EXECUTION` 에 기록이 남는지 확인

## 3. 전환

같은 날 Jenkins와 Fargate가 둘 다 돌면 Slack 메시지가 두 번 온다. 전환은 한 번에:

1. Jenkins에서 `이벤트_만료처리`, `유저일일통계정보-prod` **비활성화**
2. `BATCH_SCHEDULES_STATE` = `ENABLED` → "Infra Deploy (batch)" 실행
3. 그날 저녁 19:00~22:30, 21:30 실행을 Slack·`BATCH_JOB_EXECUTION` 으로 확인

## 4. 관찰 후 센터 정리

1. 1주 관찰 (실패 알림 없음, 매일 Slack 메시지)
2. 센터 EC2 **중지** (2주 보관 — 롤백용)
3. 2주 뒤: 센터 EC2 종료, ALB 규칙·타겟그룹 `Dudoong-jenkins`, Route 53 `jenkins.dudoong.com` 정리
   - ⚠️ 보안그룹 `Dudoong-center-bound` 는 **지우지 않는다** (스테이징이 같이 쓴다)

## 롤백

- 전환 직후: `BATCH_SCHEDULES_STATE=DISABLED` 반영 + Jenkins 작업 다시 활성화
- 센터 중지 후: 센터 EC2 시작 → Jenkins 작업 활성화

## 알아둘 것

- 이미지는 2023-07 빌드(Java 시절 코드)를 그대로 쓴다. dev(Kotlin) 코드 batch 이미지로 바꾸는 건 별도 이슈 — Boot 3 배치 실행 설정 확인 후 `BatchImageTag` 만 바꾸는 PR
- 실패 알림: `app` 컨테이너가 0이 아닌 코드로 끝나면 SNS 메일. 이미지 pull 실패처럼 컨테이너가 시작도 못 한 경우는 알림이 안 갈 수 있다 → 매일 Slack 메시지가 없으면 확인
- 태스크는 퍼블릭 서브넷 + 퍼블릭 IP(실행 중에만 과금)로 나간다. 들어오는 포트는 없다
