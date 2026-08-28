import Foundation

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#endif

@main
struct HeliosSwiftCrossUIApp {
    static func main() {
        #if canImport(SwiftCrossUI)
        print("Wire the SwiftCrossUI runtime here and hydrate ManagementSettingsRootView from ../../shared/management-settings.slice.json.")
        #else
        print("SwiftCrossUI is not installed yet. This scaffold stays compile-safe while the Windows UI runtime settles.")
        #endif
    }
}
