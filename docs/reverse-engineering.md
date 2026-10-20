# COFO Desk Android：REA 靜態調查

2026-10-20。已實際使用使用者指定的 [Reverse Engineer Anything skill](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md)，以 REA 6.7.0 的 Android provider 分析模擬器內已安裝的原 App。這份紀錄只主張 APK 靜態觀察；原 App 畫面操作由另外的模擬器驗證紀錄佐證，沒有真桌 BLE 封包或硬體驗收結果。

## 目標與工具身分

| 項目 | 本次實際資料 |
| --- | --- |
| App | `com.jiecang.app.android.cofodesk`，1.0.10 / versionCode 15 |
| base APK SHA-256 | `b194d5ea3dec1c31ac27b850d92068850ad37b4350315d5896127f3103a35f01` |
| SDK / 盤點 | minSdk 25、targetSdk 36、4,353 個頂層類別、536 個資源項目 |
| REA | npm `rea-agents` 6.7.0，AndroidAnalysisService 與 CLI 共用的 provider |
| 引擎 | 官方 [jadx-headless-mcp 0.7.1](https://github.com/1013503897/jadx-headless-mcp/releases/tag/v0.7.1)，JDK 21.0.10 |
| 引擎 SHA-256 | `6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`，符合 REA 內建 pin |
| 引擎 source revision | `5844800a486d2248fa949b74c9896285f5b54de2` |
| 界線 | REA 未執行 APK，未驗簽，未分析 density split，未連任何桌子 |

provider、快取與原始 Evidence 留在本次 `/private/tmp/cofo-rea-*` scratch；未改全域 Codex/MCP 設定。首次呼叫因 Swift 預設 module cache 與 sandbox spawn 限制失敗，改以 task-local `REA_DARWIN_MODULE_CACHE_PATH` 並依環境審核執行後成功。未停用 REA 的 process ownership 控制。

[Evidence index](rea-evidence/index.json) 列出實際 Evidence ID。repo 保存的是**選取欄位／方法片段的 projection**，不是可送入 `evidence-import` 的 canonical bundle；每份 projection 保留原 record 的 ID、SHA-256、目標身分、引擎身分與限制。行號是 decompiler 回傳文字的行號，不是原始碼行號。APK 與完整應用反編譯不放進 repo。

2026-10-20 以相同 APK、REA 6.7.0 與 pinned JADX 重跑 index 內的全部方法：既有 projection 的程式碼行都出現在新結果中，本文語意描述逐項相符；Evidence ID 每次執行都會不同，但內容一致。同次另補 `onMonth` 與 `NewMainActivity.<init>` 兩筆 projection（index 中標記 `verification_pass`）。

## 已回答的問題

### BLE profile 與連線初始化

`BluetoothLeService` 有三組 profile。以下短 UUID 使用尾碼 `-0000-1000-8000-00805f9b34fb`。

| profile | service | write | notify/read | name / set |
| --- | --- | --- | --- | --- |
| 1 | `0000ff12` | `0000ff01` | `0000ff02` | `0000ff06` |
| 3 | `0000fe60` | `0000fe61` | `0000fe62` | `0000fe63` |
| 2 | `88121427-11e2-52a2-4615-ff00dec16800` | `88121427-11e2-52a2-4615-ff00dec16801` | 同 write | 未見此 profile 專用名稱 characteristic |

原 App 對 notify 呼叫 `setCharacteristicNotification(true)`，寫入 CCCD `00002902-0000-1000-8000-00805f9b34fb` 的 enable notification value。若另有 service `9e5d1e47-5c13-43a0-8635-82adffc0386f`，對 characteristic `9e5d1e47-5c13-43a0-8635-82adffc1386f` 寫入 `01 16 02 38 38 38 38`。這是靜態可見的額外寫入，尚無證據可斷言每張桌子需要它或其完整授權語意。

來源：[profile constants](rea-evidence/gatt-profile-constants.json)，`ev_5988efdf624ea6bd20591142aae057957e249004a1d36527057f33187d8c0ef4`；[discovery](rea-evidence/gatt-discovery.json)，`ev_5fc526bdec83a5470c9777a30a79b9aebf54315fce162268de9ff0864da5bec7`。Android SDK dexdump 的[常數觀察](rea-evidence/uuid-constants.json)亦相符。

連上 GATT 後約 200 ms 呼叫 service discovery；service discovered 後發出 `0C` 查詢三次，排程延遲為 0 / 200 / 400 ms；再發出 `07` 查詢三次，延遲為 800 / 1,000 / 1,200 ms。原 App 未將這些寫入序列化成逐個 callback 確認的 queue。這些時間是 App 排程值，不是硬體需求保證。登入寫入是在 `setCharacteristicNotification()` 掃描 service 時同步發出，早於上述查詢排程，也不等待寫入 callback；因此原 App 任何控制指令之前都已嘗試過登入。profile 3 的 `fe63` 也會另外啟用 notification。[通知與初始化片段](rea-evidence/notifications.json)，`ev_02055b56fb65335537ca161201d8b079edd6f6ac3dff550cc41a4b29e8ea0bac`。

### 寫入指令

| 操作 | 實際方法中可見的 bytes |
| --- | --- |
| 上升 | `F1 F1 01 00 01 7E` |
| 下降 | `F1 F1 02 00 02 7E` |
| 停止 | `F1 F1 2B 00 2B 7E` |
| 初始化查詢 | `F1 F1 0C 00 0C 7E` |
| 高度上下限查詢 | `F1 F1 07 00 07 7E` |
| 目標高度 | `F1 F1 1B 02 hi lo checksum 7E`，`checksum = (0x1B + 2 + hi + lo) & 0xff` |

來源：[up](rea-evidence/up.json)、[down](rea-evidence/down.json)、[stop](rea-evidence/sendstop.json)、[target](rea-evidence/main-onstop.json)。`intToBytes` 是 big-endian；目標值取最後兩個 bytes。[整數轉換](rea-evidence/inttobytes.json)。

儲存的記憶高度以 inch 表示；移動記憶高度時，每個 display/native unit 分支都執行 `int(storedInches * 25.4)`，即以毫米為目標封包值。這與通知高度使用的 native unit 不同。slider 的目標值由已回報的 max/min 線性插值後送出。來源：[memory command](rea-evidence/memory-command.json)，`ev_e3061d3f265252db551032eea2e871f2243357de54d50c989da334ae57043909`。

上升／下降的 repeat interval 是 100 ms；原 App 的 touch listener 只有 ACTION_UP 呼叫停止，未在該段處理 ACTION_CANCEL。坐／站／午睡 shortcut 點擊或 repeat 皆送出目標高度；M 按鈕另開儲存對話框。[control input](rea-evidence/control-input.json)。clone 若於取消觸控、背景或分頁切換時也停止，屬明確的改良設計。

### 通知解析與狀態

原 App 將每次 characteristic 值轉成大寫連續 hex，交給 BroadcastReceiver 做 substring 搜尋。[broadcast](rea-evidence/broadcast-data.json)，`ev_ac291f8786222e546b2dfa51f14894a2fb42b37ef83786aef267ea4f8219d6f4`。下表是這個 receiver 實際接受的 pattern 與欄位，並不等同完整硬體封包格式。

| pattern | 靜態可見語意 |
| --- | --- |
| `F2 F2 0E 01 value` | `00` native cm；`01` native inch |
| `F2 F2 07 length maxHi maxLo minHi minLo` | 兩個 16-bit big-endian max/min 值，length 未驗證；依用法推定為 mm（見下文） |
| `F2 01 length hi lo` | 搜尋此 pattern 後讀兩個 bytes 為 raw height；未要求 length 恰為 2 |
| `F2 04` | 顯示 `RST`、停提醒、設 error flag |
| `F2 02 01 code` | 錯誤狀態；停止提醒並設 error flag |

錯誤映射：`01..09` → `E01..E09`，`0A..0D` →原 App 字面值 `E010..E013`，`0E` → `H01`，`0F` → `H02`，`10` → `LOCK`。這是顯示字串，未從代碼推導其實際原因。[notifications](rea-evidence/notifications.json)。

高度通知後，原 App 以 `raw >= 550` 推定 cm，否則 inch；以 `raw / 10` 得 native 高度，再依 App display preference 換算。因而通知欄位是十分之一 native cm/in，**不能把每筆通知都當毫米**。`0E` unit 回報也存在，但高度 handler 仍會執行此 heuristic。

上下限沒有單位欄位，但三處用法都把它當 mm：cm-native 時 `maxVul = maxHei`、in-native 時 `maxHei / 2.54`，再與十分之一 native 單位的 raw 高度比較；進度以 `raw*254/100 - minHeightCion` 換算；推薦高度以 `maxHei/10` 當 cm 上限（[height recommendations](rea-evidence/height-recommendations.json)）。這是由用法推得的結論，尚未以真桌封包驗證。

pattern 是對整串 hex 字串做 substring 搜尋，未對齊 byte 邊界；理論上其他封包的資料（例如 `0F 20 1x`）也可能被當成 `F201` 高度通知。

原 receiver 未驗 checksum、trailer、資料長度，也沒有跨 notification 分片重組；write callback 也廣播寫入值。由 outgoing bytes 可推得「command + length + payload modulo 256」規律；2026-10-20 的真桌紀錄顯示 incoming 也使用同樣的格式與 checksum，並會分片（見下節）。CLI 依此驗 checksum 並跨通知重組，相關實作假設列在 [CLI 文件](cli.md#通知解析)。

### 記憶高度與使用者資料

M 開啟坐／站／午睡單選對話框，按確認才呼叫對應 remember 方法；沒有把「長按 shortcut 儲存」當成該段原 App 手勢。[memory dialog](rea-evidence/memory-dialog.json)，`ev_0bb46b137c29d8a72f6c2468469ef8518743c90e8ea8ebeeddca3d8ad4a4c048`。

坐／站儲存需已連線、非錯誤、slider 已放開、高度在範圍，另要求語意未明的 `mBackFlag != 2`（午睡無此條件）；坐高度必須低於已有站高度，站高度必須高於已有坐高度。午睡高度亦檢查連線、錯誤與範圍，但未見相同坐站排序約束。三者存在本機 preference，以 inch 為共同單位。[sit](rea-evidence/remembersit.json)、[stand](rea-evidence/rememberstand.json)、[nap](rea-evidence/remembersleep.json)。

設定頁 `SetDesk1Activity` 有身高、體重與坐／站／午睡高度，可帶入建議高度；返回時保存。若身高單位為 cm，建議坐高是 `int(0.35 * height + 7.62)`（極小身高另有 `0.45 * height` 分支），建議站高在身高至少 127 cm 時為 `int(0.94 * height - 52.07)`，否則為 `int(0.74 * height)`；之後依桌子的上下限限制。午睡建議為建議坐高再加 5 個顯示單位，受上限限制。這些是原 App 公式，並非人體工學建議。[完整公式片段](rea-evidence/height-recommendations.json)，`ev_e27c34ae20653acefb0efcb9e92edd817fb90ba5541700c80424cab9bdd5a57e`。

cm/in 選擇頁直接改 App 顯示 preference，該方法沒有對桌子發出更換硬體單位的指令。[display unit](rea-evidence/display-unit.json)。體重 kg 直接保存輸入字串；lb 乘 `0.453` 保存，但每日統計 `onDay` 用 `Integer.parseInt` 讀體重，存在小數字串不相容的靜態風險，未將此風險當已重現的崩潰；週／月／年統計改用 `Double.valueOf(weight).intValue()`，可處理小數。[profile save](rea-evidence/profile-save.json)。

### 首次預設值與提醒選擇器

原 preference getter 的預設值為：每日目標、坐提醒分鐘、站提醒分鐘皆 `0`；身高、體重及坐／站／午睡 memory 皆空字串；坐／站提醒與各自鈴聲開關皆 `false`；身高單位 `cm`、體重單位 `kg`。這些預設與模擬桌的示範高度要分開，不能將示範值寫成原 App 預設。來源：[目標](rea-evidence/defaults-target.json)、[坐時間](rea-evidence/defaults-sit.json)、[站時間](rea-evidence/defaults-stand.json)、[身高](rea-evidence/defaults-height.json)、[體重](rea-evidence/defaults-weight.json)；其餘 getter 在 [index](rea-evidence/index.json) 的 `defaults-*` 記錄。

HealthActivity 的三組 hour/minute 控制使用相同邊界：hour down 在 0 停住、hour up 在 24 停住；minute down 以 10 減少，在 0 停住而不借位；minute up 以 10 增加，50 後變 0 並增加 hour，但 hour 已 24 就留 24。因此靜態可表示 `24:50`，再次增加 minute 會變 `24:00`。返回箭頭將三組數值以 `hours*60+minutes` 保存，未見額外裁切。此非一般的時間選擇器邊界，clone 若改成最多 24 小時需列出差異。[bounds](rea-evidence/reminder-bounds.json)，`ev_9254c40079d0f1c14c307bab3cc483c65be6ce67029cf5d5ffb3ce5f98c5544f`；[初始顯示](rea-evidence/reminder-initialization.json)。

「使用建議高度」按鈕只在 `mFlag==1` 時把三個建議文字填到可編輯欄位並設 `mB=true`，此 listener 沒有送 BLE 或直接移動桌子；實際保存仍由返回流程處理。[fill](rea-evidence/recommendation-fill.json)。

### 站立判斷、統計與提醒

真正設定 `sitStand` 的 receiver，僅在連續兩筆 raw height 相同時更新分類。若 `getStand()==0`（站立提醒時間 preference）或站立 memory 為空，用 **raw 946** 當門檻，沒有按 native inch 修正。其他情況用 `storedStandInches - 0.196` inch 為門檻，與 cm-native `raw/25.4` 或 inch-native `raw/10` 比較。低於門檻為坐，否則為站。這些耦合與 heuristic 屬原 App 觀察，clone 是否修正需列成差異。

`ThreadTimeAction` 雖另外計算 `standSitDivideHeight`（例如 940），但本次完整 run 方法未讀它來分類，而是使用 `sitStand`；不能單看該欄位當成已生效門檻。thread 每約 5 秒記錄連線且高度大於 0 的經過時間，error flag 會阻擋累計。App onCreate 啟動 thread；本次未藉此證明 Android 長時間背景存活。[activity clock](rea-evidence/activity-clock.json)，`ev_bda79c8a4887f6b308b690cdcfbccdbf3a19e8dc0eb465bc1fb2554cd6c05b7c`。

熱量使用**站立秒數**與整數體重：`long(standingSeconds * (weight * 1.5 + 60) / 3600)`，weight 為 0 則回傳 0。每日為該日公式值；週／月先各日計算並截斷再加總；年以每月總站立秒數各計算並截斷再加總。雞腿顯示值為熱量除 200，格式 1 位小數。這是相容性公式，未驗證生理準確性。[calorie](rea-evidence/calorie.json)，`ev_b2fd26e2f157cb784b008c1126b618acce5136a8f8142a612a4b0795f3924fb3`；[daily](rea-evidence/day-statistics.json)、[weekly](rea-evidence/week-statistics.json)、[monthly](rea-evidence/month-statistics.json)、[yearly](rea-evidence/year-statistics.json)。週為週一到下週日（另查本週日但未使用）；月依 `getActualMaximum` 取 28–31 日。體重空白時，日統計直接回 0，週／月／年改用 `defaultWeightValue`，建構子 smali 將其設為 `0`，所以結果仍為 0；本次只確認建構子與上述方法，未搜尋其他寫入點。[default weight](rea-evidence/default-weight.json)。

每日目標百分比先對站立秒數 `/60` 取整，再乘 100 除目標分鐘數取整、最高 100；原 App 零坐零站特別顯示 100。這個零活動行為與合理 UX 的選擇應分別記錄。提醒設定有坐／站啟用、各自鈴聲啟用與鈴聲選取；health 頁預設目標快捷 40 / 60 / 120 / 180 / 240，坐／站快捷 40 / 60 / 120。[health controls](rea-evidence/health-controls.json)。

## 真桌觀察（2026-10-20）

使用者的桌子透過 CLI `--trace` 首次連線，完整紀錄在 [first-contact log](hardware-evidence/2026-10-20-first-contact.log)，使用的腳本是 [first-contact script](hardware-evidence/2026-10-20-first-contact.sh)。這只是一張桌子、一次連線的觀察，不代表所有 COFO 桌型。

- **profile**：桌子提供 `fe60` service（寫入 `fe61`、通知 `fe62`，另有 `fe63`／`fe64`），以及標準的 Device Information service `180a`。沒有登入 service `9e5d…`，所以這張桌子不需要、也不會收到登入寫入。
- **通知格式**：進來的封包和送出的指令結構相同：`F2 F2 opcode length payload checksum 7E`，checksum 是 `opcode + length + payload` 取最低 8 bits。所有收到的封包都驗算過。前綴是兩個 `F2`；原 App 搜尋的 `F201` 子字串在雙前綴封包中也找得到。
- **高度**：`F2 F2 01 03 02 76 07 83 7E`。length 是 3：前 2 byte 為高度（`0x0276` = 630，即 63.0 cm），第 3 byte 一直是 `07`，意義不明。面板顯示 63，單位通知 `F2 F2 0E 01 00` 表示 cm。
- **上下限**：`F2 F2 07 04 05 00 02 76 88 7E`，max 1280、min 630。桌子停在最低點時高度正好 630，證實上下限是 mm，也就是上文的推論成立。
- **原 App 未解析的通知**：`25`／`26`／`27`／`28` 各帶一個 16-bit 值（這次是 959、631、1280、0），可能是桌體記憶高度；`17`、`19`、`1D` 各帶 1 byte（`01`、`00`、`02`）。只記錄，未推定用途。
- **分片**：BLE 通知有時會把一個封包拆成兩筆，例如 `…88 7E F2 F2 01 03` 接著下一筆 `7E`，或一筆結尾多出 `F2`、下一筆是 `CC FF`。後者的 `CC FF` 不符合已知格式，可能是雜訊或未知封包。
- **回應重複**：每個查詢都會收到多次相同的回應；桌子靜止時也會持續回報高度。
- **移動**：UP 寫入一次、160 ms 後 STOP，高度 630 → 631（1 mm），面板仍顯示 63。這個距離太短，無法判斷是 STOP 讓桌子停下，還是桌子在沒收到重送時自己停。
- **未測**：目標高度 `1B` 的單位、STOP 在明顯移動中的效果、漏送重送時的停止時限，以及錯誤碼通知。

## 本次回答範圍與剩餘驗證

| 問題 | 狀態 | 還缺什麼 |
| --- | --- | --- |
| App／provider 身分 | 已回答（靜態） | APK 簽章未驗；split 未分析 |
| profile UUID、控制與目標 bytes | 已回答（靜態）；使用者的桌子是 `fe60`、無登入 service，UP／STOP 寫入有效 | 目標 `1B` 的單位與 STOP 在明顯移動中的效果 |
| 初始化與通知欄位 | 大致回答（一張真桌）：雙 `F2` 前綴、有 checksum 與 `7E`、高度 length 3、會分片 | 高度第 3 byte 與 `17`／`19`／`1D`／`25`–`28` 的意義、ACK |
| 記憶操作與資料單位 | 已回答（靜態） | 有真桌時驗 M 儲存、移動及上下限 |
| 站立判斷與熱量 | 已回答（靜態） | 實機 runtime 對照與明確列出 clone 修正的原 App quirks |
| 原 App 每個設定／支援畫面 | 此調查僅補部分 | 另以模擬器逐頁紀錄，不能用類別名宣稱頁面已驗 |
| 物理停止／碰撞／斷線 | 未解 | 桌子型號、可連線桌子與有人監看的驗收 |

可重跑的起點（先準備相同 APK 和上述 pinned JAR；下例路徑依本次 scratch）：

```sh
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
REA_DARWIN_MODULE_CACHE_PATH=/private/tmp/cofo-rea-clang-module-cache \
REA_JADX_MCP_JAR=/private/tmp/cofo-rea-jadx-0.7.1-all.jar \
rea inspect-android-package /private/tmp/cofo-original/base.apk --format json

# 再從 class inventory 選明確 method / overload。
rea inspect-android-class /private/tmp/cofo-original/base.apk \
  com.jiecang.app.android.aidesk.BluetoothLeService --format json
rea inspect-android-method /private/tmp/cofo-original/base.apk \
  com.jiecang.app.android.aidesk.NewMainActivity sendStopCommand --format json
```

focused 呼叫亦需同一組環境變數。本次先跑 CLI，再用相同 `AndroidAnalysisService` 保留單一 provider session，避免反覆重載。每個結果仍由 REA 建立 Evidence，並於調查結束關閉 provider。
