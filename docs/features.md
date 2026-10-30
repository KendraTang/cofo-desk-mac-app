# COFO Desk 功能盤點

原始資料（REA Evidence、原 App 畫面與商店截圖）不放在公開 repo，存在維護者本機的 `local_docs/reverse-engineering/`；下文以 `資料夾/檔名` 註明出處。需要時可用 REA 重新分析原 APK 取得。

2026-10-20。目標為模擬器從 Google Play 安裝的 `com.jiecang.app.android.cofodesk` **1.0.10 / versionCode 15**。先前的公開截圖盤點已補上原 App 操作與 REA 靜態分析。本文件列出已發現功能及證據範圍；尚未宣稱已窮盡所有執行期／硬體行為。

## 證據來源

- **D／S**：官方文字／官方截圖。Android：[Google Play](https://play.google.com/store/apps/details?id=com.jiecang.app.android.cofodesk&hl=en_US)；iOS：[App Store](https://apps.apple.com/jp/app/cofo-desk/id6444395619)；[COFO 官方網站](https://www.cofodesk.jp/)。已保存 10 張官方圖片，原 URL、日期與 SHA-256 見 sources.json（`research-assets/sources.json`）。
- **R**：本次模擬器實際打開的原 App 畫面。XML 與 PNG 存於 runtime-assets（`runtime-assets/`），不把未連線畫面當成真桌成功證據。
- **C**：REA 對上述 APK 的靜態觀察。完整來源、方法選取、Evidence ID、雜湊與限制見 [逆向調查](reverse-engineering.md) 和 Evidence index（`rea-evidence/index.json`）。靜態程式碼不證明真實硬體行為。
- **U**：尚待原 App／實體桌驗證。

官方 [Premium 多語手冊](https://cdn.shopify.com/s/files/1/0551/2632/7355/files/V11_COFO_Desk_JP_EN_TW_CN_Mass_20250327.pdf?v=1743143614) 的操作頁已保存於研究圖片。實體面板同按 `1`、`3` 超過 3 秒切換 Bluetooth，`BLE` 表示開啟、`OFF` 表示關閉；這不是 App 的 BLE 封包規格。

## 功能與驗證範圍

ID 保留供測試與實作對照。以下是原 App 的證據，不能直接視為替代 App 已完成的功能。

| ID | 功能 | 證據與已知範圍 | 剩餘未知 |
| --- | --- | --- | --- |
| F-CON-01 | BLE 桌子連線 | D；C 有三組 GATT profile、CCCD 與初始化查詢 | 使用者桌型的實際 profile、配對與硬體適用性 |
| F-CON-02 | 連線入口與未連線提示 | R：未連線控制頁（`runtime-assets/control-unconnected.png`） | 裝置選取、QR 流程、重連及逾時完整行為 |
| F-CON-03 | 已連線狀態／桌子識別 | S、C：儲存名稱／位址與狀態更新 | 已連接真桌的畫面與名稱編輯 |
| F-CTL-01 | 高度與單位顯示 | S、C：高度 raw 為十分之一 native cm/in；原 App 含單位 heuristic | 通知實際封包、更新延遲與面板同步 |
| F-CTL-02 | 升高、降低、停止、目標高度 | C：up/down 每 100 ms 重送；ACTION_UP 送 opcode `2B`；目標 `1B` 為 mm | 真桌停止保證、watchdog、斷線與碰撞 |
| F-CTL-03 | M 與坐／站／午睡記憶捷徑 | C：M 開單選儲存對話框；記憶存在本機、單位 inch；坐必須低於已存站高 | 有真桌時核對儲存／移動與限位；目前 Android 模擬版仍用長按儲存，屬待修正差異 |
| F-NAV-01 | 控制／歷史／設定主分頁 | R、S：原 App 為三個主區域 | 替代 App 額外提供提醒分頁，屬自己的導覽選擇 |
| F-HIS-01 | 日／週／月／年歷史 | R：每日畫面（`runtime-assets/history-day.png`）；S、C 有期間處理 | 原 App 每種期間 runtime 跨日／時區測試 |
| F-HIS-02 | 每日站立目標 | R：設定頁（`runtime-assets/reminder-goal.png`）；C：初始值 0，快捷 40/60/120/180/240 分鐘 | 真實達標通知；替代 App 預設 0 與快捷已對齊 |
| F-HIS-03 | 目標完成率 | C：站立秒數先取整分鐘，再整數百分比、最高 100；零活動有特殊分支 | 實機累計對照；替代 App 採相同整數算法，但零活動顯示 0%、目標 0 顯示未設定（刻意差異） |
| F-HIS-04 | 距離目標剩餘時間 | R、S、C | 背景與斷線下時間來源／準確性 |
| F-HIS-05 | 熱量估算與雞腿換算 | C：`long(seconds * (kg * 1.5 + 60) / 3600)`；週／月逐日截斷加總，年逐月；雞腿為 kcal/200 | 生理準確性不在相容性驗收內；真實活動資料尚未驗證；替代 App 已顯示雞腿數 |
| F-REM-01 | 每日站立目標時間設定 | R、C：時／分控制；小時 0–24、分鐘以 10 為步幅；初始 0 | 邊界操作 runtime 對照；替代 App 支援 0–24:50、10 分鐘單位，但仍用數字欄位而非時／分選擇器 |
| F-REM-02 | 久坐提醒 | R：久坐頁（`runtime-assets/reminder-sitting.png`）；C：時間、啟用開關、獨立鈴聲開關／選取 | 實際觸發、背景、鎖屏、鈴聲播放與取消 |
| F-REM-03 | 久站提醒 | R：久站頁（`runtime-assets/reminder-standing.png`）；C：對應時間／開關／鈴聲 | 同上；站立判斷與記憶／提醒設定耦合詳見 REA |
| F-REM-04 | 快捷時間 | R、C：目標 40m/1h/2h/3h/4h；坐站提醒 40m/1h/2h | 替代 App 已有相同快捷（只填入欄位，須儲存）；原 App 完整選取／保存對照仍待測 |
| F-SET-01 | 健康提醒入口 | R：設定選單（`runtime-assets/settings-menu.png`） → 三類提醒 | 替代 App 尚未補齊鈴聲等細節 |
| F-SET-02 | 桌子／個人設定 | R：桌子設定（`runtime-assets/desk-settings.png`）；C：身高、體重、坐／站／午睡高度、推薦高度填入；初始空白；kg/lb 保存 | 推薦值與硬體上下限、原 App lb 小數處理風險；替代 App 身高體重已改為初始空白，其餘尚未完整相容 |
| F-SET-03 | 度量單位 | R：cm/in 選項（`runtime-assets/measurement-unit.png`）；C：改 App 顯示 preference，不送硬體單位命令 | 真桌顯示與單位切換對照 |
| F-SET-04 | 異常維護入口 | R：該次畫面為空白 WebView（`runtime-assets/maintenance-menu.png`） | 尚未確認預期網頁內容與空白原因，不能稱已驗證維修功能 |
| F-SET-05 | 新手教學 | R：1（`runtime-assets/onboarding-1.png`）、2（`runtime-assets/onboarding-2.png`）、3（`runtime-assets/onboarding-3.png`）；設定另有入口 | 教學後續／重播完整流程 |
| F-SET-06 | 語言 | R：五種語言（`runtime-assets/language-options.png`）：簡中、英文、日文、韓文、繁中 | 原 App 全頁翻譯；替代 App 已有五語，原字句不要求逐字複製 |
| F-SET-07 | 深色模式 | R：跟隨系統／一般／深色（`runtime-assets/dark-mode-options.png`），Android 亦有此功能 | 原 App 每頁配色；替代 App 三種模式另有測試 |
| F-SET-08 | 關於 App | R：版本、更新、使用者協議、隱私、評分入口（`runtime-assets/about-app.png`） | 各外部連結、更新及評分行為尚未逐一驗證 |
| F-SET-09 | 意見／回饋 | R：支援提示頁（`runtime-assets/feedback-form.png`），該次畫面沒有輸入表單或可見信箱 | 未提交任何訊息；支援入口後續內容待核 |

## 界線與後續

1. 公開頁、原 App 畫面及 REA 已大幅縮小未知，仍不能將類別清單或截圖當成「所有功能」的完整證明。
2. 原 APK 的 BLE 控制封包、停止 opcode、記憶語意、推薦高度與熱量公式已有靜態證據。先前「只能猜測封包／公式」的限制已解除；硬體執行期驗收仍未解除。
3. 替代 Android App 目前是獨立模擬版本。尚需補齊 M 對話框／記憶順序、初始空白／零值、身高體重單位／推薦、提醒鈴聲等差異，再做真實 transport 與實機驗收。
4. 原 App 的 raw-height heuristic、inch 判斷、lb 字串與零活動百分比有靜態風險；修正時需清楚列出差異，不把原 App bug 當成已通過的硬體規格。
