import SwiftUI

struct ContentView: View {
    @StateObject private var document = ImageDocumentModel()

    var body: some View {
        MetalImageView(image: document.currentImage, editState: document.editState)
            .frame(minWidth: 480, minHeight: 360)
            .safeAreaInset(edge: .bottom) {
                exposureControls
            }
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

    private var exposureControls: some View {
        HStack {
            Text("Exposure")
            Slider(value: $document.editState.exposureEV, in: -5...5)
            Text(String(format: "%+.2f EV", document.editState.exposureEV))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Button("Reset") {
                document.editState.exposureEV = 0
            }
            .disabled(document.editState.exposureEV == 0)
        }
        .padding()
        .disabled(document.currentImage == nil)
    }
}

#Preview {
    ContentView()
}
