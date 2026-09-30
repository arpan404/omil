import SwiftUI
import VisionKit
import AVFoundation

/// Asks for the camera, then presents the QR scanner and pairs with the
/// scanned code. Falls back to guidance when scanning isn't possible.
struct ScanPairingButton<Label: View>: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ViewBuilder let label: () -> Label
    @State private var showScanner = false

    var body: some View {
        Button(action: begin, label: label)
            .disabled(coordinator.pairingInProgress || !DataScannerViewController.isSupported)
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    PairingScanner { code in
                        showScanner = false
                        Task {
                            await coordinator.pair(with: code)
                            if coordinator.pairingMessage == "Connected to your Mac." {
                                ToastCenter.shared.show("Connected to Your Mac", symbol: "checkmark.circle.fill")
                            } else {
                                ToastCenter.shared.show("Couldn't Pair", symbol: "exclamationmark.triangle.fill", tone: .error)
                            }
                        }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Pairing Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
            }
    }

    private func begin() {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed && DataScannerViewController.isAvailable {
                showScanner = true
            } else {
                coordinator.pairingMessage = allowed
                    ? "The camera scanner is unavailable. Enter the connection details instead."
                    : "Allow camera access in Settings to scan the code, or enter the connection details instead."
                ToastCenter.shared.show("Camera Unavailable", symbol: "camera.fill", tone: .warning)
            }
        }
    }
}

struct PairingScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        if DataScannerViewController.isAvailable {
            try? scanner.startScanning()
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if DataScannerViewController.isAvailable && !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var scanned = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !scanned else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let value = barcode.payloadStringValue {
                    scanned = true
                    dataScanner.stopScanning()
                    onScan(value)
                    return
                }
            }
        }
    }
}
