import SwiftUI
import UIKit

/// Presents transient companion warnings without interrupting the reader with
/// an alert. The manager retains the latest message so a newly presented
/// library or sheet can show it once; this view owns the five-second display.
struct ComputerDocumentToast: ViewModifier {
  @ObservedObject var manager: CompanionDocumentManager
  @State private var visibleMessage: String?
  @State private var dismissalTask: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let visibleMessage {
          Text(visibleMessage)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(visibleMessage)
            .accessibilityIdentifier("companion.toast")
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: visibleMessage)
      .onAppear {
        present(manager.toast)
      }
      .onChange(of: manager.toast) { _, message in
        present(message)
      }
      .onDisappear {
        dismissalTask?.cancel()
      }
  }

  @MainActor
  private func present(_ message: String?) {
    dismissalTask?.cancel()
    visibleMessage = message
    guard let message, !message.isEmpty else { return }

    UIAccessibility.post(notification: .announcement, argument: message)
    dismissalTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
      guard !Task.isCancelled, visibleMessage == message else { return }
      visibleMessage = nil
      if manager.toast == message { manager.toast = nil }
    }
  }
}
