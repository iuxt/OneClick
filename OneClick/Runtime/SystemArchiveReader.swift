import Darwin
import Foundation

/// The system libarchive is used for TAR filters and the other libarchive formats
/// already supported by extraction. Resolve its stable C API without a Homebrew dependency.
nonisolated private struct SystemArchiveAPI: @unchecked Sendable {
    static let shared = try? SystemArchiveAPI()
    let create: @convention(c) () -> OpaquePointer?
    let filters: @convention(c) (OpaquePointer) -> Int32
    let formats: @convention(c) (OpaquePointer) -> Int32
    let open: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int) -> Int32
    let next: @convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    let pathname: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let size: @convention(c) (OpaquePointer) -> Int64
    let filetype: @convention(c) (OpaquePointer) -> UInt32
    let hardlink: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let mtimeIsSet: @convention(c) (OpaquePointer) -> Int32
    let mtime: @convention(c) (OpaquePointer) -> Int
    let mtimeNanoseconds: @convention(c) (OpaquePointer) -> Int
    let birthtimeIsSet: @convention(c) (OpaquePointer) -> Int32
    let birthtime: @convention(c) (OpaquePointer) -> Int
    let birthtimeNanoseconds: @convention(c) (OpaquePointer) -> Int
    let read: @convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int
    let skip: @convention(c) (OpaquePointer) -> Int32
    let error: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let free: @convention(c) (OpaquePointer) -> Int32

    init() throws {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw ArchiveError.toolUnavailable }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw ArchiveError.toolUnavailable }
            return unsafeBitCast(address, to: type)
        }
        // Keep the library loaded for the lifetime of these function pointers.
        create = try symbol("archive_read_new", as: type(of: create))
        filters = try symbol("archive_read_support_filter_all", as: type(of: filters))
        formats = try symbol("archive_read_support_format_all", as: type(of: formats))
        open = try symbol("archive_read_open_filename", as: type(of: open))
        next = try symbol("archive_read_next_header", as: type(of: next))
        pathname = try symbol("archive_entry_pathname_utf8", as: type(of: pathname))
        size = try symbol("archive_entry_size", as: type(of: size))
        filetype = try symbol("archive_entry_filetype", as: type(of: filetype))
        hardlink = try symbol("archive_entry_hardlink", as: type(of: hardlink))
        mtimeIsSet = try symbol("archive_entry_mtime_is_set", as: type(of: mtimeIsSet))
        mtime = try symbol("archive_entry_mtime", as: type(of: mtime))
        mtimeNanoseconds = try symbol("archive_entry_mtime_nsec", as: type(of: mtimeNanoseconds))
        birthtimeIsSet = try symbol("archive_entry_birthtime_is_set", as: type(of: birthtimeIsSet))
        birthtime = try symbol("archive_entry_birthtime", as: type(of: birthtime))
        birthtimeNanoseconds = try symbol("archive_entry_birthtime_nsec", as: type(of: birthtimeNanoseconds))
        read = try symbol("archive_read_data", as: type(of: read))
        skip = try symbol("archive_read_data_skip", as: type(of: skip))
        error = try symbol("archive_error_string", as: type(of: error))
        free = try symbol("archive_read_free", as: type(of: free))
    }
}

nonisolated enum SystemArchiveReader {
    private static func withReader<T>(url: URL, work: (SystemArchiveAPI, OpaquePointer) throws -> T) throws -> T {
        guard let api = SystemArchiveAPI.shared, let reader = api.create() else { throw ArchiveError.toolUnavailable }
        defer { _ = api.free(reader) }
        _ = api.filters(reader)
        _ = api.formats(reader)
        guard api.open(reader, url.path, 32_768) == 0 else { throw failure(api, reader) }
        return try work(api, reader)
    }

    private static func failure(_ api: SystemArchiveAPI, _ reader: OpaquePointer) -> ArchiveError {
        .failed(api.error(reader).map { String(cString: $0) } ?? "libarchive")
    }

    static func list(_ url: URL) throws -> [ArchiveEntry] {
        try withReader(url: url) { api, reader in
            var entries: [ArchiveEntry] = []
            var pathBytes = 0
            var entry: OpaquePointer?
            while true {
                try Task.checkCancellation()
                let status = api.next(reader, &entry)
                if status == 1 { break } // ARCHIVE_EOF
                guard status == 0, let entry, let path = api.pathname(entry) else { throw failure(api, reader) }
                let name = String(cString: path)
                pathBytes += name.utf8.count
                guard entries.count < 100_000, pathBytes <= 32 * 1_024 * 1_024 else { throw ArchiveBrowserError.listingTooLarge }
                let type = api.filetype(entry)
                let modified = api.mtimeIsSet(entry) != 0
                    ? Date(timeIntervalSince1970: Double(api.mtime(entry)) + Double(api.mtimeNanoseconds(entry)) / 1_000_000_000) : nil
                let created = api.birthtimeIsSet(entry) != 0
                    ? Date(timeIntervalSince1970: Double(api.birthtime(entry)) + Double(api.birthtimeNanoseconds(entry)) / 1_000_000_000) : nil
                entries.append(ArchiveEntry(path: name, size: max(0, api.size(entry)),
                                            isDirectory: type == 0o040000,
                                            isLink: type != 0o040000 && type != 0o100000 || api.hardlink(entry) != nil,
                                            modifiedDate: modified, createdDate: created))
                guard api.skip(reader) >= 0 else { throw failure(api, reader) }
            }
            return entries
        }
    }

    static func read(_ url: URL, entry selected: ArchiveEntry, limit: Int) throws -> Data {
        try withReader(url: url) { api, reader in
            var entry: OpaquePointer?
            while true {
                try Task.checkCancellation()
                let status = api.next(reader, &entry)
                if status == 1 { throw ArchiveBrowserError.entryUnavailable }
                guard status == 0, let entry, let path = api.pathname(entry) else { throw failure(api, reader) }
                guard String(cString: path) == selected.path else {
                    guard api.skip(reader) >= 0 else { throw failure(api, reader) }
                    continue
                }
                guard api.filetype(entry) == 0o100000, api.hardlink(entry) == nil else { throw ArchiveBrowserError.entryUnavailable }
                guard api.size(entry) <= limit else { throw ArchiveBrowserError.previewTooLarge }
                var output = Data()
                var buffer = [UInt8](repeating: 0, count: 32_768)
                while true {
                    try Task.checkCancellation()
                    let count = api.read(reader, &buffer, buffer.count)
                    if count == 0 { return output }
                    guard count > 0 else { throw failure(api, reader) }
                    guard output.count + count <= limit else { throw ArchiveBrowserError.previewTooLarge }
                    output.append(contentsOf: buffer.prefix(count))
                }
            }
        }
    }
}
