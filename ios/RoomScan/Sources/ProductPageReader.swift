import Foundation
import WebKit

/// Reads a product page the way the phone's browser would: loads it in a hidden web view (so the
/// page's own scripts run, which is where Target puts its price, and bot checks see a real phone),
/// then pulls the name, price, photo and dimensions out of the finished page.
@MainActor
final class ProductPageReader {
    struct Found {
        var name: String?
        var price: Double?
        var store: String
        var url: String
        var image: String?
        var dimensions: String?
        var blocked: Bool
    }

    enum ReadError: LocalizedError {
        case nothing, blocked(String)
        var errorDescription: String? {
            switch self {
            case .nothing: return "Couldn't find a product on that page."
            case let .blocked(store): return "\(store) showed a robot check instead of the product. "
                + "Open the link in Safari, then try again, or type the product in."
            }
        }
    }

    private var webView: WKWebView?

    /// Up to about 15 seconds: waits for the page to load, then looks every second until it has
    /// both a name and a price.
    func read(_ url: URL) async throws -> Found {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView = web
        defer {
            web.stopLoading()
            webView = nil
        }
        web.load(URLRequest(url: url))
        var best: Found?
        for i in 0..<15 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if web.isLoading && i < 5 { continue }
            guard let json = try? await web.evaluateJavaScript(Self.script) as? String,
                  let found = Self.parse(json, page: url) else { continue }
            if best == nil || found.name != nil { best = found }
            if found.name != nil, found.price != nil, !found.blocked { break }
        }
        guard let best else { throw ReadError.nothing }
        if best.blocked { throw ReadError.blocked(best.store) }
        guard best.name != nil else { throw ReadError.nothing }
        return best
    }

    private static func parse(_ json: String, page: URL) -> Found? {
        guard let data = json.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            let v = (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return v?.isEmpty == false ? v : nil
        }
        var price: Double?
        if let n = d["price"] as? NSNumber { price = n.doubleValue }
        if let s = d["price"] as? String { price = Double(s.replacingOccurrences(of: ",", with: "")) }
        let store = storeName(page.host ?? "")
        return Found(name: str("name").map { cleanName($0, store: store) }, price: price, store: store,
                     url: str("url") ?? page.absoluteString, image: str("image"), dimensions: str("dimensions"),
                     blocked: d["blocked"] as? Bool ?? false)
    }

    static func storeName(_ host: String) -> String {
        let h = host.lowercased()
        if h.contains("containerstore") { return "Container Store" }
        if h.contains("target.com") { return "Target" }
        if h.contains("amazon.") || h.contains("amzn.") { return "Amazon" }
        if h.contains("walmart") { return "Walmart" }
        if h.contains("neatmethod") { return "Neat Method" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Drop the " : Target" / " | The Container Store" / " : Amazon.com" tails page titles carry.
    private static func cleanName(_ name: String, store: String) -> String {
        var n = name
        for tail in [" : Target", " | The Container Store", " | Container Store", " : Amazon.com", " - Amazon.com",
                     " | Walmart.com", " - Walmart.com"] where n.hasSuffix(tail) {
            n = String(n.dropLast(tail.count))
        }
        if n.hasPrefix("Amazon.com: ") { n = String(n.dropFirst("Amazon.com: ".count)) }
        return n.trimmingCharacters(in: .whitespaces)
    }

    /// Runs in the page: schema.org Product data first, then Open Graph tags, then what's on screen.
    private static let script = #"""
    (() => {
      const out = {};
      const q = s => document.querySelector(s);
      const meta = n => { const m = q(`meta[property="${n}"],meta[name="${n}"],meta[itemprop="${n}"]`); return m ? m.getAttribute('content') : null; };
      for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
        try {
          const d = JSON.parse(s.textContent);
          const list = Array.isArray(d) ? d : (d['@graph'] || [d]);
          for (const it of list) {
            const t = it && it['@type'];
            if (!(t === 'Product' || (Array.isArray(t) && t.includes('Product')))) continue;
            out.name = out.name || it.name;
            const img = Array.isArray(it.image) ? it.image[0] : it.image;
            out.image = out.image || (img && img.url) || img;
            let o = it.offers; if (Array.isArray(o)) o = o[0];
            if (o) out.price = out.price || o.price || o.lowPrice;
          }
        } catch (e) {}
      }
      out.name = out.name || meta('og:title') || (q('h1') && q('h1').innerText);
      out.image = out.image || meta('og:image');
      out.price = out.price || meta('product:price:amount') || meta('og:price:amount') || meta('price');
      if (!out.price) {
        for (const e of document.querySelectorAll('[data-test*="price" i],[class*="price" i],[itemprop="price"],#corePrice_feature_div')) {
          const m = (e.innerText || '').match(/\$\s?(\d{1,4}(?:,\d{3})*(?:\.\d{2})?)/);
          if (m) { out.price = m[1]; break; }
        }
      }
      const text = document.body ? document.body.innerText : '';
      const dm = text.match(/Dimensions[^:\n]{0,30}:\s*([^\n]{3,120})/i);
      if (dm) out.dimensions = dm[1].trim();
      out.url = meta('og:url') || location.href;
      out.blocked = /access to this page has been denied|are you a robot|captcha|sorry for the wait|unusual traffic/i.test(document.title + ' ' + text.slice(0, 600));
      if (out.price != null) out.price = String(out.price).replace(/[^0-9.]/g, '');
      return JSON.stringify(out);
    })()
    """#
}
