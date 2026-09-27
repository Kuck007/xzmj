//
//  PhotoComponents.swift
//  杏子美甲管理系统
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import PDFKit

// MARK: - 图片选择（NSOpenPanel 直接调用）
func pickImageFromFiles(onPick: @escaping (Data) -> Void) {
    let panel = NSOpenPanel()
    // 放宽到 .image（所有 macOS 原生可读的图片类型：
    // PNG JPEG BMP GIF TIFF HEIC WebP 以及部分 RAW CR2/NEF/ARW/DNG 等）
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.canCreateDirectories = false
    panel.title = "选择照片"
    panel.message = "支持 PNG/JPEG/BMP/HEIC/WebP/TIFF/GIF 以及部分 RAW 格式，会自动压缩转 JPEG 保存"
    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
        // 读文件时就先压缩一次（保证所有通过 picker 进来的图都是压过的 JPEG）
        let compressed = ImageCompressor.compressToJPEG(data) ?? data
        onPick(compressed)
    }
}

// MARK: - 缩略图组件
struct PhotoThumbnail: View {
    let imageData: Data?
    var size: CGFloat = 100

    var body: some View {
        if let data = imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - 独立图片查看窗口控制器（可调节大小 + 支持原生全屏）
final class PhotoWindowController: NSWindowController {
    static var shared: PhotoWindowController?

    convenience init(photos: [PhotoRecord], initialIndex: Int, onIndexChange: @escaping (Int) -> Void) {
        let content = PhotoViewerWindowContent(
            photos: photos,
            initialIndex: initialIndex,
            onIndexChange: onIndexChange
        )

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = NSRect(
            x: screen.midX - 450,
            y: screen.midY - 350,
            width: 900,
            height: 700
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "照片查看"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.minSize = NSSize(width: 600, height: 450)
        window.center()

        self.init(window: window)
    }

    static func show(photos: [PhotoRecord], initialIndex: Int, onIndexChange: @escaping (Int) -> Void) {
        if let existing = shared {
            existing.close()
            shared = nil
        }

        let controller = PhotoWindowController(photos: photos, initialIndex: initialIndex, onIndexChange: onIndexChange)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func closeCurrent() {
        shared?.close()
        shared = nil
    }
}

// MARK: - 图片查看器窗口内容（承载在独立 NSWindow 中）
struct PhotoViewerWindowContent: View {
    let photos: [PhotoRecord]
    @State var currentIndex: Int
    let onIndexChange: (Int) -> Void

    init(photos: [PhotoRecord], initialIndex: Int, onIndexChange: @escaping (Int) -> Void) {
        self.photos = photos
        _currentIndex = State(initialValue: initialIndex)
        self.onIndexChange = onIndexChange
    }

    // 缩放与拖动状态
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isFullscreen: Bool = false

    // 缩放范围
    private let minScale: CGFloat = 0.5
    private let maxScale: CGFloat = 5.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部栏
                    HStack {
                        if photos.count > 1 {
                            Text("\(currentIndex + 1) / \(photos.count)")
                                .font(.headline).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Button {
                            PhotoWindowController.closeCurrent()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    .padding()

                    // 图片区（可缩放、可拖动）
                    if currentIndex >= 0 && currentIndex < photos.count,
                       let data = photos[currentIndex].imageData,
                       let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in
                                        scale = lastScale * val
                                        scale = max(minScale, min(maxScale, scale))
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                    }
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { val in
                                        offset = CGSize(
                                            width: lastOffset.width + val.translation.width,
                                            height: lastOffset.height + val.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    if scale > 1.0 {
                                        reset()
                                    } else {
                                        scale = 2.0
                                        lastScale = 2.0
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    // 底部备注
                    if currentIndex < photos.count, let note = photos[currentIndex].note, !note.isEmpty {
                        Text(note)
                            .font(.body).foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, 8)
                    }

                    // 底部工具栏：放大 缩小 全屏 初始大小
                    HStack(spacing: 20) {
                        Button {
                            adjustScale(by: 0.3)
                        } label: {
                            toolButton(systemName: "plus.magnifyingglass", label: "放大")
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Button {
                            adjustScale(by: -0.3)
                        } label: {
                            toolButton(systemName: "minus.magnifyingglass", label: "缩小")
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Button {
                            toggleNativeFullscreen()
                        } label: {
                            toolButton(
                                systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: isFullscreen ? "退出全屏" : "全屏"
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { reset() }
                        } label: {
                            toolButton(systemName: "1.magnifyingglass", label: "初始大小")
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial.opacity(0.6))
                    .cornerRadius(12)
                    .padding(.bottom, 16)
                }

                // 左右切换箭头
                if currentIndex > 0 {
                    Button {
                        switchTo(currentIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    .position(x: 50, y: geo.size.height / 2)
                }

                if currentIndex < photos.count - 1 {
                    Button {
                        switchTo(currentIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    .position(x: geo.size.width - 50, y: geo.size.height / 2)
                }
            }
        }
        .onAppear {
            // 监听窗口全屏状态
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.contentViewController is NSHostingController<AnyView> }) {
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didEnterFullScreenNotification,
                        object: window, queue: .main
                    ) { _ in isFullscreen = true }
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didExitFullScreenNotification,
                        object: window, queue: .main
                    ) { _ in isFullscreen = false }
                }
            }
        }
    }

    private func toolButton(systemName: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 18))
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: 64, height: 48)
        .contentShape(Rectangle())
    }

    private func adjustScale(by delta: CGFloat) {
        let new = max(minScale, min(maxScale, lastScale + delta))
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = new
            lastScale = new
        }
    }

    private func toggleNativeFullscreen() {
        guard let window = NSApp.keyWindow else { return }
        window.toggleFullScreen(nil)
    }

    private func reset() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    private func switchTo(_ idx: Int) {
        currentIndex = idx
        onIndexChange(idx)
        withAnimation(.easeInOut(duration: 0.2)) { reset() }
    }
}

// MARK: - 兼容旧接口（sheet 调用已弃用，统一走 PhotoWindowController）
struct PhotoViewer: View {
    let photos: [PhotoRecord]
    @Binding var currentIndex: Int

    var body: some View {
        EmptyView()
    }
}

// MARK: - 可编辑照片网格（编辑模式用）
/// 支持四种添加方式：从文件选择、粘贴、拖拽（Finder/浏览器/聊天窗口）、摄像头拍照（USB 摄像头或 iPhone 当 Mac 摄像头）
struct EditablePhotoGrid: View {
    @Binding var photos: [PhotoRecord]

    private let thumbSize: CGFloat = 100
    private let spacing: CGFloat = 8

    @State private var showCamera = false
    @State private var dragOver = false
    /// 连续互通相机宿主视图（validRequestor/readSelection 挂在这里，菜单 popUp 时沿响应链命中）
    @State private var continuityHost: ContinuityCameraHostView?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: spacing) {
                // 已有照片
                ForEach($photos) { $p in
                    ZStack(alignment: .topTrailing) {
                        PhotoThumbnail(imageData: p.imageData, size: thumbSize)
                        Button {
                            photos.removeAll { $0.id == p.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.red)
                                .background(Circle().fill(.white))
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .padding(4)
                    }
                }
                // 添加按钮：点击弹来源菜单 / 右键同菜单 / 拖拽图片进来 / 拖拽时高亮
                Button {
                    showSourceMenu()
                } label: {
                    dashedAddBox
                }
                .buttonStyle(.plain)
                .contextMenu { sourceMenuItems }
                .onDrop(of: [.fileURL, .image], isTargeted: $dragOver) { providers in
                    handleDrop(providers)
                }
                .overlay {
                    if dragOver {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { data in
                addPhoto(data)
                showCamera = false
            }
            .frame(width: 620, height: 500)
        }
        // 连续互通相机宿主：手动挂到窗口 contentView（保证响应链可靠），菜单弹出时沿链命中 validRequestor
        .onAppear { ensureContinuityHostAttached() }
        .onDisappear {
            continuityHost?.removeFromSuperview()
            continuityHost = nil
        }
    }

    /// 确保连续互通宿主视图挂在窗口 contentView 下，响应链: host → contentView → window → ... → NSApp
    private func ensureContinuityHostAttached() {
        guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
        if continuityHost == nil {
            let host = ContinuityCameraHostView()
            host.onImageData = { data in
                DispatchQueue.main.async { self.addPhoto(data) }
            }
            // EditablePhotoGrid 是值类型不能 weak 捕获；视图销毁时 onDisappear 清空闭包并置 nil 打破引用环
            continuityHost = host
        }
        if let host = continuityHost, host.superview !== contentView {
            contentView.addSubview(host)
            host.frame = contentView.bounds
            host.autoresizingMask = [.width, .height]
        }
    }

    // 来源菜单
    @ViewBuilder
    private var sourceMenuItems: some View {
        Button("从文件选择…") {
            pickImageFromFiles { addPhoto($0) }
        }
        Button("粘贴") {
            pasteImage()
        }
        .disabled(!clipboardHasImage())
        Divider()
        Button {
            showCamera = true
        } label: {
            Label("用摄像头拍照", systemImage: "camera")
        }
    }

    // 虚线加号框
    private var dashedAddBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
        }
        .frame(width: thumbSize, height: thumbSize)
        .contentShape(Rectangle())
    }

    // 拖拽：支持图片数据（浏览器/微信/QQ 直接拖图）和图片文件（Finder 拖文件）
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data = data else { return }
                    DispatchQueue.main.async { addPhoto(data) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = item as? URL, let data = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async { addPhoto(data) }
                }
                handled = true
            }
        }
        return handled
    }

    // 点击虚线框：在鼠标当前位置弹出系统原生来源菜单（视觉不受菜单样式影响）
    private func showSourceMenu() {
        // 关键：编辑页在 sheet 中，onAppear 时 keyWindow 可能还是主窗口，
        // 宿主可能挂错窗口导致验证链查不到（菜单项灰色）。每次弹菜单前重新挂到当前 keyWindow。
        ensureContinuityHostAttached()
        let menu = NSMenu()
        let target = PhotoGridMenuTarget()
        target.onPickFile = {
            pickImageFromFiles { self.addPhoto($0) }
        }
        target.onPaste = {
            self.pasteImage()
        }
        target.onCamera = {
            self.showCamera = true
        }
        menu.addItem(withTitle: "从文件选择…", action: #selector(PhotoGridMenuTarget.pickFile), keyEquivalent: "").target = target
        let pasteItem = menu.addItem(withTitle: "粘贴", action: #selector(PhotoGridMenuTarget.paste), keyEquivalent: "")
        pasteItem.target = target
        pasteItem.isEnabled = clipboardHasImage()
        menu.addItem(.separator())
        menu.addItem(withTitle: "用摄像头拍照", action: #selector(PhotoGridMenuTarget.camera), keyEquivalent: "").target = target
        // 连续互通相机：不手动加项，让 popUpContextMenu 自动插入“设备→拍照/扫描/速绘”菜单（系统原生，可用）
        if let window = NSApp.keyWindow, let host = continuityHost {
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
            // 合成一个鼠标事件（来源菜单由按钮点击触发，无系统事件可用）
            let event = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
            if let event {
                // 把 firstResponder 临时设为宿主视图：让 AppKit 在 current responder chain
                // 上命中 validRequestor，从而启用设备菜单项（拍照/扫描/速绘）
                let originalFirstResponder = window.firstResponder
                if host !== originalFirstResponder {
                    window.makeFirstResponder(host)
                }
                // 不恢复原 firstResponder：让宿主保持在焦点链上（连拍重弹菜单时设备项才可点击）
                NSMenu.popUpContextMenu(menu, with: event, for: host)
            } else {
                menu.popUp(positioning: nil, at: host.convert(windowPoint, from: nil), in: host)
            }
        }
    }

    // 剪贴板是否有可用图片
    private func clipboardHasImage() -> Bool {
        let types = NSPasteboard.general.types ?? []
        return types.contains(.tiff) || types.contains(.png) || types.contains(.fileURL)
    }

    // 粘贴：先取图片数据（复制图片后通常是 TIFF/PNG），再取文件 URL
    private func pasteImage() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            addPhoto(data)
            return
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first,
           let data = try? Data(contentsOf: url) {
            addPhoto(data)
        }
    }

    // 统一入库：压缩转 JPEG 后追加
    private func addPhoto(_ data: Data) {
        let compressed = ImageCompressor.compressToJPEG(data) ?? data
        photos.append(PhotoRecord(angle: "正面", imageData: compressed))
    }
}

// MARK: - 摄像头拍照（AVFoundation；USB 摄像头 / iPhone 当 Mac 摄像头均会被枚举为视频设备）
struct CameraCaptureView: View {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var session: CameraSession?
    @State private var capturedImage: NSImage?
    @State private var statusText = "正在启动摄像头…"
    @State private var hasCamera = false

    var body: some View {
        VStack(spacing: 16) {
            Text("摄像头拍照").font(.headline)

            // 预览区域：未拍照时实时预览，拍照后显示拍到的照片
            Group {
                if let capturedImage {
                    Image(nsImage: capturedImage)
                        .resizable()
                        .scaledToFit()
                } else if let session {
                    CameraPreviewView(session: session.session)
                } else {
                    Text(statusText).foregroundStyle(.secondary)
                }
            }
            .frame(width: 560, height: 360)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 16) {
                Button("取消") { dismiss() }
                if capturedImage != nil {
                    Button("重拍") { capturedImage = nil }
                }
                Button {
                    if let capturedImage {
                        // 使用照片：转 JPEG 后回调
                        if let tiff = capturedImage.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                            onCapture(jpg)
                        } else if let tiff = capturedImage.tiffRepresentation {
                            onCapture(tiff)
                        }
                        dismiss()
                    } else {
                        session?.capture { image in
                            capturedImage = image
                        }
                    }
                } label: {
                    Text(capturedImage == nil ? "拍照" : "使用照片")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasCamera && capturedImage == nil)
            }
        }
        .padding(24)
        .onAppear {
            let cam = CameraSession()
            cam.start { success, message in
                hasCamera = success
                statusText = message
                if success { session = cam }
            }
        }
        .onDisappear { session?.stop() }
    }
}

/// 摄像头会话：枚举视频设备（USB 摄像头即插即用）、配置输入输出、拍照回调
final class CameraSession: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var captureHandler: ((NSImage) -> Void)?

    func start(completion: @escaping (Bool, String) -> Void) {
        // 关键：必须先确认摄像头权限。
        // 未授权时 AVCaptureDeviceInput(device:) 会抛 Objective-C 异常（不是 Swift error），导致 app 直接崩溃。
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configure(completion: completion)
                    } else {
                        completion(false, "未授权使用摄像头，请在「系统设置 → 隐私与安全性 → 摄像头」中允许")
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                completion(false, "摄像头权限被拒绝，请在「系统设置 → 隐私与安全性 → 摄像头」中允许")
            }
        @unknown default:
            DispatchQueue.main.async {
                completion(false, "无法确定摄像头权限状态")
            }
        }
    }

    /// 权限已确认后：在后台线程配置并启动会话
    private func configure(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            guard let device = AVCaptureDevice.default(for: .video) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion(false, "未检测到摄像头（请插入 USB 摄像头）") }
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { completion(false, "无法使用摄像头") }
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)
                // 必须先提交配置事务，再 startRunning（Apple 限制：配置事务进行中禁止 startRunning，会抛异常）
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async { completion(true, "就绪") }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion(false, "摄像头启动失败：\(error.localizedDescription)") }
            }
        }
    }

    func capture(_ handler: @escaping (NSImage) -> Void) {
        captureHandler = handler
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = NSImage(data: data) else { return }
        captureHandler?(image)
    }
}

/// 摄像头实时预览层
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

/// 来源菜单的 action 转发（NSMenuItem 需要 @objc selector + target 对象）
private final class PhotoGridMenuTarget: NSObject {
    var onPickFile: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCamera: (() -> Void)?
    @objc func pickFile() { onPickFile?() }
    @objc func paste() { onPaste?() }
    @objc func camera() { onCamera?() }
}

// MARK: - 连续互通相机（Apple 官方 AppKit 机制，无私有 API）
/// 原理（Apple 文档《Supporting Continuity Camera in Your Mac App》）：
/// 1. responder 实现 validRequestor(forSendType:returnType:) 声明"本 app 可接收图片"；
/// 2. 菜单项带 NSMenuItem.importFromDeviceIdentifier，用户点击后系统自动在 iPhone/iPad 上启动连续互通相机；
/// 3. 拍完/扫描完，AppKit 把图片放到 pasteboard，并回调本 view 的 readSelection(from:) 读取图片。
/// 这解决了"程序化触发连续互通相机"的问题：不需要 NSPerformService 的私有服务名，
/// 用系统官方菜单项机制即可，且自动出现在右键/来源菜单里。
final class ContinuityCameraHostView: NSView, NSServicesMenuRequestor {
    /// 收到图片数据（已转 JPEG）回调
    var onImageData: ((Data) -> Void)?

    /// 纯响应链载体：不参与绘制、不拦截任何鼠标/键盘事件
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }
    /// 允许成为 firstResponder：AppKit 检查连续互通相机的启用状态时走 current responder chain，
    /// 只有宿主在焦点链上，设备菜单（拍照/扫描/速绘）才会被启用（否则灰色）
    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        // Sidecar 连续互通相机的查询 sendType 为空（"接收"类服务）；必须无条件返回 self，
        // 否则 send=nil/ret=nil 之类的查询会走 super 返回 SwiftUI 内部对象，
        // 该对象不响应 readSelectionFromPasteboard:，导致 "does not respond to selector" 且照片进不来。
        if sendType == nil {
            return self
        }
        if let pasteboardType = returnType,
           NSImage.imageTypes.contains(pasteboardType.rawValue)
            || pasteboardType.rawValue == "com.adobe.pdf"
            || pasteboardType.rawValue == "com.apple.DocumentCamera.scan-archive" {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // NSServicesMenuRequestor 协议方法：AppKit 通过 ObjC selector `readSelectionFromPasteboard:`
    // 调用收图。实测：手工 `@objc func readSelection(from:)` 生成的 selector 不是这个
    // （responds(to:) 为 false，Sidecar 报 "does not respond to selector" 且照片进不来），
    // 必须 conform 协议（或显式 @objc(readSelectionFromPasteboard:)）才能得到正确 selector。
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        // 扫描文稿多页：iPhone 上连续扫描多页后一次“保存”，返回的是 PDF
        // （com.apple.DocumentCamera.scan-archive 或 com.adobe.pdf）——每页渲染成一张 JPEG 逐张入库
        let pdfTypes = ["com.adobe.pdf", "com.apple.DocumentCamera.scan-archive"]
        if pasteboard.canReadItem(withDataConformingToTypes: pdfTypes),
           let pdfData = pasteboard.data(forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
            ?? pasteboard.data(forType: NSPasteboard.PasteboardType("com.apple.DocumentCamera.scan-archive")),
           let pdf = PDFDocument(data: pdfData) {
            var okCount = 0
            for i in 0..<pdf.pageCount {
                if let page = pdf.page(at: i), let jpg = Self.renderPDFPageToJPEG(page) {
                    onImageData?(jpg)
                    okCount += 1
                }
            }
            return okCount > 0
        }
        // 单张图片（拍照/速绘等单张来源）。pasteboard 可能同时带多个表示（高清原图 + 缩略图），
        // NSImage(pasteboard:) 会选中较小的表示导致糊——枚举所有图片类型，选像素最大的那个
        var bestData: Data?
        var bestPixels = 0
        for type in (pasteboard.types ?? []) {
            guard NSImage.imageTypes.contains(type.rawValue) else { continue }
            guard let data = pasteboard.data(forType: type),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
            let pixels = w * h
            if pixels > bestPixels {
                bestPixels = pixels
                bestData = data
            }
        }
        guard let bestData,
              let image = NSImage(data: bestData),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return false
        }
        onImageData?(jpg)
        return true
    }

    /// 协议另一半（导出服务用，本 app 用不到），必须实现才能 conform
    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        return false
    }

    /// 扫描文稿 PDF 单页 → JPEG：白底 2x 渲染（保证清晰度）→ 自动裁白边，返回 JPEG Data
    private static func renderPDFPageToJPEG(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        // 4x 渲染：扫描文稿源位图是 300DPI（约 2480x3508），2x（1224x1584）会砍掉一半以上分辨率导致模糊
        let scale: CGFloat = 4.0
        let w = Int(ceil(bounds.width * scale))
        let h = Int(ceil(bounds.height * scale))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let cgImage = ctx.makeImage() else { return nil }
        // 扫描文稿页面是 A4 文档尺寸，内容居中、四周大片白边——自动裁掉，只留 4px 边距
        let trimmed = Self.trimWhiteBorders(cgImage, margin: 4)
        let rep = NSBitmapImageRep(cgImage: trimmed)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// 逐像素找非白内容边界并裁剪（留 margin 边距）。扫描文稿整页渲染后四周是 A4 白边。
    /// 注意：content 区域按 row0=顶部 的行序扫描，与 CGImage.cropping 的坐标系一致。
    private static func trimWhiteBorders(_ image: CGImage, margin: Int) -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return image }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return image }
        var minX = w, minY = h, maxX = -1, maxY = -1
        // 按行扫描，只在整行全白时跳过，找内容包围盒
        for y in 0..<h {
            let rowOffset = y * bpr
            for x in 0..<w {
                let off = rowOffset + x * bpp
                let r = ptr[off], g = ptr[off + 1], b = ptr[off + 2]
                if r < 245 || g < 245 || b < 245 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }  // 全白页不裁
        let m = margin
        var cropX = max(0, minX - m)
        var cropY = max(0, minY - m)
        var cropW = min(w - cropX, maxX - minX + 1 + m * 2)
        var cropH = min(h - cropY, maxY - minY + 1 + m * 2)
        if cropX + cropW > w { cropW = w - cropX }
        if cropY + cropH > h { cropH = h - cropY }
        guard cropW > 0, cropH > 0,
              let cropped = image.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else { return image }
        return cropped
    }
}
