# Label Studio for iPhone

A SwiftUI iOS 17+ app for compatible 4.2-inch, 400 × 300 WoLink labels. It prepares
black, white, yellow and red artwork and writes it directly over CoreBluetooth.
Image generation is optional: imported PNGs and JPEGs work locally.

## Configure your installation

The public project uses `com.example.LabelStudio`, an empty signing team and an
empty server address. It contains no server credentials or label authentication
key. Obtain the key for your own compatible label from an authorized source;
this repository does not supply one.

1. Open Settings in the app. Enter your label authentication key as exactly
   32 hexadecimal characters, then choose **Save label key**. The key is stored
   in this app's Keychain with access restricted to the unlocked device. It is
   used locally for the Bluetooth challenge response and is never sent to the
   image-generation server. Settings also lets you replace or remove it.
2. To generate artwork, deploy your own [backend](../backend/README.md). Keep the
   OpenAI API key in the backend's secret storage. Enter the backend HTTPS origin
   and private connection code in the app's Settings. The connection code is
   stored separately in Keychain; changing server origins requires a new code.
3. Create or import a design, inspect the final four-colour preview, then choose
   your nearby label and write. Keep the app open. Advertising windows can make
   discovery take several minutes; the screen may flash during refresh.

If the app reports an unconfirmed refresh, inspect the physical display before
retrying. Only the 400 × 300 profile is implemented; do not use it for another
panel size without updating and validating its format.

## Build

Open `ios/LabelStudio.xcodeproj` from the repository root. Simulator builds need
no signing team. Install the Ruby `xcodeproj` gem if you want to regenerate the
project after adding sources:

```sh
gem install xcodeproj
ruby scripts/generate_xcode_project.rb
xcodebuild -project ios/LabelStudio.xcodeproj -scheme LabelStudio \
  -showdestinations
```

For a physical iPhone, create the ignored `ios/Config/Local.xcconfig` and set your
own values:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
BUNDLE_ID_PREFIX = your.unique.reverse.domain
```

`Config/Defaults.xcconfig` includes this optional file. Generated project files
retain variable references rather than copying personal values. The app's bundle
ID becomes `your.unique.reverse.domain.LabelStudio`. Leave the server address
empty and enter it at runtime, or optionally add the nonsecret address locally:

```xcconfig
LABEL_SERVICE_URL = https:/$()/your-server.example
```

The `$()` avoids treating the slashes as an xcconfig comment. Never put either
connection code, a label key or an OpenAI API key in build settings, assets or
source. Keep `Local.xcconfig` untracked.

Select an installed simulator name from `-showdestinations` when running tests:

```sh
xcodebuild -project ios/LabelStudio.xcodeproj -scheme LabelStudio \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_SIMULATOR' \
  -derivedDataPath tmp/ios-derived test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

Local ad-hoc simulator signing needs no Apple developer account and allows the
Keychain integration tests to use real storage. Disabling signing prevents those
storage tests from running successfully.

Tests cover rendering, image orientation and packing, synthetic FIPS-197 AES
vectors, Bluetooth packet/status handling, isolated Keychain key storage,
credential origin binding, redirect rejection and basic UI navigation. All
network responses in tests are mocked. The test artwork resource is a generic
illustration; it is never included in the application target. Simulator tests do
not establish physical iPhone-to-label compatibility.

## Architecture

- `LabelArtwork` normalizes image orientation, fits the canvas, flattens alpha
  onto white and packs four pixels per byte. The preview and display bytes use
  the same exact palette.
- `LabelProtocol` implements the wire format and accepts an explicit 16-byte
  authentication key. No default key exists. GATT service/characteristic UUIDs
  are public protocol identifiers, not identifiers for a particular label.
- `LabelBluetooth` uses fresh advertisements, acknowledged short writes and
  current refresh notifications. An upload acknowledgement does not by itself
  confirm that the display refreshed. Cancellation after refresh begins can
  leave the physical outcome uncertain.
- `GenerationClient` talks to your private backend over HTTPS with bounded
  responses and redirects disabled. Persisted request IDs support resuming an
  interrupted generation without silently starting another paid request.
- `LabelKeyStore` and `ConnectionSettings` store separate credentials in Keychain.
  The local design library works independently of the backend.

## Sign and distribute your own build

Choose your own Apple developer team, unique bundle identifier, version and build
number. Create your own App Store Connect app record and distribution group.
Archive using those local signing settings, then validate and upload through
Xcode Organizer or your own release tooling. No published release or tester
access is included with this source distribution.

`ExportOptions.plist` is a generic export template without a team ID. If a command
line export needs an explicit team, copy it to the ignored
`ios/ExportOptions.local.plist` and add your own `teamID` there. Keep signing
certificates, provisioning profiles, App Store Connect keys, archives and IPA
files outside version control. Review the privacy declaration against your
backend's actual retention and logging practices before distributing an app.
