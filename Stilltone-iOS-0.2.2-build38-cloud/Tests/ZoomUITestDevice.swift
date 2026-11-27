import Foundation
import WebKit

// Built only in the temporary simulator UI-test copy.
@MainActor
final class ZoomUITestDevice {
    let enabled = ProcessInfo.processInfo.arguments.contains("-zoom-ui-test")
    private let revision = 73
    private var request = 20
    private var zoom = 1.0
    private var commands = 0
    private weak var publishedWeb: WKWebView?

    func publish(_ web: WKWebView) {
        guard publishedWeb !== web else { return }
        publishedWeb = web
        report(web)
    }

    func accept(_ payload: [String:Any], in web: WKWebView) {
        commands += 1
        guard (payload["inputRevision"] as? Int) == revision,
              let id = payload["zoomRequestID"] as? Int, id == request+1,
              let factor = payload["value"] as? Double, [0.5,1,2,3].contains(factor),
              payload["pinchID"] == nil else { report(web); return }
        request = id
        zoom = factor
        report(web)
    }

    private func report(_ web: WKWebView) {
        let state: [String:Any] = ["ready":true,"busy":false,"formats":["HEIF"],"sizes":[12],
            "zoom":zoom,"zoomTarget":zoom,"zoomRequestID":request,"zoomSettling":false,
            "inputRevision":revision,"zoomRange":[0.5,15.0],"lenses":[0.5,1,2,3],
            "opticalZoomStops":[0.5,1,3],"live":false,"flash":false,"biasLimits":[-2,2]]
        let probe = """
        window.receiveCamera(state);
        let receipt = document.getElementById('zoom-test-receipt');
        if (!receipt) {
            receipt = document.createElement('span');
            receipt.id = 'zoom-test-receipt';
            receipt.style.cssText = 'position:fixed;left:4px;top:60px;pointer-events:none;font:8px sans-serif;color:white;z-index:100';
            document.body.append(receipt);
        }
        const active = document.querySelector('.capture-tools [data-step][aria-pressed=true]');
        receipt.textContent = ['zoom receipt', count, state.zoomRequestID, state.zoom, active?.dataset.step].join(' ');
        """
        STCallPageScript(web, probe, ["state":state,"count":commands], nil)
    }
}
