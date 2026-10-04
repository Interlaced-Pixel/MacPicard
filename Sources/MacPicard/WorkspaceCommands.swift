import Foundation

/// One source of action availability for menus, toolbar and context actions.
enum WorkspaceAction {
    case edit, lookup, script, save, discard, organize
}

enum WorkspaceScope {
    case selection
    case items(Set<UUID>)
    case library
}

extension AppModel {
    func commandFileIDs(_ scope: WorkspaceScope) -> Set<UUID> {
        switch scope {
        case .selection: selectedFileIDs
        case let .items(ids): ids
        case .library: activeWorkspace?.kind == .library ? Set(files.map(\.id)) : []
        }
    }

    func canPerform(_ action: WorkspaceAction, scope: WorkspaceScope = .selection) -> Bool {
        let ids = commandFileIDs(scope)
        switch action {
        case .edit, .script: return canEdit(ids)
        case .organize: return !isBusy && !contextFiles(ids).isEmpty
        case .lookup: return canLookUp(ids)
        case .save: return canEdit(ids) && contextFiles(ids).contains(where: \.isModified)
        case .discard: return canDiscardChanges(ids)
        }
    }
}
