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
        let from = zoom
        request = id
        zoom = factor
        let motion = PresetZoomMotion(started:0, initial:CGFloat(from), target:CGFloat(zoom), base:1, revision:revision)
        let frames = (0...18).map { index -> Double in
            let time = Double(index) / 18 * PresetZoomMotion.duration
            return Double(motion.factor(at:time))
        }
        report(web, frames:frames)
    }

    private func report(_ web: WKWebView, frames:[Double] = []) {
        let state: [String:Any] = ["ready":true,"busy":false,"formats":["HEIF"],"sizes":[12],
            "zoom":zoom,"zoomTarget":zoom,"zoomRequestID":request,"zoomSettling":false,
            "inputRevision":revision,"zoomRange":[0.5,15.0],"lenses":[0.5,1,2,3],"presentedZoomFrames":true,
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
                    hits.textContent += ' ' + [type, target, Math.round(event.clientX), Math.round(event.clientY)].join('/');
                }, {capture:true,passive:true});
            }
        }
        const receipt = document.createElement('div');
        panel.replaceChildren(receipt);
        const rail = document.querySelector('.capture-tools');
        const active = rail.querySelector('[data-step][aria-pressed=true]');
        receipt.textContent = ['zoom receipt', count, state.zoomRequestID, state.zoom, active?.dataset.step].join(' ');
        if (frames.length) {
            const buttons = Array.from(rail.querySelectorAll('[data-step]'));
            const stops = buttons.map(b => Number(b.dataset.step));
            const targetIndex = stops.indexOf(state.zoom);
            const center = b => { const r = b.getBoundingClientRect(); return r.x + r.width / 2; };
            const pitch = center(buttons[1]) - center(buttons[0]);
            const measuredSlot = () => targetIndex - (center(buttons[targetIndex]) - innerWidth / 2) / pitch;
            function expectedSlot(z) {
                const hi = stops.findIndex(s => s >= z);
                if (hi < 0) return stops.length - 1;
                if (hi === 0) return 0;
                return hi - 1 + Math.log(z / stops[hi-1]) / Math.log(stops[hi] / stops[hi-1]);
            }
            let maxError = Math.abs(measuredSlot() - expectedSlot(frames[0]));
            let between = 0;
            const start = performance.now(), low = Math.min(frames[0],state.zoom), high = Math.max(frames[0],state.zoom);
            const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));
            for (let i = 0; i < frames.length; i++) {
                const deadline = start + duration * 1000 * i / (frames.length-1);
                let now = await nextFrame();
                while (now < deadline) now = await nextFrame();
                if (!receipt.isConnected) return;
                const zoom = frames[i];
                window.receiveZoomFrame({inputRevision:state.inputRevision, zoomRequestID:state.zoomRequestID,
                                         zoom, settled:i === frames.length-1, presentedTime:now / 1000});
                const pos = measuredSlot();
                maxError = Math.max(maxError, Math.abs(pos - expectedSlot(zoom)));
                if (pos > expectedSlot(low) + .02 && pos < expectedSlot(high) - .02) between++;
            }
            const result = document.createElement('div');
            result.textContent = ['zoom frames',state.zoomRequestID,between,maxError.toFixed(4)].join(' ');
            panel.append(result);
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
        STCallPageScript(web, probe, ["state":state,"count":commands,"frames":frames,"duration":PresetZoomMotion.duration], nil)
    }
}
