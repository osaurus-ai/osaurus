//
//  ModelSearchablePicker.swift
//  osaurus
//
//  A model chosen in a settings form: `SettingsSearchablePicker` over
//  picker-catalog models, grouped by where they run. A stored model that is
//  no longer offered shows as "(unavailable)" in the warning tone.
//

import SwiftUI

struct ModelSearchablePicker: View {
    let items: [ModelPickerItem]
    @Binding var selection: String?
    /// The nil choice ("Default model"). Already localized.
    let noneTitle: String
    /// The id a model is stored under. Nil leaves the model out.
    var rowID: (ModelPickerItem) -> String? = { $0.id }
    /// The field's text for a stored id. Defaults to the model's name.
    var label: ((String) -> String)? = nil
    var style: SettingsSearchablePicker.Style = .field
    var icon: String? = "cube"
    var actions: [SettingsSearchablePicker.Action] = []

    private var options: [SettingsSearchablePicker.Option] {
        items.filter(\.isMLXFormat).compactMap { item in
            rowID(item).map { Self.option(item, id: $0) }
        }
    }

    var body: some View {
        let options = options
        let current = selection.flatMap { id in options.first { $0.id == id } }
        SettingsSearchablePicker(
            options: options,
            selection: $selection,
            label: selection.map { id in label?(id) ?? current?.title ?? L("\(id) (unavailable)") } ?? noneTitle,
            icon: icon,
            noneTitle: noneTitle,
            searchPlaceholder: "Search models",
            isInvalid: selection != nil && current == nil,
            style: style,
            actions: actions
        )
    }

    static func option(_ item: ModelPickerItem, id: String? = nil) -> SettingsSearchablePicker.Option {
        let group: String
        switch item.source {
        case .foundation, .local, .imageGeneration: group = L("On this Mac")
        case .remote(let providerName, _): group = providerName
        }
        return SettingsSearchablePicker.Option(id: id ?? item.id, title: item.displayName, group: group, keywords: item.id)
    }
}

extension Binding where Value == String {
    /// "" as nil, for stored model ids where empty means "use the default".
    var emptyAsNil: Binding<String?> {
        Binding<String?>(get: { wrappedValue.isEmpty ? nil : wrappedValue }, set: { wrappedValue = $0 ?? "" })
    }
}
