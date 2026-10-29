/// Set by the snapshot tests: offscreen rendering can't draw scroll views, so pages lay out flat instead.
public enum SnapshotMode { nonisolated(unsafe) public static var active = false }
