import Foundation

enum XcodeBuildOutput {
    static func parseSchemes(_ output: String) throws -> [String] {
        struct Container: Decodable { var schemes: [String]? }
        struct Listing: Decodable { var project: Container?; var workspace: Container? }
        let listing = try JSONDecoder().decode(Listing.self, from: Data(output.utf8))
        return Array(Set(listing.workspace?.schemes ?? listing.project?.schemes ?? [])).sorted()
    }

    /// xcodebuild has no JSON destination listing. Accept only explicit supported
    /// platform/ID records in its compatible section, and reject unavailable rows.
    static func parseDestinations(_ output: String) -> [BuildDestination] {
        let expression = try! NSRegularExpression(pattern: #"(?:^|,\s*)(platform|arch|id|OS|name|error):\s*(.*?)(?=,\s*(?:platform|arch|id|OS|name|error):|$)"#)
        var compatible = false
        var destinations: [BuildDestination] = []
        for line in output.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("destinations compatible with") || lower.contains("available destinations for") { compatible = true; continue }
            if lower.contains("destinations incompatible with") || lower.contains("ineligible destinations") { compatible = false; continue }
            guard compatible, line.contains("{"), line.contains("}"), !line.contains("error:") else { continue }
            var fields: [String: String] = [:]
            let body = String(line.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Device names may contain commas and colons; split only at known keys.
            for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let key = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body) else { continue }
                fields[String(body[key])] = body[value].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let id = fields["id"], !id.isEmpty, !id.contains("placeholder"),
                  let name = fields["name"], let platform = fields["platform"],
                  ["macOS", "iOS Simulator"].contains(platform),
                  !destinations.contains(where: { $0.id == id && $0.platform == platform }) else { continue }
            destinations.append(BuildDestination(id: id, name: name, platform: platform))
        }
        return destinations.sorted { $0.label < $1.label }
    }
}
