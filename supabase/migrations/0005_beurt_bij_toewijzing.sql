-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0005: beurt pas aftrekken bij toewijzing aan een sessie
-- ----------------------------------------------------------------------------
-- Belangrijke gedragswijziging op basis van feedback:
--   - Bij de SCAN / check-in wordt GEEN beurt meer afgetrokken.
--   - De beurt wordt pas afgetrokken op het moment dat het lid uit de
--     wachtkamer naar een sessie wordt gesleept (toewijzing).
--   - 'Herstel' (annuleren) zet de beurt terug ALS er met een beurtenkaart
--     was afgerekend, en zet de check-in terug naar de wachtkamer (status
--     'in_wachtkamer') zodat de medewerker opnieuw kan toewijzen of annuleren.
--
-- We bepalen 'groen/rood' bij de scan nog steeds (om de kleur te tonen), maar
-- het effectief afboeken gebeurt later. Daarom slaan we bij de check-in op
-- WELKE beurtenkaart gebruikt zou worden, zonder al af te trekken.
-- ============================================================================

-- Onthoud welke beurtenkaart 'gepland' is om af te boeken bij toewijzing.
alter table checkins
    add column if not exists geplande_beurtenkaart_id uuid references beurtenkaarten(id);
comment on column checkins.geplande_beurtenkaart_id is
    'Beurtenkaart die bij toewijzing wordt afgeboekt. Pas bij slepen naar sessie wordt de beurt afgetrokken.';


-- ----------------------------------------------------------------------------
-- fn_verwerk_scan (herzien): trekt GEEN beurt meer af.
-- Bepaalt groen/rood en onthoudt welke beurtenkaart later afgeboekt wordt.
-- ----------------------------------------------------------------------------
create or replace function fn_verwerk_scan(
    p_qr_token       text,
    p_medewerker_id  uuid
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
    moet_akaart         boolean,
    gevonden            boolean
)
language plpgsql
as $$
declare
    v_lid         leden%rowtype;
    v_kaartje_id  uuid;
    v_abo         abonnementen%rowtype;
    v_kaart       beurtenkaarten%rowtype;
    v_resultaat   checkin_resultaat;
    v_kaart_id    uuid := null;
    v_rest        integer := null;
    v_abo_geldig  boolean := false;
    v_abo_tot     date := null;
    v_checkin_id  uuid;
begin
    select n.id, l.* into v_kaartje_id, v_lid
      from naamkaartjes n join leden l on l.id = n.lid_id
     where n.qr_token = p_qr_token and n.geldig and l.actief
     limit 1;

    if not found then
        return query select null::uuid,null::uuid,null::text,null::text,null::text,
                            null::boolean,null::checkin_resultaat,null::integer,
                            null::boolean,null::date,null::boolean,false;
        return;
    end if;

    -- Geldig abonnement?
    select * into v_abo from abonnementen
     where lid_id = v_lid.id and actief
       and current_date between start_datum and eind_datum
     order by eind_datum desc limit 1;

    if found then
        v_abo_geldig := true; v_abo_tot := v_abo.eind_datum; v_resultaat := 'groen';
    else
        -- Is er een beurtenkaart met saldo? (NIET aftrekken, enkel plannen)
        select * into v_kaart from beurtenkaarten
         where lid_id = v_lid.id and actief and beurten_resterend > 0
         order by aangemaakt_op asc limit 1;
        if found then
            v_resultaat := 'groen';
            v_kaart_id  := v_kaart.id;       -- gepland om af te boeken bij toewijzing
            v_rest      := v_kaart.beurten_resterend;  -- huidig saldo (nog niet -1)
        else
            v_resultaat := 'rood';
        end if;
    end if;

    insert into checkins (
        lid_id, naamkaartje_id, medewerker_id, resultaat,
        geplande_beurtenkaart_id, beurt_afgetrokken,
        betaling_ok, akaart_ok, status, soort
    )
    values (
        v_lid.id, v_kaartje_id, p_medewerker_id, v_resultaat,
        v_kaart_id, false,
        (v_resultaat = 'groen'),
        case when v_lid.sociaal_tarief then false else null end,
        'in_wachtkamer', 'check_in'
    )
    returning id into v_checkin_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (p_medewerker_id, 'checkin',
            'Scan: ' || v_resultaat::text || ' (beurt nog niet afgetrokken).',
            v_lid.id, v_checkin_id);

    return query select v_checkin_id, v_lid.id, v_lid.voornaam, v_lid.achternaam, v_lid.foto_pad,
                        v_lid.sociaal_tarief, v_resultaat, v_rest, v_abo_geldig, v_abo_tot,
                        v_lid.sociaal_tarief, true;
end;
$$;


-- ----------------------------------------------------------------------------
-- fn_rond_wachtkamer_af (herzien): trekt NU pas de geplande beurt af.
-- ----------------------------------------------------------------------------
create or replace function fn_rond_wachtkamer_af(
    p_checkin_id     uuid,
    p_toewijzing     toewijzing_type,
    p_clubsessie_id  uuid,
    p_medewerker_id  uuid
)
returns text
language plpgsql
as $$
declare
    v_checkin checkins%rowtype;
    v_rest    integer;
begin
    select * into v_checkin from checkins where id = p_checkin_id for update;
    if not found then return 'Check-in niet gevonden.'; end if;

    if not v_checkin.betaling_ok then return 'Betaling is nog niet afgevinkt.'; end if;
    if v_checkin.akaart_ok is not null and v_checkin.akaart_ok = false then
        return 'A-Kaart-check is nog niet afgevinkt.';
    end if;
    if p_toewijzing = 'clubsessie' and p_clubsessie_id is null then
        return 'Kies eerst een clubsessie.';
    end if;

    -- NU pas de beurt aftrekken, als er een gepland was en die nog niet af is.
    if v_checkin.geplande_beurtenkaart_id is not null and not v_checkin.beurt_afgetrokken then
        update beurtenkaarten
           set beurten_resterend = beurten_resterend - 1
         where id = v_checkin.geplande_beurtenkaart_id
           and beurten_resterend > 0
        returning beurten_resterend into v_rest;

        update checkins
           set beurt_afgetrokken = true,
               beurtenkaart_id   = v_checkin.geplande_beurtenkaart_id
         where id = p_checkin_id;
    end if;

    update checkins
       set status = 'toegewezen', toewijzing = p_toewijzing,
           clubsessie_id = case when p_toewijzing='clubsessie' then p_clubsessie_id else null end,
           toegewezen_op = now()
     where id = p_checkin_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (p_medewerker_id, 'toegewezen',
            'Toegewezen aan ' || p_toewijzing::text
            || case when v_checkin.geplande_beurtenkaart_id is not null then ' (beurt afgetrokken).' else '.' end,
            v_checkin.lid_id, p_checkin_id);

    return 'ok';
end;
$$;


-- ----------------------------------------------------------------------------
-- fn_herstel_naar_wachtkamer
-- 'Herstel' vanuit het dagoverzicht: zet een TOEGEWEZEN check-in terug naar de
-- wachtkamer. Was er een beurt afgetrokken (beurtenkaart), dan wordt die
-- teruggezet. Bij abonnement/geen-beurt is er niets af te boeken; de check-in
-- komt sowieso terug in de wachtkamer voor annulatie of opnieuw toewijzen.
-- ----------------------------------------------------------------------------
create or replace function fn_herstel_naar_wachtkamer(
    p_checkin_id     uuid,
    p_medewerker_id  uuid
)
returns text
language plpgsql
as $$
declare
    v_checkin checkins%rowtype;
begin
    select * into v_checkin from checkins where id = p_checkin_id for update;
    if not found then return 'Check-in niet gevonden.'; end if;

    -- Beurt teruggeven indien afgetrokken.
    if v_checkin.beurt_afgetrokken and v_checkin.beurtenkaart_id is not null then
        update beurtenkaarten
           set beurten_resterend = least(beurten_resterend + 1, beurten_totaal)
         where id = v_checkin.beurtenkaart_id;
    end if;

    update checkins
       set status = 'in_wachtkamer',
           toewijzing = null,
           clubsessie_id = null,
           toegewezen_op = null,
           beurt_afgetrokken = false,
           beurtenkaart_id = null
     where id = p_checkin_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (p_medewerker_id, 'hersteld_naar_wachtkamer',
            'Terug naar wachtkamer'
            || case when v_checkin.beurt_afgetrokken then ' (beurt teruggezet).' else '.' end,
            v_checkin.lid_id, p_checkin_id);

    return 'ok';
end;
$$;

comment on function fn_herstel_naar_wachtkamer is
    'Zet een toegewezen check-in terug naar de wachtkamer; herstelt de beurt als die met een beurtenkaart was afgeboekt.';
