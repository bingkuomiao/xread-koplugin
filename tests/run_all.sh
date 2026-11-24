#!/bin/bash
# xread.koplugin 自动测试统一入口（在 WSL Ubuntu 内运行）
# 用法：
#   bash tests/run_all.sh              # 全套（10 个用例，约 10 分钟）
#   bash tests/run_all.sh --quick      # 快速（仅语法+交付包一致性，秒级）
#   bash tests/run_all.sh --only 03_toolbar 04_catalog
# 每次运行独立归档到 tests/reports/<时间戳>/，含逐用例日志、截图与 SUMMARY.md。

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
RUN_DIR="$TESTS_DIR/reports/$(date +%Y%m%d-%H%M%S)"
export RUN_DIR
mkdir -p "$RUN_DIR"

MODE="${1:---full}"
if [ "$MODE" = "--quick" ]; then
    scripts=("$TESTS_DIR/cases/09_syntax.sh" "$TESTS_DIR/cases/10_package_consistency.sh")
elif [ "$MODE" = "--only" ]; then
    shift
    scripts=()
    for id in "$@"; do
        [ -f "$TESTS_DIR/cases/$id.sh" ] && scripts+=("$TESTS_DIR/cases/$id.sh") || echo "未知用例: $id"
    done
else
    scripts=("$TESTS_DIR"/cases/*.sh)
fi

PASS=0
FAIL=0
printf '# xread.koplugin 自动测试报告\n\n' > "$RUN_DIR/SUMMARY.md"
printf -- '- 时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$RUN_DIR/SUMMARY.md"
printf -- '- 模式：%s\n' "$MODE" >> "$RUN_DIR/SUMMARY.md"
printf -- '- 环境：WSL1 Ubuntu + KOReader 模拟器 1072x1448 dpi300\n\n' >> "$RUN_DIR/SUMMARY.md"
printf '| 用例 | 结果 | 说明 | 截图 |\n|---|---|---|---|\n' >> "$RUN_DIR/SUMMARY.md"

echo "Reports: $RUN_DIR"
echo "Cases: ${#scripts[@]}"

for script in "${scripts[@]}"; do
    id="$(basename "$script" .sh)"
    echo "---- $id ----"
    # 后端偶发挂起/环境抖动会导致单次失败，自动重试一次再判定
    attempt=1
    while [ "$attempt" -le 2 ]; do
        rm -f "$RUN_DIR/$id.status"
        bash "$script" > "$RUN_DIR/$id.runner.log" 2>&1
        rc=$?
        status="$(cat "$RUN_DIR/$id.status" 2>/dev/null || echo ERROR)"
        if [ "$status" = "PASS" ] && [ "$rc" -eq 0 ]; then break; fi
        if [ "$attempt" -eq 1 ]; then
            cp "$RUN_DIR/$id.runner.log" "$RUN_DIR/$id.attempt1.log" 2>/dev/null
            echo "  retrying $id (attempt 2/2)"
        fi
        attempt=$((attempt+1))
    done
    detail="$(grep '^RESULT:' "$RUN_DIR/$id.runner.log" 2>/dev/null | head -1 | sed 's/^RESULT: PASS$/PASS/')"
    [ -z "$detail" ] && detail="$status"
    [ "$attempt" -gt 1 ] && detail="已重试${attempt}次; $detail"
    shot="-"
    [ -f "$RUN_DIR/$id.png" ] && shot="[$id.png]($id.png)"
    if [ "$status" = "PASS" ] && [ "$rc" -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "  FAILED: $detail"
    fi
    printf '| %s | %s | %s | %s |\n' "$id" "$status" "$detail" "$shot" >> "$RUN_DIR/SUMMARY.md"
done

printf '\n合计：PASS=%d FAIL=%d\n' "$PASS" "$FAIL" | tee -a "$RUN_DIR/SUMMARY.md"
echo "Summary: $RUN_DIR/SUMMARY.md"
[ "$FAIL" -eq 0 ]
