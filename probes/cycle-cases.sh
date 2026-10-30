#!/bin/bash
# Walkthrough of the sit and stand cycle on the real desk. The countdowns are set to two hours so the
# desk only moves when a step triggers it (SIGUSR1). Leaving the script any way, including Ctrl-C,
# reinstalls the daily setup. Run it from a regular terminal, not tmux, so codesign can reach the
# keychain. Writes a marker into the agent log before each step, then copies the log to probes/out/.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"
DESK=(--cofo-desk "$REPO/.venv/bin/cofo-desk" --device 24793885-E0D3-DAA3-9DD8-4271F4793A63)
mark() { printf '{"event":"case","case":"%s","time":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
wait_enter() { read -r -p "   $1 " _ < /dev/tty; }
step() { echo; echo "== $1"; echo "   $2"; wait_enter "(Enter)"; mark "$1"; }
trigger() { launchctl kill SIGUSR1 "gui/$(id -u)/dev.cofodesk.timer-desk"; }
daily() {
    echo
    echo "換回日常設定：坐 25 分鐘、站 10 分鐘、Clock 連動開啟。"
    "$REPO/timer-desk/install.sh" "${DESK[@]}" --clock
}

echo "先關掉手機的 COFO App，清空桌面，把桌子降到 M2。"
wait_enter "好了按 Enter。"
trap daily EXIT
LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$REPO/timer-desk/install.sh" "${DESK[@]}" --sit-after 7200 --stand-after 7200 --snooze 7200 || exit 1
echo "連線中，最多等 30 秒⋯⋯"
for _ in $(seq 30); do
    tail -n +$((LINES + 1)) "$LOG" | grep -q desk-session-ready && break
    sleep 1
done
if ! tail -n +$((LINES + 1)) "$LOG" | grep -q desk-session-ready; then
    echo "連不上桌子，結束測試。最近的紀錄："
    tail -n +$((LINES + 1)) "$LOG" | tail -5
    exit 1
fi
echo "連上了。選單列應該顯示 ↑ 和兩小時左右的倒數，它在步驟之間不會動。"

step "1. 升起" "桌子會小動一下，3 秒後升到 M1。按 Enter 開始，過程中不要碰面板。"
trigger
wait_enter "桌子停在 M1 後，按 Enter。"

step "2. 降下" "桌子會小動一下，3 秒後降到 M2。按 Enter 開始，過程中不要碰面板。"
trigger
wait_enter "桌子停在 M2 後，按 Enter。"

step "3. 取消" "桌子會小動一下。看到它動，就在 3 秒內按一下面板的 M2。桌子不應該升上去。按 Enter 開始。"
trigger
wait_enter "按完之後，按 Enter。"

step "4. 沒人時不動" "按 Enter 後，70 秒內不要碰鍵盤和滑鼠。時間到桌子應該不動，選單列顯示「等你回來」。"
sleep 70
trigger
sleep 5
wait_enter "現在動一下滑鼠，桌子應該小動一下再升到 M1。停好後按 Enter。"

step "5. 手動切換" "在面板按 M2 降下來。選單列的箭頭應該從 ↓ 變成 ↑，開始新的倒數。按 Enter 繼續。"

mark end
mkdir -p "$DIR/out"
cp "$LOG" "$DIR/out/cycle-cases.log"
echo "紀錄存到 $DIR/out/cycle-cases.log"
