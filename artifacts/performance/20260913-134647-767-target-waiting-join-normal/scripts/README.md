# Target 실험 코드

실행 진입점은 저장소 루트의 `ops/performance.ps1 -Mode target`이다.
아래 파일을 직접 k6로 실행하면 fixture·예열·관측·정리 계약이 빠지므로 일반 실행은 진입점을 사용한다.

| 구분 | 코드 / 안내 |
|---|---|
| 사전 거래·단계형 예열 | `priming.js`, `warmup.js` |
| 결제 수락·Worker | `worker.js` |
| Waiting 원인 분리 및 개선 전후 비교 | [waiting-v2](waiting-v2/README.md) |
| READY 소비·DB 점유 | `reservation.js` |
| 역할 간 간섭 / 최종 사용자 흐름 | `isolation.js`, `business.js` |
| 공통 HTTP·사용자 행동·지표 | `common.js` |

`waiting.js`는 과거 경로 호환용이며 실제 구현은 `waiting-v2/unused-ready.js`다.
`waiting-v2`는 제품 버전이 아니라 이번 실험 묶음이다. 기존 Waiting 요청 동작은 바꾸지 않았다.
Reservation 등 재사용 가능한 시나리오를 복제하거나 다른 폴더로 일괄 이동하지 않는다.

실행기·관측·결과 판정과 offline 회귀 검사는 `ops/performance/target-*.ps1`에 유지한다.
실행 결과는 기존 `artifacts/performance/<시각>-target-<scenario>-<variant>/`에 계속 저장한다.
스크립트 트리를 하위 폴더까지 복사하고 `config.json.scriptPath`로 실제 진입 파일을 기록한다.
과거 artifact 안의 스크립트·경로·로그는 당시 재현 근거이므로 이동하거나 갱신하지 않는다.
