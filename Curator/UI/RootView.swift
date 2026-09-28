import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system
    @State private var showFileImporter = false
    @State private var showProfileDrawer = false
    @State private var importAfterClosingProfileDrawer = false
    @State private var importName = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoadingProfiles {
                    ProgressView()
                } else if model.isImporting {
                    ImportingArchiveView(
                        profileName: model.importingProfileName,
                        snapshot: model.importSnapshot,
                        onCancel: model.cancelImport,
                        selectedProfile: model.selectedProfile,
                        selectedPhoto: model.selectedProfileID.flatMap(
                            model.latestProfilePhoto(for:)
                        ),
                        onProfileTap: { showProfileDrawer = true }
                    )
                } else if model.profiles.isEmpty {
                    EmptyArchiveView(
                        isInspectingArchive: model.isInspectingArchive,
                        onImport: { showFileImporter = true },
                        onProfileTap: { showProfileDrawer = true }
                    )
                } else if let profile = model.selectedProfile {
                    ProfileArchiveScreen(
                        model: model,
                        profile: profile,
                        onProfileTap: { showProfileDrawer = true }
                    )
                        .id(profile.id)
                } else {
                    ContentUnavailableView(
                        "Profile unavailable",
                        systemImage: "person.crop.circle.badge.xmark"
                    )
                    .toolbar {
                        StickyInlineLargeTitle("Curator")
                    }
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .task { await model.loadProfiles() }
        .fullScreenCover(
            isPresented: $showProfileDrawer,
            onDismiss: {
                guard importAfterClosingProfileDrawer else { return }
                importAfterClosingProfileDrawer = false
                Task { @MainActor in
                    await Task.yield()
                    showFileImporter = true
                }
            }
        ) {
            ProfileDrawerView(
                model: model,
                appearance: $appearance,
                onAddProfile: {
                    importAfterClosingProfileDrawer = true
                }
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.inspectArchive(from: url)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: model.pendingImport?.id) { _, _ in
            if let proposal = model.pendingImport {
                importName = proposal.suggestedName
            }
        }
        .alert(
            "Name this profile",
            isPresented: pendingImportAlertIsPresented
        ) {
            TextField("Profile name", text: $importName)
                .textInputAutocapitalization(.words)

            Button("Cancel", role: .cancel) {
                model.cancelPendingImport()
            }

            Button("Done") {
                guard let proposal = model.pendingImport else { return }
                model.createProfile(from: proposal, name: importName)
            }
            .disabled(importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Curator couldn’t complete that", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var pendingImportAlertIsPresented: Binding<Bool> {
        Binding(
            get: { model.pendingImport != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelPendingImport()
                }
            }
        )
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }
}

private struct EmptyArchiveView: View {
    let isInspectingArchive: Bool
    let onImport: () -> Void
    let onProfileTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Spacer()

            if isInspectingArchive {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Checking archive")
            } else {
                Text("No Archives")
                    .foregroundStyle(.secondary)

                Text("Start by importing an archive")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button(action: onImport) {
                Text("Import Archive")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 36)
                .padding(.bottom, 8)
                .disabled(isInspectingArchive)
        }
        .toolbar {
            StickyInlineLargeTitle("Curator")

            ProfileToolbarItem(
                profile: nil,
                photo: nil,
                action: onProfileTap
            )
        }
    }
}

private struct ImportingArchiveView: View {
    let profileName: String?
    let snapshot: ImportSnapshot?
    let onCancel: () -> Void
    let selectedProfile: VaultProfile?
    let selectedPhoto: MediaRecord?
    let onProfileTap: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(spacing: 4) {
                Text("Importing Archive")

                Text("organizing \(profileName ?? "archive")")
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            ProgressView(value: snapshot?.fraction ?? 0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 142)
                .accessibilityValue(snapshot.map {
                    "\((Int($0.fraction * 100)).formatted()) percent"
                } ?? "Starting")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive, action: onCancel) {
                Text("Cancel Import")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .padding(.horizontal, 36)
                .padding(.bottom, 8)
        }
        .toolbar {
            StickyInlineLargeTitle("Curator")

            ProfileToolbarItem(action: onProfileTap)
        }
    }
}

private struct ProfileArchiveScreen: View {
    @Bindable var model: AppModel
    let profile: VaultProfile
    let onProfileTap: () -> Void

    @State private var selectedTab: ArchiveTab = .feed
    @State private var displayState: ProfileMediaDisplayState
    @State private var menuSelection: MediaMenuSelection
    @State private var preferenceSaveTask: Task<Void, Never>?

    init(
        model: AppModel,
        profile: VaultProfile,
        onProfileTap: @escaping () -> Void
    ) {
        self.model = model
        self.profile = profile
        self.onProfileTap = onProfileTap
        let preferences = model.mediaPreferences(for: profile.id)
        _displayState = State(initialValue: ProfileMediaDisplayState(preferences: preferences))
        _menuSelection = State(initialValue: MediaMenuSelection(preferences))
    }

    var body: some View {
        Group {
            if let items = model.itemsByProfileID[profile.id] {
                ProfileArchiveContent(
                    items: items,
                    itemsRevision: profile.updatedAt,
                    displayState: displayState,
                    selectedTab: $selectedTab
                )
            } else {
                ProgressView()
            }
        }
        .toolbar {
            profileToolbar
        }
        .task(id: profile.id) {
            if model.itemsByProfileID[profile.id] == nil {
                await model.loadItems(for: profile.id)
            }
        }
    }

    @ToolbarContentBuilder
    private var profileToolbar: some ToolbarContent {
        StickyInlineLargeTitle(profile.name)

        ToolbarItem(placement: .topBarTrailing) {
            feedOptionsMenu
        }

        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        ToolbarItem(placement: .topBarTrailing) {
            ProfileButton(
                profile: profile,
                photo: model.latestProfilePhoto(for: profile.id),
                action: onProfileTap
            )
        }
    }

    private var feedOptionsMenu: some View {
        NativeFeedOptionsButton(
            sortOrder: displayState.sortOrder,
            selection: menuSelection,
            onSortOrderChange: { displayState.sortOrder = $0 },
            onPreferencesChange: updatePreferences
        )
        .fixedSize()
    }

    private func updatePreferences(_ preferences: MediaPreferences) {
        displayState.preferences = preferences
        model.rememberMediaPreferences(preferences, for: profile.id)
        preferenceSaveTask?.cancel()
        preferenceSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            _ = await model.updateMediaPreferences(
                profileID: profile.id,
                preferences: preferences
            )
        }
    }
}

private struct ProfileArchiveContent: View {
    let items: [MediaRecord]
    let itemsRevision: Date
    let displayState: ProfileMediaDisplayState
    @Binding var selectedTab: ArchiveTab

    @State private var visibleItems: [MediaRecord] = []
    @State private var hasResolvedQuery = false

    var body: some View {
        Group {
            if !hasResolvedQuery {
                ProgressView()
            } else if !items.isEmpty, visibleItems.isEmpty {
                ContentUnavailableView {
                    Label("No media selected", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Use View Options to turn on at least one media category.")
                }
            } else {
                archiveTabs
            }
        }
        .task(id: query) {
            await resolveVisibleItems()
        }
    }

    private var archiveTabs: some View {
        TabView(selection: $selectedTab) {
            ArchiveFeedView(
                items: visibleItems,
                mediaURL: mediaURL(for:)
            )
            .tabItem {
                Label("Feed", systemImage: "rectangle.stack.fill")
            }
            .tag(ArchiveTab.feed)

            ArchiveView(
                items: visibleItems,
                mediaURL: mediaURL(for:),
                thumbnailURL: thumbnailURL(for:)
            )
            .tabItem {
                Label("Grid", systemImage: "rectangle.grid.3x2.fill")
            }
            .tag(ArchiveTab.grid)
        }
    }

    private var query: MediaQuery {
        MediaQuery(
            itemsRevision: itemsRevision,
            sortOrder: displayState.sortOrder,
            visibleContentKinds: displayState.preferences.visibleContentKinds
        )
    }

    private func resolveVisibleItems() async {
        let sourceItems = items
        let preferences = displayState.preferences
        let sortOrder = displayState.sortOrder
        let worker = Task.detached(priority: .userInitiated) {
            let filtered = sourceItems.filter(preferences.includes)
            guard !Task.isCancelled else { return [MediaRecord]() }
            return sortOrder.sorted(filtered)
        }
        let resolved = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        visibleItems = resolved
        hasResolvedQuery = true
    }

    private func mediaURL(for item: MediaRecord) -> URL {
        AppPaths().vault(for: item.profileID).appending(path: item.mediaPath)
    }

    private func thumbnailURL(for itemID: String) -> URL {
        AppPaths().thumbnail(for: itemID)
    }
}

private struct MediaQuery: Hashable {
    let itemsRevision: Date
    let sortOrder: FeedSortOrder
    let visibleContentKinds: Set<ContentKind>
}

private struct ProfileToolbarItem: ToolbarContent {
    let profile: VaultProfile?
    let photo: MediaRecord?
    let action: () -> Void

    init(
        profile: VaultProfile? = nil,
        photo: MediaRecord? = nil,
        action: @escaping () -> Void
    ) {
        self.profile = profile
        self.photo = photo
        self.action = action
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ProfileButton(
                profile: profile,
                photo: photo,
                action: action
            )
        }
    }
}

private struct StickyInlineLargeTitle: ToolbarContent {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(title)
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct ProfileButton: View {
    let profile: VaultProfile?
    let photo: MediaRecord?
    let action: () -> Void

    var body: some View {
        Button("Profiles", systemImage: "person.crop.circle", action: action)
        .labelStyle(.iconOnly)
        .accessibilityHint("Opens profiles and appearance settings")
    }
}

private enum ArchiveTab: Hashable {
    case feed
    case grid
}

enum MediaFilterCategory: String, CaseIterable, Identifiable {
    case stories
    case posts
    case reels
    case profilePhotos
    case otherMedia

    var id: Self { self }

    static func category(for contentKind: ContentKind) -> Self {
        switch contentKind {
        case .story:
            .stories
        case .post, .archivedPost:
            .posts
        case .reel:
            .reels
        case .profilePhoto:
            .profilePhotos
        case .other, .recovered:
            .otherMedia
        }
    }

    var contentKinds: Set<ContentKind> {
        switch self {
        case .stories:
            [.story]
        case .posts:
            [.post, .archivedPost]
        case .reels:
            [.reel]
        case .profilePhotos:
            [.profilePhoto]
        case .otherMedia:
            [.other, .recovered]
        }
    }

    var displayName: String {
        switch self {
        case .stories: "Stories"
        case .posts: "Posts"
        case .reels: "Reels"
        case .profilePhotos: "Profile Photos"
        case .otherMedia: "Other Media"
        }
    }

    var systemImage: String {
        switch self {
        case .stories: "circle.dashed"
        case .posts: "rectangle.grid.3x1.fill"
        case .reels: "play.square.fill"
        case .profilePhotos: "person.crop.circle.fill"
        case .otherMedia: "shippingbox.fill"
        }
    }
}

@MainActor
@Observable
private final class ProfileMediaDisplayState {
    var preferences: MediaPreferences
    var sortOrder: FeedSortOrder

    init(
        preferences: MediaPreferences,
        sortOrder: FeedSortOrder = .newestFirst
    ) {
        self.preferences = preferences
        self.sortOrder = sortOrder
    }
}

private final class MediaMenuSelection {
    private var preferences: MediaPreferences

    init(_ preferences: MediaPreferences) {
        self.preferences = preferences
    }

    func contains(_ category: MediaFilterCategory) -> Bool {
        category.contentKinds.isSubset(of: preferences.visibleContentKinds)
    }

    func set(_ category: MediaFilterCategory, isVisible: Bool) -> MediaPreferences {
        if isVisible {
            preferences.visibleContentKinds.formUnion(category.contentKinds)
        } else {
            preferences.visibleContentKinds.subtract(category.contentKinds)
        }
        return preferences
    }
}

private struct NativeFeedOptionsButton: UIViewRepresentable {
    let sortOrder: FeedSortOrder
    let selection: MediaMenuSelection
    let onSortOrderChange: (FeedSortOrder) -> Void
    let onPreferencesChange: (MediaPreferences) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sortOrder: sortOrder,
            selection: selection,
            onSortOrderChange: onSortOrderChange,
            onPreferencesChange: onPreferencesChange
        )
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: "line.3.horizontal.decrease"),
            for: .normal
        )
        button.tintColor = .label
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Sort and view options"
        context.coordinator.installMenu(on: button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.update(
            sortOrder: sortOrder,
            onSortOrderChange: onSortOrderChange,
            onPreferencesChange: onPreferencesChange
        )
    }

    @MainActor
    final class Coordinator {
        private var sortOrder: FeedSortOrder
        private let selection: MediaMenuSelection
        private var onSortOrderChange: (FeedSortOrder) -> Void
        private var onPreferencesChange: (MediaPreferences) -> Void
        private var sortActions: [FeedSortOrder: UIAction] = [:]

        init(
            sortOrder: FeedSortOrder,
            selection: MediaMenuSelection,
            onSortOrderChange: @escaping (FeedSortOrder) -> Void,
            onPreferencesChange: @escaping (MediaPreferences) -> Void
        ) {
            self.sortOrder = sortOrder
            self.selection = selection
            self.onSortOrderChange = onSortOrderChange
            self.onPreferencesChange = onPreferencesChange
        }

        func update(
            sortOrder: FeedSortOrder,
            onSortOrderChange: @escaping (FeedSortOrder) -> Void,
            onPreferencesChange: @escaping (MediaPreferences) -> Void
        ) {
            self.sortOrder = sortOrder
            self.onSortOrderChange = onSortOrderChange
            self.onPreferencesChange = onPreferencesChange
            updateSortActionStates()
        }

        func installMenu(on button: UIButton) {
            let sortItems = FeedSortOrder.allCases.map { order in
                let action = UIAction(
                    title: order.displayName,
                    state: order == sortOrder ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.sortOrder = order
                    self.updateSortActionStates()
                    self.onSortOrderChange(order)
                }
                sortActions[order] = action
                return action
            }

            let viewItems = MediaFilterCategory.allCases.map { category in
                UIAction(
                    title: category.displayName,
                    image: UIImage(systemName: category.systemImage),
                    attributes: [.keepsMenuPresented],
                    state: selection.contains(category) ? .on : .off
                ) { [weak self] action in
                    guard let self else { return }
                    let isVisible = action.state == .on
                    let preferences = self.selection.set(
                        category,
                        isVisible: isVisible
                    )
                    self.onPreferencesChange(preferences)
                }
            }

            let sortMenu = UIMenu(
                options: [.displayInline, .singleSelection],
                children: sortItems
            )
            let viewMenu = UIMenu(title: "View Options", children: viewItems)
            button.menu = UIMenu(children: [sortMenu, viewMenu])
        }

        private func updateSortActionStates() {
            for (order, action) in sortActions {
                action.state = order == sortOrder ? .on : .off
            }
        }
    }
}
