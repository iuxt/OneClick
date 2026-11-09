import Foundation
import Testing
@testable import OneClick

struct ArchiveAssociationTests {
    @Test func builtApplicationDeclaresEveryAssociableArchiveType() throws {
        let documents = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let viewerTypes = Set(documents.filter { $0["CFBundleTypeRole"] as? String == "Viewer" }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        #expect(Set(ArchiveAssociationFormat.all.map(\.typeID)).isSubset(of: viewerTypes))

        let imported = try #require(Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]])
        for format in ArchiveAssociationFormat.all where format.id != "ZIP" {
            let declaration = try #require(imported.first { $0["UTTypeIdentifier"] as? String == format.typeID })
            let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
            #expect((tags["public.filename-extension"] as? [String])?.contains(format.id.lowercased()) == true)
        }
    }
}
