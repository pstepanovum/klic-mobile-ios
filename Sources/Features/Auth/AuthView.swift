import SwiftUI
import Inject

/// Auth flow entry point. Login and Sign Up are now separate pages (each with their
/// own circle-container backdrop) instead of one toggle-mode form; this just hosts
/// the navigation between them, chrome-less to match the mock.
struct AuthView: View {
    @ObserveInjection var inject

    var body: some View {
        NavigationStack {
            LoginView()
        }
        .tint(AuthStyle.ctaRed)
        .enableInjection()
    }
}
