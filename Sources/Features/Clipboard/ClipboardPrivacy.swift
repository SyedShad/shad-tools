import Foundation

enum ClipboardRetention: Int, CaseIterable, Sendable {
    case day = 1, week = 7, month = 30, threeMonths = 90, sixMonths = 180, year = 365, noAgeLimit = 0

    var title: String {
        switch self {
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        case .threeMonths: "90 days"
        case .sixMonths: "180 days"
        case .year: "365 days"
        case .noAgeLimit: "No age limit"
        }
    }

    func cutoff(at date: Date) -> Date? {
        self == .noAgeLimit ? nil : date.addingTimeInterval(-Double(rawValue) * 86_400)
    }
}

struct ClipboardExcludedApp: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ClipboardPrivacy: Equatable, Sendable {
    var retention: ClipboardRetention = .noAgeLimit
    var excludedApps: [ClipboardExcludedApp] = []

    func excludes(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return excludedApps.contains { id == $0.id || id.hasPrefix($0.id + ".") }
    }
}
