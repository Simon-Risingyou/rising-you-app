-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0007: gezinnen (gelinkte profielen) en gezins-check-in
-- ----------------------------------------------------------------------------
-- Doel: een voogd kan voor het hele gezin inchecken zonder dat elk gezinslid
-- een eigen kaartje hoeft te scannen. Bij de check-in van een gezinslid komen
-- de andere gelinkte leden als aanvinkbare opties in de wachtkamer.
--
-- Keuzes (op basis van afstemming):
--   - Een gezin is een VRIJE groep gelinkte leden. Rollen ('voogd1', 'kind1'…)
--     zijn enkel labels voor de duidelijkheid, geen harde regels.
--   - Per gezinslid kan de medewerker bij check-in kiezen: meebetalen (eigen
--     beurt/abo) of gratis meedoen. Er moet MINSTENS ÉÉN betalende check-in zijn.
--   - De A-Kaart wordt één keer voor de hele groep afgevinkt (voogd regelt dit).
--   - Kinderen kunnen ALTIJD nog apart inchecken met hun eigen kaartje.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. GEZINNEN
-- Een gezin groepeert leden. We houden het bewust simpel: een gezin is enkel
-- een id met een naam (bv. "Gezin Haddad"), en leden verwijzen ernaar.
-- ----------------------------------------------------------------------------
create table gezinnen (
    id              uuid primary key default gen_random_uuid(),
    naam            text not null,
    aangemaakt_op   timestamptz not null default now(),
    aangemaakt_door uuid references medewerkers(id)
);

comment on table gezinnen is
    'Een gezin groepeert gelinkte leden zodat een voogd voor de hele groep kan inchecken.';

-- ----------------------------------------------------------------------------
-- 2. GEZINSLEDEN
-- Koppeltabel: welk lid hoort bij welk gezin, met een rol als label.
-- Een lid kan in principe bij één gezin horen (uniek op lid_id), wat het
-- gedrag voorspelbaar houdt. Wil je later meerdere gezinnen toelaten, dan
-- verwijder je de unique-constraint.
-- ----------------------------------------------------------------------------
create type gezinsrol as enum ('voogd', 'kind', 'lid');

create table gezinsleden (
    id          uuid primary key default gen_random_uuid(),
    gezin_id    uuid not null references gezinnen(id) on delete cascade,
    lid_id      uuid not null references leden(id) on delete cascade,
    rol         gezinsrol not null default 'lid',
    -- volgnummer voor weergave (voogd1, voogd2, kind1, kind2 …)
    volgorde    integer not null default 0,

    unique (lid_id)
);

comment on table gezinsleden is
    'Koppelt leden aan een gezin met een rol (voogd/kind/lid) als label.';

create index idx_gezinsleden_gezin on gezinsleden(gezin_id);


-- ----------------------------------------------------------------------------
-- 3. CHECK-IN: groepeer gezins-check-ins
-- We voegen een 'groep_id' toe zodat check-ins die samen gebeurd zijn (de
-- voogd + aangevinkte kinderen) herkenbaar bij elkaar horen. Dat is handig voor
-- het overzicht en om een hele groep in één keer te kunnen herstellen.
-- ----------------------------------------------------------------------------
alter table checkins
    add column if not exists groep_id uuid,
    add column if not exists is_betalend boolean not null default true;

comment on column checkins.groep_id is
    'Check-ins met dezelfde groep_id zijn samen ingecheckt als gezin (voogd + kinderen).';
comment on column checkins.is_betalend is
    'false = dit gezinslid doet gratis mee (geen beurt/abo gebruikt). Minstens één in de groep moet betalend zijn.';


-- ----------------------------------------------------------------------------
-- 4. fn_gezin_van_lid
-- Geeft de andere gezinsleden van een lid terug (voor de aanvinkbare opties
-- in de wachtkamer), met hun rol en huidige beurt/abo-status.
-- ----------------------------------------------------------------------------
create or replace function fn_gezin_van_lid(p_lid_id uuid)
returns table (
    lid_id            uuid,
    voornaam          text,
    achternaam        text,
    rol               gezinsrol,
    volgorde          integer,
    beurten_resterend integer,
    abonnement_tot    date,
    sociaal_tarief    boolean
)
language sql
stable
as $$
    with mijn_gezin as (
        select gezin_id from gezinsleden where lid_id = p_lid_id
    )
    select l.id, l.voornaam, l.achternaam, gl.rol, gl.volgorde,
           coalesce((select sum(beurten_resterend)::int from beurtenkaarten
                     where lid_id = l.id and actief), 0),
           (select max(eind_datum) from abonnementen
             where lid_id = l.id and actief and current_date between start_datum and eind_datum),
           l.sociaal_tarief
    from gezinsleden gl
    join leden l on l.id = gl.lid_id
    where gl.gezin_id in (select gezin_id from mijn_gezin)
      and gl.lid_id <> p_lid_id
      and l.actief
    order by gl.rol, gl.volgorde, l.voornaam;
$$;

comment on function fn_gezin_van_lid is
    'Geeft de andere gezinsleden van een lid terug, voor de aanvinkbare opties bij gezins-check-in.';


-- ----------------------------------------------------------------------------
-- 5. fn_maak_gezin / fn_voeg_toe_aan_gezin / fn_verwijder_uit_gezin
-- Beheer van gezinnen vanuit het ledenbeheer.
-- ----------------------------------------------------------------------------
create or replace function fn_maak_gezin(
    p_naam           text,
    p_medewerker_id  uuid
)
returns uuid
language plpgsql
as $$
declare v_id uuid;
begin
    insert into gezinnen (naam, aangemaakt_door) values (p_naam, p_medewerker_id)
    returning id into v_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'gezin_aangemaakt', 'Gezin aangemaakt: ' || p_naam);
    return v_id;
end;
$$;

create or replace function fn_voeg_toe_aan_gezin(
    p_gezin_id       uuid,
    p_lid_id         uuid,
    p_rol            gezinsrol,
    p_medewerker_id  uuid
)
returns text
language plpgsql
as $$
declare v_volg integer;
begin
    -- Als het lid al in een ander gezin zit, eerst verwijderen (uniek per lid).
    delete from gezinsleden where lid_id = p_lid_id;
    select coalesce(max(volgorde),0)+1 into v_volg from gezinsleden
      where gezin_id = p_gezin_id and rol = p_rol;
    insert into gezinsleden (gezin_id, lid_id, rol, volgorde)
    values (p_gezin_id, p_lid_id, p_rol, v_volg);
    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'gezinslid_toegevoegd', 'Toegevoegd aan gezin als ' || p_rol::text, p_lid_id);
    return 'ok';
end;
$$;

create or replace function fn_verwijder_uit_gezin(
    p_lid_id         uuid,
    p_medewerker_id  uuid
)
returns text
language plpgsql
as $$
begin
    delete from gezinsleden where lid_id = p_lid_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'gezinslid_verwijderd', 'Uit gezin gehaald', p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_maak_gezin is 'Maakt een nieuw gezin aan.';
comment on function fn_voeg_toe_aan_gezin is 'Voegt een lid toe aan een gezin met een rol (voogd/kind/lid).';
comment on function fn_verwijder_uit_gezin is 'Haalt een lid uit zijn gezin.';
