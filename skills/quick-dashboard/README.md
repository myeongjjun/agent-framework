# 📊 Quick Analytics Dashboard Builder

데이터 소스만 말하면 즉시 실행 가능한 Streamlit 대시보드를 만들어주는 Claude 스킬입니다.

## 설치

이 폴더를 스킬 디렉토리에 복사:

```bash
# Codex (개인)
~/.codex/skills/quick-dashboard/

# Claude (개인)
~/.claude/skills/quick-dashboard/

# Codex (프로젝트)
.codex/skills/quick-dashboard/

# Claude (프로젝트)
.claude/skills/quick-dashboard/
```

## 사용법

Claude에게 이렇게 말하세요:

```
"[데이터 소스]에서 [분석 내용]을 대시보드로 만들어줘"
```

## 예시

```
"여러 ES 클러스터의 인덱스 용량을 날짜별로 비교하는 대시보드 만들어줘"

"PostgreSQL DB들의 테이블 크기를 비교하는 앱 만들어줘"

"API 엔드포인트 응답시간을 실시간 모니터링하는 대시보드 만들어줘"
```

## 지원 데이터 소스

- REST API
- Elasticsearch
- PostgreSQL, MySQL
- Redis, MongoDB
- ClickHouse, Prometheus
- CSV, JSON 파일

## 실행

```bash
cd [프로젝트명]
uv run streamlit run app.py
```
