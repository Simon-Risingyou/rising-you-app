-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0004: eenmalige klanten, 'alleen info', annuleren met herstel
-- ----------------------------------------------------------------------------
-- Wijzigingen op basis van feedback:
--   - Leden kunnen 'kaartloos' zijn (eenmalige clubsessie-klanten zonder QR).
--   - Een check-in kan van het type 'alleen_info' zijn: lid bekijkt enkel zijn
--     profiel, er wordt GEEN beurt afgetrokken.
--   - Een check-in annuleren herstelt automatisch de afgetrokken beurt.
--   - fn_zoek_leden: manueel opzoeken van een klant zonder te scannen.
--   - fn_checkin_lid: rechtstreeks inchecken op lid-id (manueel of nieuw profiel),
--     zonder QR-token.
-- ============================================================================

-- 'land van herkomst' staat al als 'herkomst' in de ledentabel; we hernoemen
-- het commentaar voor duidelijkheid (kolomnaam blijft 'herkomst').
comment on column leden.herkomst is
    'Land van herkomst. Alleen voor anonieme statistiek; niet individueel gebruiken.';

-- Markeer of een lid een vast lid is of een eenmalige/kaartloze klant.
alter table leden
    add column if not exists is_eenmalig boolean not null default false;
comment on column leden.is_eenmalig is
    'true = eenmalige/kaartloze klant (bv. clubsessie), heeft geen QR-kaartje nodig.';

-- Check-in krijgt een type: gewone check-in of 'alleen info' (geen beurt).
do $$
begin
    if not exists (select 1 from pg_type where typname = 'checkin_soort') then
        create type checkin_soort as enum ('check_in', 'alleen_info');
    end if;
end$$;

alter table checkins
    add column if not exists soort checkin_soort not null default 'check_in';
comment on column checkins.soort is
    '''alleen_info'' = lid bekeek enkel het profiel; geen beurt afgetrokken.';


-- ----------------------------------------------------------------------------
-- fn_annuleer_checkin
-- Annuleert een check-in (verkeerde of dubbele scan). Herstelt de afgetrokken
-- beurt indien er een was. Zet de status op 'geannuleerd' en logt het.
-- Werkt zowel vanuit de wachtkamer als vanuit het dagoverzicht.
-- ----------------------------------------------------------------------------
create or replace function fn_annuleer_checkin(
    p_checkin_id     uuid,
    p_medewerker_id  uuid,
    p_reden          text default null
)
returns text
language plpgsql
as $$
declare
    v_checkin checkins%rowtype;
begin
    select * into v_checkin from checkins where id = p_checkin_id for update;
    if not found then
        return 'Check-in niet gevonden.';
    end if;

    if v_checkin.status = 'geannuleerd' then
        return 'Deze check-in is al geannuleerd.';
    end if;

    -- Herstel de beurt als er een werd afgetrokken.
    if v_checkin.beurt_afgetrokken and v_checkin.beurtenkaart_id is not null then
        update beurtenkaarten
           set beurten_resterend = least(beurten_resterend + 1, beurten_totaal)
         where id = v_checkin.beurtenkaart_id;
    end if;

    update checkins
       set status = 'geannuleerd'
     where id = p_checkin_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (p_medewerker_id, 'checkin_geannuleerd',
            coalesce('Check-in geannuleerd: ' || p_reden, 'Check-in geannuleerd.')
            || case when v_checkin.beurt_afgetrokken then ' Beurt hersteld.' else '' end,
            v_checkin.lid_id, p_checkin_id);

    return 'ok';
end;
$$;

comment on function fn_annuleer_checkin is
    'Annuleert een check-in en herstelt de eventueel afgetrokken beurt. Voor verkeerde/dubbele scans.';


-- ----------------------------------------------------------------------------
-- fn_checkin_lid
-- Checkt een lid rechtstreeks in op lid-id (zonder QR). Voor manueel opzoeken
-- en voor nieuwe/eenmalige profielen die meteen in de wachtkamer komen.
-- p_soort: 'check_in' (normaal, beurt-logica) of 'alleen_info' (geen beurt).
-- Hergebruikt dezelfde groen/rood- en beurt-logica als de scan.
-- ----------------------------------------------------------------------------
create or replace function fn_checkin_lid(
    p_lid_id         uuid,
    p_medewerker_id  uuid,
    p_soort          checkin_soort default 'check_in'
)
returns table (
    checkin_id          uuid,
    lid_id              uuid,
    voornaam            text,
    achternaam          text,
    foto_pad            text,
    sociaal_tarief      boolean,
    resultaat           checkin_resultaat,
    beurten_resterend   integer,
    abonnement_geldig   boolean,
    abonnement_tot      date,
    soort               checkin_soort
)
language plpgsql
as $$
declare
    v_lid        leden%rowtype;
    v_abo        abonnementen%rowtype;
    v_kaart      beurtenkaarten%rowtype;
    v_resultaat  checkin_resultaat;
    v_beurt_af   boolean := false;
    v_kaart_id   uuid := null;
    v_rest       integer := null;
    v_abo_geldig boolean := false;
    v_abo_tot    date := null;
    v_checkin_id uuid;
begin
    select * into v_lid from leden where id = p_lid_id and actief;
    if not found then
        return query select null::uuid,null::uuid,null::text,null::text,null::text,
                            null::boolean,null::checkin_resultaat,null::integer,
                            null::boolean,null::date,null::checkin_soort;
        return;
    end if;

    -- 'Alleen info': geen beurt, altijd groen (puur tonen).
    if p_soort = 'alleen_info' then
        v_resultaat := 'groen';
        -- toon resterende beurten ter info
        select beurten_resterend into v_rest
          from beurtenkaarten
         where lid_id = v_lid.id and actief and beurten_resterend > 0
         order by aangemaakt_op asc limit 1;
        select eind_datum into v_abo_tot
          from abonnementen
         where lid_id = v_lid.id and actief and current_date between start_datum and eind_datum
         order by eind_datum desc limit 1;
        v_abo_geldig := v_abo_tot is not null;
    else
        -- Normale check-in: zelfde logica als scan.
        select * into v_abo from abonnementen
         where lid_id = v_lid.id and actief
           and current_date between start_datum and eind_datum
         order by eind_datum desc limit 1;

        if found then
            v_abo_geldig := true; v_abo_tot := v_abo.eind_datum; v_resultaat := 'groen';
        else
            select * into v_kaart from beurtenkaarten
             where lid_id = v_lid.id and actief and beurten_resterend > 0
             order by aangemaakt_op asc limit 1 for update;
            if found then
                update beurtenkaarten set beurten_resterend = beurten_resterend - 1
                 where id = v_kaart.id returning beurten_resterend into v_rest;
                v_beurt_af := true; v_kaart_id := v_kaart.id; v_resultaat := 'groen';
            else
                v_resultaat := 'rood';
            end if;
        end if;
    end if;

    insert into checkins (
        lid_id, medewerker_id, resultaat, beurtenkaart_id, beurt_afgetrokken,
        betaling_ok, akaart_ok, status, soort
    )
    values (
        v_lid.id, p_medewerker_id, v_resultaat, v_kaart_id, v_beurt_af,
        (v_resultaat = 'groen' and p_soort = 'check_in'),
        case when v_lid.sociaal_tarief and p_soort = 'check_in' then false else null end,
        'in_wachtkamer', p_soort
    )
    returning id into v_checkin_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (p_medewerker_id,
            case when p_soort='alleen_info' then 'alleen_info' else 'checkin_manueel' end,
            case when p_soort='alleen_info' then 'Profiel bekeken (geen beurt).'
                 else 'Manuele check-in: ' || v_resultaat::text
                      || case when v_beurt_af then ' (beurt afgetrokken)' else '' end end,
            v_lid.id, v_checkin_id);

    return query select v_checkin_id, v_lid.id, v_lid.voornaam, v_lid.achternaam,
                        v_lid.foto_pad, v_lid.sociaal_tarief, v_resultaat, v_rest,
                        v_abo_geldig, v_abo_tot, p_soort;
end;
$$;

comment on function fn_checkin_lid is
    'Checkt een lid rechtstreeks in (manueel/nieuw profiel). Ondersteunt ''alleen_info'' zonder beurt.';


-- ----------------------------------------------------------------------------
-- fn_zoek_leden
-- Eenvoudige zoekfunctie op naam (voor- of achternaam) voor manueel opzoeken
-- aan de kassa. Geeft basisinfo + huidige beurten/abonnementstatus terug.
-- ----------------------------------------------------------------------------
create or replace function fn_zoek_leden(p_zoek text)
returns table (
    lid_id            uuid,
    voornaam          text,
    achternaam        text,
    foto_pad          text,
    sociaal_tarief    boolean,
    is_eenmalig       boolean,
    beurten_resterend integer,
    abonnement_tot    date
)
language sql
stable
as $$
    select l.id, l.voornaam, l.achternaam, l.foto_pad, l.sociaal_tarief, l.is_eenmalig,
           coalesce((select sum(beurten_resterend)::int from beurtenkaarten
                     where lid_id = l.id and actief), 0) as beurten_resterend,
           (select max(eind_datum) from abonnementen
             where lid_id = l.id and actief and current_date between start_datum and eind_datum)
    from leden l
    where l.actief
      and (l.voornaam ilike '%'||p_zoek||'%' or l.achternaam ilike '%'||p_zoek||'%'
           or (l.voornaam||' '||coalesce(l.achternaam,'')) ilike '%'||p_zoek||'%')
    order by l.voornaam, l.achternaam
    limit 25;
$$;

comment on function fn_zoek_leden is
    'Zoekt leden op naam voor manueel inchecken aan de kassa (zonder QR-kaartje).';
