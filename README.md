# Rising You — Ledenbeheer & Check-in

Een lokaal draaiende desktop-app (Tauri) met een Supabase-database, voor het
beheren van leden en het inchecken aan de kassa bij Rising You VZW.

Dit document leidt je door de opzet. Het is geschreven voor een technisch
onderlegde beheerder die het systeem zelf draaiende houdt.

---

## 1. Wat zit waar?

```
rising-you-app/
├── index.html              ← Check-in (kassa)        — de kern
├── ledenbeheer.html        ← Ledenbeheer
├── admin-portaal.html      ← Admin portaal
├── registratie.html        ← Publieke zelfregistratie
├── src/lib/
│   ├── supabase.js         ← verbinding met Supabase
│   ├── databron.js         ← ALLE datatoegang loopt hierlangs
│   ├── offline.js          ← lokale cache + wachtrij (kassa blijft werken)
│   └── navigatie.js        ← tabs + gedeelde admin-status
├── supabase/migrations/    ← de volledige database (0001 t/m 0010)
├── src-tauri/              ← de desktop-app (Rust/Tauri) + auto-updater
├── .env.example            ← kopieer naar .env en vul in
└── package.json
```

De **businesslogica zit in de database** (de migraties), niet in de schermen.
Daardoor gedragen de desktop-app en een latere website zich identiek: ze roepen
allebei dezelfde databasefuncties aan (bv. `fn_verwerk_scan`,
`fn_wijs_toe_aan_sessie`, `fn_keur_account_goed`).

---

## 2. Eenmalige opzet

### Stap 1 — Vereisten installeren
- **Node.js** 18 of nieuwer (https://nodejs.org)
- **Rust** (https://rustup.rs) — nodig om de desktop-app te bouwen
- De Tauri-systeemvereisten voor jouw OS:
  https://tauri.app/start/prerequisites/

### Stap 2 — Supabase-project aanmaken
1. Maak een gratis project op https://supabase.com.
2. Ga naar **Project Settings → API** en noteer:
   - de **Project URL**
   - de **anon public key**
3. Kopieer `.env.example` naar `.env` en vul beide waarden in.

### Stap 3 — De database opbouwen
De map `supabase/migrations/` bevat de volledige database in volgorde
(0001 t/m 0010). Twee manieren om ze te draaien:

**Met de Supabase CLI (aanbevolen):**
```bash
npm install -g supabase
supabase link --project-ref JOUW_PROJECT_REF
supabase db push
```

**Of handmatig:** open de SQL-editor in Supabase en plak de inhoud van elk
migratiebestand, in numerieke volgorde, één voor één.

### Stap 4 — App-afhankelijkheden installeren
```bash
npm install
```

---

## 3. Dagelijks gebruik (ontwikkelen / testen)

```bash
npm run tauri:dev
```
Dit opent de desktop-app met live herladen. De vier schermen zijn bereikbaar
via de tabs bovenaan.

---

## 4. De app bouwen voor de kassa-pc's

```bash
npm run tauri:build
```
Dit maakt een installer voor jouw besturingssysteem (`.msi`/`.exe` voor Windows,
`.dmg` voor Mac, `.AppImage`/`.deb` voor Linux) in
`src-tauri/target/release/bundle/`.

Installeer die op de kassa-pc. De app draait dan **lokaal** en praat met de
**online** Supabase-database. Valt het internet weg, dan werkt de check-in door
op de lokale cache en synchroniseert zodra de verbinding terug is.

---

## 5. Updates op afstand uitrollen

Je wou de kassa op afstand kunnen updaten. Dat gaat via de **Tauri-updater**:

1. Genereer eenmalig een sleutelpaar:
   ```bash
   npm run tauri signer generate
   ```
   Zet de **publieke** sleutel in `src-tauri/tauri.conf.json` (veld `pubkey`).
   Bewaar de **private** sleutel veilig (nooit delen/committen).

2. Verhoog het versienummer in `package.json` én `src-tauri/tauri.conf.json`.

3. Bouw met de private sleutel als omgevingsvariabele:
   ```bash
   TAURI_SIGNING_PRIVATE_KEY="..." npm run tauri:build
   ```

4. Publiceer de gebouwde bestanden + `latest.json` als een **GitHub Release**.
   De kassa-pc's controleren de `endpoints`-URL en bieden de update automatisch
   aan. Pas de `endpoints`-URL in `tauri.conf.json` aan naar jouw repo.

---

## 6. Privacy & GDPR

- Er wordt **minimale data** bewaard: naam, geboortejaar (niet de volledige
  geboortedatum), postcode, land van herkomst, en lidmaatschap.
- Leeftijd, postcode en herkomst zijn bedoeld voor **anonieme statistiek** en
  worden niet aan individuele personen gekoppeld in rapportages.
- Foto's zijn optioneel en worden enkel bewaard als ze toegevoegd zijn.
- Beveilig de database met **Row Level Security** in Supabase (zie de
  opmerkingen in migratie 0001) voordat je live gaat.

---

## 7. Volgende stappen (later)

- Mobiele check-in-app: de database registreert al de **bron** van elke
  check-in (kassa/mobiel/website), dus dit sluit netjes aan.
- Statistieken-sectie in het admin portaal.
- Website-koppeling op risingyou.be waar leden hun beurten kunnen opvolgen.
