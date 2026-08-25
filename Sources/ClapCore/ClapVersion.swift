/// Single source of truth for the release version.
///
/// Everything else derives from here:
/// - CLI `--version` and the Settings header read `ClapVersion.current`.
/// - `Scripts/make_app.sh` injects it into Info.plist's
///   CFBundleShortVersionString at packaging time.
/// - `Scripts/bump_version.sh` updates ONLY this file.
public enum ClapVersion {
    public static let current = "0.2.2"
}
