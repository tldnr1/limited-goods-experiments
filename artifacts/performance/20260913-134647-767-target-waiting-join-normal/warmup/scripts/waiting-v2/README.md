# Waiting v2: 원인 분리 → 같은 조건에서 개선 검증

상태: **실험 준비 및 offline 검증 단계. 아래 새 실험의 실제 부하는 아직 실행하지 않았다.**
Java, Redis Lua, Nginx, CPU/메모리, rate/permit 정책은 이번 정리에서 변경하지 않았다.
계약은 [PROJECT](../../../PROJECT.md), 전체 실행은 [Target 가이드](../../../docs/guides/target-v1-load-guide.md)를 따른다.
이 문서는 이번 Waiting 조사에 필요한 실행 순서·해석·수정 선택 기준만 보완한다.

## 1. 무엇을 구분하는가

현재 흐름은 `대기 등록 → polling으로 READY 확인/발급 → 티켓으로 구매 요청 → DB HELD → 결제 수락 → Worker`다.
Redis가 재고를 점유하는 것이 아니다. Redis는 진입을 제어하고 PostgreSQL이 실제 재고를 점유한다.
READY는 재고 확보가 아니라 잠깐 유효한 구매 진입 허가다.
화면에서 버튼을 잠그는지와 서버에서 admission을 검사하는지는 별개다.

| 실험 | CLI Scenario / 실제 코드 | 확인하는 것 | 확인하지 못하는 것 |
|---|---|---|---|
| A: 등록만 | `waiting-join` / `join.js` | 신규 사용자당 POST 1회, 등록 경로의 100/s 수용 | 실제 대기 생명주기, polling·READY·DB 처리량 |
| B: READY 미사용 | `waiting` / `unused-ready.js` | 기존 join+poll 부하 및 미사용 티켓 적체 재현 | 정상 구매의 READY 소비율, DB 락 정합성 |
| C: READY 소비 | `reservation` / `../reservation.js` | join+poll+실제 구매, READY 해제·HELD·DB 보호 | 결제/Worker, 5만 명과 품절 후 반환 흐름 |

B는 기존 `browser()` 행동을 그대로 사용한다. READY를 보면 사용자는 종료하지만 티켓은 서버에서 만료까지 남는다.
현재 READY 동시 한도 50, TTL 최대 10초이므로 미사용이 계속되면 대략 `50/10 = 5 READY/s` 수준의 제약이 생긴다.
이는 상시 정확한 처리율이 아니다. 등록 만료가 가까우면 티켓 TTL이 짧아지고, polling 지연·발급 간격도 영향을 준다.
`WaitingRate=25`는 발급 상한이지 항상 25/s를 생산하는 스케줄러가 아니다.
현재 구현은 poll 중 발급 조건을 검사하며 앞쪽 1,000명에게 1초 retryAfter를 준다.
따라서 **25 READY/s를 만들려면 반드시 1,000 poll/s가 필요하다는 뜻이 아니다.**

`Rps=100`은 B/C에서는 신규 사용자 100명/s이고 전체 HTTP 100회/s가 아니다.
`HTTP RPS ≈ 신규 등록 + 재등록 + Σ(대기 사용자 수 / 실제 poll 주기) + 구매·재시도`로 구분한다.
A는 재시도·poll이 없어 신규 사용자 수와 등록 요청 수가 일치한다. 30초 heartbeat를 갱신하지 않으므로
inactive cleanup도 발생한다. A의 큐 크기·Redis 비용을 B와 완전히 동일한 조건으로 보지는 않는다.

현재 Lua는 만료 정리, heartbeat, 순번 조회, READY 발급 등 **읽기와 쓰기**를 함께 수행한다.
개인별 poll 응답을 단순 캐싱하면 티켓·순서·만료·heartbeat가 어긋날 수 있다.
`FULLY_HELD` 분기는 순번 구간 판단보다 먼저 전체 대기자에게 1초 retryAfter를 준다.
향후 Business에서는 이 별도 분기도 확인해야 하며, 반환 발견 지연 목표를 보존하지 않는 주기 변경은 개선으로 인정하지 않는다.

## 2. 기존 결과에서 말할 수 있는 범위

로컬 원본: `artifacts/performance/20260913-112630-835-target-waiting-normal`.
100명/s × 60초에서 started 4,117, dropped 1,883, HTTP 총 120,051회 중 실패 6,122회였다.
전체 HTTP 수는 유입 60초뿐 아니라 남은 사용자 처리 구간을 포함하므로 60으로 나누어 측정 RPS라고 쓰면 안 된다.
Nginx의 upstream 연결 timeout / no live upstreams, API scrape 실패가 관측됐다.
그렇지만 Nginx, API 수락 대기, CPU quota, 발생기 간 원인 비율은 아직 분리하지 못했다.
k6는 최대 약 834.5MiB/1GiB였으므로 VU 증가 중 drops가 났다는 사실만으로 메모리 한계라고 단정하지 않는다.

Waiting 측정 구간의 주문·결제 생성은 0건이다. DB가 이 경로에서 격리됐다는 근거이지,
비관적 락으로 경쟁 구매의 정합성을 검증했다는 근거가 아니다.
별도 Warmup 272/272 확정은 준비 흐름 검증이며 JIT가 모두 완료됐다는 보장은 아니다.
Worker 10/s·120초의 1,201건 수락/확정과 backlog 회복은 해당 부하의 근거이며 처리 한계나 5만 명 목표 달성은 아니다.
각 로컬 실행 ID는 `20260913-022723-330-target-warmup-normal`, `20260913-111037-343-target-worker-normal`이다.

따라서 현재 결론은 **시나리오 의미와 부하 증폭을 분리할 필요가 있고, 실제 HTTP 경로 실패도 발생했다**는 것이다.
시나리오를 바꾸어 오류가 사라져도 기존 구현의 수용 능력이 개선됐다고 주장하지 않는다.

## 3. 이번에 필요한 수정과 보류 사항

- 추가: A는 기존 인자로 polling을 끌 수 없어 `joinOnly()`와 전용 스크립트를 추가했다.
  429·5xx·잘못된 202 응답도 등록 실패다. 실제 시작 전체가 등록 성공해야 한다.
- 분리: B의 스크립트를 이동하고 과거 `waiting.js` 진입점은 호환용으로 남겼다.
  새 A/B summary에 p99 수치를 저장한다. 기존 timeout·retry·poll 정책은 그대로다.
- 재사용: C는 기존 Reservation 시나리오로 가능하므로 복제하지 않았다.
- 보류: polling 정책·캐싱·서버 튜닝·자원 확대. 아래 결과에서 원인을 좁힌 뒤 하나씩 선택한다.
- 유지: 다른 k6 파일, 실행기 폴더, 과거 artifact는 역할 구분이 이미 있어 일괄 재배치하지 않았다.

## 4. 직접 실행하는 순서 (PowerShell 7, 저장소 루트)

명령은 **한 번에 하나씩** 실행하고 결과를 읽은 뒤 다음 단계로 간다. 일괄 실행용 목록이 아니다.
dev/test 부하를 동시에 실행하지 않는다. `Run -Reset`은 **perf DB/Redis 실험 데이터를 초기화**하고
사전 거래·embedded warmup·cleanup 후 본 측정을 수행한다. 과거 artifact는 보존된다.
따라서 `DurationSeconds=60`이어도 총 실행은 예열·남은 사용자 처리·관측을 포함해 수분 걸릴 수 있다.

### 준비 확인

```powershell
pwsh -NoProfile -File ops/performance.ps1 -Mode target -Action Check -Scenario waiting-join -WaitingRate 25 -ReservationRate 25 -Permits 8 -MockPgDelayMs 0
```

준비가 없거나 설정이 다를 때만 아래를 실행한다. 다른 환경 충돌이면 먼저 그 환경을 명시적으로 종료한다.
스크립트·문서만 변경한 이번 작업 때문에 기존에 준비된 서버 이미지를 다시 빌드할 필요는 없다.

```powershell
pwsh -NoProfile -File ops/performance.ps1 -Mode target -Action Prepare -WaitingRate 25 -ReservationRate 25 -Permits 8 -MockPgDelayMs 0
```

### 첫 실행: A — 등록 자체가 100/s를 받는가

```powershell
pwsh -NoProfile -File ops/performance.ps1 -Mode target -Action Run -Scenario waiting-join -Variant normal -Rps 100 -DurationSeconds 60 -Stock 1000 -Vus 200 -MaxVus 200 -WaitingRate 25 -ReservationRate 25 -Permits 8 -MockPgDelayMs 0 -Seed 20260911 -Reset
```

기준: started=finished=join_accepted가 6,000~6,001, dropped=0, join_rejected=0,
join p99≤1,000ms, endpoint unexpected=0, 주문·결제 생성=0, scrape·Hikari·재기동 검사 이상 없음.
VU는 고정해 동적 증설 변인을 제거했다. 응답이 나빠져 이 VU 수로 유입을 못 채우면 그 실행은 실패/원인 조사 대상이다.
VU만 올려 결과를 PASS로 덮지 않는다. A 실패 시 B/C 고부하로 넘어가지 않는다.

### A 확인 후: B — 기존 polling 부하를 낮은 유입부터 확인

```powershell
pwsh -NoProfile -File ops/performance.ps1 -Mode target -Action Run -Scenario waiting -Variant normal -Rps 25 -DurationSeconds 60 -Stock 1000 -Vus 200 -MaxVus 2000 -WaitingRate 25 -ReservationRate 25 -Permits 8 -MockPgDelayMs 0 -Seed 20260911 -Reset
```

정상적으로 관측 가능하면 같은 명령에서 `-Rps 50`, 이후 `-Rps 100`으로 각각 1회씩 확인한다.
실패/drop/scrape 누락이 발생한 단계에서 멈추고 첫 악화 시각을 비교한다.
위 계단은 원인 조사용이며 과거 100/s 실행과는 MaxVus가 다르다. 과거 조건의 재현이 필요할 때만 다음 명령을 쓴다.

```powershell
pwsh -NoProfile -File ops/performance.ps1 -Mode target -Action Run -Scenario waiting -Variant normal -Rps 100 -DurationSeconds 60 -Stock 1000 -Vus 200 -MaxVus 20000 -WaitingRate 25 -ReservationRate 25 -Permits 8 -MockPgDelayMs 0 -Seed 20260911 -Reset
```

B는 READY를 소비하지 않으므로 25 READY/s를 통과 조건으로 잡지 않는다.
started/finished 일치는 사용자 함수가 끝났다는 뜻이지 모두 READY가 됐다는 뜻도 아니다.
원본 browser는 일부 오류에서 조기 종료하므로 READY 수·오류·만료와 실제 HTTP 공급량을 함께 본다.
개선 전후 비교에서는 Vus/MaxVus까지 같은 값을 사용한다.

### C — 정상 구매로 READY가 비워지는가

B에서 어떤 일이 일어나는지 파악한 뒤, 별도 실험으로 실행한다.

```powershell
pwsh -NoProfile -File ops/performance.ps1 -Mode target -Action Run -Scenario reservation -Variant normal -Rps 10 -DurationSeconds 60 -Stock 10000 -Vus 200 -MaxVus 2000 -WaitingRate 25 -ReservationRate 25 -Permits 8 -MockPgDelayMs 0 -Seed 20260911 -Reset
```

문제가 없으면 같은 명령에서 `-Rps 25`로 확인한다. 재고를 넉넉히 둬 품절을 섞지 않는다.
추가로 100/s 유입 제어를 보려면 `-Rps 100`으로 별도 실행하되, 발급/구매 상한 25/s와 대기 180초 만료를 유지하므로
전체 도착의 구매 성공을 무조건 기대하지 않는다. 공급 구간과 이후 대기 해소 구간을 나눠 본다.
수동으로 started→READY→HELD, DB orders=HELD, 구매 거절/재시도·만료, rate/permit, DB lock/Hikari를 확인한다.
10/s의 충분한 재고·정상 흐름에서는 전체 started의 HELD 도달을 요구한다.
기존 자동 판정은 `held>0` 및 DB 일치만으로 전체 사용자 구매 성공을 보증하지 않는다.
결제 요청은 없으므로 이 테스트만으로 Worker 성능을 결론 내리지 않는다.

## 5. 결과 확인과 다음 수정 선택

각 실행이 출력한 결과 디렉터리를 사용한다. 예를 들어 `$run`에 그 경로를 지정한다.

```powershell
$run = 'artifacts/performance/실행이-출력한-디렉터리명'
Get-Content "$run/result.json"
Get-Content "$run/config.json"
Get-Content "$run/k6-summary.json"
```

`automatedChecksPassed=true`여도 `requires_review`는 수동 검토가 남았다는 뜻이다.
결과 판정을 다시 실행하면 result.json을 덮어쓰므로 과거 결과를 정리 목적으로 재판정하지 않는다.

| 먼저 볼 증거 | 용도 |
|---|---|
| `phases.json`, `raw.json` | 공급 구간별 join/poll/purchase 요청 수, status별 p95/p99, dropped 발생 시각 |
| `k6.log`, `generator-resources.jsonl` | 실제 VU·도착·CPU/메모리, 발생기 부족 가능성 |
| `services.log`, `prometheus.json`, `resources.jsonl` | upstream 연결 오류, API active/latency/scrape, 서비스 CPU/메모리의 같은 시각 비교 |
| `redis-samples.jsonl`, `redis-slowlog.txt` | queue/READY 점유, Redis CPU·지연; 누적 통계는 구간 차분으로 비교 |
| `db-samples.jsonl`, `after-db.json`, `boundary-*.json`, `timeline.json` | Waiting DB 격리, C의 정합성·락·Hikari·영속 결과 |

- A부터 실패: polling을 원인으로 단정하지 말고 발생기→Nginx→API→Redis 등록 경로부터 좁힌다.
- A 정상/B 악화: polling이 더하는 요청 수, 미사용 READY 적체, HTTP당 비용이 다음 조사 축이다.
  A/B는 큐 상태도 다르므로 이 비교만으로 특정 구현 결함이 확정되지는 않는다.
- B 악화/C 저부하 정상: READY 소비 유무가 적체에 영향을 준다는 가설을 조사한다.
  필요하면 B/C를 같은 신규 유입·재고·VU 조건으로 추가 비교한다. C에는 DB 부하도 추가된다.
- k6가 먼저 불안정: 같은 서비스 자원을 유지하고 발생기만 분리한 비교가 우선이다.
  현 harness는 Docker 내부 호스트 이름과 로컬 fixture/관측에 결합돼 있어 다른 PC에서 명령만 복사해 실행할 수 없다.
  LAN 분리는 이후 별도 작업이며 이번에는 구현하지 않았다. 초기 로컬 원인 분리는 계속 가능하다.
- 서비스가 먼저 포화: poll 빈도/불필요한 작업을 줄이는 후보와 HTTP 연결·스레드 설정을 구분해서 조사한다.
  캐싱은 공통 catalog 등 허용 가능한 지연이 있는 읽기 대상부터 검토하고, 개인별 READY 상태를 그대로 캐시하지 않는다.

자원 한계 계산은 같은 안정 구간에서 `CPU 사용 시간 증가량 / 처리 요청 수 = 요청당 CPU 비용`을 구하고,
`join RPS × join CPU 비용 + poll RPS × poll CPU 비용 + 관측 등 비용`을 CPU quota와 비교한다.
혼합 구간만 있으면 endpoint별 비용을 분리 추정할 수 없으므로 분리 실험이 필요하다.
처리 중 평균 요청 수는 안정 구간에서 `L ≈ λ × 평균 응답 시간`으로 확인하되 p99를 평균 대신 넣지 않는다.
애플리케이션 응답 시간은 CPU 실행 시간과 다르다. 클라이언트·서버 평균의 차이만으로 Nginx 대기 시간을 확정하지 않는다.
현재 evidence에 CPU throttling·accept backlog를 직접 입증하는 지표가 부족하면 그 수집이 다음 최소 변경이다.
CPU 한도에 가까운 그래프만으로 scale-up이 유일한 해법이라는 결론은 내릴 수 없다.

## 6. 완료 조건과 포트폴리오 문장

원인을 좁힌 뒤 **한 번에 하나의 제품/설정 변인**을 수정하고, 동일 자원·유입·클라이언트 행동·seed·VU·예열 조건으로
수정 전후 각 3회 비교한다. 실험 중 발생기가 못 넣은 부하나 실패로 조기 종료해 줄어든 부하를 성능 향상으로 세지 않는다.
서버 retryAfter를 바꿨다면 그것이 의도한 변경임을 적고, HTTP 감소뿐 아니라 READY/HELD 달성·공정성·만료·반환 발견 지연도 확인한다.
그 후 Isolation, 정상 Business, 품절/반환·재시도 흐름을 다시 검증한다. A/B 통과는 5만 명 목표 달성의 충분조건이 아니다.

검증 후에만 채울 문장:

> 대기 등록·polling·READY 소비를 분리해 [원인]을 확인하고 [변경]을 적용하여, 동일 [자원/유입]에서
> [오류율·p99·HTTP 요청량]을 [전→후]로 개선하면서 [READY/HELD 처리와 정합성·반환 지연]을 유지했다.

현재 쓸 수 있는 범위는 **원인 분리용 실험 및 판정 체계를 마련했다**까지다. 아직 성능 개선 수치를 주장하지 않는다.

### 부하 없는 회귀 검사

```powershell
node --experimental-vm-modules ops/performance/target-static-test.mjs
pwsh -NoProfile -File ops/performance/target-command-test.ps1
pwsh -NoProfile -File ops/performance/target-review-test.ps1
pwsh -NoProfile -File ops/performance/target-lifecycle-test.ps1
```

가짜 HTTP/Docker/시계 또는 임시 fixture를 쓰는 offline 검사다. 실제 k6/DB 부하 검증을 대체하지 않는다.
