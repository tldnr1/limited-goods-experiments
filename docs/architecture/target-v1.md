# Target v1 — 기능 계약과 검증 범위

기능 결과: [2026-09-10 기능 검증](../../artifacts/target-v1/20260910-functional/review.md).
최신 부하 결과: [2026-09-13 사전 거래 추가 후 Warmup 통과](../reviews/warmup-20260913-review.md). 다음은 Worker 측정이며 steady-state 성능 검증은 대기 중이다.

대량 유입을 Waiting/READY에서 흡수해 PostgreSQL 재고 경로의 진입률을 통제하고,
재고 점유는 PostgreSQL 원장으로 정확하게 보장하며, 결제는 durable acceptance 이후 Worker가 비동기로 처리하여
외부 PG 지연이나 순간 폭주가 구매/결제 접수 경로 전체로 전파되지 않도록 한다.
아래는 확정한 Target v1 SLO와 측정 계약이며 **성능 달성은 미검증**이다. 기존 archive/baseline 수치를 새 구현의 성능으로 인용하지 않는다.

## 성능 계약과 측정 조건

Primary performance SLO는 **warmup 이후 steady-state**와 선언한 resource budget을 전제로 한다.
Target `Run -Reset`은 재기동 후 단계형 warmup을 검증하고 데이터를 정리한 뒤 같은 JVM에서 본 측정을 시작한다. 이전 자동 warmup 없는 결과는 steady-state SLO 증거로 사용하지 않는다.
Cold-start 결과는 deployment/startup characteristic으로 보존하고 steady-state capacity와 별도로 기록한다.
DB/OS 캐시는 남을 수 있으므로 완전히 cold한 환경이라는 뜻은 아니다. 동일 비교 시험은 동일한 warmup/reset 조건을 사용한다.
단계형 warmup/독립 Validation, 202 accepted-only metric, terminal timestamp/deadline evidence, configurable Mock PG delay를 구현했다. 사전 거래를 추가한 warmup은 1회 PASS했으며 steady-state 성능 달성은 미검증이다.

### 대표 workload와 hard correctness

Business normal은 관심 사용자 50,000명 / 초기 stock 1,000개 / 사용자당 최대 1개다.
도착은 0~5초 30,000명, 5~15초 15,000명, 15~60초 5,000명이며, HELD 후 기존 seed 기반 1~45초 think time 뒤 SUCCESS 결제를 시도한다.
Hold 300초, Waiting registration max 180초, READY TTL 10초, 현재 Mock confirmation window는 acceptedAt + 70초를 유지한다.
50,000명/1,000개는 workload이며 모든 사용자의 구매 결과나 WAITING→READY를 1초 안에 완료하는 약속이 아니다. 대기는 정상 동작이다.

모든 normal/retry/failure 실험에서 성능보다 다음 불변식을 우선한다.

- oversell, inventory invariant violation, per-user limit violation, invalid/partial hold 모두 0.
- duplicate successful payment / duplicate confirmation 모두 0. 동일 사용자·멱등키·본문 retry는 중복 주문이나 중복 payment attempt를 만들지 않는다.
- Waiting path는 durable order/payment를 만들지 않고 Waiting role의 DB connection은 0이다.
- READY 자체는 stock reservation이 아니며 Redis는 inventory/order/payment authoritative store가 아니다.
- accepted payment가 존재하는 주문은 단순 시간 경과만으로 재고를 반환하지 않는다. 확정된 실패에 따른 상태 전이는 기존 계약을 따른다.
- UNKNOWN / LOST_RESPONSE는 같은 attempt를 복구·재확인하며 새 성공을 중복 생성하지 않는다.

### 역할별 primary SLO

| 경로 | 대표 steady-state normal 계약 |
|---|---|
| Waiting | 정상 join/poll **개별 HTTP 응답** 각각 p99 ≤ 1초, dropped iteration=0. 정상 Business에서 예상 밖 5xx/timeout/503=0. 명시적 admission/backpressure 429는 시스템 오류와 분리 |
| Reservation | 실제 READY 수신 후 purchase 요청의 성공 **201 accepted latency p99 ≤ 1초**. stock correctness 위반/Hikari connection timeout/process restart/OOM 모두 0 |
| Payment acceptance | 성공 **202 accepted-only latency p95 ≤ 1초**. normal/isolation에서 Hikari timeout 및 unexpected 5xx/client timeout=0. 접수된 payment는 durable DB state로 남음 |
| Payment confirmation / Worker | durable accepted SUCCESS payment마다 자신의 confirmationDeadline(현재 Mock: acceptedAt + 70초) **전에 terminal 처리**, 정상 SUCCESS는 CONFIRMED. drain 이후 성공 시나리오 pending payment=0 |

Waiting의 WAITING→READY 전체 시간에는 1초 SLO가 없다. 순서·READY rate·재고 상태에 따른 대기를 허용한다.
Waiting 성공은 PostgreSQL 연결 증가 없이 Redis/Waiting tier에서 유입을 흡수하고 READY 발급률로 downstream 진입량을 제어하며,
Waiting traffic 증가가 durable DB order/payment 생성에 비례 전파되지 않는 것이다.
Waiting READY rate / Reservation rate / permit의 현재 25/s / 25/s / 8은 용량 보호 policy knob의 측정 전 초기값이며 SLO가 아니다.

Payment API는 durable acceptance를 책임진다. `target_payment_accepted_ms`는 실제 202 attempt만 측정한다.
기존 `target_payment_ms`는 retry/실패가 섞인 진단 지표로 보존하며 PASS 기준에서 제외한다.
Mock PG 최초 호출 허용 창 자체는 기존 기능 정책이며, SUCCESS의 deadline 전 최종 처리 SLO는 그와 별도로 검증해야 한다.
기한을 놓친 결과를 나중에 복구해도 SLO 실패는 남고, UNKNOWN 보유·같은 attempt 재확인 등의 정합성 동작은 유지한다.

Worker의 primary contract는 고정 jobs/s가 아닌 backlog와 deadline이다. 공급 종료 후 backlog가 계속 증가하거나 회복하지 못하면 실패다.
oldest pending age를 confirmation deadline의 잔여 예산과 함께 관측한다. 기존 약 32 jobs/s 가정은 hard requirement에서 제거한다.
40/s, 125/s는 component capacity probe/stress input으로만 사용할 수 있고 서비스 PASS/FAIL SLO가 아니다.
관측 대상은 confirmed/s, accepted/s, backlog slope, pending count, oldest pending age, Worker active slots,
worker job time, PG call time, Worker/Mock PG/PostgreSQL CPU, Hikari다. drain 성공만으로 지속 용량을 인증하지 않는다.

### Business / Isolation / variant

Normal 50,000명 / stock 1,000개의 primary Business SLO는 다음과 같다.

- sale start + 60초 안에 **초기 stock 1,000개가 HELD**, sale start + 120초 안에 **stock의 95% 이상이 CONFIRMED**.
- correctness invariant 위반 모두 0, 성공 purchase 201 p99 ≤ 1초, 성공 payment 202 acceptance p95 ≤ 1초.
- normal SUCCESS로 accepted된 payment는 각각 confirmationDeadline 전에 처리.
- 정상 steady-state Hikari timeout/process restart/OOM/generator dropped iteration 모두 0, 예상 밖 오류 ≤ 0.1%.

60초는 초기 stock의 hold 완료 목표이며 50,000명 모두가 구매 결과를 받는 기한이 아니다.
전체 오류 ≤ 0.1%는 Waiting의 예상 밖 5xx/timeout/503=0 및 Payment normal/isolation 오류=0 계약을 완화하지 않는다.

Isolation은 동일 payment workload에 Waiting traffic을 추가해도 성공 202 acceptance p95 ≤ 1초,
Hikari timeout 및 unexpected 5xx/timeout=0, accepted SUCCESS의 deadline 내 처리와 correctness를 유지해야 한다.
Worker-only 대비 latency/backlog degradation은 기록하되 임의의 상대 성능 기준(예: 20%)을 두지 않는다.

Burst 및 후속 PG delay 실험에는 normal latency SLO를 일률 적용하지 않는다. durable acceptance 유지,
backlog 규모, oldest pending age의 confirmation budget 침범, accepted SUCCESS의 deadline 내 처리, correctness를 본다.
1,000건 burst의 1초 내 PG confirmation이나 125 jobs/s를 요구하지 않는다.
Retry / LOST_RESPONSE / UNKNOWN / FAILURE의 primary 계약은 idempotency, duplicate prevention, durable state,
올바른 recovery/reconciliation이다. 영구 UNKNOWN에 정상 SUCCESS의 CONFIRMED 목표를 적용하지 않는다.

반환 가능 시점부터 5초 내 재구매는 **secondary/stretch timing target**이다.
`holdExpiresAt → 실제 release commit → catalog AVAILABLE projection → READY 발급 → purchase → 새 HELD commit`의
정확한 event timestamp가 있어야 인증할 수 있다. 현재 coarse observer sample만으로 ≤5초 달성을 확정하지 않는다.

## 이번 구현

- 같은 JAR의 `waiting` / `reservation` / `payment` / `worker` profile. Waiting은 DataSource/JPA/Flyway가 없다.
- Redis는 WAITING/READY와 짧은 판매 상태 projection만 소유한다. PostgreSQL이 주문·점유·재고·결제 원장이다.
- 대기 등록만으로 점유하지 않는다. READY를 받은 클라이언트가 명시적으로 구매 POST를 전송한다.
- Worker는 기본 동시성 4를 유지하고 작업 완료 즉시 다음 DB 작업을 가져온다. 빈 큐만 250ms 대기한다.
- 현재 상품 행 락 모델과 인당 제한·다중 상품 원자성을 유지한다. 새 주문 응답 재조회 3개를 임계 구간에서 제거한다.
- MQ, 재고 단위 행 전환, 실제 PG, 브라우저 UI, 대규모 부하는 포함하지 않는다.

## 상태·시간 계약

| 항목 | v1 계약 / 초기값 |
|---|---|
| 판매 전 | 등록 거절. DB 판매 시각을 Redis에 투영해 검사하고 실제 구매에서도 DB 검사 |
| 대기 | WAITING → READY → 클라이언트가 점유 요청. 서버 자동 점유 없음 |
| 대기 기한 | 등록부터 최대 180초. 정상 polling이 30초 동안 없으면 대기 순서에서 제외 |
| READY | 발급부터 최대 10초, 전체 대기 기한을 넘지 않음. 조회로 연장하지 않음 |
| 초기 제한 | READY 발급 25/s, 미사용 READY 50개, 대기+READY 50,000개. 모두 정책/후속 측정 대상 |
| 점유 진입 | 별도 25/s 및 기존 전체 permit 8. 측정으로 조정할 초기 제한 |
| 재접수 | 만료 후 같은 사용자·멱등키·본문으로 다시 등록 가능. 활성 등록 중 다른 본문은 409 |
| 점유 | 생성 시점부터 300초. 실제 DB 락·커넥션은 트랜잭션 종료 시 반환 |
| 결제 접수 | 주문 락 획득 후 기한 검사. 정확히 만료 시각이면 거절. 기한 내 DB 접수 후에는 만료 작업이 반환하지 않음 |
| PG 최초 처리 창 | 접수+70초. Mock PG의 임시 정책이며 처리 지연 SLO나 실제 토스 계약이 아님 |
| UNKNOWN | 같은 시도로 재확인. 시간 경과만으로 재고를 반환하거나 새 결제를 허용하지 않음 |

READY는 재고 보장이나 엄격한 FIFO가 아니다. 접수 순서의 선두 후보 중 실제 조회하는 브라우저에게 발급한다.
입장권은 사용자·구매 멱등키·본문 fingerprint·기한에 서명한다. 기한이 지난 입장권도 서명/소유권이 맞고
이미 DB 주문이 있으면 그 주문을 반환한다. 없는 주문의 신규 생성은 거절한다.
재고 락 대기 중 READY가 만료되면 DB 변경 없이 거절한다. DB 성공 후 Redis 후처리 실패는 성공을 뒤집지 않는다.

Redis 유실 시 미점유 순서 복구는 보장하지 않는다. 기존 주문의 조회·결제는 Redis 없이 동작한다.
점유 직후 이탈한 사용자의 300초 보유는 정상적인 포기로 남는다. 이 구현은 늦은 서버 자동 점유를 제거한다.
모두 HELD인 경우 반환 대기이며 SOLD_OUT과 구분한다. 최대 180초 대기는 300초 반환을 보장하지 않는다.

## 역할·자원

`compose.yaml`은 기존 baseline, `compose.target.yml`은 Target 오버레이다. 같은 Compose 프로젝트/DB 볼륨을 사용한다.
동시에 실행하지 않는다. 별도 저장소나 데이터베이스로 분리하지 않는다.

| 역할 | 개수 | 각 CPU quota | 각 메모리 상한 | 각 DB pool |
|---|---:|---:|---:|---:|
| Waiting (api1/api2) | 2 | 0.375 | 384MiB | 없음 |
| Reservation | 1 | 0.5 | 512MiB | 4 |
| Payment | 1 | 0.25 | 384MiB | 4 |
| Worker | 1 | 0.5 | 512MiB | 4 |
| Mock PG | 1 | 0.25 | 384MiB | 2 |
| Public / Checkout Nginx | 2 | 0.125 | 64MiB | 없음 |
| PostgreSQL | 1 | 1.5 | 1536MiB | — |
| Redis | 1 | 0.25 | 256MiB | — |

총 4.25 CPU / 4,480MiB로 기존 총상한을 유지한 최초 배분이다. 물리 자원 전용 할당이나 처리량 보장이 아니다.
현재 local Target 배분은 측정을 위한 초기 hypothesis이며 CPU/memory/pool/rate/concurrency를 이번 작업에서 조정하지 않는다.
Local 결과는 harness integration, obvious bottleneck, logic/rate/pool mismatch와 수정 필요 여부를 확인하는 데 사용한다.
최종 portfolio 성능 claim은 load generator와 server를 분리하고 fixed/declared resource envelope에서 동일 workload의
대표 조건을 반복 실행한 결과로 검증한다. AWS instance type과 최종 resource 숫자는 아직 정하지 않는다.
Waiting HTTP/Redis와 Reservation/Payment의 Tomcat/Hikari가 분리되지만, DB·호스트·네트워크는 공유한다.
Compose 기동 시 Payment/Worker/Checkout Nginx는 Reservation readiness에 일부 의존한다.
따라서 실행 중 결제 보호와 Reservation 장애 중 독립 기동은 별도 검증이며, 현재 강한 장애 독립성을 주장하지 않는다.
대기 포트는 8080, 구매/결제 포트는 8082다. 모두 localhost 전용이다. X-User-Id와 기본 서명 비밀은 로컬 시험용이다.

## API와 실행

1. 8082 `POST /api/sales`: 기존 로컬 fixture 생성. Reservation의 주기적 projection이 Redis에 반영될 때까지 잠깐 503 가능.
2. 8080 `POST /api/admissions`: 기존 구매 본문, `X-User-Id`, `Idempotency-Key`. 202와 id 반환.
3. 8080 `GET /api/admissions/{id}`: 같은 사용자. READY 응답의 ticket을 보관한다.
4. 8082 `POST /api/purchases`: 같은 본문/멱등키와 `X-Admission-Ticket`. 응답 유실 시 같은 요청으로 재시도한다.
5. 8082 `POST /api/orders/{id}/payments`, `GET /api/orders/{id}`: 기존 결제/조회 계약.

조회 응답은 `Cache-Control: no-store`, `Retry-After`/retryAfter를 제공한다. 가까운 대기와 반환 대기는 1초, 먼 일반 대기는 12초다.
클라이언트는 이 최소 간격에 양의 jitter를 추가하고 완료 시 중단해야 한다. 브라우저 UI는 미구현이다.
대기 항목이 TTL로 사라지거나 유실되면 GET은 404다. 이를 주문 실패나 판매 완료로 해석하지 않고 재접수/기존 주문 확인으로 처리한다.
너무 이른 조회는 새 READY 발급 판단을 생략한다. 이는 HTTP ingress 자체의 rate limit을 대체하지 않는다.

```powershell
# 기본은 읽기 전용 상태 확인
./ops/target.ps1 -Action Check
./ops/target.ps1 -Action Start
./ops/target.ps1 -Action Smoke -RedisOutage
./ops/target.ps1 -Action Stop
```

Start는 JAR/image를 빌드하고 dev 역할 구성을 기동한다. 데이터 초기화/볼륨 삭제는 하지 않는다.
Smoke는 작은 dev 판매를 새로 만들며, RedisOutage를 지정하면 Redis를 잠시 중단 후 복구한다.
baseline perf 실행은 Target Stop 후 기존 `ops/performance.ps1`을 사용한다.
Target 전용은 같은 진입점의 `-Mode target`이며 [단계별 실행 가이드](../guides/target-v1-load-guide.md)를 따른다.
Warmup / Worker / Waiting / Reservation / Isolation / Business 파일을 분리했다. 과거 cold Worker 및 첫 Warmup 실행은 실패했고, 나머지 단계의 성능 검증은 대기 중이다.
부하 흐름 그림은 [Target v1 시나리오](target-v1-load-scenario.md)에 별도로 있다.

## 검증과 다음 단계

자동 테스트: 실제 limited_goods_test와 Redis에서 300초 경계, 늦은 결제·만료 경쟁, PG 응답 유실,
만료 입장권/Redis 장애 후 DB 재조회, READY 상한·소유권·미사용 만료·이탈 제외,
Waiting의 DB 없는 기동, Worker 연속 공급·동시성 상한을 확인한다.

남은 일: 새 warmup·계측·자동 판정의 실제 Docker+k6 통합 확인, 300초 실제 시간 보유 시험,
READY/Reservation 초기 25/s 정책 측정, Worker backlog·각 SUCCESS confirmation deadline 검증,
결제 집중 시 backlog·최초 PG 지연 검증, 5만 명 통합 부하,
앞단 폭주 중 결제 SLO, HTTP ingress 제한/브라우저 jitter, 신규 작업과 재확인 처리 예산의 세분화.
현재 catalog publisher는 전체 판매를 1초 주기로 한 번 조회한다. 이벤트 수가 커질 때는 활성 판매 범위/페이징을 도입해야 한다.
projection은 5초 TTL이며 장애 시 신규 대기는 503으로 닫힌다. 반영 지연과 조회 간격 때문에 UI의 반환 인지는 더 늦을 수 있다.
반환 polling은 secondary/stretch인 5초 재구매 목표를 고려해 1초로 조정했다. 명목 시간 예산과 실제 판정 한계는
[시간 정책](../guides/target-v1-load-guide.md#5-반환-시간-정책)을 따른다. 5초 달성이나 모든 대기자의 READY 획득을 보장한 것은 아니다.
현재 2초 Mock PG timeout과 10초 lease를 실제 PG에 그대로 적용하면 안 된다. 긴 호출의 lease 갱신·소유권 검증은 후속이다.
