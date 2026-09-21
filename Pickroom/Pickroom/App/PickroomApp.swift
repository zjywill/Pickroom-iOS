import SwiftUI

@main
struct PickroomApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        // BGTaskScheduler handlers must be registered before launch
        // finishes, exactly once — here, not in any async path.
        AppModel.registerBackgroundWork(for: model)
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
