import SwiftUI
import FotoKit

/// Synology-style filter panel shown from the timeline's 필터 button. Binds to the
/// `LibraryViewModel`'s filter state; every change re-runs the (filtered) timeline.
/// File type / date / people / place(countries) are always visible; the EXIF
/// facets (camera/lens/ISO/aperture) are tucked under a collapsed "고급" section.
struct FilterPanel: View {
    @Bindable var library: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("필터").font(.headline)
                    Spacer()
                    if library.activeFilterCount > 0 {
                        Button("모두 지우기") { library.clearAllFilters() }.buttonStyle(.link)
                    }
                }

                section("파일 유형") {
                    Picker("파일 유형", selection: $library.typeFilter) {
                        ForEach(LibraryViewModel.TypeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: library.typeFilter) { apply() }
                }

                section("즐겨찾기") {
                    Toggle(isOn: $library.favoriteOnly) {
                        Label("즐겨찾기만 보기", systemImage: "heart.fill")
                    }
                    .onChange(of: library.favoriteOnly) { apply() }
                }

                section("촬영 날짜") {
                    Toggle("기간 지정", isOn: $library.dateFilterActive)
                        .onChange(of: library.dateFilterActive) { apply() }
                    if library.dateFilterActive {
                        DatePicker("시작", selection: $library.startDate, in: ...library.endDate, displayedComponents: .date)
                            .onChange(of: library.startDate) { apply() }
                        DatePicker("종료", selection: $library.endDate, in: library.startDate..., displayedComponents: .date)
                            .onChange(of: library.endDate) { apply() }
                    }
                }

                if !library.namedPeople.isEmpty {
                    disclosure("사람", count: library.selectedPersonIds.count) {
                        if library.selectedPersonIds.count > 1 {
                            Picker("조합", selection: $library.personPolicy) {
                                ForEach(LibraryViewModel.PersonPolicy.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .onChange(of: library.personPolicy) { apply() }
                        }
                        ForEach(library.namedPeople) { person in
                            checkbox(person.displayName, id: person.id, in: $library.selectedPersonIds)
                        }
                    }
                }

                if !library.countries.isEmpty {
                    disclosure("장소", count: library.selectedCountryIds.count) {
                        ForEach(library.countries) { country in
                            checkbox(country.name, id: country.id, in: $library.selectedCountryIds)
                        }
                    }
                }

                if hasExifFacets {
                    disclosure("고급", count: exifSelectedCount) {
                        facetDisclosure("카메라", library.facets.camera, $library.selectedCameraIds)
                        facetDisclosure("렌즈", library.facets.lens, $library.selectedLensIds)
                        facetDisclosure("ISO", library.facets.iso, $library.selectedIsoIds)
                        facetDisclosure("조리개", library.facets.aperture, $library.selectedApertureIds)
                    }
                }
            }
            .padding()
        }
        .frame(width: 300, height: 460)
        .task { await library.loadFiltersIfNeeded() }
    }

    private func apply() { Task { await library.applyFilters() } }

    private var hasExifFacets: Bool {
        !(library.facets.camera.isEmpty && library.facets.lens.isEmpty && library.facets.iso.isEmpty && library.facets.aperture.isEmpty)
    }
    private var exifSelectedCount: Int {
        library.selectedCameraIds.count + library.selectedLensIds.count + library.selectedIsoIds.count + library.selectedApertureIds.count
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
        Divider()
    }

    @ViewBuilder
    private func disclosure<Content: View>(_ title: String, count: Int, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) { content() }.padding(.top, 4)
        } label: {
            HStack {
                Text(title).font(.subheadline)
                if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        Divider()
    }

    @ViewBuilder
    private func facetDisclosure(_ title: String, _ options: [FotoFilterOption], _ selection: Binding<Set<Int>>) -> some View {
        if !options.isEmpty {
            disclosure(title, count: selection.wrappedValue.count) {
                ForEach(options) { opt in checkbox(opt.name, id: opt.id, in: selection) }
            }
        }
    }

    private func checkbox(_ label: String, id: Int, in selection: Binding<Set<Int>>) -> some View {
        Toggle(isOn: Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { on in
                if on { selection.wrappedValue.insert(id) } else { selection.wrappedValue.remove(id) }
                apply()
            }
        )) {
            Text(label).lineLimit(1)
        }
        .toggleStyle(.checkbox)
    }
}
