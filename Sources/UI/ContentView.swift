import SwiftUI

struct ContentView: View {
    @StateObject private var document = ImageDocumentModel()

    var body: some View {
        MetalImageView(image: document.currentImage, editState: document.editState)
            .frame(minWidth: 480, minHeight: 360)
            .safeAreaInset(edge: .bottom) {
                editControls
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

    private var editControls: some View {
        VStack {
            HStack {
                Text("Temperature")
                Slider(value: $document.editState.whiteBalanceTemperature, in: 3500...9500)
                Text(String(format: "%.0fK", document.editState.whiteBalanceTemperature))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Button("Reset") {
                    document.editState.whiteBalanceTemperature = 6500
                }
                .disabled(document.editState.whiteBalanceTemperature == 6500)
            }
            HStack {
                Text("Tint")
                Slider(value: $document.editState.whiteBalanceTint, in: -100...100)
                Text(String(format: "%+.0f", document.editState.whiteBalanceTint))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Button("Reset") {
                    document.editState.whiteBalanceTint = 0
                }
                .disabled(document.editState.whiteBalanceTint == 0)
            }
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
            HStack {
                Text("Contrast")
                Slider(value: $document.editState.contrast, in: -1...1)
                Text(String(format: "%+.0f%%", document.editState.contrast * 100))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Button("Reset") {
                    document.editState.contrast = 0
                }
                .disabled(document.editState.contrast == 0)
            }
            HStack {
                Text("Highlights")
                Slider(value: $document.editState.curvesHighlights, in: -1...1)
                Text(String(format: "%+.0f%%", document.editState.curvesHighlights * 100))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Button("Reset") {
                    document.editState.curvesHighlights = 0
                }
                .disabled(document.editState.curvesHighlights == 0)
            }
            HStack {
                Text("Shadows")
                Slider(value: $document.editState.curvesShadows, in: -1...1)
                Text(String(format: "%+.0f%%", document.editState.curvesShadows * 100))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Button("Reset") {
                    document.editState.curvesShadows = 0
                }
                .disabled(document.editState.curvesShadows == 0)
            }
        }
        .padding()
        .disabled(document.currentImage == nil)
    }
}

#Preview {
    ContentView()
}
