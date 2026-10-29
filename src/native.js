// Running inside the Hermit desktop app (Tauri) rather than a browser.
// The app shows the bare UI (no demo stage) and draws under the native macOS title bar.
export const isApp = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window
