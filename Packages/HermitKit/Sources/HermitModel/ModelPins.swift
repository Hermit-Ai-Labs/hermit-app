import Foundation

/// The exact bytes of a model release, built into the app: every file's size and SHA-256, and for big files the
/// SHA-256 of each piece. Whatever source a byte comes from (models.hermit.my, ModelScope or Hugging Face), it is
/// only kept if it matches these, so no mirror can change the model.
///
/// Written by `scripts/publish-model.py` from the Hugging Face commit; never edit by hand.
public struct ModelPin: Sendable, Codable {
    public struct File: Sendable, Codable {
        public let path: String
        public let size: Int64
        public let sha256: String
        /// SHA-256 of each `pieceSize` slice, for files bigger than one piece.
        public let pieces: [String]?
        public init(path: String, size: Int64, sha256: String, pieces: [String]? = nil) {
            self.path = path; self.size = size; self.sha256 = sha256; self.pieces = pieces
        }
    }
    /// The Hugging Face commit these files are from.
    public let revision: String
    public let pieceSize: Int64
    public let files: [File]
}

enum ModelPins {
    static let all: [String: ModelPin] = [
    // rahulol/Hermit-1.2-4B-MLX-4bit
    "rahulol/Hermit-1.2-4B-MLX-4bit":
        ModelPin(revision: "6183aaf929d66dc50f4b7c547d140fca57be54e6", pieceSize: 134217728, files: [
            .init(path: "generation_config.json", size: 174, sha256: "b85588c5a41e2eb6667442f752ea5d2ecbe310ef6189f0fde59a6479ff1921eb"),
            .init(path: "tokenizer_config.json", size: 730, sha256: "400c3ab7c84026ef441e0223425c8724f11057171df2c149a544825d3296afb7"),
            .init(path: "config.json", size: 2014, sha256: "22da2f5295ee337b28b2065452b2ff3812ddc8c3589dc244d52c8609d0419d98"),
            .init(path: "chat_template.jinja", size: 8571, sha256: "e4174581bb7d9926b7b6420bb84a03a3f61fcefd68f8587c4ce5f4bbf638ae1e"),
            .init(path: "model.safetensors.index.json", size: 63964, sha256: "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777"),
            .init(path: "tokenizer.json", size: 11422650, sha256: "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
            .init(path: "model.safetensors", size: 2263022529, sha256: "f9b656bc2c489631786a7bf204eb1d922e8e493372d107282049092cb6464495", pieces: [
                "f1667cfe35d1e20292fa44f36aa39723d81b37c03a2d299192ec469352f896e2",
                "9041e6cbfde1a77a91e74e5d2c12a22f87d176384bc29f9a9210d1e940b0e606",
                "52551c348575ddaa9185bcb958cc45ea8d6ac609df2d82304abaf068447d4902",
                "3b0c76f2ca2cb14aa9e49cc1254492250296e8c2a2bf483a6de37b8c4af95ecc",
                "a7cb2dd8ae181d60069cdeea4479da473cb51688bf5209dfef5d70270924c4d0",
                "2f535b5f2b8d294f279f5fd92006089deb20a1a78c01ab785ba95c407fe0484d",
                "ad67184e9f252906606165a3d94351f0a0c1855ab07193e819da182b323cf7d4",
                "b0fe4eac417a3bc79d21189bf18270451fe68cb6c3bc1d76983fcb896dc2f9cf",
                "dba43976de7893724bcac6a8f1bd6662f3c9f35564603f91573d0f394c3458c7",
                "4aa7b39ea9bfcb18304ecfb69bc2581e347b321aee6d1c2d650c47a0f0426c22",
                "e11dbd81cc200e02dee52c2a7622a40e5e9d16fbe0a3d1c399efc27668263de7",
                "09049d54fa07589d3bb1132ca728a758b2097df026001f0d1d3b9f6d4edfec66",
                "4ea8553dbe4da057de2b74df44a4f385336a19e9024e55865934c94ba1d736da",
                "78a5bfc98686e3e96d214faf40c1e7f0ad2fda470296f43fb6e16499333eda73",
                "cf549e7a4f449aa33ea2f90b67d9e40c89c1a923cfc4264335630da74c4d7fff",
                "93fe9ee5ec459182ac097b57c63a88deb6e1148190a29def152eda639406259c",
                "39507650dc0aae97655cf793664056b1efd592d5771d32e6cad28e35a2d3b016",
            ]),
        ]),
    // rahulol/Hermit-1.1-Lite-MLX-4bit
    "rahulol/Hermit-1.1-Lite-MLX-4bit":
        ModelPin(revision: "52b8428909ab484f23945d317a32d4a63da57f49", pieceSize: 134217728, files: [
            .init(path: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
            .init(path: "added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
            .init(path: "config.json", size: 937, sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
            .init(path: "tokenizer_config.json", size: 9706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
            .init(path: "model.safetensors.index.json", size: 49731, sha256: "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
            .init(path: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            .init(path: "tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            .init(path: "model.safetensors", size: 968080210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f", pieces: [
                "4f31af10ef6b77e67d3abb6c353e820483d070f50e89491a4cff833e6a09540e",
                "df7379f32ddae9990fa5179cc8f496407a1163043f419d62b1ac09ff6aec47d2",
                "06f843a3a8f2550b137329acf7c81b1e1076836c882ad5d13d85d05e1f2c95cf",
                "12600cc112c0aaea47d3e649ee874351edf375b888dd5b573caf5dea71ab2f13",
                "3f19c2d76d59d497b51810f209310d7bd2ef3f75b9b86dcd170fe235fa72c47f",
                "e514383f48d2bae7ea2add665f512189fb0211c71c9fed7fa33491e6481e8a32",
                "9c40f23d8ae67f522f8865e74ae81b2398be18765c501b2b747f3bdfa9dc82c3",
                "11aaf4ecc7563cc96fc46b6457c98528e6d85b6119a1f9130ecb20aed192dfe9",
            ]),
        ]),
    ]
}
