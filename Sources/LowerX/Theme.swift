import AppKit
import SwiftUI

/// Visual da janela principal, no estilo do NGENUITY: fundo quase preto, vermelho
/// HyperX e a fonte Saira (OFL, embutida no app em Contents/Resources/Fonts).
enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let sidebar = Color(red: 0.075, green: 0.078, blue: 0.088)
    static let card = Color(red: 0.105, green: 0.108, blue: 0.12)
    static let cardRaised = Color(red: 0.14, green: 0.143, blue: 0.158)
    static let stroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.89, green: 0.10, blue: 0.20)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.32)

    enum Weight: String {
        case book = "Regular", medium = "Medium", bold = "Bold", black = "Black"
    }

    /// Fonte da marca; se não estiver registrada, o SwiftUI usa a do sistema.
    static func font(_ size: CGFloat, _ weight: Weight = .book) -> Font {
        .custom("Saira-\(weight.rawValue)", size: size)
    }
}

/// Imagens dos produtos (do pacote do NGENUITY), em Contents/Resources/Devices,
/// com o nome do `model` do `DeviceCatalog`.
enum DeviceImages {
    private static var cache: [String: NSImage] = [:]

    static func image(model: String) -> NSImage? {
        if let cached = cache[model] { return cached }
        guard let url = Bundle.main.url(forResource: model, withExtension: "png", subdirectory: "Devices"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[model] = image
        return image
    }
}

/// Imagem do produto ou, sem ela, o símbolo da categoria.
struct ProductImage: View {
    let model: String
    var category: DeviceCatalog.Category = .headset

    var body: some View {
        if let image = DeviceImages.image(model: model) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: Self.symbol(for: category))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Theme.tertiaryText)
                .padding(18)
        }
    }

    static func symbol(for category: DeviceCatalog.Category) -> String {
        switch category {
        case .headset: return "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .mousePad: return "rectangle.portrait"
        case .microphone: return "mic"
        case .webcam: return "web.camera"
        case .other: return "cube"
        }
    }
}

/// Bloco de conteúdo com título em caixa alta, como os painéis do NGENUITY.
struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title.uppercased())
                    .font(Theme.font(12, .bold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                trailing
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }
}

/// Seletor em "pílulas", com o item escolhido em vermelho.
struct PillPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(Theme.font(12, .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection == value ? Color.white : Theme.secondaryText)
                        .background(selection == value ? Theme.accent : Theme.cardRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Linha com título, descrição e um controle à direita.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(14, .medium))
                if let detail {
                    Text(detail).font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

/// Distribui os itens em linhas, quebrando quando não cabem.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
