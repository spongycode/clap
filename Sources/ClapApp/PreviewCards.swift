import AppKit
import SwiftUI
import ClapCore

// MARK: - Feature cards

struct ColorCardView: View {
    @EnvironmentObject private var state: AppState
    let color: ParsedColor
    let source: String

    private var formats: ParsedColor.Formats { color.formats }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: color.red, green: color.green, blue: color.blue,
                            opacity: color.alpha))
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Color Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    formatCopyButton("HEX", formats.hex)
                    formatCopyButton("RGB", formats.rgb)
                    formatCopyButton("HSL", formats.hsl)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color preview: \(source)")
    }

    private func formatCopyButton(_ label: String, _ value: String) -> some View {
        Button {
            state.copyTransformedText(value)
        } label: {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.primary.opacity(AppAlpha.Fill.soft))
                )
        }
        .buttonStyle(.plain)
        .help("Copy as \(label)")
        .accessibilityLabel("Copy color as \(label)")
    }
}

struct DecodedCardView: View {
    let icon: String
    let tint: Color
    let title: String
    let decoded: String
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button(action: onCopy) {
                        Label("Copy Decoded", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Text(decoded)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.06))
        )
    }
}

struct JWTCardView: View {
    @EnvironmentObject private var state: AppState
    let jwt: JWTData
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text("JWT Inspector")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.primary)

                Text(jwt.algorithm)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )

                if let isExp = jwt.isExpired {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(isExp ? Color.red : Color.green)
                            .frame(width: 6, height: 6)
                        Text(isExp ? "Expired" : "Valid")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isExp ? .red : .green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill((isExp ? Color.red : Color.green).opacity(0.12))
                    )
                }

                Spacer()

                Menu {
                    Button("Copy Payload JSON") { onCopy(jwt.payloadJSON) }
                    Button("Copy Header JSON") { onCopy(jwt.headerJSON) }
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if jwt.subject != nil || jwt.issuer != nil || jwt.expirationDate != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let sub = jwt.subject {
                        claimRow(label: "Subject:", value: sub, monospaced: true)
                    }
                    if let iss = jwt.issuer {
                        claimRow(label: "Issuer:", value: iss, monospaced: true)
                    }
                    if let expDate = jwt.expirationDate {
                        HStack(spacing: 6) {
                            Text("Expires:")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(Self.dateFormatter.string(from: expDate))
                                .font(.system(size: 11))
                        }
                    }
                }
            }

            Divider()

            Text("Decoded Payload:")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(jwt.payloadJSON)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
                )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.indigo.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.indigo.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func claimRow(label: String, value: String, monospaced: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct EpochCardView: View {
    @EnvironmentObject private var state: AppState
    let epoch: EpochData
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "clock.badge.checkmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Epoch Timestamp")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(epoch.unitDescription)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.12))
                        )
                }

                Spacer()

                Menu {
                    Button("Copy ISO 8601 (\(epoch.iso8601))") { onCopy(epoch.iso8601) }
                    Button("Copy Local Date") { onCopy(epoch.localFormatted) }
                    if epoch.unitDescription.contains("Seconds") {
                        Button("Copy as Milliseconds (\(epoch.unixMillis))") {
                            onCopy(String(epoch.unixMillis))
                        }
                    } else {
                        Button("Copy as Seconds (\(epoch.unixSeconds))") {
                            onCopy(String(epoch.unixSeconds))
                        }
                    }
                } label: {
                    Label("Copy Date", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(epoch.localFormatted)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    Text("UTC:")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(epoch.iso8601)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 5) {
                    Text("Relative:")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(epoch.relativeFormatted)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

struct ImageContentView: View {
    let entry: ClipboardEntry
    let image: NSImage?
    var showsQR: Bool = false
    var onCopyImage: (Data) -> Void = { _ in }
    let onCopyText: (String) -> Void

    var body: some View {
        ScrollView([.vertical]) {
            VStack(spacing: 12) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.panelBorder), lineWidth: 0.5)
                            )
                    } else {
                        ProgressView()
                            .frame(height: 140)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Image preview, \(entry.imageFormat?.uppercased() ?? "unknown format")")
                .padding(.top, 4)

                if showsQR, let ocrSource = entry.content, QRCodeBuilder.canEncode(ocrSource) {
                    QRCardView(content: ocrSource) { png in
                        onCopyImage(png)
                    }
                }

                if let ocrText = entry.content, !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Extracted Text (OCR)", systemImage: "doc.text.viewfinder")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Button { onCopyText(ocrText) } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        Text(ocrText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
                            )
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - QR code card

/// Renders clipboard text as a scannable QR — send links/text to a phone
/// with no network dependency. Content fades in once generated.
struct QRCardView: View {
    @EnvironmentObject private var state: AppState
    let content: String
    let onCopyImage: (Data) -> Void

    @State private var qrImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                Text("QR Code")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                if qrImage != nil {
                    Button {
                        if let png = QRCodeBuilder.pngData(for: content) {
                            onCopyImage(png)
                        }
                    } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Copy the QR image to the clipboard")
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.clear.overlay(ProgressView())
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.hairline), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan with a phone camera")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Opens this content on another device — no network needed.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
                )
        )
        .task(id: content) {
            qrImage = nil
            let generated = await Task.detached(priority: .userInitiated) {
                QRCodeBuilder.pngData(for: content)
            }.value
            if let data = generated, let image = NSImage(data: data) {
                qrImage = image
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QR code for clipboard content")
    }
}

// MARK: - JSON card

/// Validated JSON with pretty/minified renderings and one-tap copies.
struct JSONCardView: View {
    @EnvironmentObject private var state: AppState
    let json: JSONData
    var repairedFixes: [String] = []
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: repairedFixes.isEmpty ? "curlybraces" : "wand.and.rays")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(repairedFixes.isEmpty ? .mint : .orange)
                Text(repairedFixes.isEmpty ? "JSON" : "JSON · Repaired")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.primary)

                Text(json.isTopLevelObject
                     ? "object · \(json.valueCount) keys"
                     : "array · \(json.valueCount) items")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(
                        (repairedFixes.isEmpty ? Color.mint : Color.orange).opacity(0.12)))

                Spacer()
            }
            if !repairedFixes.isEmpty {
                Text("Fixed: " + repairedFixes.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Fixes applied by JSON repair")
            }

            HStack(spacing: 6) {
                formatCopyButton("Copy Pretty", json.pretty)
                formatCopyButton("Copy Minified", json.minified)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((repairedFixes.isEmpty ? Color.mint : Color.orange).opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder((repairedFixes.isEmpty ? Color.mint : Color.orange).opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func formatCopyButton(_ label: String, _ value: String) -> some View {
        Button {
            onCopy(value)
        } label: {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(AppAlpha.Fill.soft)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
