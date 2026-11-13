import Foundation

/// Lookup firmy v Českém registru ekonomických subjektů (ARES).
/// Dokumentace: https://ares.gov.cz/stranky/vyvojar-info
enum AresClient {
    struct Company {
        var name: String
        var ico: String
        var dic: String?
        var address: String?
    }

    enum AresError: LocalizedError {
        case invalidICO
        case notFound
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidICO: return "IČ musí být číselné (obvykle 8 číslic)."
            case .notFound: return "Firma s tímto IČ nebyla v ARES nalezena."
            case .transport(let msg): return "Chyba ARES: \(msg)"
            }
        }
    }

    static func lookup(ico rawIco: String) async throws -> Company {
        let ico = rawIco.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !ico.isEmpty, ico.allSatisfy({ $0.isNumber }) else { throw AresError.invalidICO }

        let urlString = "https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/\(ico)"
        guard let url = URL(string: urlString) else { throw AresError.invalidICO }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AresError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AresError.transport("neplatná odpověď serveru")
        }
        if http.statusCode == 404 { throw AresError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw AresError.transport("HTTP \(http.statusCode)")
        }

        struct AresResponse: Decodable {
            let ico: String?
            let obchodniJmeno: String?
            let dic: String?
            let sidlo: Sidlo?
            struct Sidlo: Decodable {
                let textovaAdresa: String?
            }
        }
        guard let decoded = try? JSONDecoder().decode(AresResponse.self, from: data),
              let name = decoded.obchodniJmeno else {
            throw AresError.notFound
        }

        return Company(
            name: name,
            ico: decoded.ico ?? ico,
            dic: decoded.dic,
            address: decoded.sidlo?.textovaAdresa
        )
    }
}
