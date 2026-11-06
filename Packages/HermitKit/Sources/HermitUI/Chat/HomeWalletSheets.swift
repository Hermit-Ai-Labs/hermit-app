import SwiftUI
import CoreImage.CIFilterBuiltins

/// A QR code for an address or payment link. Home's wallet buttons open the Wallets page's real sheets now.
struct QRCode: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            img.interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit()
        }
    }
    static func make(_ s: String) -> Image? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}
