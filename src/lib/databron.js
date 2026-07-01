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
  const { data, error } = await supabase.rpc('fn_zoek_leden', { p_zoek: zoekterm });
  if (error) throw error;
  return data;
}

// Haal één lid met al zijn tegoed (beurtenkaarten + abonnementen per activiteit).
// Loopt via fn_haal_lid (security definer), niet rechtstreeks op de tabel, zodat
// RLS de leden-tabel kan afschermen en enkel de nodige velden meekomen.
export async function haalLid(lidId) {
  const { data, error } = await supabase.rpc('fn_haal_lid', { p_lid_id: lidId });
  if (error) throw error;
  return data;
}

// --- Ledenbeheer: bewerken ---

// Tarieftype handmatig zetten ('kind' | 'student' | 'volwassene').
export async function zetTarieftype(lidId, tarief, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_zet_tarieftype', {
    p_lid_id: lidId, p_tarief: tarief, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Sociaal tarief aan/uit zetten.
export async function zetSociaalTarief(lidId, sociaal, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_zet_sociaal_tarief', {
    p_lid_id: lidId, p_sociaal: sociaal, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Basisgegevens bijwerken.
export async function wijzigLid(lidId, velden, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_wijzig_lid', {
    p_lid_id: lidId,
    p_voornaam: velden.voornaam,
    p_achternaam: velden.achternaam,
    p_geboortejaar: velden.geboortejaar,
    p_postcode: velden.postcode,
    p_herkomst: velden.herkomst,
    p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Beurtenkaart opladen (activiteit + aantal; tarief null = tarief van het lid).
export async function laadBeurtenkaart(lidId, aantal, activiteit, tarief, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_laad_beurtenkaart', {
    p_lid_id: lidId, p_aantal: aantal, p_activiteit: activiteit,
    p_tarief: tarief ?? null, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Abonnement opladen (duur '3_maanden'|'6_maanden'|'12_maanden', startdatum, activiteit).
export async function laadAbonnement(lidId, duur, startDatum, activiteit, tarief, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_laad_abonnement', {
    p_lid_id: lidId, p_duur: duur, p_start: startDatum, p_activiteit: activiteit,
    p_tarief: tarief ?? null, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Nieuw QR-kaartje aanmaken (failsafe: maakt oude kaartjes ongeldig). Geeft het
// nieuwe qr_token terug.
export async function nieuwKaartje(lidId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_nieuw_kaartje', {
    p_lid_id: lidId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;   // het nieuwe token (text)
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
export async function verwerkScan(qrToken, medewerkerId) {
  try {
    const { data, error } = await supabase.rpc('fn_verwerk_scan', {
      p_qr_token: qrToken,
      p_medewerker_id: medewerkerId,
    });
    if (error) throw error;
    // fn_verwerk_scan RETURNS TABLE -> data is een array met één rij.
    const rij = Array.isArray(data) ? data[0] : data;
    return { online: true, ...rij };
  } catch (e) {
    // Offline-vangnet: zoek het lid in de cache en zet de scan in de wachtrij.
    const cache = leesCache();
    const lid = cache?.leden?.find((l) => l.qr === qrToken);
    if (!lid) throw new Error('Onbekende code (en geen internet om te controleren).');
    voegToeAanWachtrij({ soort: 'scan', qrToken, medewerkerId });
    return { online: false, lid };
  }
}

// Check een lid handmatig in (zonder scan), bv. via zoeken aan de kassa.
// p_soort: 'check_in' (normaal) of 'alleen_info' (enkel profiel tonen).
export async function checkInLid(lidId, medewerkerId, soort = 'check_in') {
  const { data, error } = await supabase.rpc('fn_checkin_lid', {
    p_lid_id: lidId,
    p_medewerker_id: medewerkerId,
    p_soort: soort,
  });
  if (error) throw error;
  return Array.isArray(data) ? data[0] : data;
}

// Vink iets af in de wachtkamer (bv. betaling of A-Kaart).
export async function vinkAf(checkinId, wat, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_vink_af', {
    p_checkin_id: checkinId,
    p_wat: wat,
    p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Rond een wachtkamer-check-in af: wijs toe aan een losse klimsessie of clubsessie.
// De database boekt de juiste beurt af volgens activiteit + betaalwijze, en
// ondersteunt een geleende beurtenkaart. Per persoon één aanroep.
//   toewijzing:   'losse_klimsessie' of 'clubsessie'
//   betaalwijze:  'tegoed' (abo/beurt) of 'los' (cash aan de kassa)
//   geleendVanKaartId: optioneel, de beurtenkaart van een gezinslid
export async function rondWachtkamerAf({ checkinId, toewijzing, clubsessieId, activiteit, betaalwijze, geleendVanKaartId, medewerkerId }) {
  const { data, error } = await supabase.rpc('fn_rond_wachtkamer_af', {
    p_checkin_id: checkinId,
    p_toewijzing: toewijzing,
    p_clubsessie_id: clubsessieId ?? null,
    p_activiteit: activiteit,
    p_betaalwijze: betaalwijze,
    p_geleend_van_kaart_id: geleendVanKaartId ?? null,
    p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Annuleer een check-in (bv. verkeerd gescand).
export async function annuleerCheckin(checkinId, medewerkerId, reden = '') {
  const { error } = await supabase.rpc('fn_annuleer_checkin', {
    p_checkin_id: checkinId,
    p_medewerker_id: medewerkerId,
    p_reden: reden,
  });
  if (error) throw error;
}

// Zet een toegewezen check-in terug naar de wachtkamer (geeft de beurt terug).
export async function herstelNaarWachtkamer(checkinId, medewerkerId) {
  const { error } = await supabase.rpc('fn_herstel_naar_wachtkamer', {
    p_checkin_id: checkinId,
    p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
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

// --- Gezinnen beheren (ledenbeheer) ---

// Nieuw gezin aanmaken. Geeft het nieuwe gezin_id terug.
export async function maakGezin(naam, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_maak_gezin', {
    p_naam: naam, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Lid toevoegen aan een gezin met een rol ('voogd' | 'kind' | 'lid').
export async function voegToeAanGezin(gezinId, lidId, rol, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_voeg_toe_aan_gezin', {
    p_gezin_id: gezinId, p_lid_id: lidId, p_rol: rol, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Lid uit zijn gezin halen.
export async function verwijderUitGezin(lidId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_verwijder_uit_gezin', {
    p_lid_id: lidId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// --- Activiteiten (gedeeld door alle schermen) ---

export async function alleActiviteiten() {
  const { data, error } = await supabase.rpc('fn_alle_activiteiten');
  if (error) throw error;
  return data;
}

// Actieve medewerkers ophalen (voor de kassa-kiezer).
export async function actieveMedewerkers() {
  const { data, error } = await supabase.rpc('fn_actieve_medewerkers');
  if (error) throw error;
  return data;
}

// --- Medewerkersbeheer (admin portaal) ---

export async function alleMedewerkers() {
  const { data, error } = await supabase.rpc('fn_alle_medewerkers');
  if (error) throw error;
  return data;
}

export async function maakMedewerker(voornaam, achternaam, isAdmin, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_maak_medewerker', {
    p_voornaam: voornaam, p_achternaam: achternaam ?? null,
    p_is_admin: isAdmin, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function deactiveerMedewerker(doelId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_deactiveer_medewerker', {
    p_doel_id: doelId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function zetAdminRechten(doelId, isAdmin, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_zet_admin_rechten', {
    p_doel_id: doelId, p_is_admin: isAdmin, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function zetAdminWachtwoord(doelId, nieuwWachtwoord) {
  const { data, error } = await supabase.rpc('fn_zet_admin_wachtwoord', {
    p_medewerker_id: doelId, p_nieuw: nieuwWachtwoord,
  });
  if (error) throw error;
  return data;
}

export async function checkAdminLogin(medewerkerId, wachtwoord) {
  const { data, error } = await supabase.rpc('fn_check_admin_login', {
    p_medewerker_id: medewerkerId, p_wachtwoord: wachtwoord,
  });
  if (error) throw error;
  return data;   // true / false
}

export async function maakActiviteit(naam, gratis, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_maak_activiteit', {
    p_naam: naam, p_gratis: gratis, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function wijzigActiviteit(code, naam, gratis, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_wijzig_activiteit', {
    p_code: code, p_naam: naam, p_gratis: gratis, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function deactiveerActiviteit(code, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_deactiveer_activiteit', {
    p_code: code, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// --- Admin portaal: sessiebeheer ---

export async function alleClubsessies() {
  const { data, error } = await supabase.rpc('fn_alle_clubsessies');
  if (error) throw error;
  return data;
}

export async function maakClubsessie(naam, activiteit, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_maak_clubsessie', {
    p_naam: naam, p_activiteit: activiteit, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function wijzigClubsessie(sessieId, naam, activiteit, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_wijzig_clubsessie', {
    p_sessie_id: sessieId, p_naam: naam, p_activiteit: activiteit ?? null, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function verwijderClubsessie(sessieId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_verwijder_clubsessie', {
    p_sessie_id: sessieId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function voegMomentToe(sessieId, weekdag, start, eind, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_voeg_moment_toe', {
    p_sessie_id: sessieId, p_weekdag: weekdag, p_start: start, p_eind: eind, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

export async function verwijderMoment(momentId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_verwijder_moment', {
    p_moment_id: momentId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// --- Admin portaal: recente wijzigingen + accounts ---

export async function recenteWijzigingen(limiet = 30) {
  const { data, error } = await supabase.rpc('fn_recente_wijzigingen', { p_limiet: limiet });
  if (error) throw error;
  return data;
}

export async function keurAccountGoed(lidId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_keur_account_goed', {
    p_lid_id: lidId, p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}

// Accounts die op goedkeuring wachten.
export async function nieuweAccounts() {
  const { data, error } = await supabase.rpc('fn_nieuwe_accounts');
  if (error) throw error;
  return data;
}

export async function wijsAccountAf(lidId, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_wijs_account_af', {
    p_lid_id: lidId, p_medewerker_id: medewerkerId,
  });
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

// ----------------------------------------------------------------------------
// SYNCHRONISATIE
// ----------------------------------------------------------------------------

// Haal de gegevens op die de kassa offline nodig heeft en zet ze in de cache.
export async function vulCache() {
  try {
    const [{ data: leden }, { data: sessies }] = await Promise.all([
      supabase.rpc('fn_cache_leden'),
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
          p_qr_token: actie.qrToken,
          p_medewerker_id: actie.medewerkerId,
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

// Kaartontwerp (visuele editor): achtergrond + positie/grootte van QR- en naam-box.
export async function haalKaartLayout() {
  const { data, error } = await supabase.rpc('fn_haal_kaart_layout');
  if (error) throw error;
  return data;
}

export async function bewaarKaartLayout(layout, medewerkerId) {
  const { data, error } = await supabase.rpc('fn_bewaar_kaart_layout', {
    p_achtergrond_data: layout.achtergrond_data ?? null,
    p_qr_x: layout.qr_x,
    p_qr_y: layout.qr_y,
    p_qr_grootte: layout.qr_grootte,
    p_naam_x: layout.naam_x,
    p_naam_y: layout.naam_y,
    p_naam_lettergrootte: layout.naam_lettergrootte,
    p_naam_breedte: layout.naam_breedte,
    p_ondertitel: layout.ondertitel,
    p_ondertitel_x: layout.ondertitel_x,
    p_ondertitel_y: layout.ondertitel_y,
    p_medewerker_id: medewerkerId,
  });
  if (error) throw error;
  return data;
}
