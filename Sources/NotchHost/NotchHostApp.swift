import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotchExtensionCore

@main
@MainActor
struct NotchHostApp: App {
    @StateObject private var model = HostModel()
    var body: some Scene {
        WindowGroup("Notch 扩展中心") { ExtensionCenter(model: model).frame(minWidth: 740, minHeight: 500) }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("停止全部扩展") { model.stopAll() }
            }
        }
    }
}

@MainActor
final class HostModel: ObservableObject {
    @Published var installed: [InstalledExtension] = []
    @Published var catalog: CatalogDocument?
    @Published var signedCatalog: SignedCatalogPayload?
    @Published var hasNetworkSource = false
    @Published var status = "开发预览：仅运行你信任并在本地构建的扩展。普通子进程不是安全沙箱。"
    @Published var busy = false
    @Published var stopping = false
    @Published var publicCatalogAddress = ""
    private var lastPublicRefresh: Date?
    private let store: ExtensionStore?
    private let browser: CatalogBrowser
    private var transport: SignedPackageTransport?
    private var networkURL: URL?
    private var lastNetworkRefresh: Date?
    private var processes: [String: ExtensionProcess] = [:]
    private var retiredProcesses: [ExtensionProcess] = []
    private let overlay = NotchOverlay()
    private var launchGeneration = 0
    private var processMonitor: Timer?
    private var presentedID: String?
    private var terminationObserver: NSObjectProtocol?
    private var operationTask: Task<Void, Never>?
    private var refreshGeneration = 0
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchFramework-Development", isDirectory: true)
        store = try? ExtensionStore(rootURL: base.appendingPathComponent("Extensions", isDirectory: true))
        browser = CatalogBrowser(cacheURL: base.appendingPathComponent("catalog-cache.json"))
        catalog = try? browser.cached()
        // Developer mode never autoruns executable code after host restart.
        stopping = true
        operationTask = Task {
            try? await withStore { store in
                for item in try store.list() where item.enabled { try store.setEnabled(id:item.manifest.id,enabled:false) }
            }
            if launchGeneration == 0 { stopping = false }
            refresh()
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll(immediate:true) }
        }
    }
    func refresh() {
        refreshGeneration += 1; let generation = refreshGeneration
        Task {
            do { let list = try await withStore { try $0.list() }; if generation == refreshGeneration { installed = list } }
            catch { status = error.localizedDescription }
        }
    }
    func importFixture() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "选择本地构建目录"; panel.message = "目录需含 manifest.json 和自己构建的可执行文件。下载的未知程序不应通过开发模式运行。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let warning = NSAlert()
        warning.messageText = "将这个本地目录作为开发扩展安装？"
        warning.informativeText = "开发模式不验证发布者签名或公证。启用后它拥有当前用户进程权限，不是安全沙箱。安装后仍保持禁用。\n\(url.lastPathComponent)"
        warning.addButton(withTitle: "安装开发包"); warning.addButton(withTitle: "取消")
        guard warning.runModal() == .alertFirstButtonReturn else { return }
        for process in processes.values { retire(process) }; processes.removeAll(); overlay.hide()
        performStore { store in
            for item in try store.list() where item.enabled { try store.setEnabled(id:item.manifest.id,enabled:false) }
            _ = try store.installDeveloperFixture(from:url)
            return "开发包已安装，尚未启用。"
        }
    }
    func importCatalog() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { catalog = try browser.readLocal(url); status = "目录已校验格式并缓存；这不代表已验证发布者信任。" }
    }
    func enable(_ item: InstalledExtension) {
        guard !busy, !stopping else { return }
        let alert = NSAlert(); alert.messageText = "启用 \(item.manifest.name)？"
        alert.informativeText = "这将运行你安装的本地开发程序。其权限与当前用户进程相同。"
        alert.addButton(withTitle: "启用并运行"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        let generation = launchGeneration
        operationTask = Task {
            defer { if generation == launchGeneration { busy = false }; refresh() }
            do {
                guard generation == launchGeneration else { return }
                let process = try await withStore { store in
                    try store.setEnabled(id:item.manifest.id,enabled:true)
                    return try store.makeProcess(id:item.manifest.id)
                }
                guard generation == launchGeneration, !Task.isCancelled else {
                    retire(process); try? await withStore(cancellable:false) { try $0.setEnabled(id:item.manifest.id,enabled:false) }; return
                }
                stopProcess(id:item.manifest.id); processes[item.manifest.id] = process
                let hello = try await process.requestHello(timeout: 3)
                guard generation == launchGeneration, processes[item.manifest.id] === process else {
                    retire(process); try? await withStore(cancellable:false) { try $0.setEnabled(id:item.manifest.id,enabled:false) }; return
                }
                presentedID = item.manifest.id
                startProcessMonitor()
                overlay.show(title: hello.title, subtitle: hello.subtitle, progress: hello.progress)
                status = "\(item.manifest.name) 已连接。刘海显示使用该扩展真实 IPC 返回的数据。"
            } catch {
                stopProcess(id:item.manifest.id)
                try? await withStore(cancellable:false) { try $0.setEnabled(id:item.manifest.id,enabled:false) }
                status = "启动失败，已禁用：\(error.localizedDescription)"
            }
        }
    }
    func disable(_ item: InstalledExtension) {
        stopProcess(id:item.manifest.id); overlay.hide()
        performStore { store in try store.setEnabled(id:item.manifest.id,enabled:false); return "扩展已停止并禁用。" }
    }
    func rollback(_ item: InstalledExtension) {
        stopProcess(id:item.manifest.id); overlay.hide()
        performStore { store in
            try store.setEnabled(id:item.manifest.id,enabled:false)
            _ = try store.rollback(id:item.manifest.id)
            return "已回滚并保持禁用。"
        }
    }
    func uninstall(_ item: InstalledExtension) {
        let alert = NSAlert(); alert.messageText = "卸载 \(item.manifest.name)？"
        alert.informativeText = "停止扩展，并移入本应用的可恢复删除目录。"
        alert.addButton(withTitle:"卸载");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopProcess(id:item.manifest.id);overlay.hide()
        performStore { store in let backup = try store.uninstall(id:item.manifest.id); return "已卸载。恢复位置：\(backup.path)" }
    }
    func refreshPublicCatalog() {
        guard !busy, !stopping, let url = URL(string: publicCatalogAddress.trimmingCharacters(in:.whitespacesAndNewlines)) else { return }
        if let last = lastPublicRefresh, Date().timeIntervalSince(last) < 30 { status = "请等待 30 秒再刷新。"; return }
        lastPublicRefresh = Date(); busy = true
        Task {
            defer { busy = false }
            do { catalog = try await browser.fetchPublicPreview(from:url); status = "GitHub 目录已下载并缓存。当前为未验证预览；配置受信发布者后才能安装正式包。" }
            catch { status = "GitHub 目录读取失败，保留已有缓存：\(error.localizedDescription)" }
        }
    }
    func connectTestNetwork() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.message = "选择本地 fixture 生成的 test-source.json。此入口仅信任公开测试向量和本机 HTTP，不配置正式发布信任根。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let info = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 8192 else { throw CatalogError.invalid }
            let data = try Data(contentsOf: url)
            guard data.count <= 8192 else { throw CatalogError.invalid }
            let source = try JSONDecoder().decode(TestNetworkSource.self, from: data)
            guard source.keyID == "RFC8032-TEST-ONLY", source.catalogURL.scheme == "http", source.catalogURL.host == "127.0.0.1",
                  let key = Data(base64Encoded: source.publicKey), key.map({ String(format:"%02x",$0) }).joined() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" else { throw CatalogError.invalid }
            let warning = NSAlert(); warning.messageText = "连接本机开发测试目录？"
            warning.informativeText = "这个公钥是人人已知的测试向量，不代表可信发布者。只接受你在本机搭建的测试服务器。不会保存为生产信任根。"
            warning.addButton(withTitle:"连接测试目录"); warning.addButton(withTitle:"取消")
            guard warning.runModal() == .alertFirstButtonReturn else { return }
            let config = DistributionConfiguration(trustedKeys:[source.keyID:key],githubOwner:"test-owner",githubRepository:"test-registry",allowLoopbackHTTPForTests:true)
            let cache = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotchFramework-Development/NetworkTestCache")
            transport = try SignedPackageTransport(configuration:config,cacheDirectory:cache)
            networkURL = source.catalogURL; signedCatalog = nil; hasNetworkSource = true; lastNetworkRefresh = nil
            status = "已连接本机测试源，点击刷新签名目录。测试签名不是生产发布者认证。"
        }
    }
    func refreshNetwork() {
        guard let transport, let networkURL, !busy, !stopping else { return }
        if let last = lastNetworkRefresh, Date().timeIntervalSince(last) < 30 { status = "请等待 30 秒后再刷新，避免重复请求。"; return }
        lastNetworkRefresh = Date(); busy = true
        Task {
            defer { busy = false }
            do { signedCatalog = try await transport.fetchCatalog(from:networkURL); status = "已下载并验证测试目录签名，缓存已保存。" }
            catch {
                if let cached = try? await transport.cachedCatalog() {
                    signedCatalog = cached; status = "网络读取失败，显示尚未过期且验签通过的缓存目录。"
                } else { status = "目录读取失败：\(error.localizedDescription)" }
            }
        }
    }
    func installNetwork(_ entry: CatalogEntry) {
        guard let transport, let shownCatalog = signedCatalog, !busy, !stopping else { return }
        let alert = NSAlert(); alert.messageText = "下载并验证 \(entry.name)？"
        alert.informativeText = "本机开发测试包 · \(entry.size) 字节\n所需能力：\(entry.capabilities.isEmpty ? "无" : entry.capabilities.joined(separator:", "))\n将校验测试目录签名、下载哈希和 ZIP，运行一次 Hello 健康检查，然后保持禁用。测试公钥并不证明真实发布者身份；只继续安装你自己构建的包。"
        alert.addButton(withTitle:"安装并运行测试");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; let generation = launchGeneration
        operationTask = Task {
            defer { if generation == launchGeneration { busy = false }; refresh() }
            var newInstallation: InstalledExtension?
            do {
                let stage = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotchFramework-Development/NetworkStaging")
                let package = try await transport.preparePackage(id:entry.id,stagingParent:stage, expectedCatalogVersion:shownCatalog.catalogVersion, expectedEntry:entry)
                defer { try? FileManager.default.removeItem(at:package.directory) }
                guard generation == launchGeneration else { return }
                stopProcess(id:entry.id)
                let installed = try await withStore { try $0.installVerifiedPackage(package) }; newInstallation = installed
                guard generation == launchGeneration, !Task.isCancelled else { throw CancellationError() }
                let child = try await withStore { store in
                    try store.setEnabled(id:entry.id,enabled:true); return try store.makeProcess(id:entry.id)
                }
                guard generation == launchGeneration, !Task.isCancelled else {
                    retire(child); throw CancellationError()
                }
                processes[entry.id] = child
                _ = try await child.requestHello(timeout:3)
                stopProcess(id:entry.id)
                try await withStore { try $0.setEnabled(id:entry.id,enabled:false) }
                guard generation == launchGeneration else { throw CancellationError() }
                status = "下载、验签、解包、安装和进程健康检查成功；扩展保持禁用。"
            } catch {
                stopProcess(id:entry.id)
                var recovery = "安装状态未变更。"
                if let installed = newInstallation {
                    do {
                        if installed.previousVersion != nil { _ = try await withStore(cancellable:false) { try $0.rollback(id:entry.id) }; recovery = "已回滚上一版本并保持禁用。" }
                        else { _ = try await withStore(cancellable:false) { try $0.uninstall(id:entry.id) }; recovery = "已移除失败安装并保留恢复副本。" }
                    } catch { recovery = "自动恢复失败，请检查安装状态：\(error.localizedDescription)" }
                }
                status = "安装失败：\(error.localizedDescription) \(recovery)"
            }
        }
    }
    func explainRemoteBlock() { perform { try browser.authorizeRemoteInstall() } }
    private func retire(_ process: ExtensionProcess) {
        process.stop()
        retiredProcesses.removeAll { !$0.hasLiveProcess }
        if process.hasLiveProcess && !retiredProcesses.contains(where: { $0 === process }) { retiredProcesses.append(process) }
    }
    private func stopProcess(id:String) {
        if let process = processes.removeValue(forKey:id) { retire(process) }
    }
    func stopAll(immediate: Bool = false) {
        launchGeneration += 1; let generation = launchGeneration
        let previous = operationTask; previous?.cancel()
        processMonitor?.invalidate(); processMonitor = nil; presentedID = nil
        retiredProcesses = retiredProcesses.filter { $0.hasLiveProcess } + Array(processes.values)
        for process in retiredProcesses { process.stop(immediate:immediate) }; processes.removeAll(); overlay.hide()
        // Termination must kill synchronously; persisted enabled state is reset on next startup.
        if immediate { return }
        stopping = true; busy = true
        operationTask = Task {
            await previous?.value
            try? await withStore(cancellable:false) { store in
                for item in try store.list() where item.enabled { try store.setEnabled(id:item.manifest.id,enabled:false) }
            }
            if generation == launchGeneration { stopping = false; busy = false }
            refresh()
        }
    }
    private func startProcessMonitor() {
        guard processMonitor == nil else { return }
        processMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.busy, !self.stopping else { return }
                let exited = self.processes.filter { !$0.value.isRunning }
                for (id, process) in exited {
                    self.retire(process); self.processes.removeValue(forKey:id)
                    if self.presentedID == id { self.overlay.hide(); self.presentedID = nil }
                }
                if self.processes.isEmpty { self.processMonitor?.invalidate(); self.processMonitor = nil }
                if !exited.isEmpty {
                    let ids = Array(exited.keys)
                    self.performStore { store in
                        for id in ids { try store.setEnabled(id:id,enabled:false) }
                        return "扩展意外退出，已禁用：" + ids.joined(separator:", ")
                    }
                }
            }
        }
    }
    private func withStore<T: Sendable>(cancellable: Bool = true, _ body: @escaping @Sendable (ExtensionStore) throws -> T) async throws -> T {
        let store = try requireStore()
        let work = Task.detached(priority:.userInitiated) { try Task.checkCancellation(); return try body(store) }
        if !cancellable { return try await work.value }
        return try await withTaskCancellationHandler(operation:{ try await work.value }, onCancel:{ work.cancel() })
    }
    private func performStore(_ body: @escaping @Sendable (ExtensionStore) throws -> String) {
        guard !busy, !stopping else { return }; busy = true
        let generation = launchGeneration
        operationTask = Task {
            defer { if generation == launchGeneration { busy = false }; refresh() }
            do { status = try await withStore(body) } catch { status = error.localizedDescription }
        }
    }
    private func requireStore() throws -> ExtensionStore {
        guard let store else { throw CocoaError(.fileWriteNoPermission) }; return store
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); refresh() } catch { status = error.localizedDescription }
    }
}

struct ExtensionCenter: View {
    @ObservedObject var model: HostModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Notch 扩展中心").font(.largeTitle.bold())
                    Text("独立宿主 · 独立扩展 · 开发预览 0.1.0").foregroundStyle(.secondary)
                }
                Spacer()
                Button("连接本机测试源") { model.connectTestNetwork() }
                Button("导入目录 JSON") { model.importCatalog() }
                Button("安装 / 升级本地扩展") { model.importFixture() }.buttonStyle(.borderedProminent)
            }
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.installed.isEmpty { Text("尚未安装扩展。先构建 Hello 示例，再选择其 dist 目录。").padding() }
                        ForEach(model.installed, id: \.manifest.id) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.manifest.name).font(.headline)
                                    Text("\(item.manifest.id) · \(item.manifest.version)").font(.caption).foregroundStyle(.secondary)
                                    Text(item.enabled ? "已启用" : "已禁用").foregroundColor(item.enabled ? .green : .secondary)
                                }
                                Spacer()
                                if item.enabled { Button("停用") { model.disable(item) } }
                                else { Button("启用") { model.enable(item) } }
                                if item.previousVersion != nil { Button("回滚") { model.rollback(item) } }
                                Button("卸载", role: .destructive) { model.uninstall(item) }
                            }.padding().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding()
                }.tabItem { Text("已安装") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("正式安装待配置可信签名根。可先浏览 GitHub 公开目录；本机测试源可完整验证安装链路。").foregroundStyle(.orange)
                        HStack {
                            TextField("已发布的 GitHub Pages / raw 目录 HTTPS 地址", text:$model.publicCatalogAddress)
                            Button("刷新 GitHub 目录") { model.refreshPublicCatalog() }
                        }
                        Text("公开目录预览不代表签名已验证。未配置默认地址，避免指向不存在的仓库。").font(.caption).foregroundStyle(.secondary)
                        if model.hasNetworkSource { Button("刷新签名目录") { model.refreshNetwork() } }
                        if let signed = model.signedCatalog {
                            Text("测试签名目录 v\(signed.catalogVersion)")
                            ForEach(signed.entries, id: \.id) { entry in
                                HStack {
                                    VStack(alignment:.leading) { Text(entry.name).bold(); Text(entry.version).font(.caption) }
                                    Spacer()
                                    Button("下载并安装测试包") { model.installNetwork(entry) }
                                }.padding()
                            }
                        }
                        if let catalog = model.catalog {
                            Text("未验证预览 · 缓存目录版本 \(catalog.catalogVersion) · \(catalog.entries.count) 项")
                            ForEach(catalog.entries) { item in
                                HStack {
                                    VStack(alignment: .leading) { Text(item.name ?? item.id).bold(); Text(item.version).font(.caption) }
                                    Spacer()
                                    Button("查看安装条件") { model.explainRemoteBlock() }
                                }.padding()
                            }
                        } else { Text("尚无目录缓存。可导入 registry/site/catalog-v1.json。") }
                    }.padding()
                }.tabItem { Text("发现") }
            }
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).font(.callout).textSelection(.enabled).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.padding(24).disabled(model.busy || model.stopping)
    }
}

private struct TestNetworkSource: Decodable { let catalogURL: URL; let keyID: String; let publicKey: String }
