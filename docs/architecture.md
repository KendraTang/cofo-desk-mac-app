# 實作與驗收邊界

## 選擇

先以 Android 原生 Java 實作，minSdk 26、target/compileSdk 36、JDK 21、Gradle 8.14.3、AGP 8.13.2。README 指定 Android App，且開發環境已有 Android SDK 與 API 36 模擬器。沒有額外的前端框架或執行期第三方套件。

本專案追蹤原 App 的可觀察功能，使用獨立 UI；未完成逐像素複製或完整實機相容。主分頁加入提醒捷徑，是本專案的導覽選擇。

## 模組

| 模組 | 責任 | 驗證方法 |
| --- | --- | --- |
| `core/DeskPort` | 提供真實或模擬的連線、高度、移動、停止、鎖定與故障狀態；高度統一 mm | 每個 transport 都要通過契約案例，不能用 App 推測高度代替硬體通知 |
| `core/SimulatedDesk` | 可重現的桌子：63–128 cm、35 mm/s、碰撞停止與連線中斷 | JVM 測試；數值參考 Premium 規格，故障行為為測試模型 |
| `core/DeskSession` | 記憶高度、資料驗證、單位、前景坐站統計、目標與提醒 | JVM 測試、持久化 round trip、邊界案例 |
| `core/ActivityHistory` | 依本機日曆分桶，日／週／月／年彙總 | 跨日、跨年、週一、DST 測試 |
| `SessionStore` | 私有 SharedPreferences；損壞欄位各自回復預設值 | Activity recreation、JVM 損壞資料案例 |
| `MainActivity` | 四個分頁、可捲動畫面、操作與生命週期 | Espresso 操作測試與模擬器截圖 |
| `ReminderReceiver` | Android 通知與一次性 inexact alarm | 倒數測試及模擬器權限／通知測試 |
| `BleInspector` | 有限時掃描、明確選擇裝置、列出 GATT service/characteristic UUID 和 properties | Android 權限及未找到裝置情境；真桌 GATT 待驗證 |

BLE 診斷沒有 characteristic/descriptor 寫入 API。另有 REA 證據支持的 `CofoProtocol` 純編碼器，尚未接入 Android 真桌 transport；控制頁清楚標示「模擬模式」。

## 本專案自行定義、待與原 App 比對的行為

- 手指按住升降、放開或觸控取消停止；輔助使用者的 accessibility click 每次移動 1 cm。
- 記憶高度預設 72、105、118 cm；點按移動，長按儲存。原 App 的 M／姿勢捷徑語意尚未實測。
- 切換分頁、進入背景、鎖定、碰撞和中斷連線都停止模擬馬達。重新連線／返回前景不續跑舊指令。
- 模擬碰撞會停止並阻止新移動，直到手動清除。真桌硬體的下降碰撞回退行為另見官方手冊，尚未在這裡重現或控制。
- 站立門檻預設 95 cm，目標 60 分鐘，久坐提醒 40 分鐘，久站提醒 60 分鐘。這些預設值不是原 App 規格。
- 只在前景且桌子已連線時累計。背景和斷線時高度不可觀察，因此不推算活動；背景會重設連續姿勢提醒。
- 歷史採本機時區、週一為一週起點；日／週／月／年顯示本期截至今天。時區切換不重新分配已存日期。
- 熱量依 REA 取得的原 App 1.0.10 公式：站立整秒 ×（目前體重 kg × 1.5 + 60）÷ 3600 後截斷；週／月逐日、年逐月加總。支援 canonical 小數 kg，避免原 App lb 字串被 Integer.parseInt 處理的風險；不聲稱生理準確性。
- 一次性倒數依 wall clock 儲存截止時間，背景通知採 Android inexact alarm，省電時可能延後。程序重啟可復原截止時間；手機重啟不重設 OS alarm，開 App 仍會核對是否到期。
- 不保存模擬桌連線、正在執行的指令或硬體故障；App 再次啟動須明確連線。

## 下一個實作關卡

1. 原 App runtime 盤點完成，補齊入口內頁、語言、各功能精確語意。
2. 取得正確桌型的封包規格或可核對紀錄，完成 `DeskPort` 實機 transport。
3. 實機逐項通過 `test-plan.md` 的 H 案例後，才可將完整 BLE clone 勾選完成。


## 語言與外觀

文字、錯誤碼、BLE 診斷和通知已使用 Android resources，提供繁中／英文／日文／簡中／韓文。`UiPreferences` 將語言與跟隨系統／淺色／深色保存在獨立 appearance preferences；不被 session 儲存覆蓋，不改裝置語言或系統主題。切換會停止模擬馬達並重建 Activity。App Bundle 關閉 language split，使所有內建語言離線可用。
