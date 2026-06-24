// ============================================================================
// Rising You — Navigatie en gedeelde admin-status
// ----------------------------------------------------------------------------
// De vier schermen zijn aparte pagina's. Deze helper zorgt dat:
//   - de tabs bovenaan naar de juiste pagina navigeren;
//   - de "admin ingelogd"-status gedeeld wordt tussen de pagina's (via
//     sessionStorage), zodat de Admin-portaal-tab op elke pagina verschijnt
//     zodra een admin is ingelogd, en overal verdwijnt bij uitloggen.
//
// sessionStorage leeft zolang het app-venster open is. Bij het afsluiten van
// de kassa-app is de admin dus automatisch weer uitgelogd — veilig en eenvoudig.
// ============================================================================

const ADMIN_SLEUTEL = 'ry_admin';

export function isAdminIngelogd() {
  try { return sessionStorage.getItem(ADMIN_SLEUTEL) === '1'; }
  catch { return false; }
}

export function zetAdminIngelogd(aan) {
  try {
    if (aan) sessionStorage.setItem(ADMIN_SLEUTEL, '1');
    else sessionStorage.removeItem(ADMIN_SLEUTEL);
  } catch { /* sessionStorage niet beschikbaar: stil negeren */ }
}

// Toont of verbergt de Admin-portaal-tab op basis van de admin-status.
export function werkAdminTabBij() {
  const tab = document.getElementById('admin-portaal-tab');
  if (tab) tab.style.display = isAdminIngelogd() ? 'inline-block' : 'none';
}

// Koppelt de tabs aan echte navigatie. Roep dit één keer aan bij het laden.
export function koppelNavigatie() {
  const routes = {
    'tab-checkin': 'index.html',
    'tab-ledenbeheer': 'ledenbeheer.html',
    'admin-portaal-tab': 'admin-portaal.html',
  };
  for (const [id, doel] of Object.entries(routes)) {
    const el = document.getElementById(id);
    if (el) el.addEventListener('click', (e) => { e.preventDefault(); window.location.href = doel; });
  }
  werkAdminTabBij();
}
