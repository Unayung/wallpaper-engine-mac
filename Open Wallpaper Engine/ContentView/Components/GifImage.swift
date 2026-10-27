//
//  GifImage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import Cocoa
import SwiftUI

struct GifImage: NSViewRepresentable {
    
    var gifName: String?
    var gifUrl: URL?
    
    var isResizable: Bool = false
    var contentMode: ContentMode = .fill
    
    var animates: Bool
    
    init(_ gifName: String, animates: Bool = true) {
        self.gifName = gifName
        self.animates = animates
    }
    
    init(contentsOf url: URL, animates: Bool = true) {
        self.gifUrl = url
        self.animates = animates
    }
    
    /// What the view last loaded, so updates that do not change it cost nothing.
    final class Coordinator {
        var loaded: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let nsView = NSImageView()
        
        nsView.canDrawSubviewsIntoLayer = true
        nsView.imageScaling = .scaleProportionallyUpOrDown
        nsView.animates = animates
        
        updateModifiers(nsView, context: context)
        
        return nsView
    }
    
    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = animates
        updateModifiers(nsView, context: context)
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        if !self.isResizable {
            return nsView.sizeThatFits(nsView.frame.size)
        } else {
            guard let width = proposal.width, let height = proposal.height else { return nil }
            return CGSize(width: width, height: height)
        }
    }
    
    private var sourceURL: URL? {
        if let gifName = self.gifName {
            return Bundle.main.url(forResource: gifName, withExtension: "gif")
        }
        return gifUrl
    }

    private func updateModifiers(_ nsView: NSImageView, context: Context) {
        // Decode only when the source changes. updateNSView runs on every re-render of the
        // parent — for the preview pane, every tick of its Volume slider — and reloading
        // here re-read and re-decoded the file each time (58 library previews are GIFs of
        // up to 1 MB).
        let url = sourceURL
        if url != context.coordinator.loaded {
            context.coordinator.loaded = url
            if let url, let image = NSImage(contentsOf: url) {
                let gifRep = image.representations.first as? NSBitmapImageRep
                gifRep?.setProperty(.loopCount, withValue: 0)
                nsView.image = image
            } else {
                nsView.image = nil
            }
        }
        if self.isResizable {
            switch self.contentMode {
            case .fill:
                nsView.imageScaling = .scaleAxesIndependently
            case .fit:
                nsView.imageScaling = .scaleProportionallyUpOrDown
            }
        }
    }
    
    func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> Self {
        var view = self
        view.isResizable = true
        return view
    }
    
    func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> Self {
        var view = self
        view.contentMode = contentMode
        return view
    }
}
