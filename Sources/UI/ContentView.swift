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
        ScrollView {
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
                HStack {
                    Text("Hue")
                    Slider(value: $document.editState.hslHue, in: -180...180)
                    Text(String(format: "%+.0f°", document.editState.hslHue))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Button("Reset") {
                        document.editState.hslHue = 0
                    }
                    .disabled(document.editState.hslHue == 0)
                }
                HStack {
                    Text("Saturation")
                    Slider(value: $document.editState.hslSaturation, in: -1...1)
                    Text(String(format: "%+.0f%%", document.editState.hslSaturation * 100))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Button("Reset") {
                        document.editState.hslSaturation = 0
                    }
                    .disabled(document.editState.hslSaturation == 0)
                }
                HStack {
                    Text("Crop Top")
                    Slider(value: $document.editState.cropInsetTop, in: 0...0.45)
                    Text(String(format: "%.0f%%", document.editState.cropInsetTop * 100))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Button("Reset") {
                        document.editState.cropInsetTop = 0
                    }
                    .disabled(document.editState.cropInsetTop == 0)
                }
                HStack {
                    Text("Crop Bottom")
                    Slider(value: $document.editState.cropInsetBottom, in: 0...0.45)
                    Text(String(format: "%.0f%%", document.editState.cropInsetBottom * 100))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Button("Reset") {
                        document.editState.cropInsetBottom = 0
                    }
                    .disabled(document.editState.cropInsetBottom == 0)
                }
                HStack {
                    Text("Crop Left")
                    Slider(value: $document.editState.cropInsetLeft, in: 0...0.45)
                    Text(String(format: "%.0f%%", document.editState.cropInsetLeft * 100))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Button("Reset") {
                        document.editState.cropInsetLeft = 0
                    }
                    .disabled(document.editState.cropInsetLeft == 0)
                }
                HStack {
                    Text("Crop Right")
                    Slider(value: $document.editState.cropInsetRight, in: 0...0.45)
                    Text(String(format: "%.0f%%", document.editState.cropInsetRight * 100))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Button("Reset") {
                        document.editState.cropInsetRight = 0
                    }
                    .disabled(document.editState.cropInsetRight == 0)
                }
            }
            .padding()
        }
        .frame(maxHeight: 280)
        .disabled(document.currentImage == nil)
    }
}

#Preview {
    ContentView()
}
