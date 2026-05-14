import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - AddItemViewModel lifecycle (build 6)
//
// Phase 4 added a `deinit` that wipes large UIImage / processed-image
// state on tear-down so SwiftUI sheets that get rebuilt rapidly (e.g.
// multi-pick mid-batch) don't leave several hundred MB of bitmap data
// sitting in memory until iOS reclaims it. These tests pin the
// behaviour by exercising weak-reference release semantics around the
// VM — they don't poke at the VM's internals, they verify that the
// retain graph actually drops the object.

@MainActor
struct AddItemViewModelLifecycleTests {

    @Test func viewModelDeallocatesWhenLastReferenceDrops() async {
        weak var weakVM: AddItemViewModel?
        do {
            let vm = AddItemViewModel()
            weakVM = vm
            vm.selectedImage = UIImage()
            // Ensure the VM isn't nil-ed by the optimizer.
            _ = vm.selectedImage
        }
        // After leaving the scope, the strong ref is gone. Allow the
        // run loop a tick to flush any retain cycles from observers.
        try? await Task.sleep(for: .milliseconds(10))
        #expect(weakVM == nil, "AddItemViewModel must deallocate when the last strong reference drops")
    }

    @Test func onCameraCancelledClearsErrorMessage() {
        let vm = AddItemViewModel()
        vm.errorMessage = "Couldn't capture: simulated failure"
        vm.isShowingCamera = true

        vm.onCameraCancelled()

        #expect(vm.isShowingCamera == false)
        #expect(vm.errorMessage == nil,
                "build 6: onCameraCancelled must wipe a stale capture error so the next open is clean")
    }

    @Test func onCameraCoverDismissedIsCallableNoOp() {
        // Logging-only seam — exists so `AddItemView.onDisappear` has
        // a testable callsite and future builds can hang teardown
        // here. Just confirm it doesn't crash and doesn't mutate
        // visible state.
        let vm = AddItemViewModel()
        let beforeStep = vm.currentStep
        vm.onCameraCoverDismissed()
        #expect(vm.currentStep == beforeStep)
    }
}
