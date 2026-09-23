import AppKit
import SwiftUI

/// Medidas do alternador conforme estilo e tamanho escolhidos.
struct SwitcherLayout {
    let style: SwitcherStyle
    let scale: CGFloat

    init(_ settings: SwitcherSettings) {
        style = settings.style
        scale = settings.size.scale
    }

    var thumbnailSize: CGSize { CGSize(width: 220 * scale, height: 140 * scale) }
    var iconSize: CGFloat { 72 * scale }
    var rowWidth: CGFloat { 420 * scale }
    let spacing: CGFloat = 8
    let padding: CGFloat = 14

    var cellWidth: CGFloat {
        switch style {
        case .thumbnails: thumbnailSize.width + 16
        case .icons: iconSize + 24
        case .titles: rowWidth
        }
    }
}

struct SwitcherView: View {
    @ObservedObject var controller: SwitcherController
    let layout: SwitcherLayout

    var body: some View {
        let columns = layout.style == .titles ? 1 : max(1, Int((controller.maxWidth - layout.padding * 2) / (layout.cellWidth + layout.spacing)))
        let indices = Array(controller.items.indices)
        let rows = stride(from: 0, to: indices.count, by: columns).map { Array(indices[$0..<min($0 + columns, indices.count)]) }

        VStack(alignment: layout.style == .titles ? .leading : .center, spacing: layout.spacing) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: layout.spacing) {
                    ForEach(row, id: \.self) { index in
                        cell(index)
                            .contentShape(Rectangle())
                            .onHover { if $0 { controller.select(index) } }
                            .onTapGesture {
                                controller.select(index)
                                controller.commit()
                            }
                    }
                }
            }
        }
        .padding(layout.padding)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12)))
        .fixedSize()
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        let item = controller.items[index]
        let isSelected = index == controller.selected

        Group {
            switch layout.style {
            case .thumbnails: thumbnailCell(item)
            case .icons: iconCell(item)
            case .titles: titleCell(item)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }

    private func thumbnailCell(_ item: SwitcherItem) -> some View {
        let size = layout.thumbnailSize
        return VStack(spacing: 6) {
            ZStack {
                if let image = controller.thumbnails[item.windowID], item.windowID != 0 {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 2)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06))
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: size.height * 0.45, height: size.height * 0.45)
                }
                if item.isMinimized {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: size.width, height: size.height)

            HStack(spacing: 5) {
                Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .frame(width: size.width)
        }
    }

    private func iconCell(_ item: SwitcherItem) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: layout.iconSize, height: layout.iconSize)
                .opacity(item.isMinimized ? 0.6 : 1)
            Text(item.appName)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: layout.iconSize + 8)
        }
    }

    private func titleCell(_ item: SwitcherItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon).resizable().frame(width: 22 * layout.scale, height: 22 * layout.scale)
            Text(item.fullTitle)
                .font(.system(size: 13 * layout.scale))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isMinimized {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: layout.rowWidth - 16)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
