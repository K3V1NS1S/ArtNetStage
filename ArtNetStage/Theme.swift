import SwiftUI
import AppKit

// MARK: - Tema ArtNet Stage 2.0
//
// Design system "vetro satinato" ispirato a CleanMyMac: scena 3D a tutta finestra, pannello laterale in
// vetro traslucido, card ad angoli continui e un'identità cromatica per ognuna delle 5 sezioni.
// Questo file contiene solo presentazione: nessuna logica di rendering, di rete o di dati.

// MARK: Colori e identità delle sezioni

/// Identità cromatica di una sezione: gradiente (start → end) e colore d'accento.
struct SectionTheme: Equatable {
    let start: Color
    let end: Color
    let accent: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Gradiente delicato che tinge il vetro del pannello.
    var tint: LinearGradient {
        LinearGradient(colors: [start.opacity(0.20), end.opacity(0.07)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func hex(_ a: UInt32, _ b: UInt32, accent: UInt32? = nil) -> SectionTheme {
        SectionTheme(start: Color(rgb: a), end: Color(rgb: b), accent: Color(rgb: accent ?? a))
    }

    static let network = SectionTheme.hex(0x00C6FF, 0x0072FF)                  // ciano → blu elettrico
    static let links = SectionTheme.hex(0x00E676, 0x00BFA5)                    // verde smeraldo → acquamarina
    static let lights = SectionTheme.hex(0xFF4081, 0x7C4DFF, accent: 0xFF5C93)  // magenta → viola
    static let stage = SectionTheme.hex(0xFFAB40, 0xFF6D00)                    // ambra → arancio caldo
    static let dmx = SectionTheme.hex(0x536DFE, 0x3D5AFE, accent: 0x7C8FFF)    // indaco → blu notte luminoso
}

extension Color {
    /// Colore sRGB da un valore esadecimale 0xRRGGBB.
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }
}

extension PanelSection {
    var theme: SectionTheme {
        switch self {
        case .network: return .network
        case .patch: return .links
        case .fixtures: return .lights
        case .stage: return .stage
        case .monitor: return .dmx
        }
    }

    var icon: String {
        switch self {
        case .network: return "antenna.radiowaves.left.and.right"
        case .patch: return "cable.connector"
        case .fixtures: return "lightbulb.led.fill"
        case .stage: return "theatermasks.fill"
        case .monitor: return "waveform.path.ecg"
        }
    }
}

// MARK: Ambiente SwiftUI

private struct SectionThemeKey: EnvironmentKey {
    static let defaultValue = SectionTheme.network
}

extension EnvironmentValues {
    /// Tema della sezione attiva: lo leggono card, pulsanti e selezioni.
    var sectionTheme: SectionTheme {
        get { self[SectionThemeKey.self] }
        set { self[SectionThemeKey.self] = newValue }
    }
}

// MARK: - NSVisualEffectView

/// Vetro nativo di macOS. `.withinWindow` sfoca ciò che sta dietro nella stessa finestra (la scena 3D).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

/// Area che permette di trascinare la finestra (la barra del titolo è nascosta).
struct WindowDragArea: NSViewRepresentable {
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Superfici in vetro

enum GlassMetrics {
    static let radius: CGFloat = 14
    static let panelRadius: CGFloat = 18
    static let border = Color.white.opacity(0.12)
}

/// Vetro scuro satinato per gli elementi sovrapposti alla scena (HUD, pillole, badge, suggerimenti).
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = GlassMetrics.radius
    var tint: SectionTheme? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, blending: .withinWindow)
                    Color.black.opacity(0.22)
                    LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                    if let tint { tint.tint }
                }
                .clipShape(shape)
            )
            .overlay(shape.strokeBorder(GlassMetrics.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}

extension View {
    /// Applica il trattamento «vetro» ad angoli continui.
    func glassSurface(cornerRadius: CGFloat = GlassMetrics.radius, tint: SectionTheme? = nil) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Sfondo unico della finestra

/// Unico sfondo continuo dell'intera finestra: sfumatura atmosferica scura tinta dal colore della sezione attiva.
/// Sta dietro sia ai controlli sia alla scena 3D (che ha sfondo trasparente). Con `blackout` diventa nero puro (#000000).
struct WindowBackdrop: View {
    let section: PanelSection
    let blackout: Bool

    var body: some View {
        ZStack {
            Color.black
            // Base atmosferica scura.
            LinearGradient(colors: [Color(rgb: 0x0B0D14), Color(rgb: 0x040508)],
                           startPoint: .top, endPoint: .bottom)
            // Una tinta per sezione, in dissolvenza incrociata al cambio di scheda.
            ForEach(PanelSection.allCases) { s in
                ZStack {
                    LinearGradient(colors: [s.theme.start.opacity(0.30), s.theme.end.opacity(0.10), Color.clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [s.theme.end.opacity(0.26), Color.clear],
                                   center: .bottomTrailing, startRadius: 20, endRadius: 760)
                    RadialGradient(colors: [s.theme.start.opacity(0.22), Color.clear],
                                   center: .topLeading, startRadius: 10, endRadius: 560)
                }
                .opacity(s == section ? 1 : 0)
            }
            .opacity(blackout ? 0 : 1)
        }
        .overlay(blackout ? Color.black : Color.clear)
        .animation(.easeInOut(duration: 0.45), value: section)
        .animation(.easeInOut(duration: 0.30), value: blackout)
        .ignoresSafeArea()
    }
}

// MARK: - Card (GroupBox)

/// Sostituisce ogni `GroupBox` con una card in vetro morbido; l'icona dell'etichetta prende il colore della sezione.
struct GlassGroupBoxStyle: GroupBoxStyle {
    @Environment(\.sectionTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassMetrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.accent)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Color.black.opacity(0.26)
                Color.white.opacity(0.05)
                LinearGradient(colors: [Color.white.opacity(0.07), Color.clear],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(shape)
        )
        .overlay(shape.strokeBorder(GlassMetrics.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
    }
}

// MARK: - Pulsanti e campi

/// Pulsante in vetro: pillola traslucida; i pulsanti con ruolo destructive sono rossi; `.prominent` usa il gradiente.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.sectionTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    private var vPad: CGFloat { controlSize == .small || controlSize == .mini ? 4 : 6 }
    private var hPad: CGFloat { controlSize == .small || controlSize == .mini ? 9 : 12 }

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(controlSize == .small || controlSize == .mini ? .caption : .callout, design: .rounded).weight(.medium))
            .foregroundStyle(prominent ? Color.white : (destructive ? Color.red : Color.primary))
            .padding(.vertical, vPad)
            .padding(.horizontal, hPad)
            .background(
                Group {
                    if prominent {
                        shape.fill(theme.gradient)
                    } else if destructive {
                        shape.fill(Color.red.opacity(0.16))
                    } else {
                        shape.fill(Color.white.opacity(configuration.isPressed ? 0.20 : 0.10))
                    }
                }
            )
            .overlay(shape.strokeBorder(prominent ? Color.white.opacity(0.28) : GlassMetrics.border, lineWidth: 1))
            .shadow(color: prominent ? theme.accent.opacity(0.35) : Color.clear, radius: 8, x: 0, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static var glassProminent: GlassButtonStyle { GlassButtonStyle(prominent: true) }
}

/// Campo di testo in vetro; i valori tecnici (IP, universi, canali, Hz, coordinate) restano a cifre tabulari.
struct GlassFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration
            .textFieldStyle(.plain)
            .font(.system(.body).monospacedDigit())
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(shape.fill(Color.black.opacity(0.28)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

extension TextFieldStyle where Self == GlassFieldStyle {
    static var glass: GlassFieldStyle { GlassFieldStyle() }
}

// MARK: - Barra delle sezioni a pillole

/// Le 5 schede come pillole morbide; la pillola attiva scorre da una scheda all'altra (`matchedGeometryEffect`).
struct SectionTabBar: View {
    @Binding var selection: PanelSection
    @Namespace private var pillSpace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelSection.allCases) { s in
                let active = s == selection
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = s }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: s.icon)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 11, weight: .semibold))
                        Text(s.rawValue)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(active ? Color.white : Color.white.opacity(0.62))
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if active {
                            Capsule(style: .continuous)
                                .fill(s.theme.gradient)
                                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.30), lineWidth: 0.75))
                                .shadow(color: s.theme.accent.opacity(0.45), radius: 8, x: 0, y: 3)
                                .matchedGeometryEffect(id: "pill", in: pillSpace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(s.rawValue)
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.26)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Maniglia di ridimensionamento

/// Barra verticale sottile e traslucida fra pannello e viewport: trascinala per allargare o stringere la viewport 3D.
/// Al passaggio del mouse si illumina e compare l'impugnatura.
struct PanelResizeHandle: View {
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>

    @State private var hovering = false
    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false

    private var active: Bool { hovering || dragStart != nil }

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.02), Color.white.opacity(active ? 0.55 : 0.16), Color.white.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: active ? 2 : 1)
                .shadow(color: Color.white.opacity(active ? 0.35 : 0), radius: 5)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(active ? 0.7 : 0))
                .frame(width: 4, height: 44)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: active)
        .onHover { inside in
            hovering = inside
            if inside, !cursorPushed {
                NSCursor.resizeLeftRight.push()
                cursorPushed = true
            } else if !inside, cursorPushed, dragStart == nil {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let proposed = (dragStart ?? width) + value.translation.width
                    width = min(max(proposed, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    dragStart = nil
                    if !hovering, cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
        )
        .help("Trascina per ridimensionare il pannello")
    }
}

// MARK: - Stile globale del contenuto del pannello

extension View {
    /// Applica a tutto il contenuto di una sezione: card in vetro, pulsanti e campi curati, liste trasparenti,
    /// tinta (slider, toggle, selezioni) e tema della sezione nell'ambiente.
    func sectionStyled(_ section: PanelSection) -> some View {
        self
            .environment(\.sectionTheme, section.theme)
            .groupBoxStyle(GlassGroupBoxStyle())
            .buttonStyle(GlassButtonStyle())
            .textFieldStyle(GlassFieldStyle())
            .tint(section.theme.accent)
            .scrollContentBackground(.hidden)
    }
}
