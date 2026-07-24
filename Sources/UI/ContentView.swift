import SwiftUI

struct ContentView: View {
    @StateObject private var document = ImageDocumentModel()

    var body: some View {
        MetalImageView(image: document.currentImage)
            .frame(minWidth: 480, minHeight: 360)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Open…") {
                        document.openImage()
                    }
                }
            }
            .navigationTitle(document.currentFileName ?? "PhotoApp")
            .alert(
                "Couldn't Open Image",
                isPresented: Binding(
                    get: { document.loadErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented { document.loadErrorMessage = nil }
                    }
                ),
                presenting: document.loadErrorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
    }
}

#Preview {
    ContentView()
}
