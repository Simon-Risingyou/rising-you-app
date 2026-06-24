// ============================================================================
// Rising You — Tauri applicatie-opzet
// ----------------------------------------------------------------------------
// Registreert de plugins. De 'updater'-plugin maakt het mogelijk dat jij op
// afstand een nieuwe versie publiceert (via GitHub Releases) en de kassa-pc's
// die automatisch oppikken — precies wat je wou: lokaal draaien, maar door jou
// op afstand te beheren en te updaten.
// ============================================================================

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .run(tauri::generate_context!())
        .expect("Fout bij het starten van Rising You Ledenbeheer");
}
