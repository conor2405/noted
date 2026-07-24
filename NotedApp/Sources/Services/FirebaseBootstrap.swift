import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    @discardableResult
    static func configureIfAvailable(bundle: Bundle = .main) -> Bool {
        if FirebaseApp.app() != nil {
            return true
        }

        guard
            let configurationURL = bundle.url(forResource: "GoogleService-Info", withExtension: "plist"),
            let options = FirebaseOptions(contentsOfFile: configurationURL.path)
        else {
            return false
        }

        FirebaseApp.configure(options: options)
        return true
    }
}
