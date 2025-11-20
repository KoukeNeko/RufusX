//
//  ISODownloadService.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation
import Combine

final class ISODownloadService: ObservableObject {

    // MARK: - Constants

    private enum Endpoints {
        static let sessionWhitelist = "https://vlscppe.microsoft.com/tags"
        static let skuInfo = "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition"
        static let downloadLinks = "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku"
    }

    private let orgID = "y6jn8c31"

    // MARK: - Product IDs

    private let windowsProductIDs: [String: [String: String]] = [
        "Windows 11": [
            "24H2 (Build 26100 - 2024.10)": "2935",
            "23H2 v2 (Build 22631.2861 - 2024.01)": "2769",
            "22H2 v1 (Build 22621.525 - 2022.10)": "2618"
        ],
        "Windows 10": [
            "22H2 v1 (Build 19045.2965 - 2023.05)": "2618"
        ],
        "Windows 8.1": [
            "Update 3 (Build 9600)": "52"
        ]
    ]

    // MARK: - Error Types

    enum DownloadError: LocalizedError {
        case invalidURL
        case networkError(String)
        case noDownloadLink
        case sessionFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL"
            case .networkError(let message):
                return "Network error: \(message)"
            case .noDownloadLink:
                return "No download link found"
            case .sessionFailed:
                return "Failed to create session"
            case .cancelled:
                return "Download cancelled"
            }
        }
    }

    // MARK: - Published Properties

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var currentStatus: String = ""

    // MARK: - Private Properties

    private var downloadTask: URLSessionDownloadTask?
    private var isCancelled = false

    // MARK: - Public Methods

    func cancel() {
        isCancelled = true
        downloadTask?.cancel()
    }

    func getDownloadURL(
        version: String,
        release: String,
        language: String,
        architecture: String
    ) async throws -> URL {

        isCancelled = false

        // Step 1: Create session
        let sessionID = UUID().uuidString

        currentStatus = "Creating session..."
        try await registerSession(sessionID: sessionID)

        if isCancelled { throw DownloadError.cancelled }

        // Step 2: Get product ID
        guard let productID = getProductID(version: version, release: release) else {
            throw DownloadError.invalidURL
        }

        // Step 3: Get SKU info
        currentStatus = "Getting available languages..."
        let skuID = try await getSkuID(
            productID: productID,
            language: language,
            sessionID: sessionID
        )

        if isCancelled { throw DownloadError.cancelled }

        // Step 4: Get download links
        currentStatus = "Getting download links..."
        let downloadURL = try await getDownloadLink(
            skuID: skuID,
            architecture: architecture,
            sessionID: sessionID
        )

        return downloadURL
    }

    func downloadISO(
        url: URL,
        to destination: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {

        isDownloading = true
        isCancelled = false

        defer {
            isDownloading = false
        }

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.networkError("Invalid response")
        }

        // Move to destination
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Private Methods

    private func registerSession(sessionID: String) async throws {
        var components = URLComponents(string: Endpoints.sessionWhitelist)!
        components.queryItems = [
            URLQueryItem(name: "org_id", value: orgID),
            URLQueryItem(name: "session_id", value: sessionID)
        ]

        guard let url = components.url else {
            throw DownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.sessionFailed
        }
    }

    private func getProductID(version: String, release: String) -> String? {
        return windowsProductIDs[version]?[release]
    }

    private func getSkuID(
        productID: String,
        language: String,
        sessionID: String
    ) async throws -> String {

        var components = URLComponents(string: Endpoints.skuInfo)!
        components.queryItems = [
            URLQueryItem(name: "profile", value: "606624d44113"),
            URLQueryItem(name: "productEditionId", value: productID),
            URLQueryItem(name: "SKU", value: "IsosAndSDKs"),
            URLQueryItem(name: "friendlyFileName", value: ""),
            URLQueryItem(name: "Locale", value: mapLanguageToLocale(language)),
            URLQueryItem(name: "sessionID", value: sessionID)
        ]

        guard let url = components.url else {
            throw DownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.networkError("Failed to get SKU info")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skus = json["Skus"] as? [[String: Any]],
              let firstSku = skus.first,
              let skuID = firstSku["Id"] as? String else {
            throw DownloadError.noDownloadLink
        }

        return skuID
    }

    private func getDownloadLink(
        skuID: String,
        architecture: String,
        sessionID: String
    ) async throws -> URL {

        var components = URLComponents(string: Endpoints.downloadLinks)!
        components.queryItems = [
            URLQueryItem(name: "profile", value: "606624d44113"),
            URLQueryItem(name: "SKU", value: skuID),
            URLQueryItem(name: "friendlyFileName", value: ""),
            URLQueryItem(name: "Locale", value: "en-US"),
            URLQueryItem(name: "sessionID", value: sessionID)
        ]

        guard let url = components.url else {
            throw DownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.networkError("Failed to get download links")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let productLinks = json["ProductDownloadLinks"] as? [[String: Any]] else {
            throw DownloadError.noDownloadLink
        }

        // Find matching architecture
        let archCode = architecture == "ARM64" ? "ARM64" : "IsoX64"

        for link in productLinks {
            if let downloadType = link["DownloadType"] as? String,
               downloadType.contains(archCode),
               let uriString = link["Uri"] as? String,
               let downloadURL = URL(string: uriString) {
                return downloadURL
            }
        }

        throw DownloadError.noDownloadLink
    }

    private func mapLanguageToLocale(_ language: String) -> String {
        let localeMap: [String: String] = [
            "English International": "en-GB",
            "English": "en-US",
            "Chinese (Traditional)": "zh-TW",
            "Chinese (Simplified)": "zh-CN",
            "Japanese": "ja-JP",
            "Korean": "ko-KR",
            "French": "fr-FR",
            "German": "de-DE",
            "Spanish": "es-ES"
        ]
        return localeMap[language] ?? "en-US"
    }
}

// MARK: - UEFI Shell Download

extension ISODownloadService {

    func getUEFIShellDownloadURL() -> URL {
        // UEFI Shell from Tianocore
        return URL(string: "https://github.com/pbatard/UEFI-Shell/releases/download/24H2/UEFI-Shell-2.2-24H2-RELEASE.iso")!
    }
}
