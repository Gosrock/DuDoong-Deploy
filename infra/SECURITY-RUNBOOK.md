# 보안 설정 배포 절차 (Deploy #30)

> 퍼블릭 리포라 실제 IP·비밀번호·키는 여기 적지 않는다

이번 변경: nginx 전달 헤더 재작성·보안 헤더·로그 쿼리스트링 제거, Redis 비밀번호·localhost bind·이미지 고정.

---

## 1. 배포 전에 할 일 (순서대로)

### ① 백엔드: Redisson 에도 비밀번호 적용 (선행 필수)

Lettuce(`RedisConfig`)는 `REDIS_PASSWORD` 를 쓰지만 `RedissonConfig` 는 비밀번호를 넣지 않는다.
Redis 에 비밀번호를 걸면 Redisson(분산 락·bucket4j)이 붙지 못한다. 이 수정이 들어간 백엔드 버전이 운영·스테이징에 먼저 떠 있어야 한다.

### ② SSM 에 `REDIS_PASSWORD` 추가

- `/dudoong/env/prod`, `/dudoong/env/staging` 에 `REDIS_PASSWORD=<값>` 줄을 추가한다 (아직 GitHub `ENV_VARS` 를 쓰는 서버라면 거기에도)
- 값은 영숫자만: `openssl rand -hex 32`. `$`·따옴표·공백은 compose 와 앱이 다르게 읽을 수 있다
- 값이 없거나 비어 있으면 compose 가 시작을 거부한다(`${REDIS_PASSWORD:?}`) → 스테이징 배포가 실패하고 운영으로 넘어가지 않는다
- 운영과 스테이징은 다른 값을 쓴다

### ③ Redis 버전 확인

compose 는 `redis:8.10-alpine` 으로 고정한다. Redis 는 자기보다 새 버전이 쓴 RDB 를 못 읽으므로 서버에서 지금 버전을 확인한다.

```bash
sudo docker exec $(sudo docker ps -qf name=redis) redis-server --version
```

8.10 보다 높으면 compose 의 태그를 그 버전에 맞춘다.

### ④ nginx 이미지 빌드

compose 가 `water0641/dudoong-nginx:1.8.0` 을 쓴다. 머지하기 전에 PR 마지막 커밋에 `Nginx-v1.8.0` 태그를 push 해서 이미지를 먼저 만든다 (Actions "Build & Docker Push - Nginx").
이미지가 없을 때 머지되면 `pull` 에서 스테이징 배포가 실패하고 운영은 그대로다 → 태그 빌드 후 Deployment 를 수동 실행하면 된다.

## 2. 배포할 때 생기는 일

- **로그인 풀림**: Redis 설정이 바뀌어 컨테이너가 새로 만들어진다. compose 에 Redis 볼륨이 없고 새 이미지는 `/data` 볼륨도 선언하지 않아 기존 데이터가 넘어오지 않는다 → refresh token 이 사라진다 → 모든 사용자가 access token 만료(기본 1시간) 뒤 다시 로그인해야 한다. 이용이 적은 시간에 배포한다
- 같은 이유로 진행 중이던 분산 락·rate limit 카운터도 초기화된다
- 응답에 HSTS(1년, 하위 도메인 포함)·`X-Frame-Options: DENY`·`nosniff`·`Referrer-Policy` 가 붙는다. 다른 사이트가 두둥 페이지를 iframe 으로 넣으면 막힌다. 스테이징에서 결제(토스 → `/pay/confirm`) 1회 확인

## 3. 되돌리기

- nginx: compose 의 이미지를 `1.7.0` 으로 되돌려 배포
- Redis: `command` 를 지우면 비밀번호 없이 뜬다. 앱은 `REDIS_PASSWORD` 가 있어도 Redis 쪽에 비밀번호가 없으면 AUTH 오류가 나므로 SSM 값도 함께 지운다

---

## 스테이징 분리 (사용자 작업)

스테이징이 운영과 같은 DB 계정·JWT 키를 쓰면 스테이징 서버 하나가 털려도 운영 데이터·토큰 위조로 이어진다. 아래는 secrets·DB 작업이라 사람이 한다.

### DB 계정

1. RDS 에 스테이징 전용 스키마와 계정을 만든다. 스테이징 앱은 `ddl-auto: update` 라 자기 스키마에는 DDL 권한이 필요하다
   ```sql
   CREATE DATABASE <스테이징 DB>;
   CREATE USER '<스테이징 계정>'@'%' IDENTIFIED BY '<새 비밀번호>';
   GRANT ALL PRIVILEGES ON <스테이징 DB>.* TO '<스테이징 계정>'@'%';
   ```
   운영 스키마에는 아무 권한도 주지 않는다
2. 스테이징에 필요한 데이터가 있으면 운영 덤프가 아니라 개인정보를 뺀 데이터로 채운다
3. SSM `/dudoong/env/staging` 의 `DB_NAME`·`MYSQL_USERNAME`·`MYSQL_PASSWORD` 를 바꾸고 스테이징 배포
4. 운영 계정 비밀번호를 스테이징이 알고 있었으므로 운영 `MYSQL_PASSWORD` 도 교체한다 (SSM `/dudoong/env/prod`·배치 `/dudoong/env/batch` 같이)

### JWT 키

1. 새 키 생성: `openssl rand -base64 64 | tr -d '\n'`
2. SSM `/dudoong/env/staging` 의 `JWT_SECRET_KEY` 만 새 값으로 바꾸고 스테이징 배포 (스테이징 사용자만 다시 로그인)
3. 운영 키는 그대로 두되, 스테이징과 같은 값이었다면 운영도 교체를 검토한다 (교체하면 운영 전체 재로그인)

### 확인

- SSM 에서 prod·staging 값이 서로 다른지 확인: `REDIS_PASSWORD`·`MYSQL_USERNAME`·`MYSQL_PASSWORD`·`JWT_SECRET_KEY`
- 스테이징에서 받은 토큰으로 운영 API 를 부르면 401 이어야 한다


## 하지 않기로 한 것
- `/internal-api` 접근 IP 제한: 운영자 접속 환경이 고정되어 있지 않아 적용하지 않는다(2026-10-10 결정). 운영 어드민 보호는 어드민 전용 토큰 분리(Backend #763)로 보강한다.
