import SwiftUI

@main
struct LabelStudioApp: App {
    @StateObject private var studio = StudioModel()
    @StateObject private var bluetooth = LabelBluetooth()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            StudioView().environmentObject(studio).environmentObject(bluetooth)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { studio.pause(); bluetooth.cancel(); bluetooth.stopScan(); UIApplication.shared.isIdleTimerDisabled = false }
                    else if phase == .active { UIApplication.shared.isIdleTimerDisabled = bluetooth.isWriting || bluetooth.isScanning }
                }
                .onChange(of: bluetooth.isWriting) { _, _ in updateIdleTimer() }
                .onChange(of: bluetooth.isScanning) { _, _ in updateIdleTimer() }
        }
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && (bluetooth.isWriting || bluetooth.isScanning)
    }
}
