import AppKit
import SwiftUI

/// "People…": scan for faces, review the people found, name / merge / hide / delete them, and correct individual faces. Faces are
/// found and grouped on this Mac and stored only in the catalog: nothing is written to photo files, sidecars or exports.
struct PeopleSheetView: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: FacesModel
    let onDone: () -> Void

    @State private var nameText = ""
    @State private var selectedPersonNameSeen: String?
    @State private var pendingDelete: PersonSummary?
    @State private var duplicateName: (existingID: Int64, name: String)?

    /// What the name field shows after the people list changed. The field follows the stored name only while the user has not typed
    /// something else (`current == lastStored`); an edit in progress is never overwritten.
    static func refreshedNameText(current: String, lastStored: String?, stored: String?) -> String {
        current == (lastStored ?? "") ? (stored ?? "") : current
    }

    private var selectedPerson: PersonSummary? {
        if case .person(let id)? = model.selection { return model.people.first { $0.id == id } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People").font(.headline)
            Text("Faces are found and grouped on this Mac and stored only in your catalog. They are not written to your photo files, sidecars or exports. Grouping is automatic and cautious: check it, merge people who were split, and use “Not this person” on mistakes.")
                .font(.caption).foregroundStyle(Theme.textSecondary)

            scanRow
            if let summary = model.summary { Text(summary).font(.caption).foregroundStyle(Theme.textSecondary) }
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(Theme.warning) }

            HStack(alignment: .top, spacing: 14) {
                peopleList.frame(width: 250)
                Divider()
                detail.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 360)

            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(FlatButtonStyle(prominent: true))
            }
        }
        .padding(20)
        .frame(width: 780)
        .task { await model.reload() }
        .onChange(of: model.selection) { _, _ in
            nameText = selectedPerson?.name ?? ""
            selectedPersonNameSeen = selectedPerson?.name
        }
        .onChange(of: model.people) { _, _ in
            nameText = Self.refreshedNameText(current: nameText, lastStored: selectedPersonNameSeen, stored: selectedPerson?.name)
            selectedPersonNameSeen = selectedPerson?.name
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible
        ) {
            Button("Delete Person", role: .destructive) {
                if let person = pendingDelete { Task { await model.delete(person.id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its faces become unsorted and may be grouped again. Your photos are not changed.")
        }
        .alert("That name is taken", isPresented: Binding(get: { duplicateName != nil }, set: { if !$0 { duplicateName = nil } })) {
            Button("Merge Into “\(duplicateName?.name ?? "")”") {
                if let selected = selectedPerson, let existing = duplicateName?.existingID { Task { await model.merge(selected.id, into: existing) } }
                duplicateName = nil
            }
            Button("Cancel", role: .cancel) { duplicateName = nil }
        } message: {
            Text("Another person is already called that. Merge this person into them?")
        }
    }

    // MARK: Scan

    private var scanRow: some View {
        HStack {
            if model.isWorking {
                ProgressView(value: Double(model.progress?.completed ?? 0), total: Double(max(model.progress?.total ?? 1, 1)))
                    .frame(maxWidth: 220)
                Text(model.phase.isEmpty ? "\(model.progress?.completed ?? 0) of \(model.progress?.total ?? 0)" : "\(model.phase) \(model.progress?.completed ?? 0) of \(model.progress?.total ?? 0)")
                    .font(.caption).monospacedDigit()
                Button("Cancel") { model.cancel() }.buttonStyle(.flat)
            } else {
                Button(model.people.isEmpty && model.unsortedCount == 0 ? "Find Faces" : "Scan for New Faces") { catalog.beginFaceScan() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(FlatButtonStyle(prominent: true))
                Text("Scans every photo in the selected collection (or the whole Library), whatever filters are on; photos already scanned and unchanged are skipped.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: List

    private var peopleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.unsortedCount > 0 {
                    row(selection: .unsorted, title: "Unsorted faces", subtitle: "\(model.unsortedCount) face\(model.unsortedCount == 1 ? "" : "s")", crop: nil, dimmed: false)
                }
                ForEach(model.people) { person in
                    row(selection: .person(person.id), title: person.displayName + (person.isHidden ? " (hidden)" : ""),
                        subtitle: "\(person.photoCount) photo\(person.photoCount == 1 ? "" : "s")", crop: model.tileCrops[person.id], dimmed: person.isHidden)
                }
                if model.people.isEmpty && model.unsortedCount == 0 && !model.isWorking {
                    Text("No faces yet. Choose “Find Faces”.").font(.caption).foregroundStyle(Theme.textSecondary).padding(8)
                }
            }
        }
    }

    private func row(selection: FacesModel.Selection, title: String, subtitle: String, crop: Data?, dimmed: Bool) -> some View {
        let isSelected = model.selection == selection
        return HStack(spacing: 10) {
            FaceImage(data: crop, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionChip(isSelected: isSelected)
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = selection }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .person?:
            if let person = selectedPerson { personDetail(person) } else { hint }
        case .unsorted?:
            VStack(alignment: .leading, spacing: 8) {
                Text("Unsorted faces").font(.subheadline.weight(.semibold))
                Text("Faces the grouping was not sure about. Right-click a face to give it to someone.").font(.caption).foregroundStyle(Theme.textSecondary)
                faceGrid(person: nil)
            }
        case nil:
            hint
        }
    }

    private var hint: some View {
        Text("Select a person to name them or review their faces.").foregroundStyle(Theme.textSecondary)
    }

    private func personDetail(_ person: PersonSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitName(person) }
                    .accessibilityLabel("Person name")
                Button("Save Name") { commitName(person) }
                    .buttonStyle(.flat)
                    .disabled(nameText == (person.name ?? ""))
            }
            HStack {
                Button("Show Photos") {
                    catalog.personFilterID = person.id
                    onDone()
                }
                .buttonStyle(.flat)
                .help("Filter the Library to photos this person is in")
                Button(person.isHidden ? "Unhide" : "Hide") { Task { await model.setHidden(person.id, !person.isHidden) } }
                    .buttonStyle(.flat)
                    .help("A hidden person stays in the catalog but is left out of the Library's Person filter")
                Menu("Merge Into…") {
                    ForEach(model.people.filter { $0.id != person.id }) { other in
                        Button(other.displayName) { Task { await model.merge(person.id, into: other.id) } }
                    }
                }
                .disabled(model.people.count < 2)
                Button("Delete…") { pendingDelete = person }.buttonStyle(.flat)
            }
            Text("\(person.faceCount) face\(person.faceCount == 1 ? "" : "s") in \(person.photoCount) photo\(person.photoCount == 1 ? "" : "s"). Right-click a face to correct it.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            faceGrid(person: person)
        }
    }

    private func commitName(_ person: PersonSummary) {
        let typed = nameText
        Task {
            let result = await model.rename(person.id, to: typed)
            if case .duplicate(let existingID)? = result { duplicateName = (existingID, typed) }
        }
    }

    private func faceGrid(person: PersonSummary?) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                ForEach(model.selectedFaces) { face in
                    FaceImage(data: face.crop, size: 78)
                        .help(face.isConfirmed ? "Confirmed by you" : "Grouped automatically")
                        .overlay(alignment: .bottomTrailing) {
                            if face.isConfirmed { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.white).padding(3) }
                        }
                        .contextMenu { faceMenu(face, person: person) }
                        .accessibilityLabel(face.isConfirmed ? "Face, confirmed" : "Face")
                }
            }
        }
    }

    @ViewBuilder
    private func faceMenu(_ face: Face, person: PersonSummary?) -> some View {
        if let faceID = face.id {
            if let person {
                Button("Not “\(person.displayName)”") { Task { await model.notThisPerson(faceID, from: person.id) } }
                Button("Confirm This Is “\(person.displayName)”") { Task { await model.assign([faceID], to: person.id) } }
                    .disabled(face.isConfirmed)
            }
            Menu("Assign To…") {
                ForEach(model.people.filter { $0.id != person?.id }) { other in
                    Button(other.displayName) { Task { await model.assign([faceID], to: other.id) } }
                }
                Divider()
                Button("New Person") { Task { await model.assignToNewPerson([faceID]) } }
            }
        }
    }
}

/// A face crop (or a placeholder) as a rounded square.
struct FaceImage: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack { Theme.raised; Image(systemName: "person.fill").foregroundStyle(Theme.textTertiary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

/// Presents `PeopleSheetView` when the Photo menu / toolbar requests it, unless another sheet or dialog is up (`blocked`).
struct PeopleSheetModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.peopleSheetRequested) { _, requested in
                guard requested else { return }
                catalog.peopleSheetRequested = false
                if !blocked && !catalog.peopleSheetPresented {
                    catalog.faces.clear()
                    catalog.peopleSheetPresented = true
                }
            }
            .sheet(isPresented: $catalog.peopleSheetPresented, onDismiss: {
                catalog.faces.cancel()
            }) {
                PeopleSheetView(catalog: catalog, model: catalog.faces) { catalog.peopleSheetPresented = false }
            }
    }
}
