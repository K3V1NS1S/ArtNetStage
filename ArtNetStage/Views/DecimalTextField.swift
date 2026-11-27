import SwiftUI

/// Campo numerico con digitazione libera (v3.0).
///
/// Il testo mostrato è uno `@State` interno, separato dal valore `Double` del modello: mentre si scrive non viene
/// mai riformattato, quindi si possono digitare liberamente cifre, virgola `,`, punto `.` e segno `-`.
/// Il testo diventa un numero (con la virgola normalizzata in punto) solo alla conferma: Invio (`onSubmit`) oppure
/// perdita del focus (`onChange(of: isFocused)`). Il modello viene quindi scritto una volta sola, a conferma avvenuta,
/// e un solo passo entra nella cronologia Annulla/Ripristina. Un testo non valido ripristina il valore precedente.
struct DecimalTextField: View {
    var title: String = ""
    @Binding var value: Double
    var minimum: Double? = nil
    var maximum: Double? = nil
    var maxFractionDigits: Int = 3
    var alignment: TextAlignment = .leading

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.glass)
            .multilineTextAlignment(alignment)
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { focused in
                if !focused { commit() }                     // perdita del focus = conferma
            }
            .onChange(of: text) { newText in
                // Solo cifre, virgola, punto e segno meno: tutto il resto viene scartato mentre si scrive.
                let allowed = newText.filter { "0123456789.,-".contains($0) }
                if allowed != newText { text = allowed }
            }
            .onChange(of: value) { newValue in
                if !isFocused { text = Self.format(newValue, digits: maxFractionDigits) }   // modifiche da slider / Gumball
            }
            .onAppear { text = Self.format(value, digits: maxFractionDigits) }
    }

    private func commit() {
        let normalized = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed.isFinite else {
            text = Self.format(value, digits: maxFractionDigits)       // testo non valido: si torna al valore attuale
            return
        }
        var v = parsed
        if let minimum { v = Swift.max(v, minimum) }
        if let maximum { v = Swift.min(v, maximum) }
        if v != value { value = v }
        text = Self.format(v, digits: maxFractionDigits)
    }

    /// Testo mostrato a riposo: numero con la virgola della lingua di sistema, senza separatore delle migliaia.
    static func format(_ v: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
