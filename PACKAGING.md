# FilterInspection — Windows 安裝檔打包指南

本文件說明如何把這個專案打包成一份可以交給廠商的 Windows 安裝檔
（`FilterInspection_Setup_vX.Y.Z.exe`），廠商拿到的只有編譯後的
執行檔，看不到 Python 原始碼。

---

## 1. 專案分析摘要

### 1.1 程式進入點

這個程式是**兩個 Python 行程**組成的（刻意設計，見
[`nircam_launcher.pyw`](NIRcam-first/nircam_launcher.pyw) 檔頭註解）：

| 行程 | 檔案 | 用途 | GUI 框架 |
|---|---|---|---|
| 前台 splash | `NIRcam-first/nircam_launcher.pyw` | 顯示啟動動畫，不 import PyQt5/torch，開機瞬間顯示 | **Tkinter** |
| 核心 GUI | `NIRcam-first/BasicDemo.py` | 相機取流、AI 偵測、主視窗 | **PyQt5** |

splash 用 `subprocess.Popen([sys.executable, "-s", "-u", "BasicDemo.py"], ...)`
把 `BasicDemo.py` 當子行程拉起來，等子行程開出可見視窗後才關閉自己。
這個設計是為了避免 262MB 的模型權重載入去卡住動畫的事件迴圈。

打包後這個關係維持不變，只是子行程換成呼叫 `BasicDemo.exe`
（見第 4 節「必改程式碼」）。

### 1.2 相依套件

根目錄 [`requirements.txt`](requirements.txt)：

| 套件 | 重量級？ | 備註 |
|---|---|---|
| `torch>=2.2` / `torchvision>=0.17` | **重** | 需搭配 CUDA 12.1（`cu121`），推論走 GPU 才能滿足產線節拍 |
| `opencv-python-headless` | 中 | 必須是 headless 版，非 headless 會跟 PyQt5 搶 Qt plugin |
| `PyQt5` | 中 | 主 GUI 框架 |
| `numpy<2` | 輕 | 版本鎖死，opencv C extension 綁 1.x ABI |
| `scipy` | 輕 | SimpleTracker 用匈牙利演算法 |
| `PyYAML` | 輕 | 設定檔 |

`NIRcam-first/requirements.txt` 是舊版/子集，打包以根目錄
`requirements.txt` 為準。`ultralytics`、`anomalib` 明確標註不需要。

### 1.3 推論框架

**PyTorch 原生模型**（不是 ONNX）。權重檔是
[`weights/supervised_global.pt`](weights/README.md)（274MB，
git 不追蹤，需另外複製到機器上），由 `hybrid_detect.load_model()`
載入，經 `CamOperation_class.set_ai_model()` 注入主程式。

### 1.4 核心演算法／敏感清單

以下檔案視為核心演算法/商業邏輯，**不對廠商揭露原始碼**
（Nuitka `--standalone` 編譯，只列檔名不列內容）：

- `NIRcam-first/hybrid_detect.py`
- `NIRcam-first/detect.py`
- `NIRcam-first/supervised_detect.py`
- `NIRcam-first/two_band_filter.py`
- `NIRcam-first/simple_tracker.py`
- `inspection/enhance.py`
- `inspection/gpu_preprocess.py`

> 註：Nuitka `--standalone` 是整支程式一起編譯成機器碼，沒有「只編譯這幾支、
> 其餘留明碼 .py」這種選項——所以實務上 `BasicDemo.exe` 裡的**所有**
> 第一方程式碼（含 GUI 玻璃碼）都會被編譯保護，上面清單是「至少要保護到」
> 的範圍，不是「僅保護這些」。第三方套件（`MvImport/`、PyQt5、torch 本身）
> 不算，也不需要保護。

### 1.5 GUI 套件與 Nuitka plugin

- `BasicDemo.exe`：`--enable-plugin=pyqt5`
- `nircam_launcher.exe`：`--enable-plugin=tk-inter`
  （splash 用純 Tkinter，刻意不 import PyQt5，見 1.1）

### 1.6 版本控管現況

- 有 git 版本紀錄（`master` / feature 分支流程）。
- **目前沒有任何版本號機制**（沒有 `version.py`、沒有 `__version__`）。
  本 pipeline 新增 `NIRcam-first/version.py` 來補這個洞（見第 2 節）。

---

## 2. 版本號規則（SemVer：`major.minor.patch`）

| 位數 | 何時要加 | 範例情境 |
|---|---|---|
| **major** | 破壞性變更：設定檔格式改變、模型輸出格式改變、需要重新校正產線或重新訓練 | 換一顆新模型、`test_config.json` 欄位改名 |
| **minor** | 新功能但相容既有流程 | 新增一種偵測模式、新增一個 UI 面板 |
| **patch** | Bug 修復、小幅調校，行為不變 | 修相機重連 bug、調 UI 文字、修 boundary filter 誤判 |

版本號存放位置：`NIRcam-first/version.py`

```python
VERSION = "1.0.0"
```

`BasicDemo.py` 主視窗標題列與「關於」對話框顯示 `f"itri AI detect v{VERSION}"`。
`build.ps1` 直接讀這個檔案取得版本號，安裝檔檔名也用它。

---

## 3. 打包 Pipeline 流程圖

```
┌─────────────────────────────────────────────────────────────────┐
│ 0. 前置需求（一次性，開發機安裝）                                 │
│    - MSVC Build Tools（C++ build tools workload）                │
│    - Nuitka（pip install nuitka）                                 │
│    - Inno Setup 6（choco install innosetup 或官網下載）           │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. 手動：確認 NIRcam-first/version.py 版本號已更新                │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. 手動（僅第一次 / 每次改權重）：用假權重檔跑一次 build 驗證流程   │
│    見「4. 敏感內容 / 假權重檔測試流程」                            │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. 自動（build.ps1）：Nuitka 編譯                                 │
│    3a. nircam_launcher.pyw → nircam_launcher.exe（onefile）      │
│    3b. BasicDemo.py        → BasicDemo.exe（standalone 資料夾）  │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. 自動（build.ps1 呼叫 ISCC.exe）：Inno Setup 編譯安裝檔          │
│    輸出 FilterInspection_Setup_v{VERSION}.exe                    │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. 自動：搬到 dist/ 資料夾，印出完成訊息與路徑                     │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. 手動：驗收測試（見第 7 節），確認換回真權重檔且 GPU 真的有跑     │
└───────────────────────────┬─────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. 交機：廠商執行安裝檔 → 精靈顯示機器識別碼 → 你來回一次授權碼      │
│    → 授權碼驗證通過才會裝完（見第 5.1 節，這一步需要人工來回）      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 敏感內容 / 假權重檔測試流程

因為 3b 的敏感範圍在 Nuitka standalone 模式下是「整支程式一起保護」，
不需要「先塞假邏輯、事後手動換檔」這種源碼層級的偷天換日。**唯一需要
手動換檔的是 274MB 的權重檔**（開發時可能用小的測試權重跑得比較快）：

1. 開發/除錯打包腳本時，`weights/supervised_global.pt`
   換成一顆幾 KB 的 dummy `.pt`（隨便存一個空的 state_dict 即可），
   跑完整條 pipeline，確認 Nuitka 編譯、Inno Setup 打包都不報錯、
   安裝後程式能開啟。
2. **用假權重檔跑完整流程時，一併驗證授權機制擋得住錯誤指紋**：
   安裝後先不要放 `license.key`，確認程式跳出「找不到授權檔」訊息框並乾淨結束；
   接著放一個內容錯誤（例如隨便打的字串）的 `license.key`，確認跳出
   「授權檔與這台機器不符」並乾淨結束，不能看到 Python traceback。
   兩種情況都要試過，流程都對了才進第 3 步換真權重檔。
3. **【手動步驟，不可省略】** 確認要出正式版之前，
   把 `weights/supervised_global.pt` **換回真正的 274MB 權重檔**，
   重新執行一次 `build.ps1`，重新產生正式的 `FilterInspection_Setup_v{VERSION}.exe`，
   並用第 5.1 節的流程實際發一把正確的 `license.key` 出來驗證能正常啟動。
4. 用檔案大小或 hash 做一個簡單自我檢查：正式打包前
   `build.ps1` 會印出 `weights/supervised_global.pt` 的檔案大小，
   **小於 100MB 就中止 build 並警告**（避免手滑拿假權重檔出正式安裝檔）。

> 四項必改程式碼（`version.py`、`license_check.py`、MVS 檢查、launcher 改呼叫
> `BasicDemo.exe`）建議**逐項獨立驗證**，不要一次改完才測：尤其是
> `license_check.py` 呼叫 PowerShell 失敗時的容錯路徑，以及 launcher 用
> list 形式傳遞帶空白的安裝路徑這兩點，各自單獨測過一次再合起來跑
> 完整 pipeline，出問題時比較好定位是哪一項改動造成的。

---

## 5. 授權 / 機器綁定（簡易版，非硬體加密狗）

- 機器指紋取法：**不使用 `wmic.exe`**（Windows 11 已棄用、新機可能沒裝），
  改用 PowerShell `Get-CimInstance Win32_ComputerSystemProduct` 取
  `UUID`，Python 端用 `subprocess.run(["powershell", "-Command", ...])`
  呼叫，取得結果後做 SHA-256 雜湊。
- 綁定檔：安裝目錄下 `license.key`，內容是
  `HMAC-SHA256(機器指紋雜湊, 私鑰)` 簽章過的字串，私鑰只在你這邊，
  不寫進程式碼倉庫。
- **檢查點放兩處**（缺一不可，否則繞過 launcher 直接雙擊
  `BasicDemo.exe` 就能跳過授權）：
  1. `nircam_launcher.pyw` 啟動時檢查一次
  2. `BasicDemo.py` 啟動時（`session_log` 啟動之後、載入 PyQt5/模型之前）再檢查一次
  兩處呼叫同一個共用函式，見 `NIRcam-first/license_check.py`。
- 授權失敗時的行為：跳原生訊息框告知「請聯絡窗口取得授權」，
  然後 `sys.exit(1)`——不能讓廠商看到 Python traceback。
  `get_machine_fingerprint()` 對「PowerShell 不存在／逾時／輸出空白」這幾種
  情況一律回傳 `None` 而不是拋例外，`verify_license()` 把 `None` 當成
  「無法驗證」處理，同樣走乾淨結束的訊息框路徑，不會讓廠商看到未捕捉的例外。
- 呼叫子行程一律用 list 形式傳參數（`subprocess.Popen([exe_path, ...])`），
  不要組成單一字串——安裝路徑是 `C:\Program Files\FilterInspection\`，
  中間有空白，字串形式會被空白截斷找不到檔案。

### 5.1 授權金鑰發放流程

授權碼的輸入**直接內建在安裝精靈裡**（`installer/setup.iss` 的 `[Code]`
段），不是裝完之後另外再跑一次工具。安裝過程中會多一頁：

1. 廠商執行 `FilterInspection_Setup_v{VERSION}.exe`，一路下一步到「軟體授權」頁
2. 這一頁會**自動**顯示這台機器的「機器識別碼」（唯讀，不能改），
   廠商把這串文字複製，透過 LINE/Email 傳給你
3. 你在自己電腦上執行：
   ```powershell
   python tools\license\generate_license.py <廠商傳來的機器識別碼>
   ```
   產生 `license.key`（這個檔案的內容就是「授權碼」字串）
4. 把授權碼字串（`license.key` 打開複製內容，或直接把整段字串）回傳給廠商，
   請他們貼進安裝精靈「授權碼」欄位，按下一步，安裝才會繼續完成
5. 授權碼比對錯誤時，精靈會跳出錯誤訊息並卡在該頁，不會讓安裝繼續；
   比對成功後，安裝完成的同時 `license.key` 會自動寫進安裝目錄，
   **不需要廠商再手動放檔案**

> 技術細節：精靈頁背後呼叫的是隨裝機暫存的 `LicenseActivator.exe`
> （`tools/license/license_installer_helper.py` 編譯來的，只給安裝程式用，
> 不會出現在最終安裝目錄），比對邏輯跟執行期 `license_check.py` 完全共用
> 同一份 `SECRET_KEY`，寫進磁碟的是工具算出來的標準化雜湊值，不是廠商
> 貼上的原始文字，避免大小寫或多餘空白造成事後比對失敗。

### 5.2 換機器 / 重新啟用（不重跑整個安裝）

如果裝完之後廠商換了硬體、重灌系統，導致機器識別碼改變，`license.key`
就會失效。這時候**不需要重跑整個安裝程式**，用比較輕量的方式：

1. 廠商執行安裝目錄下 `Tools\FingerprintTool.exe`（雙擊即可，會印出新的
   機器識別碼），把印出來的字串回傳給你
2. 你一樣用 `python tools\license\generate_license.py <新識別碼>` 產生新的
   `license.key`
3. 把新的 `license.key` 傳回去，請廠商覆蓋安裝目錄裡舊的那個檔案

（也可以選擇直接重新執行一次 `FilterInspection_Setup_v{VERSION}.exe`，
走一次跟第一次安裝一樣的精靈流程，效果相同，只是比較重。）

`license_check.py` 裡的 `SECRET_KEY` 是所有授權相關工具（`license_check.py`
本身、`LicenseActivator.exe`、`generate_license.py`）共用的簽章金鑰，
**正式出貨前務必換成你自己的隨機字串**，並且只放在你自己的電腦上。
即使 `LicenseActivator.exe` 和 `FingerprintTool.exe` 會隨安裝檔/安裝過程
出現在廠商機器上，`SECRET_KEY` 仍會被 Nuitka 一起編譯進這些二進位檔裡
（沒有辦法讓「驗證邏輯」出現在廠商機器上、又完全不讓金鑰出現在裡面）；
這是本方案「非硬體加密狗」的已知限制，見第 10 節。

---

## 6. MVS 相機 SDK 檢查

安裝檔**不**內建 Hikvision MVS runtime（假設目標機器已裝好，
因為裝相機本來就要裝 MVS 驅動）。但要在程式啟動時做**明確的失敗訊息**，
而不是讓 `WinDLL("MvCameraControl.dll")` 丟出原始例外把使用者嚇到：

- 在 `BasicDemo.py` import `MvImport.MvCameraControl_class` 之前，
  先嘗試 `ctypes.WinDLL("MvCameraControl.dll")`，失敗就跳訊息框：
  「找不到 Hikvision MVS 驅動，請先安裝 MVS Runtime（聯絡窗口：___）」，
  然後 `sys.exit(1)`。
- Inno Setup 安裝完成頁加一行文字提示：「若尚未安裝相機廠商的 MVS
  驅動程式，請先安裝後再啟動本程式」。

---

## 7. 驗收條件（Definition of Done）

打包完成後，**必須**在一台乾淨環境（沒裝過 Python/conda，但已裝好
顯示卡驅動 + MVS runtime）的 Windows 機器上實測，且滿足全部：

- [ ] 安裝檔可以正常安裝，桌面/開始選單捷徑指向 `nircam_launcher.exe`
- [ ] 雙擊捷徑後，splash 正常顯示動畫，並在數秒內接手顯示主視窗
- [ ] 主視窗畫面上顯示的推論裝置字串確認是 **CUDA/GPU**，不是悄悄退回 CPU
      （Nuitka 常見的坑：編譯不報錯，但 CUDA/cuDNN DLL 沒被掃到，
      跑到別台機器上退回 CPU 模式或直接崩潰）
- [ ] 單張推論耗時跟開發機（約 45ms 等級）數量級相近，不是慢好幾倍
- [ ] 安裝過程中的「軟體授權」頁能正確顯示機器識別碼，
      輸入錯誤/隨便打的授權碼會被擋下且不能繼續安裝
- [ ] 輸入正確授權碼後安裝完成，**不用手動放檔案**，
      `license.key` 已自動出現在安裝目錄
- [ ] 把已裝好的 `license.key` 換成別台機器的內容（或刪掉），
      程式應該拒絕啟動並顯示提示，不是崩潰
- [ ] 刻意搬移到沒裝 MVS runtime 的機器上，應顯示明確提示而非崩潰
- [ ] 直接雙擊 `BasicDemo.exe`（跳過 launcher）也會被授權檢查擋下

---

## 8. 每次出新版本要做的事（操作手冊）

1. 確認程式碼已經在 `master`（或指定分支）上測試過、可正常運作
2. 修改 `NIRcam-first/version.py` 的 `VERSION`（依第 2 節規則決定加哪一位）
3. 確認 `weights/supervised_global.pt` 是**正式權重檔**（檔案大小 > 100MB）
4. 在開發機上開啟終端機，執行：
   ```powershell
   .\build.ps1
   ```
5. 腳本跑完後，到 `dist/FilterInspection_Setup_v{VERSION}.exe` 確認產出
6. 依第 7 節「驗收條件」在乾淨機器上實測
7. 驗收通過後，才把安裝檔交給廠商（USB / 內部網路傳輸，
   **不要**上傳到公開的檔案分享服務）
8. 在內部記錄這次交付的版本號、日期、交付對象（方便日後追蹤）

---

## 9. 必改程式碼（已完成）

以下一次性程式碼調整已經完成，不是 `build.ps1` 能自動生出來的：

1. `NIRcam-first/nircam_launcher.pyw`：`launch()` 改成優先呼叫同目錄的
   `BasicDemo.exe`（存在的話），找不到才退回 `sys.executable BasicDemo.py`
   （開發模式，尚未跑過 `build.ps1` 時用）。子行程參數一律用 list 傳
   （不是拼接字串），避免 `C:\Program Files\FilterInspection\` 路徑裡的
   空白把命令截斷。啟動時也會呼叫一次 `enforce_license_or_exit()`。
2. 新增 `NIRcam-first/version.py`（見第 2 節）。
3. 新增 `NIRcam-first/license_check.py`（見第 5 節）：
   `get_machine_fingerprint()` 對 PowerShell 失敗/逾時/空輸出一律回傳
   `None` 而不拋例外；`nircam_launcher.pyw` 和 `BasicDemo.py` 都各呼叫一次
   `enforce_license_or_exit()`。
4. `BasicDemo.py` 在 `import MvImport.MvCameraControl_class` 之前，先用
   `ctypes.WinDLL("MvCameraControl.dll")` 探測，抓不到就跳訊息框、
   `sys.exit(1)`，不會讓 `import *` 內部的 `OSError` 變成使用者看到的崩潰。
5. 新增三支授權相關工具，見第 5.1、5.2 節：
   - `tools/license/license_installer_helper.py` → 編譯成 `LicenseActivator.exe`，
     只給 `installer/setup.iss` 的安裝精靈呼叫，讓「顯示機器識別碼、
     輸入授權碼、驗證、寫入 `license.key`」整個流程都在安裝過程中完成
   - `tools/license/print_fingerprint.py` → 編譯成 `Tools\FingerprintTool.exe`，
     隨裝機出貨，僅用於裝完之後的重新啟用（換機器/重灌）
   - `tools/license/generate_license.py`（只在你自己電腦上跑，不編譯、
     不出貨）：拿機器識別碼簽出授權碼
6. `installer/setup.iss` 新增一個安裝精靈頁（`[Code]` 段的
   `CreateInputQueryPage` + `NextButtonClick` + `CurStepChanged`），
   把授權驗證整合進安裝流程本身。

---

## 10. 已知限制與後續強化方向

- **安裝檔不能無人值守靜默安裝**：因為授權碼要在安裝過程中人工輸入，
  `FilterInspection_Setup_v{VERSION}.exe /VERYSILENT` 這種靜默安裝參數
  沒辦法完成（精靈頁會卡住等輸入）。如果之後有大量部署需求，需要另外
  設計一個「/LICENSECODE=xxx」之類的命令列參數，在 `[Code]` 裡判斷
  `ExpandConstant('{param:LICENSECODE}')` 略過互動頁直接驗證。
- **無 CI/CD**：目前打包是手動在開發機上跑 `build.ps1`。之後可以接
  GitHub Actions self-hosted runner（因為要 GPU 機器）或內部 Jenkins，
  在打 tag 時自動觸發打包。
- **授權機制很陽春**：只防止「整包資料夾複製到別台機器」，
  不防止逆向工程或記憶體內取模型權重。如果之後有更高保護需求，
  可以考慮商用 licensing SDK（如 Cryptolens）或程式碼混淆（如 PyArmor
  搭配 Nuitka）。
- **安裝檔沒有數位簽章**：Windows SmartScreen 可能會警告「未知發行者」。
  之後可以買程式碼簽章憑證（Code Signing Certificate）簽署 exe/安裝檔。
- **CUDA/cuDNN DLL 掃描是 Nuitka 已知的脆弱點**：每次升級 torch 版本
  都建議重新走一次第 7 節驗收流程，不要假設「編譯成功=能跑」。
- **假權重檔測試流程仰賴人工記得換回真檔**：`build.ps1` 已加檔案大小
  守門（<100MB 中止），但這只是最後一道防線，不是萬無一失。
