import Foundation
import WebKit

// Built only in the temporary simulator UI-test copy.
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
              let factor = (payload["value"] as? NSNumber)?.doubleValue, [0.5,1,2,3].contains(factor),
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
        let panel = document.getElementById('zoom-test-probe');
        if (!panel) {
            panel = document.createElement('div');
            panel.id = 'zoom-test-probe';
            panel.style.cssText = 'position:fixed;left:4px;top:60px;pointer-events:none;font:8px sans-serif;color:white;z-index:100';
            document.body.append(panel);
            const hits = document.createElement('div');
            panel.after(hits);
            hits.style.cssText = 'position:fixed;left:4px;top:108px;pointer-events:none;font:8px sans-serif;color:white';
            for (const type of ['pointerdown','pointerup','pointercancel']) {
                document.addEventListener(type, event => {
                    const target = event.target.closest('[data-step]')?.dataset.step ?? event.target.tagName;
                    panel.dataset.heldStep = type === 'pointerdown' ? target : '';
                    hits.textContent += ' ' + [type, target, Math.round(event.clientX), Math.round(event.clientY)].join('/');
                }, {capture:true,passive:true});
            }
        }
        const receipt = document.createElement('div');
        panel.replaceChildren(receipt);
        const rail = document.querySelector('.capture-tools');
        const active = rail.querySelector('[data-step][aria-pressed=true]');
        receipt.textContent = ['zoom receipt', count, state.zoomRequestID, state.zoom, active?.dataset.step].join(' ');
        if (count && panel.dataset.heldStep === String(state.zoom)) {
            const observed = document.createElement('div');
            observed.textContent = 'zoom acknowledged before release ' + state.zoomRequestID;
            panel.append(observed);
        }
        let previous = '', stable = 0;
        function measure() {
            if (!receipt.isConnected) return;
            const lines = Array.from(rail.querySelectorAll('[data-step]'), button => {
                const box = button.getBoundingClientRect(), x = box.x + box.width / 2, y = box.y + box.height / 2;
                const hit = document.elementFromPoint(x,y)?.closest('[data-step]')?.dataset.step ?? '-';
                return ['zoom point', state.zoomRequestID, button.dataset.step, (x / innerWidth).toFixed(6),
                        (y / innerHeight).toFixed(6), hit].join(' ');
            });
            const now = lines.join('|');
            stable = now === previous ? stable + 1 : 0;
            previous = now;
            if (stable < 2 || rail.getAnimations().some(a => a.playState === 'running' || a.pending)) {
                requestAnimationFrame(measure);
                return;
            }
            for (const text of lines) {
                const line = document.createElement('div');
                line.textContent = text;
                panel.append(line);
            }
        }
        requestAnimationFrame(measure);
        """
        STCallPageScript(web, probe, ["state":state,"count":commands], nil)
    }
}
