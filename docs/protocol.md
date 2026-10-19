# COFO BLE 調查與實機接入

目前已透過使用者模擬器中的原 App 1.0.10 及 REA 取得三組 GATT UUID、初始化、升降／停止／目標高度 bytes 和通知解析程式碼，見 [逆向調查與 Evidence](reverse-engineering.md)。尚未取得真桌封包，因此 incoming 完整 framing、checksum、分片、時序與實體停止保證仍未驗證。這不是廠商公開 SDK。

## 已可使用的診斷

App → 控制 → 裝置與 BLE 診斷 → 掃描。Android 12 以上要求附近裝置權限；Android 8–11 要求精確位置權限，且系統定位服務可能需啟用。掃描限制 10 秒，不背景循環掃描。

選擇裝置後限時連線，探索 GATT services；列出 UUID 與 characteristic properties 後關閉 GATT。可用「複製服務資訊」保留結果。這只證明裝置可被發現／探索，不能識別為相容桌子。

官方 Premium 手冊的實體面板操作：同按記憶 `1`、`3` 超過 3 秒切換 Bluetooth，顯示 `BLE` 為開、`OFF` 為關。此步驟不適用於尚未確認的其他型號。[手冊 PDF 第 72 頁的研究圖](research-assets/manual-page-72.png)

## 捕捉資料的順序

1. 記錄桌型、控制盒、手控器／BLE 配件型號、韌體、手機與原 App 完整版本。
2. 先從使用者自己的設備取得 GATT 列表，記錄 characteristic 的 read/write/write-without-response/notify/indicate properties。
3. 如有官方 SDK／協定，先以該文件為準；否則在 Android 開發者選項啟用 Bluetooth HCI snoop log，透過原 App 對自己的桌子逐次操作並記時間。不要公開完整 bugreport、手機識別或其他裝置流量。
4. 每次僅一個操作：初次連線、讀高度、開始上升、放開、下降、停止、記憶讀寫、斷線。高度、面板顯示與封包必須對得上。
5. 先離線建立 decoder/encoder fixtures，測分包、黏包、長度、checksum、未知 opcode 和截斷資料。不能靠相似品牌協定猜測。
6. 受控實機先測讀取與停止，再測短距離升降。完整記錄 request、ack、status notification、時間與面板行為。

## 真實 transport 必須履行

- 服務與能力驗證完成前不可顯示「可控制」；連上 GATT 不代表已就緒。
- 連線中、就緒、斷線、故障狀態須可辨識。所有指令有 timeout／failure，不把 optimistic UI 當成功。
- 硬體高度和移動狀態由通知／回應更新；不得沿用模擬器速度推算真桌高度。
- 指令序列化，取消與 stop 優先；重連不重播過期移動命令。
- 背景切換／離線時送 stop 的保證需由協定和硬體 watchdog 驗證。手機在斷線後不能保證命令送達。
- 可提供的鎖定、記憶、目標高度等 capability 需由已驗證協定決定；不支援則 UI 應說明。
- 硬體碰撞偵測、限位及面板控制始終由控制盒處理，App 不取代它們。

## 解鎖實機驗收所需輸入

目前缺少使用者實際桌型／控制盒資料、可核對的真桌通知封包，以及可進行短距離受控測試的實體桌。原 App APK 靜態資料已取得；模擬器不能替代實體停止、限位與通訊可靠性驗收。


## 已實作的純編碼器

Android `core/CofoProtocol` 已編碼靜態可見的 `01` 上升、`02` 下降、`2B` 停止、`0C` 查詢、`07` 限位查詢及 `1B` 毫米目標，含 checksum wrap 測試。這個類別不發出 BLE 寫入；控制頁仍使用模擬桌。
