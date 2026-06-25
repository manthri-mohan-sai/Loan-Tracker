import SwiftUI

// MARK: - Bank Template Picker

/// Searchable sheet for selecting a bank loan template to pre-fill the loan form.
struct BankTemplatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (BankLoanTemplate) -> Void

    @State private var search = ""
    @State private var selectedCategory: LoanCategory? = nil
    @State private var selectedCountry: String? = nil

    private var filteredTemplates: [BankLoanTemplate] {
        BankTemplateStore.all.filter { t in
            if let cat = selectedCategory, t.loanType != cat { return false }
            if let country = selectedCountry, t.country != country { return false }
            if !search.isEmpty {
                let q = search.lowercased()
                return t.bankName.lowercased().contains(q)
                    || t.country.lowercased().contains(q)
                    || t.loanType.rawValue.lowercased().contains(q)
            }
            return true
        }
    }

    /// Unique countries from templates, sorted by frequency (most templates first).
    private var countries: [(code: String, name: String)] {
        let counts = Dictionary(grouping: BankTemplateStore.all, by: { $0.country })
        return counts.keys
            .sorted { (counts[$0]?.count ?? 0) > (counts[$1]?.count ?? 0) }
            .map { code in
                let name = Locale.current.localizedString(forRegionCode: code) ?? code
                return (code: code, name: name)
            }
    }

    /// Group filtered templates by country for the list display.
    private var groupedTemplates: [(country: String, templates: [BankLoanTemplate])] {
        let grouped = Dictionary(grouping: filteredTemplates, by: { $0.country })
        return grouped
            .sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
            .map { (country: $0.key, templates: $0.value.sorted { $0.bankName < $1.bankName }) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Category filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(LoanCategory.allCases) { cat in
                            FilterChip(label: cat.rawValue, isSelected: selectedCategory == cat) {
                                selectedCategory = selectedCategory == cat ? nil : cat
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Country filter
                if !search.isEmpty || selectedCountry != nil {
                    // Show as inline when filtering
                } else {
                    // Collapsible country picker
                    Section("Country") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(label: "All", isSelected: selectedCountry == nil) {
                                    selectedCountry = nil
                                }
                                ForEach(countries, id: \.code) { c in
                                    FilterChip(label: flag(c.code) + " " + c.name,
                                              isSelected: selectedCountry == c.code) {
                                        selectedCountry = selectedCountry == c.code ? nil : c.code
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }

                // Templates grouped by country
                ForEach(groupedTemplates, id: \.country) { group in
                    Section(countryName(group.country)) {
                        ForEach(group.templates) { template in
                            Button {
                                onSelect(template)
                                dismiss()
                            } label: {
                                TemplateRow(template: template)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if filteredTemplates.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search banks…")
            .navigationTitle("Bank Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func countryName(_ code: String) -> String {
        let name = Locale.current.localizedString(forRegionCode: code) ?? code
        return "\(flag(code)) \(name)"
    }

    private func flag(_ countryCode: String) -> String {
        let base: UInt32 = 127397
        return String(countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { Character($0) })
    }
}

// MARK: - Template Row

private struct TemplateRow: View {
    let template: BankLoanTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: LoanIcon(rawValue: template.loanType.iconKey)?.systemImage ?? "banknote.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text(template.bankName)
                    .fontWeight(.medium)
                Spacer()
                Text(template.loanType.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 12) {
                Label("\(formatRate(template.typicalRateMin))–\(formatRate(template.typicalRateMax))%",
                      systemImage: "percent")
                Label(template.isFloatingRate ? "Floating" : "Fixed",
                      systemImage: template.isFloatingRate ? "arrow.up.arrow.down" : "lock.fill")
                if template.prepaymentPenaltyPercent > 0 {
                    Label("\(formatRate(template.prepaymentPenaltyPercent))% penalty",
                          systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !template.notes.isEmpty {
                Text(template.notes)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatRate(_ rate: Double) -> String {
        String(format: "%.1f", rate * 100)
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
