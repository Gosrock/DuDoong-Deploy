# 배치 이전 런북: 센터(Jenkins) → ECS Fargate

> WorkBook EP09 4단계 · Deploy #25·#28 · 퍼블릭 리포라 리소스 ID·시크릿은 적지 않는다
> 처음 설정(SSM 등록·역할 스택·GitHub secret)은 `infra/SETUP.md` 를 먼저 끝낸다

## 무엇이 바뀌나

| | 지금 | 이후 |
|---|---|---|
| 실행 위치 | 센터 EC2 (상시 켜짐, 월 ~$15) | ECS Fargate (실행할 때만, 월 $1 미만) |
| 스케줄 | Jenkins cron | EventBridge Scheduler (`infra/batch.yml`) |
| 이미지 | `water0641/dudoong-batch:latest` (=1.0.5-1) | ECR `dudoong-batch:1.0.5-1` (같은 이미지, 태그 고정) |
| env | 센터 `/root/dudoong/.env.prod` | SSM `/dudoong/env/batch` (같은 파일, ECS 가 직접 주입) |
| Redis | 센터 redis 컨테이너 | 같은 태스크의 Redis 사이드카 (`REDIS_HOST=localhost`) |
| 수동 실행 | Jenkins "Build" | Actions "Batch Run (manual)" |
| 인프라 변경 | 콘솔·서버 | `infra/batch.yml` PR → 머지 시 반영 (GitOps) |

| job | 스케줄 (KST) | 파라미터 |
|---|---|---|
| `이벤트_자동만료` | 19~22시 0·30분 | `version=$RUN_ID` (실행마다 epoch 초) |
| `슬랙유저통계` | 매일 21:30 | `date=$TODAY` (KST yyyy-MM-dd) |
| 정산 7개 (아래) | 스케줄 없음, **수동** | `eventId=<공연 ID> version=$RUN_ID` |

**정산 job** (운영 DB 기록: 2023-03 ~ 2024-03-16에 공연별로 수동 실행, PG 결제 중단 이후 미실행). 이 순서로 돈다:
`이벤트거래정산` → `이벤트정산요약` → `이벤트정산서` → `이벤트주문목록_엑셀업로드` → `이벤트정산_이메일발송_어드민` → `이벤트정산_이메일발송_호스트` → `이벤트정산_알림톡발송_호스트`
- Actions "Batch Run (manual)"에서 `정산_전체` + 공연 ID → 7개를 순서대로, 하나라도 실패하면 멈춤. 개별 job도 고를 수 있다
- 정산 job은 Redis 분산 락을 쓰는데, 사이드카 Redis라 운영 API와 락을 공유하지 않는다. 정산은 공연이 끝난 뒤에 돌리므로 같은 공연의 주문 처리와 겹칠 일이 거의 없어 이렇게 둔다(사용자 확인 2026-10-09). 다시 자주 쓰게 되면 운영 Redis 연결(B안)을 검토

## 1. 준비 (1회)

`infra/SETUP.md` 1~3단계(SSM 등록, 역할 스택, GitHub secret `AWS_ACCOUNT_ID`)를 끝낸 뒤:

1. Actions **"Infra Deploy (batch)"** 수동 실행 (main) → `dudoong-batch` 스택 생성
   - 실패하면 Actions 가 빨간색으로 끝난다. 스택이 `ROLLBACK_COMPLETE` 면 콘솔에서 스택 삭제 → ECR `dudoong-batch` 저장소가 남아 있으면 같이 지우고 다시 실행
   - SNS 구독 확인 메일의 링크를 누른다 (`/dudoong/infra/alert-email`)
2. Actions **"Batch Image Copy"** 실행 (tag `1.0.5-1`)

- 배치 env 는 SSM `/dudoong/env/batch` 를 ECS 가 태스크에 넣는다. 진입 스크립트가 `docker --env-file` 과 같은 규칙으로 읽는다(값을 해석하지 않음 — 실제 이미지로 비교 확인). Redis 는 사이드카(`localhost:6379`, 비밀번호 없음)로 덮어쓴다
- 배치 반영 역할은 **GitHub Environment `DuDoong-Infra`(필수 승인자 + main 만) 승인을 받은 job 만** 맡을 수 있고, PR 은 실행 권한 없는 미리보기 역할만 맡는다. **콘솔에서 변경 세트를 직접 실행(Execute)하지 않는다**

## 2. 확인 (스케줄 꺼진 상태)

Actions **"Batch Run (manual)"**
- `이벤트_자동만료` 실행 → exit code 0, Slack "공연 자동 만료 알림" 도착. 이미 닫힌 공연은 다시 닫지 않아 몇 번 돌려도 안전
- `슬랙유저통계` 는 날짜마다 한 번만 성공한다(Spring Batch 같은 파라미터 재실행 불가). 오늘 21:30 Jenkins가 이미 돌았으면 실패하는 게 정상 → **아직 안 돈 날짜**로 시험하면 그 날짜 통계가 Slack에 한 번 더 올라간다
- CloudWatch Logs `/dudoong/batch` 에서 로그 확인 (Actions 로그에는 배치 로그를 찍지 않는다)
- `BATCH_JOB_EXECUTION` 에 기록이 남는지 확인

## 3. 전환

같은 날 Jenkins와 Fargate가 둘 다 돌면 Slack 메시지가 두 번 온다. 전환은 한 번에:

1. Jenkins에서 `이벤트_만료처리`, `유저일일통계정보-prod` **비활성화**
2. 알림 메일 구독 확인이 된 것을 확인
3. SSM `/dudoong/infra/batch-schedules-state` = `ENABLED` → Actions "Infra Deploy (batch)" 실행
4. 그날 저녁 19:00~22:30, 21:30 실행을 Slack·내부 어드민 "배치 이력"으로 확인

## 4. 관찰 후 센터 정리

1. 1주 관찰 (실패 알림 없음, 매일 Slack 메시지)
2. 센터 EC2 **중지** (2주 보관 — 롤백용)
3. 2주 뒤: 센터 EC2 종료, ALB 규칙·타겟그룹 `Dudoong-jenkins`, Route 53 `jenkins.dudoong.com` 정리
   - ⚠️ 보안그룹 `Dudoong-center-bound` 는 **지우지 않는다** (스테이징이 같이 쓴다)

## 롤백

- 전환 직후: SSM `/dudoong/infra/batch-schedules-state` = `DISABLED` → "Infra Deploy (batch)" + Jenkins 작업 다시 활성화
- 센터 중지 후: 센터 EC2 시작 → Jenkins 작업 활성화

## 알아둘 것

- 이미지는 2023-07 빌드(Java 시절 코드)를 그대로 쓴다. dev(Kotlin) 코드 batch 이미지로 바꾸는 건 별도 이슈 — Boot 3 배치 실행 설정과 **Spring Batch 5 메타데이터 스키마 마이그레이션**을 확인한 뒤 "Batch Image Copy" → SSM `/dudoong/infra/batch-image-tag` 변경 → "Infra Deploy (batch)" (템플릿 기본값만 바꾸는 PR은 기존 스택에 반영되지 않는다)
- 실패 알림 (SNS 메일, SSM `/dudoong/infra/alert-email`)
  - `app` 컨테이너가 0이 아닌 코드로 끝남
  - 태스크가 시작조차 못 함 (이미지 pull 실패, env 파일 없음 등)
  - 스케줄러가 태스크를 못 띄움 (권한·서브넷·용량 → DLQ 알람)
- 수동 실행이 55분 넘게 안 끝나면 Actions 는 실패로 끝나지만 **태스크는 계속 돌 수 있다.** 다시 실행하지 말고 배치 이력 화면에서 확인. `정산_전체` 를 다시 돌리면 이미 성공한 메일·알림톡 job 도 다시 나간다 → 실패한 job부터 개별 실행
- 진입 스크립트는 `BATCH_ARGS` 를 셸로 해석(eval)하지 않고 `$TODAY`/`$RUN_ID` 자리표시자만 바꾼다. 수동 실행 입력(공연 ID·날짜)도 값 전체를 검사한다 → 입력에 명령을 섞어도 실행되지 않는다
- 이미지 복사 때 Docker Hub 이미지 digest 를 Actions 로그에 남기고, ECR 은 푸시 때 취약점을 스캔한다
- 한글 job 이름: 이미지의 JVM 이 `LANG` 없이도 UTF-8 로 인자를 읽는 것을 확인함 (`sun.jnu.encoding=UTF-8`)
- ECR 은 태그 없는 이미지만 7일 뒤 정리한다 (쓰는 태그는 지우지 않음, 태그 변경 불가)
- 태스크는 퍼블릭 서브넷 + 퍼블릭 IP(실행 중에만 과금)로 나간다. 들어오는 포트는 없다
