-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0009: check-in bron, sessie-dagen en geleende beurt
-- ----------------------------------------------------------------------------
-- Wijzigingen op basis van feedback:
--   - Elke check-in registreert VANWAAR ze komt (kassa, mobiel, website),
--     zodat een latere mobiele check-in-app netjes kan aansluiten.
--   - Clubsessies krijgen een set weekdagen waarop ze actief zijn; de check-in
--     toont enkel de sessies die VANDAAG actief zijn.
--   - Bij een geleende beurt onthouden we van wie geleend werd (voor de audit
--     en om de juiste kaart te kunnen herstellen).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. CHECK-IN BRON (uitbreidbaar via enum)
-- ----------------------------------------------------------------------------
do $$
begin
    if not exists (select 1 from pg_type where typname = 'checkin_bron') then
        create type checkin_bron as enum ('kassa', 'mobiel', 'website');
    end if;
end$$;

alter table checkins
    add column if not exists bron checkin_bron not null default 'kassa';

comment on column checkins.bron is
    'Vanwaar de check-in kwam: kassa (lokale app), mobiel (toekomstige app) of website.';


-- ----------------------------------------------------------------------------
-- 2. GELEENDE BEURT: van wie werd geleend
-- ----------------------------------------------------------------------------
alter table checkins
    add column if not exists geleend_van_lid_id uuid references leden(id);

comment on column checkins.geleend_van_lid_id is
    'Indien de beurt geleend werd van een gezinslid: het lid van wie de beurtenkaart gebruikt is.';


-- ----------------------------------------------------------------------------
-- 3. CLUBSESSIES: op welke weekdagen actief
-- We bewaren de weekdagen als een set integers (0=zondag .. 6=zaterdag),
-- plus een optionele losse datum voor eenmalige sessies. De check-in filtert
-- op de huidige weekdag.
-- ----------------------------------------------------------------------------
alter table clubsessies
    add column if not exists weekdagen integer[] default '{}',
    add column if not exists eenmalige_datum date;

comment on column clubsessies.weekdagen is
    'Weekdagen waarop de sessie terugkeert (0=zondag .. 6=zaterdag). Leeg bij een eenmalige sessie.';
comment on column clubsessies.eenmalige_datum is
    'Voor een eenmalige sessie: de concrete datum. Anders leeg (dan gelden de weekdagen).';

-- De bestaande 'datum'-kolom uit migratie 0001 blijft bruikbaar voor eenmalige
-- sessies; we synchroniseren eenmalige_datum ermee waar nodig in de app-laag.


-- ----------------------------------------------------------------------------
-- 4. fn_sessies_van_dag
-- Geeft de clubsessies terug die op een bepaalde datum actief zijn:
--   - terugkerende sessies waarvan de weekdag overeenkomt, OF
--   - eenmalige sessies met die exacte datum.
-- ----------------------------------------------------------------------------
create or replace function fn_sessies_van_dag(p_datum date)
returns table (
    id          uuid,
    naam        text,
    activiteit  text,
    start_tijd  time,
    eind_tijd   time
)
language sql
stable
as $$
    select c.id, c.naam, c.activiteit, c.start_tijd, c.eind_tijd
    from clubsessies c
    where c.actief
      and (
        (c.eenmalige_datum is not null and c.eenmalige_datum = p_datum)
        or
        (c.eenmalige_datum is null
         and extract(dow from p_datum)::int = any(c.weekdagen))
      )
    order by c.start_tijd nulls last, c.naam;
$$;

comment on function fn_sessies_van_dag is
    'Geeft de clubsessies die op een bepaalde dag actief zijn (terugkerend op weekdag of eenmalig op datum).';
