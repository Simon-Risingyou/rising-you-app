// ============================================================================
// Rising You — Offline cache
// ----------------------------------------------------------------------------
// De kassa moet blijven werken als het internet even wegvalt. Deze module
// houdt een lokale kopie bij van de gegevens die de check-in nodig heeft
// (leden, hun kaartjes/tegoed, sessies van vandaag) en bewaart check-ins die
// nog niet gesynchroniseerd zijn.
//
// Aanpak (bewust eenvoudig en onderhoudbaar):
//   - We gebruiken de browseropslag (localStorage) van het Tauri-venster als
//     lokale cache. Voor de schaal van Rising You (honderden leden, <100
//     check-ins/dag) is dat ruim voldoende en heeft het geen extra database
//     nodig op de kassa-pc.
//   - Bij het opstarten en periodiek halen we de actuele gegevens op en zetten
//     ze in de cache (pullCache).
//   - Een check-in wordt altijd EERST lokaal weggeschreven en in een wachtrij
//     gezet; daarna proberen we te synchroniseren (pushWachtrij). Lukt dat niet
//     (offline), dan blijft de check-in in de wachtrij tot het internet terug is.
// ============================================================================

const CACHE_SLEUTEL = 'ry_cache_v1';
const WACHTRIJ_SLEUTEL = 'ry_wachtrij_v1';

// --- Cache lezen/schrijven ---
export function leesCache() {
  try {
    const ruw = localStorage.getItem(CACHE_SLEUTEL);
    return ruw ? JSON.parse(ruw) : null;
  } catch {
    return null;
  }
}

export function schrijfCache(data) {
  try {
    localStorage.setItem(CACHE_SLEUTEL, JSON.stringify({
      ...data,
      bijgewerkt_op: new Date().toISOString(),
    }));
    return true;
  } catch (e) {
    console.error('Kon cache niet opslaan:', e);
    return false;
  }
}

// --- Wachtrij van nog-niet-gesynchroniseerde acties ---
export function leesWachtrij() {
  try {
    const ruw = localStorage.getItem(WACHTRIJ_SLEUTEL);
    return ruw ? JSON.parse(ruw) : [];
  } catch {
    return [];
  }
}

export function voegToeAanWachtrij(actie) {
  const rij = leesWachtrij();
  rij.push({ ...actie, lokaal_id: crypto.randomUUID(), tijd: new Date().toISOString() });
  localStorage.setItem(WACHTRIJ_SLEUTEL, JSON.stringify(rij));
}

export function verwijderUitWachtrij(lokaalId) {
  const rij = leesWachtrij().filter((a) => a.lokaal_id !== lokaalId);
  localStorage.setItem(WACHTRIJ_SLEUTEL, JSON.stringify(rij));
}

export function wachtrijAantal() {
  return leesWachtrij().length;
}
