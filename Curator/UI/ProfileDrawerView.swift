import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

struct ProfileDrawerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @Binding var appearance: AppAppearance
    let onAddProfile: () -> Void

    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTargetID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section("Profiles") {
                    if model.profiles.isEmpty {
                        ContentUnavailableView(
                            "No Profiles",
                            systemImage: "person.crop.circle.badge.plus",
                            description: Text("Import an archive to create your first profile.")
                        )
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.profiles) { profile in
                            profileRow(profile)
                        }
                    }

                    Button {
                        onAddProfile()
                        dismiss()
                    } label: {
                        Label("Add Profile", systemImage: "plus.circle.fill")
                    }
                    .disabled(model.isImporting || model.isInspectingArchive)
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Appearance")
                }
            }
            .navigationTitle("Profiles")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .alert("Rename Profile", isPresented: renameAlertIsPresented) {
            TextField("Profile name", text: $renameText)
                .textInputAutocapitalization(.words)

            Button("Cancel", role: .cancel) {
                renameTargetID = nil
            }

            Button("Save") {
                guard let renameTargetID else { return }
                Task {
                    if await model.renameProfile(
                        profileID: renameTargetID,
                        to: renameText
                    ) {
                        self.renameTargetID = nil
                    }
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete Profile?", isPresented: deleteAlertIsPresented) {
            Button("Cancel", role: .cancel) {
                deleteTargetID = nil
            }

            Button("Delete", role: .destructive) {
                guard let deleteTargetID else { return }
                Task {
                    if await model.deleteProfile(profileID: deleteTargetID) {
                        self.deleteTargetID = nil
                    }
                }
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private func profileRow(_ profile: VaultProfile) -> some View {
        HStack(spacing: 12) {
            Button {
                model.selectProfile(profile.id)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    ProfileAvatar(
                        profile: profile,
                        photo: model.latestProfilePhoto(for: profile.id),
                        size: 48
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .foregroundStyle(.primary)

                        Text(profileDetail(profile))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if model.selectedProfileID == profile.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Selected")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Rename", systemImage: "pencil") {
                    beginRenaming(profile)
                }
                .disabled(model.isImporting)

                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleteTargetID = profile.id
                }
                .disabled(model.isImporting)
            } label: {
                Label("Edit \(profile.name)", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteTargetID = profile.id
            }
            .disabled(model.isImporting)

            Button("Rename", systemImage: "pencil") {
                beginRenaming(profile)
            }
            .tint(.blue)
            .disabled(model.isImporting)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                beginRenaming(profile)
            }
            .disabled(model.isImporting)

            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteTargetID = profile.id
            }
            .disabled(model.isImporting)
        }
    }

    private var renameAlertIsPresented: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { isPresented in
                if !isPresented {
                    renameTargetID = nil
                }
            }
        )
    }

    private var deleteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { deleteTargetID != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTargetID = nil
                }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        guard let deleteTargetID,
              let profile = model.profile(withID: deleteTargetID)
        else {
            return "This permanently removes the profile and its imported media."
        }
        return "This permanently removes \(profile.name) and all of its imported media."
    }

    private func beginRenaming(_ profile: VaultProfile) {
        renameText = profile.name
        renameTargetID = profile.id
    }

    private func profileDetail(_ profile: VaultProfile) -> String {
        let itemLabel = profile.itemCount == 1 ? "item" : "items"
        if let filename = profile.latestArchiveFilename {
            return "\(profile.itemCount.formatted()) \(itemLabel) · \(filename)"
        }
        return "\(profile.itemCount.formatted()) \(itemLabel)"
    }
}

struct ProfileAvatar: View {
    let profile: VaultProfile?
    let photo: MediaRecord?
    let size: CGFloat

    var body: some View {
        Group {
            if let photo {
                ThumbnailImage(
                    url: AppPaths().vault(for: photo.profileID)
                        .appending(path: photo.mediaPath),
                    maxPixelSize: Int(size * 3),
                    contentMode: .fill
                )
            } else if let profile {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.gradient)

                    Text(initials(for: profile.name))
                        .bold()
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemBackground))

                    Image(systemName: "person.fill")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(Circle())
        .accessibilityHidden(true)
    }

    private func initials(for name: String) -> String {
        let components = name.split(whereSeparator: \.isWhitespace)
        return components.prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}
