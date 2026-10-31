import SwiftUI

extension ClipboardContent.Kind {
    var title: String {
        switch self { case .text: L10n.clipboardText; case .image: L10n.clipboardImages; case .files: L10n.clipboardFiles }
    }
    var symbol: String {
        switch self { case .text: "text.alignleft"; case .image: "photo"; case .files: "doc.on.doc" }
    }
}

struct ClipboardTypePicker: View {
    @Binding var kind: ClipboardContent.Kind?
    var body: some View {
        Picker(L10n.clipboardType, selection: $kind) {
            Text(L10n.clipboardAllTypes).tag(ClipboardContent.Kind?.none)
            ForEach(ClipboardContent.Kind.allCases, id: \.self) { type in
                Text(type.title).tag(Optional(type))
            }
        }.labelsHidden().pickerStyle(.menu).fixedSize().help(L10n.clipboardType)
    }
}

struct ClipboardThumbnail: View {
    let entry: ClipboardEntry
    var size: CGFloat = 24
    @State private var preview: CGImage?
    var body: some View {
        Group {
            if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: entry.kind.symbol).foregroundStyle(.secondary) }
        }.frame(width: size, height: size)
            .task(id: entry.id) {
                if case .image(let image) = entry.content {
                    let result = await ClipboardPreviewCache.shared.preview(id: entry.id, image: image)
                    if !Task.isCancelled { preview = result }
                }
            }
            .onDisappear { preview = nil }
    }
}

struct ClipboardContentDetail: View {
    @Environment(ClipboardModel.self) private var model
    let entry: ClipboardEntry
    @State private var preview: CGImage?
    @State private var failed = false
    @State private var availability: [URL: Bool] = [:]
    var body: some View {
        ScrollView {
            switch entry.content {
            case .text(let text):
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            case .image(let image):
                VStack(alignment: .leading, spacing: 12) {
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: 512, maxHeight: 512)
                    } else if failed { Text(L10n.clipboardPreviewFailed).foregroundStyle(.secondary) }
                    else { ProgressView().frame(maxWidth: .infinity) }
                    Text("\(image.width) × \(image.height) · \(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }.task(id: entry.id) {
                    let result = await ClipboardPreviewCache.shared.preview(id: entry.id, image: image)
                    if !Task.isCancelled { preview = result; failed = result == nil }
                }
            case .files(let urls):
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(url.lastPathComponent, systemImage: "doc").lineLimit(2)
                            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if availability[url] == false {
                                Label(L10n.clipboardMissingFile, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(L10n.clipboardFilesHelp).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .task(id: entry.id) {
                        while !Task.isCancelled {
                            let states = await model.fileStates(urls)
                            if Task.isCancelled { return }
                            availability = states
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        }
                    }
            }
        }.id(entry.id).onDisappear { preview = nil }
    }
}

struct ClipboardPasteButton: View {
    @Environment(ClipboardModel.self) private var model
    @Environment(CommandStore.self) private var store
    let entry: ClipboardEntry
    var body: some View {
        if store.config.settings.clipboard.pasteEnabled {
            Button { Task { await model.paste(entry) } } label: {
                Image(systemName: "arrow.up.doc.on.clipboard").frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.borderless).controlHoverFeedback().disabled(model.isPasting)
                .help(L10n.clipboardPaste).accessibilityLabel(L10n.clipboardPaste)
        }
    }
}
