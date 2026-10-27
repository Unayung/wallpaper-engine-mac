//
//  SettingsView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI

protocol SettingsPage: View {
    var viewModel: GlobalSettingsViewModel { get set }
    
    init(globalSettings: GlobalSettingsViewModel)
}

// `GlobalSettingsViewModel.selection` indexes the pages in toolbar order; these three and the
// switch in `SettingsView` are the only places that know the numbers. A "Plugins" page used to
// sit at 2 with About at 3; it held placeholder text and one real toggle, which now lives in
// General.
extension AppDelegate {
    @objc func jumpToPerformance() {
        self.globalSettingsViewModel.selection = 0
    }

    @objc func jumpToGeneral() {
        self.globalSettingsViewModel.selection = 1
    }

    @objc func jumpToAbout() {
        self.globalSettingsViewModel.selection = 2
    }
}

struct SettingsView: View {
    @EnvironmentObject var viewModel: GlobalSettingsViewModel
    
    var body: some View {
        VStack {
            Group {
                switch viewModel.selection {
                case 0:
                    PerformancePage(globalSettings: viewModel)
                case 1:
                    GeneralPage(globalSettings: viewModel)
                case 2:
                    AboutUsView()
                default:
                    fatalError()
                }
            }
            .frame(minHeight: 400, maxHeight: 800)
            // No OK / Cancel / "Edited": every control applies the moment it changes (see
            // `GlobalSettingsViewModel.settings`), and those three only pretended otherwise.
        }
        .frame(minWidth: 500)
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.about]
    }
        
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.about]
    }
    
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.about]
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        
        switch itemIdentifier {
        case SettingsToolbarIdentifiers.performance:
            toolbarItem.action = #selector(jumpToPerformance)
            toolbarItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "Performance")

        case SettingsToolbarIdentifiers.general:
            toolbarItem.action = #selector(jumpToGeneral)
            toolbarItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "General")
            
        case SettingsToolbarIdentifiers.about:
            toolbarItem.action = #selector(jumpToAbout)
            toolbarItem.image = NSImage(systemSymbolName: "person.3", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "About")
            
        default:
            fatalError()
        }
        
        toolbarItem.isBordered = false
        
        return toolbarItem
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject({ () -> GlobalSettingsViewModel in 
                let viewModel = GlobalSettingsViewModel()
                viewModel.selection = 1
                return viewModel
            }())
            .frame(width: 500, height: 600)
    }
}


