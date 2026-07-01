-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0018: abonnement-einddatum manueel aanpassen (admin)
-- ----------------------------------------------------------------------------
-- Naast beurten aftrekken (migratie 0017) moet een admin ook de einddatum
-- van een lopend abonnement kunnen corrigeren. Een expliciete nieuwe datum
-- instellen is eenduidiger dan "maanden aftrekken": een lid kan over de tijd
-- meerdere abonnement-rijen voor dezelfde activiteit hebben (fn_laad_abonnement
-- maakt altijd een nieuwe rij aan, nooit stapelend), dus "aftrekken van welke
-- rij" zou dubbelzinnig zijn. Deze functie werkt daarom op HET ene, actueel
-- geldige abonnement voor die activiteit (zelfde opzoeklogica als
-- fn_beschikbaar_tegoed: het abonnement met de verste, nog geldige einddatum).
-- ============================================================================
create or replace function fn_zet_abonnement_einddatum(
    p_lid_id           uuid,
    p_activiteit       text,
    p_nieuwe_einddatum date,
    p_medewerker_id    uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_abo abonnementen%rowtype;
begin
    select * into v_abo
      from abonnementen
     where lid_id = p_lid_id and activiteit = p_activiteit and actief
       and current_date between start_datum and eind_datum
     order by eind_datum desc
     limit 1;

    if not found then
        return 'Geen lopend abonnement gevonden voor deze activiteit.';
    end if;

    update abonnementen set eind_datum = p_nieuwe_einddatum where id = v_abo.id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'abonnement_einddatum_aangepast',
            'Einddatum abonnement ' || p_activiteit || ' aangepast: van ' || v_abo.eind_datum
                || ' naar ' || p_nieuwe_einddatum || '.',
            p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_zet_abonnement_einddatum is
    'Past de einddatum van het huidige lopende abonnement voor een activiteit handmatig aan. Bedoeld voor admins (UI-gated).';

grant execute on function fn_zet_abonnement_einddatum(uuid, text, date, uuid) to anon;
