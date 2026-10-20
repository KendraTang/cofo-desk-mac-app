# 實作與驗收邊界

## 選擇

先以 Android 原生 Java 實作，minSdk 26、target/compileSdk 36、JDK 21、Gradle 8.14.3、AGP 8.13.2。README 指定 Android App，且開發環境已有 Android SDK 與 API 36 模擬器。沒有額外的前端框架或執行期第三方套件。

本專案追蹤原 App 的可觀察功能，使用獨立 UI；未完成逐像素複製或完整實機相容。主分頁加入提醒捷徑，是本專案的導覽選擇。

## 模組

| 模組 | 責任 | 驗證方法 |
| --- | --- | --- |
| `core/DeskPort` | 提供真實或模擬的連線、高度、行程上下限、目標與方向移動、停止、鎖定與故障狀態；高度與上下限在同一份狀態快照，統一 mm。未連線、鎖定、故障或尚未取得上下限時拒絕移動 | 每個 transport 都要繼承 `DeskPortContract` 通過共用案例；目前由 `SimulatedDesk` 與限位不同、上下限需另行回報的測試替身 `ScriptedDesk` 共用。不能用 App 推測高度代替硬體通知 |
| `core/SimulatedDesk` | 可重現的桌子：63–128 cm（連線後才回報上下限）、35 mm/s、碰撞停止與連線中斷 | JVM 測試；數值參考 Premium 規格，故障行為為測試模型。停止是立即的，也不需要重送；真桌沒有重送時約 1 秒自己停、STOP 後約再走 1.5 cm、速度約 38 mm/s（見 [移動案例](reverse-engineering.md#移動案例2026-10-20)），接真桌時再決定是否模擬 |
| `core/DeskSession` | 記憶高度、資料驗證、單位、前景坐站統計、目標與提醒 | JVM 測試、持久化 round trip、邊界案例 |
| `core/ActivityHistory` | 依本機日曆分桶，日／週／月／年彙總 | 跨日、跨年、週一、DST 測試 |
| `SessionStore` | 私有 SharedPreferences；損壞欄位各自回復預設值。模擬桌停止位置另存在 `simulator` 偏好 | Activity recreation、App 重開、JVM 損壞資料案例 |
| `MainActivity` | 生命週期、前景計時、分頁導覽、權限結果；使用者操作統一經過驗證路徑（存檔、更新畫面，拒絕原因轉成訊息） | Espresso 操作測試與模擬器截圖 |
| `ControlPage`、`HistoryPage`、`ReminderPage`、`SettingsPage`、`DevicesPage` | 各分頁自己的畫面與更新；共用 `Views`（元件工廠）與 `Palette`（淺色／深色配色） | Espresso 操作測試 |
| `UiText` | 把 core 的 `Refused.Reason`、`Alert`、`Fault` 對應到五種語言的文字；switch 窮舉，漏掉對應就無法編譯 | 每種語言逐一檢查所有代碼都有不重複的文字 |
| `ReminderReceiver` | Android 通知與一次性 inexact alarm | 倒數測試及模擬器權限／通知測試 |
| `BleInspector` | 有限時掃描、明確選擇裝置、列出 GATT service/characteristic UUID 和 properties | Android 權限及未找到裝置情境；真桌 GATT 待驗證 |

BLE 診斷沒有 characteristic/descriptor 寫入 API。另有 REA 證據支持的 `CofoProtocol` 純編碼器，尚未接入 Android 真桌 transport；控制頁清楚標示「模擬模式」。

## 本專案自行定義、待與原 App 比對的行為

- 手指按住升降、放開或觸控取消停止；輔助使用者的 accessibility click 每次移動 1 cm。
- 記憶高度預設 72、105、118 cm；點按移動，長按儲存。原 App 的 M／姿勢捷徑語意尚未實測。
- 切換分頁、進入背景、鎖定、碰撞和中斷連線都停止模擬馬達。重新連線／返回前景不續跑舊指令。
- 模擬碰撞會停止並阻止新移動，直到手動清除。真桌硬體的下降碰撞回退行為另見官方手冊，尚未在這裡重現或控制。
- 站立門檻預設 95 cm，這是本專案的定義，不是原 App 規格。
- 每日目標、久坐提醒、久站提醒的新資料預設都是 0，與原 App 初始值一致；0 表示目標未設定或提醒關閉。範圍是 0–1490 分鐘（原 App 時／分選擇器可表示的 24:50），新的選擇以 10 分鐘為單位；舊版已存的非整十值會保留，不強制取整。原 App 另有提醒啟用開關與鈴聲開關，替代 App 以 0 表示關閉，鈴聲尚未實作，相容性另行追蹤。
- 目標旁有 40／60／120／180／240 分鐘快捷，久坐與久站各有 40／60／120 分鐘快捷，與原 App 相同；快捷只填入欄位，仍須按儲存。
- 身高、體重的新資料是空白，與原 App 相同；沒有體重時熱量顯示 0。舊版已保存的值（包含當時的預設 170 cm／65 kg）會保留，因為舊格式無法分辨是否為使用者輸入。
- 每日目標完成率採原 App 整數算法：`min(100, (站立秒數 / 60) × 100 / 目標分鐘)`。兩項刻意差異：沒有活動時顯示 0%（原 App 特殊分支顯示 100%）；目標為 0 時顯示「未設定」，不做除法，也不觸發達標提醒。
- 只在前景且桌子已連線時累計。背景和斷線時高度不可觀察，因此不推算活動；背景會重設連續姿勢提醒。
- 歷史採本機時區、週一為一週起點；日／週／月／年顯示本期截至今天。時區切換不重新分配已存日期。
- 熱量依 REA 取得的原 App 1.0.10 公式：站立整秒 ×（目前體重 kg × 1.5 + 60）÷ 3600 後截斷；週／月逐日、年逐月加總。支援 canonical 小數 kg，避免原 App lb 字串被 Integer.parseInt 處理的風險；不聲稱生理準確性。雞腿數與原 App 相同，為該期間熱量 ÷ 200，取一位小數。
- 一次性倒數依 wall clock 儲存截止時間，背景通知採 Android inexact alarm，省電時可能延後。每次 App 回到前景時，若截止時間還沒到，就用同一個 PendingIntent 重新排程，因此手機重開機後，只要開一次 App 就會恢復提醒；沒有 `BOOT_COMPLETED` receiver，開 App 之前不會恢復。若開 App 時已經到期，只顯示到期狀態並清除排程，不補發通知，避免送出過時或重複的提醒。force-stop 期間 Android 會取消 alarm，App 不承諾照常通知。
- 模擬桌的停止位置以整數 mm 保存；Activity 重建（旋轉、切換語言或外觀）與 App 重開都會恢復。保存前先停止模擬運動；恢復後一律是未連線、不移動，不恢復舊指令、鎖定或故障；資料不合法時回到 72 cm。這只用於模擬桌，真桌高度一律以裝置回報為準。
- 不保存模擬桌連線、正在執行的指令或硬體故障；App 再次啟動須明確連線。

## 下一個實作關卡

1. 原 App runtime 盤點完成，補齊入口內頁、語言、各功能精確語意。
2. 取得正確桌型的封包規格或可核對紀錄，完成 `DeskPort` 實機 transport。
3. 實機逐項通過 `test-plan.md` 的 H 案例後，才可將完整 BLE clone 勾選完成。


## 語言與外觀

文字、錯誤碼、BLE 診斷和通知已使用 Android resources，提供繁中／英文／日文／簡中／韓文。`UiPreferences` 將語言與跟隨系統／淺色／深色保存在獨立 appearance preferences；不被 session 儲存覆蓋，不改裝置語言或系統主題。切換會停止模擬馬達並重建 Activity，模擬桌停止位置會保留。App Bundle 關閉 language split，使所有內建語言離線可用。
