# 驗收清單與測試案例

規格來源為 [features.md](features.md)，本專案自行定義的細節見 [architecture.md](architecture.md)。這份測試設計涵蓋公開盤點中所有功能與仍需觀察的入口；沒有證據的原 App 行為先列「待確認」，不把模擬器預設值當成原 App 規格。

## 每次執行前

- [ ] 記錄 commit／工作樹、App 版本、Android API、裝置或 AVD 型號。
- [ ] 確認測試目標是 `dev.cofodesk.auto`，不用原 App 或其他 App 的資料做 reset。
- [ ] 模擬測試從已知偏好設定與未連線狀態開始；真桌測試另記桌型、韌體及原 App 版本。
- [ ] 真桌初次先讀取／停止，再短距離升降；測試人員可操作實體面板。
- [ ] 報告區分 JVM、Android 模擬器和實體桌。任何一層通過不能替代另外兩層。

## 自動化案例

| ID | 關聯功能 | 前置／操作 | 預期結果 | 已實作測試 |
| --- | --- | --- | --- | --- |
| S01 | F-CON-02、F-CTL-02 | 未連線，送升降命令 | 拒絕、不移動、顯示未連線 | `disconnectedCannotMove`、`connectionJogPresetAndStop` |
| S02 | F-CTL-01/02 | 72 cm 連線，移到 105 cm，推進時間 | 35 mm/s、準確到目標停止；此速度屬模擬模型 | `movesAtSpecifiedSpeedAndStopsAtTarget` |
| S03 | F-CTL-02 | 指令超出 63–128 cm，長時間升降 | 無效目標被拒、jog 停在上下限 | `limitsRejectInvalidTargetsAndClampJog` |
| S04 | F-CTL-02 | 先上升再下降 | 新方向取代舊命令 | `reversingDirectionReplacesOldCommand` |
| S05 | F-CTL-02 | 升降中放開／取消觸控、按停止 | 高度停止變化，accessibility 點擊只走 1 cm | `connectionJogPresetAndStop`、`cancelledTouchStopsAndAccessibilityClickMovesOneCm` |
| S06 | F-CON-02/03 | 移動中斷線、再連線 | 不續跑舊指令、無連線期間不累計 | `stopsDoNotResumeOnReconnectOrAdvance` |
| S07 | 模擬鎖／故障 | 移動中鎖定或注入碰撞，再送命令 | 立即停止、拒絕新移動；清除／解鎖後可繼續 | `collisionAndLockStopAndBlockMovement`、`lockCollisionAndRecovery` |
| S08 | F-CTL-03（目前模擬手勢） | 長按記憶目前高度，重新建立 session | 只有已連線且停止時可存；3 槽保留；裝置不自動重連 | `presetsRequireStationaryConnectionAndPersist` |
| S09 | 生命週期 | 移動中進入背景再返回 | 停止且不自動恢復 | `pauseStopsMotorAndNeverAutoResumes`、`backgroundStopsMovingAndDoesNotResume` |
| S09b | 生命週期、模擬桌 | 移動後重建 Activity、重開 App；移動中重建 | 恢復停止位置；未連線、不續跑；不合法位置回到 72 cm | `simulatorRestoresOnlyAStoppedDisconnectedPosition`、`simulatedHeightSurvivesRecreationAndRelaunchWithoutResumingMotion` |
| S10 | F-SET-02/03、資料 | 新資料檢查身高體重；修改身高、體重、門檻及英吋，重建 Activity；載入舊版資料 | 初始空白、無體重熱量 0；資料保留；72 cm 顯示 28.3 in；無效／NaN 被拒；舊版 170／65 保留 | `profileUnitsAndValidation`、`newProfileIsEmptyAndCaloriesStayZeroWithoutWeight`、`legacyStoredDefaultsAreKept`、`profileStartsEmptyAndSurvivesActivityRecreation` |
| S11 | F-HIS-03/05 | 離線、連線坐姿、連線站姿各推進時間 | 只累計連線且達門檻的前景站立時間；熱量符合已標示公式 | `statisticsOnlyCountConnectedStandingTime`、`thresholdCrossingDoesNotCountWholeMovementAsStanding`、`drumsticksAreKcalOver200WithOneDecimal` |
| S12 | F-HIS-01 | 跨午夜、週一、月底與年底累計 | 日期正確拆分；週一開始；本期不包含前期 | `midnightSplitsBucketsAndYearDoesNotLeak`、`weekStartsMondayAndMonthExcludesOldDays` |
| S13 | F-HIS-01 | 美東 DST 春季切換日 | 實際 23 小時，不假定每日固定 24 小時 | `dstDayUsesActualElapsedTime` |
| S14 | F-HIS-02/03/04、F-REM-01/04 | 預設值、0／24:00／24:50／超界、舊版非整十值；不足一分鐘、整分鐘交界、剛達標、超標；快捷填入後儲存；切換期間 | 預設 0、目標 0 顯示未設定且不提醒；範圍 0–1490、新選擇 10 分鐘單位、舊值保留；完成率整數且最高 100；快捷不自動儲存；達標提醒一次 | `goalsAndRemindersDefaultToZeroAndAcceptTheOriginalRange`、`legacyOffStepValueIsKeptButNewChoicesUseTenMinuteSteps`、`goalPercentUsesTheOriginalIntegerRule`、`zeroGoalNeverRaisesTheGoalAlert`、`standingGoalAndReminderPersistAndCanBeDisabled`、`reminderGoalsShortcutsAndHistoryNavigation` |
| S15 | F-REM-02/03 | 設 10 分鐘，未達先暫停，再恢復；切換坐站姿勢 | 連續計時重設；達門檻僅提醒一次；0 可停用 | `sittingReminderFiresOnceAndPauseResetsContinuousTime`、`standingReminderResetsWhenPostureChanges` |
| S16 | 額外倒數 | 開始、替換、重建、逾期、取消；alarm 遺失（模擬重開機）後開 App、重複 resume、已到期才開 App、取消後重開 | 使用持久化截止時間；未到期就重新排程；已到期只顯示、清除排程、不補發通知；取消不再到期；不移動桌子 | `countdownDeadlineSurvivesRestoreAndFiresOnlyOnce`、`cancelAndRestartReplaceDeadline`、`countdownStartsRestoresAndCancels`、`pendingCountdownIsRearmedOnOpenAfterItsAlarmWasLost`、`expiredCountdownIsShownAsDueWithoutALateNotification` |
| S17 | F-REM-02/03 通知通路 | 已授權通知，執行 receiver，再取消 | App 通知存在，取消後移除 | `receiverPostsNotificationAndCancellationRemovesIt`；此案例不證明 OS alarm 準時 |
| S18 | 資料恢復 | 損壞部分偏好與日期資料，重新載入 | 逐欄回復，保留合法欄位；不崩潰 | `corruptPreferencesRecoverWithoutDiscardingValidFields`、`persistenceAndClear` |
| S19 | F-SET-06 | 清除語言偏好後啟動 | App 預設為繁中，與裝置語言無關 | `defaultLanguageIsTraditionalChinese`；其餘流程測試改用 resource 比對，不寫死文案 |

JVM 類別：`app/src/test/java/dev/cofodesk/auto/core/`。Android 類別：`app/src/androidTest/java/dev/cofodesk/auto/AppFlowTest.java` 與 `LocaleAppearanceTest.java`。

新增案例：`CofoProtocolTest` 比對 REA 靜態封包與 checksum wrap；`StandingCaloriesTest` 比對原公式、canonical kg 與日／月截斷差異；`LocaleAppearanceTest` 驗五語切換後資料、三種外觀、輸入可讀性、背景 receiver／BLE 診斷語言、損壞語言偏好與換行。通知斷言輪詢系統服務（最多 3 秒），避免把非同步送達當成同步操作。

## 模擬器／人工補充案例

| ID | 操作 | 預期結果與證據 |
| --- | --- | --- |
| E01 | 開 BLE 診斷，拒絕附近裝置權限 | 顯示權限說明、可返回並繼續模擬桌，不崩潰 |
| E02 | 允許權限，關閉藍牙再掃描 | 顯示藍牙不可用，不顯示假連線 |
| E03 | 藍牙開啟，無周邊下掃描 | 10 秒後停止，顯示無裝置；可重試 |
| E04 | 掃描中離開頁面／進入背景 | 掃描停止；不存在循環掃描或自動重連 |
| E05 | 開始倒數，拒絕通知權限 | App 內倒數仍有效，提示背景通知未開啟 |
| E06 | 倒數到期、App 在背景或被系統回收 | 有通知權限時 OS 可送達通知；記錄實際延遲，回到 App 核對到期。不能要求 inexact alarm 秒級準時 |
| E07 | 強制停止／手機重啟後啟動 App | 不自動連線或移動；設定保留；逾期倒數顯示到期；新的倒數重新設定 OS alarm |
| E08 | 放大字體、橫向、小螢幕、鍵盤輸入 | 可捲動取得控制項、按鈕不與系統列重疊、輸入錯誤可修正 |
| E09 | 設定目標快捷 40m/1h/2h/3h/4h 後保存 | 分別為 40/60/120/180/240 分鐘；重開保留 |
| E10 | 指南、維護狀態與關於 | 正確顯示本專案可用能力，不宣稱真桌可控制 |

執行結果另記 [verification.md](verification.md)，未執行不得勾選。

## 原 App／實體桌待驗證矩陣

| ID | 功能 ID | 前置／操作 | 驗收標準 |
| --- | --- | --- | --- |
| H01 | F-CON-01/02/03 | 記版本與桌型，原 App 初次連線、拒權限、關藍牙、找不到桌子、離線再連 | 取得所有畫面與實際錯誤行為；確認是否需 QR／驗證；對應 GATT 證據 |
| H02 | F-CTL-01/02 | 原 App 升／降／停止；實體面板同步；限制位置 | 比對高度解析度、延遲、停止語意；替代 App 完成同樣結果 |
| H03 | F-CTL-03 | 逐一操作 M 與 3 姿勢捷徑，短按／長按／重啟 | 先建立原 App 真實語意，再調整目前記憶模型；記憶是否存在桌體或手機需確認 |
| H04 | F-HIS-01–05 | 設站立目標、改體重、跨姿勢／日／週／月／年；背景和斷線 | 取得判定、累計、熱量和期間規則；公式不明時不得聲稱數值相容 |
| H05 | F-REM-01–04 | 3 類提醒的完整內頁、快捷、範圍、取消、背景、鎖屏、程序結束 | 原 App 行為與替代 App 各自留下時間證據；測複數通知是否重複觸發 |
| H06 | F-SET-02/04 | 打開桌子設定與維修內頁，記錄所有欄位／指令／故障 | 依實際證據補實作；不可用模擬鎖代替硬體鎖設定 |
| H07 | F-SET-03/06/07 | 單位選單、所有語言、深色模式平台差異 | Android 逐頁無缺漏／截斷；單位轉換不改變實際高度；深色模式以實際支援為準 |
| H08 | F-SET-01/05/08/09 | 提醒入口、初次指南、關於、回饋逐頁記錄 | 確認是否需網路、外部連結與資料內容；逐項決定替代 App 的相容實作 |
| H09 | 故障與生命週期 | 實機移動中斷電、斷連、App 背景、面板操作／鎖定、控制盒故障 | 保留停止與 watchdog 的實機證據；重連不重播舊命令；硬體與 UI 狀態最終一致 |

**完整 clone 放行條件：** 公開功能盤點之外完成 runtime 逐頁盤點；H01–H09 全部有對應桌型的通過證據；所有仍未知的控制語意與支援項已處理。Android 模擬器只能放行已定義的軟體與 UI 行為。

## 執行指令

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

需設定 `ANDROID_HOME` 並先啟動 AVD。第一次建置會下載 Maven 相依套件。產物與報告路徑見 README。

API 33+ 模擬器另可執行 `python3 scripts/emulator-permission-smoke.py --serial emulator-5554`，驗證 E01、E02/E03 的可用分支與 E05。腳本只操作本專案與系統權限對話框，暫時修改後還原本 App 權限，並會取消倒數。它不證明真實周邊可連線。
