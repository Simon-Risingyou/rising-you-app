-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0020: profielfoto van een lid instellen/verwijderen
-- ----------------------------------------------------------------------------
-- leden.foto_pad bestond al (en werd al getoond in ledenbeheer.html), maar er
-- was geen databankfunctie om hem in te stellen — de knop om een foto te
-- maken/uploaden/verwijderen was op een eerder moment losgekoppeld geraakt
-- van het echte detailscherm. Deze migratie voegt fn_zet_foto toe.
--
-- Bewaard als data-URL (base64) in de tekstkolom foto_pad, zelfde aanpak als
-- kaart_layout.achtergrond_data: geen Supabase Storage-bucket nodig. De
-- frontend snijdt/verkleint altijd naar een klein vierkant (256x256, jpeg
-- kwaliteit 0.8) vóór het opslaan, dus dit blijft een kleine tekstwaarde.
-- ============================================================================
create or replace function fn_zet_foto(
    p_lid_id        uuid,
    p_foto_data     text,
    p_medewerker_id uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    update leden set foto_pad = p_foto_data, bijgewerkt_op = now()
     where id = p_lid_id;

    if not found then
        return 'Lid niet gevonden.';
    end if;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id,
            case when p_foto_data is null then 'foto_verwijderd' else 'foto_gewijzigd' end,
            case when p_foto_data is null then 'Profielfoto verwijderd.' else 'Profielfoto gewijzigd.' end,
            p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_zet_foto is
    'Stelt de profielfoto van een lid in (data-URL) of verwijdert ze (null).';

grant execute on function fn_zet_foto(uuid, text, uuid) to anon;
