import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Apple-hosted asset packs (the speech model). The system downloads what the
/// app asks for; the default behaviour is all this needs.
@main
struct AssetPackDownloader: StoreDownloaderExtension {}
