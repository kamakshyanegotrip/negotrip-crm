-- NegoTrip CRM · migration 004 · a lead from outside never arrives with no owner
-- If no sales person is free to take a lead (or none exists yet), it goes to a manager: sales manager first,
-- then branch manager, company admin, owner. Safe to run again.

CREATE OR REPLACE FUNCTION crm.fn_lead_auto_assign(p_lead uuid, p_exec text) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; cfg jsonb; v_staff uuid; v_roles text[]; v_keys text[]; v_rule text;
BEGIN
  SELECT * INTO l FROM crm.lead WHERE id = p_lead;
  IF NOT FOUND THEN RETURN NULL; END IF;
  cfg := crm.fn_cfg(l.org_id, 'lead_assignment');
  v_rule := COALESCE(cfg->>'strategy', 'round_robin');
  SELECT COALESCE(array_agg(x), ARRAY['sales_executive', 'sales_manager']) INTO v_roles FROM jsonb_array_elements_text(COALESCE(cfg->'roles', '[]'::jsonb)) x;
  v_keys := array_remove(ARRAY[lower(l.segment), lower(l.audience), lower(l.destination_text)], NULL);
  SELECT s.id INTO v_staff
  FROM crm.staff s
  WHERE s.org_id = l.org_id AND s.active AND s.role = ANY (v_roles)
    AND (NOT COALESCE((cfg->>'respect_max_open_leads')::boolean, true) OR s.max_open_leads IS NULL OR s.max_open_leads >
         (SELECT count(*) FROM crm.lead o WHERE o.owner_staff_id = s.id AND o.deleted_at IS NULL AND o.status NOT IN ('won', 'lost', 'dormant', 'duplicate')))
  ORDER BY
    CASE WHEN COALESCE((cfg->>'match_speciality')::boolean, true)
              AND EXISTS (SELECT 1 FROM unnest(s.specialities) sp, unnest(v_keys) k WHERE btrim(sp) <> '' AND k LIKE '%' || lower(btrim(sp)) || '%')
         THEN 0 ELSE 1 END,
    (SELECT max(a.assigned_at) FROM crm.lead_assignment a WHERE a.staff_id = s.id) NULLS FIRST,
    s.created_at
  LIMIT 1;
  IF v_staff IS NULL THEN
    SELECT s.id INTO v_staff FROM crm.staff s
    WHERE s.org_id = l.org_id AND s.active AND crm.fn_is_manager(s.role)
    ORDER BY CASE s.role WHEN 'sales_manager' THEN 0 WHEN 'branch_manager' THEN 1 WHEN 'company_admin' THEN 2 ELSE 3 END,
             (SELECT max(a.assigned_at) FROM crm.lead_assignment a WHERE a.staff_id = s.id) NULLS FIRST, s.created_at
    LIMIT 1;
    v_rule := 'fallback_manager';
  END IF;
  IF v_staff IS NOT NULL THEN
    PERFORM crm.fn_lead_set_owner(p_lead, v_staff, NULL, 'Automatic assignment', v_rule, p_exec);
  END IF;
  RETURN v_staff;
END $fn$;

INSERT INTO crm.schema_migration (filename, note) VALUES ('004_assign_fallback.sql', 'Automatic assignment falls back to a manager when no sales person can take the lead') ON CONFLICT (filename) DO NOTHING;
