// ============================================================================
// Rising You — Vite configuratie
// ----------------------------------------------------------------------------
// De vier schermen zijn aparte HTML-pagina's. Vite bundelt ze samen tot één
// app. De tabs bovenaan navigeren tussen deze pagina's.
// ============================================================================

import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  // Tauri verwacht een vaste poort tijdens ontwikkeling.
  server: {
    port: 5173,
    strictPort: true,
    watch: {
      ignored: ['**/src-tauri/**'],
    },
  },
  // Voorkom dat Vite de env-variabelen weggooit die Tauri nodig heeft.
  envPrefix: ['VITE_', 'TAURI_'],
  build: {
    outDir: 'dist',
    // Deze app draait uitsluitend in Tauri's eigen (moderne) WebView2, nooit
    // in willekeurige browsers — dus mag het build-target de nieuwste
    // syntax (o.a. top-level await in de opstartcode van elk scherm) gewoon
    // laten staan i.p.v. te transpileren naar oudere browsers.
    target: 'esnext',
    // Elk scherm is een eigen ingang.
    rollupOptions: {
      input: {
        checkin: resolve(__dirname, 'index.html'),
        ledenbeheer: resolve(__dirname, 'ledenbeheer.html'),
        admin: resolve(__dirname, 'admin-portaal.html'),
        registratie: resolve(__dirname, 'registratie.html'),
      },
    },
  },
});
