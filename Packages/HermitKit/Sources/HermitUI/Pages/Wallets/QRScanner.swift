#if os(iOS)
import SwiftUI
import VisionKit

/// Live camera QR scanning for Send (VisionKit). The camera is used only while this is on screen; nothing is saved.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var available: Bool { DataScannerViewController.isSupported }

    /// "ethereum:0xabc@8453?value=1", "solana:Abc…?amount=1" → just the address.
    static func address(from code: String) -> String {
        var s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = s.firstIndex(of: ":"), !s.hasPrefix("0x") { s = String(s[s.index(after: colon)...]) }
        if let cut = s.firstIndex(where: { $0 == "@" || $0 == "?" || $0 == "/" }) { s = String(s[..<cut]) }
        return s
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let b) in items {
                if let v = b.payloadStringValue, !v.isEmpty {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(v); return
                }
            }
        }
    }
}

/// Full-screen camera with a frame and a Cancel button.
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            QRScannerView(onCode: onCode).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.9), lineWidth: 3).frame(width: 250, height: 250)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel("Cancel")
                }
                Spacer()
                Text("Point at a wallet address QR code").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.45), in: Capsule())
            }
            .padding(20)
        }
        .background(.black)
    }
}
#endif
