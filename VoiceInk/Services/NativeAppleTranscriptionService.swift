import Foundation
import AVFoundation
import os

// Check for availability of new Speech APIs (macOS 26+ / iOS 26+)
#if canImport(Speech) && swift(>=6.0)
import Speech

// Check if the new SpeechTranscriber API is available at compile time
// This is a more precise check than just Swift version
#if hasSymbol(SpeechTranscriber)

/// Transcription service that leverages the new SpeechAnalyzer / SpeechTranscriber API available on macOS 26+ (Tahoe).
/// Falls back with an unsupported-provider error on earlier OS versions so the application can gracefully degrade.
class NativeAppleTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "NativeAppleTranscriptionService")
    
    /// Maps simple language codes to Apple's BCP-47 locale format
    private func mapToAppleLocale(_ simpleCode: String) -> String {
        let mapping = [
            "en": "en-US",
            "es": "es-ES",
            "fr": "fr-FR",
            "de": "de-DE",
            "ar": "ar-SA",
            "it": "it-IT",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "pt": "pt-BR",
            "yue": "yue-CN",
            "zh": "zh-CN"
        ]
        return mapping[simpleCode] ?? "en-US"
    }
    
    enum ServiceError: Error, LocalizedError {
        case unsupportedOS
        case transcriptionFailed
        case localeNotSupported
        case invalidModel
        case assetAllocationFailed
        
        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "SpeechAnalyzer requires macOS 26+ or iOS 26+."
            case .transcriptionFailed:
                return "Transcription failed using SpeechAnalyzer."
            case .localeNotSupported:
                return "The selected language is not supported by SpeechAnalyzer."
            case .invalidModel:
                return "Invalid model type provided for Native Apple transcription."
            case .assetAllocationFailed:
                return "Failed to allocate assets for the selected locale."
            }
        }
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model is NativeAppleModel else {
            throw ServiceError.invalidModel
        }
        
        guard #available(macOS 26, iOS 26, *) else {
            logger.error("SpeechAnalyzer is not available on this OS version")
            throw ServiceError.unsupportedOS
        }
        
        logger.notice("Starting Apple native transcription with SpeechAnalyzer.")
        
        let audioFile = try AVAudioFile(forReading: audioURL)
        
        // Get the user's selected language in simple format and convert to BCP-47 format
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
        let appleLocale = mapToAppleLocale(selectedLanguage)
        let locale = Locale(identifier: appleLocale)

        // Check for locale support and asset installation status using proper BCP-47 format
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        let isLocaleSupported = supportedLocales.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47))
        let isLocaleInstalled = installedLocales.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47))

        // Create the detailed log message
        let supportedIdentifiers = supportedLocales.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        let installedIdentifiers = installedLocales.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        let availableForDownload = Set(supportedLocales).subtracting(Set(installedLocales)).map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        
        var statusMessage: String
        if isLocaleInstalled {
            statusMessage = "✅ Installed"
        } else if isLocaleSupported {
            statusMessage = "❌ Not Installed (Available for download)"
        } else {
            statusMessage = "❌ Not Supported"
        }
        
        let logMessage = """
        
        --- Native Speech Transcription ---
        Selected Language: '\(selectedLanguage)' → Apple Locale: '\(locale.identifier(.bcp47))'
        Status: \(statusMessage)
        ------------------------------------
        Supported Locales: [\(supportedIdentifiers)]
        Installed Locales: [\(installedIdentifiers)]
        Available for Download: [\(availableForDownload)]
        ------------------------------------
        """
        logger.notice("\(logMessage)")

        guard isLocaleSupported else {
            logger.error("Transcription failed: Locale '\(locale.identifier(.bcp47))' is not supported by SpeechTranscriber.")
            throw ServiceError.localeNotSupported
        }
        
        // Properly manage asset allocation/deallocation
        try await deallocateExistingAssets()
        try await allocateAssetsForLocale(locale)
        
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        
        // Ensure model assets are available, triggering a system download prompt if necessary.
        try await ensureModelIsAvailable(for: transcriber, locale: locale)
        
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        
        var transcript: AttributedString = ""
        for try await result in transcriber.results {
            transcript += result.text
        }
        
        var finalTranscription = String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        finalTranscription = WhisperTextFormatter.format(finalTranscription)
        
        logger.notice("Native transcription successful. Length: \(finalTranscription.count) characters.")
        return finalTranscription
    }
    
    @available(macOS 26, iOS 26, *)
    private func deallocateExistingAssets() async throws {
        // Deallocate any existing allocated locales to avoid conflicts
        for locale in await AssetInventory.allocatedLocales {
            await AssetInventory.deallocate(locale: locale)
        }
        logger.notice("Deallocated existing asset locales.")
    }
    
    @available(macOS 26, iOS 26, *)
    private func allocateAssetsForLocale(_ locale: Locale) async throws {
        do {
            try await AssetInventory.allocate(locale: locale)
            logger.notice("Successfully allocated assets for locale: '\(locale.identifier(.bcp47))'")
        } catch {
            logger.error("Failed to allocate assets for locale '\(locale.identifier(.bcp47))': \(error.localizedDescription)")
            throw ServiceError.assetAllocationFailed
        }
    }
    
    @available(macOS 26, iOS 26, *)
    private func ensureModelIsAvailable(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installedLocales = await SpeechTranscriber.installedLocales
        let isInstalled = installedLocales.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47))

        if !isInstalled {
            logger.notice("Assets for '\(locale.identifier(.bcp47))' not installed. Requesting system download.")
            
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                logger.notice("Asset download for '\(locale.identifier(.bcp47))' complete.")
            } else {
                logger.error("Asset download for '\(locale.identifier(.bcp47))' failed: Could not create installation request.")
                // Note: We don't throw an error here, as transcription might still work with a base model.
            }
        }
    }
}

#else
// -----------------------------------------------------------------------------
// Fallback when SpeechTranscriber symbol is not available (current Xcode versions)
// -----------------------------------------------------------------------------

/// Fallback implementation when SpeechTranscriber APIs are not available at compile time.
/// Simply throws an error but conforms to TranscriptionService so the rest of the project compiles.
class NativeAppleTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "NativeAppleTranscriptionService")
    
    enum ServiceError: Error, LocalizedError {
        case unsupportedCompiler
        
        var errorDescription: String? {
            switch self {
            case .unsupportedCompiler:
                return "SpeechTranscriber APIs require future Xcode versions with macOS 26+ SDK."
            }
        }
    }
    
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        logger.info("SpeechTranscriber APIs not available at compile time - using fallback error")
        throw ServiceError.unsupportedCompiler
    }
}

#endif

#else
// -----------------------------------------------------------------------------
// Fallback for older Swift versions or when Speech framework is unavailable
// -----------------------------------------------------------------------------

/// Fallback implementation for environments where the new Speech APIs are not available.
/// Simply throws an error but conforms to TranscriptionService so the rest of the project compiles.
class NativeAppleTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "NativeAppleTranscriptionService")
    
    enum ServiceError: Error, LocalizedError {
        case unsupportedEnvironment
        
        var errorDescription: String? {
            switch self {
            case .unsupportedEnvironment:
                return "Native Apple transcription requires newer Swift and macOS versions."
            }
        }
    }
    
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        logger.info("NativeAppleTranscriptionService unavailable - older environment")
        throw ServiceError.unsupportedEnvironment
    }
}

#endif 
