import SwiftUI
import DrawerCore

@main
struct DrawerMobileApp: App {
    var body: some Scene {
        DocumentGroup { document in
            MobileContentView(document: document)
        } makeDocument: { _, _ in
            DrawerDocument()
        }
    }
}
