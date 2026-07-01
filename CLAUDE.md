# Rising You — Ledenbeheer & Check-in

Desktopapp voor **Rising You VZW**, een klimzaal in Antwerpen die anderstalige nieuwkomers laagdrempelig doet sporten. Dit document geeft de projectcontext voor Claude Code. Lees het volledig voor je aan de slag gaat.

---

## Belangrijkste regel: alles in eenvoudig Nederlands

Het volledige systeem (schermen, knoppen, meldingen, foutmeldingen, kaartjes) is in **eenvoudig, duidelijk Nederlands**. Geen vertaalfunctie, geen andere talen — leden moeten juist Nederlands leren. Korte zinnen, eenvoudige woorden, grote leesbare tekst, ondersteund met **kleur en symbolen** (groen = oké, rood = betalen/probleem, oranje = betaald maar extra check nodig). Ook variabelnamen en code-commentaar zijn in het Nederlands. Ook veel **medewerkers** spreken beperkt Nederlands, dus alles moet intuïtief zijn.

De gebruiker (Simon) is een capabele niet-ontwikkelaar. Leg keuzes duidelijk uit, wees eerlijk over voor- en nadelen, en hou rekening met een **VZW met beperkt budget**.

---

## Stack & omgeving

- **Tauri** (desktop shell, Rust) + **Vite** (build) + **Supabase** (PostgreSQL backend).
- Lokaal: **Windows**, VS Code, project in `C:\dev\rising-you-app` (bewust buiten OneDrive i.v.m. EBUSY).
- Versiebeheer: GitHub publieke repo `rising-you-ledenbeheer`, via GitHub Desktop + 1Password SSH-agent.
- Draaien: `npm run tauri:dev` vanuit de VS Code-terminal.
  - **Ctrl+R** herlaadt de JS (volstaat voor de meeste wijzigingen).
  - Wijzigingen aan **module-niveau `await`** of aan `tauri.conf.json` vereisen een **volledige herstart** (Ctrl+C, opnieuw `npm run tauri:dev`).
- Supabase-project: `https://agdjqrduzhywzltxurae.supabase.co` (regio Frankfurt, eu-central-1, GDPR). Anon key staat in de client en is veilig by design (zie beveiliging).
- Supabase CLI: staat als `supabase` in de Windows-PATH (via scoop). Migraties via `supabase db push` (migraties 0001–0011 toegepast, repo en live database lopen weer gelijk sinds migratie 0011).
- **Docker is niet geïnstalleerd** op deze machine. `supabase db pull`/`db diff`/`db dump` werken daardoor niet (ze hebben een gedockerde shadow-database nodig). Schema rechtstreeks inspecteren kan wel zonder Docker via `supabase db query --linked "<sql>"` (gaat via de Management API, geen wachtwoord nodig).

---

## Architectuur

Drie schermen (elk een HTML-bestand met `<script type="module">`), gekoppeld aan Supabase via `src/lib/databron.js`:

1. **`index.html`** — Check-in aan de kassa.
2. **`ledenbeheer.html`** — Ledenbeheer (zoeken, gegevens, tegoed, kaartjes, gezinnen).
3. **`admin-portaal.html`** — Admin portaal (sessies, activiteiten, wijzigingen, accounts, medewerkers).

`src/lib/databron.js` bevat alle `export async function`-wrappers rond de Supabase RPC-aanroepen (`supabase.rpc('fn_...')`). **Alle** businesslogica zit in de database in `security definer`-functies; de frontend roept die aan. Zo gedragen desktop, en later website/mobiel, zich identiek.

### Beveiligingsmodel
- Anon key alleen in de Tauri-client.
- **RLS** staat aan op alle tabellen; directe tabeltoegang is geblokkeerd.
- Alle toegang loopt via `security definer`-functies met `grant execute ... to anon`.
- Wachtwoorden (admins) worden **bcrypt-gehasht** opgeslagen via pgcrypto.

### GDPR / privacy
Kwetsbare doelgroep. Minimale data. Opgeslagen: voornaam, achternaam, **geboortejaar** (niet de volledige datum), postcode (huidige Belgische woonplaats), land van herkomst. Herkomst en woonplaats worden **apart** gehouden (vluchtelingen zijn verhuisd). Leeftijd/postcode/herkomst zijn enkel voor **anonieme statistiek**, niet gekoppeld aan individuen. Foto alleen indien toegevoegd.

---

## Kernbegrippen & businessregels (VASTGELEGD)

- **Tarieftype** staat opgeslagen in `leden.tarieftype_handmatig`, bepaald bij aanmaken op leeftijd: ≤13 kind, 14–25 student, 26+ volwassene. Enige automatische overgang is kind→student op 14 jaar. Een student van 26+ blijft student (geen automatische overgang naar volwassene). `fn_tarieftype` leest de opgeslagen waarde met enkel die kind→14→student-uitzondering; valt terug op leeftijd als de waarde null is. `fn_haal_lid` geeft `tarieftype_effectief` terug.
- **Activiteiten** zijn DB-gedreven en uitbreidbaar, met een **`gratis` boolean**. Alle drie de schermen laden de activiteiten uit de database (`fn_alle_activiteiten`).
  - **Gratis** activiteiten (bv. conversatietafel) lopen via clubsessies **zonder afrekening**: geen beurt, geen betaalwijze, geen A-Kaart-check. Ze verschijnen **niet** in het tegoed-overzicht.
  - **Betalende** activiteiten (klimmen, yoga, workout) vereisen beurtenkaart of abonnement.
- **Toewijzing-prioriteit** per betalende activiteit: geldig abonnement (nooit afgetrokken) → eigen beurtenkaart (1 beurt af) → lenen van beurtenkaart van gezinslid → anders losse beurt (cash).
- **Kaartje-failsafe**: zodra een nieuw naamkaartje wordt aangemaakt, worden alle oude kaartjes van dat lid ongeldig (`update naamkaartjes set geldig=false`). Verloren kaartjes werken dan niet meer.
- **Wachtkamer**: na inchecken komt een lid in de wachtkamer. Pas na afvinken van (betaling/geldige beurt) én (indien nodig) A-Kaart mag het lid toegewezen worden aan een clubsessie of losse klimsessie. Toewijzen gebeurt via **tap-to-assign** (pak kaart → tik sessie), niet drag-and-drop.
- **Sociaal tarief + A-Kaart**: leden met sociaal tarief moeten inchecken met hun A-Kaart (NFC, stad Antwerpen). Dat A-Kaartsysteem is **niet** gekoppeld; de medewerker vinkt handmatig af dat de A-Kaart-check gebeurd is. Bij gratis activiteiten is dit niet nodig.
- **Medewerker-selectie**: dropdown "Wie werkt nu?" bovenaan check-in en ledenbeheer, gevuld uit `fn_actieve_medewerkers`. Keuze wordt bewaard in `sessionStorage('ry_medewerker_id')` en gedeeld tussen de schermen. Elke gelogde handeling gebruikt de gekozen medewerker.
- **Admin-rechten** worden bepaald door het `is_admin`-veld in de database (niet meer op naam). Admin-login gebruikt momenteel nog een demo-wachtwoord (`'rising'`, constante `DEMO_WACHTWOORD` in index.html en ledenbeheer.html) — **dit moet nog vervangen worden door de persoonlijke wachtwoorden** (zie openstaande stappen).

---

## Belangrijke geleerde lessen (voorkom herhaling van bugs)

- **pgcrypto**: de extensie staat nu AAN. `crypt()`/`gen_salt()` zitten in het **`extensions`**-schema van Supabase. Functies die ze gebruiken MOETEN `set search_path to 'public', 'extensions', 'pg_temp'` hebben, anders faalt het met "function gen_salt does not exist" — ook al werkt de aanroep los in de SQL-editor wél. Dit geldt voor `fn_zet_admin_wachtwoord` en `fn_check_admin_login` (beide al gecorrigeerd).
- **Functie-returntype wijzigen** vereist eerst `DROP FUNCTION IF EXISTS` vóór `CREATE OR REPLACE` (bij `RETURNS TABLE`-wijzigingen).
- **PostgreSQL variabelen**: scalar-kolommen en `%rowtype`-variabelen niet mengen in één `SELECT INTO` — splitsen in twee selects.
- **CSP in Tauri/WebView2**: externe CDN-scripts zijn geblokkeerd. JS-libraries (jsPDF, qrcode) zijn lokaal gebundeld in `vendor/` en geladen via `./vendor/...`. CSP in `src-tauri/tauri.conf.json` bevat `frame-src 'self' blob:; object-src 'self' blob:` voor de PDF-iframe.
- **Drag-and-drop** is onbetrouwbaar in WebView2 → tap-to-assign is de bevestigde oplossing.
- **Dubbele exports** in `databron.js`: sommige functies bestonden al uit eerdere fases (keurAccountGoed, wijsAccountAf, recenteWijzigingen, nieuweAccounts). Check op duplicaten vóór je toevoegt — een dubbele `export async function`-naam breekt de hele module ("Identifier already declared").
- **str_replace op grote blokken** kan per ongeluk aangrenzende HTML wissen (is één keer met het activiteiten-paneel gebeurd). Verifieer na paneel-wijzigingen altijd dat alle `paneel-X` én `st-X` id's bestaan en matchen met de lijst in `toonPaneel`.
- **Kaartje-tokens**: gebruiken nu `gen_random_uuid()` (omweg uit de tijd dat pgcrypto uit stond). Nu pgcrypto aan is, mag dit optioneel terug naar `gen_random_bytes` voor sterkere tokens — niet dringend.
- Frontend syntax-check vóór opleveren: extraheer het grootste `<script>`-blok en draai `node --check`.

---

## Database-werkwijze (Supabase CLI + migraties)

**Claude Code beheert de database via de Supabase CLI en migratiebestanden — niet via handmatig geplakte SQL.** Elke DB-wijziging wordt een migratiebestand in `supabase/migrations/` en gaat via `supabase db push` naar de live database. Zo blijft de database reproduceerbaar en versiebeheerd.

### ✅ OPGELOST (2026-07-01): live/repo-drift baseline
Migratie `0011_baseline_live_functies.sql` legt 22 functies + de `gratis`-kolom op `activiteiten` vast die eerder rechtstreeks via de SQL-editor waren aangemaakt. Repo en live database lopen nu gelijk (`supabase_migrations.schema_migrations` bevat 0001–0011). **Docker ontbreekt op deze machine**, dus dit is manueel gedaan via `supabase db query --linked` (pg_proc/information_schema introspectie + `pg_get_functiondef`) in plaats van `supabase db pull` — hou daar rekening mee bij toekomstige drift-checks; zie hierboven bij "Supabase CLI".

Werkwijze voor nieuwe migraties vanaf nu:
1. Check bij twijfel of iets al leeft via `supabase db query --linked "<sql>"` (bv. `select proname from pg_proc ...`) vóór je een nieuwe migratie schrijft.
2. Schrijf de wijziging als migratiebestand.
3. Toon de SQL aan Simon, vraag bevestiging, dan pas `supabase db push`.

**NOOIT `supabase db reset` op de live database** — dat gooit data weg (persoonsgegevens!). Reset hoogstens tegen een lokale dev-database.

### Veiligheid & bevestiging
- Het gaat om een live database met **persoonsgegevens van een kwetsbare doelgroep**. Wees voorzichtig.
- **Toon de migratie-SQL aan Simon en vraag bevestiging vóór je `supabase db push` draait.** Simon wil kunnen meelezen wat er op de live database landt. Voer destructieve of twijfelachtige wijzigingen niet ongevraagd uit.
- Nieuwe DB-functies volgen de bestaande conventies: `security definer`, `set search_path to 'public', 'pg_temp'` (of `'public','extensions','pg_temp'` als ze pgcrypto's `crypt`/`gen_salt` gebruiken), en `grant execute on function ... to anon`.
- Na een geslaagde push: verifieer met een korte `select` dat de functie/kolom werkt, en koppel indien nodig de bijhorende wrapper in `src/lib/databron.js` + de window-koppeling in het betrokken scherm.

### CLI-context
Supabase CLI staat in `C:\Users\simon\supabase` (in PATH). Project is gelinkt aan het Supabase-project in Frankfurt. Als de link of het DB-wachtwoord ontbreekt, vraag Simon het te leveren i.p.v. te gokken.

---

## Bestandsstructuur (relevant)

```
C:\dev\rising-you-app\
├── index.html                 # Check-in
├── ledenbeheer.html           # Ledenbeheer
├── admin-portaal.html         # Admin portaal
├── src/lib/databron.js        # Alle Supabase RPC-wrappers
├── vendor/
│   ├── jspdf.umd.min.js       # lokaal gebundeld (CSP)
│   └── qrcode.min.js          # lokaal gebundeld (CSP)
├── src-tauri/
│   └── tauri.conf.json        # CSP incl. frame-src/object-src blob:
└── CLAUDE.md                  # dit bestand
```

Elk scherm koppelt HTML-`onclick`-handlers aan functies via `Object.assign(window, { ... })` onderaan het scriptblok (want module-scope is niet globaal). Nieuwe functies die vanuit HTML aangeroepen worden, MOETEN aan die window-koppeling toegevoegd worden.

---

## Database-functies (overzicht, allemaal `security definer`, `grant execute to anon`)

**Leden**: `fn_zoek_leden(text)` (incl. `gezin_id`), `fn_haal_lid(uuid)→jsonb` (incl. `tarieftype_effectief`), `fn_wijzig_lid(...)` (logt "van X naar Y" per gewijzigd veld), `fn_zet_tarieftype`, `fn_zet_sociaal_tarief`, `fn_tarieftype`, `fn_maak_lid(text,text,integer,text,text,boolean,uuid)→uuid` (nieuw lid aan de kassa, goedkeuring='nieuw', blokkeert inchecken niet), `fn_zet_foto(uuid,text,uuid)` (profielfoto als data-URL zetten/verwijderen).

**Tegoed**: `fn_laad_beurtenkaart(uuid,integer,text,tarieftype,uuid)`, `fn_laad_abonnement(uuid,abonnement_duur,date,text,tarieftype,uuid)` (maken altijd een NIEUWE rij aan, geven het nieuwe id terug). `fn_annuleer_beurtenkaart(uuid,uuid)`/`fn_annuleer_abonnement(uuid,uuid)` maken dat ongedaan (elke medewerker). `fn_trek_beurten_af(uuid,text,integer,uuid)` trekt handmatig beurten af van de oudste kaart(en) eerst (admin, UI-gated). `fn_zet_abonnement_einddatum(uuid,text,date,uuid)` past de einddatum van het lopende abonnement voor een activiteit aan (admin, UI-gated).

**Kaartjes**: `fn_nieuw_kaartje(uuid,uuid)` (failsafe: oude ongeldig, `gen_random_uuid()`).

**Gezinnen**: `fn_maak_gezin`, `fn_voeg_toe_aan_gezin`, `fn_verwijder_uit_gezin`, `fn_leenbare_gezinsbeurten(uuid,text)`.

**Check-in**: `fn_checkin_lid`, `fn_sessies_van_dag(date)`, `fn_momenten_van_dag(date)`, `fn_rond_wachtkamer_af(uuid,toewijzing_type,uuid,text,text,uuid,uuid)` (bevat de gratis-uitzondering vooraan: bij gratis activiteit meteen toewijzen zonder beurt/betaling/A-Kaart), `fn_herstel_naar_wachtkamer`.

**Sessies (admin)**: `fn_maak_clubsessie`, `fn_wijzig_clubsessie`, `fn_verwijder_clubsessie`, `fn_voeg_moment_toe`, `fn_verwijder_moment`, `fn_alle_clubsessies()`.

**Activiteiten**: `fn_alle_activiteiten()` (kolommen: code, naam, actief, volgorde, gratis), `fn_maak_activiteit(text,boolean,uuid)`, `fn_wijzig_activiteit(text,text,boolean,uuid)`, `fn_deactiveer_activiteit(text,uuid)`.

**Wijzigingen & accounts (admin)**: `fn_recente_wijzigingen(int)`, `fn_nieuwe_accounts()`, `fn_keur_account_goed(uuid,uuid)`, `fn_wijs_account_af(uuid,uuid)`.

**Medewerkers (admin)**: `fn_actieve_medewerkers()`, `fn_alle_medewerkers()` (incl. `heeft_wachtwoord`), `fn_maak_medewerker(text,text,boolean,uuid)`, `fn_deactiveer_medewerker(uuid,uuid)` (beschermt laatste actieve admin), `fn_zet_admin_rechten(uuid,boolean,uuid)` (beschermt laatste actieve admin), `fn_zet_admin_wachtwoord(uuid,text)` (bcrypt, search_path incl. extensions), `fn_check_admin_login(uuid,text)→boolean` (checkt actief + is_admin + bcrypt-match, search_path incl. extensions).

**Offline-cache (kassa)**: `fn_cache_leden()` — minimale ledenlijst incl. geldig QR-token, gebruikt door `vulCache()` in `databron.js` zodat de kassa kan doorwerken bij internetverlies.

**Kaartontwerp (admin)**: `fn_haal_kaart_layout()→jsonb`, `fn_bewaar_kaart_layout(text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,text,numeric,numeric,uuid)` (incl. `naam_breedte`, `ondertitel_x`). Werken op de singleton-tabel `kaart_layout` (één rij, `id boolean primary key default true`): achtergrond als base64 data-URL + positie/grootte van de QR-box, naam-box en ondertitel-box. Zie ook item hieronder.

**Statistieken (admin)**: `fn_statistieken(date,date,text,uuid,text)→jsonb` (vanaf, tot, activiteit, sessie_id, groepering 'dag'/'week') — anonieme, gegroepeerde aantallen (tijdlijn per dag/week, leeftijd-emmer, postcode, herkomst, deelnames per activiteit), filterbaar op periode/activiteit/sessie. Nooit individuele leden identificeerbaar.

**Enums**: `goedkeuring` = {nieuw, goedgekeurd, afgewezen}. Verder o.a. `tarieftype`, `toewijzing_type`, `abonnement_duur`.

**Testdata**: medewerkers `...b1` Lana (admin, **heeft wachtwoord**), `...b2` Sara, `...b3` Mehmet, `...b4` Joke. Leden `...0001`–`0009`. Clubsessies `...00c1` (Klimclub/klimmen), `...00c2` (Yoga), `...00c3` (We Workout), elk met momenten voor alle weekdagen.

---

## WAAR WE NU STAAN

Net afgerond en volledig werkend tegen de database:
- Check-in (scannen, tegoed, gezinnen, lenen, gratis activiteiten, herstel naar wachtkamer).
- Ledenbeheer (zoeken, gegevens, tarief, sociaal tarief, tegoed, kaartjes met failsafe + jsPDF-print 85×54mm, gezinnen).
- Admin portaal: sessiebeheer, activiteitenbeheer (incl. gratis/betalend bewerken), recente wijzigingen (sorteert recentste eerst, logt "van X naar Y"), accounts goedkeuren/afwijzen.
- Medewerker-selectie gekoppeld; logging registreert de juiste medewerker; admin-rechten via `is_admin`.
- pgcrypto aan; `fn_zet_admin_wachtwoord` en `fn_check_admin_login` werken (Lana heeft een wachtwoord, momenteel `testww1234` — nog te vervangen door haar echte keuze via de Medewerkers-tab).
- **(2026-07-01)** DB-drift opgelost: migratie `0011_baseline_live_functies.sql` gepusht, repo en live database lopen weer gelijk (zie "Database-werkwijze" hierboven).
- **(2026-07-01)** Medewerkersbeheer getest en werkend bevonden (zie item 1 hieronder, nu afgevinkt).
- **(2026-07-01)** Admin-login koppelen aan persoonlijke wachtwoorden afgerond en getest (zie item 2 hieronder, nu afgevinkt).
- **(2026-07-01)** Visuele kaart-editor gebouwd en getest (zie hieronder).

### RECENT AFGEROND (details)

- **Medewerkersbeheer in het admin portaal**: tabblad "Medewerkers" (lijst, toevoegen, admin-rechten togglen, wachtwoord instellen, deactiveren, laatste-admin-bescherming) — gebouwd en op 2026-07-01 via headless-browser doorloop (Playwright, nu devDependency) getest: beide tabbladen tekenen correct, geen console-errors, alle acties + de laatste-actieve-admin-bescherming werken.
- **Admin-login op persoonlijke wachtwoorden**: `index.html`/`ledenbeheer.html` gebruiken niet meer `DEMO_WACHTWOORD`; `doeAdminLogin()` is async en roept `checkAdminLogin()` (→ `fn_check_admin_login`) aan met de in de dropdown gekozen medewerker, met aparte foutmelding bij verbindingsproblemen. Bijkomende drift gevonden en opgelost: migratie 0006's opgeslagen tekst miste de `search_path`-fix die al live stond — vastgelegd in `0012_admin_login_search_path.sql`. Getest op 2026-07-01 via browser: oud demo-wachtwoord geweigerd, fout wachtwoord geweigerd, juist wachtwoord logt in (beide schermen), niet-admin kan het loginscherm niet openen.
- **(2026-07-01)** `HUIDIGE_MEDEWERKER_ID` in `admin-portaal.html` gekoppeld aan de echt ingelogde admin: leest nu `sessionStorage('ry_medewerker_id')` (zelfde sleutel als check-in/ledenbeheer) i.p.v. hardgecodeerd Lana. De "Admin: X"-badge bovenaan toont nu ook de echte naam (via `fn_alle_medewerkers`, opgehaald in nieuwe functie `laadAdminNaam()`). Getest via browser: ingelogd als Sara (tijdelijk admin gemaakt voor de test, nadien teruggezet) toont de badge "Sara" en nieuwe logregels in "Recente wijzigingen" tonen "(door Sara Helper)" i.p.v. Lana.
- **(2026-07-01) Visuele kaart-editor**: nieuw tabblad "Kaartontwerp" in het admin portaal (migratie `0013_kaart_layout.sql`, singleton-tabel `kaart_layout`). Upload van een achtergrondafbeelding (bewaard als base64 data-URL, geen Supabase Storage-bucket nodig — er was er nog geen, en het gaat om één zelden wijzigende afbeelding), versleepbare QR-box en naam-box op een 5px/mm schaalmodel (425×270px voor de 85×54mm kaart), plus numerieke velden voor exacte positionering. **Belangrijk**: het slepen gebruikt pointer-events (pointerdown/move/up), NIET de native HTML5 drag-and-drop-API — die laatste is onbetrouwbaar in Tauri's WebView2 (zie geleerde lessen). `ledenbeheer.html`'s `doePrint()` is nu async en haalt de layout op via `fn_haal_kaart_layout()`, met terugval op de oorspronkelijke hardgecodeerde waarden als het laden mislukt (bv. offline) of nog niets is opgeslagen. Getest via browser: posities wijzigen via velden én via slepen werken en blijven gesynchroniseerd, achtergrond uploaden werkt, opslaan werkt, en een nieuw kaartje printen na het opslaan genereert de PDF zonder fouten (blob-URL in de print-iframe).
- **(2026-07-01) Kaart-editor uitgebreid na gebruikersfeedback** ("QR- en naam-vak moeten in grootte aanpasbaar zijn; ondertitel moet een los verschuifbaar tekstvak zijn"): migratie `0014_kaart_layout_afmetingen.sql` voegt `naam_breedte` (mm, = jsPDF `maxWidth`) en `ondertitel_x` toe. QR-box en naam-box hebben nu een sleep-**handvat** (rechtsonder resp. rechts) om in grootte te veranderen, los van het verplaatsings-slepen op de box zelf (`e.stopPropagation()` voorkomt dat het handvat ook de box verplaatst). De ondertitel is een volledig eigen, los versleepbaar vak geworden (`#ko-box-ondertitel`), niet langer gekoppeld aan de naam-positie. De naam-box in de editor schaalt bovendien in hoogte mee met het lettertype + een geschat aantal terugloop-regels (`koSchatRegels`, canvas-tekstmeting), zodat zichtbaar is of een groter lettertype nog past — dit is enkel visueel; de echte afbreking bij het printen gebeurt door jsPDF zelf op basis van `naam_breedte`.
- **(2026-07-01) Statistieksectie**: de uitgeschakelde tab "Statistieken (later)" is vervangen door een werkende tab "Statistieken" (migratie `0015_statistieken.sql`, `fn_statistieken()→jsonb`). Toont vier reeksen als eenvoudige balkjes (geen chart-library nodig): leeftijd (in emmers: 0-12, 13-17, 18-25, 26-35, 36-50, 51-65, 66+, onbekend), postcode, herkomst, en deelnames per activiteit (telling van `checkins` met `status='toegewezen'` en `soort='check_in'`, gekoppeld aan `activiteiten.naam`). **Belangrijk (GDPR)**: de functie geeft uitsluitend gegroepeerde aantallen terug, nooit een individueel lid gekoppeld aan leeftijd/postcode/herkomst. Getest via browser: alle vier reeksen tonen correcte aantallen op de bestaande testdata, "Vernieuwen"-knop herlaadt zonder fouten.
- **(2026-07-01) Statistieken uitgebreid: tijdlijn-chart + slicers** (na gebruikersfeedback). Migratie `0016_statistieken_slicers.sql` vervangt `fn_statistieken()` door een geparametriseerde versie: `p_vanaf, p_tot, p_activiteit, p_sessie_id, p_groepering` ('dag'|'week'). Nieuwe elementen in het admin-portaal:
  - **Slicer-balk** bovenaan de tab: Periode (Laatste 7/30/90 dagen, Dit jaar, Alles — standaard **Alles**, resolved client-side naar concrete datums in `statPeriodeNaarData()`), Activiteit (dropdown, gevuld uit `fn_alle_activiteiten`) en Sessie (dropdown, gevuld uit `fn_alle_clubsessies`). Wijzigen van een slicer herlaadt automatisch (change-listener); geldt voor de chart ÉN de vier reeksen eronder.
  - **Tijdlijn-chart** "Check-ins per dag/week, per activiteit": een handgetekende gestapelde staafgrafiek op een `<canvas>` (`statTekenTijdlijn()`), met een eigen dag/week-schakelaar (`statZetGroepering()`) die enkel de groepering van de chart bepaalt (los van de periode-slicer). Kleur per activiteit + legende. Bewust géén chart-library toegevoegd (CSP/vendor-bundeling zou nodig zijn; canvas-tekenen is simpel genoeg).
  - **Belangrijk (GDPR/telling)**: leeftijd/postcode/herkomst tellen nu **DISTINCTe leden** binnen de gefilterde check-ins (iemand die 3x incheckte telt 1x mee in bv. de postcode-verdeling); "deelnames per activiteit" en de tijdlijn tellen wél elke check-in apart (dat is net "hoe vaak").
  - Getest via browser: activiteit/sessie-dropdowns vullen correct, dag↔week-schakelaar werkt (stapelt per week samen), filteren op activiteit toont enkel die activiteit in "deelnames", periode-filter "Laatste 7 dagen" toont nog steeds de (recente) testdata, geen console-fouten.
- **(2026-07-01) Ledenbeheer — Tegoed-sectie compacter**: het altijd-zichtbare blok (Activiteit-dropdown + Beurtenkaart-invoer + Abonnement-duur, permanent onder het tegoed-overzicht) is vervangen door één knop "Tegoed toevoegen" die een modal (`#overlay-tegoed`) opent met exact diezelfde velden (Activiteit, Beurtenkaart-aantal + knop, Abonnement-duur + knop). De modal staat — net als de andere overlays (`overlay-print` e.d.) — statisch in de pagina i.p.v. binnen `tekenDetail()`'s dynamisch herbouwde HTML, zodat ze niet verdwijnt bij een her-render na het toevoegen (dus meerdere dingen toevoegen zonder opnieuw te moeten klikken). `voegBeurtenkaartToe()`/`voegAbonnementToe()` zelf zijn ongewijzigd (lazen en lezen nog steeds `#tg-activiteit`/`#tg-aantal`/`#tg-duur`). Getest via browser: knop opent de modal met de juiste activiteiten en tarief-info, beurtenkaart + abonnement toevoegen werken beide, modal blijft open na toevoegen, sluit pas via de Sluiten-knop, geen console-fouten.
  - Tijdens het onderzoek ontdekt: `lidmaatschapSectieHTML()` en de bijhorende `openToevoegBeurt`/`openToevoegAbo`/`overlay-toevoegbeurt`/`overlay-toevoegabo` zijn **dode code** uit een vroeger prototype (werken op een lokale mock-array, worden nergens meer aangeroepen). Niet aangeraakt — buiten scope van deze aanpassing, maar het opruimen ervan kan later.
- **(2026-07-01) Tegoed ongedaan maken (iedereen) + beurten aftrekken (admin)**. Migratie `0017_ongedaan_maken_en_aftrekken.sql`:
  - `fn_annuleer_beurtenkaart`/`fn_annuleer_abonnement` verwijderen precies de kaart/het abonnement dat net is aangemaakt (beide `fn_laad_*`-functies maken altijd een NIEUWE rij aan, nooit stapelend — ongedaan maken is dus gewoon die rij weer weg). Beschikbaar voor **elke medewerker**, geen adminvereiste. Veiligheidsgrendel op de kaart: enkel ongedaan te maken zolang er nog geen beurt van afgetrokken is (`beurten_resterend = beurten_totaal`); abonnementen hebben geen vergelijkbare grendel nodig (worden nooit "verbruikt", enkel op geldigheid gecheckt).
  - `fn_trek_beurten_af` trekt handmatig beurten af van de oudste kaart(en) eerst (zelfde volgorde als `fn_beschikbaar_tegoed`), weigert bij onvoldoende tegoed (geen gedeeltelijke aftrek). **Enkel UI-gated tot admin-modus** (`isAdmin()`), zoals de andere admin-acties in deze app — geen harde rol-check in de functie zelf.
  - In de "Tegoed toevoegen"-modal (`ledenbeheer.html`): een "Ongedaan maken"-knopje verschijnt na het toevoegen van een beurtenkaart/abonnement, en een apart blok "Beurten aftrekken (admin)" onderaan dat enkel zichtbaar is in admin-modus.
  - Getest via browser: niet-admin ziet het aftrek-blok niet, toevoegen + ongedaan maken werkt voor zowel beurtenkaart als abonnement, admin ziet en kan het aftrek-blok gebruiken, en aftrekken van meer dan beschikbaar wordt correct geweigerd met een duidelijke melding.
  - **(2026-07-01) Fix na gebruikersfeedback**: "ongedaan maken" onthield eerst enkel de állerlaatste toevoeging (`laatsteBeurtenkaartId`/`laatsteAbonnementId`) — bij 3x per ongeluk toevoegen kon je maar 1x ongedaan maken. Vervangen door een stapel (`beurtenkaartStapel`/`abonnementStapel`, laatst-toegevoegd-eerst-ongedaan-gemaakt) die elke toevoeging in de modal-sessie bijhoudt; de knop toont het aantal openstaande toevoegingen (bv. "Ongedaan maken (3x)") en verdwijnt pas als de stapel leeg is. Getest via browser: 3x toevoegen + 3x ongedaan maken herstelt het tegoed exact naar de oorspronkelijke waarde, met de teller die correct aftelt (3x → 2x → geen teller → verborgen).
- **(2026-07-01) Abonnement-einddatum manueel aanpassen (admin)**. Migratie `0018_abonnement_einddatum_aanpassen.sql`, `fn_zet_abonnement_einddatum(uuid,text,date,uuid)`. Gekozen boven "maanden aftrekken": een lid kan meerdere abonnement-rijen per activiteit hebben (`fn_laad_abonnement` maakt altijd een nieuwe rij, nooit stapelend), dus "van welke rij aftrekken" zou dubbelzinnig zijn — een expliciete nieuwe datum instellen op HET ene actueel lopende abonnement (zelfde opzoeklogica als `fn_beschikbaar_tegoed`: verste nog geldige einddatum) is eenduidiger en flexibeler (kan ook verkorten, niet enkel in maand-stappen).
  - In de "Tegoed toevoegen"-modal, admin-blok: een datumveld dat bij het wisselen van activiteit automatisch de huidige einddatum toont (`tgVulAboEinddatum()`, on-change listener op `#tg-activiteit`), of "Geen lopend abonnement voor deze activiteit" als er geen is.
  - Getest via browser: niet-admin ziet het blok niet; bij een activiteit mét lopend abonnement wordt de juiste datum vooringevuld en aanpassen werkt; bij een activiteit zonder abonnement verschijnt de juiste melding i.p.v. het veld.
- **(2026-07-01) Check-in: demo-namenrij onder "Scan kaartje" verwijderd.** `index.html` had een `<div id="demorij">` die bij het opstarten gevuld werd met een knopje per naam uit een oude, lokale test-dataset (`leden`-object met nep-codes als `"RY-guy"`), puur om tijdens de bouw snel een scan te kunnen simuleren. Div, CSS (`.demo-rij`) en de vulcode zijn verwijderd.
  - Bij nader onderzoek bleek dit deel van een véél groter, parallel "prototype"-systeem in zowel `index.html` als `ledenbeheer.html`: een hardgecodeerde lokale `leden`/`gezinnen`-mock-dataset naast de echte, DB-gekoppelde code. **Belangrijke nuance die toen is uitgezocht**: sommige van die mock-functies waren niet zomaar dode code, maar **zichtbare, klikbare knoppen die stilzwijgend nep/kapot werkten** — met name "Klant opzoeken" en "Nieuw profiel" op de check-in-pagina. Dat is toen apart aangepakt (zie hieronder), vóór de rest werd opgeruimd.
- **(2026-07-01) "Klant opzoeken" en "Nieuw profiel" écht gemaakt (index.html).** Beide gebruikten voorheen enkel de lokale mock-dataset (zoeken/aanmaken gebeurde niet in de database; een lid toewijzen aan een sessie zou gecrasht zijn op een ongeldige nep-ID). Migratie `0019_maak_lid.sql` voegt `fn_maak_lid` toe (goedkeuring='nieuw', net als zelfregistratie — blokkeert het meteen inchecken niet, want `fn_checkin_lid` filtert enkel op `actief`). `zoek()` gebruikt nu `fn_zoek_leden` (al bestaand, gebruikt in ledenbeheer), `maakNieuwProfiel()` roept `fn_maak_lid` + meteen `fn_checkin_lid` aan. Gemeenschappelijke logica (gezinsleden + tegoed-cache ophalen, wachtkamer-rij aanmaken) is uit `verwerkScan()` getrokken naar een gedeelde `verwerkEchteCheckin(r, soort)`, hergebruikt door scan, zoek-resultaat en nieuw-profiel. Getest via browser: zoeken toont echte leden met echt tegoed, nieuw profiel verschijnt meteen (met correct 0-tegoed) in de wachtkamer en in "Check-ins vandaag".
- **(2026-07-01) Grote opruiming van dode/mock-legacycode in `index.html` en `ledenbeheer.html`.** Na het echt maken van bovenstaande twee features bleek de rest van het parallelle mock-systeem overal ongebruikt (nul echte aanroepers, geverifieerd per functie vóór verwijdering). Verwijderd: de mock `leden`/`gezinnen`-datasets, `verwerkScanCode` + globale scan-buffer-onderschepper (ving snel getypte `"RY-"`-tekst overal op de pagina op — onschadelijk sinds echte QR-tokens UUID's zijn), mock `checkInLid`/`regelTegoed`/`vraagLenen`/`bronLabel`, en in `ledenbeheer.html` een hele reeks dubbelgangers van al lang vervangen functies: `gezinSectieHTML` (dood, te onderscheiden van de echte `gezinSectieHtml` — kleine hoofdletter-h!), `tariefSectieHTML`/`zetTarief`, `lidmaatschapSectieHTML` + het hele beurten/abonnement-toevoeg-popupsysteem (`tbTel`/`taKies`/...), de mock gezin-modals (`overlay-gezin`/`overlay-rol`), het land-kiezer- en foto/webcam-systeem (`overlay-land`/`overlay-fotokeuze`/`overlay-bijsnijden`/`overlay-cam`), `sessieHistoriekHTML`/`ongedaan`, en `adminVerwijderHTML`/`verwijderLid` (nergens aan gekoppeld, dus momenteel bestaat er geen "profiel verwijderen"-knop in de echte UI). Samen goed voor **~930 regels** verwijderd uit `ledenbeheer.html` en **~240 regels** uit `index.html`.
  - **Regressie gevonden en gefixt tijdens het testen**: `kiesLid()` (echt, actief) reset per ongeluk nog `beurtTeller`/`aboKeuze` — variabelen die enkel bij de verwijderde mock-code hoorden. Zonder fix crashte het hele detailpaneel (`beurtTeller is not defined`) zodra je op een lid klikte. Statement verwijderd; sindsdien getest en werkend.
  - Getest via browser: volledige regressietest van check-in (zoeken, nieuw profiel) én ledenbeheer (lid kiezen, Gegevens/Tarief/Tegoed/Kaartje/Gezin-secties, Tegoed-modal) — alles werkt, geen console-fouten, HTML-structuur (overlays) intact.
- **(2026-07-01) Correctie: profielfoto (webcam/upload/bijsnijden/verwijderen) hersteld en nu écht gekoppeld.** Bij de opruiming hierboven bleek achteraf dat het foto-systeem (`openFotoKeuze`/crop-modal/webcam-modal) ten onrechte als dode code was ingeschat: het was géén bewust prototype-restant zoals de rest, maar een eerder al **echt geteste** feature waarvan de aanroep-knop op een niet-gedocumenteerd moment losgekoppeld was geraakt van het echte detailscherm (`leden.foto_pad` werd al wél getoond in `tekenDetail()`, maar er was geen knop meer om een foto te zetten). Omdat "nul aanroepers" toen niet werd onderscheiden van "per ongeluk losgekoppeld", is de hele crop/webcam-logica mee verwijderd — dat was een fout.
  - Hersteld door de oorspronkelijke crop/webcam-code (goed herbruikbaar, uit de git-geschiedenis vóór de opruiming) opnieuw te verbinden aan de échte database i.p.v. de mock `leden`-array. Nieuwe migratie `0020_lid_foto.sql`: `fn_zet_foto(uuid,text,uuid)` zet/verwijdert `leden.foto_pad`, bewaard als data-URL (zelfde patroon als `kaart_layout.achtergrond_data` — geen Supabase Storage-bucket nodig). Frontend snijdt/verkleint altijd naar 256×256 jpeg (kwaliteit 0.8) vóór het opslaan — klein genoeg, nog duidelijk genoeg.
  - Nieuwe knop op de foto zelf (klein cameraatje rechtsonder, `.foto-wijzig-knop`) opent de keuze (webcam of bestand); een "Foto verwijderen"-knop verschijnt naast de naam zodra er een foto is. Getest via browser: bestand uploaden → bijsnijden (zoom-slider) → bewaren toont de foto meteen in het detailscherm én de ledenlijst, en verwijderen zet de avatar terug op het standaard-icoon. Webcam-flow zelf niet automatisch getest (vereist een echte/virtuele camera), maar herbouwd volgens exact dezelfde, al eerder geteste logica als de upload-flow.
  - **Les voor mezelf**: "nul aanroepers gevonden" bewijst dat iets *nu* niet aangesloten is, niet dat het *nooit gewenst* was. Bij twijfel over grotere, zichtbaar-onvolledige functionaliteit (een knop/modal die je zou verwachten) eerst navragen in plaats van aannemen dat het prototype-restant is.
- **(2026-07-01) Profielfoto ook zichtbaar op de check-in-pagina (`index.html`).** Na het herstellen van de foto-functie in ledenbeheer bleek `index.html` de foto nergens te tonen: de wachtkaart en de "Klant opzoeken"-zoekresultaten hadden allebei al een `.fotomini`-div, maar die stond hardgecodeerd op het standaard-icoontje (nooit gevuld met `foto_pad`); het profiel-infovenster (`.profiel-foto`) had zelfs geen `id` om dynamisch te vullen. Beide echte check-in-RPC's (`fn_verwerk_scan`, `fn_checkin_lid`) gaven `foto_pad` altijd al mee — enkel de frontend gebruikte het nooit. Fix: `foto_pad`/`fotoPad` wordt nu doorgegeven van scan/zoek-resultaat → `verwerkEchteCheckin()` → `checkInLidDb()` → de wachtkaart-render, en zowel `zoek()` als `toonProfiel()` tonen nu ook de echte foto (met `<img>`/`object-fit:cover`-CSS toegevoegd aan `.fotomini` en `.profiel-foto`, die ontbrak). Getest via browser: foto zetten in ledenbeheer → meteen zichtbaar op de check-in-pagina in zoekresultaat, wachtkaart, én profiel-infovenster.
- **(2026-07-01) Scannen — hoe het werkt + globaal vangnet hersteld.** Op vraag nagekeken en uitgelegd: een USB/Bluetooth QR-scanner werkt vrijwel altijd als **toetsenbord-emulatie** (razendsnel getypte tekst + Enter) — er is dus **geen "voeg scanner toe"-instelling nodig** in het admin portaal; elke scanner gedraagt zich identiek zodra hij op Windows is aangesloten/gekoppeld (een OS-stapje, geen app-instelling). Scannen werkt zolang het scanveld ("Scan kaartje…") de focus heeft; dat gebeurt automatisch bij het opstarten en na elke scan.
  - **Correctie op een eerdere aanname**: bij de grote opruimronde is de "GLOBALE SCAN-ONDERSCHEPPING" (ving scans overal op de pagina op, ongeacht focus) verwijderd met de redenering "onschadelijk sinds echte QR-tokens UUID's zijn, nooit RY--prefix" — dat klopte niet. `fn_nieuw_kaartje` genereert tokens als `'RY-' || replace(gen_random_uuid()::text,'-','')`, dus échte kaartjes beginnen wél met `RY-`. Dat vangnet was dus geen dood prototype-restant maar legitieme functionaliteit die enkel zijn aanroeppad (het dode `verwerkScanCode()` op mock-data) kwijt was.
  - Hersteld: de globale keydown-onderschepping (`SCAN_PREFIX='RY-'`, buffert snelle bursts, `SCAN_MAX_PAUZE=60`ms) roept nu een gedeelde `verwerkGescandeCode(code, toonMelding)` aan (ook gebruikt door het scanveld zelf), die de échte `dbVerwerkScan` + `verwerkEchteCheckin()` gebruikt. Bij een scan terwijl de bediende ergens anders mee bezig was, verschijnt een groene banner bovenaan ("Scan herkend: naam"). **Bekende, onveranderde beperking** (zat al zo in de oorspronkelijke versie): de eerste 2 tekens van een burst ("RY") kunnen nog in het op dat moment actieve veld terechtkomen vóór het systeem de scan herkent — cosmetisch, geen functioneel probleem.
  - Getest via browser: scannen (getypte burst + Enter) terwijl een ander veld focus had, wordt correct herkend, toont de banner, en zet het lid met correct tegoed in de wachtkamer — zonder het scanveld ooit aan te raken.

### DIRECT OPENSTAAND — hier zijn we mee bezig

Geen — alle "DAARNA"-items uit de vorige ronde zijn afgerond. Nieuwe prioriteiten door de gebruiker te bepalen.

### LATER / UITBREIDINGEN
- Website-zelfregistratie op afgeschermd deel van risingyou.be (account aanmaken + eigen beurten/abonnement zien; nog geen digitaal beheer/betaling). Live sync met dezelfde database; vangnet als internet wegvalt.
- Mobiele check-in-app.
- Distributie als installeerbare **.exe** met auto-updates (Tauri GitHub Releases; vereist signing-keypair) — moet remote door Simon beheerd/geüpdatet kunnen worden.
- Microsoft 365/Outlook: e-mails zijn Outlook-adressen op `@risingyou.be` (voor eventuele bevestigingen/herinneringen).
- Optioneel: kaartje-tokens terug naar `gen_random_bytes`.

---

## Werkwijze-afspraken
- Stel verduidelijkende vragen vóór grote technische keuzes.
- Hou code onderhoudbaar en goed becommentarieerd (in het Nederlands), zodat een medewerker het later kan beheren.
- Wees eerlijk over voor-/nadelen en over wat een wijziging raakt.
- Voor elke lid-facing tekst: consequent eenvoudig Nederlands.
