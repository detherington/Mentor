import AppKit
import Foundation

/// The page the browser shows when Orbis sign-in redirects back to Pepper,
/// styled like the setup walkthrough's black welcome (and Muesli's page of
/// the same name): the app's icon, a Neon kicker, then a headline pairing
/// the expanded display face with the serif, uppercase at −2% tracking and
/// 100% leading, and one line of body text — three type sizes. Self-
/// contained: the icon is inlined from the app bundle and the brand faces
/// are asked for by name with system fallbacks; the licensed font file is
/// never put in a page. The provider's own error wording is never echoed.
enum SignInPage {
    enum Outcome {
        case signedIn, failed, waiting
    }

    static func html(_ outcome: Outcome) -> String {
        let (display, serif, detail, kicker): (String, String, String, String)
        switch outcome {
        case .signedIn:
            (display, serif, detail, kicker) = ("Signed in", "to Orbis", "You can close this window and go back to Pepper.", "kicker")
        case .failed:
            (display, serif, detail, kicker) = ("Sign-in", "didn’t finish", "You can close this window and try again in Pepper.", "kicker quiet")
        case .waiting:
            (display, serif, detail, kicker) = ("Waiting", "for sign-in", "Finish signing in, then come back to Pepper.", "kicker")
        }
        let icon = iconDataURI.map { "<img class=\"icon\" src=\"\($0)\" alt=\"\">" } ?? ""
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Pepper</title>
        <style>\(css)</style>
        </head><body><main>
        \(icon)
        <p class="\(kicker)">Pepper</p>
        <h1><span class="display">\(display)</span><span class="serif">\(serif)</span></h1>
        <p class="detail">\(detail)</p>
        </main></body></html>
        """
    }

    /// Brand tokens as in `Brand.swift`: black ground, Neon kicker, white at
    /// 72% for body; 12 / 48 / 18 px.
    private static let css = """
    :root{color-scheme:dark}
    *{box-sizing:border-box}
    html,body{height:100%;margin:0}
    body{display:flex;align-items:center;justify-content:center;padding:48px 24px;background:#000;color:#fff;\
    text-align:center;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;\
    -webkit-font-smoothing:antialiased}
    main{max-width:640px}
    .icon{display:block;width:128px;height:128px;margin:0 auto 32px;border-radius:22.5%}
    .kicker{margin:0 0 20px;font-size:12px;font-weight:600;font-stretch:expanded;letter-spacing:.06em;\
    text-transform:uppercase;color:#CEFF58}
    .kicker.quiet{color:rgba(255,255,255,.55)}
    h1{margin:0;font-size:48px;font-weight:normal;line-height:1;letter-spacing:-.02em;text-transform:uppercase}
    h1 span{display:block}
    .display{font-family:"Maison Neue Extended","MaisonNeueExtended-Demi",-apple-system,BlinkMacSystemFont,\
    "Arial Black",sans-serif;font-weight:600;font-stretch:expanded}
    .serif{font-family:"Nantes","Nantes-Light",ui-serif,"New York",Georgia,"Times New Roman",serif;font-weight:300}
    .detail{margin:28px auto 0;max-width:440px;font-size:18px;line-height:1.5;color:rgba(255,255,255,.72)}
    """

    /// Pepper's icon as a 256 px PNG data URI, read once from the app
    /// bundle. The file is square artwork (macOS rounds the corners when it
    /// shows an icon), so the page rounds them the same way.
    private static let iconDataURI: String? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        let side = 256
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()
}
