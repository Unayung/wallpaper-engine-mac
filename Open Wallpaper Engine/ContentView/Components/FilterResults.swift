//
//  FilterResults.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/29.
//

import SwiftUI

struct FilterSection<Content>: View where Content: View {
    private let content: Content
    private let alignment: HorizontalAlignment
    private var spacing: CGFloat?
    private let titleKey: LocalizedStringKey
    
    @State private var isExpanded: Bool = true
    
    init(_ titleKey: LocalizedStringKey, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.alignment = alignment
        self.spacing = spacing
        self.titleKey = titleKey
    }
    
    var body: some View {
        VStack(alignment: self.alignment, spacing: self.spacing) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.caption)
                        .rotationEffect(isExpanded ? .zero : .degrees(-90.0))
                        .animation(.spring(), value: isExpanded)
                    Text(self.titleKey)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if isExpanded {
                content.padding(.leading, (self.alignment == .leading) ? 10 : 0)
            }
        }
    }
}

struct FilterResults: View {
    @ObservedObject var viewModel: FilterResultsViewModel
    
    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 30) {
                    Button {
                        viewModel.reset()
                    } label: {
                        Label("Reset Filters", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    VStack(alignment: .leading) {
                        Group {
                            ForEach(Array(zip(FRShowOnly.allOptions.indices, FRShowOnly.allOptions)), id: \.0) { (i, option) in
                                let (option, image) = option
                                let color: Color = {
                                    if i == 0 {
                                        return Color.green
                                    } else if i == 1 {
                                        return Color.pink
                                    } else if i == 2 {
                                        return Color.orange
                                    } else {
                                        return Color.accentColor
                                    }
                                }()
                                Toggle(isOn: Binding<Bool>(get: {
                                    viewModel.showOnly.contains(FRShowOnly(rawValue: 1 << i))
                                }, set: {
                                    if $0 {
                                        viewModel.showOnly.insert(FRShowOnly(rawValue: 1 << i))
                                    } else {
                                        viewModel.showOnly.remove(FRShowOnly(rawValue: 1 << i))
                                    }
                                    print(String(describing: viewModel.showOnly))
                                })) {
                                    HStack(spacing: 2) {
                                        Image(systemName: image)
                                            .foregroundStyle(color)
                                        Text(option)
                                    }
                                }
                                .disabled(i != 0 ? true : false)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .padding(.all)
                    .padding(.top)
                    .overlay {
                        ZStack {
                            Rectangle()
                                .stroke(lineWidth: 1)
                                .foregroundStyle(Color(nsColor: NSColor.unemphasizedSelectedTextBackgroundColor))
                                .padding(.top, 8)
                            VStack {
                                HStack {
                                    Text("Show Only:")
                                        .background(Color(nsColor: NSColor.windowBackgroundColor))
                                        .padding(.leading, 5)
                                    Spacer()
                                }
                                Spacer()
                            }
                        }
                    }
                    VStack(spacing: 15) {
                        FilterSection("Type", alignment: .leading) {
                            ForEach(Array(zip(FRType.allOptions.indices, FRType.allOptions)), id: \.0) { (i, option) in
                                Toggle(option, isOn: Binding<Bool>(get: {
                                    viewModel.type.contains(FRType(rawValue: 1 << i))
                                }, set: {
                                    if $0 {
                                        viewModel.type.insert(FRType(rawValue: 1 << i))
                                    } else {
                                        viewModel.type.remove(FRType(rawValue: 1 << i))
                                    }
                                    print(String(describing: viewModel.type))
                                }))
                            }
                        }
                        FilterSection("Age Rating", alignment: .leading) {
                            ForEach(Array(zip(FRAgeRating.allOptions.indices, FRAgeRating.allOptions)), id: \.0) { (i, option) in
                                Toggle(option, isOn: Binding<Bool>(get: {
                                    viewModel.ageRating.contains(FRAgeRating(rawValue: 1 << i))
                                }, set: {
                                    if $0 {
                                        viewModel.ageRating.insert(FRAgeRating(rawValue: 1 << i))
                                    } else {
                                        viewModel.ageRating.remove(FRAgeRating(rawValue: 1 << i))
                                    }
                                    print(String(describing: viewModel.ageRating))
                                }))
                            }
                        }
                        // Source and Tags were greyed out under a `.disabled(true)` along with a
                        // Resolution section that filtered nothing; Resolution is gone (see
                        // FilterResultsViewModel.swift for why) and these two now filter.
                        // Unticking every box in either means "no restriction", not "nothing".
                        FilterSection("Source", alignment: .leading) {
                            ForEach(FRSource.options, id: \.flag.rawValue) { option in
                                Toggle(option.title, isOn: Binding<Bool>(get: {
                                    viewModel.source.contains(option.flag)
                                }, set: {
                                    if $0 {
                                        viewModel.source.insert(option.flag)
                                    } else {
                                        viewModel.source.remove(option.flag)
                                    }
                                }))
                            }
                            .toggleStyle(.checkbox)
                        }
                        FilterSection("Tags", alignment: .leading) {
                            HStack {
                                Button("All")  {
                                    viewModel.tag = .all
                                }
                                Button("None") {
                                    viewModel.tag = .none
                                }
                            }
                            .buttonStyle(.link)
                            ForEach(Array(zip(FRTag.allOptions.indices, FRTag.allOptions)), id: \.0) { (i, option) in
                                Toggle(option, isOn: Binding<Bool>(get: {
                                    viewModel.tag.contains(FRTag(rawValue: 1 << i))
                                }, set: {
                                    if $0 {
                                        viewModel.tag.insert(FRTag(rawValue: 1 << i))
                                    } else {
                                        viewModel.tag.remove(FRTag(rawValue: 1 << i))
                                    }
                                }))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .padding(.trailing)
            }
            .lineLimit(1)
        }
        Divider()
    }
}
