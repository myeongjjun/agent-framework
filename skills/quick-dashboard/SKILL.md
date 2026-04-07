---
name: quick-dashboard
version: 1.0.0
description: 데이터 소스만 말하면 즉시 실행 가능한 Streamlit 대시보드 생성. 대시보드, 분석, 시각화, 모니터링 요청 시 사용.
---

# Quick Analytics Dashboard Builder

사용자가 데이터 분석/시각화/대시보드/모니터링을 요청하면 이 스킬을 적용한다.

---

## 핵심 원칙

1. **즉시 실행 가능** - 생성 후 바로 `uv run streamlit run app.py` 실행 가능해야 함
2. **요구사항 맞춤** - 범용 템플릿 복붙 X, 사용자 요청에 딱 맞는 코드
3. **연결 정보 보호** - credentials 하드코딩 금지, 사이드바에서 입력받음

---

## 실행 절차

### 1단계: 프로젝트 초기화

```bash
uv init [project-name]
cd [project-name]
uv add streamlit plotly pandas requests
```

데이터 소스별 추가 패키지:
- PostgreSQL: `uv add psycopg2-binary`
- MySQL: `uv add pymysql`
- MongoDB: `uv add pymongo`
- Redis: `uv add redis`
- Elasticsearch: `uv add elasticsearch`
- ClickHouse: `uv add clickhouse-connect`

### 2단계: app.py 생성

필수 구조:
```python
import streamlit as st
import pandas as pd
import plotly.express as px

st.set_page_config(page_title="대시보드", layout="wide", page_icon="📊")

# 사이드바: 연결 정보 입력 (st.sidebar)
# 메인: 필터 + 차트 + 테이블
# 하단: CSV 다운로드 버튼
```

### 3단계: 실행 안내

```bash
uv run streamlit run app.py
```

---

## 앱 구조 가이드

### 사이드바 (데이터 소스 관리)
- 연결 정보 입력 폼
- 여러 소스 등록 시 JSON 일괄 등록 지원
- 연결 테스트 버튼

### 메인 영역
- **필터**: 날짜 범위, 검색, 정렬
- **탭**: 전체 비교 | 개별 상세
- **차트**: Plotly 사용 (bar, line, pie 등)
- **테이블**: st.dataframe으로 데이터 표시

### 에러 처리
- 연결 실패: 친절한 오류 메시지 + 재시도 버튼
- 데이터 없음: 빈 상태 안내
- try/except로 앱 크래시 방지

---

## 예시 매핑

| 사용자 요청 | 생성할 것 |
|-------------|-----------|
| "ES 클러스터 인덱스 용량 분석" | ES 연결, 인덱스 목록 조회, 용량 차트 |
| "PostgreSQL 테이블 크기 비교" | DB 연결, pg_total_relation_size 쿼리, 비교 차트 |
| "API 응답시간 모니터링" | requests로 주기적 호출, 시계열 차트 |
| "Redis 키 분석" | redis-py 연결, SCAN으로 키 조회, 패턴별 분류 |
| "CSV 파일 시각화" | 파일 업로드, pandas 처리, 자동 차트 추천 |

---

## 하지 말 것

- ❌ 불필요한 설명 없이 코드만 생성
- ❌ 복잡한 클래스 구조 (간단한 함수 기반으로)
- ❌ 외부 설정 파일 요구 (모든 설정은 UI에서)
- ❌ 인증 정보를 코드에 하드코딩
