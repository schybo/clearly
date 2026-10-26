import Foundation

enum WiskNoteSortMode: String, CaseIterable, Identifiable {
    case modifiedNewest
    case modifiedOldest
    case createdNewest
    case createdOldest
    case titleAscending
    case titleDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modifiedNewest: return "Modified: Newest"
        case .modifiedOldest: return "Modified: Oldest"
        case .createdNewest: return "Created: Newest"
        case .createdOldest: return "Created: Oldest"
        case .titleAscending: return "Name: A-Z"
        case .titleDescending: return "Name: Z-A"
        }
    }

    var shortTitle: String {
        switch self {
        case .modifiedNewest: return "Newest"
        case .modifiedOldest: return "Oldest"
        case .createdNewest: return "Created"
        case .createdOldest: return "Created Oldest"
        case .titleAscending: return "A-Z"
        case .titleDescending: return "Z-A"
        }
    }
}

enum WiskNotesScope: Hashable, Identifiable {
    case all
    case archive
    case trash
    case untagged
    case tag(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .archive: return "archive"
        case .trash: return "trash"
        case .untagged: return "untagged"
        case .tag(let tag): return "tag:\(tag)"
        }
    }

    var title: String {
        switch self {
        case .all: return "All Notes"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .untagged: return "Untagged"
        case .tag(let tag): return tag
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "note.text"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .untagged: return "tag.slash"
        case .tag: return "tag"
        }
    }
}
