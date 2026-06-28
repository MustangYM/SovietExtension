<p align="center">
  <img src="./3.1.png" width="900" alt="SovietExtension Banner" />
</p>

<h1 align="center">SovietExtension 苏维埃助手</h1>

<p align="center">
  For 开源共产主义，For 理想主义。<br/>
  免费的，抽象的，令人愉快的 Mac 微信插件。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey.svg" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-M%20Chip-brightgreen.svg" />
  <img src="https://img.shields.io/badge/WeChat-4.0%2B-07C160.svg" />
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/fstudio/clangbuilder.svg" />
  </a>
  <a href="https://996.icu">
    <img src="https://img.shields.io/badge/link-996.icu-red.svg" />
  </a>
</p>

---

## Effect / 效果展示

<p align="center">
  <img src="./1.5.png" width="600" alt="SovietExtension Effect 1" />
</p>

<p align="center">
  <img src="./2.1.png" width="600" alt="SovietExtension Effect 2" />
</p>

---

## Supported Version / 支持版本

> **睁大眼睛看：目前只支持下表列出的 Apple Silicon / M 芯片版本。**
> 本人没有 Intel 机器，无法开发和测试 Intel 版本，所以 Intel 版目前无效。
> 微信 4.x QT 化之后逆向起来比较麻烦，其他版本随缘适配。
> 代码已完全开源，可自行查看，爱你。

请注意：[微信官网](https://mac.weixin.qq.com/) 显示的大版本号可能一致，但实际小版本和 Build 号可能不同。
使用前请务必核对完整版本号和 Build 号。

| 微信版本      | Build 号 | Apple Silicon / M 芯片 | Intel | 下载地址                                                                        | 说明                       |
| --------- | ------: | :------------------: | :---: | --------------------------------------------------------------------------- | ------------------------ |
| 4.1.10.53 |  268853 |         ✅ 支持         | ❌ 不支持 | [微信官网](https://weixin.qq.com/updates?platform=mac&version=4.1.10)           | 截止 2026-06-19，我在官网下载到的版本 |
| 4.1.9.58  |  268602 |         ✅ 支持         | ❌ 不支持 | [GitHub 归档](https://github.com/zsbai/wechat-versions/releases/tag/4.1.9.58) | 已测试                      |

> 不在表格中的版本暂不保证可用。
> 即使大版本看起来一样，只要 Build 号不同，也可能无法使用。

---

## Install / 安装

### 1. 先打开一次微信

如果是刚安装的微信，请先手动打开一次微信，然后再安装插件。

否则安装完成后，可能会提示：

```text
“xxx” 已损坏，无法打开。
```

### 2. 执行安装脚本

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/MustangYM/SovietExtension/main/soviet.sh | bash -s install
```

或克隆仓库后，进入 `Rely` 文件夹执行 `install.sh`：

```bash
cd SovietExtension/Rely
sh install.sh
```

或者直接执行完整路径：

```bash
sh /Users/mustangym/SovietExtension/SovietExtension/Rely/install.sh
```

安装过程示例：

```text
mustangym@macdeMacBook-Pro Rely % sh /Users/mustangym/SovietExtension/SovietExtension/Rely/install.sh

==============================
 Install SovietExtension
==============================

APP_PATH=/Applications/WeChat.app
PLUGIN_SRC_PATH=/Users/mustangym/SovietExtension/SovietExtension/Rely/Plugin/SovietExtension.framework
FRAMEWORK_DST_PATH=/Applications/WeChat.app/Contents/MacOS/SovietExtension.framework
INSERT_DYLIB_PATH=/Users/mustangym/SovietExtension/SovietExtension/Rely/insert_dylib
SUPPORTED_FILE=/Users/mustangym/SovietExtension/SovietExtension/Rely/supported_versions.txt
LOAD_DYLIB_PATH=@executable_path/SovietExtension.framework/SovietExtension

👉 [INFO] Detected WeChat version / 检测到微信版本:
    CFBundleShortVersionString: 4.1.9
    CFBundleVersion:            268602

✅ [OK] Version supported / 版本检查通过
    Supported Display Version: 4.1.9.58
    Matched Rule:              4.1.9.58|4.1.9|268602|Tested on Mac WeChat 4.1.9.58

...省略一万句...

👉 [INFO] Verify code signature / 检查签名...
⚠️  [WARN] Code signature verification failed, but app may still run for debugging / 签名验证未完全通过，但调试运行不一定受影响

==============================
✅ SovietExtension installed successfully
✅ SovietExtension 安装完成
==============================

Run WeChat and watch log / 启动微信并查看日志：
  rm -f /tmp/YMWeChatAntiRevokePatch.log
  open -a WeChat
  tail -f /tmp/YMWeChatAntiRevokePatch.log

Uninstall / 卸载：
  /Users/mustangym/SovietExtension/SovietExtension/Rely/uninstall.sh
```

---

## Troubleshooting / 常见问题

### 1. 提示 `Operation not permitted`

如果安装时报错：

```text
cp: xxxxx: Operation not permitted
```

请到：

```text
系统设置 → 隐私与安全性
```

给你当前运行脚本的“终端工具”开启以下权限：

| 权限                          | 说明         |
| --------------------------- | ---------- |
| 完整磁盘访问权限 / Full Disk Access | 允许脚本修改应用目录 |
| 文件与文件夹 / Files and Folders  | 允许访问相关文件   |

常见终端工具包括：

* Terminal / 终端
* iTerm2
* VSCode
* Cursor
* Warp

你用哪个工具执行脚本，就给哪个工具开权限。

### 2. 如果反复弹窗提示[”微信“想访问其他App的数据]
```text
在系统设置中打开微信”完全磁盘访问“，如果微信已经在里面，则删除后重新添加。
```

---

### 3. 提示版本不支持

请确认你的微信版本和 Build 号是否在支持表格中。

查看方式：

```bash
defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleShortVersionString
defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleVersion
```

只有表格中明确列出的版本才保证可用。

---

### 4. 安装后微信打不开

可先执行卸载脚本恢复：

```bash
sh /Users/mustangym/SovietExtension/SovietExtension/Rely/uninstall.sh
```

如果仍然打不开，可以删除微信后重新安装官方版本。

---

## Uninstall / 卸载

一键卸载：

```bash
curl -fsSL https://raw.githubusercontent.com/MustangYM/SovietExtension/main/soviet.sh | bash -s uninstall
```

或进入 `Rely` 文件夹，执行：

```bash
sh uninstall.sh
```

或者直接执行完整路径：

```bash
sh /Users/mustangym/SovietExtension/SovietExtension/Rely/uninstall.sh
```

---

## Notes / 说明

* 本项目仅用于学习、研究与个人折腾。
* 代码完全开源，可自行查看实现。
* 不接受除 Bug 以外的任何 Issue。
* 不接受任何形式的捐赠与收费。
* 其他版本适配随缘，别催，催就是你对。

---

## Thanks / 致谢

感谢湖畔大学全体同学。

**瑞思拜。**

MustangYM.

---

## License / 开源协议

<a href="LICENSE">
  <img src="https://img.shields.io/github/license/fstudio/clangbuilder.svg" />
</a>

<a href="https://996.icu">
  <img src="https://img.shields.io/badge/link-996.icu-red.svg" />
</a>
