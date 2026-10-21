# Clock 計時器自動升降桌

狀態：Gate 1、Gate 2 通過，下一步 Gate 3 桌子串接；本輪目標做到 Gate 3。最後更新：2026-10-21。

這份取代 2026-10-20 的 agent 規格。主要差異是：前版要求「使用者按下確認才升降」並要做 Menu Bar App；本版改為點動預告加上實體鍵取消窗口，也不做 GUI。理由見[與前版的差異](#與前版的差異)。

## 目標

使用者在 Mac 上用 Apple 時鐘（Clock）的計時器做 25 分鐘番茄鐘。計時自然完成時，桌子先點動預告；使用者沒有取消就升到站姿。自動升起後 15 分鐘使用者仍沒有自己調整，就用同樣的方式降回坐姿。使用者操作 Clock 的習慣不變。

**非目標**：重做番茄鐘、GUI、寫入桌子 M 鍵（另外開研究，見[後續](#後續本輪不做)）、Garmin、截圖或 OCR、規避 macOS 權限。

## 行為

### 自動升起

1. 只有**自然完成**且原始長度約 25 分鐘（可設定，測試時可另外加 10 秒）的計時器會觸發。取消、暫停或其他長度都不觸發。
2. 桌子已在站姿高度（M1 ±1 cm）就不動。
3. 向上點動約 2 cm 當預告。
4. 取消窗口 10 秒（可設定）：持續監看高度。出現不是本程式造成的高度變化，也就是使用者按了實體鍵，就放棄這次升起。
5. `goto` M1 高度。記錄「這次是自動升起」以及實際到達的高度。

### 自動下降

1. 只有自動升起的那次會排程，15 分鐘後執行（可設定）。使用者手動升起的不排程。
2. 時間到時重新連線並讀一次高度。如果跟自動升起時到達的高度差超過 1 cm，就當作使用者已經調整過，不動。已知限制：降下後又升回原高度，會被當成沒動過。
3. 向下點動約 2 cm → 10 秒取消窗口 → `goto` M2 高度。

待降期間如果又有計時完成，因為桌子已在站姿，不會再升起；原本的下降排程照舊。

### 安全

- **沒有確認步驟是刻意的決定**：用點動預告和取消窗口代替確認。實體鍵與 STOP 永遠優先。
- Mac 鎖定或睡眠時，升降都不執行，也不補發；待降的排程遇到鎖定直接取消，桌子留在高位，等使用者回來自己調。
- 程式重啟時，不恢復未完成的移動或排程，也不把舊的計時完成當成新事件。
- 同一時間只允許一個移動。連線失敗（例如手機 App 佔著連線、藍牙中斷）、高度不是新的、桌子回報故障，都不動。
- 沿用 `cofo_desk` 既有的保護：移動前必須有新高度和上下限；移動中 1.5 秒沒有新高度就送 STOP；收到中斷訊號時送 STOP。見 [CLI 文件](cli.md#指令與停止行為)。

### 回報

正常流程不跳任何通知（Clock 自己已經有通知）。只有「應該動卻沒動」或移動失敗時，才用 `osascript` 發一則沒有按鈕的系統通知，內容寫明原因。所有觀測、決策和錯誤都寫進 log，不記錄 UI 文字內容。

### 設定

設定檔包含：站姿 = M1、坐姿 = M2、觸發長度、取消窗口秒數、待降分鐘數、點動距離、裝置 UUID。高度每次都從桌子讀取，設定檔不存 mm 值。

## 架構

主程式用 Swift 寫，負責偵測與流程；桌子動作則以子程序呼叫本 repo 的 `cofo-desk` CLI，讀它的 JSON 與結束碼。程式由 LaunchAgent 在登入時啟動並常駐，不做 GUI。

選 Swift 的原因是偵測需要輔助使用權限。macOS 把權限記在發起的程式身上，由一個專用的程式持有輔助使用和藍牙權限，就不必把權限給整個 Python 直譯器。`cofo-desk` 子程序會沿用主程式的藍牙權限（見下方可行性表）。

程式用本機自簽憑證 `cofo-desk-auto local signing` 簽署（建立方式：`scripts/create-signing-identity.sh`），所以重新編譯後權限不必重給。Command Line Tools 的臨時簽署每次編譯都會改變身分。

```text
Clock（外部，計時的唯一依據）
  → TimerObserver（偵測來源可替換）
  → 正規化與去重
  → Coordinator（升降狀態機、鎖定判斷、下降排程）
  → DeskController（cofo_desk）
  → Reporter（log、失敗通知）
```

偵測和桌子控制分開。單元測試使用假的計時觀測和 `cofo-desk --simulate`；整合測試才連真桌。

程式在 [`timer-desk/`](../timer-desk)：

```sh
timer-desk/test.sh                                 # 單元測試（含用真實紀錄重播）
timer-desk/install.sh --length 10 --length 1500    # 編譯、簽署並載入 LaunchAgent
tail -f ~/Library/Logs/timer-desk.log              # JSON Lines 事件紀錄
timer-desk/uninstall.sh                            # 停止並移除 LaunchAgent
```

不加 `--cofo-desk` 時只記錄事件，計時完成時寫 `"decision": "would-raise"` 或 `"ignore"` 及原因。加上 `--cofo-desk PATH --device UUID` 後會真的升降；`--simulate-state FILE` 改用模擬桌。其他參數：`--stand`／`--sit`（預設 M1／M2）、`--nudge`（mm）、`--window`、`--lower-after`（秒），以及測試用的 `--test-raise`（啟動後立刻升一次）。設定都寫在 LaunchAgent 的參數裡，沒有另外的設定檔。

新的執行檔第一次啟動時，要在「輔助使用」清單中允許 `timer-desk`；第一次控制桌子時要允許藍牙。

點動用 `goto 目前高度 ± 20 mm`，桌子會自己減速停下；取消窗口用 `watch`，第一筆高度當基準，變化超過 5 mm 就當作按了實體鍵，結束 `watch` 並放棄。鎖定時對執行中的 `cofo-desk` 送 SIGTERM，移動中會送 STOP。

## Gate 1 可行性

環境：macOS 26.6.2（25G83）、arm64、Swift 6.3.2（只有 Command Line Tools，沒有 Xcode）、repo 的 `.venv`。系統語言為 `en-TW`。

| 能力 | 狀態 | 證據與說明 |
| --- | --- | --- |
| Clock 計時的 App Intents | Verified（靜態） | `MobileTimerSupport.framework` 的 `Metadata.appintents` 列出 Start、Get Current、Pause、Resume、Cancel Timer，全部是 `isDiscoverable: true`，除了 Start 之外的四個只標註 watchOS obsoleted |
| A：Shortcuts 取得目前計時器 | Unsupported（UI） | 2026-10-21 在 Shortcuts 搜尋 `timer` 和 `get current`，Clock 只出現 Start Timer。metadata 有，但 Shortcuts 沒有提供這個動作；原因不明 |
| Get Current Timer 的輸出 | 只有靜態證據 | metadata 的 `outputType` 是 duration measurement，看起來只有一個時間長度，沒有狀態或原始長度。就算能用，也很可能分不出暫停或完成，也篩不出 25 分鐘 |
| B：輔助使用讀取選單列 | Verified | Control Center（`com.apple.controlcenter`）的選單列項目 `AXIdentifier = com.apple.menuextra.timer`，`AXValue` 是 `"2:53"` 這類剩餘時間，每秒更新。Clock App 結束後照樣更新。兩個螢幕各有一份 |
| B：閒置、暫停、取消、完成的區分 | 部分 Verified | 四種狀態的 `AXValue` 都是 `"0:00"`。自然完成是 `0:01 → 0:00`；暫停和取消是從中途的數值直接跳到 `0:00`；恢復時從暫停前的數值接著倒數。暫停和取消要等到一直沒恢復才分得出來。已知漏洞：剛好在 `0:01` 暫停，會被當成完成 |
| B：訂閱數值變化 | Unsupported | `AXObserverAddNotification(kAXValueChangedNotification)` 回傳 -25207（notification unsupported），只能輪詢。0.5 秒輪詢的偵測延遲在 1 秒內 |
| B：螢幕鎖定時讀取 | Verified | 鎖定期間選單列照常讀得到，計時完成會記錄，並因 `screen-locked` 而忽略 |
| B：睡眠、重新登入、UI 語言、隱藏選單列項目 | Unverified | 睡眠跨過到期的情況已有單元測試，尚未實機測 |
| C：Clock 通知偵測 | Unverified | 下一步 |
| 推定計時器的原始長度 | 部分 Verified | 選單列沒有原始長度，只能用開始後第一次看到的數值：10 秒計時器第一個值是 `0:09`，且維持約 2 秒。程式啟動時如果計時器已經在跑，就不知道原始長度，這種情況不觸發。25 分鐘的實際數值未測 |
| 桌子 M1／M2 高度可讀 | Verified | 每次送出上下限查詢（`F1 F1 07`）後都會收到 `25`／`26`／`27`／`28`。按 M1 停在 959（`25` = 959，面板顯示 96）；按 M2 停在 631（`26` = 631，面板顯示 63）。`27` = 1280、`28` = 0，沒有按 M3，所以尚未證實 |
| 手動按鍵即時送出高度 | Verified | 面板移動期間每 0.1–0.3 秒有一筆高度通知，不會中斷；靜止時間隔最長 4.4 秒。M1 移動約 33 mm/s |
| LaunchAgent 下的權限 | Verified | 2026-10-21 用 [perm-probe](../probes/perm/run.sh) 測試：launchd 啟動的簽署程式在授權後 `AXIsProcessTrusted = true`，並讀到正在跑的計時器 `23:17`。它啟動的 `cofo-desk status` 透過藍牙讀到真桌 631 mm。重新編譯並用同一張自簽憑證簽署後，不需要重新授權。第一次編譯時，codesign 讀取私鑰要在鑰匙圈視窗選「永遠允許」 |

Clock 證據：[選單列 probe](../probes/ax-timer-watch.swift) 錄下的 [四組 10 秒計時](../probes/out/ax-timer-cases.log)（自然完成、暫停後恢復、取消、連續兩次），以及 [AX 樹狀結構 probe](../probes/ax-dump.swift)。

桌子證據：[panel keys log](hardware-evidence/2026-10-21-panel-keys.log)，用 [script](hardware-evidence/2026-10-21-panel-keys.sh) 錄製。這個 script 只監看，不送移動指令。

**Gate 1 結論（2026-10-21）**：可以在不改變使用習慣的前提下偵測 Clock 計時自然完成，方法是每 0.5 秒輪詢 Control Center 選單列的計時器項目。已知限制：

- 剛好在 `0:01` 暫停，會被當成完成；之後的點動預告和取消窗口可以擋下。
- 原始長度只能從第一次看到的數值推定；程式啟動時計時器已經在跑，就不觸發。
- 睡眠、重新登入、UI 語言和隱藏選單列項目尚未實機測試。

### 測試矩陣

每條偵測路線都要評估：

| 情境 | 期望 |
| --- | --- |
| 10 秒計時自然完成 | 恰好一次完成事件 |
| 25 分鐘自然完成 | 同上，記錄延遲（目標 5 秒內，這是工程目標，不是 API 保證） |
| 其他長度自然完成 | 不觸發 |
| 中途取消 | 不觸發 |
| 暫停超過原定到期時間後再恢復 | 暫停期間不觸發 |
| 完成後立刻重新開始 | 兩次不混淆，不重複觸發 |
| 到期通知沒顯示、勿擾模式 | 記錄能否偵測 |
| 睡眠跨過到期時間、鎖定 | 不動，不補發 |
| 監測程式重啟 | 不把舊狀態當成新的完成 |
| 其他 App 發出通知 | 不誤判 |
| 權限被拒、UI 讀不到 | 失敗通知，不動 |
| 藍牙中斷、手機 App 佔用連線 | 失敗通知，不宣稱成功 |

## Gates

1. **可行性**：回答「能不能在不改變使用習慣的前提下，偵測 Clock 計時自然完成並篩出 25 分鐘」。三條路都不行就停下回報，一起決定備援方案，不自行替換使用者的工作流程。
2. **偵測原型**：只寫 log、不動馬達。10 秒計時自然完成恰好一次事件；取消、暫停、鎖定、重啟都不誤觸發。
   2026-10-21 通過，用 [gate2-cases.sh](../probes/gate2-cases.sh) 實測，紀錄在 [gate2-cases.log](../probes/out/gate2-cases.log)：10 秒自然完成 → `would-raise`；20 秒 → `length-mismatch`；暫停後恢復 → 一次 `would-raise`（暫停時讀到 8、恢復時讀到 7，靠 ±1 容差接上）；取消 → 只有 `stopped`；鎖定 → `screen-locked`；計時中途重啟 → `length-unknown`。睡眠跨過到期的情況沒有實測。
3. **桌子串接**：在真桌上完整跑過點動、窗口取消、升起、15 分鐘後下降與「已手動調整就不降」；失敗時跳通知。
4. **長期試用**（本輪不做）：多輪 25 分鐘實際使用，量測延遲、漏報與誤報。

## 與前版的差異

2026-10-21 與使用者確認：

- 移除「確認後才升降」。Clock 本身已經有通知，不需要第二層確認；改用點動預告與實體鍵取消。
- 新增自動下降：只針對自動升起的那次，15 分鐘後執行，使用者已調整就不降。
- 不做 Menu Bar App 與確認通知，只在失敗時通知。
- 高度以桌子 M 鍵為準：M1 站、M2 坐。
- 「已經存在的升降桌 script」就是本 repo 的 `cofo-desk`。
- 偵測改用 Control Center 選單列的計時器項目（方案 B）；Shortcuts 沒有提供讀取計時器的動作。
- 主程式用 Swift，原因見[架構](#架構)。

## 後續（本輪不做）

- 寫入桌子 M 鍵：目前沒有已知封包，原 App 也不使用。可以先用 REA 分析其他 Jiecang App，找到後再到真桌驗證。
- 每兩輪提醒離開座位走動、依閒置或會議狀態判斷是否觸發、Garmin。
