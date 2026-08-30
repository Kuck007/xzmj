//
//  PhotoComponents.swift
//  杏子美甲管理系统
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
struct EditablePhotoGrid: View {
    @Binding var photos: [PhotoRecord]

    private let thumbSize: CGFloat = 100
    private let spacing: CGFloat = 8

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
                // 添加按钮（正方形中间加号，整块虚线区域可点击）
                Button {
                    pickImageFromFiles { data in
                        photos.append(PhotoRecord(angle: "正面", imageData: data))
                    }
                } label: {
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
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .padding(.vertical, 4)
        }
    }
}
