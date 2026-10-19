#!/bin/bash
# 实时查看 TBOX 日志
echo "=== TBOX 实时日志 ==="
echo "按 Ctrl+C 退出"
echo ""
log stream --predicate 'subsystem == "com.tbox.app"' --level debug
