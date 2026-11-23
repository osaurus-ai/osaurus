import AppKit
import Foundation
import SwiftUI

/// Stable no-op facade in normal builds. The implementation and its resources
/// exist only when the package is explicitly built for design inspection.
public enum DevelopmentDesignInspector {
    public static var isAvailable: Bool {
        #if OSAURUS_DESIGN_INSPECTOR
        true
        #else
        false
        #endif
    }
    /// Called before AppDelegate or any app singleton is initialized.
    public static func prepareProcess() {
        #if OSAURUS_DESIGN_INSPECTOR
        guard Bundle.main.bundleIdentifier == "studio.topiary.osaurus-design-integration",
            let path = Bundle.main.object(forInfoDictionaryKey:"DesignInspectorDataRoot") as? String,
            let workspace = Bundle.main.object(forInfoDictionaryKey:"DesignInspectorWorkspace") as? String else {
            fatalError("Design builds require the isolated identity and workspace launcher. Refusing normal app startup.")
        }
        let root=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        let parent=URL(fileURLWithPath:workspace).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(parent.path + "/"),root.path != NSHomeDirectory() else {
            fatalError("Design data must remain inside its isolated workspace")
        }
        setenv("OSAURUS_TEST_ROOT",root.path,1)
        let connectedModels = Bundle.main.object(forInfoDictionaryKey: "DesignInspectorConnectedModels") as? Bool ?? false
        setenv("OSAURUS_DESIGN_INSPECTOR_CONNECTED_MODELS", connectedModels ? "1" : "0", 1)
        setenv("OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS","1",1)
        setenv("OSAURUS_KEYCHAIN_FREE_SHOW_UI","1",1)
        setenv("OSU_MODELS_DIR",root.appendingPathComponent("models").path,1)
        setenv("HF_HOME",root.appendingPathComponent("model-cache").path,1)
        setenv("HF_HUB_CACHE",root.appendingPathComponent("model-cache/hub").path,1)
        do {
            for sub in ["config","models","model-cache/hub"] {
                try FileManager.default.createDirectory(at:root.appendingPathComponent(sub),withIntermediateDirectories:true)
            }
            let config=root.appendingPathComponent("config/server.json")
            if !FileManager.default.fileExists(atPath:config.path) {
                let data=try JSONSerialization.data(withJSONObject:["port":14379,"exposeToNetwork":false,"startAtLogin":false,"hideDockIcon":false,"appearanceMode":"dark"],options:[.prettyPrinted,.sortedKeys])
                try data.write(to:config,options:.atomic)
            }
        } catch { fatalError("Cannot create isolated development data: \(error)") }
        UserDefaults.standard.register(defaults:["hasCompletedOnboarding":true,"onboardingVersion":3])
        if ProcessInfo.processInfo.environment["OSAURUS_MODEL_CONNECTION_CHECKS"] == "1" {
            Task { @MainActor in DesignModelConnectionChecks.run() }
        }
        if ProcessInfo.processInfo.environment["OSAURUS_APP_DEFAULT_CHECKS"] == "1" {
            Task { @MainActor in _ = DesignWorkingStore.shared }
        }
        #endif
    }
    @MainActor public static func show() {
        #if OSAURUS_DESIGN_INSPECTOR
        DesignInspectorWindow.shared.show()
        #endif
    }
}

#if OSAURUS_DESIGN_INSPECTOR
@MainActor private final class DesignInspectorWindow {
    static let shared=DesignInspectorWindow()
    private var window:NSWindow?
    func show() {
        if let window {window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return}
        let new=NSWindow(contentRect:NSRect(x:0,y:0,width:1380,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        new.title="Osaurus · Integration inspector"
        new.minSize=NSSize(width:1100,height:720)
        new.isReleasedWhenClosed=false
        new.contentView=NSHostingView(rootView:CatalogContentView(store: CatalogDesignStore()))
        new.center();new.makeKeyAndOrderFront(nil);window=new
        NSApp.activate(ignoringOtherApps:true)
    }
}
#endif
