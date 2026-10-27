# COFO Desk Auto

COFO 升降桌的功能研究，以及原廠 App 以外的控制方式。原廠 App：[Google Play](https://play.google.com/store/apps/details?id=com.jiecang.app.android.cofodesk&hl=en)。

這個 repo 有三個可以使用的部分：

| 部分 | 位置 | 做什麼 | 目前狀態 |
| --- | --- | --- | --- |
| `cofo-desk` 命令列工具 | `cofo_desk/` | 在 Mac 上透過藍牙掃描、讀狀態、升降、到指定高度、停止；另有模擬桌 | 已在一張真桌（fe60 profile）上使用 |
| Clock 番茄鐘自動升降 | `timer-desk/` | Mac 背景程式：Clock 的計時器結束就把桌子升到站姿，15 分鐘後降回坐姿 | 已在同一張真桌上通過 Gate 3，日常試用中 |
| Desk Auto Android App | `app/` | 原廠 App 的替代品：控制、記憶高度、活動統計、提醒 | 只接模擬桌，還沒有真實藍牙連線 |

只想讓桌子跟著番茄鐘升降，依序做[安裝](#安裝installation)的第 1、2 步，再看[番茄鐘自動升降](#番茄鐘自動升降)。

## 安裝（Installation）

### 需求

| 用途 | 需要 | 實際測過的版本 |
| --- | --- | --- |
| `cofo-desk`（真桌） | macOS、Python 3.11+、藍牙 | macOS 26.6（arm64）、Python 3.14.8、Bleak 3.0.2 |
| `cofo-desk`（只用模擬桌） | Python 3.11+，任何有 POSIX `fcntl` 的系統 | 同上 |
| 番茄鐘自動升降 | 上一列的 `cofo-desk`、Swift 6（Command Line Tools 即可，不需 Xcode）、Apple 時鐘 App | Swift 6.3.2、只裝 Command Line Tools |
| Android App | JDK 21、Android SDK platform 36、已啟動的 Android AVD；`ANDROID_HOME` 指向 SDK | API 36 模擬器（`minSdk` 26） |

另外，控制真桌時：

- 執行指令的終端機必須有系統的藍牙權限（系統設定 › 隱私權與安全性 › 藍牙）。
- 同一時間只能有一個程式連著桌子，先關掉手機上的原廠 App。

### 1. `cofo-desk` 命令列工具

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[ble]'
.venv/bin/cofo-desk --json scan --seconds 5    # 找出桌子的 UUID
.venv/bin/cofo-desk --json --device <桌子 UUID> status
```

`status` 會回報目前高度、上下限和面板記憶高度 `memory_mm`。番茄鐘自動升降用的就是面板上的 M1（站姿）和 M2（坐姿），請先在桌子面板上設好。

### 2. 番茄鐘自動升降

以下指令都要在一般的終端機（例如 Ghostty、Terminal）執行，不要在 tmux 裡，否則簽署時讀不到鑰匙圈，會出現 `errSecInternalComponent`。

```sh
scripts/create-signing-identity.sh    # 只需一次，過程中會要求登入密碼
timer-desk/install.sh --cofo-desk "$PWD/.venv/bin/cofo-desk" --device <桌子 UUID>
```

- `create-signing-identity.sh` 會在登入鑰匙圈建立本機簽署身分 `cofo-desk-auto local signing`。重新編譯後簽署身分不變，macOS 給的權限就不會失效。
- `install.sh` 會編譯、簽署，再把程式裝成 LaunchAgent（`dev.cofodesk.timer-desk`），登入後自動啟動，結束了也會自己重啟。
- 第一次執行時 macOS 會要求輔助使用（用來讀選單列上的計時器）和藍牙權限。
- 裝好後用[查看狀態](#查看狀態)的指令確認它在執行、已連上桌子。

### 3. Android App

```sh
./gradlew :app:assembleDebug
./gradlew :app:installDebug
adb shell am start -n dev.cofodesk.auto/.MainActivity
```

APK 在 `app/build/outputs/apk/debug/app-debug.apk`。App 名稱 **Desk Auto**，package `dev.cofodesk.auto`，不會覆蓋原廠 App。第一次建置會下載相依套件，之後快取完整時可加 `--offline`。

## 使用

### 命令列工具

```sh
.venv/bin/cofo-desk --device <桌子 UUID> goto 105 --unit cm --timeout 20
.venv/bin/cofo-desk --device <桌子 UUID> up --seconds 0.3
.venv/bin/cofo-desk --device <桌子 UUID> stop
```

共用選項（`--json`、`--simulate`、`--device` 等）放在子指令之前。不連真桌也可以用模擬桌試，這時不需要 Bleak：

```sh
python3 -m cofo_desk --json --simulate --state-file /tmp/cofo-demo.json status
python3 -m cofo_desk --simulate --state-file /tmp/cofo-demo.json goto 80
```

所有子指令、停止語意和真桌限制見 [CLI 文件](docs/cli.md)。

### 番茄鐘自動升降

在 Apple 時鐘用計時器開番茄鐘，照平常使用即可。任何長度的計時器自然結束都會觸發：

1. 計時自然結束時，桌子先往上點動約 1 cm 當預告。
2. 3 秒內按任何面板鍵就取消；沒按就升到 M1。已經在 M1 附近則不動。
3. 自動升起 15 分鐘後，如果高度沒被調整過（差 3 mm 以內），同樣點動往下、等 3 秒，再降回 M2。
4. 螢幕鎖定或睡眠時一律不動，也不補做。

失敗時會跳系統通知。暫停、取消的計時器不會觸發。完整規則和已知限制見[規格](docs/timer-desk.md)。

背景程式一直連著桌子，所以這段期間手機的原廠 App 通常連不上。要用原廠 App 時先執行 `timer-desk/uninstall.sh`。

#### 查看狀態

```sh
launchctl print gui/$(id -u)/dev.cofodesk.timer-desk | grep -m1 'state ='    # running 表示在監控
grep -v TRACE ~/Library/Logs/timer-desk.log | tail -5                        # 最近的事件
grep lower-scheduled ~/Library/Logs/timer-desk.log | tail -1                 # 下次自動下降的時間
```

紀錄是 JSON Lines，每行一個事件。開一個任意長度的計時器，幾秒內應該會出現 `"event":"started"`。

#### 更新、改設定、移除

- **更新或改設定**：直接重跑 `install.sh`，不必先移除，它會先停掉舊版。設定都寫在 LaunchAgent 的參數裡，沒有另外的設定檔，例如：
  - `--nudge 15`：點動距離改成 15 mm
  - `--window 5`：取消等待改成 5 秒
  - `--lower-after 1200`：升起後 20 分鐘才降
  - `--length 1500`：只認 25 分鐘的計時器（可重複給多個長度）

  全部參數見規格的「架構」一節，或執行 `timer-desk/bin/timer-desk --help`。
- **重裝的時機**：重裝會重新啟動程式，等待中的下降會被取消，正在倒數的計時器結束時也不會升（它沒看到開頭，不知道長度）。最好在兩個番茄鐘之間重裝。
- **移除**：`timer-desk/uninstall.sh`，會保留紀錄檔和編譯好的程式。

### Android App

進入控制頁後點「連接模擬桌」。按住升／降，放開即停止；點按 M1–M3 移動，長按儲存。切換分頁或進入背景會停止。設定頁可調整身高、體重、站立門檻與 cm／in。

提醒頁包含每日目標、久坐／久站設定及倒數。久坐／久站和活動統計只在 App 前景且桌子連線時累計；倒數使用系統 inexact alarm，背景通知可能延後。App 本身沒有自動升降排程。

## 測試

```sh
python3 -m unittest discover -s tests -v       # cofo-desk，用模擬桌和封包 fixture
timer-desk/test.sh                              # 番茄鐘程式的單元測試（含真實紀錄重播）
./gradlew :app:testDebugUnitTest :app:lintDebug
./gradlew :app:connectedDebugAndroidTest       # 需要已啟動的模擬器
python3 scripts/emulator-permission-smoke.py --serial emulator-5554
```

- 以上都不會移動真桌。真桌的逐步驗收腳本在 `probes/`，例如 `probes/gate3-cases.sh`，會實際升降桌子。
- Android 操作測試只清除本 App 的偏好設定與通知，並允許本 App 通知。
- Python 權限矩陣需要 API 33+ 模擬器，會暫時調整後還原本 App 權限，並取消倒數。
- 報告位置：
  - JVM：`app/build/reports/tests/testDebugUnitTest/index.html`
  - Android：`app/build/reports/androidTests/connected/debug/index.html`
  - Lint：`app/build/reports/lint-results-debug.html`

## 文件

| 文件 | 內容 |
| --- | --- |
| [Clock 計時器自動升降桌](docs/timer-desk.md) | 番茄鐘升降的規則、架構、可行性與真桌驗收紀錄、已知限制 |
| [命令列工具](docs/cli.md) | 安裝、BLE／模擬操作、JSON、停止語意與測試 |
| [BLE 接入](docs/protocol.md) | 可用診斷、官方藍牙啟用方式、封包調查與真桌驗收條件 |
| [REA 逆向調查](docs/reverse-engineering.md) | 原 APK 身分、GATT／封包、記憶／統計與 Evidence |
| [功能盤點](docs/features.md) | 25 項功能、官方截圖／手冊證據、已知與待確認行為 |
| [架構與假設](docs/architecture.md) | Android App 的控制抽象、模擬模型、統計／提醒規則與相容性界線 |
| [測試清單與案例](docs/test-plan.md) | 自動化、人工／模擬器、原 App 與實體桌的驗收矩陣 |
| [驗證紀錄](docs/verification.md) | Android App 的實際測試結果、畫面與未驗證項 |
| [後續自動化](docs/automation.md) | 坐站週期、工作時段、手動確認、捷徑與自動 session 的順序和驗收 |

## 專案進度

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
- [ ] Clock 番茄鐘自動升降
  - [x] Gate 1–3：偵測可行性、只記錄的偵測原型、真桌串接
  - [ ] Gate 4：日常長期試用
  - [ ] 睡眠、重新登入、UI 語言與隱藏選單列項目的實機測試

Android App 已依 REA 的原 App 熱量公式與期間截斷方式更新計算。模擬預設值、記憶長按手勢、可調站立門檻與前景統計仍有相容性差異，詳見架構及功能盤點。模擬器通過不代表已相容真桌。
