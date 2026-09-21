import SwiftUI

/// One button in a camp dialog. The role picks its colour: primary is
/// green, destructive red, cancel a quiet cream.
struct CampDialogAction: Identifiable {
    enum Role {
        case primary, destructive, cancel
    }

    let id = UUID()
    let title: String
    var role: Role = .primary
    var action: () -> Void = {}

    static func cancel(_ title: String = "Cancel") -> CampDialogAction {
        CampDialogAction(title: title, role: .cancel)
    }
}

extension View {
    /// A camp-styled dialog in place of `.alert` / `.confirmationDialog`:
    /// the raccoon, a title, a line of explanation, chunky buttons. It
    /// covers the whole window, tab bar included.
    func campDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        mood: Raccoon.Mood = .watching,
        actions: [CampDialogAction]
    ) -> some View {
        modifier(CampDialogModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            mood: mood,
            actions: actions
        ))
    }
}

private struct CampDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String?
    let mood: Raccoon.Mood
    let actions: [CampDialogAction]

    /// The cover is presented without the system slide; the dialog
    /// animates itself in and out on top.
    @State private var showsCover = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { showsCover = presented }
            }
            .fullScreenCover(isPresented: $showsCover) {
                CampDialogView(
                    title: title,
                    message: message,
                    mood: mood,
                    actions: actions,
                    close: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { isPresented = false }
                    }
                )
                .presentationBackground(.clear)
            }
    }
}

private struct CampDialogView: View {
    let title: String
    let message: String?
    let mood: Raccoon.Mood
    let actions: [CampDialogAction]
    let close: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black
                .opacity(shown ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture {
                    if let cancel = actions.first(where: { $0.role == .cancel }) {
                        run(cancel)
                    }
                }
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                Raccoon(mood: mood)
                    .frame(width: 72)
                    .padding(.top, 4)
                Text(title)
                    .font(Camp.display(.title3, weight: .bold))
                    .foregroundStyle(Camp.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Camp.muted)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button {
                            run(action)
                        } label: {
                            Text(action.title)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(style(for: action.role))
                    }
                }
                .padding(.top, 6)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Camp.sheet)
                    .shadow(color: Camp.panelEdge, radius: 0, x: 0, y: 6)
            )
            .padding(.horizontal, 28)
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { shown = true }
        }
    }

    private func style(for role: CampDialogAction.Role) -> ChunkyButtonStyle {
        switch role {
        case .primary: .keep
        case .destructive: .toss
        case .cancel: .campPlain
        }
    }

    private func run(_ action: CampDialogAction) {
        withAnimation(.easeIn(duration: 0.15)) {
            shown = false
        } completion: {
            close()
            action.action()
        }
    }
}
