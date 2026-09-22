# 성능 실험 기준

## 현재 Target v1 검증 방향

2026-09-13 변경: 정상 거래 한 건을 별도 priming으로 실행·확정·정리한 뒤 기존 2→5→10→10/s warmup을 수행한다.
CPU/pool/JIT는 유지하며 사전 실행 유무의 비교가 목적이다. 원본은 priming/에 분리하고,
완료/cleanup은 실제 시작 수와 영속 상태를 대조한다. [사전 거래 추가 후 실행](reviews/warmup-20260913-review.md)은
272/272건 확정, Payment Hikari timeout 0건으로 통과했다. 다음은 기존 Worker 10/s·120초 측정이다.
Git Bash 명령은 [Stage 0 실행 가이드](guides/target-v1-load-guide.md#stage-0과-embedded-warmup)를 따른다.

변경 전 `20260912-223508-886-target-warmup-normal`은 실제 시작 273건, 확정 262건, Payment Hikari timeout 13건으로 실패했다.
이전 [2026-09-12 첫 Warmup](reviews/warmup-20260912-review.md)은 실제 272회 도착·완료,
dropped=0이었으나 Payment Hikari timeout 18건과 결제 오류로 실패했다. 고정 270건 판정과 cleanup은
실제 시작 수 기준으로 수정했다. Warmup PASS 이후 steady-state 성능 검증은 대기 중이다.
도착 수는 각 constant-arrival-rate 시나리오의 추가 1회만 허용하고 실제 시작 수 전체의 영속 완료를 요구한다.
Hikari는 trial별 fresh boundary delta, process restart는 Prometheus window와 컨테이너 evidence로 검사한다.
전체 문서 구성은 [목차](README.md), 실행별 기록은 [분석 목록](reviews/README.md)을 따른다.

기능 구현·계약 검증 이후, **Warmup Validation → Worker → Waiting → Reservation → Isolation → Business** 순서로 측정한다.
[Target 실행 가이드](guides/target-v1-load-guide.md)에 각 단계의 독립 실행·수집 지표·자동/수동 판정이 있고,
[시나리오 아키텍처](architecture/target-v1-load-scenario.md)는 부하가 지나가는 역할을 시각화한다.
자동화 준비와 실패 재현은 성능 목표 달성과 구분한다. 실제 wall-clock 300초 시험은 아직 수행하지 않았다.
반복 실행은 `Prepare`(배포, 데이터 보존)와 `Run -Reset`(기존 이미지 재사용, perf 초기화 후 1회 측정)으로 구분한다.
Run은 준비 검사를 포함하며 별도 Check는 선택 사항이다. k6 주문 fixture는 SharedArray로 공유하되 실제 메모리 절감량은 미측정이다.

핵심은 Waiting/READY에서 대량 유입을 흡수해 PostgreSQL 재고 경로의 진입률을 통제하고,
PostgreSQL 원장으로 점유를 보장하며 durable acceptance 이후 Worker가 비동기 결제를 처리해 외부 PG 지연·폭주의 전파를 막는 것이다.
Worker의 primary 계약은 accepted SUCCESS별 confirmationDeadline(현재 Mock: acceptedAt + 70초) 전 terminal/CONFIRMED,
drain 후 성공 시나리오 pending=0과 backlog 회복이다. 공급 종료 후 backlog가 계속 증가하거나 회복하지 못하면 실패다.
기존 약32 jobs/s 최소 요구는 폐기한다. 40/s·125/s는 component capacity probe/stress input이며 서비스 SLO가 아니다.
confirmed/s·accepted/s·backlog slope·pending count·oldest pending age와 deadline 관계, active slots·job/PG time·Worker/Mock PG/PostgreSQL CPU·Hikari를 관측한다.
Waiting의 READY 발급률은 유입 조절이고 Reservation rate/permit은 DB 보호다. 같은 25/s 초기값의 적절성도 측정 대상이다.
반환 대기 polling은 1초로 맞췄으며, 반환 가능 시점부터 5초 목표는 secondary/stretch target으로 실측 전이다.
역할별 풀 분리가 물리적 독립성이나 기동 장애 독립성을 뜻하지 않는다. catalog 전체 조회 최적화는 현재 보류한다.
아래 baseline 수치·실행 이력은 변경 전 근거로 보존하며 Target 달성값으로 인용하지 않는다.

Primary performance SLO는 warmup 이후 steady-state 기준이다. Target Run -Reset은 재기동 후 단계형 warmup/Validation을 수행하고
데이터 정리 후 동일 JVM에서 측정한다. 이전 자동 warmup 없는 결과는 steady-state 증거로 쓰지 않는다. Cold-start 결과도 deployment/startup characteristic으로
보존하고 steady-state capacity와 별도로 기록한다. DB/OS 캐시가 남을 수 있으며 동일 비교 시험은 동일한 warmup/reset 조건을 사용한다.
단계형 warmup/Validation, MockPgDelayMs(기본 0, 0~5000ms), 202 accepted-only metric, terminal_at/deadline evidence와 saleStart 판정을 구현했다.
혼합 `target_payment_ms`는 진단용이며 review의 legacy 32/40 처리율 요구를 제거했다. 사전 거래를 추가한 Stage 0은 1회 PASS했으며 steady-state 성능 달성은 아직 미검증이다.

## Baseline 실행 이력의 범위

Target v1 첫 구현은 [별도 실행·검증 문서](architecture/target-v1.md)를 따른다. 아래 자원 표와 실행 이력은 baseline 기준이다.
Target 오버레이는 같은 총 CPU/메모리 상한을 역할별로 재배분한다. 새 목표 처리량과 대량 polling은 미검증이다.

Java 정합성 테스트·컨테이너 스모크와 예열 후 10 RPS/60초 본 측정 1회를 완료했다. 아래 과거 기록과 구분하며,
전체 실행 요약은 [실험 기록](../artifacts/performance/README.md)을 따른다.
과거 Python 수치는 archive/python-fastapi-baseline에 보존했으며 Java 성능 수치로 재사용하지 않는다.

## 자원 예산

성능 SLO는 resource budget과 함께만 의미가 있다. 아래는 baseline 예산이며 [현재 Target 배분](architecture/target-v1.md#역할자원)도
측정을 위한 초기 hypothesis다. CPU/memory/pool/rate/concurrency를 이번 문서 작업에서 조정하지 않는다.
Local 결과는 harness integration, obvious bottleneck, logic/rate/pool mismatch와 수정 필요 여부 판단에 사용한다.
최종 portfolio 성능 claim은 load generator/server 분리, fixed/declared resource envelope, 동일 workload와 대표 조건 반복 실행으로 검증한다.
AWS instance type이나 최종 resource 숫자는 아직 정하지 않는다.

Ryzen 5600은 6코어/12논리 CPU, 호스트 RAM 16GB다. 제공된 Docker 정보는 12 CPU/7.715GiB였다.
Compose cpu quota는 물리 코어 전용 할당이 아니다. localhost 결과를 같은 사양의 EC2 성능으로 환산하지 않는다.

| 서비스 | CPU quota | 메모리 상한 | DB pool |
|---|---:|---:|---:|
| Nginx | 0.25 | 128MiB | — |
| API 각 2개 | 각각 0.75 | 각각 768MiB | 각각 8 |
| PostgreSQL | 1.5 | 1536MiB | — |
| Redis | 0.25 | 256MiB | — |
| Worker | 0.5 | 512MiB | 4 |
| Mock PG | 0.25 | 512MiB | 2 |
| Prometheus (선택) | 0.25 | 256MiB | — |

핵심 서비스 합계 4 CPU/3968MiB, Mock PG 포함 4.25 CPU/4480MiB다.
선택 관측 도구와 부하 발생기는 남은 예산에서 실행하고 실제 CPU/메모리도 기록한다.
JVM heap 상한은 컨테이너 메모리의 65%다. 나머지가 native/thread/direct memory를 모두 보장한다는 뜻은 아니다.
API 하나와 둘을 비교할 때는 API 총 CPU=1.5, 총 메모리=1536MiB, 총 pool=16을 유지해야 한다.
현재 Compose는 2개 구성이다. 단일 API 공정 비교용 설정/측정은 아직 하지 않았다.

## 목표와 판정

아래는 확정한 Target v1 계약이며 **달성은 미검증**이다. 대표 normal Business는 관심 사용자 50,000명 / 초기 stock 1,000개,
인당 최대 1개, 0~5초 30,000명·5~15초 15,000명·15~60초 5,000명이다. HELD 후 seed 기반 1~45초 think time을 둔다.
Waiting registration max 180초 / READY TTL 10초 / hold 300초 / Mock confirmation window acceptedAt+70초를 유지한다.

| 항목 | 목표 |
|---|---|
| 정합성 | 모든 normal/retry/failure에서 아래 hard invariant 위반 0 |
| Waiting | 정상 steady-state 개별 join/poll HTTP 각각 p99 ≤ 1초, dropped=0, 정상 Business unexpected 5xx/timeout/503=0. WAITING→READY 전체 시간에는 1초 SLO 없음 |
| Reservation | 실제 READY 수신 후 성공 purchase 201 accepted latency p99 ≤ 1초, stock correctness/Hikari timeout/restart/OOM=0 |
| Business 초기 점유 / 확정 | sale start +60초 내 초기 stock 1,000개 HELD, +120초 내 stock의 ≥95%(950개) CONFIRMED |
| Business 예상 밖 오류 | normal 전체 ≤0.1%. Waiting 및 Payment의 더 엄격한 오류 0 계약을 완화하지 않음 |
| Payment acceptance | 정상 steady-state 성공 202 accepted-only p95 ≤ 1초. normal/isolation Hikari timeout/unexpected 5xx/client timeout=0, durable DB state 유지 |
| Worker / confirmation | accepted SUCCESS별 confirmationDeadline 전에 terminal/CONFIRMED, drain 이후 성공 시나리오 pending=0, 공급 종료 후 backlog 회복 |
| Isolation | 동일 payment workload에 Waiting 추가 후 202 p95 ≤ 1초, Hikari timeout/unexpected 5xx/timeout=0, SUCCESS deadline와 correctness 유지. Worker-only 대비 latency/backlog degradation 기록, 임의 상대 한도 없음 |
| 반환 재고 재구매 | 반환 가능 시점부터 ≤5초는 secondary/stretch timing target이며 primary SLO 아님 |
| 자원 | normal steady-state Hikari timeout/process restart/OOM=0 |
| 반복 | 대표 시나리오 3회 개별 결과, 생성기 dropped_iterations=0 |

429는 오류와 분리해도 반드시 비율을 보고한다. 판매 수량/확정 시간 없이 빠른 거절만으로 통과시키지 않는다.
50,000명/1,000개는 workload이며 60초는 초기 stock hold 목표다. 모든 사용자의 60초 내 구매 결과나 1초 내 READY를 약속하지 않는다.
Waiting은 PostgreSQL 연결 증가 없이 대량 유입을 흡수하고 READY로 downstream 진입률을 제어해야 한다.

Hard invariant: oversell/inventory invariant/per-user limit/invalid·partial hold/duplicate successful payment·confirmation 위반=0.
같은 사용자·멱등키·본문 retry는 중복 주문/attempt를 만들지 않는다. Waiting은 durable order/payment를 만들지 않고 DB connection=0이다.
READY는 stock reservation이 아니며 Redis는 inventory/order/payment authoritative store가 아니다.
accepted payment 주문은 시간만으로 재고를 반환하지 않는다. UNKNOWN/LOST_RESPONSE는 같은 attempt로 복구·재확인하며 중복 성공을 만들지 않는다.

반환 5초 인증에는 `holdExpiresAt → 실제 release commit → catalog AVAILABLE projection → READY 발급 → purchase → 새 HELD commit`의
정확한 event timestamp가 필요하다. 현재 coarse observer sample만으로 ≤5초를 확정하지 않는다.
30초 drain은 현재 관측 절차이며 개별 confirmationDeadline 검증을 대체하는 고정 복구 SLO가 아니다.
Burst/후속 PG delay에 normal latency SLO를 일률 적용하지 않는다. durable acceptance, backlog 규모,
oldest pending age의 confirmation budget 침범, accepted SUCCESS의 deadline와 correctness를 본다.
1,000건 burst의 1초 내 PG confirmation 요구는 없다. retry/LOST_RESPONSE/UNKNOWN/FAILURE는 멱등성·중복 방지·durable state·복구/재확인이 primary다.
영구 UNKNOWN과 의도적으로 중단한 PG에는 정상 판매 완료 목표를 적용하지 않으며 상태 정합성을 확인한다.

## Baseline 실행 방법

공통 절차는 ops/performance.ps1로 통합했다. 명령과 결과 파일 설명은
[Git Bash 실행 가이드](guides/load-test-guide.md)를 따른다.
현재 purchase-spike는 최초 구매 시도와 성공 점유의 결제 접수만 포함하며,
전체 비즈니스 합격 시험이나 자동 RPS 상승 실험은 아니다.

`capacity`는 충분한 재고·정상 PG·모든 구매 성공을 전제로 한 별도 시나리오다.
CLI에서 RPS/재고/시간을 지정하며, 10 → 25 → 50 → 100 RPS를 사용자가 결과 확인 후 한 단계씩 실행한다.
HTTP 지연/오류/누락 외에 Worker backlog·가장 오래된 작업의 나이 추이, 최종 확정/불변식/Hikari를 확인한다.
최종 drain 성공은 지속 처리 능력의 충분조건이 아니다. 경계 아래에서 더 긴 실행과 반복이 필요하다.
일반 탐색은 Diagnostics OFF, 경계 원인 진단은 ON으로 구분한다. 실행과 파일 해석은 위 가이드를 따른다.

capacity 경계를 확인한 뒤 business workload로 넘어가는 이해는 맞다. 다만 전체 최초 유입 RPS와
성공 점유→결제 처리율은 다르므로 capacity가 3,000 RPS에 못 미친다는 이유만으로 business 실험을 배제하지 않는다.
재고 1,000개를 두고 소진 응답·재시도·포기·반환 재고 재구매를 포함하는 별도 요구사항을 검증해야 한다.
필요하면 축소 부하로 흐름을 먼저 확인하되 목표 부하를 충족했다고 기록하지 않는다.
현재 purchase-spike의 3,000→400은 최초 도착 패턴일 뿐, 위 행동을 포함한 완성된 business workload는 아니다.

## Baseline에서 남았던 성능 실험

아래는 baseline의 미완료 목록이다. 현재 우선순위와 Target 시험은 문서 상단의 단계별 계획을 따른다.

- 시드 고정의 정상 backoff+jitter/최대 5회 과도 재시도, 구매 포기/반환 재고 재구매를 포함한 120초 workload.
- 기준선 vs Redis gate의 실제 처리량·락 대기·DB 쿼리/요청 비용.
- 총 자원 고정 API 1개/2개 비교, 포화점과 결제 접수 지연.
- 컨테이너 강제 종료, Redis/PG 장애 상태에서 재기동 복구 시간 측정.
- 생성기 자체 한계 검증과 대표 조건 3회 반복.

자동 테스트에서 Clock과 lease를 이용한 복구 논리는 검증하지만 실제 컨테이너 장애 시간 측정을 대신하지 않는다.
현재 수치는 목표이며 달성 측정값을 아직 기록하지 않았다.

## 과거 실행 이력

2026-09-08~09의 기능 확인·기동 오류·baseline warmup 및 본 측정 과정은 [Java baseline 실행 이력](reviews/java-baseline-history.md)에 보존한다.
실행별 원본과 요약은 [artifact 목록](../artifacts/performance/README.md), 이후 Target 결과는 [분석 목록](reviews/README.md)을 따른다.
