# COFO Desk Auto

COFO Desk 功能研究、Android 替代 App 與命令列工具。現在可在 Android 模擬器操作模擬桌、記錄活動與設定提醒；CLI 已有 BLE 控制後端及獨立模擬裝置，真桌相容性仍待實機驗證。

原 App：[Google Play](https://play.google.com/store/apps/details?id=com.jiecang.app.android.cofodesk&hl=en)。

## Todo

- [ ] List all the functions that the current COFO Desk app has
  - [x] 盤點官方商店截圖、說明與手冊，建立 25 項有來源的功能 ID
  - [x] 原 App 1.0.10 的教學、主要設定、語言／外觀與提醒畫面紀錄
  - [ ] 連線後頁面、維護 WebView 與外部支援流程的完整驗收
- [x] Design and prepare checklist and test cases
- [ ] Clone the app
  - [x] 可安裝的 Android App、控制抽象與可重現模擬桌
  - [x] 升降／停止、3 組本機記憶高度、模擬鎖定／碰撞／斷線
  - [x] 日／週／月／年活動統計、每日目標、熱量粗估
  - [x] 久坐／久站提醒、目標快捷、一次性倒數與通知、個人資料／單位保存
  - [x] BLE 權限、限時掃描與 GATT 服務診斷
  - [x] 核心單元測試與 Android 模擬器操作測試
  - [x] 五種語言與跟隨系統／淺色／深色外觀
  - [x] 使用 REA 分析原 App 1.0.10、取得控制封包與統計公式
  - [ ] 套用已發現的記憶手勢、設定／推薦高度與提醒鈴聲差異
  - [ ] 真實 BLE transport、硬體狀態同步與逐項實機驗收
- [x] Plan further auto features

完整盤點與 clone 仍保留未完成；模擬器通過不代表已相容真桌。

## 命令列工具

Python 3.11+ 可直接試用模擬桌：

```sh
python3 -m cofo_desk --json --simulate --state-file /tmp/cofo-demo.json status
python3 -m cofo_desk --simulate --state-file /tmp/cofo-demo.json goto 80
python3 -m cofo_desk --simulate --state-file /tmp/cofo-demo.json stop
```

安裝 BLE 支援及 `cofo-desk` 指令：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[ble]'
.venv/bin/cofo-desk --json scan --seconds 5
```

支援 scan／inspect／status／watch／up／down／goto／stop、JSON 與有界操作。共用選項放在子指令之前。使用方式、停止語意與實機限制見 [CLI 文件](docs/cli.md)。

## 執行

需求：JDK 21、Android SDK（platform 36）、已啟動的 Android AVD。`minSdk` 為 26，目前執行期驗證為 API 36。設定 `ANDROID_HOME` 指向你的 SDK。

```sh
./gradlew :app:assembleDebug
./gradlew :app:installDebug
adb shell am start -n dev.cofodesk.auto/.MainActivity
```

APK：`app/build/outputs/apk/debug/app-debug.apk`。App 名稱 **Desk Auto**，package `dev.cofodesk.auto`，不會覆蓋原 App。

進入控制頁後點「連接模擬桌」。按住升／降，放開即停止；點按 M1–M3 移動，長按儲存。切換分頁或進入背景會停止。設定頁可調整身高、體重、站立門檻與 cm／in。

提醒頁包含每日目標、久坐／久站設定及倒數。久坐／久站和活動統計只在 App 前景且桌子連線時累計；倒數使用系統 inexact alarm，背景通知可能延後。現在沒有自動升降排程。

## 測試

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug
./gradlew :app:connectedDebugAndroidTest
python3 scripts/emulator-permission-smoke.py --serial emulator-5554
python3 -m unittest discover -s tests -v
```

第一次建置會下載相依套件；之後可在快取完整時加 `--offline`。操作測試只清除本專案 App 的偏好設定與通知，並允許本 App 通知。額外的 Python 權限矩陣需要 API 33+ 模擬器，會暫時調整後還原本 App 權限及取消倒數。

- JVM 報告：`app/build/reports/tests/testDebugUnitTest/index.html`
- Android 報告：`app/build/reports/androidTests/connected/debug/index.html`
- Lint 報告：`app/build/reports/lint-results-debug.html`

## 文件

| 文件 | 內容 |
| --- | --- |
| [功能盤點](docs/features.md) | 25 項功能、官方截圖／手冊證據、已知與待確認行為 |
| [架構與假設](docs/architecture.md) | 控制抽象、模擬模型、統計／提醒規則與相容性界線 |
| [測試清單與案例](docs/test-plan.md) | 自動化、人工／模擬器、原 App 與實體桌的驗收矩陣 |
| [驗證紀錄](docs/verification.md) | 本次實際測試結果、畫面與未驗證項 |
| [REA 逆向調查](docs/reverse-engineering.md) | 原 APK 身分、GATT／封包、記憶／統計與 Evidence |
| [BLE 接入](docs/protocol.md) | 可用診斷、官方藍牙啟用方式、封包調查與真桌驗收條件 |
| [命令列工具](docs/cli.md) | 安裝、BLE／模擬操作、JSON、停止語意與測試 |
| [後續自動化](docs/automation.md) | 坐站週期、工作時段、手動確認、捷徑與自動 session 的順序和驗收 |

已依 REA 的原 App 熱量公式與期間截斷方式更新計算。模擬預設值、記憶長按手勢、可調站立門檻與前景統計仍有相容性差異，詳見架構及功能盤點。硬體相容性另行驗收。
