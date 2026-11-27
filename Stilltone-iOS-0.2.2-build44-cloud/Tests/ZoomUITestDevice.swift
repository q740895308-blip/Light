import Foundation
import AVFoundation
import WebKit

// The image spans the rear rig's full ultrawide field of view. Each bar has a
// physical width of 1/32 of that field, independent of the chosen UI preset.
private enum ZoomTestChart {
    static func sample(at displayZoom: Double) -> CMSampleBuffer? {
        let base = rearWideZoomBase(wideIndex:1,switchOverFactors:[2,6],displayMultiplier:1)
        let width = 768, height = 1024
        let factor = max(1,displayZoom * Double(base))
        let span = min(width,Int((Double(width)*factor/32).rounded()))
        let start = (width-span)/2
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString:Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String:Any],
                                           kCVPixelBufferMetalCompatibilityKey:true]
        guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer, CVPixelBufferLockBaseAddress(buffer,[]) == kCVReturnSuccess else { return nil }
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer), row = address.assumingMemoryBound(to:UInt32.self)
            for x in 0..<width { row[x] = x >= start && x < start+span ? 0xff00ff00 : 0xff000000 }
            for y in 1..<height { memcpy(address.advanced(by:y*stride),address,width*4) }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,
                  formatDescriptionOut:&description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:60),
                           presentationTimeStamp:CMClockGetTime(CMClockGetHostTimeClock()),decodeTimeStamp:.invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,
                formatDescription:description,sampleTiming:&timing,sampleBufferOut:&sample) == noErr else { return nil }
        return sample
    }
}

// Built only in the temporary simulator UI-test copy.
final class ZoomUITestDevice {
    static let previewRecipe = Recipe(aspect:"4:3",look:.FL2,strength:0.1)
    let enabled = ProcessInfo.processInfo.arguments.contains("-zoom-ui-test")
    let testsVideoMode = ProcessInfo.processInfo.arguments.contains("-video-mode-ui-test")
    private var videoMode = false
    private var modeCommands = 0
    private let revision = 73
    private var request = 20
    private var zoom = 1.0
    private var commands = 0
    private weak var publishedWeb: WKWebView?

    private weak var camera: Camera?

    func publish(_ web: WKWebView, camera: Camera) {
        guard publishedWeb !== web else { return }
        publishedWeb = web
        self.camera = camera
        expose(at:zoom)
        report(web)
    }

    private func expose(at factor: Double) {
        guard let camera, let sample = ZoomTestChart.sample(at:factor) else { return }
        camera.receiveZoomTestSample(sample)
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
            if index == 18 { return factor }
            return from * exp2((factor >= from ? 1 : -1) * Double(motion.rate) * time)
        }
        report(web, frames:frames)
        for (index, value) in frames.enumerated() {
            let time = Double(index) / Double(frames.count-1) * PresetZoomMotion.duration
            DispatchQueue.main.asyncAfter(deadline:.now()+time) { [weak self] in
                guard self?.request == id else { return }
                self?.expose(at:value)
            }
        }
    }

    func acceptVideoMode(_ payload: [String:Any], in web: WKWebView) {
        guard let enabled = payload["enabled"] as? Bool else { return }
        modeCommands += 1
        videoMode = enabled
        report(web)
    }

    private func report(_ web: WKWebView, frames:[Double] = []) {
        var state: [String:Any] = ["ready":true,"busy":false,"formats":["HEIF"],"sizes":[12],
            "zoom":frames.first ?? zoom,"zoomTarget":zoom,"zoomRequestID":request,"zoomSettling":!frames.isEmpty,
            "inputRevision":revision,"zoomRange":[0.5,15.0],"lenses":[0.5,1,2,3],"presentedZoomFrames":true,
            "opticalZoomStops":[0.5,1,3],"live":false,"flash":false,"biasLimits":[-2,2]]
        if testsVideoMode {
            state["videoMode"] = videoMode
            state["videoState"] = "idle"
            state["videoResolution"] = "HD"
            state["videoFPS"] = 30
            state["videoChoices"] = ["HD":[30]]
        }
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
        if (typeof state.videoMode === 'boolean') {
            function measureMode() {
                if (!receipt.isConnected) return;
                const mode = document.querySelector('.mode'), choice = mode.querySelector('[aria-pressed=true]');
                const box = mode.getBoundingClientRect(), chosen = choice.getBoundingClientRect();
                const x = box.x + box.width / 2, y = box.y + box.height / 2;
                if (Math.abs(chosen.x + chosen.width / 2 - x) >= 1) { requestAnimationFrame(measureMode); return; }
                const stage = document.querySelector('.stage');
                const line = document.createElement('div');
                line.textContent = ['mode receipt', modeCount, choice.textContent, stage.dataset.format,
                                    (x/innerWidth).toFixed(6), (y/innerHeight).toFixed(6)].join(' ');
                panel.append(line);
            }
            requestAnimationFrame(measureMode);
        }
        const rail = document.querySelector('.capture-tools');
        const active = rail.querySelector('[data-step][aria-pressed=true]');
        receipt.textContent = ['zoom receipt', count, state.zoomRequestID, state.zoomTarget, active?.dataset.step].join(' ');
        if (frames.length) {
            const buttons = Array.from(rail.querySelectorAll('[data-step]'));
            const stops = buttons.map(b => Number(b.dataset.step));
            const targetIndex = stops.indexOf(state.zoomTarget);
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
            const start = performance.now(), low = Math.min(frames[0],state.zoomTarget), high = Math.max(frames[0],state.zoomTarget);
            let deviceSettled = false;
            function finishDevice() {
                if (deviceSettled || !receipt.isConnected) return;
                deviceSettled = true;
                window.receiveCamera({...state,zoom:state.zoomTarget,zoomSettling:false});
            }
            const endpoint = setTimeout(finishDevice,duration*1000);
            const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));
            for (let i = 0; i < frames.length; i++) {
                const deadline = start + duration * 1000 * i / (frames.length-1);
                let now = await nextFrame();
                while (now < deadline) now = await nextFrame();
                if (!receipt.isConnected) return;
                const zoom = frames[i];
                if (i === frames.length-1) { clearTimeout(endpoint); finishDevice(); }
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
        STCallPageScript(web, probe, ["state":state,"count":commands,"modeCount":modeCommands,"frames":frames,"duration":PresetZoomMotion.duration], nil)
    }
}
