#!/usr/bin/env swift

// Renders frames of design/Ollama Bar.dc.html into docs/images/ for the README.
//
// The mockup is plain inline-styled HTML, so a WKWebView snapshot is enough — no browser, no
// network, no design tool. Frames are pulled out by the HTML comment markers already in the file;
// the design's own Russian annotations are dropped and the captions come from here, in English.
//
// These are pictures of the design, not of the app — see docs/DESIGN_BRIEF.md for where the two
// deliberately differ. Re-run after re-exporting the mockup.
//
// Run: swift scripts/render-design.swift

import AppKit
import WebKit

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let mockup = root.appending(path: "design/Ollama Bar.dc.html")
let outputDir = root.appending(path: "docs/images")

guard let source = try? String(contentsOf: mockup, encoding: .utf8) else {
    FileHandle.standardError.write(Data("run me from the repo root: swift scripts/render-design.swift\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Pulling frames out of the mockup

/// The first balanced `<div>` following `marker`. The mockup nests only divs in these regions, so
/// counting tags is enough — no need to actually parse HTML.
func frame(after marker: String) -> String {
    guard let markerEnd = source.range(of: marker)?.upperBound,
          let start = source.range(of: "<div", range: markerEnd..<source.endIndex)?.lowerBound
    else { fatalError("no frame after \(marker) — did the mockup get re-exported?") }

    var depth = 0
    var i = start
    while i < source.endIndex {
        if source[i...].hasPrefix("<div") {
            depth += 1
            i = source.index(i, offsetBy: 4)
        } else if source[i...].hasPrefix("</div>") {
            depth -= 1
            i = source.index(i, offsetBy: 6)
            if depth == 0 { return String(source[start..<i]) }
        } else {
            i = source.index(after: i)
        }
    }
    fatalError("unbalanced markup after \(marker)")
}

/// Wraps a mockup frame so the page keeps only the artwork at `path` — the panel, the window, the
/// row of menu bar items — and drops the label above it and the design note below.
func figure(_ marker: String, keeping path: [Int] = [1], caption: String? = nil) -> String {
    let text = caption.map { "<figcaption>\($0)</figcaption>" } ?? ""
    let steps = path.map(String.init).joined(separator: ",")
    return #"<figure data-keep="\#(steps)">\#(frame(after: marker))\#(text)</figure>"#
}

// MARK: - Sheets

struct Sheet {
    let name: String
    let layout: String
    let body: String
    var script = ""
}

let menuBarLabels = ["not responding", "no models", "loaded, idle", "generating", "warning", "error"]

/// The mockup was drawn in Russian and a few strings live inside the artwork rather than in the
/// annotations around it. Rendering fails if any Cyrillic survives, so a re-export that adds copy
/// shows up here rather than in the README.
let translations = [
    "78% времени — загрузка модели":
        "78% of it was loading the model",
    "Без перехвата приложение показывает модели, память и скорость. Перехват добавляет промпт, живой вывод и обдумывание.":
        "Without interception you see models, memory and speed. Interception adds the prompt, the live output and the thinking.",
]

func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

let sheets = [
    Sheet(name: "panel-idle", layout: "row", body: figure("<!-- 3 idle -->")),
    Sheet(name: "panel-generating", layout: "row", body: figure("<!-- 5 generating + intercept -->")),
    Sheet(
        name: "panel-states",
        layout: "grid",
        body: [
            figure("<!-- 1 unreachable -->", caption: "server not responding"),
            figure("<!-- 2 no models -->", caption: "server up, nothing loaded"),
            figure("<!-- 4 generating, no intercept -->", caption: "generating, interception off"),
            figure("<!-- 6 thinking -->", caption: "thinking"),
            figure("<!-- 7 warning -->", caption: "warning"),
            figure("<!-- 8 error -->", caption: "request failed"),
        ].joined()
    ),
    Sheet(
        name: "menubar",
        layout: "row",
        body: figure("<!-- MENU BAR ITEM -->", keeping: [2]),
        // The design ships its own Russian captions under each variant; replace them in place so
        // the pills themselves stay exactly as drawn.
        script: """
        const labels = \(json(menuBarLabels));
        const row = document.querySelector('figure > div');
        [...row.children].forEach((item, i) => {
            const caption = item.children[1];
            caption.textContent = labels[i] ?? '';
            caption.style.color = '#8a8a8a';
            caption.style.fontFamily = "ui-monospace,'SF Mono',Menlo,monospace";
        });
        """
    ),
    Sheet(name: "window-output", layout: "wide", body: figure("<!-- WINDOWS -->", keeping: [0, 1])),
    Sheet(name: "window-history", layout: "wide", body: figure("<!-- WINDOWS -->", keeping: [1, 1])),
    Sheet(name: "settings", layout: "wide", body: figure("<!-- WINDOWS -->", keeping: [2, 1])),
]

// MARK: - Page

func page(_ sheet: Sheet) -> String {
    """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
      :root { color-scheme: light }
      * { animation: none !important }
      body {
        margin: 0; background: transparent; color: #111;
        font: 13px/1.4 -apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif;
      }
      .sheet { padding: 48px; align-items: start }
      .sheet.row { display: inline-flex; gap: 40px }
      .sheet.wide { display: inline-flex; padding: 64px }
      .sheet.grid { display: inline-grid; grid-template-columns: repeat(3, 340px); gap: 36px 40px }
      figure { margin: 0; display: flex; flex-direction: column; gap: 12px }
      figcaption {
        font: 11px/1 ui-monospace, 'SF Mono', Menlo, monospace;
        letter-spacing: .04em; color: #8a8a8a;
      }
    </style></head><body>
    <div class="sheet \(sheet.layout)">\(sheet.body)</div>
    <script>
      // Each mockup frame wraps its artwork in annotations — a label above, a design note below.
      // Walk down to the artwork itself and drop everything the design wrote around it.
      document.querySelectorAll('figure[data-keep]').forEach(figure => {
        const frame = figure.firstElementChild;
        const artwork = figure.dataset.keep.split(',').reduce((node, i) => node.children[+i], frame);
        figure.replaceChild(artwork, frame);
      });
      \(sheet.script)

      const translations = \(json(translations));
      const text = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      while (text.nextNode()) {
        const replacement = translations[text.currentNode.nodeValue.trim()];
        if (replacement) text.currentNode.nodeValue = replacement;
      }
      window.leftover = (document.body.innerText.match(/[^\\s]*[А-Яа-яЁё][^\\s]*/g) || []).join(' ');
    </script>
    </body></html>
    """
}

// MARK: - Rendering

final class Loader: NSObject, WKNavigationDelegate {
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}

func waiting(for done: () -> Bool) {
    let deadline = Date().addingTimeInterval(20)
    while !done(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let loader = Loader()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
webView.navigationDelegate = loader
webView.underPageBackgroundColor = .clear

let host = NSWindow(
    contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
host.isOpaque = false
host.backgroundColor = .clear
host.contentView = webView
host.setFrameOrigin(NSPoint(x: -9000, y: -9000))
host.orderFrontRegardless()

func evaluate(_ javaScript: String) -> Any? {
    var result: Any?
    var finished = false
    webView.evaluateJavaScript(javaScript) { value, _ in
        result = value
        finished = true
    }
    waiting { finished }
    return result
}

for sheet in sheets {
    loader.loaded = false
    webView.loadHTMLString(page(sheet), baseURL: nil)
    waiting { loader.loaded }

    // Let layout settle before measuring, or the first sheet snapshots short.
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))

    if let leftover = evaluate("window.leftover") as? String, !leftover.isEmpty {
        fatalError("\(sheet.name) still has Russian in the artwork — add it to `translations`: \(leftover)")
    }

    guard let size = evaluate(
        "const r = document.querySelector('.sheet').getBoundingClientRect(); [Math.ceil(r.width), Math.ceil(r.height)]"
    ) as? [Double], size.count == 2 else {
        fatalError("could not measure \(sheet.name)")
    }

    let rect = NSRect(x: 0, y: 0, width: size[0], height: size[1])
    host.setContentSize(rect.size)
    webView.frame = rect
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    let configuration = WKSnapshotConfiguration()
    configuration.rect = rect
    configuration.afterScreenUpdates = true

    var snapshot: NSImage?
    var finished = false
    webView.takeSnapshot(with: configuration) { image, error in
        if let error { FileHandle.standardError.write(Data("\(sheet.name): \(error)\n".utf8)) }
        snapshot = image
        finished = true
    }
    waiting { finished }

    guard let image = snapshot,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else { fatalError("no snapshot for \(sheet.name)") }

    // NSImage carries points; pin the rep to its own pixels so the PNG has no stray DPI.
    bitmap.size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(sheet.name)")
    }
    try png.write(to: outputDir.appending(path: "\(sheet.name).png"))
    print("\(sheet.name).png  \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
}
