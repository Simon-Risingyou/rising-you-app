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

**Leden**: `fn_zoek_leden(text)` (incl. `gezin_id`), `fn_haal_lid(uuid)→jsonb` (incl. `tarieftype_effectief`), `fn_wijzig_lid(...)` (logt "van X naar Y" per gewijzigd veld), `fn_zet_tarieftype`, `fn_zet_sociaal_tarief`, `fn_tarieftype`.

**Tegoed**: `fn_laad_beurtenkaart(uuid,integer,text,tarieftype,uuid)`, `fn_laad_abonnement(uuid,abonnement_duur,date,text,tarieftype,uuid)`.

**Kaartjes**: `fn_nieuw_kaartje(uuid,uuid)` (failsafe: oude ongeldig, `gen_random_uuid()`).

**Gezinnen**: `fn_maak_gezin`, `fn_voeg_toe_aan_gezin`, `fn_verwijder_uit_gezin`, `fn_leenbare_gezinsbeurten(uuid,text)`.

**Check-in**: `fn_checkin_lid`, `fn_sessies_van_dag(date)`, `fn_momenten_van_dag(date)`, `fn_rond_wachtkamer_af(uuid,toewijzing_type,uuid,text,text,uuid,uuid)` (bevat de gratis-uitzondering vooraan: bij gratis activiteit meteen toewijzen zonder beurt/betaling/A-Kaart), `fn_herstel_naar_wachtkamer`.

**Sessies (admin)**: `fn_maak_clubsessie`, `fn_wijzig_clubsessie`, `fn_verwijder_clubsessie`, `fn_voeg_moment_toe`, `fn_verwijder_moment`, `fn_alle_clubsessies()`.

**Activiteiten**: `fn_alle_activiteiten()` (kolommen: code, naam, actief, volgorde, gratis), `fn_maak_activiteit(text,boolean,uuid)`, `fn_wijzig_activiteit(text,text,boolean,uuid)`, `fn_deactiveer_activiteit(text,uuid)`.

**Wijzigingen & accounts (admin)**: `fn_recente_wijzigingen(int)`, `fn_nieuwe_accounts()`, `fn_keur_account_goed(uuid,uuid)`, `fn_wijs_account_af(uuid,uuid)`.

**Medewerkers (admin)**: `fn_actieve_medewerkers()`, `fn_alle_medewerkers()` (incl. `heeft_wachtwoord`), `fn_maak_medewerker(text,text,boolean,uuid)`, `fn_deactiveer_medewerker(uuid,uuid)` (beschermt laatste actieve admin), `fn_zet_admin_rechten(uuid,boolean,uuid)` (beschermt laatste actieve admin), `fn_zet_admin_wachtwoord(uuid,text)` (bcrypt, search_path incl. extensions), `fn_check_admin_login(uuid,text)→boolean` (checkt actief + is_admin + bcrypt-match, search_path incl. extensions).

**Offline-cache (kassa)**: `fn_cache_leden()` — minimale ledenlijst incl. geldig QR-token, gebruikt door `vulCache()` in `databron.js` zodat de kassa kan doorwerken bij internetverlies.

**Enums**: `goedkeuring` = {nieuw, goedgekeurd, afgewezen}. Verder o.a. `tarieftype`, `toewijzing_type`, `abonnement_duur`.

**Testdata**: medewerkers `...b1` Lana (admin, **heeft wachtwoord**), `...b2` Sara, `...b3` Mehmet, `...b4` Joke. Leden `...0001`–`0009`. Clubsessies `...00c1` (Klimclub/klimmen), `...00c2` (Yoga), `...00c3` (We Workout), elk met momenten voor alle weekdagen.

---

## WAAR WE NU STAAN

Net afgerond en volledig werkend tegen de database:
- Check-in (scannen, tegoed, gezinnen, lenen, gratis activiteiten, herstel naar wachtkamer).
- Ledenbeheer (zoeken, gegevens, tarief, sociaal tarief, tegoed, kaartjes met failsafe + jsPDF-print 85×54mm, gezinnen).
- Admin portaal: sessiebeheer, activiteitenbeheer (incl. gratis/betalend bewerken), recente wijzigingen (sorteert recentste eerst, logt "van X naar Y"), accounts goedkeuren/afwijzen.
- Medewerker-selectie gekoppeld; logging registreert de juiste medewerker; admin-rechten via `is_admin`.
- pgcrypto aan; `fn_zet_admin_wachtwoord` en `fn_check_admin_login` werken (Lana heeft een wachtwoord).
- **(2026-07-01)** DB-drift opgelost: migratie `0011_baseline_live_functies.sql` gepusht, repo en live database lopen weer gelijk (zie "Database-werkwijze" hierboven).

### DIRECT OPENSTAAND — hier zijn we mee bezig

1. **[NET GEBOUWD, MOET NOG GETEST] Medewerkersbeheer in het admin portaal.** Nieuw tabblad "Medewerkers": lijst, toevoegen (voornaam/achternaam/admin-switch), admin-rechten togglen, wachtwoord instellen (popup), deactiveren. Beschermt de laatste actieve admin. databron-functies toegevoegd: `alleMedewerkers`, `maakMedewerker`, `deactiveerMedewerker`, `zetAdminRechten`, `zetAdminWachtwoord`, `checkAdminLogin`.
   - **Bug die net is opgelost**: bij het toevoegen van het medewerkers-paneel was per ongeluk het volledige `paneel-activiteiten` overschreven, waardoor Activiteiten én Medewerkers een leeg scherm gaven (`toonPaneel` crashte op het ontbrekende element). Het activiteiten-paneel is teruggezet. Geverifieerd dat alle 5 panelen (`sessies, wijzigingen, accounts, activiteiten, medewerkers`) en bijbehorende `st-`tabs nu bestaan.
   - **TE DOEN**: in de app testen dat beide tabbladen weer tekenen, en dat toevoegen/deactiveren/admin-togglen/wachtwoord-instellen werkt. De laatste-admin-bescherming testen (mag niet lukken).

2. **[PENDING] Admin-login koppelen aan persoonlijke wachtwoorden.** Nu gebruiken index.html en ledenbeheer.html nog `DEMO_WACHTWOORD='rising'` in `doeAdminLogin()`. Vervangen door `fn_check_admin_login(gekozenMedewerkerId, wachtwoord)` via `checkAdminLogin()` uit databron. **Gevoelige stap**: als dit breekt kan niemand inloggen. Lana heeft al een wachtwoord, dus er is altijd een weg terug. Login moet checken tegen de in de dropdown gekozen medewerker.

### DAARNA (door gebruiker gekozen prioriteit)
3. **Visuele kaart-editor** in het admin portaal: upload huisstijl-achtergrond, versleepbare QR- en naam-boxen, layout opslaan, toepassen bij het printen. Nu is het kaartontwerp hardgecodeerd in jsPDF (QR links ~34mm, naam rechts, tekst "Rising You — lidkaart"). Gebruiker koos expliciet voor een "volwaardige visuele editor".
4. **Statistieksectie** (tab bestaat al als uitgeschakeld "Statistieken (later)"): anonieme aantallen op leeftijd, postcode, herkomst, deelnames per activiteit.

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
