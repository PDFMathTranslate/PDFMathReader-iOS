import SwiftUI

/// Show/hide timing for the floating pager, matching the desktop reader:
/// hidden until the document scrolls, then hidden again one second after the
/// last scroll unless the page field is being edited.
@MainActor
final class ReaderPagerVisibility: ObservableObject {
  @Published private(set) var isVisible = false
  private var isHeld = false
  private static let clock = ContinuousClock()
  private var hideDeadline: ContinuousClock.Instant?
  private var hideTask: Task<Void, Never>?

  func show() {
    if !isVisible { isVisible = true }
    guard !isHeld else { return }
    hideDeadline = Self.clock.now.advanced(by: .seconds(1))
    startHideTaskIfNeeded()
  }

  func hold() {
    isHeld = true
    hideDeadline = nil
  }

  func release() {
    isHeld = false
    hideDeadline = Self.clock.now.advanced(by: .seconds(1))
    startHideTaskIfNeeded()
  }

  private func startHideTaskIfNeeded() {
    guard !isHeld, hideTask == nil else { return }
    hideTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let deadline = self?.hideDeadline else { break }
        do {
          try await Self.clock.sleep(until: deadline)
        } catch {
          break
        }
        guard !Task.isCancelled, let self, !self.isHeld,
          let latestDeadline = self.hideDeadline
        else { break }
        if latestDeadline > Self.clock.now { continue }
        self.isVisible = false
        self.hideDeadline = nil
        break
      }
      self?.hideTask = nil
    }
  }
}

/// Floating page navigator in the reader's bottom-right corner: previous
/// page, editable page number over the page count, next page.
struct ReaderPager: View {
  @ObservedObject var model: ReaderViewModel
  @ObservedObject var visibility: ReaderPagerVisibility
  let compact: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isEditing: Bool
  @State private var entry = ""

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if visibility.isVisible && model.pageCount > 0 {
        island
          .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .padding(.trailing, compact ? 10 : 22)
    .padding(.bottom, compact ? 12 : 22)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: visibility.isVisible)
  }

  private var island: some View {
    HStack(spacing: 0) {
      pageButton(
        model.readingState.scrollDirection == .horizontal ? "chevron.left" : "chevron.up",
        label: L10n.string("navigator.previousPage"),
        disabled: model.readingState.page <= 1
      ) { model.goToPage(model.readingState.page - 1) }

      HStack(spacing: 4) {
        TextField("", text: $entry)
          .keyboardType(.numberPad)
          .multilineTextAlignment(.center)
          .font(.body.weight(.semibold).monospacedDigit())
          .frame(width: max(36, CGFloat(String(model.pageCount).count) * 11), height: 44)
          .background {
            if isEditing {
              Capsule().fill(.primary.opacity(0.08))
            }
          }
          .focused($isEditing)
          .accessibilityLabel(L10n.string("navigator.pageNumber"))
          .accessibilityIdentifier("reader.pager.page")
          .onSubmit(submit)
        Text(verbatim: "/ \(model.pageCount)")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      pageButton(
        model.readingState.scrollDirection == .horizontal ? "chevron.right" : "chevron.down",
        label: L10n.string("navigator.nextPage"),
        disabled: model.readingState.page >= model.pageCount
      ) { model.goToPage(model.readingState.page + 1) }
    }
    .padding(4)
    .modifier(ReaderPagerGlassSurface())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.string("navigator.pageNavigator"))
    .accessibilityIdentifier("reader.pager")
    .toolbar {
      if isEditing {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button(L10n.string("menu.extra.messages.Go")) { isEditing = false }
        }
      }
    }
    .onAppear { entry = "\(model.readingState.page)" }
    .onChange(of: model.readingState.page) { _, page in
      if !isEditing { entry = "\(page)" }
    }
    .onChange(of: isEditing) { _, editing in
      // Like the desktop field, leaving it commits the typed page.
      if editing {
        visibility.hold()
      } else {
        submit()
        visibility.release()
      }
    }
  }

  private func pageButton(
    _ systemImage: String,
    label: String,
    disabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      visibility.show()
    } label: {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.borderless)
    .buttonBorderShape(.circle)
    .foregroundStyle(disabled ? .tertiary : .primary)
    .disabled(disabled)
    .accessibilityLabel(label)
  }

  private func submit() {
    if let page = Int(entry.trimmingCharacters(in: .whitespaces)), page != model.readingState.page {
      model.goToPage(page)
    }
    entry = "\(model.readingState.page)"
  }
}

private struct ReaderPagerGlassSurface: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: .capsule)
    } else {
      content
        .background(.regularMaterial, in: Capsule())
        .overlay {
          Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
  }
}
