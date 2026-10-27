//
//  ContentView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI

protocol SubviewOfContentView: View {
    var viewModel: ContentViewModel { get set }
    
//    init(contentViewModel viewModel: ContentViewModel)
}

struct ContentView: View {
    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel
    
    @ObservedObject var viewModel: ContentViewModel
    
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @State var isDropTargeted = false
    @State var isParseFinished = false
    @State var isFilterReveal = true
    
    @State var isDockIconHidden = false
    
    @State var project: WEProject!
    @State var projectUrl: URL!
    @State var greet: String = "Hello, world!"
    
    var body: some View {
        ZStack {
            HSplitView {
                if viewModel.isStaging {
                    VStack(spacing: 5) {
                        TopTabBar(contentViewModel: viewModel)
                        switch viewModel.topTabBarSelection {
                        case 0:
                            ExplorerTopBar(contentViewModel: viewModel)
                                .environmentObject(globalSettingsViewModel)
                            HStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    // MARK: Filter Results
                                    FilterResults(viewModel: viewModel)
                                }
                                .frame(width: viewModel.isFilterReveal ? 225 : 0)
                                .opacity(viewModel.isFilterReveal ? 1 : 0)
                                .animation(.spring(), value: viewModel.isFilterReveal)
                                
                                WallpaperExplorer(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                                .onDrop(of: [.fileURL], delegate: viewModel)
                                .contextMenu {
                                    ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                                }
                                .padding(.leading, viewModel.isFilterReveal ? 10 : 0)
                            }
                            .animation(.default, value: viewModel.isFilterReveal)
                        case 1:
                            WorkshopView(contentViewModel: viewModel)
                        default:
                            fatalError()
                        }
                        if viewModel.topTabBarSelection == 0 {
                            HStack {
                                Button {
                                    AppDelegate.shared.openImportFromFolderPanel()
                                } label: {
                                    Label("Open Wallpaper", systemImage: "arrow.up.bin.fill")
                                        .frame(width: 220)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    WallpaperPreview(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                        .frame(maxWidth: 320)
                }
            }
            .opacity(viewModel.isStaging ? 1 : 0)
            .blur(radius: viewModel.isStaging ? 0 : 2.0)
            
            // indicate that this view is initializing
            if !viewModel.isStaging {
                HStack(spacing: 20) {
                    Text("Power Saving Mode, Sleeping...")
                        .font(.largeTitle)
                }
            }
        }
        .confirmationDialog("Unsubscribe Confirmation",
                            isPresented: $viewModel.isUnsubscribeConfirming) {
            if let url = viewModel.hoveredWallpaper?.wallpaperDirectory {
                Button("Delete Immediately", role: .destructive) {
                    unsubscribe([url], toTrash: false)
                    viewModel.hoveredWallpaper = nil
                }
                Button("Move to Trash") {
                    unsubscribe([url], toTrash: true)
                    viewModel.hoveredWallpaper = nil
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.hoveredWallpaper = nil
            }
        } message: {
            Text("\(viewModel.hoveredWallpaper?.project.title ?? "invalid wallpaper")")
        }
        .confirmationDialog("Batch Unsubscribe Confirmation",
                            isPresented: $viewModel.isBatchUnsubscribeConfirming) {
            Button("Delete All \(viewModel.selectedWallpapers.count) Immediately", role: .destructive) {
                unsubscribe(Array(viewModel.selectedWallpapers), toTrash: false)
                viewModel.clearSelection()
            }
            Button("Move All \(viewModel.selectedWallpapers.count) to Trash") {
                unsubscribe(Array(viewModel.selectedWallpapers), toTrash: true)
                viewModel.clearSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let items = viewModel.selectedWallpaperItems()
            let names = items.prefix(3).map(\.project.title).joined(separator: ", ")
            let suffix = items.count > 3 ? " and \(items.count - 3) more" : ""
            Text("Unsubscribe \(items.count) wallpapers: \(names)\(suffix)")
        }
        .alert(isPresented: $viewModel.importAlertPresented, error: viewModel.importAlertError) { _ in

        } message: { error in
            // Spelled out because the per-item import report lives in failureReason, and
            // the message-less overload is not guaranteed to show it.
            Text([error.failureReason, error.recoverySuggestion]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        .sheet(isPresented: $globalSettingsViewModel.isFirstLaunch) {
            FirstLaunchView()
                .environmentObject(globalSettingsViewModel)
        }
        .sheet(isPresented: $viewModel.isDisplaySettingsReveal) {
            DisplaySettings(viewModel: viewModel)
                .padding()
                .frame(width: 520, height: 450)
        }
        .sheet(isPresented: $viewModel.isUnsafeWallpaperWarningPresented) {
            UnsafeWallpaper(wallpaper: wallpaperViewModel.nextCurrentWallpaper)
                .frame(width: 600, height: 300)
        }
        .frame(minWidth: 1000, minHeight: 640, idealHeight: 800)
    }

    /// Delete or trash wallpaper folders, unassigning only the ones actually removed.
    ///
    /// The old buttons ran `try?` and then unassigned regardless, so a failed delete (a
    /// permission error, a volume without a Trash) left the wallpaper on disk and in the
    /// grid, took it off every screen, and said nothing.
    private func unsubscribe(_ urls: [URL], toTrash: Bool) {
        var failures: [String] = []
        for url in urls {
            do {
                if toTrash {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
                wallpaperViewModel.removeWallpaperFromAllScreens(directory: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        viewModel.refresh()
        if !failures.isEmpty {
            viewModel.alertImportModal(which: WPImportError(
                errorDescription: "Could Not Unsubscribe \(failures.count) Wallpaper(s)",
                failureReason: failures.prefix(8).joined(separator: "\n"),
                helpAnchor: "",
                recoverySuggestion: ""
            ))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: .init(isStaging: true), wallpaperViewModel: .init())
            .environmentObject(GlobalSettingsViewModel())
    }
}
