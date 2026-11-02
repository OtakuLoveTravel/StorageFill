# StorageFill — iPhone 存储空间清洗 App

一个原生 SwiftUI App：把 App 沙盒里的空间写到「可用空间 − 保留余量」，再一键删除，反复 N 轮。
在空间被写紧的过程中，iOS 会主动回收各 App 的缓存、日志等可清除数据——这就是"清洗"效果；删除后可用空间回涨的部分即净释放量。

## ⚠️ 使用前提（务必读完）

1. **默认保留 500 MB 余量**，不要改成 0。真正写到 0 会导致系统卡死、无法拍照，极端情况需要连电脑恢复。
2. 运行期间保持 App **前台 + 不锁屏**（App 已自动禁用息屏），手机会发烫、变卡，属正常现象。
3. App 只能写自己的沙盒目录（iOS 安全限制），**它删不掉系统或其他 App 的垃圾**，别把它当清理大师用。

## 目录结构

```
StorageFill/
├── StorageFill.xcodeproj/          # Xcode 工程（Xcode 15+ 直接打开）
├── StorageFill/                    # 源码
│   ├── StorageFillApp.swift        # 入口
│   ├── ContentView.swift           # 界面（参数 / 进度 / 日志）
│   ├── StorageEngine.swift         # 写入 & 清理引擎
│   └── Assets.xcassets             # 图标 / 主题色
└── .github/workflows/build.yml     # GitHub Actions：云端构建未签名 ipa
```

## 方案 A：有 Mac（朋友 / 公司电脑也行）—— 5 分钟搞定

1. 把整个 `StorageFill` 文件夹拷到 Mac，双击 `StorageFill.xcodeproj`。
2. 左侧选中项目 → TARGETS 选 `StorageFill` → **Signing & Capabilities**：
   - Team 选你登录的 Apple ID（没有就 Xcode → Settings → Accounts 添加，免费即可）；
   - Bundle Identifier 随便改一个独一无二的，如 `com.你的名字.storagefill`。
3. iPhone 用数据线连 Mac，顶部设备栏选中你的 iPhone。
4. 手机上：**设置 → 隐私与安全性 → 开发者模式 → 打开**（iOS 16+，需重启生效）。
5. Xcode 按 `⌘R` 运行。首次安装如果报 `Untrusted Developer`，去手机 **设置 → 通用 → VPN与设备管理** 里信任你的证书。

## 方案 B：只有 Windows —— GitHub 云端构建 + 侧载 

### 第 1 步：云端拿到 ipa   已打包直接下载就好

1. 仓库页 → **Actions** 标签 → 左侧 `Build unsigned IPA` → **Run workflow** 手动触发。
2. 等 3~5 分钟，该次运行页面底部的 **Artifacts** 里下载 `StorageFill-ipa`，解压得到 `StorageFill.ipa`。

### 第 2 步：侧载安装到 iPhone（Windows 上用 Sideloadly）

1. 下载安装 [Sideloadly](https://sideloadly.io)（需要先装 iTunes 的驱动包，官网有说明）。
2. iPhone 用数据线连电脑，打开 Sideloadly：
   - 拖入 `StorageFill.ipa`；
   - Apple ID 填你的 iCloud 账号；
   - 点 Start，等它自动重签并安装。
   - 开了双重认证的话，密码栏填「应用专用密码」（appleid.apple.com → 登录与安全 → App 专用密码）。
3. 手机上信任证书 + 打开开发者模式（同方案 A 第 4、5 步）。

### 有效期注意

- **免费 Apple ID 签名只有 7 天**，到期后 App 打不开，重新用 Sideloadly 签一次即可（数据会保留）。
- 付费开发者账号（$99/年）签一次管 1 年。

## App 内参数建议

| 参数 | 建议值 | 说明 |
|------|--------|------|
| 保留余量 | 500 MB | 安全线；想更彻底选 200 MB，但期间手机明显卡顿 |
| 循环轮数 | 3 轮 | 第 1 轮收益最大（系统大量清缓存），后面几轮是巩固 |
| 运行时机 | 睡前插电挂机 | 写满几十 GB 需要时间，别白天急用手机时跑 |

## 技术细节

- 写入块 8 MB 伪随机数据，非原子写入，空间不足时立刻抛错停止，不会误写。
- 文件标记了 `isExcludedFromBackup`，不会吃掉你的 iCloud 备份空间。
- App 异常被杀后，下次启动会自动清理残留的填充文件。
- 写入在独立线程执行，UI 全程可响应，随时可点"停止"。
