//
//  AboutUsView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI

extension AppDelegate {
    @objc func showAboutUs() {
        let window = NSWindow()
        window.styleMask = [.closable, .titled]
        window.isReleasedWhenClosed = false
        window.title = ""
        window.contentView = NSHostingView(rootView: AboutUsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutUsView: View {
    var body: some View {
        VStack(spacing: 50) {
            HStack {
                Image(nsImage: NSImage(named: "AppIcon")!)
                Divider().frame(maxHeight: 100)
                VStack(alignment: .leading) {
                    Text("Open Wallpaper Engine").bold().font(.title)
                    Text("Wallpaper Engine for Mac").font(.footnote)
                }
            }
            VStack(spacing: 12) {
                Text("version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String)")

                Divider().frame(width: 200)

                Text("Contributors")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    creditRow("Haren Chen", handle: "haren724", role: "Original creator")
                    creditRow("MrWindDog", handle: "MrWindDog", role: "Upstream maintainer")
                    creditRow("Chen Chia Yang", handle: "Unayung", role: "Scene rendering, Workshop, multi-display")
                    creditRow("1ris_W", handle: "Erica-Iris", role: "Chinese i18n")
                    creditRow("Klaus Zhu", handle: "klauszhu1105", role: "App logo icons")
                }
                .font(.caption)
            }
        }
        .frame(width: 420, height: 380)
    }
}

extension AboutUsView {
    private func creditRow(_ name: String, handle: String, role: String) -> some View {
        HStack(spacing: 4) {
            Link("@\(handle)", destination: URL(string: "https://github.com/\(handle)")!)
                .frame(width: 120, alignment: .leading)
            Text("—")
                .foregroundStyle(.tertiary)
            Text(role)
                .foregroundStyle(.secondary)
        }
    }
}

struct AboutUsView_Previews: PreviewProvider {
    static var previews: some View {
        AboutUsView()
    }
}
