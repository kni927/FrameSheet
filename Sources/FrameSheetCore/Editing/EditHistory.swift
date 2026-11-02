import Foundation

/// Undo and redo of library and sheet edits (§3): up to 50 snapshots of the
/// library, not persisted. Global settings are not part of an edit; undo and
/// redo keep the settings that are current.
public struct EditHistory: Sendable {
    public static let limit = 50

    public private(set) var undoStack: [Library] = []
    public private(set) var redoStack: [Library] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call with the library as it was before an edit.
    public mutating func record(_ before: Library) {
        undoStack.append(before)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
    }

    public mutating func undo(_ current: Library) -> Library? {
        guard var previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        previous.settings = current.settings
        return previous
    }

    public mutating func redo(_ current: Library) -> Library? {
        guard var next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        next.settings = current.settings
        return next
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

/// A library with its edit history: every user-visible edit goes through
/// `edit`, which records an undo step only when the library changed.
public struct EditableLibrary: Sendable {
    public private(set) var library: Library
    public private(set) var history = EditHistory()

    public init(_ library: Library) {
        self.library = library
    }

    @discardableResult
    public mutating func edit<T>(_ change: (inout Library) throws -> T) rethrows -> T {
        let before = library
        let result = try change(&library)
        if library != before { history.record(before) }
        return result
    }

    /// Changes that are not undoable: selection and global settings.
    public mutating func update(_ change: (inout Library) -> Void) {
        change(&library)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = history.undo(library) else { return false }
        library = previous
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = history.redo(library) else { return false }
        library = next
        return true
    }

    /// Replaces the library without an undo step (e.g. after loading).
    public mutating func reset(_ library: Library) {
        self.library = library
        history.clear()
    }
}
