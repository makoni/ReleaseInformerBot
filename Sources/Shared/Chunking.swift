//
//  Chunking.swift
//  ReleaseInformerBot
//

public extension Array {
	/// Splits the array into runs of at most `size` elements, preserving order.
	func chunked(into size: Int) -> [[Element]] {
		guard size > 0 else { return isEmpty ? [] : [self] }

		return stride(from: 0, to: count, by: size).map { start in
			Array(self[start..<Swift.min(start + size, count)])
		}
	}
}
