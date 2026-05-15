import Foundation
import SwiftData

/// SwiftData wrapper around a `Project`. The full project is stored as a
/// JSON blob in `data`; lighter `id`, `name`, and `modifiedAt` columns live
/// alongside for sorting / lookup without decoding the blob.
///
/// CloudKit compatibility requirements: every property has a default value,
/// no unique constraints (CloudKit uses its own record IDs), no required
/// relationships. Sync happens automatically when the model container is
/// configured with a CloudKit database.
@Model
final class ProjectRecord {
    var id: UUID = UUID()
    var name: String = ""
    var modifiedAt: Date = Date.distantPast
    var data: Data = Data()

    init(
        id: UUID = UUID(),
        name: String = "",
        modifiedAt: Date = .now,
        data: Data = Data()
    ) {
        self.id = id
        self.name = name
        self.modifiedAt = modifiedAt
        self.data = data
    }
}
