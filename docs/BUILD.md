# Building Hermit

You need macOS 26, Xcode 26 (we use 26.6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/Hermit-Ai-Labs/hermit-app && cd hermit-app
brew install xcodegen
xcodegen generate        # writes Hermit.xcodeproj from project.yml
open Hermit.xcodeproj    # targets: Hermit (Mac), HermitiOS (iPhone), HermitWidgets
```

`project.yml` signs the iPhone targets and the Mac Release build with our team ID, so pick your own team in Xcode
(Signing & Capabilities) to run on your devices. To build without signing from the command line, the way our CI
(`.github/workflows/apple.yml`) does on a `macos-26` runner:

```sh
xcodebuild -project Hermit.xcodeproj -scheme Hermit -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
xcodebuild -project Hermit.xcodeproj -scheme HermitiOS -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
```

The tests are in [VERIFY.md](VERIFY.md#the-swift-tests).

## Where the code is

Code paths are under `Packages/HermitKit/Sources/`. The NEAR parts have their own page, [NEAR.md](NEAR.md).

- `HermitCore/` is the tool loop. It parses tool calls, cleans tool results and guards the money tools
  (`ToolLoop.swift`, `ToolCalls.swift`, `AgentTools.swift`).
- `HermitModel/` has the on-device models and their download (`ModelCatalog.swift`, `LocalAgent.swift`,
  `ModelSources.swift`, `ModelPins.swift`).
- `HermitCloud/` is Private Cloud on NEAR AI Cloud.
- `HermitWallet/` has the keys and chains (`KeyVault.swift`, `Chains.swift`), the spending policy
  (`SpendPolicy.swift`), batch sends (`BatchSend.swift`), Hyperliquid, Jupiter and Aave (`Hyperliquid.swift`,
  `Jupiter.swift`, `AavePositions.swift`) and the browser wallet (`Dapps/`).
- `HermitUI/` has the screens: `Chat/`, `Cloud/`, `Pages/Wallets/`, `Pages/Trade/`, `Pages/Earn/`, `Pages/Browser/`
  and `Pages/Payments/`, plus `ApprovalSheet.swift` and `AutomationScheduler.swift`.

## Our scripts

They all run on a Mac. The release ones need our signing setup.

- `bash scripts/core-tests.sh` runs the non-UI tests without building MLX or SwiftUI.
- `zsh scripts/run-iphone.sh [device-id]` builds a development copy and installs it on a connected iPhone.
- `zsh scripts/release-mac.sh` makes the signed, notarized DMG.
- `zsh scripts/release-ios.sh` archives the iPhone app and uploads it to TestFlight. With `ARCHIVE_ONLY=1` it stops
  before the upload.
- `bash scripts/bundle-shared-key.sh` writes our shared NEAR AI key and 1Click partner key into the bundle, masked, for
  TestFlight builds. The files it writes are gitignored, and `--remove` takes them out. Without them, you add your own
  keys in the app.
- `bash scripts/agent-check.sh` runs the on-device tool loop against a real model folder, outside the app.
- `zsh scripts/mac-shots.sh` and `zsh scripts/phone-shots.sh` take screenshots of every screen from Debug builds.

The README's figures are in `docs/img/`. Each one is drawn from `docs/img/src/<name>/figure.html`, and
`PW=<path to the playwright module> node docs/img/src/render.cjs` renders them all, light and dark.
