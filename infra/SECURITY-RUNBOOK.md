# 보안 설정 배포 절차 (Deploy #30)

> 퍼블릭 리포라 실제 IP·비밀번호·키는 여기 적지 않는다

이번 변경: nginx 전달 헤더 재작성·보안 헤더·로그 쿼리스트링 제거, nginx 1.30 업그레이드.

---

## 1. 배포 전에 할 일 (순서대로)

### ① nginx 이미지 빌드

compose 가 `water0641/dudoong-nginx:1.8.0` 을 쓴다. 머지하기 전에 PR 마지막 커밋에 `Nginx-v1.8.0` 태그를 push 해서 이미지를 먼저 만든다 (Actions "Build & Docker Push - Nginx").
이미지가 없을 때 머지되면 `pull` 에서 스테이징 배포가 실패하고 운영은 그대로다 → 태그 빌드 후 Deployment 를 수동 실행하면 된다.

## 2. 배포할 때 생기는 일

- 응답에 HSTS(1년, 하위 도메인 포함)·`X-Frame-Options: DENY`·`nosniff`·`Referrer-Policy` 가 붙는다. 다른 사이트가 두둥 페이지를 iframe 으로 넣으면 막힌다. 스테이징에서 결제(토스 → `/pay/confirm`) 1회 확인

## 3. 되돌리기

- nginx: compose 의 이미지를 `1.7.0` 으로 되돌려 배포

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

- SSM 에서 prod·staging 값이 서로 다른지 확인: `MYSQL_USERNAME`·`MYSQL_PASSWORD`·`JWT_SECRET_KEY`
- 스테이징에서 받은 토큰으로 운영 API 를 부르면 401 이어야 한다


## 하지 않기로 한 것
- Redis 비밀번호: 환경변수 추가 부담 대비 효과가 작아 적용하지 않는다(2026-10-10 결정). Redis 는 host 네트워크지만 보안 그룹이 6379 를 외부에 열지 않는다.
- `/internal-api` 접근 IP 제한: 운영자 접속 환경이 고정되어 있지 않아 적용하지 않는다(2026-10-10 결정). 운영 어드민 보호는 어드민 전용 토큰 분리(Backend #763)로 보강한다.

---

## 해외 IP 차단 (Deploy #58)

nginx 가 국내 IP 만 받는다. 그 밖의 IP 는 모든 도메인·경로에서 403 안내 페이지를 받고, 접근 로그에 `geo=0` 으로 남는다 (CloudWatch `dudoong-prod` / `nginx` 스트림).

- 허용 목록: `nginx/geo/allow-kr.conf` — APNIC KR 할당분 + AWS 서울(ap-northeast-2) EC2 대역. AWS 서울은 미국(ARIN) 등록이라 따로 넣는다(운영·스테이징 EIP, Fargate 배치)
- 서버 안·사설 대역(localhost, VPC)은 `nginx.conf` 에서 항상 허용 — 배포 헬스체크, 운영 → 스테이징 헬스체크
- TLS 점검 워크플로(GitHub 러너, 해외)는 핸드셰이크만 하므로 영향 없음

### 목록 갱신 (분기 1회 권장)

```sh
python3 scripts/gen-geo-kr.py   # 목록이 비정상적으로 작으면 파일을 쓰지 않고 실패한다
git diff --stat nginx/geo/      # 변화량 확인 후 커밋, nginx 이미지 새 태그로 빌드·배포
```

### 예외 추가 (해외 출장 등)

`nginx/geo/allow-extra.conf` 에 `<IP>/32 1;  # 사유·기한` 한 줄 추가 → nginx 이미지 새 태그 → 배포. 기한이 지나면 지운다.
퍼블릭 리포라 커밋한 IP 는 공개된다 — 사유에는 이름 대신 역할만 적는다.

### 차단 건수 보기 (CloudWatch Logs Insights, 그룹 `dudoong-prod`)

```
filter @logStream = "nginx" and @message like /geo=0/
| parse @message /^(?<ip>\S+) .*"(?<method>\S+) (?<path>\S+) /
| stats count() by ip | sort count() desc | limit 20
```

### 되돌리기

compose 의 nginx 이미지를 `1.9.2` 로 되돌려 배포한다.
