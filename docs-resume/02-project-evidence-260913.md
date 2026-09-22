# 개인 프로젝트 근거 기록과 최신 실험 해석

기준일: 2026-09-13. 이번 확인은 기존 자료의 읽기·분석이며 테스트 재실행이 아니다. 수치는 별도 표시가 없으면 로컬 단일 실행이다. 표의 RPS는 시나리오 설정값이고, 도착 수와 전체 HTTP 수는 관측값이다.

## 1. 버전·증거 경계

- 현재 계약: [PROJECT](../PROJECT.md), 구현 설명: [DESIGN](../DESIGN.md), [Target 구조](../docs/architecture/target-v1.md).
- 과거 근거: [기존 portfolio ledger](../docs/portfolio/portfolio-evidence.md). 과거 Java·Python 실험을 현재 Target v1 성능으로 옮기지 않는다.
- 최신 결과는 아래 실행 폴더의 `config.json`, `k6-summary.json`, `result.json`, `after-db.json` 등을 대조했다. 과거 상세 수치는 기존 ledger에 출처가 있으나 이번에 원격 CSV를 다시 계산하지 않았다.
- 자동 검사 통과, 기능 테스트 성공, 반복 부하 검증, 실제 운영 검증은 서로 다르다. `requires_review`는 그대로 보존한다.

## 2. 과거 경험 — 삭제하지 않고 별도 관리

| ID | 보존할 내용 | 출처·현재 사용 범위 |
|---|---|---|
| H0 | 총 60회, Redis Lua 1,000 VU 평균 p95 340.32ms, 3,000~10,000 VU에서 성공 주문 100건·주문/재고 차이 0 | 기존 `tmp/02-experience-evidence.md`의 사용자 기록. 정확한 원본 행렬·집계식은 이번에 재확인하지 않음. 현재 구현의 수치로 사용 금지 |
| H1 | 이전 Java에서 재고 100개에 성공 주문 973건 생성. 세 재고 전략의 기본 행렬은 각 15회, 초과 판매·주문/재고 불일치 0 | 기존 ledger 항목 1. [당시 실험 기록](https://github.com/tldnr1/limited-goods-reservation/blob/0c39efc77bdc1725f665b726570ec1de5d93eab6/records/experiments/v1-oversell-baseline.md), [비교 CSV](https://github.com/tldnr1/limited-goods-reservation/blob/0c39efc77bdc1725f665b726570ec1de5d93eab6/records/experiments/v2-stock-strategy-comparison.csv) |
| H2 | Redis 차감 후 DB 저장 실패 주입 시 Redis 10회 모두 차감 100·DB 주문 90, RDB 10회는 차감/주문 100으로 일치 | 기존 ledger 항목 2. [실패 주입 CSV](https://github.com/tldnr1/limited-goods-reservation/blob/0c39efc77bdc1725f665b726570ec1de5d93eab6/records/experiments/v2-stock-failure-injection.csv). 특정 실패 지점의 정합성 비교이며 초과 판매나 전체 복구 성능 검증과 다름 |
| H3 | 이전 Java v3.2에서 Front Gate의 HTTP p95가 RDB 대비 조건별 43.5~69.5% 낮음. 24행의 초과 판매·예약 불일치 0 | 기존 ledger 항목 3. [비교 CSV](https://github.com/tldnr1/limited-goods-reservation/blob/0c39efc77bdc1725f665b726570ec1de5d93eab6/records/experiments/v3-2-architecture-vu-baseline.csv). Waiting OFF, 조건별 1회, 같은 로컬 호스트. 현재 대기열 성능 개선율로 인용 금지 |
| H4 | 이전 Worker에 40/s 공급 시 결제 접수 2,401건, pending 최대 1,473. 약 90초 관측의 확정 기울기 15.42/s를 당시 4건/250ms 제출 구조와 연결 | [당시 capacity 결과](../artifacts/performance/20260909-230854-201-baseline-capacity/capacity-result.json), 기존 ledger 항목 5. 현재 immediate refill의 전후 개선 배수로 쓰지 않음 |

H0~H3은 기존 기록을 잃지 않기 위한 보존과 연결이다. 숫자를 실제 제출 문장에 넣을 때는 해당 원본과 조건을 다시 확인한다. 서로 다른 실험 횟수를 합산하지 않는다.

추천 이야기: Redis 내부 원자성과 Redis–DB 전체 작업의 원자성은 범위가 다르다는 점을 장애 주입으로 확인했다(H2). 현재 PostgreSQL 원장·트랜잭션 중심 구조(C1)와 연결할 수 있지만, 실제 설계 변경의 직접 계기였는지는 본인의 당시 판단으로 확인한다.

## 3. 현재 구현과 기능 검증

### C1. 상태·트랜잭션·결제 실패 처리 — 구현 근거

근거: [프로젝트 계약](../PROJECT.md), [트랜잭션·결제 설계](../DESIGN.md), [계약 테스트 코드](../src/test/java/com/limitedgoods/ContractTest.java).

- 다중 상품의 주문·점유·재고 변경을 한 DB 트랜잭션으로 처리한다. 재고 락 순서를 UUID 오름차순으로 맞춘다.
- 구매 멱등키는 사용자 단위, 결제 멱등키는 주문 단위다. 같은 키의 다른 본문은 409다.
- Redis READY/permit은 진입 제어이며 재고 정합성의 원장이 아니다.
- 결제 시도를 DB에 저장한 후 202로 접수하고 Worker가 처리한다. PG HTTP 호출 동안 DB 트랜잭션을 유지하지 않는다.
- Worker는 lease와 SKIP LOCKED로 작업을 가져오고 attempt UUID를 PG 멱등키로 사용한다. UNKNOWN은 재고를 보유하며 재확인한다.
- 슬롯 완료 즉시 다음 작업을 가져오는 구조로 바꿨다. 이 구현 사실과 이전 대비 처리량 개선 배수는 구분한다.

가능한 문장:

> 결제 접수와 최종 확정을 분리하고 시도를 DB에 영속화했습니다. 응답 유실은 같은 시도로 재확인하며, 결과가 불명확한 결제의 재고가 시간 만료만으로 반환되지 않도록 구현했습니다.

보장하지 않는 범위: 실제 PG 운영·무제한 장애 복구·전역 exactly-once·영구 UNKNOWN의 자동 해결. 역할별 풀 분리는 물리 자원과 장애의 완전한 독립성을 뜻하지 않는다. 락 순서 통일만으로 모든 교착 상태가 제거됐다고 쓰지 않는다.

### C2. 기능 계약 확인 — 당시 테스트 결과

근거: [2026-09-10 tests](../artifacts/target-v1/20260910-functional/tests.json), [review](../artifacts/target-v1/20260910-functional/review.md), [smoke](../artifacts/target-v1/20260910-functional/smoke.json).

- 당시 실제 PostgreSQL·Redis 기반 39개 테스트에서 failure/error 0.
- 소량 HTTP smoke 4건 모두 CONFIRMED. 응답 유실·지연 확정·Redis 중단 중 기존 경로를 확인한 기록이 있다.
- 300초 점유와 299초 경계는 제어 시계 검사다. 실제 5분 대기나 장시간 부하 복구 검증으로 바꾸지 않는다.
- 현재 작업에서 재실행하지 않았으므로 최신 커밋 전체에 대해 새로 39개가 통과했다고 쓰지 않는다.

가능한 문장:

> 실제 DB 기반 테스트와 소량 HTTP 확인으로 점유·결제 상태 전이, 응답 유실 후 재확인 동작을 검증했습니다.

## 4. 최근 실험 결과

### N1. 사전 정상 거래 이후 warmup

근거: [전후 분석](../docs/reviews/warmup-20260913-review.md), [변경 전 결과](../artifacts/performance/20260912-223508-886-target-warmup-normal/result.json), [변경 후 결과](../artifacts/performance/20260913-022723-330-target-warmup-normal/result.json).

동일 애플리케이션 JAR, Payment 0.25 CPU / 384MiB / pool 4 및 기존 2→5→10→10/s 각 10초를 유지하고, 정상 거래 한 건을 별도로 실행·확정·정리하는 priming을 추가했다. 모든 API·분기를 한 번씩 실행하거나 JIT 최적화 완료를 보증하는 절차는 아니다.

| 관측 항목 | 사전 거래 없음 | 사전 거래 추가 |
|---|---:|---:|
| 실제 시작 / 최종 확정 | 273 / 262 | 272 / 272 |
| Payment Hikari timeout 증가 | 13 | 0 |
| Payment HTTP 500 / client timeout, 재시도 포함 | 13 / 4 | 0 / 0 |
| 성공한 Payment 202 p95 | 158.70ms | 88.16ms |
| dropped iterations | 0 | 0 |

priming 결제 응답 자체는 약 3.069초였다. priming 시작부터 warmup 시작까지 수집·정리 포함 약 21.291초가 추가됐다. 초기 비용이 사라진 것이 아니라 사전 처리 구간에서 관측됐다. 사전 호출과 경과 시간이 함께 달라졌고 단일 비교이므로 JIT 단독 원인·재현 가능한 개선율로 확정하지 않는다. 성공 응답 p95는 실패 요청을 제외하므로 그 수치만으로 효과를 제시하지 않는다.

가능한 문장:

> 초기 거래에서 발생하던 오류와 본 측정을 구분하기 위해 정상 거래를 사전 실행하도록 했습니다. 동일 자원 설정의 후속 warmup 1회에서 272건 모두 확정되고 Payment 커넥션 획득 timeout이 관측되지 않았습니다.

용도: 측정 조건과 오류 해석을 보여주는 보조 사례. “JIT 튜닝으로 서비스 성능 개선”, “자원이 충분함을 입증”은 불가.

### N2. Worker — 설정 10건/s, 120초

근거 폴더: [20260913-111037-343](../artifacts/performance/20260913-111037-343-target-worker-normal/). 핵심 파일은 [summary](../artifacts/performance/20260913-111037-343-target-worker-normal/k6-summary.json), [DB](../artifacts/performance/20260913-111037-343-target-worker-normal/after-db.json), [판정](../artifacts/performance/20260913-111037-343-target-worker-normal/result.json).

- 미리 준비한 주문에 결제를 요청하는 Worker 시나리오다. 대기·구매까지 전체 사용자 흐름의 처리량이 아니다.
- 실제 시작·완료·접수·확정 1,201건, dropped=0, unexpected=0. 결제 접수 지연 p95 약 8.38ms.
- 최종 pending/unknown/failed=0, 기록된 성공 deadline 위반 및 재고·인당 한도·점유 위반=0.
- 자동 집계의 약 115.40초 표본에서 accepted/confirmed 약 10.00/s, backlog slope=0, 표본 pending 최대 2, oldest 최대 약 0.214초. 표본 사이의 순간 최댓값을 보증하지 않는다.
- `automatedChecksPassed=true`, `status=requires_review`. Mock PG delay 0, 로컬 1회이며 지속 용량·포화점·반복 검증 완료가 아니다.

가능한 문장:

> 예열 후 로컬 Worker 실험에서 10건/s로 120초간 결제를 요청해 실제 1,201건 모두 최종 확정된 것을 확인했습니다.

이것은 확인 수치다. 이전보다 몇 배 빨라졌다는 개선 수치가 아니다. 설정에 `users=50000`이 있어도 실제 5만 명 실행을 뜻하지 않는다.

### N3~N6. Waiting — 등록과 polling을 분리한 결과

각 폴더의 config·summary·result를 기준으로 기록했다. “시작/완료”는 사용자 함수 실행이며 모두 READY 또는 구매에 도달했다는 뜻이 아니다.

| ID / 실행 폴더 | 시나리오와 설정 | 실제 관측 | 판정 |
|---|---|---|---|
| N3 [112630](../artifacts/performance/20260913-112630-835-target-waiting-normal/) | join+poll, 100명/s·60초, VUs 200 / Max 20,000 | 시작 4,117, dropped 1,883. HTTP 120,051회 중 unexpected 6,122회 | failed. join/poll 지연·오류 기준 및 API scrape 실패 |
| N4 [134647](../artifacts/performance/20260913-134647-767-target-waiting-join-normal/) | join만, 100명/s·60초, VUs 200 / Max 200 | 시작·완료 6,001, dropped/unexpected 0. join p99 70.17ms | 자동 검사 통과, requires_review |
| N5 [153316](../artifacts/performance/20260913-153316-036-target-waiting-normal/) | join+poll·READY 미사용, 25명/s·60초, VUs 200 / Max 2,000 | 시작·완료·READY 1,000, dropped 501. unexpected 0. join/poll p99 132.77/127.86ms | failed. 유입 부족으로 목표 부하 검증 불가 |
| N6 [154852](../artifacts/performance/20260913-154852-123-target-waiting-normal/) | N5와 같은 행동·유입, VUs 1,600 / Max 2,000 | 시작·완료 1,501, dropped 0, READY 425. join unexpected 254/1,501, poll 830/20,006. join/poll p99 1,002.44/1,070.49ms | failed. 응답 오류·지연 기준 및 API scrape 실패 |

해석:

1. N4는 등록 경로의 해당 조건만 확인한다. N3에서 polling을 제거한 것은 부하 내용과 큐 상태를 바꾼 진단 실험이다. 제품 성능을 개선한 전후 비교가 아니다.
2. N5는 수행된 요청의 지연·오류만 보면 양호하지만 예정 유입을 충분히 넣지 못했다. 성공 실행으로 채택할 수 없다. MaxVus 설정값을 실제 사용 VU나 메모리 포화의 증거로 읽지 않는다.
3. N6는 사전 VU 수를 늘려 도착 누락은 없어졌지만 응답 실패가 남았다. 따라서 “VU만 늘리면 해결”도 성립하지 않는다. 같은 호스트의 발생기 비용, API·Nginx·Redis 경합 중 기여도는 미확정이다.
4. 미사용 READY는 구매로 소비되지 않고 만료까지 남는다. 현재 동시 한도 50·TTL 최대 10초는 단순 모델에서 약 5 READY/s의 제약을 만들 수 있다. 실제 항상 5/s라는 측정 결론도, WaitingRate 25면 항상 25/s가 발급된다는 보장도 아니다.
5. 신규 사용자 25명/s는 전체 HTTP 25회/s가 아니다. 대기자가 누적되면 polling 요청이 추가된다. 전체 HTTP 집계에는 유입 종료 후 대기 해소도 포함되므로 총 요청 수를 60초로 나누지 않는다.
6. 에러로 사용자가 조기 종료하면 HTTP 수가 감소할 수 있다. N6의 총 HTTP 감소를 최적화 효과로 해석하지 않는다. Waiting의 주문·결제 0은 구매하지 않는 시나리오의 결과이며 경쟁 구매 정합성 증거가 아니다.

시나리오 설명과 후속 조사 후보: [Waiting v2 가이드](../k6/target/waiting-v2/README.md). 이 파일의 “미실행” 상태 문구는 최신 artifact보다 오래됐다.

현재 가능한 문장:

> 대기 등록과 polling을 분리해 등록 전용 100명/s 실험의 응답을 확인하고, polling 포함 실험에서는 발생기의 유입 누락과 실제 응답 오류를 구분해 조사 범위를 좁혔습니다.

불가: “polling 병목 해결”, “CPU 부족을 확정”, “대기열 도입으로 100 RPS 처리”, “5만 명 동시 접속 검증”.

## 5. 현재 판단과 후속 작업의 경계

현재 자료로는 Payment/Worker가 해당 10/s 조건에서 동작한다는 근거가 추가됐다. 전체 자원이 충분한지, Waiting 실패의 근본 원인이 무엇인지는 확정되지 않았다. 기존 문서의 Reservation·Isolation·Business 명령은 실행 계획이며 대응 결과가 확인되지 않은 테스트를 완료 목록에 넣지 않는다.

실험을 이어갈 때는 N5/N6의 공급 구간을 맞춰 첫 drop·오류와 발생기/서비스 자원·upstream 로그 시각을 대조하는 것이 조사 후보다. 정상 구매로 READY를 소비하는 기존 Reservation 저부하 시나리오는 별도 가설 비교 후보이며 polling과 DB 부하 조건이 달라짐을 명시해야 한다. 이번 문서 작업에서 실행하거나 구현하지 않았다.

자기소개서는 기다릴 필요가 없다. C1/C2의 판단과 확인 범위, 원본을 확인한 H1/H2/H3를 핵심으로 쓰고 N1/N2는 보조한다. N3~N6은 해결 전 조사임을 유지한다. 개선율이 꼭 필요한 문항이 아니라면 더 큰 작업을 선행 조건으로 만들지 않는다.
