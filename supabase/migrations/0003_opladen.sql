-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0003: opladen en betaling afvinken
-- ----------------------------------------------------------------------------
-- Het systeem houdt GEEN geld bij. Geld zit in een apart kassasysteem.
-- Hier zitten enkel de handelingen die beurten/abonnementen beheren en het
-- afvinken van "betaald" / "A-Kaart ok" in de wachtkamer.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- fn_laad_beurtenkaart
-- Laadt een nieuwe beurtenkaart op voor een lid (bv. 10 beurten).
-- Geeft de nieuwe kaart-id terug. Gebruikt aan de kassa (rood -> groen) en
-- later eventueel vanaf het beheer.
-- ----------------------------------------------------------------------------
create or replace function fn_laad_beurtenkaart(
    p_lid_id         uuid,
    p_aantal         integer,
    p_medewerker_id  uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    if p_aantal <= 0 then
        raise exception 'Aantal beurten moet groter zijn dan 0.';
    end if;

    insert into beurtenkaarten (lid_id, beurten_totaal, beurten_resterend, aangemaakt_door)
    values (p_lid_id, p_aantal, p_aantal, p_medewerker_id)
    returning id into v_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'beurtenkaart_opgeladen',
            'Beurtenkaart opgeladen: ' || p_aantal || ' beurten.', p_lid_id);

    return v_id;
end;
$$;

comment on function fn_laad_beurtenkaart is
    'Laadt een nieuwe beurtenkaart op (X beurten). Geld wordt apart afgehandeld.';


-- ----------------------------------------------------------------------------
-- fn_laad_abonnement
-- Laadt een abonnement op van 3, 6 of 12 maanden. Berekent zelf de einddatum.
-- ----------------------------------------------------------------------------
create or replace function fn_laad_abonnement(
    p_lid_id         uuid,
    p_duur           abonnement_duur,
    p_start          date,
    p_medewerker_id  uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id     uuid;
    v_maanden integer;
    v_eind   date;
begin
    v_maanden := case p_duur
                    when '3_maanden'  then 3
                    when '6_maanden'  then 6
                    when '12_maanden' then 12
                 end;

    v_eind := (p_start + (v_maanden || ' months')::interval)::date;

    insert into abonnementen (lid_id, duur, start_datum, eind_datum, aangemaakt_door)
    values (p_lid_id, p_duur, p_start, v_eind, p_medewerker_id)
    returning id into v_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'abonnement_opgeladen',
            'Abonnement opgeladen: ' || v_maanden || ' maanden (tot ' || v_eind || ').', p_lid_id);

    return v_id;
end;
$$;

comment on function fn_laad_abonnement is
    'Laadt een abonnement op (3/6/12 maanden) en berekent de einddatum.';


-- ----------------------------------------------------------------------------
-- fn_vink_af
-- Vinkt in de wachtkamer "betaling" of "A-Kaart" af voor een check-in.
-- p_wat: 'betaling' of 'akaart'. Bij rood scherm dat ter plaatse betaald is
--        zonder beurt op te laden, gebruikt de kassa 'betaling'.
-- ----------------------------------------------------------------------------
create or replace function fn_vink_af(
    p_checkin_id     uuid,
    p_wat            text,
    p_medewerker_id  uuid
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

    if p_wat = 'betaling' then
        update checkins set betaling_ok = true where id = p_checkin_id;
        insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
        values (p_medewerker_id, 'betaling_afgevinkt', 'Betaling afgevinkt.', v_checkin.lid_id, p_checkin_id);

    elsif p_wat = 'akaart' then
        if v_checkin.akaart_ok is null then
            return 'Dit lid heeft geen sociaal tarief; A-Kaart is niet nodig.';
        end if;
        update checkins set akaart_ok = true where id = p_checkin_id;
        insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
        values (p_medewerker_id, 'akaart_afgevinkt', 'A-Kaart-check afgevinkt.', v_checkin.lid_id, p_checkin_id);

    else
        return 'Onbekende afvinkactie.';
    end if;

    return 'ok';
end;
$$;

comment on function fn_vink_af is
    'Vinkt betaling of A-Kaart af voor een check-in in de wachtkamer.';
