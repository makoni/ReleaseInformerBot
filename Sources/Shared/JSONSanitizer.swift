//
//  JSONSanitizer.swift
//  ReleaseInformerBot
//

import Foundation

/// Repairs iTunes API payloads that are not quite valid JSON.
public enum JSONSanitizer {
	/// Escapes raw control characters that appear inside JSON string literals.
	///
	/// Apple's `releaseNotes` regularly contain unescaped newlines, and occasionally other
	/// control characters, which `JSONDecoder` rejects outright. Because version lookups are
	/// batched, letting the response fail would leave every other app in the same request
	/// unchecked — so one malformed app must not be able to poison its batch.
	///
	/// Iteration is over Unicode scalars rather than `Character` on purpose: Swift treats
	/// CRLF as a single grapheme cluster, so a `Character`-based pass walks straight past it.
	public static func repairingControlCharacters(in input: String) -> String {
		var result = ""
		result.reserveCapacity(input.unicodeScalars.count)

		var isInsideString = false
		var isEscaped = false

		for scalar in input.unicodeScalars {
			if isEscaped {
				// Whatever follows a backslash is already escaped. Passing it through
				// verbatim is what stops a string ending in `\\` from being read as the
				// start of a new escape and desynchronising the rest of the document.
				result.unicodeScalars.append(scalar)
				isEscaped = false
				continue
			}

			switch scalar {
			case "\\" where isInsideString:
				result.unicodeScalars.append(scalar)
				isEscaped = true
			case "\"":
				isInsideString.toggle()
				result.unicodeScalars.append(scalar)
			default:
				if isInsideString {
					result += escaping(scalar)
				} else if scalar == "\u{00A0}" {
					// Not legal JSON whitespace between tokens.
					result.unicodeScalars.append(" ")
				} else {
					result.unicodeScalars.append(scalar)
				}
			}
		}

		return result
	}

	private static func escaping(_ scalar: Unicode.Scalar) -> String {
		switch scalar {
		case "\n": return "\\n"
		case "\t": return "\\t"
		case "\r": return "\\r"
		default:
			// Everything below U+0020 must be escaped; the rest — including the
			// non-breaking spaces Apple likes — is legal and is left exactly as written.
			guard scalar.value < 0x20 else { return String(scalar) }
			return String(format: "\\u%04x", scalar.value)
		}
	}
}
