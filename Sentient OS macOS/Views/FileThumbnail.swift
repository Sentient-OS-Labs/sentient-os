//
//  FileThumbnail.swift
//  Sentient OS macOS
//
//  Shared file preview: a real QuickLook thumbnail (PDF page / image / doc preview), falling
//  back to the workspace file-type icon. Used by the Database viewer and the Processing screen.
//

import SwiftUI
import AppKit
import QuickLookThumbnailing

struct FileThumbnail: View {
    let path: String?
    let size: CGFloat
    var cornerRadius: CGFloat?

    @State private var image: NSImage?

    private var radius: CGFloat { cornerRadius ?? size * 0.18 }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable().aspectRatio(contentMode: .fit).padding(size * 0.16)
            } else {
                Image(systemName: "doc").font(.system(size: size * 0.38)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .task(id: path) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        image = nil
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size * 2, height: size * 2),
            scale: scale, representationTypes: .thumbnail
        )
        let nsImage: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
        if let nsImage { image = nsImage }
    }
}
