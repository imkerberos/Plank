import Foundation

struct CatalogApplication: Sendable, Equatable {
    let url: URL
    let name: String

    static func matching(_ query: String, in applications: [Self]) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return applications.filter { application in
            terms.allSatisfy {
                application.name.localizedStandardContains($0)
                    || application.url.deletingPathExtension().lastPathComponent.localizedStandardContains($0)
            }
        }
    }
}

enum ApplicationCatalog {
    static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         URL(fileURLWithPath: "/System/Applications"),
         URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
    }

    /// Walk application directories, including Utilities, without descending into bundles.
    static func scan(roots: [URL] = defaultRoots) -> [CatalogApplication] {
        var seen: Set<String> = []
        var applications: [CatalogApplication] = []
        func collect(_ candidate: URL) {
            guard candidate.pathExtension.lowercased() == "app" else { return }
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted, let bundle = Bundle(url: url),
                  let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
                  ["APPL", "FNDR"].contains(packageType),
                  let executable = bundle.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { return }
            for key in ["LSUIElement", "LSBackgroundOnly"] {
                let value = bundle.object(forInfoDictionaryKey: key)
                if (value as? NSNumber)?.boolValue == true || (value as? NSString)?.boolValue == true { return }
            }
            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? FileManager.default.displayName(atPath: url.path)
            let name = displayName.lowercased().hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            applications.append(CatalogApplication(url: url, name: name))
        }
        for root in roots {
            if Task.isCancelled { break }
            if root.pathExtension.lowercased() == "app" { collect(root); continue }
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                collect(url)
            }
        }
        return applications.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.url.path < $1.url.path : comparison == .orderedAscending
        }
    }
}
