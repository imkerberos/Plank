import Foundation

struct CatalogApplication: Sendable, Equatable {
    let url: URL
    let name: String

    static func matching(_ query: String, in applications: [Self]) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        guard !terms.isEmpty else { return applications }
        return applications.enumerated().compactMap { index, application -> (Int, Int, Self)? in
            let names = [normalized(application.name),
                         normalized(application.url.deletingPathExtension().lastPathComponent)]
            var total = 0
            for term in terms {
                guard let score = names.compactMap({ fuzzyScore(term, in: $0) }).max() else { return nil }
                total += score
            }
            return (total, index, application)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    /// Score ordered character matches, favoring exact names, prefixes, and compact runs.
    private static func fuzzyScore(_ term: String, in name: String) -> Int? {
        if term == name { return 10_000 }
        let query = Array(term)
        let characters = Array(name)
        guard !query.isEmpty, query.count <= characters.count else { return nil }
        var best: Int?
        for start in characters.indices where characters[start] == query[0] {
            var position = start
            var score = 100 - start
            if start == 0 { score += 100 }
            else if !characters[start - 1].isLetter && !characters[start - 1].isNumber { score += 50 }
            var matched = true
            for character in query.dropFirst() {
                let next = position + 1
                guard next < characters.count,
                      let found = characters[next...].firstIndex(of: character) else {
                    matched = false
                    break
                }
                score += found == next ? 30 : -(found - next)
                position = found
            }
            if matched {
                score -= characters.count - query.count
                best = max(best ?? score, score)
            }
        }
        return best
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
