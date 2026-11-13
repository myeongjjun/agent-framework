#!/usr/bin/env bash
# Sessions 패널 토글: 이미 보이면 닫고, 아니면(닫힘·다른 모드) Sessions 패널로 연다.
CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux
mode=$("$CMUX" right-sidebar mode 2>/dev/null)
if [[ $mode == *'"mode":"custom-sidebar"'* && $mode == *'"visible":true'* ]]; then
  exec "$CMUX" right-sidebar hide
fi
exec "$CMUX" right-sidebar set custom sessions
