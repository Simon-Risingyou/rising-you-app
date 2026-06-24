-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0008: activiteiten, lidmaatschapstypes en herdachte tegoed-logica
-- ----------------------------------------------------------------------------
-- Grote herziening op basis van feedback:
--   - Beurtenkaarten en abonnementen krijgen een ACTIVITEIT (klimmen, yoga,
--     workout — uitbreidbaar) en een TARIEFTYPE (kind, student, volwassene).
--   - Een clubsessie heeft een vaste activiteit (admin kiest die bij aanmaken).
--     Een losse klimsessie gaat altijd over 'klimmen'.
--   - Bij toewijzing wordt enkel tegoed van de JUISTE activiteit gebruikt:
--       1. geldig abonnement voor die activiteit -> niets aftrekken
--       2. anders eigen beurtenkaart voor die activiteit -> 1 beurt af
--       3. anders (na bevestiging) lenen van een gezinslid -> alleen beurten
--       4. anders foutmelding / losse beurt betalen aan de kassa
--   - Abonnementen zijn STRIKT persoonsgebonden: nooit lenen.
--   - Tarieftype: kind = 0-13 jaar (auto op geboortejaar), student vanaf 14
--     (auto), student blijft student tot admin het handmatig op volwassene zet.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ACTIVITEITEN (uitbreidbaar)
-- We zetten activiteiten in een tabel i.p.v. een vaste enum, zodat je later
-- gewoon een rij toevoegt voor een nieuwe activiteit (geen migratie nodig).
-- ----------------------------------------------------------------------------
create table activiteiten (
    code        text primary key,        -- bv. 'klimmen', 'yoga', 'workout'
    naam        text not null,            -- weergavenaam in het Nederlands
    actief      boolean not null default true,
    volgorde    integer not null default 0
);

insert into activiteiten (code, naam, volgorde) values
    ('klimmen', 'Klimmen', 1),
    ('yoga',    'Yoga',    2),
    ('workout', 'We Workout', 3);

comment on table activiteiten is
    'Activiteiten waarvoor lidmaatschappen gelden. Uitbreidbaar: voeg een rij toe voor een nieuwe activiteit.';


-- ----------------------------------------------------------------------------
-- 2. TARIEFTYPE
-- Het tarieftype bepaalt welk tarief geldt. 'kind' en 'student' worden
-- afgeleid van de leeftijd; 'volwassene' wordt handmatig gezet door een admin.
-- ----------------------------------------------------------------------------
create type tarieftype as enum ('kind', 'student', 'volwassene');

-- Per lid onthouden we of een admin het tarieftype handmatig heeft vastgezet
-- (bv. student -> volwassene). Zo niet, dan leidt de app het af van de leeftijd.
alter table leden
    add column if not exists tarieftype_handmatig tarieftype;

comment on column leden.tarieftype_handmatig is
    'Indien gezet door een admin: overschrijft het automatisch afgeleide tarieftype (bv. student -> volwassene).';

-- Hulpfunctie: leidt het tarieftype af. Handmatige waarde wint; anders op leeftijd.
-- kind = 0-13 jaar, student = vanaf 14 jaar (tot admin het op volwassene zet).
create or replace function fn_tarieftype(p_lid_id uuid)
returns tarieftype
language sql
stable
as $$
    select case
        when l.tarieftype_handmatig is not null then l.tarieftype_handmatig
        when l.geboortejaar is null then 'student'::tarieftype
        when (extract(year from current_date)::int - l.geboortejaar) <= 13 then 'kind'::tarieftype
        else 'student'::tarieftype
    end
    from leden l where l.id = p_lid_id;
$$;

comment on function fn_tarieftype is
    'Tarieftype van een lid: handmatige admin-waarde wint, anders kind (0-13) of student (14+) op leeftijd.';


-- ----------------------------------------------------------------------------
-- 3. ACTIVITEIT + TYPE op beurtenkaarten en abonnementen
-- ----------------------------------------------------------------------------
alter table beurtenkaarten
    add column if not exists activiteit text references activiteiten(code),
    add column if not exists tarief tarieftype;

alter table abonnementen
    add column if not exists activiteit text references activiteiten(code),
    add column if not exists tarief tarieftype;

comment on column beurtenkaarten.activiteit is 'Voor welke activiteit deze beurten gelden (klimmen/yoga/workout).';
comment on column abonnementen.activiteit is 'Voor welke activiteit dit abonnement geldt.';

-- Bestaande rijen krijgen 'klimmen' als standaard (enige actieve activiteit nu).
update beurtenkaarten set activiteit = 'klimmen' where activiteit is null;
update abonnementen   set activiteit = 'klimmen' where activiteit is null;


-- ----------------------------------------------------------------------------
-- 4. ACTIVITEIT op clubsessies
-- Admin kiest de activiteit bij het aanmaken van een clubsessie.
-- ----------------------------------------------------------------------------
alter table clubsessies
    add column if not exists activiteit text references activiteiten(code) default 'klimmen';

comment on column clubsessies.activiteit is 'Vaste activiteit van de clubsessie, gekozen door de admin bij aanmaken.';


-- ----------------------------------------------------------------------------
-- 5. fn_beschikbaar_tegoed
-- Geeft voor een lid + activiteit terug wat er beschikbaar is:
--   - heeft het een geldig abonnement voor die activiteit?
--   - hoeveel beurten heeft het voor die activiteit?
-- Gebruikt door de check-in om te bepalen of toewijzing mag en wat afgaat.
-- ----------------------------------------------------------------------------
create or replace function fn_beschikbaar_tegoed(
    p_lid_id      uuid,
    p_activiteit  text
)
returns table (
    abonnement_geldig  boolean,
    abonnement_tot     date,
    beurten            integer,
    beurtenkaart_id    uuid
)
language plpgsql
stable
as $$
declare
    v_abo_tot   date;
    v_beurten   integer;
    v_kaart_id  uuid;
begin
    select max(eind_datum) into v_abo_tot
      from abonnementen
     where lid_id = p_lid_id and actief and activiteit = p_activiteit
       and current_date between start_datum and eind_datum;

    -- Eerst-aangemaakte kaart met saldo voor deze activiteit.
    select id, beurten_resterend into v_kaart_id, v_beurten
      from beurtenkaarten
     where lid_id = p_lid_id and actief and activiteit = p_activiteit
       and beurten_resterend > 0
     order by aangemaakt_op asc
     limit 1;

    return query select
        (v_abo_tot is not null),
        v_abo_tot,
        coalesce((select sum(beurten_resterend)::int from beurtenkaarten
                  where lid_id = p_lid_id and actief and activiteit = p_activiteit), 0),
        v_kaart_id;
end;
$$;

comment on function fn_beschikbaar_tegoed is
    'Geeft per lid + activiteit het beschikbare tegoed: geldig abonnement en/of beurten + de eerst te gebruiken kaart.';


-- ----------------------------------------------------------------------------
-- 6. fn_leen_beurt_van_gezin
-- Zoekt binnen het gezin van p_lid_id een ANDER lid met een beurtenkaart voor
-- de gevraagde activiteit (met saldo). Geeft kandidaten terug zodat de kassa
-- kan vragen of geleend mag worden. LENEN MAG NOOIT met abonnementen.
-- ----------------------------------------------------------------------------
create or replace function fn_leenbare_gezinsbeurten(
    p_lid_id      uuid,
    p_activiteit  text
)
returns table (
    lener_lid_id  uuid,
    voornaam      text,
    beurten       integer,
    beurtenkaart_id uuid,
    tarief        tarieftype
)
language sql
stable
as $$
    with mijn_gezin as (
        select gezin_id from gezinsleden where lid_id = p_lid_id
    )
    select l.id, l.voornaam,
           bk.beurten_resterend, bk.id, bk.tarief
    from gezinsleden gl
    join leden l on l.id = gl.lid_id
    join beurtenkaarten bk on bk.lid_id = l.id and bk.actief
         and bk.activiteit = p_activiteit and bk.beurten_resterend > 0
    where gl.gezin_id in (select gezin_id from mijn_gezin)
      and gl.lid_id <> p_lid_id
    order by bk.beurten_resterend desc;
$$;

comment on function fn_leenbare_gezinsbeurten is
    'Geeft gezinsleden met een beurtenkaart (juiste activiteit, saldo) van wie geleend kan worden. Nooit abonnementen.';
