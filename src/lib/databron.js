// ============================================================================
// Rising You — Databron
// ----------------------------------------------------------------------------
// Dit is de ENIGE laag waar de schermen mee praten om data op te halen of weg
// te schrijven. De schermen weten niets van Supabase af; ze roepen functies
// zoals `zoekLeden`, `verwerkScan` of `wijsToeAanSessie` aan.
//
// Voordeel: alle businesslogica zit al in de database (de migraties 0001-0010).
// Deze module roept die DB-functies (rpc) aan. Zo gedragen de desktop-app en
// de toekomstige website zich identiek, want ze gebruiken dezelfde logica.
//
// Bij verbindingsproblemen valt het ophalen terug op de lokale cache, en
// worden check-ins in de wachtrij gezet (zie lib/offline.js).
// ============================================================================

import { supabase } from './supabase.js';
import {
  leesCache, schrijfCache,
  voegToeAanWachtrij, leesWachtrij, verwijderUitWachtrij,
} from './offline.js';

// ----------------------------------------------------------------------------
// LEDEN
// ----------------------------------------------------------------------------

// Zoek leden op naam (gebruikt de DB-functie fn_zoek_leden uit migratie 0004).
export async function zoekLeden(zoekterm) {
  const { data, error } = await supabase.rpc('fn_zoek_leden', { p_zoekterm: zoekterm });
  if (error) throw error;
  return data;
}

// Haal één lid met al zijn tegoed (beurtenkaarten + abonnementen per activiteit).
export async function haalLid(lidId) {
  const { data, error } = await supabase
    .from('leden')
    .select(`
      *,
      beurtenkaarten ( id, activiteit, tarief, beurten_resterend, actief ),
      abonnementen ( id, activiteit, tarief, start_datum, eind_datum, actief ),
      gezinsleden ( gezin_id, rol )
    `)
    .eq('id', lidId)
    .single();
  if (error) throw error;
  return data;
}

// Beschikbaar tegoed voor een lid + activiteit (DB-functie fn_beschikbaar_tegoed).
export async function beschikbaarTegoed(lidId, activiteit) {
  const { data, error } = await supabase.rpc('fn_beschikbaar_tegoed', {
    p_lid_id: lidId, p_activiteit: activiteit,
  });
  if (error) throw error;
  return data?.[0] ?? null;
}

// ----------------------------------------------------------------------------
// CHECK-IN (scannen)
// ----------------------------------------------------------------------------

// Verwerk een gescande QR-code. Probeert online; valt bij problemen terug op
// de cache zodat de kassa blijft werken, en zet de check-in in de wachtrij.
export async function verwerkScan(qrCode, medewerkerId, bron = 'kassa') {
  try {
    const { data, error } = await supabase.rpc('fn_verwerk_scan', {
      p_qr_code: qrCode,
      p_medewerker_id: medewerkerId,
      p_bron: bron,
    });
    if (error) throw error;
    return { online: true, ...data };
  } catch (e) {
    // Offline-vangnet: zoek het lid in de cache en zet de scan in de wachtrij.
    const cache = leesCache();
    const lid = cache?.leden?.find((l) => l.qr === qrCode);
    if (!lid) throw new Error('Onbekende code (en geen internet om te controleren).');
    voegToeAanWachtrij({ soort: 'scan', qrCode, medewerkerId, bron });
    return { online: false, lid };
  }
}

// Wijs een ingecheckt lid toe aan een sessie (hier wordt de beurt afgeboekt
// volgens de juiste activiteit). DB-functie regelt de aftreklogica.
export async function wijsToeAanSessie({ checkinId, sessieId, activiteit, betaalwijze, geleendVanLidId, medewerkerId }) {
  const { data, error } = await supabase.rpc('fn_wijs_toe_aan_sessie', {
    p_checkin_id: checkinId,
    p_sessie_id: sessieId,
    p_activiteit: activiteit,
    p_betaalwijze: betaalwijze,
    p_geleend_van_lid_id: geleendVanLidId ?? null,
    p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// ----------------------------------------------------------------------------
// SESSIES (van vandaag)
// ----------------------------------------------------------------------------

export async function sessiesVandaag(datum = new Date().toISOString().slice(0, 10)) {
  try {
    const { data, error } = await supabase.rpc('fn_momenten_van_dag', { p_datum: datum });
    if (error) throw error;
    return data;
  } catch {
    // Offline: gebruik de gecachte sessies.
    return leesCache()?.sessies_vandaag ?? [];
  }
}

// ----------------------------------------------------------------------------
// GEZINNEN
// ----------------------------------------------------------------------------

export async function gezinVanLid(lidId) {
  const { data, error } = await supabase.rpc('fn_gezin_van_lid', { p_lid_id: lidId });
  if (error) throw error;
  return data;
}

export async function leenbareGezinsbeurten(lidId, activiteit) {
  const { data, error } = await supabase.rpc('fn_leenbare_gezinsbeurten', {
    p_lid_id: lidId, p_activiteit: activiteit,
  });
  if (error) throw error;
  return data;
}

// ----------------------------------------------------------------------------
// ADMIN PORTAAL
// ----------------------------------------------------------------------------

export async function nieuweAccounts() {
  const { data, error } = await supabase
    .from('leden')
    .select('id, voornaam, achternaam, geboortejaar, postcode, herkomst, bron, aangemaakt_op')
    .eq('goedkeuring', 'nieuw')
    .order('aangemaakt_op', { ascending: false });
  if (error) throw error;
  return data;
}

export async function keurAccountGoed(lidId, medewerkerId) {
  const { error } = await supabase.rpc('fn_keur_account_goed', {
    p_lid_id: lidId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
}

export async function wijsAccountAf(lidId, medewerkerId) {
  const { error } = await supabase.rpc('fn_wijs_account_af', {
    p_lid_id: lidId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
}

export async function recenteWijzigingen(limiet = 100) {
  const { data, error } = await supabase
    .from('handelingen_log')
    .select('tijdstip, handeling, omschrijving, lid_id, medewerker_id, leden(voornaam, achternaam), medewerkers(naam)')
    .order('tijdstip', { ascending: false })
    .limit(limiet);
  if (error) throw error;
  return data;
}

// ----------------------------------------------------------------------------
// SYNCHRONISATIE
// ----------------------------------------------------------------------------

// Haal de gegevens op die de kassa offline nodig heeft en zet ze in de cache.
export async function vulCache() {
  try {
    const [{ data: leden }, { data: sessies }] = await Promise.all([
      supabase.from('leden').select('id, voornaam, achternaam, qr, sociaal_tarief, geboortejaar'),
      supabase.rpc('fn_momenten_van_dag', { p_datum: new Date().toISOString().slice(0, 10) }),
    ]);
    schrijfCache({ leden: leden ?? [], sessies_vandaag: sessies ?? [] });
    return true;
  } catch (e) {
    console.warn('Cache vullen mislukt (waarschijnlijk offline):', e.message);
    return false;
  }
}

// Werk de wachtrij af zodra er weer verbinding is.
export async function synchroniseerWachtrij() {
  const rij = leesWachtrij();
  for (const actie of rij) {
    try {
      if (actie.soort === 'scan') {
        await supabase.rpc('fn_verwerk_scan', {
          p_qr_code: actie.qrCode,
          p_medewerker_id: actie.medewerkerId,
          p_bron: actie.bron,
        });
      }
      // (andere actie-soorten kunnen hier later toegevoegd worden)
      verwijderUitWachtrij(actie.lokaal_id);
    } catch (e) {
      // Stop bij de eerste fout: waarschijnlijk nog offline. Probeer later opnieuw.
      console.warn('Synchronisatie onderbroken, probeer later opnieuw.');
      break;
    }
  }
}
