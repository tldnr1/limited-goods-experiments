# 실험 분석 목록

새 분석은 이 폴더에 두고 원본 artifact를 링크한다. 기존 artifact와 함께 보관된 분석은 원래 위치를 유지한다.
당시 코드·SLO·workload와 현재 계약을 구분하며 실패 실행도 보존한다.

| 실행 / 범위 | 분석 | 해석 |
|---|---|---|
| 2026-09-13 Target Warmup | [사전 거래 비교](warmup-20260913-review.md) | 사전 거래 1건 후 272/272 확정, Hikari timeout 13→0. 다음은 Worker 측정 |
| 2026-09-12 Target Warmup | [첫 Warmup 분석](warmup-20260912-review.md) | 272회 도착, Payment 초기 오류. 건수 판정 수정과 서비스 실패 분리 |
| 2026-09-11 cold Worker | [실행 분석](../../artifacts/target-v1/20260911-worker-diagnosis/review.md) | old SLO/no warmup. 새 steady-state capacity 결과 아님 |
| 2026-09-11 observer 실패 | [실패 artifact 안내](../../artifacts/performance/README.md) | k6 시작 전 경로 오류, 서비스 성능 결과 아님 |
| 2026-09-11 harness 준비 / 반복 실행 | [준비](../../artifacts/target-v1/20260911-harness-preparation/review.md), [반복 실행](../../artifacts/target-v1/20260911-repeatability/review.md) | 당시 offline 검증 범위 |
| 2026-09-10 Target 기능 | [기능 검증](../../artifacts/target-v1/20260910-functional/review.md) | DB/Redis 테스트·소량 smoke, capacity 측정 아님 |
| 2026-09-08~09 Java baseline | [기능·실행 이력](java-baseline-history.md), [실행 목록](../../artifacts/performance/README.md), [Worker capacity 결과](../../artifacts/performance/20260909-230854-201-baseline-capacity/capacity-result.json) | 저부하 flow 성공 및 기존 Worker 병목 |

이전 Java/Python 실험의 원본 commit과 주장 범위는 [portfolio ledger](../portfolio/portfolio-evidence.md)에서 확인한다.
