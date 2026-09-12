# Target v1 단계별 부하 실행 가이드

이 문서는 **사용자가 실행할 Target 전용 절차**다. 과거 cold Worker와 첫 단계형 Warmup을 실제 실행했으며,
[2026-09-12 Warmup](../reviews/warmup-20260912-review.md)은 Payment 초기 오류로 실패했다.
두 번째 실행 `20260912-223508-886-target-warmup-normal`도 Payment Hikari timeout 13건으로 실패했다.
현재는 정상 거래 한 건의 사전 실행(priming)을 추가한 비교 조건이며, 실제 재실행과 성능 목표 달성은 미검증이다.
과거 baseline 명령은 [load-test-guide](load-test-guide.md), 시나리오 그림은 [아키텍처 위의 부하 흐름](../architecture/target-v1-load-scenario.md)을 본다.

## 1. 실행 경계

공통 진입점은 `ops/performance.ps1 -Mode target`이다. Stage 0 Warmup Validation → Worker → Waiting → Reservation → Isolation → Business 순서이며 각 단계는 독립적인 k6 파일을 갖는다.
자동 상승·다음 단계 이동·반복 실행·장애 주입을 자동 수행하지 않는다. 매번 결과를 검토하고 다음 명령을 선택한다.

| Action | 수행 내용 | 데이터/부하 |
|---|---|---|
| Check (기본) | Target profile, perf DB/Redis namespace, rate/permit, health, Prometheus 6개 target 확인 | 읽기 전용. 초기화·기동·HTTP 시나리오 없음 |
| Prepare | bootJar/image 빌드, 앱 중단, 기존 health 의존 순서로 한 번 기동, 준비 검사 | **데이터 초기화 없음**. 최초 DB의 Flyway는 앱 기동 중 적용. 부하 없음 |
| Run | 비어 있는 perf DB 확인, priming·정리 → warmup/Validation·정리 → 선택한 본 측정·drain·결과 저장 | **실제 부하**. Prepare나 다음 성능 단계로 자동 이동하지 않음 |
| Run -Reset | 사전 검사, 앱 중단, 이전 DB 상태 보존, perf 초기화, 기존 이미지로 한 번 기동한 뒤 Run | **기존 perf 데이터/namespace 삭제 + 실제 부하**. 재빌드·이미지 pull 없음 |

기존 dev/baseline 앱과 dev/test DB 연결이 있으면 준비를 거절한다. 다른 터미널의 Gradle test도 종료한 뒤 실행한다.
같은 물리 호스트에서 dev/test/perf를 함께 실행하지 않는다. 기존 Target은 `./ops/target.ps1 -Action Stop`,
baseline은 `docker compose stop nginx api1 api2 worker mock-pg`로 사용자가 명시적으로 멈춘다.
`Prepare`는 최초 배포 또는 애플리케이션 코드/설정 변경 시 사용한다. RPS·기간·재고·Users만 바꾸는 반복 실험에는
**`Run -Reset` 한 번**이면 된다. `Run`이 사전 검사를 포함하므로 별도 `Check`는 선택 사항이다.
`-Reset` 없는 Run은 이전 판매가 남아 있으면 거절한다. 이 경우 Prepare로 데이터를 지우려고 하지 않는다.
`Run -Reset`도 준비된 역할/설정/관측 상태가 필요하다. 중단되었거나 준비가 실패한 환경은 Prepare로 복구한다.
기존 결과 폴더는 덮어쓰지 않으며, 초기화 직전 DB 상태·timeline은 새 결과 폴더의 `pre-reset-*`에 저장한다.
이 snapshot은 이전 실행의 전체 관측 자료를 대체하지 않는다. 기존 결과 수집이 완료된 뒤 다음 실험을 시작한다.
동일 저장소의 Prepare/Run은 파일 잠금으로 drain·수집 종료까지 겹치지 않게 한다. 다른 도구/checkout의 실행까지 막지는 않는다.
Run 중 Ctrl+C로 중단했다면 `docker ps --filter name=goods-target-k6`로 잔존 생성기를 확인하고
필요할 때 해당 컨테이너만 `docker stop goods-target-k6`로 종료한다. 다음 Prepare는 실행 중 생성기가 있으면 거절한다.

JDK 21, Docker Desktop, PowerShell 7, 로컬 `grafana/k6:0.54.0` 이미지가 필요하다.
이미지가 없으면 사용자가 `docker pull grafana/k6:0.54.0`로 준비한다. fixture를 만든 뒤 이미지 pull로 hold 시간을 소모하지 않게 Run이 사전 확인한다.
이미 실행 중인 Codex의 JAVA_HOME이 오래되었다면 설치된 JDK 경로를 현재 셸에 적용한다.

Git Bash에서도 아래처럼 `pwsh -NoProfile -File ./ops/performance.ps1 ...`로 실행한다.
`cd /d/Code/limited-goods-reservation`으로 저장소 루트에 이동한 뒤 사용한다.
이 문서의 한 줄 `pwsh -File` 명령은 두 셸에서 동일하다. Git Bash에서 여러 줄로 나누려면 `\`를 사용하며,
PowerShell의 줄 연속 문자(백틱)를 사용하지 않는다. `.ps1` 파일을 Bash에 직접 실행시키지 않는다.
Docker의 `/scripts`, `/results` 및 mount 인자는 PowerShell 내부에서 구성하므로 Bash 명령줄로 직접 넘길 필요가 없다.
저장소 밖에서 실행하려면 `-File`에 스크립트의 절대경로를 지정한다. 공백이 있으면 경로를 따옴표로 감싼다.
Target은 Compose 실행 위치를 저장소 루트로 맞추고 종료 후 호출자의 위치를 복원한다.

```bash
# 최초 준비 또는 앱 코드/배포 설정 변경 시. 기존 데이터는 유지한다.
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Prepare
# 선택 사항: Run에도 같은 준비 검사가 포함된다.
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Check

# perf 초기화 후 1회 Worker 측정. 완료 후 result.json 검토.
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario worker -Rps 10 -DurationSeconds 30 -Vus 10 -MaxVus 50
# 앞선 결과를 확인한 후 입력만 변경해서 별도로 실행한다.
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario worker -Rps 40 -DurationSeconds 60 -Vus 10 -MaxVus 100
```

Prepare/Check/Run의 `WaitingRate`, `ReservationRate`, `Permits`는 일치해야 한다. 기본은 25/25/8이다.
기본값을 자동으로 높이거나 gate/ticket 검사를 끄지 않는다. 설정 변경 시험은 Prepare부터 같은 값을 명시한다.
`-Diagnostics`는 baseline 옵션이므로 Target에서는 거절한다. Target 공통 관측은 항상 켜져 있다.

### 기동·초기화 순서

- Prepare: 빌드 → Target 앱 8개 중단 → Compose 기동 1회 → 역할/관측 준비 검사.
  Mock PG는 PostgreSQL health 뒤 기동하면서 Flyway를 적용하고, Reservation은 PostgreSQL·Redis·Mock PG health를 기다린다.
  Waiting 2개는 Redis, Payment는 PostgreSQL·Reservation, Worker는 PostgreSQL·Mock PG·Reservation을 기다린다.
  Public Nginx는 Waiting 2개, Checkout Nginx는 Reservation·Payment·Worker health 뒤 기동한다.
- Run -Reset: 설정·이미지·실행 충돌 검사 → 앱 8개 중단 → 이전 DB 상태 보존 → 공통 reset의 `-AppsStopped`로 초기화
  → `up --no-build --pull never --wait` 1회 → 준비 검사 → priming·정리 → warmup/Validation → evidence 보존·정리 → fixture → 관측·부하·drain·수집.
  PostgreSQL·Redis·Prometheus는 명시적으로 중단하지 않는다. 초기화 실패 시 재기동/부하로 넘어가지 않는다.
- `-AppsStopped`는 중단 검사를 생략하지 않는다. 앱이 남아 있으면 삭제를 거절하고, 이미 멈춘 앱에 stop을 중복 호출하지 않는다.

Prepare는 데이터를 보존하지만 앱을 기동하므로 기존 미완료 주문의 Worker 처리가 다시 진행될 수 있다.
Primary performance SLO는 warmup 이후 steady-state 기준이다. Run -Reset은 재기동 후 아래 warmup을 통과해야 본 측정으로 진행한다.
이전 자동 warmup 없는 결과는 steady-state 증거로 사용하지 않는다. DB/OS 캐시는 남을 수 있어 완전한 cold 환경이라고 부르지 않는다.
Cold-start 결과도 deployment/startup characteristic으로 보존하고 steady-state capacity와 별도 기록한다.
비교 시험은 같은 warmup/reset 조건과 MockPgDelayMs를 사용한다. warmup 후 JVM/container를 재기동하지 않는다.

### Stage 0과 embedded warmup

모든 Target Run은 **정상 거래 한 건을 먼저 실행**한다. `priming.js`는 shared-iterations/VU 1로
Waiting→READY→purchase→SUCCESS 202를 실행하고, harness가 Worker→Mock PG→CONFIRMED를 DB에서 확인한다.
이 한 건은 JIT 최적화 완료 기준이 아니라 첫 실행 비용을 미리 처리하는 최소 비교 조건이다.
Business think time은 없으며 priming HTTP timeout만 15초다. 기존 warmup/본 측정의 5초 client timeout,
서버 Hikari 1초·PG timeout·70초 confirmation 계약과 CPU/memory/pool/JIT 설정은 유지한다.
priming k6 실행은 최대 180초로 제한하고, 이후 실제 결제 deadline까지 drain한다. priming에는 기존 고정 30초 drain 대기를 추가하지 않는다.
오류·미확정·증거 누락이면 정리와 다음 부하를 중단한다. 모든 주문/시도의 정상 완료를 확인한 뒤 사전 거래 데이터를 정리한다.

그다음 `-Scenario warmup`은 기존과 같은 2/s×10초 → 5/s×10초 → 10/s×10초 → 10/s×10초의 부하를 실행한다.
단계는 config.json의 warmupStages에 저장하며 계획 사용자 수와 기간은 여기서 계산한다(현재 계획상 270명).
부하 모양을 유지해 이전 실패와 사전 거래 추가 후의 결과를 비교한다.
각 구간 preAllocatedVUs=maxVUs=40, warmup stock=400이며 측정용 Stock/Vus와 분리한다.
실제 Waiting→READY→purchase→HELD 직후 SUCCESS 202→Worker→Mock PG→CONFIRMED 경로를 검증한다.
Business think time은 적용하지 않는다. Stage 0 앞에 embedded warmup을 중복 실행하지 않는다.

```bash
cd /d/Code/limited-goods-reservation
# 기존 Target perf 서비스가 준비돼 있다면 바로 실행. 스크립트 변경만이므로 재빌드 불필요.
# 재기동/perf 초기화 → 사전 거래/확정/정리 → 기존 40초 warmup → 결과 수집까지 자동 수행.
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario warmup

# 위 결과를 검토한 뒤 사용자가 별도로 실행할 다음 측정.
# 이 명령도 사전 거래와 warmup을 자동 수행하므로 수동 API 호출은 필요 없다.
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario worker -Rps 10 -DurationSeconds 120 -Vus 10 -MaxVus 50
```

환경이 중단되었거나 준비 검사에 실패하면 기존 `-Mode target -Action Prepare`로 복구한 뒤 실행한다.
각 명령은 1회만 실행하며 성공 여부를 보고 사용자가 다음 명령을 선택한다.

도착 수 검사는 constant-arrival-rate 시나리오별 종료 경계의 추가 1회를 허용한다. Warmup은 단계 설정에서 계산한 계획 수~계획 수+단계 수(현재 270~274회),
Business는 계획 수+0~3회(abandon은 +0~4회), Isolation은 +0~2회, 단일 시나리오는 +0~1회다.
계획보다 적은 도착이나 dropped는 허용하지 않는다. PASS는 실제 시작 수=완료 수=구매 수=결제 접수 수=DB 주문·시도·CONFIRMED 수,
dropped/unexpected/Hikari timeout delta/restart/OOM/불변식 위반=0, pending=0 및 SUCCESS deadline 위반=0이다.
Latency는 PASS threshold가 아니며 마지막 두 10/s 구간의 HTTP p95/p99와 backlog 표본은 result.json의 warmupWindows로 남긴다.
이는 저부하 hot path를 반복해 본 측정을 시작할 상태를 만든 증거이며 JIT 완전 최적화나 capacity 인증이 아니다.

다른 모든 Run은 같은 warmup을 먼저 수행한다. warmup/ 하위 폴더에 config, k6-summary, raw, k6.log,
before/after-db, timeline, before/after-containers, prometheus, phases, result를 독립 보존한다.
Hikari timeout은 warmup과 본 측정 각각의 boundary-before/after snapshot delta로 검사하고,
process start/restart는 각 trial의 Prometheus window에서 별도로 확인한다.
실패·수집 누락 시 정리/본 측정으로 진행하지 않는다. 독립 Stage 0은 결과 폴더 자체에 같은 파일을 저장한다.

사전 거래 자료는 Stage 0의 `priming/`, 다른 Run의 `warmup/priming/`에 독립 저장한다.
같은 형식의 config/HTTP/raw/DB/timeline/Prometheus/Hikari 경계/result와 cleanup 완료 증거를 남긴다.
priming 한 건은 warmup·본 측정의 시작/접수/DB 건수와 지연 통계에 합산하지 않는다.
priming의 k6-summary/phases/timeline에서 첫 HTTP 지연·실행 시간·확정 시간을 확인하고,
기존 두 번째 실행과 새 warmup의 Hikari timeout, Payment 500/timeout, 실제 시작 대비 확정 수를 비교한다.
priming부터 warmup 및 본 측정까지 컨테이너 교체/재시작을 금지한다. 준비 과정의 시간도 비용으로 보고한다.

Embedded warmup PASS 후 sale 한정 FK 순서 삭제 → goods:perf:* Redis 정리 → 측정 fixture 생성 순서다.
Catalog publisher의 shared transaction advisory lock과 cleanup의 exclusive lock(74190321)이 이전 projection 완료를 기다려 재발행 race를 막는다.
Cleanup은 perf DB·단일 warmup sale과 실제 시작 수만큼의 전체 주문·CONFIRMED·성공 결제 시도를 검사한다. reset-db/Compose 재기동은 사용하지 않는다.
Measured before-db/observer/Prometheus window는 정리 후 시작하며 warmup 누적 counter는 delta로 분리한다.
Warmup/본 측정 k6 이름은 각각 goods-target-warmup-k6 / goods-target-k6이며 실패/중단 시 해당 child와 observer를 정리한다.

### Mock PG response delay

Prepare/Check/Run에 `-MockPgDelayMs`(기본 0, 0~5000ms)를 동일하게 지정한다.
CLI → Target Compose MOCK_PG_DELAY_MS → application-mockpg.yml → MockPaymentController로 전달하고 config.json에 기록한다.
실행 중 env와 요청 값이 다르면 거절한다. delay 변경 시 Prepare로 반영한 뒤 Check/Run에도 같은 값을 준다.
Delay는 store.accept의 durable receipt commit 이후, 응답/LOST_RESPONSE 이전에 적용하며 DB 트랜잭션 밖이다.
200ms 실험도 concurrency/pool/timeout/lease/자원 값은 그대로다. 2초 provider timeout보다 긴 delay는 응답 timeout과 재확인을 유발할 수 있다.

## 2. 단계별 입력과 범위

| 단계 / 실행 파일 | 공급 방법 | 분리하는 것 / 한계 |
|---|---|---|
| warmup / `k6/target/warmup.js` | 계획 270명(도착 허용 270~274회)·stock 400·4단계 저부하 | cold-start부터 실제 hot path를 검증하는 Stage 0. capacity SLO 아님 |
| worker / `k6/target/worker.js` | SQL로 미결제 HELD 주문을 준비하고 Payment API에 `Rps`건/초 접수 | READY·구매 gate를 경유하지 않는 기존 주문. Worker+DB+Mock PG와 Payment 접수 경로의 용량. API 공급 자체가 막히면 Worker 단독 한계라고 해석하지 않음 |
| waiting / `k6/target/waiting.js` | 초당 `Rps`명의 새 브라우저가 join 후 Retry-After+jitter로 poll | 구매/결제 없음. READY는 미사용 만료. `abandon`이면 절반이 join 직후 이탈 |
| reservation / `k6/target/reservation.js` | 새 브라우저 → 실제 Waiting READY → 명시적 purchase | 충분한 재고, 결제 없음. 대기 시간을 purchase HTTP 지연과 분리. READY 공급 부족이면 DB 포화점으로 해석하지 않음 |
| isolation / `k6/target/isolation.js` | Waiting 브라우저 `Rps`명/초와 별도 HELD 주문 결제 `PaymentRps`건/초 동시 실행 | Waiting 폭주 중 기존 결제의 런타임 격리. 기동 의존성/Reservation 장애 독립성의 시험은 아님 |
| business / `k6/target/business.js` | Users의 60%/30%/10%를 5초/10초/45초에 유입 | 기본 50,000명·1,000개. 실제 READY/hold/payment 및 선택한 사용자 행동 |

`Rps`는 Waiting/Reservation/Isolation에서 **새 브라우저 도착률**이다. HTTP RPS가 아니다.
join, poll, purchase, payment를 각각 집계한다. Worker에서만 결제 접수 시도 도착률이다.
생성기는 Compose 네트워크에서 두 Nginx의 80번 포트로 연결한다. 호스트 공개 포트의 NAT 비용은 이 측정에 포함하지 않는다.
Waiting의 READY 수는 클라이언트가 관측한 서로 다른 ticket 수이며 응답 유실로 미관측된 서버 발급은 포함하지 않는다.
서버 admission limited metric과 purchase 응답 429를 함께 읽는다.

Worker/Isolation fixture는 별도 판매에 주문·항목·ACTIVE 점유·held 수량을 한 DB 트랜잭션으로 만든다.
각 hold는 생성부터 **300초**, 결제는 실제 API에서 접수되어 +70초 PG 창을 얻는다. 작업/결제 원장을 Redis에 쓰지 않는다.
이 fixture는 구매 계약의 검증 증거가 아니다. 측정 직전 생성하며 공급 기간은 1~180초로 제한한다.
단일 5분 Worker 측정은 현재 fixture로 지원하지 않는다. 300초 hold를 늘리거나 미래 생성 시각을 위조하지 않는다.
긴 지속 시험이 필요하면 주문을 시간에 맞춰 보충하는 별도 fixture 준비가 먼저 필요하다.

`DurationSeconds`는 component의 **공급 기간**이며 전체 실행 시간은 아니다. 브라우저는 최대 180초 대기하고
Business의 late-payment/abandon은 실제 300초 경계를 지난다. k6 gracefulStop은 최대 420초다. 이후 기본 30초 drain 뒤 SUCCESS pending이 남으면 실제 DB deadline까지 관측한다.
원래 대기 브라우저가 300초까지 살아 있다고 가정하지 않는다. abandon은 **300초부터 새로운 반환 수요 Stock명**을 60초에 걸쳐 보낸다.

```powershell
# 최초 Prepare 후 각각 선택 실행. 매 명령은 perf를 초기화하며 자동 연속 실행 예제가 아니다.
pwsh -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario waiting -Rps 100 -DurationSeconds 60 -Vus 200 -MaxVus 20000
pwsh -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario waiting -Variant abandon -Rps 100 -DurationSeconds 60 -Vus 200 -MaxVus 20000

# Reservation: 실제 READY 공급과 safety ceiling을 같은 설정으로 준비/확인한다.
pwsh -File ./ops/performance.ps1 -Mode target -Action Prepare -WaitingRate 100 -ReservationRate 100
pwsh -File ./ops/performance.ps1 -Mode target -Action Check -WaitingRate 100 -ReservationRate 100
pwsh -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario reservation -Rps 40 -Stock 3000 -WaitingRate 100 -ReservationRate 100

# 기본 25/25/8로 다시 Prepare한 뒤 각각 선택 실행
pwsh -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario isolation -Rps 100 -PaymentRps 40 -Vus 200 -MaxVus 20000
pwsh -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario business -Variant normal -Users 50000 -Stock 1000 -Vus 1000 -MaxVus 50000
```

100/40 등은 **입력 예시**이며 안전/달성 용량이 아니다. 기본 MaxVus=2,000은 5만 명 재현을 보장하지 않는다.
Business 세 도착 구간은 VU pool을 각각 갖고 대기 시간이 겹친다. Isolation도 두 pool이다.
생성기는 1.5 CPU/1GiB로 제한한다. 높은 MaxVus를 적었다고 그 메모리에 모두 들어가는 것은 아니다.
목표 유입 전에 작은 Users(10의 배수, 최대 50,000)로 생성기·수집을 확인하고, 누락/OOM이면 서버 한계와 구분한다.
축소 시험 결과는 목표 부하 통과로 기록하지 않는다. cold/warmup/reset/delay 조건을 실행 기록에 명시하고 비교에서 맞춘다.
성능 SLO는 resource budget과 함께만 의미가 있다. 현재 local quota/pool/rate/concurrency는 측정 전 초기 hypothesis이며 그대로 유지한다.
Local 결과는 harness integration, obvious bottleneck, logic/rate/pool mismatch와 수정 필요 여부 판단에 사용한다.
최종 portfolio claim은 generator/server 분리, fixed/declared resource envelope, 동일 workload, 대표 조건 반복 실행으로 검증한다.
AWS instance type이나 최종 resource 숫자는 아직 정하지 않는다.

### 생성기 주문 데이터 공유

작은 판매 정보는 `fixture.json`, Worker/Isolation의 주문 목록은 `orders.json`으로 분리한다.
`common.js`는 init 단계의 `SharedArray` 안에서 주문 JSON을 읽고 파싱한다. 전체 목록은 k6 프로세스당 한 번 저장하고,
각 VU는 자기 iteration에 필요한 주문 하나만 읽는다. 전체 목록을 VU마다 복사하거나 setup 결과로 전달하지 않는다.
주문 선택 인덱스·사용자·멱등키·실제 결제 접수 경로는 동일하다. 나머지 시나리오는 빈 주문 배열을 사용한다.
이는 읽기 전용 fixture 공유이며 Redis/PostgreSQL 책임 분리나 동시 사용자 수를 바꾸지 않는다.
실제 메모리 절감량과 최대 VU는 아직 측정하지 않았다. [k6 SharedArray](https://grafana.com/docs/k6/latest/javascript-api/k6-data/sharedarray/)를 참고한다.

## 3. Business variant

| Variant | 행동 | 판정에서 구분할 것 |
|---|---|---|
| normal | 점유 후 시드 고정 1~45초 생각 시간 → SUCCESS 결제 | sale start +60초 내 초기 stock 1,000개 HELD, +120초 내 950/1000 CONFIRMED, 정상 오류·결제 SLO |
| burst | 점유 주문의 결제를 측정 시작+60초까지 모았다가 접수 | durable acceptance 유지, backlog/oldest age와 confirmation budget, accepted SUCCESS의 deadline 전 처리. 125/s는 stress input일 뿐 고정 요구가 아님 |
| late-payment | holdExpiresAt 약 1초 전 결제 시도 | 네트워크/락 때문에 기한 뒤 DB 접수가 되면 HOLD_EXPIRED 가능. 접수된 결제와 만료 반환 경쟁을 timeline/상태로 확인 |
| abandon | 점유자의 시드 고정 약 20%가 결제하지 않음. +300초 신규 반환 수요 | 실제 만료·반환·재구매. 최초 대기 180초와 hold 300초를 혼동하지 않음 |
| retry | 일시적 0/429/503은 최대 5회 backoff+jitter. 성공 구매도 같은 키로 1회 재전송 | 같은 주문 ID와 DB 주문 수 유지. 재시도는 최초 사용자 수와 별도 집계 |
| pg-failure | 시드 고정 SUCCESS 60%, UNKNOWN/FAILURE/LOST_RESPONSE/DELAYED_SUCCESS 각 10% | Mock PG 행동 주입. 영구 UNKNOWN 재고 보유·중복 확정 없음. 정상 950개/120초 판정을 적용하지 않음 |

각 분포는 기대 비율이며 적은 실제 점유 수에서는 정확히 일치하지 않는다. seed 기본값은 20260911이다.
대표 normal은 50,000명/stock 1,000개/인당 최대 1개, 0~5초 30,000명·5~15초 15,000명·15~60초 5,000명이다.
Waiting 등록 최대 180초, READY TTL 10초, hold 300초, acceptance 이후 Mock confirmation window 70초를 유지한다.
50,000명 모두가 60초 안에 구매 결과를 받거나 1초 안에 READY를 받는 계약이 아니다.
Stress/failure variant 및 후속 PG delay 실험에는 normal latency SLO를 일률 적용하지 않는다.
Burst/PG delay는 durable acceptance, backlog, oldest pending age의 confirmation budget 침범, accepted SUCCESS의 deadline과 정합성을 본다.
1,000건 burst를 1초 안에 PG confirmation하는 계약은 없다. retry/LOST_RESPONSE/UNKNOWN/FAILURE는
idempotency, duplicate prevention, durable state, recovery/reconciliation이 primary 계약이다.
PG 컨테이너 중지/네트워크 단절/프로세스 kill은 수행하지 않는다. 이는 별도 장애 시험이며 이 variant의 증거로 대체하지 않는다.
결제 실패 후 새 시도, 악의적인 backoff 무시, 강한 startup fault isolation은 이 harness의 범위 밖이다.

## 4. 수집 지표와 판정

다음 표는 새 계약에 맞춘 자동 검사다. 실제 실패 실행은 보존하지만 새 warmup/steady-state 계약의 통과는 미검증이며 capacity는 자동 PASS로 선언하지 않는다.
역할별 계약의 기준은 [Target v1 SLO](../architecture/target-v1.md#성능-계약과-측정-조건)다. Primary latency는 variant=normal 및 MockPgDelayMs=0일 때만 적용한다.

| 단계 | 주요 지표 | 자동 검사 (normal/delay 0 latency) | 확정한 SLO / 추가 판정 |
|---|---|---|---|
| 공통 | HTTP endpoint/status별 수·p95/p99, 예상 밖 오류, 누락, 재고/주문, 자원·Hikari | dropped=0, normal/delay 0의 예상 밖 오류 ≤0.1%, 공급/완료 iteration 수, 불변식 0, restart/OOM 없음, Hikari timeout 증가 없음, 수집 완전성 | 거절률과 성공 수를 함께 보고 생성기 제한·관측 비용·표본 공백 확인 |
| Worker | confirmed/s, accepted/s, 처리 시도/s, pending count, active slots, PG/job time, backlog slope/oldest pending age, Worker/Mock PG/PostgreSQL CPU, Hikari | 202 accepted-only p95≤1초, 접수 전부 확정·pending=0 | accepted SUCCESS마다 confirmationDeadline 전에 terminal/CONFIRMED, drain 후 pending=0. 공급 종료 후 backlog가 계속 증가하거나 회복하지 못하면 실패. oldest age와 deadline 관계 관측. 동일 조건 3회, drain만으로 지속 용량 인증 금지 |
| Waiting | join/poll 각각 RPS·p95/p99·429/503, Redis INFO commandstats/latencystats·CPU·memory, queue/live/stale/READY, JVM/Nginx CPU, DB 활동 | join/poll tagged p99≤1초·unexpected=0, 주문/결제 생성 0, Waiting DB 연결 0 | steady-state 정상 join/poll 개별 HTTP p99≤1초, dropped=0, 정상 Business의 unexpected 5xx/timeout/503=0. 429는 admission/backpressure로 별도 보고. WAITING→READY 전체 시간에 1초 SLO 없음 |
| Reservation | 관측 READY/s → purchase 진입/s → 성공/s, gate limited, purchase 성공·거절 지연, lock/Hikari | 성공 purchase p99≤1초, HTTP/DB 주문 수 대조 | 실제 READY 후 성공 201 accepted latency p99≤1초, stock correctness/Hikari timeout/restart/OOM=0. 25/s·25/s·permit 8은 초기 보호 정책, SLO 아님 |
| Isolation | 동일 Payment/Worker 지표 + Waiting 유입, 공유 DB·CPU·Hikari | 202 accepted-only p95≤1초, 접수 전부 확정 | 동일 payment workload에 Waiting 추가 후 성공 202 p95≤1초, Hikari timeout/unexpected 5xx/timeout=0, SUCCESS deadline 및 correctness 유지. Worker-only 대비 latency/backlog degradation 기록, 임의의 상대 한도 없음 |
| Business | 사용자 단계별 결과, DB 확정 시계열, 반환/재구매 및 최초 PG 지연 | normal/delay 0만 saleStart +60초 초기 점유·+120초 95% 확정 및 201 p99/202 p95≤1초; 공통 정합성·SUCCESS deadline | normal sale start +60초 내 초기 stock 1,000개 HELD, +120초 내 ≥95% CONFIRMED. 성공 201 p99/202 p95≤1초, SUCCESS별 deadline, correctness/Hikari timeout/restart/OOM/dropped=0, 예상 밖 오류≤0.1%. 대표 조건 3회 |

모든 normal/retry/failure에서 oversell/inventory invariant/per-user limit/invalid·partial hold/중복 성공 결제·확정 위반은 0이다.
동일 사용자·키·본문 retry는 중복 주문/attempt를 만들지 않는다. Waiting은 durable order/payment를 만들지 않고 DB connection=0이며,
READY는 재고 점유가 아니다. Redis는 재고·주문·결제 원장이 아니다. accepted payment 주문의 재고는 시간만으로 반환하지 않으며,
UNKNOWN/LOST_RESPONSE는 같은 attempt로 복구·재확인한다.
Waiting의 성공은 DB 연결 증가 없는 유입 흡수, READY를 통한 downstream 제어, durable order/payment 생성의 유입 비례 증가 방지다.
Business 전체 오류≤0.1%가 Waiting 및 normal/isolation Payment의 오류 0 계약을 완화하지 않는다.

Payment API 책임은 durable acceptance다. 성공 202 accepted-only p95≤1초를 측정해야 하며 normal/isolation에서
Hikari timeout/unexpected 5xx/client timeout=0, accepted payment의 durable DB state를 확인한다. PG 완료까지 HTTP를 붙잡지 않는다.
`target_payment_accepted_ms`는 실제 202 attempt만 기록하며 혼합 `target_payment_ms`는 진단용이다.
Waiting은 기존 target_latency/target_unexpected endpoint submetric으로 판정한다. 429 분류는 그대로다.
Review의 legacy 32/s required·40/s normal target을 제거했다. 40/s·125/s는 capacity/stress input이다.
Business sale은 가까운 미래 opensAt으로 생성하고 projection 확인 후 k6 setup이 opensAt까지 기다린다.
실제 opensAt을 TARGET_SALE_START와 phases.saleStart에 보존하고 60/120초는 saleStart 기준으로 판정한다.
measurementStart와 차이는 result.saleAlignmentSeconds에 별도 기록한다. 큰 지연은 harness alignment로 검토한다.
Scaled Business는 flow/harness validation이며 50,000/1,000 SLO 통과로 선언하지 않는다.

`goods.worker.completed`는 UNKNOWN 재확인도 포함하는 **작업 처리 시도** 카운터다.
실제 성공 처리량은 DB confirmed 증가 및 `goods.payment.results{result="SUCCEEDED"}`와 대조한다.
`goods.worker.job`은 한 처리 시도의 시간이다. 접수→최초 PG는 timeline의 first_pg_delay_seconds,
접수→terminal은 V3 payment_attempts.terminal_at과 reservation.confirmation_deadline으로 비교한다.
첫 SUCCEEDED/FAILED 전이에서만 기록하며 UNKNOWN은 null, terminal replay는 기존 시각을 유지한다. 이전 terminal 행은 소급 보정하지 않는다.
PG 접수+70초는 기존 Mock 최초 호출 허용 정책이다. 새 SUCCESS SLO는 같은 confirmationDeadline 전에 최종 terminal/CONFIRMED까지 요구한다.
최초 PG 호출만 기한 내였거나 drain 후 최종 확정됐다는 사실만으로 deadline SLO를 인증하지 않는다.
SQL은 SUCCESS accepted/confirmed/pending, oldest pending age, 관련 deadline 및 successDeadlineViolations를 수집한다.
terminal_at > deadline 또는 deadline이 지난 nonterminal을 위반으로 세며 기한 전 pending은 위반이 아니다.
기본 30초 drain 뒤 pending이 남으면 observer를 유지해 실제 deadline까지 bounded wait한다. 모두 terminal이면 종료하고,
phases의 loadFinished/drainEnd/drainReason(all_success_terminal/deadline_reached/no_payment_work)을 남긴다.
Terminal timestamp는 같은 확정 트랜잭션의 application 전이 시각이며 별도의 DB commit timestamp는 아니다. 반환 5초 event 계측은 여전히 미구현이다.

## 5. 반환 시간 정책

반환 대기(`WAITING_FOR_INVENTORY_RETURN`) polling을 기존 12초에서 **1초**로 맞췄다.
가까운 일반 WAITING은 1초, 먼 일반 WAITING은 기존 12초를 유지한다. 클라이언트는 양의 jitter 0~250ms를 더한다.
FULLY_HELD의 polling 빈도는 증가하므로 Redis/Waiting 부하도 함께 측정해야 한다.
명목 예산은 만료 스캔 약1초 + projection 주기 약1초 + 반환 polling 최대1.25초 + 구매 응답1초 = 약4.25초다.
fixed-delay 작업 시간·DB 대기·실패가 더해지므로 이 합은 **5초 달성의 증거가 아니다**.

5초 목표는 **secondary/stretch timing target**이며 primary SLO가 아니다.
재고가 반환 가능한 시각(미결제 holdExpiresAt)부터 활성 구매 후보의 새 HELD commit까지를 대상으로 한다.
모든 대기 사용자에게 5초 안에 READY를 보장하지 않는다. 먼 순위/180초 만료/부재 사용자는 별도로 집계한다.
PG UNKNOWN은 반환 가능 상태가 아니므로 이 기준에 넣지 않는다.
abandon 실행에서는 초기 FULLY_HELD를 확인하고 timeline의 만료 시각, 재구매 주문 생성 시각,
Redis catalog와 poll 응답 시간을 대조한다. 재고가 원래 남아 있었거나 대응이 불명확하면 판정 보류한다.
인증에는 `holdExpiresAt → 실제 release commit → catalog AVAILABLE projection → READY 발급 → purchase → 새 HELD commit`의
정확한 event timestamp가 필요하다. 현재 coarse observer sample만으로 ≤5초 달성을 확정하지 않는다. 계측 추가는 후속 구현이다.

## 6. 결과 파일과 재검토

결과는 `artifacts/performance/<timestamp>-target-<stage>-<variant>/`에 저장된다.

| 파일 | 내용 |
|---|---|
| config.json / compose.yaml / commit.txt / working-tree.patch / git-status.txt / jar-hash.json / scripts | 입력·실제 설정·소스 snapshot. 미추적 파일은 diff에 없으므로 scripts와 복사된 target 스크립트도 보존 |
| fixture.json / orders.json | 실행 판매 / 기존 HELD 주문 ID·사용자 목록. 로컬 결과에 보존하며 Git 제외 |
| pre-reset-db.json / pre-reset-timeline.json | Run -Reset에서 초기화 전 보존한 이전 DB 상태. 이번 실험의 측정 자료와 구분 |
| phases.json | 관측 시작, k6 setup 시각, 공급 종료, 전체 브라우저 종료, drain 종료. 공급 구간과 grace/drain을 분리 |
| k6.log / k6-exit.txt / k6-summary.json / raw.json | 실행 로그·threshold 결과·요청 및 사용자 지표. raw의 endpoint/status 태그로 성공/거절 p95/p99·초당 유입 계산 |
| db-samples.jsonl / before-db.json / after-db.json | confirmed/pending/oldest age·락 waiter·DB 활동·판매별 재고·정합성 |
| timeline.json | 주문 생성/점유 만료/결제 접수/최초 PG 시각·결과와 terminal_at/confirmation_deadline. terminal_at은 결과 반영 트랜잭션 안에서 기록하며 DB commit timestamp 자체는 아님 |
| redis-samples.jsonl / redis-slowlog.txt | INFO, queue/READY/live/stale 수, catalog 값, slowlog. 응답 손실·정리 제한과 자원 비용 해석 |
| resources.jsonl / generator-resources.jsonl / before-containers.json / after-containers.json | 서비스/생성기 CPU·memory·network, 컨테이너 ID·재시작·OOM |
| prometheus.json | Waiting 2개·Reservation·Payment·Worker·Mock PG의 HTTP/JVM/process/Hikari/Worker histogram 시계열 |
| boundary-before.json / boundary-after.json | 각 trial의 k6 직전 / bounded drain 이후 Hikari instant snapshot. 네 DB 역할의 instance+pool별 delta=0, 경계 이후 scrape·누락·불일치·counter 감소 검사 |
| observer.log / observer-error.txt / collection-errors.txt / error.txt / services.log | 관측기·실행·서비스 오류. 최초 오류와 후속 수집 오류를 함께 보존 |
| result.json | 실패는 **failed**, warmup 자동 검증 통과는 **passed**, 다른 시나리오는 **requires_review**. capacity 합격은 별도 수동 판정 |

Prometheus scrape/query step은 1초다. 별도 표본 수집은 component에서 작업 완료 후 5초,
Business/Warmup에서 1초 쉬므로 **실제 간격은 Docker/SQL 명령 시간만큼 더 길다**. 각 파일의 실제 timestamp를 사용한다.
관측 SQL은 perf 연결 하나씩을 쓰고 집계를 실행하며 Redis 관측 EVAL도 commandstats에 포함된다.
관측 비용을 제외한 순수 제품 CPU라고 주장하지 않는다. 동등 비교에서는 설정을 고정한다.
Redis INFO latency는 누적 지표이고 slowlog에 항목이 없다는 것이 지연 0을 뜻하지 않는다.
생성기가 매우 짧게 실행되어 자원 표본이 없다면 해당 실행의 생성기 용량 판정은 보류한다.
DB 표본은 SQL 결과 전체를 JSON으로 검증한 뒤 한 줄로 직렬화한다. 여러 재고 행이 있는 경우에도 JSONL 한 줄은 표본 하나다.
HTTP에서 관측한 202 건수와 DB 확정 건수의 불일치는 응답 유실 가능성과 함께 확인한다.
DB 확정 건수가 더 많다는 이유만으로 Worker 미처리라고 해석하지 않으며, 자동 건수 대조 실패는 유지한다.
첫 Worker 실행의 JSONL 수정 및 실제 초기 요청 실패 분석은 [실행 분석](../../artifacts/target-v1/20260911-worker-diagnosis/review.md)을 참고한다.

```powershell
# 저장한 결과만 다시 판정. Docker/HTTP/k6 호출 없음.
pwsh -File ./ops/performance/target-review.ps1 -Directory ./artifacts/performance/<실행폴더>
```

대표 조건을 3회 각각 실행하여 결과를 합치지 않고 남긴다. 먼저 Worker, Waiting, Reservation을 측정하고
그 결과로 Isolation의 입력을 정한 뒤 Business로 간다. 실제로 확인한 병목만 수정한다.
아직 Target의 최대 용량·50,000명 Business SLO·결제 성능 격리·실제 300초 반환을 달성했다고 기록하지 않는다.

## 7. 부하 없는 스크립트 회귀 검사

아래 검사는 Git Bash 또는 PowerShell에서 실행할 수 있다. 실제 Docker/HTTP/k6, DB 초기화, 실제 대기는 수행하지 않는다.

```bash
pwsh -NoProfile -File ./ops/performance/target-command-test.ps1
pwsh -NoProfile -File ./ops/performance/target-lifecycle-test.ps1
pwsh -NoProfile -File ./ops/performance/target-review-test.ps1
pwsh -NoProfile -File ./ops/performance/target-hikari-test.ps1
pwsh -NoProfile -File ./ops/performance/target-warmup-test.ps1
node --experimental-vm-modules ./ops/performance/target-static-test.mjs
```

- command: Docker 함수 이름 충돌, Check 호출/인자 전달, 작업 디렉터리·환경 복원, 실패 시 중단을 모의 검사한다.
- lifecycle: 임시 workspace에서 Docker/HTTP/Git과 빌드를 대체해 단일 기동·무빌드 재실행·상태 보존·초기화 순서·실패 차단·수집 잠금을 검사한다. 실제 부하 진입 전 멈춘다.
- review: 실제 도착 수 전체의 완료·영속 상태 대조, 시나리오별 경계 추가 허용, 누락·과다 도착·threshold 실패·Hikari delta·증거 누락을 검사한다.
- hikari: fresh instant snapshot, bounded retry, baseline 실패 시 load 차단과 warmup/measurement 독립 경계를 검사한다.
- warmup: 실제 시작 수 기준 cleanup guard, 실패 warmup의 측정 진입 차단 및 bounded drain을 검사한다.
- static: k6 모듈·HTTP·시계·sleep을 대체해 각 시나리오와 재시도·입장권·300초 시간 계약, 두 VU 문맥의 주문 파일 단일 로드·주문 선택을 검사한다.

관측 작업의 실제 PowerShell 프로세스 경계는 아래 검사로 확인한다. Docker는 자식 프로세스에서도 모의 처리하며,
한 표본 후 즉시 종료한다. HTTP·k6·DB 접근·실제 sleep은 없다.

```bash
pwsh -NoProfile -File ./ops/performance/target-observer-test.ps1
```

다른 작업 디렉터리, 공백·한글이 있는 스크립트/결과 경로, 컨테이너 ID 배열, 단계별 관측 간격,
SQL 파일 누락·Docker 실패 시 readiness 미발행과 오류 파일 보존을 검사한다.

PowerShell은 대소문자를 구분하지 않으므로 native `docker`의 래퍼 함수를 `Docker`라고 이름 붙이면 재귀 호출된다.
`target.ps1`은 `Invoke-Docker`를 사용한다. 이 회귀 검사의 통과는 실제 부하/컨테이너 실행 검증을 대신하지 않는다.

### Observer startup failed / target-state.sql 경로 오류

`20260911-232830-531-target-worker-normal`은 관측 준비 중 `D:\target-state.sql`을 찾다가 중단됐다.
`Start-Job -FilePath`에서 스크립트 파일 문맥이 유지되지 않아 `$PSScriptRoot`가 비어 생긴 오류이며 Git Bash의 경로 변환 문제가 아니다.
자식 작업 안에서 관측 스크립트를 절대경로로 호출하도록 수정했다. 결과 경로·DB/Redis ID·컨테이너 배열·간격은 이름 있는 인자로 전달한다.
SQL과 fixture는 관측 시작 시 한 번 읽으며, 필요한 파일이 없으면 readiness를 발행하기 전에 오류를 기록한다.

이 실패는 fixture 준비 이후, k6 시작 이전에 발생했으므로 Worker 성능 실패로 해석하지 않는다.
기존 오류 폴더를 보존하고, 역할들이 준비된 상태라면 같은 Worker 명령에 `-Reset`을 붙여 다시 실행한다.
PowerShell 수정만 적용하므로 이미지 재빌드는 필요 없다. 서비스가 중단되었거나 사전 검사에 실패한다면 먼저 Prepare로 복구한다.
