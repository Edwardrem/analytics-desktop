import Foundation

/// Preview features of the engine, which the app turns on or off (Settings ▸ Preview). An engine takes the
/// current values when it is created; set `features` on an engine to override them.
public struct DAXFeatures: Sendable, Equatable {
    /// Time intelligence functions accept a calendar's name (defined on a table) in place of a date column.
    public var calendarTimeIntelligence = true
    /// TEXTSEARCH, answered from a word index of the column's text.
    public var textSearch = true
    /// Calculated columns and tables see the View-as user (USERNAME() and friends). When off they are
    /// computed as at refresh, with no View-as identity, and only queries see that user.
    public var userContextColumns = true

    public init(calendarTimeIntelligence: Bool = true, textSearch: Bool = true, userContextColumns: Bool = true) {
        self.calendarTimeIntelligence = calendarTimeIntelligence
        self.textSearch = textSearch
        self.userContextColumns = userContextColumns
    }

    private static let lock = NSLock()
    private static var stored = DAXFeatures()
    /// What new engines start with.
    public static var current: DAXFeatures {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
