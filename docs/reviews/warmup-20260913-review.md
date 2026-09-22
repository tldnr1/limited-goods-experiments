# 2026-09-13 사전 거래 추가 후 Warmup 통과

대상: [20260913-022723-330-target-warmup-normal](../../artifacts/performance/20260913-022723-330-target-warmup-normal/result.json).
실행 코드는 `f62dfe0`이다. 사용자가 실행한 결과를 파일로 분석했으며 추가 부하·Docker 명령은 실행하지 않았다.

## 변경 전후

비교 대상은 [두 번째 실패 실행](../../artifacts/performance/20260912-223508-886-target-warmup-normal/result.json)이다.
JAR SHA256은 동일하고 Payment 0.25 CPU / 384MiB / pool 4, Mock PG delay 0 및 2→5→10→10/s 각 10초 부하는 유지됐다.
이번에는 정상 거래 한 건을 먼저 실행·확정·정리했다. 아래 수치에 그 한 건은 포함하지 않는다.

| 항목 | 사전 거래 없음 | 사전 거래 추가 |
|---|---:|---:|
| 실제 시작 / 완료 | 273 / 273 | 272 / 272 |
| Payment 202 응답 | 260 | 272 |
| Payment HTTP 500 / client timeout (재시도 포함) | 13 / 4 | 0 / 0 |
| Payment Hikari timeout delta | 13 | 0 |
| 최종 확정 / 실제 시작 | 262 / 273 | 272 / 272 |
| 미확정 점유 | 11 | 0 |
| 성공한 Payment 202 p95 | 158.70ms | 88.16ms |
| 성공한 Payment 202 max | 1136.45ms | 177.80ms |
| dropped iterations | 0 | 0 |

근거: 각 실행의 k6-summary.json, boundary-before/after.json, after-db.json.
새 실행 raw.json의 endpoint/status 집계에서 구매 201=272, 구매 429=11, Payment 202=272다.
429는 재시도 후 모두 구매 완료됐으며 예상 밖 오류는 0이다. 성공 응답 지연만의 비교에는 기존 실패 요청이 제외되므로 오류·완료율을 함께 제시한다.
실제 도착 수의 차이는 허용된 시나리오 경계 차이이며 270건으로 고정해 판정하지 않았다.

## 사전 거래의 비용과 데이터 분리

[priming 결과](../../artifacts/performance/20260913-022723-330-target-warmup-normal/priming/result.json)는 통과했다.
결제 HTTP 응답은 3.069초, k6 사용자 흐름은 6.429초였다. 이 흐름은 결제 접수까지이며 최종 확정은 harness가 별도로 확인한다.
timeline의 terminal_at은 priming 측정 시작 약 7.544초 뒤다(애플리케이션 전이 시각이며 DB commit timestamp는 아님).
priming 시작부터 비교 warmup 시작까지는 수집·정리·다음 fixture 준비를 포함해 약 21.291초가 추가됐다.

priming과 warmup의 네 DB 역할 Hikari timeout delta는 모두 0이다. cleanup-state의 주문/시도/판매 재고 목록은 비었고,
warmup에는 별도 판매의 272건만 남았다. priming 전부터 warmup 후까지 컨테이너 ID·시작 시각·restart count는 동일하며 OOM은 없다.
불변식·성공 deadline 위반은 0, 최종 pending=0이다. warmup 공급 구간 DB 표본은 pending 최대 1, oldest pending age 최대 0.168초다.
표본 간격은 약 5~6초이므로 순간 최댓값이나 지속 capacity를 인증하는 수치는 아니다.

## 판단과 다음 단계

작은 사전 실행을 추가한 조건에서 초기 실패가 사라졌다는 가설을 지지하는 첫 결과다.
초기 비용 자체는 사라지지 않았고 사전 거래에서 느린 결제 응답으로 관측됐다.
사전 거래와 추가 경과 시간이 함께 달라졌으며, 단일 비교·공유 호스트·DB/OS 캐시 조건이므로 JIT 단독 원인이나 효과의 재현성을 확정하지 않는다.
이번 통과는 자원 증설 없이 다음 측정으로 진행할 근거이며 최대 처리량 달성 주장이 아니다.

코드·자원·JIT 추가 변경 없이 기존 Worker 10/s·120초 측정으로 진행한다. 다음 명령은 사용자가 Git Bash에서 실행한다.
기존 Target 환경이 준비돼 있다면 Prepare/재빌드는 불필요하다. priming과 warmup은 자동 수행된다.

```bash
pwsh -NoProfile -File ./ops/performance.ps1 -Mode target -Action Run -Reset -Scenario worker -Rps 10 -DurationSeconds 120 -Vus 10 -MaxVus 50
```

다음 결과에서는 접수 p95·오류, accepted/confirmed 처리율, 공급 중 backlog/age, 개별 SUCCESS deadline과 drain을 확인한다.
실패 원인이 새로 확인되기 전까지 추가 최적화는 하지 않는다.
