# 独立刘海框架：开发切片与验证状态

2026-10-19。真实源码已按三个独立仓库准备；未创建远端、提交、发布、启用 Pages、购买会员或创建生产密钥。原 codex-notch-meter / vga-aram-helper 完全未修改。

## 已实现

- Swift 5.9、macOS 13+ 宿主与 Core SDK；SwiftUI 扩展中心、实际刘海面板和沿开放外轮廓的进度显示。扩展数据经独立进程 JSON-lines IPC 返回。
- 本地开发目录安装：manifest、SemVer、文件精确清单、路径/符号链接/体积检查，版本目录与原子索引；默认禁用、启停、升级、回滚、可恢复卸载。
- 签名网络链路：Ed25519 精确 payload 字节验签、过期/回放拒绝、缓存再验证、有界 HTTP(S) 下载、SHA-256、原生 Swift ZIP_STORED 严格解析、manifest/签名目录身份绑定、私有 staging、复制后逐文件摘要再核对。
- App 中连接本机测试源、刷新已签名目录、展示权限/体积、下载并安装测试包；用户确认后做真实 Hello 健康检查，失败或提交后取消会尝试恢复旧版本（恢复失败明确显示），成功仍保持禁用。
- 正常 GitHub Pages/raw 公开目录可以通过 HTTPS 地址在 App 内下载、缓存及浏览，独立标记“未验证预览”。没有假装存在的默认远程地址。预览不授权执行；正式包执行仍等待生产信任配置。
- 测试网络使用公开 RFC8032 向量，不创建秘密或长期访问凭据。此模式严格只接受数值 loopback HTTP，包括重定向和包地址，无法用公开测试 key 授权 GitHub 远端可执行包。
- 所有 stop/remove 路径统一保留正在退出的进程；停止后 owner 不可再次启动，常规停止异步 TERM→KILL，退出立即 KILL 直接子进程。stopAll 有操作屏障，避免异步旧清理覆盖新启用。
- 包复制/哈希/验证/回滚在可取消后台工作中，不在 UI 主线程做这些大文件操作。小型本地配置/预览缓存仍有先检查上限的同步读取。
- 独立 Hello 仓库、静态 registry 仓库、各自 CI；Framework CI 已接 native loopback network smoke，不需先创建第二仓才运行。

## 已实际验证与未验证

当前云端 Linux 没有 Swift/AppKit：
- Framework Python 工具测试 9/9 通过（含真实本机 HTTP 服务、STORED 归档与路径安全）。
- Registry Python 测试 6/6 通过。
- build shell 脚本均通过 bash -n；样例 JSON 可解析，目录结构校验通过。
- Python cryptography 实际生成并验证了公开 RFC 测试 key 的目录签名；该固定 fixture 供 CryptoKit 交叉验证。
- 独立只读安全审查发现的 loopback 信任范围、停止后重新启动、Quit 清理、异步状态竞争、取消恢复和选择绑定问题已修改并通过静态复审。

**Swift 编译、30 项 XCTest、NotchSmoke、NotchNetworkSmoke、macOS App UI 均尚未执行。** Python 成功不是 Swift 成功；静态审查不是发版验收。macOS CI 是下一道必需门槛。

## 生产边界

- 生产可信签名根尚未配置，不能称正式 GitHub App 内安装已可发布。不存在生产私钥、PAT、OAuth secret 或 Developer ID 证书。
- 核心支持固定 owner 的 Pages/raw 目录与该 owner 下独立仓库的固定 Releases URL；App 的现成执行配置仅限本机测试。生产信任根建立、签名身份政策和公证须另行核对授权。
- v1 ZIP 只支持无 extras/comment/data-descriptor 的普通 ZIP_STORED 文件。拒绝 deflate、ZIP64、符号链接、目录记录和歧义布局；目录由文件路径安全合成。打包工具已按此生成，不能把任意第三方 ZIP 当兼容包。
- 签名目录与包摘要联结已经实现；尚未实现独立 publisher 包签名/Apple Team ID 校验、公证门禁、生产撤销列表/密钥轮换及跨来源授权。
- 普通子进程不是安全沙箱；P0只支持不生成后代的受控扩展（Hello符合），不支持会派生子进程的扩展，也不保证终止恶意后代。退出完整进程树清理需后续受控runner/预exec进程组设计，不在本切片冒充实现。同 UID 恶意进程仍可攻击私有存储的 check/use 间隙、修改已安装文件；已实现持久文件摘要及启用/启动/回滚前重验，但同UID攻击者也可能同时修改清单，因此仍不得宣传抵御同用户恶意进程。
- 已有可验证目录缓存，但尚无 ETag/304 条件请求、自动更新调度或 Retry-After 专项策略；当前用户手动刷新有30秒冷却，无自动轮询风暴。
- 五皮肤、统一动画时钟、hover/滑动仲裁、通知队列和业务功能迁移未实现；刘海显示是验证数据路径的静态最小切片。
- 无刘海屏幕不自动画假刘海。公开 NSScreen API 给的是排除矩形，不是精确物理曲线。
- 开发 App build 脚本仅 ad-hoc seal，不是 Developer ID/公证；不清除 quarantine、不关闭 Gatekeeper。

## macOS CI 与本地验收命令

Framework 自包含测试：

```sh
swift test
bash Tools/build-app.sh
bash Tools/verify-network-ci.sh
python3 -m unittest discover -s Tools -p 'test_*.py' -v
```

跨独立仓库验证（使用独立 Hello 源码）：

```sh
bash Tools/verify-local-slice.sh ../notch-extension-hello
```

以上均须在 macOS 执行。CI 的 Native smoke 编译一个专用测试进程，再依次检验真实 Hello IPC、本地安装/升级/回滚/卸载和本机 HTTP 网络下载/验签/ZIP/安装/IPC，并故意篡改包和签名确认拒绝。CI 不发布、不上传长期 artifacts、不启用 Pages。

## App 内网络安装手动验收

1. 在独立 Hello 项目执行 `bash Tools/build-fixture.sh`。
2. 在 Framework 执行 `bash Tools/build-app.sh`，打开自己构建的开发 App。
3. 启动测试源：`swift run NotchNetworkSmoke ../notch-extension-hello/dist/hello-0.1.0 --serve`。
4. 该命令打印临时 `test-source.json` 路径。App 点击“连接本机测试源”，选择此文件并确认风险。
5. “发现”中刷新签名目录，点击“下载并安装测试包”。确认体积/权限以及“运行一次测试”。应下载、验签、解包、安装、健康检查成功并保持禁用。
6. 点击启用确认，实体刘海屏幕显示扩展真实数据。停用应停止直接子进程并移除面板。
7. 升级失败、下载中取消、提交后取消、连续StopAll/启用、子进程异常退出、Quit 时忽略TERM，分别检查磁盘索引和真实进程状态，不仅检查文字。
8. 修改目录签名、归档内容、目录id/version、未知key、过期/回放目录、远端redirect：均应拒绝，不执行包。
9. 测试源终端按 Return 结束，服务器关闭且临时文件清理。正式GitHub目录浏览可以另输入已创建并核实的Pages/raw地址；无生产信任根时只浏览不执行。

## 后续需要 root 核对

用户已批准三个公开仓库采用 MIT（Copyright (c) 2026 Junming-Liang）及初始代码 CI。核对最终文件 manifest 后，由获授权的发布流程创建公开远端并上传。首先运行macOS CI、修复真实编译/测试问题，再做实际App/刘海验收。是否建立生产签名根/付费Apple会员需单独决定，不把公开测试key用于发布。
