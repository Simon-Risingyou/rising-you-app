-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0001: basisschema
-- ----------------------------------------------------------------------------
-- Dit bestand bevat het volledige databasemodel. Alles draait op PostgreSQL
-- (Supabase). Zowel de lokale kassa-app als de latere website (risingyou.be)
-- praten met dezelfde database, zodat beurten en abonnementen live kloppen.
--
-- Leesvolgorde van onder naar boven:
--   1. medewerkers      -> wie werkt aan de kassa
--   2. leden            -> de kern: persoonsgegevens (minimaal, GDPR)
--   3. naamkaartjes     -> QR-kaartjes met failsafe bij verlies
--   4. beurtenkaarten   -> tegoed in beurten
--   5. abonnementen     -> 3/6/12 maanden
--   6. clubsessies      -> momenten waar leden aan toegewezen worden
--   7. checkins         -> elke scan + wachtkamerstatus + toewijzing
--   8. handelingen_log  -> audit: welke medewerker deed wat, wanneer
-- ============================================================================

-- Zorg dat we UUID's kunnen genereren (Supabase heeft dit meestal al aanstaan).
create extension if not exists "pgcrypto";


-- ============================================================================
-- 1. MEDEWERKERS
-- ----------------------------------------------------------------------------
-- Medewerkers werken aan de lokale kassa. Login is bewust laagdrempelig:
-- aan de kassa selecteer je gewoon wie er werkt. De PIN is optioneel en dient
-- enkel om per ongeluk wisselen te vermijden, niet als strenge beveiliging.
-- Admins kunnen medewerkers toevoegen en clubsessies beheren.
-- ============================================================================
create table medewerkers (
    id              uuid primary key default gen_random_uuid(),
    voornaam        text not null,
    achternaam      text,
    is_admin        boolean not null default false,
    -- Optionele korte pincode (bv. 4 cijfers) om snel te wisselen aan de kassa.
    pincode         text,
    actief          boolean not null default true,
    aangemaakt_op   timestamptz not null default now()
);

comment on table medewerkers is
    'Medewerkers die aan de kassa werken. Login is laagdrempelig; handelingen worden wel gelogd.';


-- ============================================================================
-- 2. LEDEN
-- ----------------------------------------------------------------------------
-- De kern van het systeem. We houden BEWUST WEINIG gegevens bij (GDPR/AVG).
--   - naam en foto: enkel om het lid te herkennen aan de kassa.
--   - geboortejaar, postcode, herkomst: ENKEL voor anonieme statistiek.
--     Deze velden mogen NOOIT gebruikt worden om individuen te profileren.
--   - sociaal_tarief: bepaalt of het lid met de A-Kaart moet inchecken.
--
-- We slaan het geboorteJAAR op, niet de volledige geboortedatum: dat is genoeg
-- voor leeftijdsstatistiek en is privacyvriendelijker (dataminimalisatie).
-- ============================================================================
create table leden (
    id                  uuid primary key default gen_random_uuid(),

    -- Herkenning aan de kassa
    voornaam            text not null,
    achternaam          text,
    -- Verwijzing naar de fotobestand in Supabase Storage (mag leeg blijven).
    foto_pad            text,

    -- Contact (optioneel; e-mail is een @risingyou.be Outlook-adres of privé)
    email               text,
    telefoon            text,

    -- Sociaal tarief: zo ja, moet lid met A-Kaart inchecken (apart systeem).
    sociaal_tarief      boolean not null default false,

    -- ENKEL VOOR STATISTIEK — niet koppelen aan individu in rapporten.
    geboortejaar        integer,
    postcode            text,
    herkomst            text,

    -- Koppeling naar het online account (website). Leeg tot het lid registreert.
    -- Verwijst naar auth.users.id van Supabase. Zo kan de kern later netjes
    -- aansluiten op zelfregistratie zonder herstructurering.
    auth_user_id        uuid,

    actief              boolean not null default true,
    aangemaakt_op       timestamptz not null default now(),
    bijgewerkt_op       timestamptz not null default now()
);

comment on table leden is
    'Leden van Rising You. Minimale persoonsgegevens (GDPR). Statistiekvelden niet individueel gebruiken.';
comment on column leden.geboortejaar is
    'Alleen het jaar, voor anonieme leeftijdsstatistiek. Geen volledige geboortedatum (dataminimalisatie).';
comment on column leden.auth_user_id is
    'Koppeling met online account (Supabase auth). Leeg tot het lid zelf registreert op risingyou.be.';


-- ============================================================================
-- 3. NAAMKAARTJES (QR)
-- ----------------------------------------------------------------------------
-- Elk lid heeft één GELDIG naamkaartje met een unieke QR-code. Bij verlies
-- maakt een medewerker een nieuw kaartje; het oude wordt dan automatisch
-- ongeldig (failsafe). Daarom houden we ALLE kaartjes bij, met een vlag.
--
-- De QR-code bevat een willekeurige, niet-raadbare token (geen lidnaam of id),
-- zodat een gevonden kaartje niets prijsgeeft.
-- ============================================================================
create table naamkaartjes (
    id              uuid primary key default gen_random_uuid(),
    lid_id          uuid not null references leden(id) on delete cascade,

    -- De waarde die letterlijk in de QR-code staat. Uniek en niet-raadbaar.
    qr_token        text not null unique,

    geldig          boolean not null default true,

    aangemaakt_op   timestamptz not null default now(),
    -- Wie maakte dit kaartje aan (voor de audit / failsafe-historiek).
    aangemaakt_door uuid references medewerkers(id)
);

comment on table naamkaartjes is
    'QR-naamkaartjes. Per lid is er telkens één geldig kaartje; oude kaartjes worden ongeldig bij verlies.';
comment on column naamkaartjes.qr_token is
    'Willekeurige niet-raadbare token in de QR-code. Bevat geen naam of id (privacy).';

-- Snel het geldige kaartje van een lid terugvinden.
create index idx_naamkaartjes_lid_geldig on naamkaartjes(lid_id) where geldig;
-- Snel zoeken op token bij het scannen.
create index idx_naamkaartjes_token on naamkaartjes(qr_token);


-- ----------------------------------------------------------------------------
-- FAILSAFE: zodra een NIEUW geldig kaartje voor een lid wordt aangemaakt,
-- worden alle andere kaartjes van datzelfde lid automatisch ongeldig.
-- Dit gebeurt in de database zelf, zodat het altijd klopt — ongeacht of de
-- kassa-app, de website of een script het kaartje aanmaakt.
-- ----------------------------------------------------------------------------
create or replace function fn_kaartje_failsafe()
returns trigger
language plpgsql
as $$
begin
    if new.geldig then
        update naamkaartjes
           set geldig = false
         where lid_id = new.lid_id
           and id <> new.id
           and geldig;
    end if;
    return new;
end;
$$;

create trigger trg_kaartje_failsafe
    after insert on naamkaartjes
    for each row
    execute function fn_kaartje_failsafe();


-- ============================================================================
-- 4. BEURTENKAARTEN
-- ----------------------------------------------------------------------------
-- Een lid kan één of meer beurtenkaarten hebben. We tellen het saldo per kaart.
-- Een beurt wordt afgetrokken bij een geslaagde check-in (zie checkins).
-- We bewaren het oorspronkelijke aantal én het resterende aantal, zodat de
-- website "X van Y beurten over" kan tonen.
-- ============================================================================
create table beurtenkaarten (
    id                  uuid primary key default gen_random_uuid(),
    lid_id              uuid not null references leden(id) on delete cascade,

    beurten_totaal      integer not null check (beurten_totaal > 0),
    beurten_resterend   integer not null check (beurten_resterend >= 0),

    actief              boolean not null default true,
    aangemaakt_op       timestamptz not null default now(),
    aangemaakt_door     uuid references medewerkers(id),

    constraint chk_resterend_max check (beurten_resterend <= beurten_totaal)
);

comment on table beurtenkaarten is
    'Beurtentegoed van een lid. Beurt wordt afgetrokken bij geslaagde check-in.';

create index idx_beurtenkaarten_lid on beurtenkaarten(lid_id) where actief;


-- ============================================================================
-- 5. ABONNEMENTEN
-- ----------------------------------------------------------------------------
-- Abonnementen lopen 3, 6 of 12 maanden. Een lid mag tegelijk een abonnement
-- én een beurtenkaart hebben. Bij check-in geldt: heeft het lid een GELDIG
-- abonnement (vandaag tussen start en eind), dan is de check-in groen zonder
-- dat er een beurt wordt afgetrokken. Anders kijken we naar de beurtenkaart.
-- ============================================================================
create type abonnement_duur as enum ('3_maanden', '6_maanden', '12_maanden');

create table abonnementen (
    id              uuid primary key default gen_random_uuid(),
    lid_id          uuid not null references leden(id) on delete cascade,

    duur            abonnement_duur not null,
    start_datum     date not null,
    eind_datum      date not null,

    actief          boolean not null default true,
    aangemaakt_op   timestamptz not null default now(),
    aangemaakt_door uuid references medewerkers(id),

    constraint chk_periode check (eind_datum >= start_datum)
);

comment on table abonnementen is
    'Abonnementen van 3, 6 of 12 maanden. Geldig abonnement = groene check-in zonder beurt af te trekken.';

create index idx_abonnementen_lid on abonnementen(lid_id) where actief;


-- ============================================================================
-- 6. CLUBSESSIES
-- ----------------------------------------------------------------------------
-- Admins maken clubsessies aan (terugkerend of eenmalig). Ingecheckte leden
-- worden vanuit de wachtkamer aan een clubsessie OF aan een losse klimsessie
-- toegewezen. We modelleren de losse klimsessie niet als rij: dat is gewoon
-- de toewijzing "los" in de check-in (zie checkins.toewijzing).
-- ============================================================================
create table clubsessies (
    id              uuid primary key default gen_random_uuid(),
    naam            text not null,
    omschrijving    text,

    -- Wanneer de sessie plaatsvindt. Voor terugkerende sessies maak je telkens
    -- een concrete sessie aan op datum (eenvoudig en duidelijk te beheren).
    datum           date not null,
    start_tijd      time,
    eind_tijd       time,

    actief          boolean not null default true,
    aangemaakt_op   timestamptz not null default now(),
    aangemaakt_door uuid references medewerkers(id)
);

comment on table clubsessies is
    'Door admins aangemaakte clubmomenten. Leden worden vanuit de wachtkamer toegewezen.';

create index idx_clubsessies_datum on clubsessies(datum) where actief;


-- ============================================================================
-- 7. CHECK-INS  (incl. wachtkamer en toewijzing)
-- ----------------------------------------------------------------------------
-- Elke scan maakt een check-in aan. De check-in doorloopt een eenvoudige flow:
--
--   gescand  ->  in_wachtkamer  ->  toegewezen
--
-- In de wachtkamer moet de medewerker AFVINKEN:
--   - betaling_ok     : geldige beurt/abonnement of ter plaatse bijbetaald
--   - akaart_ok       : enkel nodig bij sociaal tarief (A-Kaart apart gescand)
-- Pas als alles ok is, mag het lid versleept worden naar een clubsessie of
-- naar een losse klimsessie (toewijzing).
--
-- 'resultaat' legt vast wat de scan opleverde (groen/rood) op het moment zelf,
-- zodat de historiek klopt ook al verandert het tegoed later.
-- ============================================================================
create type checkin_resultaat as enum ('groen', 'rood');
create type checkin_status    as enum ('in_wachtkamer', 'toegewezen', 'geannuleerd');
create type toewijzing_type   as enum ('losse_klimsessie', 'clubsessie');

create table checkins (
    id                  uuid primary key default gen_random_uuid(),
    lid_id              uuid not null references leden(id),
    -- Welk kaartje werd gescand (kan later ongeldig worden; we bewaren de ref).
    naamkaartje_id      uuid references naamkaartjes(id),

    -- Wie bediende de kassa op het moment van de scan.
    medewerker_id       uuid references medewerkers(id),

    -- Uitkomst van de scan op dat moment.
    resultaat           checkin_resultaat not null,
    -- Indien een beurt werd afgetrokken: van welke kaart.
    beurtenkaart_id     uuid references beurtenkaarten(id),
    beurt_afgetrokken   boolean not null default false,

    -- Wachtkamer-afvinkjes.
    betaling_ok         boolean not null default false,
    -- akaart_ok is null als het lid GEEN sociaal tarief heeft (niet van toepassing).
    akaart_ok           boolean,

    status              checkin_status not null default 'in_wachtkamer',

    -- Toewijzing (ingevuld zodra het lid uit de wachtkamer gaat).
    toewijzing          toewijzing_type,
    clubsessie_id       uuid references clubsessies(id),

    gescand_op          timestamptz not null default now(),
    toegewezen_op       timestamptz,

    -- Een lid kan niet twee keer tegelijk in de wachtkamer staan: dit dwingen
    -- we af in de app-laag; in de db houden we het flexibel voor heropeningen.

    constraint chk_clubsessie_verwijzing check (
        (toewijzing = 'clubsessie' and clubsessie_id is not null)
        or (toewijzing is distinct from 'clubsessie')
    )
);

comment on table checkins is
    'Elke scan = een check-in. Doorloopt wachtkamer (betaling + evt. A-Kaart afvinken) naar toewijzing.';
comment on column checkins.akaart_ok is
    'null = lid heeft geen sociaal tarief (niet van toepassing). true/false = A-Kaart-check afgevinkt of niet.';

create index idx_checkins_status on checkins(status) where status = 'in_wachtkamer';
create index idx_checkins_dag on checkins(gescand_op);
create index idx_checkins_clubsessie on checkins(clubsessie_id);


-- ============================================================================
-- 8. HANDELINGEN-LOG  (audit)
-- ----------------------------------------------------------------------------
-- Omdat de lokale login laagdrempelig is, loggen we WEL elke betekenisvolle
-- handeling: welke medewerker deed wat, wanneer, op welk lid/object. Zo blijft
-- alles herleidbaar zonder strenge inlogdrempel.
-- ============================================================================
create table handelingen_log (
    id              uuid primary key default gen_random_uuid(),
    medewerker_id   uuid references medewerkers(id),

    -- Korte code van de handeling, bv: 'checkin', 'kaartje_aangemaakt',
    -- 'beurt_afgetrokken', 'betaling_afgevinkt', 'akaart_afgevinkt',
    -- 'lid_aangemaakt', 'toegewezen'.
    handeling       text not null,

    -- Vrij omschrijvingsveld in eenvoudige taal (voor leesbaarheid in rapport).
    omschrijving    text,

    -- Optionele verwijzingen naar betrokken objecten.
    lid_id          uuid references leden(id),
    checkin_id      uuid references checkins(id),

    gebeurd_op      timestamptz not null default now()
);

comment on table handelingen_log is
    'Audit-log: welke medewerker voerde welke handeling uit, en wanneer. Compenseert de laagdrempelige login.';

create index idx_log_medewerker on handelingen_log(medewerker_id);
create index idx_log_dag on handelingen_log(gebeurd_op);
