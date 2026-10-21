import Foundation
import WebKit

/// How a message body is colored when the app is dark. Mail that brings its own dark styles is shown
/// as sent; other mail is either re-colored to suit the dark window ("adapted") or shown on a light
/// page exactly as the sender designed it ("original").
enum MessageAppearance {
	/// The app-wide default, on unless turned off in Settings.
	static let adaptKey = "adaptMessageColors"
	/// Per-sender choices made with the reader's toggle: address → adapt.
	static let overridesKey = "messageColorOverrides"

	static var adaptByDefault: Bool {
		UserDefaults.standard.object(forKey: adaptKey) as? Bool ?? true
	}

	/// Whether `sender`'s mail should be adapted: their own choice first, then the app default.
	static func adapts(sender: String) -> Bool {
		let overrides = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Bool]
		return overrides?[sender.lowercased()] ?? adaptByDefault
	}

	/// Remembers a choice for `sender`; one that matches the default is dropped rather than stored.
	static func setAdapts(_ adapt: Bool, sender: String) {
		var overrides = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Bool] ?? [:]
		overrides[sender.lowercased()] = adapt == adaptByDefault ? nil : adapt
		UserDefaults.standard.set(overrides, forKey: overridesKey)
	}

	/// Mail that declares its own dark styles, through a `prefers-color-scheme` media query or a
	/// `color-scheme` meta tag that lists dark, and is left alone.
	static func supportsDark(_ html: String) -> Bool {
		let lower = html.lowercased()
		if lower.contains("prefers-color-scheme") { return true }
		return lower.range(of: #"name=["']?(supported-)?color-scheme["']?[^>]*dark"#, options: .regularExpression) != nil
	}

	/// The re-coloring script. It runs in the app's own content world, so the page's JavaScript stays
	/// off, and does nothing unless the document is marked `data-adapt="1"`.
	static let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

	/// Light backgrounds are darkened (near-white ones become transparent, so they blend with the
	/// window), light borders follow, and text that would fall under 4.5:1 against the background it
	/// actually sits on is lightened. Hue is kept so brand colors stay recognizable. Anything inside an
	/// element painted with a background image or gradient is left as designed, as are images and SVG.
	private static let script = #"""
	(() => {
		const root = document.documentElement;
		const reveal = () => root.style.removeProperty("visibility");
		if (root.dataset.adapt !== "1") return reveal();
		const WINDOW = 0.009; // luminance of the dark window, #181818

		const parse = s => {
			const m = (s || "").match(/[\d.]+/g);
			if (!m || m.length < 3) return null;
			const a = m.length > 3 ? +m[3] : 1;
			return a === 0 ? null : { r: +m[0], g: +m[1], b: +m[2], a };
		};
		const lum = c => [c.r, c.g, c.b]
			.map(v => (v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
			.reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
		const contrast = (a, b) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
		const toHsl = ({ r, g, b }) => {
			r /= 255; g /= 255; b /= 255;
			const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
			if (max === min) return [0, 0, l * 100];
			const d = max - min, s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
			const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
			return [h * 60, s * 100, l * 100];
		};
		const fromHsl = (h, s, l, a) => {
			s /= 100; l /= 100;
			const k = n => (n + h / 30) % 12, f = n => l - s * Math.min(l, 1 - l) * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
			return { r: f(0) * 255, g: f(8) * 255, b: f(4) * 255, a };
		};
		const css = c => `rgba(${Math.round(c.r)},${Math.round(c.g)},${Math.round(c.b)},${c.a})`;
		const darken = c => {
			const [h, s, l] = toHsl(c);
			return fromHsl(h, s * 0.7, 10 + (100 - l) * 0.3, c.a);
		};
		const set = (el, prop, value) => el.style.setProperty(prop, value, "important");

		const bgOf = new WeakMap(); // element → luminance of the background it sits on, after changes
		const kept = new WeakSet(); // elements left as designed, with everything inside them
		const content = document.getElementById("c") || document.body;
		bgOf.set(content, WINDOW);

		for (const el of content.querySelectorAll("*")) {
			const parent = el.parentElement;
			if (kept.has(parent) || el instanceof SVGElement || el.tagName === "IMG") { kept.add(el); continue; }
			const cs = getComputedStyle(el);
			if (cs.backgroundImage !== "none") { kept.add(el); continue; }

			let behind = bgOf.get(parent) ?? WINDOW;
			const bg = parse(cs.backgroundColor);
			if (bg) {
				const l = lum(bg);
				if (l > 0.2) {
					const [, s, light] = toHsl(bg);
					if (light > 96 && s < 20) set(el, "background-color", "transparent");
					else { const d = darken(bg); set(el, "background-color", css(d)); behind = lum(d) * d.a + behind * (1 - d.a); }
				} else behind = l * bg.a + behind * (1 - bg.a);
			}
			bgOf.set(el, behind);

			for (const side of ["top", "right", "bottom", "left"]) {
				if (cs.getPropertyValue(`border-${side}-style`) === "none") continue;
				const border = parse(cs.getPropertyValue(`border-${side}-color`));
				if (border && lum(border) > 0.3) set(el, `border-${side}-color`, css(darken(border)));
			}

			const fg = parse(cs.color);
			if (fg && behind < 0.18 && contrast(lum(fg), behind) < 4.5) {
				const [h, s] = toHsl(fg);
				let l = Math.max(70, 100 - toHsl(fg)[2]), next = fromHsl(h, s, l, 1);
				while (contrast(lum(next), behind) < 4.5 && l < 96) next = fromHsl(h, s, l += 4, 1);
				set(el, "color", css(next));
			}
		}
		reveal();
	})();
	"""#
}
