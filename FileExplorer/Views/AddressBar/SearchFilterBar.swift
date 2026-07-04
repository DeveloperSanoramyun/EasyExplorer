//
//  SearchFilterBar.swift
//  FileExplorer
//
//  Three Menu chips (Kind / Size / Date) that narrow the visible file
//  list — independent of whether a search is active, since
//  `TabViewModel.visibleItems` applies these to the plain folder
//  listing too. Shown while searching, while a filter is set, or while
//  the user has manually opened it via AddressBar's funnel button
//  (`filterBarVisible`) — collapses back to zero height otherwise so it
//  doesn't permanently consume chrome for a feature most folders won't
//  need.
//

import SwiftUI

struct SearchFilterBar: View {
    @ObservedObject var tab: TabViewModel

    var body: some View {
        if !tab.searchQuery.isEmpty || tab.hasActiveSearchFilter || tab.filterBarVisible {
            HStack(spacing: 6) {
                Text("Filter:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                chip(
                    label: tab.searchKindFilter.rawValue,
                    isActive: tab.searchKindFilter != .all,
                    icon: "tag"
                ) {
                    ForEach(TabViewModel.KindFilter.allCases) { kind in
                        Button {
                            tab.searchKindFilter = kind
                        } label: {
                            if kind == tab.searchKindFilter {
                                Label(kind.rawValue, systemImage: "checkmark")
                            } else {
                                Text(kind.rawValue)
                            }
                        }
                    }
                }

                chip(
                    label: tab.searchSizeFilter.rawValue,
                    isActive: tab.searchSizeFilter != .all,
                    icon: "scalemass"
                ) {
                    ForEach(TabViewModel.SizeFilter.allCases) { size in
                        Button {
                            tab.searchSizeFilter = size
                        } label: {
                            if size == tab.searchSizeFilter {
                                Label(size.rawValue, systemImage: "checkmark")
                            } else {
                                Text(size.rawValue)
                            }
                        }
                    }
                }

                chip(
                    label: tab.searchDateFilter.rawValue,
                    isActive: tab.searchDateFilter != .all,
                    icon: "calendar"
                ) {
                    ForEach(TabViewModel.DateFilter.allCases) { date in
                        Button {
                            tab.searchDateFilter = date
                        } label: {
                            if date == tab.searchDateFilter {
                                Label(date.rawValue, systemImage: "checkmark")
                            } else {
                                Text(date.rawValue)
                            }
                        }
                    }
                }

                if tab.hasActiveSearchFilter {
                    Button {
                        tab.resetSearchFilters()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear all filters")
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    /// Pill-shaped Menu trigger. Active state (something other than
    /// "All / Any …" picked) shows accent-coloured fill so the user
    /// can see at a glance which filters are narrowing the list.
    @ViewBuilder
    private func chip<Content: View>(
        label: String,
        isActive: Bool,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .feFont(size: 10)
                Text(label)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .feFont(size: 8, weight: .bold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isActive ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2),
                            lineWidth: 0.5)
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
