# 문서 안내

현재 계약과 실행 절차, 특정 실행의 분석, 포트폴리오 주장을 구분해 관리한다.
명령은 별도 설명이 없으면 저장소 루트에서 실행한다.

| 목적 | 문서 |
|---|---|
| 비즈니스 계약 / 트랜잭션 설계 | [PROJECT](../PROJECT.md), [DESIGN](../DESIGN.md) |
| 현재 성능 목표·자원·검증 상태 | [performance](performance.md) |
| 코드 읽기 | [learning](learning.md) |
| 역할·상태·데이터 구조 | [Target v1](architecture/target-v1.md), [부하 흐름](architecture/target-v1-load-scenario.md), [데이터 관계](architecture/domain-model.md), [구매·결제 상태](architecture/purchase-flow.md) |
| 실행·진단 절차 | [Target 부하 가이드](guides/target-v1-load-guide.md), [baseline 가이드](guides/load-test-guide.md), [baseline 진단](guides/diagnostics.md) |
| 이번 Waiting 원인 분리·수동 실행 | [Waiting v2](../k6/target/waiting-v2/README.md), [Target 실험 코드 목차](../k6/target/README.md) |
| 실험 분석 | [분석 목록](reviews/README.md) |
| 포트폴리오 | [발전 과정](portfolio/portfolio-evolution.md), [claim/evidence ledger](portfolio/portfolio-evidence.md) |
| 설계 결정과 변경 이유 | [ADR 목록](decisions/README.md) |

## 현재 검증 상태

- Java baseline의 예열 후 10 RPS/60초 성공과 기존 Worker 병목 관측은 과거 조건의 결과다.
- 2026-09-13 로컬 Warmup은 사전 거래 추가 후 272/272건 확정, Payment Hikari timeout 0건이었다.
- 이후 로컬 Worker 10/s·120초는 1,201건 수락/확정, 자동 검사 통과이나 지속 용량은 반복·수동 검토가 필요하다.
- 로컬 Waiting 100명/s·60초는 dropped 및 HTTP 오류로 실패했다. DB 경쟁 구매의 정합성을 검증한 실행은 아니다.
- 이번 Waiting v2는 등록만/READY 미사용/실제 소비를 분리한 실험 준비다. 새 실제 부하와 제품 튜닝은 아직 수행하지 않았다.
- 위 로컬 실행 ID·해석·다음 명령은 Waiting v2 안내에 있다. 과거 Warmup 실패 기록은 당시 조건의 evidence로 보존한다.

날짜가 있는 실행 기록과 artifact는 당시 조건을 설명한다. 현재 SLO와 혼동하지 않고,
최신 상태는 이 목차와 performance, 실행 방법은 guides, 주장 가능 범위는 portfolio ledger를 따른다.
