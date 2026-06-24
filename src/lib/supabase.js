// ============================================================================
// Rising You — Supabase client
// ----------------------------------------------------------------------------
// Eén centrale plek waar de verbinding met Supabase wordt opgezet. Alle andere
// modules importeren 'supabase' hiervandaan, zodat er maar één verbinding is.
//
// De sleutels komen uit omgevingsvariabelen (.env), NOOIT hardgecodeerd in de
// code. Zie .env.example voor welke variabelen je moet invullen.
// ============================================================================

import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  // Een duidelijke fout is beter dan een vage crash later.
  console.error(
    'Supabase-instellingen ontbreken. Vul VITE_SUPABASE_URL en ' +
    'VITE_SUPABASE_ANON_KEY in je .env-bestand in (zie .env.example).'
  );
}

export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
  },
});

// Handige helper: is de app op dit moment online verbonden met Supabase?
// (De echte offline-afhandeling zit in lib/offline.js.)
export async function supabaseBereikbaar() {
  try {
    const { error } = await supabase.from('activiteiten').select('code').limit(1);
    return !error;
  } catch {
    return false;
  }
}
