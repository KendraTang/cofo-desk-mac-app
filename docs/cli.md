# COFO Desk CLI

Python 命令列工具提供 BLE 掃描、GATT 檢視、狀態、限時升降、指定高度與停止。BLE UUID／指令來自原 App 1.0.10 的 [REA 分析](reverse-engineering.md)；軟體流程與模擬裝置已驗證，真桌相容性仍待驗收。工具使用 Mac 本機的 Bluetooth，不透過 Android 模擬器控制桌子。

## 安裝與快速試用

需求 Python 3.11 以上。本次測試為 macOS arm64、Python 3.14.8；其他 OS／Python 版本尚未執行驗證。模擬器的跨程序鎖使用 POSIX `fcntl`。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[ble]'
source .venv/bin/activate
cofo-desk --version
cofo-desk --help
```

只操作模擬裝置時不需 Bleak，也可直接在 repo 執行：

```sh
python3 -m cofo_desk --json --simulate --state-file /tmp/cofo-demo.json status
python3 -m cofo_desk --simulate --state-file /tmp/cofo-demo.json goto 80
python3 -m cofo_desk --simulate --state-file /tmp/cofo-demo.json down --seconds 0.5
python3 -m cofo_desk --simulate --state-file /tmp/cofo-demo.json stop
```

共用選項（`--json`、`--simulate`、`--device` 等）放在子指令之前。子指令自己的選項（`--seconds`、`--unit`、`--timeout`）放在子指令之後。

## BLE 操作

```sh
cofo-desk --json scan --seconds 5
cofo-desk --device 'UUID_FROM_SCAN' inspect
cofo-desk --device 'UUID_FROM_SCAN' status
cofo-desk --device 'UUID_FROM_SCAN' watch --seconds 10
cofo-desk --device 'UUID_FROM_SCAN' stop
cofo-desk --device 'UUID_FROM_SCAN' up --seconds 0.3
cofo-desk --device 'UUID_FROM_SCAN' goto 105 --unit cm --timeout 20
```

Mac 的裝置識別碼是 scan 回報的 peripheral UUID。其他系統可能回報藍牙位址。執行所在的終端機／App 必須有系統 Bluetooth 存取權；請先關閉其他連線同一張桌子的 App。

`scan` 列出周邊裝置，不要求名稱包含 COFO，也不把廣播的服務當作相容性證明。`inspect` 只連線讀取 GATT metadata，沒有 characteristic／descriptor 寫入。`status`／`watch` 會訂閱通知，執行已知的條件式登入及高度／限位查詢。

工具自動選擇唯一且具備所需 properties 的 `ff12`、`fe60` 或 `legacy` profile。若有多組，使用 `--profile ff12` 等明確指定；未知服務會回報錯誤。GATT 寫入逐一等待完成，依 characteristic properties 明確指定有／無 response；ATT 寫入成功不代表馬達執行完成。

Bleak 使用方式依據官方 [Client API](https://bleak.readthedocs.io/en/latest/api/client.html) 與 [Scanner API](https://bleak.readthedocs.io/en/latest/api/scanner.html)。相依範圍為 `bleak>=3.0.2,<4`，本次實際安裝 3.0.2。

## 指令與停止行為

| 指令 | 行為 |
| --- | --- |
| `scan --seconds 5` | 限時掃描，最長 30 秒 |
| `inspect` | 服務、characteristic UUID 與 properties，不需命中已知 profile |
| `status` | 一次高度、單位、限位、錯誤及樣本時間 |
| `watch --seconds 10` | 每 0.5 秒顯示狀態，最長 3600 秒 |
| `up/down --seconds 1` | 每 100 ms 重送方向指令；時間上限 30 秒，結束送 stop |
| `goto 105 --unit cm --timeout 20` | 送一次毫米目標，等待通知進入容差後送 stop；逾時上限 120 秒 |
| `stop` | 連線與 profile 探索後立即送 stop；裝置有登入 service 時再送登入與第二次 stop，不等待通知或初始化查詢 |

移動前必須收到新高度與旅行限位，且沒有已回報錯誤。移動中高度超過 1.5 秒未更新、故障、逾時或中斷訊號都會離開控制迴圈，嘗試送 stop 後斷線；斷線可能讓 stop 無法送達，錯誤會保留這項資訊。連線中斷的實體停止保證仍須硬體驗證。

`up`／`down` 在高度距離限位 1 mm 內就停止送方向指令；移動前與移動中的檢查容許回報高度超出限位 3 mm，以吸收換算與取樣誤差。這兩個是軟體容差，不代表硬體限位保證。

### 獨立 `stop` 的登入次序

原 App 送任何控制指令前都會先嘗試登入，但登入是否為 STOP 的必要條件尚未用真桌證實。為了不讓登入延後 STOP，也不讓登入失敗擋住 STOP，`stop` 依序執行：

1. 立即送 STOP。
2. 若裝置有登入 service，送登入寫入（`--login-timeout`，預設 1 秒，最多 10 秒）。
3. 再送一次 STOP。

沒有登入 service 時只送一次 STOP。第一次 STOP 被拒、登入失敗或逾時，都不會跳過最後一次 STOP；連線已斷時，剩下的步驟記為未執行，不自動重連重播。輸出的 `steps` 逐步列出結果；登入寫入完成不代表登入成功。全部 STOP 都沒寫入成功時，指令以錯誤結束。這個次序只通過 fixture 測試，真桌相容性仍待驗證。

### 中斷訊號

SIGINT（Ctrl-C）、SIGTERM 與 SIGHUP（關閉終端機）都走同一條清理路徑：第一個訊號取消目前操作，移動中會嘗試送 STOP，再斷線。清理期間收到的後續訊號只記錄，不會打斷 STOP 或斷線；STOP 寫入最長 3 秒、斷線最長 5 秒，不重試。SIGKILL 等無法攔截的終止不保證送出 STOP 或輸出結果。

中斷輸出包含：

- `stop_attempted`：是否真的開始寫入 STOP；在連線或尚未開始移動前中斷時為 false。
- `stop_write_completed`：是否有 STOP 寫入正常完成，失敗原因列在 `stop_errors`。無 response 的寫入完成也不等於裝置 ACK。
- `physical_stop_confirmed`：一律為 false，桌子實際狀態未知。
- `ignored_signals`：清理期間收到、只記錄未處理的訊號。
- `cleanup_errors`：STOP 或斷線失敗時的補充資訊。

`goto` 接受 cm／in／mm，轉成最接近的整數毫米，並檢查桌子回報的限位。完成表示觀察到高度在目標容差內（cm 通知 1 mm，in 通知 3 mm），不表示取得馬達停止 ACK。`stop_sent` 同樣只表示寫入完成，`physical_stop_confirmed` 為 false。

高度優先依 `--native-unit cm/in`，其次使用已回報單位，最後採原 App 的 raw 值門檻推斷（`>=550` 視為 cm）。輸出包含 `unit_source`，需要時明確覆寫。通知只解析原 App 已知且完整的欄位；未知／截斷資料不會補成有效高度，不虛構 checksum、跨通知重組或錯誤清除協定。這比原 App 嚴格：原 App 找到 `F201` 後，固定讀 length byte 之後的兩個 byte，不檢查宣告長度。例如 `F2F2010302D0` 宣告 3 byte、實際只有 2 byte，原 App 會顯示 72.0 cm，本工具則丟棄。若真桌確實會送這種封包，再依實機紀錄調整。錯誤在該連線內保留，重新連線不能據此判定實體故障已排除。

`limits_mm` 把 `F2 F2 07` 的兩個值當成 mm。依據是原 App 在單位換算、進度計算與推薦高度三處都把它們當 mm 使用（見 [REA 調查](reverse-engineering.md)）；這是靜態推論，尚未用真桌面板對照。

連線預設最長 10 秒、通知訂閱及初始化後等待 telemetry 各預設 3 秒，可用 `--connect-timeout`（最多 60）及 `--telemetry-timeout`（最多 30）調整。單次寫入最長 3 秒。`stop` 不等 telemetry，但仍需連線與 GATT 探索成功。

## JSON 與模擬狀態

`--json` 的單次指令輸出一個 JSON object；`watch` 輸出 JSON Lines。執行失敗輸出 `{"error": "..."}`，結束碼 1；參數錯誤為 argparse 訊息、結束碼 2；中斷時 SIGINT 為 130、SIGTERM 為 143、SIGHUP 為 129。狀態中的 `connected` 與 `sample_age_seconds` 是取樣當時的值，單次指令結束會關閉連線。

模擬模式一定要明確加 `--simulate`，所有輸出標示 `simulated`。模擬周邊和 BLE 共用相同的 profile 選擇、編碼、通知解析及控制流程；模擬生成的通知不是硬體證據。模擬周邊只接受完整且 checksum、結尾正確的指令封包。它收到 UP／DOWN 後會持續移動到 STOP 或限位，沒有模擬硬體漏收重送時的停止時限，因為這個時限尚無證據。模擬範圍 630–1280 mm、初始 720 mm、速度 35 mm/s。

模擬狀態只保存停止位置，不保存或恢復移動指令；與 Android App 資料互相獨立。預設檔案：

- macOS：`~/Library/Application Support/cofo-desk/simulator.json`
- 其他 POSIX：`${XDG_STATE_HOME:-~/.local/state}/cofo-desk/simulator.json`

建議測試／腳本使用 `--state-file` 指定隔離檔案。全程持有檔案鎖，同一份狀態的第二個程序會明確失敗；寫入採暫存檔替換。損壞的 JSON、非有限值或超限高度會拒絕載入，不覆寫原檔。

## 驗證

```sh
python3 -m unittest discover -s tests -v
```

61 個測試涵蓋協定固定向量、未知／截斷通知、profile／properties、條件式登入與初始化、訂閱／高度逾時、序列化寫入、限位／故障／舊高度拒絕、目標逾時、停止失敗、取消清理、獨立 stop 的登入次序、模擬器拒收錯誤封包、BLE 入口 mock、跨程序狀態、三種中斷訊號與重複訊號、純文字輸出及 JSON／結束碼。已另外實際安裝含 Bleak 的 package，驗證 console entry point 與 dependency consistency；沒有進行真桌連線或移動。
