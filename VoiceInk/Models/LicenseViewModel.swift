import Foundation
import AppKit

@MainActor
class LicenseViewModel: ObservableObject {
    enum LicenseState: Equatable {
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed
    }
    
    @Published private(set) var licenseState: LicenseState = .trial(daysRemaining: 7)  // Default to trial
    @Published var licenseKey: String = ""
    @Published var isValidating = false
    @Published var validationMessage: String?
    @Published private(set) var activationsLimit: Int = 0
    
    private let trialPeriodDays = 7
    private let polarService = PolarService()
    private let userDefaults = UserDefaults.standard
    
    init() {
        loadLicenseState()
    }
    
    func startTrial() {
        // Only set trial start date if it hasn't been set before
        if userDefaults.trialStartDate == nil {
            userDefaults.trialStartDate = Date()
            licenseState = .trial(daysRemaining: trialPeriodDays)
            NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        }
    }
    
    private func loadLicenseState() {
        // 🔓 Force mode licence pro à vie
        licenseState = .licensed
        licenseKey = "LIFETIME-PATCHED"
        validationMessage = "Licence activée à vie (patché)"
        
        // Set the userDefaults to mark as licensed
        userDefaults.licenseKey = "LIFETIME-PATCHED"
        userDefaults.set(true, forKey: "VoiceInkHasLaunchedBefore")
        userDefaults.set(false, forKey: "VoiceInkLicenseRequiresActivation")
    }
    
    var canUseApp: Bool {
        switch licenseState {
        case .licensed, .trial:
            return true
        case .trialExpired:
            return false
        }
    }
    
    func openPurchaseLink() {
        if let url = URL(string: "https://tryvoiceink.com/buy") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func validateLicense() async {
        // 🔓 Bypass validation - force success
        isValidating = true
        
        // Brief delay to make it look like we're validating
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        licenseState = .licensed
        licenseKey = "LIFETIME-PATCHED"
        validationMessage = "Licence validée localement (patch)"
        
        // Set the userDefaults to mark as licensed
        userDefaults.licenseKey = "LIFETIME-PATCHED"
        userDefaults.set(false, forKey: "VoiceInkLicenseRequiresActivation")
        userDefaults.activationId = nil
        
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        isValidating = false
    }
    
    func removeLicense() {
        // Remove both license key and trial data
        userDefaults.licenseKey = nil
        userDefaults.activationId = nil
        userDefaults.set(false, forKey: "VoiceInkLicenseRequiresActivation")
        userDefaults.trialStartDate = nil
        userDefaults.set(false, forKey: "VoiceInkHasLaunchedBefore")  // Allow trial to restart
        
        licenseState = .trial(daysRemaining: trialPeriodDays)  // Reset to trial state
        licenseKey = ""
        validationMessage = nil
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        loadLicenseState()
    }
}

extension Notification.Name {
    static let licenseStatusChanged = Notification.Name("licenseStatusChanged")
}

// Add UserDefaults extensions for storing activation ID
extension UserDefaults {
    var activationId: String? {
        get { string(forKey: "VoiceInkActivationId") }
        set { set(newValue, forKey: "VoiceInkActivationId") }
    }
}
