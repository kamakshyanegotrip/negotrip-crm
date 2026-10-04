-- NegoTrip CRM · migration 002 · lead engine: duplicates, scoring, assignment, tasks, customers and the crm.api dispatcher
-- Safe to run again: tables use IF NOT EXISTS, functions use CREATE OR REPLACE, seeds use ON CONFLICT DO NOTHING.
-- Note: a dollar sign is never written directly before a quote in this file; n8n rewrites that sequence when it passes SQL through.

CREATE TABLE IF NOT EXISTS crm.lead_duplicate (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES crm.org(id),
  lead_id uuid NOT NULL REFERENCES crm.lead(id),
  other_lead_id uuid NOT NULL REFERENCES crm.lead(id),
  match_type text NOT NULL CHECK (match_type IN ('exact','probable')),
  reasons text[] NOT NULL DEFAULT '{}'::text[],
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','merged','dismissed')),
  decided_by_staff_id uuid REFERENCES crm.staff(id),
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lead_id, other_lead_id),
  CHECK (lead_id <> other_lead_id)
);
CREATE INDEX IF NOT EXISTS lead_duplicate_other_ix ON crm.lead_duplicate (other_lead_id);
CREATE INDEX IF NOT EXISTS lead_duplicate_pending_ix ON crm.lead_duplicate (org_id, status);

INSERT INTO crm.config (org_id, key, value, notes)
SELECT o.id, v.key, v.value::jsonb, v.notes FROM crm.org o CROSS JOIN (VALUES
  ('lead_scoring', '{"travel_days":[{"max":14,"points":25},{"max":45,"points":18},{"max":90,"points":10},{"max":100000,"points":5}],"budget_inr":[{"min":200000,"points":20},{"min":75000,"points":14},{"min":25000,"points":8},{"min":1,"points":4}],"pax":[{"min":10,"points":15},{"min":5,"points":10},{"min":2,"points":6},{"min":1,"points":3}],"source_quality_max":10,"repeat_customer":15,"business_audience":10,"has_destination":5,"phone_and_email":5,"hot_from":60,"warm_from":35,"ai_weight":0.25}', 'Points for each lead-scoring factor. Score is capped at 100. hot_from and warm_from set the Hot and Warm cut-offs. ai_weight is the share of the final score the AI score may carry.'),
  ('lead_sla', '{"hot_minutes":15,"warm_minutes":60,"cold_minutes":240,"escalate_after_minutes":30}', 'Minutes allowed for the first contact by lead temperature, and how long a task may be overdue before it is escalated.'),
  ('lead_assignment', '{"strategy":"round_robin","roles":["sales_executive","sales_manager"],"respect_max_open_leads":true,"match_speciality":true}', 'How leads from outside sources are assigned. Leads added by hand stay with the person who added them.')
) AS v(key, value, notes)
WHERE o.code = 'NEGOTRIP'
ON CONFLICT (org_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION crm.fn_fail(p_status int, p_code text, p_message text) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'CRM01', MESSAGE = p_status::text || '|' || p_code || '|' || p_message;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_s(v text, p_max int) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT NULLIF(btrim(left(COALESCE(v, ''), p_max)), '')
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_int(v text, p_lo int, p_hi int) RETURNS int LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN btrim(COALESCE(v, '')) ~ '^[0-9]{1,9}($)' THEN LEAST(GREATEST(btrim(v)::int, p_lo), p_hi) END
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_num(v text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN regexp_replace(COALESCE(v, ''), '[^0-9.]', '', 'g') ~ '^[0-9]{1,12}([.][0-9]{1,4})?($)'
              THEN regexp_replace(v, '[^0-9.]', '', 'g')::numeric END
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_date(v text) RETURNS date LANGUAGE plpgsql IMMUTABLE AS $fn$
BEGIN
  IF v IS NULL OR left(btrim(v), 10) !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}($)' THEN RETURN NULL; END IF;
  RETURN left(btrim(v), 10)::date;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_ts(v text) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $fn$
BEGIN
  IF v IS NULL OR btrim(v) = '' THEN RETURN NULL; END IF;
  RETURN btrim(v)::timestamptz;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_uuid(v text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN lower(btrim(COALESCE(v, ''))) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}($)' THEN lower(btrim(v))::uuid END
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_norm_phone(p text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE d text; t text := btrim(COALESCE(p, ''));
BEGIN
  IF t = '' THEN RETURN NULL; END IF;
  d := regexp_replace(t, '[^0-9]', '', 'g');
  IF left(t, 1) = '+' AND length(d) BETWEEN 8 AND 15 THEN RETURN '+' || d; END IF;
  IF length(d) = 10 THEN RETURN '+91' || d; END IF;
  IF length(d) = 11 AND left(d, 1) = '0' THEN RETURN '+91' || substr(d, 2); END IF;
  IF length(d) = 12 AND left(d, 2) = '91' THEN RETURN '+' || d; END IF;
  IF length(d) BETWEEN 10 AND 17 AND left(d, 2) = '00' THEN RETURN '+' || substr(d, 3); END IF;
  RETURN NULL;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_norm_email(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN lower(btrim(COALESCE(p, ''))) ~ '^[^ @]+@[^ @]+[.][^ @]+($)' THEN left(lower(btrim(p)), 160) END
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_name_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT regexp_replace(lower(COALESCE(p, '')), '[^a-z0-9]', '', 'g')
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_cfg(p_org uuid, p_key text) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE((SELECT value FROM crm.config WHERE org_id = p_org AND key = p_key), '{}'::jsonb)
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_is_manager(p_role text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_role IN ('super_admin', 'company_admin', 'branch_manager', 'sales_manager')
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_is_admin(p_role text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_role IN ('super_admin', 'company_admin')
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_can_edit_leads(p_role text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_role IN ('super_admin', 'company_admin', 'branch_manager', 'sales_manager', 'sales_executive')
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_event(
  p_org uuid, p_type text, p_staff uuid, p_label text, p_lead uuid, p_customer uuid, p_task uuid,
  p_detail jsonb, p_audit boolean, p_workflow text, p_exec text
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v_id uuid;
BEGIN
  INSERT INTO crm.event (org_id, event_type, is_audit, actor_staff_id, actor_label, lead_id, customer_id, task_id, workflow, execution_id, detail)
  VALUES (p_org, p_type, COALESCE(p_audit, false), p_staff, p_label, p_lead, p_customer, p_task, p_workflow, p_exec, COALESCE(p_detail, '{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_lead_score(p_lead uuid, p_ai int DEFAULT NULL, p_model text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  l crm.lead%ROWTYPE; cfg jsonb; f jsonb := '{}'::jsonb;
  v_days int; v_pts int; v_pax int; v_w numeric; v_max numeric;
  v_rule int := 0; v_ai int; v_aiw numeric; v_final int; v_temp text; v_prio text; v_nba text; v_model text;
BEGIN
  SELECT * INTO l FROM crm.lead WHERE id = p_lead;
  IF NOT FOUND THEN RETURN NULL; END IF;
  cfg := crm.fn_cfg(l.org_id, 'lead_scoring');

  v_pts := 0;
  IF l.travel_start IS NOT NULL THEN
    v_days := l.travel_start - current_date;
    IF v_days >= 0 THEN
      SELECT (e->>'points')::int INTO v_pts FROM jsonb_array_elements(COALESCE(cfg->'travel_days', '[]'::jsonb)) e
      WHERE v_days <= (e->>'max')::int ORDER BY (e->>'max')::int LIMIT 1;
    END IF;
  END IF;
  v_pts := COALESCE(v_pts, 0); v_rule := v_rule + v_pts; f := f || jsonb_build_object('travel_date', v_pts);

  v_pts := 0;
  IF l.budget_amount IS NOT NULL AND COALESCE(l.budget_currency, 'INR') = 'INR' THEN
    SELECT (e->>'points')::int INTO v_pts FROM jsonb_array_elements(COALESCE(cfg->'budget_inr', '[]'::jsonb)) e
    WHERE l.budget_amount >= (e->>'min')::numeric ORDER BY (e->>'min')::numeric DESC LIMIT 1;
  END IF;
  v_pts := COALESCE(v_pts, 0); v_rule := v_rule + v_pts; f := f || jsonb_build_object('budget', v_pts);

  v_pts := 0;
  v_pax := COALESCE(l.pax_adults, 0) + COALESCE(l.pax_children, 0);
  IF v_pax > 0 THEN
    SELECT (e->>'points')::int INTO v_pts FROM jsonb_array_elements(COALESCE(cfg->'pax', '[]'::jsonb)) e
    WHERE v_pax >= (e->>'min')::int ORDER BY (e->>'min')::int DESC LIMIT 1;
  END IF;
  v_pts := COALESCE(v_pts, 0); v_rule := v_rule + v_pts; f := f || jsonb_build_object('group_size', v_pts);

  v_max := COALESCE((cfg->>'source_quality_max')::numeric, 10);
  SELECT quality_weight INTO v_w FROM crm.lead_source WHERE id = l.source_id;
  v_pts := LEAST(round(COALESCE(v_w, 1) * v_max), round(v_max * 1.5))::int;
  v_rule := v_rule + v_pts; f := f || jsonb_build_object('source', v_pts);

  v_pts := 0;
  IF l.customer_id IS NOT NULL AND EXISTS (SELECT 1 FROM crm.lead o WHERE o.customer_id = l.customer_id AND o.id <> l.id AND o.status = 'won' AND o.deleted_at IS NULL) THEN
    v_pts := COALESCE((cfg->>'repeat_customer')::int, 0);
  END IF;
  v_rule := v_rule + v_pts; f := f || jsonb_build_object('repeat_customer', v_pts);

  v_pts := CASE WHEN l.audience IN ('b2b', 'corporate') THEN COALESCE((cfg->>'business_audience')::int, 0) ELSE 0 END;
  v_rule := v_rule + v_pts; f := f || jsonb_build_object('business', v_pts);

  v_pts := CASE WHEN l.destination_text IS NOT NULL THEN COALESCE((cfg->>'has_destination')::int, 0) ELSE 0 END;
  v_rule := v_rule + v_pts; f := f || jsonb_build_object('destination_known', v_pts);

  v_pts := CASE WHEN l.phone_e164 IS NOT NULL AND l.email IS NOT NULL THEN COALESCE((cfg->>'phone_and_email')::int, 0) ELSE 0 END;
  v_rule := v_rule + v_pts; f := f || jsonb_build_object('phone_and_email', v_pts);

  v_rule := LEAST(100, GREATEST(0, v_rule));

  v_ai := p_ai; v_model := p_model;
  IF v_ai IS NULL THEN
    SELECT s.ai_score, s.model INTO v_ai, v_model FROM crm.lead_score s WHERE s.lead_id = p_lead AND s.ai_score IS NOT NULL ORDER BY s.scored_at DESC LIMIT 1;
  END IF;
  IF v_ai IS NOT NULL THEN
    v_ai := LEAST(100, GREATEST(0, v_ai));
    v_aiw := LEAST(0.5, GREATEST(0, COALESCE((cfg->>'ai_weight')::numeric, 0.25)));
    v_final := round(v_rule * (1 - v_aiw) + v_ai * v_aiw)::int;
  ELSE
    v_final := v_rule;
  END IF;

  v_temp := CASE WHEN v_final >= COALESCE((cfg->>'hot_from')::int, 60) THEN 'hot'
                 WHEN v_final >= COALESCE((cfg->>'warm_from')::int, 35) THEN 'warm' ELSE 'cold' END;
  v_prio := CASE WHEN v_temp = 'hot' AND v_days IS NOT NULL AND v_days BETWEEN 0 AND 14 THEN 'urgent'
                 WHEN v_temp = 'hot' THEN 'high' WHEN v_temp = 'warm' THEN 'normal' ELSE 'low' END;
  v_nba := CASE
    WHEN l.status IN ('won', 'lost', 'duplicate') THEN NULL
    WHEN l.phone_e164 IS NULL AND l.email IS NOT NULL THEN 'Email them and ask for a phone number'
    WHEN v_temp = 'hot' AND l.status = 'new' THEN 'Call now'
    WHEN l.travel_start IS NULL THEN 'Ask for the travel dates'
    WHEN l.destination_text IS NULL THEN 'Ask where they want to go'
    WHEN v_pax = 0 THEN 'Ask how many people are travelling'
    WHEN l.status = 'new' THEN 'Call today'
    WHEN l.status IN ('contacted', 'qualified') THEN 'Collect the full requirement'
    WHEN l.status = 'requirement_collected' THEN 'Prepare the quotation'
    WHEN l.status IN ('quoted', 'negotiating') THEN 'Follow up on the quotation'
    ELSE 'Follow up' END;

  INSERT INTO crm.lead_score (lead_id, rule_score, ai_score, final_score, temperature, factors, model)
  VALUES (p_lead, v_rule, v_ai, v_final, v_temp, f, v_model);
  UPDATE crm.lead SET score = v_final, temperature = v_temp, priority = v_prio,
         conversion_probability = round(v_final / 100.0, 4), next_best_action = v_nba, updated_at = now()
  WHERE id = p_lead;
  RETURN jsonb_build_object('score', v_final, 'rule_score', v_rule, 'ai_score', v_ai, 'temperature', v_temp, 'priority', v_prio, 'next_best_action', v_nba, 'factors', f);
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_lead_set_owner(p_lead uuid, p_staff uuid, p_by uuid, p_by_label text, p_rule text, p_exec text) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; v_name text;
BEGIN
  SELECT * INTO l FROM crm.lead WHERE id = p_lead;
  IF NOT FOUND THEN RETURN; END IF;
  IF l.owner_staff_id IS NOT DISTINCT FROM p_staff THEN RETURN; END IF;
  UPDATE crm.lead_assignment SET released_at = now() WHERE lead_id = p_lead AND released_at IS NULL;
  IF p_staff IS NOT NULL THEN
    INSERT INTO crm.lead_assignment (lead_id, staff_id, assigned_by_staff_id, rule) VALUES (p_lead, p_staff, p_by, p_rule);
    SELECT full_name INTO v_name FROM crm.staff WHERE id = p_staff;
  END IF;
  UPDATE crm.lead SET owner_staff_id = p_staff, updated_at = now() WHERE id = p_lead;
  UPDATE crm.task SET owner_staff_id = p_staff, updated_at = now()
  WHERE lead_id = p_lead AND status IN ('open', 'in_progress') AND owner_staff_id IS NOT DISTINCT FROM l.owner_staff_id;
  PERFORM crm.fn_event(l.org_id, 'lead.assigned', p_by, p_by_label, p_lead, l.customer_id, NULL,
    jsonb_build_object('to', p_staff, 'to_name', v_name, 'rule', p_rule), false, 'TRAVELCRM', p_exec);
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_lead_auto_assign(p_lead uuid, p_exec text) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; cfg jsonb; v_staff uuid; v_roles text[]; v_keys text[];
BEGIN
  SELECT * INTO l FROM crm.lead WHERE id = p_lead;
  IF NOT FOUND THEN RETURN NULL; END IF;
  cfg := crm.fn_cfg(l.org_id, 'lead_assignment');
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
  IF v_staff IS NOT NULL THEN
    PERFORM crm.fn_lead_set_owner(p_lead, v_staff, NULL, 'Automatic assignment', COALESCE(cfg->>'strategy', 'round_robin'), p_exec);
  END IF;
  RETURN v_staff;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_lead_intake(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_org uuid; v_strict boolean := COALESCE((p->>'strict')::boolean, false);
  v_src crm.lead_source%ROWTYPE; v_ref text := crm.fn_s(p->>'source_ref', 200);
  v_name text := crm.fn_s(p->>'full_name', 120);
  v_phone_raw text := crm.fn_s(p->>'phone', 40); v_phone text; v_wa text;
  v_email_raw text := crm.fn_s(p->>'email', 160); v_email text;
  v_aud text := lower(COALESCE(crm.fn_s(p->>'audience', 20), 'retail'));
  v_msg text := crm.fn_s(p->>'message', 4000);
  v_lead crm.lead%ROWTYPE; v_cust uuid; v_cust_new boolean := false;
  v_actor uuid := crm.fn_uuid(p->>'actor_staff_id'); v_label text := COALESCE(crm.fn_s(p->>'actor_label', 160), 'System');
  v_exec text := crm.fn_s(p->>'execution_id', 60); v_wf text := COALESCE(crm.fn_s(p->>'workflow', 80), 'TRAVELCRM');
  v_assign text := COALESCE(crm.fn_s(p->>'assign', 40), 'auto');
  v_score jsonb; v_owner uuid; v_sla jsonb; v_minutes int; v_exact int := 0; v_prob int := 0; v_budget numeric; v_key text;
BEGIN
  v_org := COALESCE(crm.fn_uuid(p->>'org_id'), (SELECT id FROM crm.org WHERE code = COALESCE(crm.fn_s(p->>'org_code', 40), 'NEGOTRIP')));
  IF v_org IS NULL THEN PERFORM crm.fn_fail(400, 'bad_org', 'Unknown organisation.'); END IF;

  SELECT * INTO v_src FROM crm.lead_source WHERE org_id = v_org AND code = COALESCE(crm.fn_s(p->>'source', 40), 'external_api') AND active;
  IF NOT FOUND THEN
    IF v_strict THEN PERFORM crm.fn_fail(400, 'bad_source', 'That lead source is not set up.'); END IF;
    SELECT * INTO v_src FROM crm.lead_source WHERE org_id = v_org AND code = 'external_api';
  END IF;

  IF v_ref IS NOT NULL THEN
    SELECT * INTO v_lead FROM crm.lead WHERE org_id = v_org AND source_id = v_src.id AND source_ref = v_ref;
    IF FOUND THEN
      RETURN jsonb_build_object('created', false, 'lead', jsonb_build_object('id', v_lead.id, 'lead_no', v_lead.lead_no,
        'score', v_lead.score, 'temperature', v_lead.temperature, 'owner_staff_id', v_lead.owner_staff_id),
        'customer_id', v_lead.customer_id, 'duplicates', jsonb_build_object('exact', 0, 'probable', 0));
    END IF;
  END IF;

  v_phone := crm.fn_norm_phone(v_phone_raw);
  v_wa := COALESCE(crm.fn_norm_phone(crm.fn_s(p->>'whatsapp', 40)), v_phone);
  v_email := crm.fn_norm_email(v_email_raw);
  IF v_strict THEN
    IF v_name IS NULL THEN PERFORM crm.fn_fail(400, 'missing_name', 'Enter the name of the person.'); END IF;
    IF v_phone_raw IS NOT NULL AND v_phone IS NULL THEN PERFORM crm.fn_fail(400, 'bad_phone', 'That phone number does not look right. Use 10 digits, or start with + and the country code.'); END IF;
    IF v_email_raw IS NOT NULL AND v_email IS NULL THEN PERFORM crm.fn_fail(400, 'bad_email', 'That email address does not look right.'); END IF;
    IF v_phone IS NULL AND v_email IS NULL THEN PERFORM crm.fn_fail(400, 'missing_contact', 'Enter a phone number or an email.'); END IF;
  ELSIF v_name IS NULL AND v_phone IS NULL AND v_wa IS NULL AND v_email IS NULL AND v_msg IS NULL THEN
    PERFORM crm.fn_fail(400, 'empty_lead', 'The lead has no name, contact or message.');
  END IF;
  IF v_aud NOT IN ('retail', 'b2b', 'corporate') THEN v_aud := 'retail'; END IF;
  v_budget := crm.fn_num(p->>'budget');
  IF v_budget IS NOT NULL AND v_budget <= 0 THEN v_budget := NULL; END IF;

  SELECT c.id INTO v_cust FROM crm.customer c
  WHERE c.org_id = v_org AND c.deleted_at IS NULL AND c.merged_into_customer_id IS NULL
    AND ((v_phone IS NOT NULL AND (c.phone_e164 = v_phone OR c.whatsapp_e164 = v_phone))
      OR (v_wa IS NOT NULL AND (c.phone_e164 = v_wa OR c.whatsapp_e164 = v_wa))
      OR (v_email IS NOT NULL AND lower(c.email) = v_email))
  ORDER BY c.created_at LIMIT 1;
  IF v_cust IS NULL AND (v_phone IS NOT NULL OR v_wa IS NOT NULL OR v_email IS NOT NULL) THEN
    INSERT INTO crm.customer (org_id, kind, full_name, company_name, phone_e164, whatsapp_e164, email, city, country_code, agent_code, owner_staff_id)
    VALUES (v_org, CASE v_aud WHEN 'b2b' THEN 'agent' WHEN 'corporate' THEN 'company' ELSE 'individual' END,
            COALESCE(v_name, v_phone, v_wa, v_email), crm.fn_s(p->>'company_name', 160), v_phone, v_wa, v_email,
            crm.fn_s(p->>'city', 80), upper(crm.fn_s(p->>'country_code', 2)), crm.fn_s(p->>'agent_code', 40), NULL)
    RETURNING id INTO v_cust;
    v_cust_new := true;
  END IF;

  INSERT INTO crm.lead (org_id, customer_id, source_id, source_ref, campaign, utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                        gclid, landing_page, referrer, full_name, phone_e164, whatsapp_e164, email, company_name, audience, segment,
                        destination_text, travel_start, travel_end, pax_adults, pax_children, pax_infants, budget_amount, budget_currency,
                        message, consent_marketing, raw, correlation_id, last_activity_at)
  VALUES (v_org, v_cust, v_src.id, v_ref, crm.fn_s(p->>'campaign', 200), crm.fn_s(p->>'utm_source', 200), crm.fn_s(p->>'utm_medium', 200),
          crm.fn_s(p->>'utm_campaign', 200), crm.fn_s(p->>'utm_term', 200), crm.fn_s(p->>'utm_content', 200),
          crm.fn_s(p->>'gclid', 200), crm.fn_s(p->>'landing_page', 500), crm.fn_s(p->>'referrer', 500),
          v_name, v_phone, v_wa, v_email, crm.fn_s(p->>'company_name', 160), v_aud, lower(crm.fn_s(p->>'segment', 40)),
          crm.fn_s(p->>'destination', 160), crm.fn_date(p->>'travel_start'), crm.fn_date(p->>'travel_end'),
          crm.fn_int(p->>'adults', 0, 500), crm.fn_int(p->>'children', 0, 500), crm.fn_int(p->>'infants', 0, 100),
          v_budget, CASE WHEN v_budget IS NOT NULL THEN upper(COALESCE(crm.fn_s(p->>'currency', 3), 'INR')) END,
          v_msg, CASE WHEN p ? 'consent_marketing' THEN (p->>'consent_marketing')::boolean END,
          COALESCE(p->'raw', '{}'::jsonb), gen_random_uuid(), now())
  RETURNING * INTO v_lead;

  INSERT INTO crm.lead_status_history (lead_id, to_status, changed_by_staff_id, reason) VALUES (v_lead.id, 'new', v_actor, 'Lead received');
  PERFORM crm.fn_event(v_org, 'lead.received', v_actor, v_label, v_lead.id, v_cust, NULL,
    jsonb_build_object('source', v_src.code, 'source_name', v_src.name, 'campaign', v_lead.campaign), false, v_wf, v_exec);

  IF v_lead.consent_marketing IS NOT NULL THEN
    INSERT INTO crm.consent (org_id, customer_id, lead_id, channel, purpose, granted, source, recorded_by)
    SELECT v_org, v_cust, v_lead.id, ch, 'marketing', v_lead.consent_marketing, v_src.code, v_label
    FROM unnest(ARRAY['whatsapp', 'email', 'sms']) ch;
  END IF;

  v_key := crm.fn_name_key(v_name);
  INSERT INTO crm.lead_duplicate (org_id, lead_id, other_lead_id, match_type, reasons)
  SELECT v_org, v_lead.id, o.id, 'exact',
         array_remove(ARRAY[
           CASE WHEN v_phone IS NOT NULL AND (o.phone_e164 = v_phone OR o.whatsapp_e164 = v_phone) THEN 'same phone' END,
           CASE WHEN v_wa IS NOT NULL AND v_wa IS DISTINCT FROM v_phone AND (o.phone_e164 = v_wa OR o.whatsapp_e164 = v_wa) THEN 'same WhatsApp number' END,
           CASE WHEN v_email IS NOT NULL AND lower(o.email) = v_email THEN 'same email' END], NULL)
  FROM crm.lead o
  WHERE o.org_id = v_org AND o.id <> v_lead.id AND o.deleted_at IS NULL AND o.status <> 'duplicate'
    AND ((v_phone IS NOT NULL AND (o.phone_e164 = v_phone OR o.whatsapp_e164 = v_phone))
      OR (v_wa IS NOT NULL AND (o.phone_e164 = v_wa OR o.whatsapp_e164 = v_wa))
      OR (v_email IS NOT NULL AND lower(o.email) = v_email))
  ORDER BY o.created_at DESC LIMIT 10
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_exact = ROW_COUNT;

  IF length(v_key) >= 5 THEN
    INSERT INTO crm.lead_duplicate (org_id, lead_id, other_lead_id, match_type, reasons)
    SELECT v_org, v_lead.id, o.id, 'probable',
           array_remove(ARRAY['same name',
             CASE WHEN v_lead.destination_text IS NOT NULL AND crm.fn_name_key(o.destination_text) = crm.fn_name_key(v_lead.destination_text) THEN 'same destination' END,
             CASE WHEN v_lead.travel_start IS NOT NULL AND o.travel_start = v_lead.travel_start THEN 'same travel date' END], NULL)
    FROM crm.lead o
    WHERE o.org_id = v_org AND o.id <> v_lead.id AND o.deleted_at IS NULL AND o.status <> 'duplicate'
      AND o.created_at >= now() - interval '180 days'
      AND crm.fn_name_key(o.full_name) = v_key
      AND NOT EXISTS (SELECT 1 FROM crm.lead_duplicate d WHERE d.lead_id = v_lead.id AND d.other_lead_id = o.id)
    ORDER BY o.created_at DESC LIMIT 10
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_prob = ROW_COUNT;
  END IF;

  v_score := crm.fn_lead_score(v_lead.id);

  IF v_assign = 'creator' AND v_actor IS NOT NULL THEN
    PERFORM crm.fn_lead_set_owner(v_lead.id, v_actor, v_actor, v_label, 'creator', v_exec);
    v_owner := v_actor;
  ELSIF crm.fn_uuid(v_assign) IS NOT NULL AND EXISTS (SELECT 1 FROM crm.staff s WHERE s.id = crm.fn_uuid(v_assign) AND s.org_id = v_org AND s.active) THEN
    v_owner := crm.fn_uuid(v_assign);
    PERFORM crm.fn_lead_set_owner(v_lead.id, v_owner, v_actor, v_label, 'manual', v_exec);
  ELSIF v_assign <> 'none' THEN
    v_owner := crm.fn_lead_auto_assign(v_lead.id, v_exec);
  END IF;

  v_sla := crm.fn_cfg(v_org, 'lead_sla');
  v_minutes := COALESCE((v_sla->>(COALESCE(v_score->>'temperature', 'cold') || '_minutes'))::int, 240);
  INSERT INTO crm.task (org_id, type, title, lead_id, customer_id, owner_staff_id, created_by_staff_id, priority, due_at, sla_minutes, dedupe_key)
  VALUES (v_org, 'call', 'First contact: ' || COALESCE(v_name, v_phone, v_wa, v_email, 'new lead'), v_lead.id, v_cust, v_owner, v_actor,
          CASE v_score->>'temperature' WHEN 'hot' THEN 'urgent' WHEN 'warm' THEN 'high' ELSE 'normal' END,
          now() + make_interval(mins => v_minutes), v_minutes, 'first_contact:' || v_lead.id)
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('created', true,
    'lead', jsonb_build_object('id', v_lead.id, 'lead_no', v_lead.lead_no, 'score', (v_score->>'score')::int,
                               'temperature', v_score->>'temperature', 'owner_staff_id', v_owner),
    'customer_id', v_cust, 'customer_is_new', v_cust_new,
    'duplicates', jsonb_build_object('exact', v_exact, 'probable', v_prob));
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_task_escalate(p_org_code text DEFAULT 'NEGOTRIP') RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_org uuid; v_grace int; v_mgr uuid; v_out jsonb;
BEGIN
  SELECT id INTO v_org FROM crm.org WHERE code = p_org_code;
  IF v_org IS NULL THEN RETURN jsonb_build_object('escalated', '[]'::jsonb); END IF;
  v_grace := COALESCE((crm.fn_cfg(v_org, 'lead_sla')->>'escalate_after_minutes')::int, 30);
  SELECT s.id INTO v_mgr FROM crm.staff s WHERE s.org_id = v_org AND s.active AND crm.fn_is_manager(s.role)
  ORDER BY CASE s.role WHEN 'sales_manager' THEN 0 WHEN 'branch_manager' THEN 1 WHEN 'company_admin' THEN 2 ELSE 3 END, s.created_at LIMIT 1;
  WITH due AS (
    UPDATE crm.task t SET escalated_at = now(), escalated_to_staff_id = v_mgr, updated_at = now()
    WHERE t.org_id = v_org AND t.status IN ('open', 'in_progress') AND t.escalated_at IS NULL
      AND t.due_at IS NOT NULL AND t.due_at < now() - make_interval(mins => v_grace)
    RETURNING t.id, t.title, t.lead_id, t.customer_id, t.owner_staff_id, t.due_at
  ), ev AS (
    INSERT INTO crm.event (org_id, event_type, actor_label, lead_id, customer_id, task_id, workflow, detail)
    SELECT v_org, 'task.escalated', 'System', d.lead_id, d.customer_id, d.id, 'TRAVELCRM-WF-007',
           jsonb_build_object('title', d.title, 'due_at', d.due_at, 'to', v_mgr)
    FROM due d RETURNING 1
  )
  SELECT jsonb_build_object('escalated', COALESCE(jsonb_agg(jsonb_build_object('task_id', d.id, 'title', d.title, 'lead_id', d.lead_id,
           'owner_staff_id', d.owner_staff_id, 'due_at', d.due_at)), '[]'::jsonb), 'manager_staff_id', v_mgr, 'events', (SELECT count(*) FROM ev))
  INTO v_out FROM due d;
  RETURN v_out;
END $fn$
;

CREATE OR REPLACE FUNCTION crm.fn_lead_guard(st crm.staff, p_lead uuid, p_edit boolean) RETURNS crm.lead LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE;
BEGIN
  IF p_lead IS NULL THEN PERFORM crm.fn_fail(400, 'missing_lead', 'No lead was named.'); END IF;
  SELECT * INTO l FROM crm.lead WHERE id = p_lead AND org_id = st.org_id AND deleted_at IS NULL;
  IF NOT FOUND OR (st.role = 'sales_executive' AND l.owner_staff_id IS NOT NULL AND l.owner_staff_id <> st.id) THEN
    PERFORM crm.fn_fail(404, 'not_found', 'That lead was not found.');
  END IF;
  IF p_edit AND NOT crm.fn_can_edit_leads(st.role) THEN
    PERFORM crm.fn_fail(403, 'read_only', 'Your role can view leads but not change them.');
  END IF;
  RETURN l;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_bootstrap(st crm.staff) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  WITH vis AS (
    SELECT l.status, l.created_at, l.temperature, l.owner_staff_id FROM crm.lead l
    WHERE l.org_id = st.org_id AND l.deleted_at IS NULL
      AND (st.role <> 'sales_executive' OR l.owner_staff_id = st.id OR l.owner_staff_id IS NULL)
  ), open_vis AS (SELECT * FROM vis WHERE status NOT IN ('won', 'lost', 'dormant', 'duplicate'))
  SELECT jsonb_build_object(
    'me', jsonb_build_object('id', st.id, 'name', st.full_name, 'email', st.email, 'role', st.role,
                             'is_manager', crm.fn_is_manager(st.role), 'is_admin', crm.fn_is_admin(st.role), 'can_edit', crm.fn_can_edit_leads(st.role)),
    'org', (SELECT jsonb_build_object('code', o.code, 'name', o.name, 'currency', o.base_currency) FROM crm.org o WHERE o.id = st.org_id),
    'lead_counts', COALESCE((SELECT jsonb_object_agg(status, n) FROM (SELECT status, count(*)::int AS n FROM vis GROUP BY status) c), '{}'::jsonb),
    'leads_total', (SELECT count(*)::int FROM vis),
    'leads_open', (SELECT count(*)::int FROM open_vis),
    'leads_last_7_days', (SELECT count(*)::int FROM vis WHERE created_at >= now() - interval '7 days'),
    'leads_hot', (SELECT count(*)::int FROM open_vis WHERE temperature = 'hot'),
    'leads_unassigned', (SELECT count(*)::int FROM open_vis WHERE owner_staff_id IS NULL),
    'my_open_tasks', (SELECT count(*)::int FROM crm.task t WHERE t.org_id = st.org_id AND t.owner_staff_id = st.id AND t.status IN ('open', 'in_progress')),
    'my_overdue_tasks', (SELECT count(*)::int FROM crm.task t WHERE t.org_id = st.org_id AND t.owner_staff_id = st.id AND t.status IN ('open', 'in_progress') AND t.due_at < now()),
    'duplicates_pending', (SELECT count(*)::int FROM crm.lead_duplicate d JOIN crm.lead l ON l.id = d.lead_id
                           WHERE d.org_id = st.org_id AND d.status = 'pending' AND l.deleted_at IS NULL
                             AND (st.role <> 'sales_executive' OR l.owner_staff_id = st.id OR l.owner_staff_id IS NULL)),
    'sources', COALESCE((SELECT jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'channel', s.channel) ORDER BY s.name) FROM crm.lead_source s WHERE s.org_id = st.org_id AND s.active), '[]'::jsonb),
    'staff', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.full_name, 'role', s.role) ORDER BY s.full_name) FROM crm.staff s WHERE s.org_id = st.org_id AND s.active), '[]'::jsonb)
  )
$fn$;

CREATE OR REPLACE FUNCTION crm.api_leads_list(st crm.staff, b jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_status text := crm.fn_s(b->>'status', 40); v_q text := crm.fn_s(b->>'q', 80);
  v_owner text := crm.fn_s(b->>'owner', 40); v_temp text := crm.fn_s(b->>'temperature', 10);
  v_lim int := COALESCE(crm.fn_int(b->>'limit', 1, 200), 50); v_off int := COALESCE(crm.fn_int(b->>'offset', 0, 100000), 0);
  v_owner_id uuid; v_out jsonb;
BEGIN
  v_owner_id := CASE WHEN v_owner = 'me' THEN st.id ELSE crm.fn_uuid(v_owner) END;
  WITH hit AS (
    SELECT l.id, l.lead_no, l.full_name, l.phone_e164, l.email, l.destination_text, l.travel_start, l.pax_adults, l.pax_children,
           l.status, l.temperature, l.score, l.priority, l.next_best_action, l.created_at, l.owner_staff_id,
           s.name AS source, o.full_name AS owner_name,
           (SELECT count(*)::int FROM crm.lead_duplicate d WHERE d.lead_id = l.id AND d.status = 'pending') AS duplicates_pending
    FROM crm.lead l
    JOIN crm.lead_source s ON s.id = l.source_id
    LEFT JOIN crm.staff o ON o.id = l.owner_staff_id
    WHERE l.org_id = st.org_id AND l.deleted_at IS NULL
      AND (st.role <> 'sales_executive' OR l.owner_staff_id = st.id OR l.owner_staff_id IS NULL)
      AND (v_status IS NULL OR l.status = v_status OR (v_status = 'open' AND l.status NOT IN ('won', 'lost', 'dormant', 'duplicate')))
      AND (v_temp IS NULL OR l.temperature = v_temp)
      AND (v_owner IS NULL OR (v_owner = 'unassigned' AND l.owner_staff_id IS NULL) OR (v_owner_id IS NOT NULL AND l.owner_staff_id = v_owner_id))
      AND (v_q IS NULL OR l.full_name ILIKE '%' || v_q || '%' OR l.phone_e164 LIKE '%' || v_q || '%' OR l.email ILIKE '%' || v_q || '%'
           OR l.lead_no ILIKE '%' || v_q || '%' OR l.destination_text ILIKE '%' || v_q || '%' OR l.company_name ILIKE '%' || v_q || '%')
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*)::int FROM hit),
    'leads', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC) FROM (SELECT * FROM hit ORDER BY created_at DESC LIMIT v_lim OFFSET v_off) p), '[]'::jsonb))
  INTO v_out;
  RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_lead_create(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_rid text := crm.fn_s(b->>'request_id', 64); v_assign text := crm.fn_s(b->>'assign', 40); v_res jsonb;
BEGIN
  IF NOT crm.fn_can_edit_leads(st.role) THEN PERFORM crm.fn_fail(403, 'read_only', 'Your role can view leads but not add them.'); END IF;
  IF v_rid IS NULL OR v_rid !~ '^[A-Za-z0-9-]{8,64}($)' THEN PERFORM crm.fn_fail(400, 'missing_request_id', 'This request is missing its ID. Reload the page and try again.'); END IF;
  v_assign := CASE WHEN v_assign = 'auto' THEN 'auto'
                   WHEN crm.fn_uuid(v_assign) IS NOT NULL AND crm.fn_is_manager(st.role) THEN v_assign
                   ELSE 'creator' END;
  v_res := crm.fn_lead_intake((b - 'action') || jsonb_build_object(
    'org_id', st.org_id, 'strict', true, 'source', COALESCE(crm.fn_s(b->>'source', 40), 'phone'), 'source_ref', v_rid,
    'actor_staff_id', st.id, 'actor_label', st.full_name, 'assign', v_assign, 'workflow', 'TRAVELCRM-API-001', 'execution_id', p_exec,
    'raw', jsonb_build_object('via', 'crm_web_app', 'entered_by', st.email)));
  RETURN v_res || jsonb_build_object('possible_duplicates', COALESCE((v_res->'duplicates'->>'exact')::int, 0) + COALESCE((v_res->'duplicates'->>'probable')::int, 0));
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_lead_get(st crm.staff, b jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE l crm.lead%ROWTYPE; v_out jsonb;
BEGIN
  l := crm.fn_lead_guard(st, crm.fn_uuid(b->>'id'), false);
  SELECT jsonb_build_object(
    'lead', jsonb_build_object(
      'id', l.id, 'lead_no', l.lead_no, 'full_name', l.full_name, 'phone_e164', l.phone_e164, 'whatsapp_e164', l.whatsapp_e164, 'email', l.email,
      'company_name', l.company_name, 'audience', l.audience, 'segment', l.segment, 'destination_text', l.destination_text,
      'travel_start', l.travel_start, 'travel_end', l.travel_end, 'pax_adults', l.pax_adults, 'pax_children', l.pax_children, 'pax_infants', l.pax_infants,
      'budget_amount', l.budget_amount, 'budget_currency', l.budget_currency, 'message', l.message, 'status', l.status, 'lost_reason', l.lost_reason,
      'temperature', l.temperature, 'score', l.score, 'priority', l.priority, 'next_best_action', l.next_best_action,
      'conversion_probability', l.conversion_probability, 'owner_staff_id', l.owner_staff_id,
      'owner_name', (SELECT full_name FROM crm.staff WHERE id = l.owner_staff_id),
      'source', (SELECT name FROM crm.lead_source WHERE id = l.source_id), 'campaign', l.campaign,
      'utm_source', l.utm_source, 'utm_medium', l.utm_medium, 'utm_campaign', l.utm_campaign,
      'first_response_at', l.first_response_at, 'created_at', l.created_at, 'updated_at', l.updated_at,
      'duplicate_of_lead_id', l.duplicate_of_lead_id, 'customer_id', l.customer_id,
      'can_edit', crm.fn_can_edit_leads(st.role)),
    'customer', (SELECT jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'full_name', c.full_name,
                   'leads', (SELECT count(*)::int FROM crm.lead x WHERE x.customer_id = c.id AND x.deleted_at IS NULL))
                 FROM crm.customer c WHERE c.id = l.customer_id),
    'score', (SELECT jsonb_build_object('rule_score', s.rule_score, 'ai_score', s.ai_score, 'final_score', s.final_score, 'factors', s.factors, 'scored_at', s.scored_at)
              FROM crm.lead_score s WHERE s.lead_id = l.id ORDER BY s.scored_at DESC LIMIT 1),
    'timeline', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'type', e.event_type, 'at', e.occurred_at, 'by', e.actor_label, 'detail', e.detail) ORDER BY e.occurred_at DESC, e.id)
                          FROM (SELECT * FROM crm.event WHERE lead_id = l.id ORDER BY occurred_at DESC LIMIT 100) e), '[]'::jsonb),
    'notes', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'body', n.body, 'at', n.created_at, 'by', (SELECT full_name FROM crm.staff WHERE id = n.staff_id)) ORDER BY n.created_at DESC)
                       FROM crm.lead_note n WHERE n.lead_id = l.id AND n.deleted_at IS NULL), '[]'::jsonb),
    'tasks', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'type', t.type, 'title', t.title, 'body', t.body, 'priority', t.priority, 'due_at', t.due_at,
                         'status', t.status, 'escalated_at', t.escalated_at, 'owner_staff_id', t.owner_staff_id,
                         'owner_name', (SELECT full_name FROM crm.staff WHERE id = t.owner_staff_id)) ORDER BY (t.status IN ('open', 'in_progress')) DESC, t.due_at NULLS LAST)
                       FROM crm.task t WHERE t.lead_id = l.id), '[]'::jsonb),
    'duplicates', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'match_type', d.match_type, 'reasons', d.reasons, 'status', d.status,
                              'other', jsonb_build_object('id', o.id, 'lead_no', o.lead_no, 'full_name', o.full_name, 'status', o.status, 'created_at', o.created_at,
                                                         'destination_text', o.destination_text, 'owner_name', (SELECT full_name FROM crm.staff WHERE id = o.owner_staff_id)))
                              ORDER BY (d.status = 'pending') DESC, d.match_type, o.created_at DESC)
                            FROM crm.lead_duplicate d JOIN crm.lead o ON o.id = d.other_lead_id WHERE d.lead_id = l.id), '[]'::jsonb),
    'other_leads', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'lead_no', x.lead_no, 'status', x.status, 'destination_text', x.destination_text, 'created_at', x.created_at) ORDER BY x.created_at DESC)
                             FROM crm.lead x WHERE l.customer_id IS NOT NULL AND x.customer_id = l.customer_id AND x.id <> l.id AND x.deleted_at IS NULL), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_lead_update(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; v_phone text; v_email text; v_fields text[] := '{}'; v_budget numeric; v_aud text;
BEGIN
  l := crm.fn_lead_guard(st, crm.fn_uuid(b->>'id'), true);
  IF b ? 'full_name' THEN
    IF crm.fn_s(b->>'full_name', 120) IS NULL THEN PERFORM crm.fn_fail(400, 'missing_name', 'Enter the name of the person.'); END IF;
    l.full_name := crm.fn_s(b->>'full_name', 120); v_fields := array_append(v_fields, 'name');
  END IF;
  IF b ? 'phone' THEN
    v_phone := crm.fn_norm_phone(b->>'phone');
    IF crm.fn_s(b->>'phone', 40) IS NOT NULL AND v_phone IS NULL THEN PERFORM crm.fn_fail(400, 'bad_phone', 'That phone number does not look right. Use 10 digits, or start with + and the country code.'); END IF;
    IF l.whatsapp_e164 IS NOT DISTINCT FROM l.phone_e164 THEN l.whatsapp_e164 := v_phone; END IF;
    l.phone_e164 := v_phone; v_fields := array_append(v_fields, 'phone');
  END IF;
  IF b ? 'email' THEN
    v_email := crm.fn_norm_email(b->>'email');
    IF crm.fn_s(b->>'email', 160) IS NOT NULL AND v_email IS NULL THEN PERFORM crm.fn_fail(400, 'bad_email', 'That email address does not look right.'); END IF;
    l.email := v_email; v_fields := array_append(v_fields, 'email');
  END IF;
  IF l.phone_e164 IS NULL AND l.email IS NULL AND l.whatsapp_e164 IS NULL THEN PERFORM crm.fn_fail(400, 'missing_contact', 'Keep at least a phone number or an email.'); END IF;
  IF b ? 'company_name' THEN l.company_name := crm.fn_s(b->>'company_name', 160); v_fields := array_append(v_fields, 'company'); END IF;
  IF b ? 'destination' THEN l.destination_text := crm.fn_s(b->>'destination', 160); v_fields := array_append(v_fields, 'destination'); END IF;
  IF b ? 'travel_start' THEN l.travel_start := crm.fn_date(b->>'travel_start'); v_fields := array_append(v_fields, 'travel date'); END IF;
  IF b ? 'travel_end' THEN l.travel_end := crm.fn_date(b->>'travel_end'); v_fields := array_append(v_fields, 'return date'); END IF;
  IF b ? 'adults' THEN l.pax_adults := crm.fn_int(b->>'adults', 0, 500); v_fields := array_append(v_fields, 'adults'); END IF;
  IF b ? 'children' THEN l.pax_children := crm.fn_int(b->>'children', 0, 500); v_fields := array_append(v_fields, 'children'); END IF;
  IF b ? 'infants' THEN l.pax_infants := crm.fn_int(b->>'infants', 0, 100); v_fields := array_append(v_fields, 'infants'); END IF;
  IF b ? 'budget' THEN
    v_budget := crm.fn_num(b->>'budget');
    IF v_budget IS NOT NULL AND v_budget <= 0 THEN v_budget := NULL; END IF;
    l.budget_amount := v_budget; l.budget_currency := CASE WHEN v_budget IS NOT NULL THEN COALESCE(l.budget_currency, 'INR') END;
    v_fields := array_append(v_fields, 'budget');
  END IF;
  IF b ? 'message' THEN l.message := crm.fn_s(b->>'message', 4000); v_fields := array_append(v_fields, 'request'); END IF;
  IF b ? 'segment' THEN l.segment := lower(crm.fn_s(b->>'segment', 40)); v_fields := array_append(v_fields, 'segment'); END IF;
  IF b ? 'audience' THEN
    v_aud := lower(crm.fn_s(b->>'audience', 20));
    IF v_aud IN ('retail', 'b2b', 'corporate') THEN l.audience := v_aud; v_fields := array_append(v_fields, 'audience'); END IF;
  END IF;
  IF l.travel_start IS NOT NULL AND l.travel_end IS NOT NULL AND l.travel_end < l.travel_start THEN
    PERFORM crm.fn_fail(400, 'bad_dates', 'The return date is before the travel date.');
  END IF;
  UPDATE crm.lead SET full_name = l.full_name, phone_e164 = l.phone_e164, whatsapp_e164 = l.whatsapp_e164, email = l.email, company_name = l.company_name,
         destination_text = l.destination_text, travel_start = l.travel_start, travel_end = l.travel_end, pax_adults = l.pax_adults,
         pax_children = l.pax_children, pax_infants = l.pax_infants, budget_amount = l.budget_amount, budget_currency = l.budget_currency,
         message = l.message, segment = l.segment, audience = l.audience, updated_at = now(), last_activity_at = now()
  WHERE id = l.id;
  IF array_length(v_fields, 1) > 0 THEN
    PERFORM crm.fn_event(st.org_id, 'lead.updated', st.id, st.full_name, l.id, l.customer_id, NULL, jsonb_build_object('fields', to_jsonb(v_fields)), false, 'TRAVELCRM-API-001', p_exec);
  END IF;
  RETURN jsonb_build_object('score', crm.fn_lead_score(l.id), 'changed', to_jsonb(v_fields));
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_lead_set_status(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; v_to text := crm.fn_s(b->>'status', 40); v_reason text := crm.fn_s(b->>'reason', 500);
BEGIN
  l := crm.fn_lead_guard(st, crm.fn_uuid(b->>'id'), true);
  IF v_to IS NULL OR v_to NOT IN ('new', 'contacted', 'qualified', 'requirement_collected', 'quoted', 'negotiating', 'won', 'lost', 'dormant') THEN
    PERFORM crm.fn_fail(400, 'bad_status', 'Choose a stage from the list.');
  END IF;
  IF l.status = 'duplicate' THEN PERFORM crm.fn_fail(400, 'is_duplicate', 'This lead was merged into another one and cannot change stage.'); END IF;
  IF v_to = l.status THEN RETURN jsonb_build_object('status', l.status, 'changed', false); END IF;
  IF v_to = 'lost' AND v_reason IS NULL THEN PERFORM crm.fn_fail(400, 'missing_reason', 'Say why the lead was lost.'); END IF;
  UPDATE crm.lead SET status = v_to, lost_reason = CASE WHEN v_to = 'lost' THEN v_reason ELSE NULL END,
         first_response_at = CASE WHEN first_response_at IS NULL AND v_to <> 'new' THEN now() ELSE first_response_at END,
         updated_at = now(), last_activity_at = now()
  WHERE id = l.id;
  INSERT INTO crm.lead_status_history (lead_id, from_status, to_status, changed_by_staff_id, reason) VALUES (l.id, l.status, v_to, st.id, v_reason);
  IF l.status = 'new' THEN
    UPDATE crm.task SET status = 'done', completed_at = now(), completed_by_staff_id = st.id, updated_at = now()
    WHERE lead_id = l.id AND dedupe_key = 'first_contact:' || l.id AND status IN ('open', 'in_progress');
  END IF;
  IF v_to IN ('won', 'lost', 'dormant') THEN
    UPDATE crm.task SET status = 'cancelled', updated_at = now() WHERE lead_id = l.id AND status IN ('open', 'in_progress');
  END IF;
  PERFORM crm.fn_event(st.org_id, 'lead.status_changed', st.id, st.full_name, l.id, l.customer_id, NULL,
    jsonb_build_object('from', l.status, 'to', v_to, 'reason', v_reason), v_to IN ('won', 'lost'), 'TRAVELCRM-API-001', p_exec);
  RETURN jsonb_build_object('status', v_to, 'changed', true, 'score', crm.fn_lead_score(l.id));
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_lead_assign(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; v_raw text := crm.fn_s(b->>'staff_id', 40); v_to uuid;
BEGIN
  l := crm.fn_lead_guard(st, crm.fn_uuid(b->>'id'), true);
  v_to := CASE WHEN v_raw = 'me' THEN st.id ELSE crm.fn_uuid(v_raw) END;
  IF NOT crm.fn_is_manager(st.role) THEN
    IF NOT (l.owner_staff_id IS NULL AND v_to = st.id) THEN
      PERFORM crm.fn_fail(403, 'manager_only', 'Only a manager can move a lead to someone else. You can take a lead that has no owner.');
    END IF;
  END IF;
  IF v_to IS NOT NULL AND NOT EXISTS (SELECT 1 FROM crm.staff s WHERE s.id = v_to AND s.org_id = st.org_id AND s.active) THEN
    PERFORM crm.fn_fail(400, 'bad_staff', 'That person is not an active member of the CRM.');
  END IF;
  PERFORM crm.fn_lead_set_owner(l.id, v_to, st.id, st.full_name, CASE WHEN v_to = st.id AND l.owner_staff_id IS NULL THEN 'claimed' ELSE 'manual' END, p_exec);
  RETURN jsonb_build_object('owner_staff_id', v_to);
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_lead_note_add(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE l crm.lead%ROWTYPE; v_body text := crm.fn_s(b->>'body', 4000); v_id uuid;
BEGIN
  l := crm.fn_lead_guard(st, crm.fn_uuid(b->>'id'), true);
  IF v_body IS NULL THEN PERFORM crm.fn_fail(400, 'empty_note', 'Write the note first.'); END IF;
  INSERT INTO crm.lead_note (lead_id, staff_id, body) VALUES (l.id, st.id, v_body) RETURNING id INTO v_id;
  UPDATE crm.lead SET last_activity_at = now(), updated_at = now() WHERE id = l.id;
  PERFORM crm.fn_event(st.org_id, 'note.added', st.id, st.full_name, l.id, l.customer_id, NULL, jsonb_build_object('note_id', v_id, 'preview', left(v_body, 140)), false, 'TRAVELCRM-API-001', p_exec);
  RETURN jsonb_build_object('note_id', v_id);
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_duplicate_decide(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE d crm.lead_duplicate%ROWTYPE; l crm.lead%ROWTYPE; o crm.lead%ROWTYPE; v_dec text := crm.fn_s(b->>'decision', 20);
BEGIN
  SELECT * INTO d FROM crm.lead_duplicate WHERE id = crm.fn_uuid(b->>'id') AND org_id = st.org_id;
  IF NOT FOUND THEN PERFORM crm.fn_fail(404, 'not_found', 'That duplicate check was not found.'); END IF;
  l := crm.fn_lead_guard(st, d.lead_id, true);
  IF v_dec IS NULL OR v_dec NOT IN ('merge', 'dismiss') THEN PERFORM crm.fn_fail(400, 'bad_decision', 'Choose merge or not a duplicate.'); END IF;
  IF d.status <> 'pending' THEN PERFORM crm.fn_fail(400, 'already_decided', 'This duplicate check was already decided.'); END IF;
  SELECT * INTO o FROM crm.lead WHERE id = d.other_lead_id;
  IF v_dec = 'dismiss' THEN
    UPDATE crm.lead_duplicate SET status = 'dismissed', decided_by_staff_id = st.id, decided_at = now() WHERE id = d.id;
  ELSE
    UPDATE crm.lead_duplicate SET status = 'merged', decided_by_staff_id = st.id, decided_at = now() WHERE id = d.id;
    UPDATE crm.lead_duplicate SET status = 'dismissed', decided_by_staff_id = st.id, decided_at = now() WHERE lead_id = l.id AND status = 'pending';
    UPDATE crm.lead SET status = 'duplicate', duplicate_of_lead_id = o.id, updated_at = now() WHERE id = l.id;
    INSERT INTO crm.lead_status_history (lead_id, from_status, to_status, changed_by_staff_id, reason) VALUES (l.id, l.status, 'duplicate', st.id, 'Merged into ' || o.lead_no);
    UPDATE crm.task SET status = 'cancelled', updated_at = now() WHERE lead_id = l.id AND status IN ('open', 'in_progress');
    UPDATE crm.lead SET last_activity_at = now(), updated_at = now() WHERE id = o.id;
    PERFORM crm.fn_event(st.org_id, 'lead.merged_from', st.id, st.full_name, o.id, o.customer_id, NULL, jsonb_build_object('lead_no', l.lead_no, 'lead_id', l.id), true, 'TRAVELCRM-API-001', p_exec);
  END IF;
  PERFORM crm.fn_event(st.org_id, 'duplicate.decided', st.id, st.full_name, l.id, l.customer_id, NULL,
    jsonb_build_object('decision', v_dec, 'other_lead_no', o.lead_no, 'other_lead_id', o.id, 'match_type', d.match_type), true, 'TRAVELCRM-API-001', p_exec);
  RETURN jsonb_build_object('decision', v_dec, 'kept_lead_id', CASE WHEN v_dec = 'merge' THEN o.id END);
END $fn$
;

CREATE OR REPLACE FUNCTION crm.fn_can_edit_customers(p_role text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_role IN ('super_admin', 'company_admin', 'branch_manager', 'sales_manager', 'sales_executive', 'operations', 'accounts')
$fn$;

CREATE OR REPLACE FUNCTION crm.fn_customer_guard(st crm.staff, p_customer uuid, p_edit boolean) RETURNS crm.customer LANGUAGE plpgsql AS $fn$
DECLARE c crm.customer%ROWTYPE;
BEGIN
  IF p_customer IS NULL THEN PERFORM crm.fn_fail(400, 'missing_customer', 'No customer was named.'); END IF;
  SELECT * INTO c FROM crm.customer WHERE id = p_customer AND org_id = st.org_id AND deleted_at IS NULL;
  IF NOT FOUND OR (st.role = 'sales_executive'
       AND EXISTS (SELECT 1 FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL AND (l.owner_staff_id = st.id OR l.owner_staff_id IS NULL))) THEN
    PERFORM crm.fn_fail(404, 'not_found', 'That customer was not found.');
  END IF;
  IF p_edit AND NOT crm.fn_can_edit_customers(st.role) THEN
    PERFORM crm.fn_fail(403, 'read_only', 'Your role can view customers but not change them.');
  END IF;
  RETURN c;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_tasks_list(st crm.staff, b jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_scope text := COALESCE(crm.fn_s(b->>'scope', 10), 'mine'); v_when text := COALESCE(crm.fn_s(b->>'when', 12), 'open');
  v_lead uuid := crm.fn_uuid(b->>'lead_id'); v_lim int := COALESCE(crm.fn_int(b->>'limit', 1, 300), 100);
  v_tz text; v_today date; v_out jsonb;
BEGIN
  SELECT timezone INTO v_tz FROM crm.org WHERE id = st.org_id;
  v_tz := COALESCE(v_tz, 'Asia/Kolkata');
  v_today := (now() AT TIME ZONE v_tz)::date;
  WITH vis AS (
    SELECT t.* FROM crm.task t
    WHERE t.org_id = st.org_id
      AND (st.role <> 'sales_executive' OR t.owner_staff_id = st.id OR t.owner_staff_id IS NULL OR t.created_by_staff_id = st.id)
      AND (v_scope <> 'mine' OR t.owner_staff_id = st.id)
      AND (v_lead IS NULL OR t.lead_id = v_lead)
  ), live AS (SELECT * FROM vis WHERE status IN ('open', 'in_progress')),
  hit AS (
    SELECT * FROM vis v WHERE
      CASE v_when
        WHEN 'done' THEN v.status = 'done'
        WHEN 'overdue' THEN v.status IN ('open', 'in_progress') AND v.due_at < now()
        WHEN 'today' THEN v.status IN ('open', 'in_progress') AND (v.due_at AT TIME ZONE v_tz)::date = v_today
        WHEN 'upcoming' THEN v.status IN ('open', 'in_progress') AND (v.due_at IS NULL OR (v.due_at AT TIME ZONE v_tz)::date > v_today)
        ELSE v.status IN ('open', 'in_progress') END
  )
  SELECT jsonb_build_object(
    'counts', jsonb_build_object(
      'open', (SELECT count(*)::int FROM live),
      'overdue', (SELECT count(*)::int FROM live WHERE due_at < now()),
      'today', (SELECT count(*)::int FROM live WHERE (due_at AT TIME ZONE v_tz)::date = v_today),
      'escalated', (SELECT count(*)::int FROM live WHERE escalated_at IS NOT NULL)),
    'tasks', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.ord_done, x.due_at NULLS LAST, x.created_at) FROM (
        SELECT h.due_at, h.created_at, CASE WHEN h.status = 'done' THEN 1 ELSE 0 END AS ord_done,
          jsonb_build_object('id', h.id, 'type', h.type, 'title', h.title, 'body', h.body, 'priority', h.priority, 'due_at', h.due_at, 'status', h.status,
            'overdue', (h.status IN ('open', 'in_progress') AND h.due_at < now()), 'escalated_at', h.escalated_at, 'completed_at', h.completed_at,
            'owner_staff_id', h.owner_staff_id, 'owner_name', (SELECT full_name FROM crm.staff WHERE id = h.owner_staff_id),
            'lead', (SELECT jsonb_build_object('id', l.id, 'lead_no', l.lead_no, 'full_name', l.full_name, 'phone_e164', l.phone_e164, 'temperature', l.temperature) FROM crm.lead l WHERE l.id = h.lead_id),
            'customer', (SELECT jsonb_build_object('id', c.id, 'full_name', c.full_name) FROM crm.customer c WHERE c.id = h.customer_id)) AS j
        FROM hit h ORDER BY (h.status = 'done'), h.due_at NULLS LAST, h.created_at LIMIT v_lim) x), '[]'::jsonb))
  INTO v_out;
  RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_task_create(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_title text := crm.fn_s(b->>'title', 200); v_type text := COALESCE(crm.fn_s(b->>'type', 30), 'follow_up');
  v_prio text := COALESCE(crm.fn_s(b->>'priority', 10), 'normal'); v_due timestamptz := crm.fn_ts(b->>'due_at');
  v_lead uuid := crm.fn_uuid(b->>'lead_id'); v_cust uuid := crm.fn_uuid(b->>'customer_id');
  v_owner_raw text := crm.fn_s(b->>'owner_staff_id', 40); v_owner uuid; l crm.lead%ROWTYPE; c crm.customer%ROWTYPE; v_id uuid;
BEGIN
  IF st.role = 'read_only' THEN PERFORM crm.fn_fail(403, 'read_only', 'Your role can view tasks but not add them.'); END IF;
  IF v_title IS NULL THEN PERFORM crm.fn_fail(400, 'missing_title', 'Say what needs doing.'); END IF;
  IF v_type NOT IN ('call', 'follow_up', 'payment', 'document', 'supplier_confirmation', 'visa', 'booking', 'travel', 'other') THEN v_type := 'follow_up'; END IF;
  IF v_prio NOT IN ('low', 'normal', 'high', 'urgent') THEN v_prio := 'normal'; END IF;
  IF crm.fn_s(b->>'due_at', 40) IS NOT NULL AND v_due IS NULL THEN PERFORM crm.fn_fail(400, 'bad_due', 'That due date does not look right.'); END IF;
  IF v_lead IS NOT NULL THEN
    l := crm.fn_lead_guard(st, v_lead, false);
    v_cust := COALESCE(v_cust, l.customer_id);
  END IF;
  IF v_cust IS NOT NULL THEN c := crm.fn_customer_guard(st, v_cust, false); END IF;
  v_owner := CASE WHEN v_owner_raw IS NULL OR v_owner_raw = 'me' THEN st.id ELSE crm.fn_uuid(v_owner_raw) END;
  IF v_owner IS NULL THEN PERFORM crm.fn_fail(400, 'bad_staff', 'Choose who the task is for.'); END IF;
  IF v_owner <> st.id AND NOT crm.fn_is_manager(st.role) THEN PERFORM crm.fn_fail(403, 'manager_only', 'Only a manager can give a task to someone else.'); END IF;
  IF NOT EXISTS (SELECT 1 FROM crm.staff s WHERE s.id = v_owner AND s.org_id = st.org_id AND s.active) THEN
    PERFORM crm.fn_fail(400, 'bad_staff', 'That person is not an active member of the CRM.');
  END IF;
  INSERT INTO crm.task (org_id, type, title, body, lead_id, customer_id, owner_staff_id, created_by_staff_id, priority, due_at)
  VALUES (st.org_id, v_type, v_title, crm.fn_s(b->>'body', 2000), v_lead, v_cust, v_owner, st.id, v_prio, v_due)
  RETURNING id INTO v_id;
  IF v_lead IS NOT NULL THEN UPDATE crm.lead SET last_activity_at = now(), updated_at = now() WHERE id = v_lead; END IF;
  PERFORM crm.fn_event(st.org_id, 'task.created', st.id, st.full_name, v_lead, v_cust, v_id,
    jsonb_build_object('title', v_title, 'type', v_type, 'due_at', v_due, 'for', (SELECT full_name FROM crm.staff WHERE id = v_owner)), false, 'TRAVELCRM-API-001', p_exec);
  RETURN jsonb_build_object('task_id', v_id);
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_task_update(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  t crm.task%ROWTYPE; v_op text := crm.fn_s(b->>'op', 12); v_fields text[] := '{}'; v_owner uuid; v_due timestamptz; v_evt text; v_txt text;
BEGIN
  SELECT * INTO t FROM crm.task WHERE id = crm.fn_uuid(b->>'id') AND org_id = st.org_id;
  IF NOT FOUND OR (st.role = 'sales_executive' AND t.owner_staff_id IS NOT NULL AND t.owner_staff_id <> st.id AND t.created_by_staff_id IS DISTINCT FROM st.id) THEN
    PERFORM crm.fn_fail(404, 'not_found', 'That task was not found.');
  END IF;
  IF st.role = 'read_only' THEN PERFORM crm.fn_fail(403, 'read_only', 'Your role can view tasks but not change them.'); END IF;
  IF NOT crm.fn_is_manager(st.role) AND t.owner_staff_id IS NOT NULL AND t.owner_staff_id <> st.id AND t.created_by_staff_id IS DISTINCT FROM st.id THEN
    PERFORM crm.fn_fail(403, 'not_yours', 'This task belongs to someone else.');
  END IF;

  IF v_op IS NOT NULL THEN
    IF v_op = 'complete' THEN
      IF t.status = 'done' THEN RETURN jsonb_build_object('status', 'done', 'changed', false); END IF;
      t.status := 'done'; t.completed_at := now(); t.completed_by_staff_id := st.id; v_evt := 'task.completed';
    ELSIF v_op = 'reopen' THEN
      t.status := 'open'; t.completed_at := NULL; t.completed_by_staff_id := NULL; v_evt := 'task.reopened';
    ELSIF v_op = 'cancel' THEN
      t.status := 'cancelled'; v_evt := 'task.cancelled';
    ELSIF v_op = 'start' THEN
      t.status := 'in_progress'; v_evt := 'task.started';
    ELSE
      PERFORM crm.fn_fail(400, 'bad_op', 'That task action is not known.');
    END IF;
  END IF;

  IF b ? 'title' THEN
    IF crm.fn_s(b->>'title', 200) IS NULL THEN PERFORM crm.fn_fail(400, 'missing_title', 'Say what needs doing.'); END IF;
    t.title := crm.fn_s(b->>'title', 200); v_fields := array_append(v_fields, 'title');
  END IF;
  IF b ? 'body' THEN t.body := crm.fn_s(b->>'body', 2000); v_fields := array_append(v_fields, 'details'); END IF;
  IF b ? 'type' THEN
    v_txt := crm.fn_s(b->>'type', 30);
    IF v_txt IN ('call', 'follow_up', 'payment', 'document', 'supplier_confirmation', 'visa', 'booking', 'travel', 'other') THEN t.type := v_txt; v_fields := array_append(v_fields, 'type'); END IF;
  END IF;
  IF b ? 'priority' THEN
    v_txt := crm.fn_s(b->>'priority', 10);
    IF v_txt IN ('low', 'normal', 'high', 'urgent') THEN t.priority := v_txt; v_fields := array_append(v_fields, 'priority'); END IF;
  END IF;
  IF b ? 'due_at' THEN
    v_due := crm.fn_ts(b->>'due_at');
    IF crm.fn_s(b->>'due_at', 40) IS NOT NULL AND v_due IS NULL THEN PERFORM crm.fn_fail(400, 'bad_due', 'That due date does not look right.'); END IF;
    IF v_due IS DISTINCT FROM t.due_at THEN
      t.due_at := v_due; v_fields := array_append(v_fields, 'due date');
      IF v_due IS NULL OR v_due > now() THEN t.escalated_at := NULL; t.escalated_to_staff_id := NULL; END IF;
    END IF;
  END IF;
  IF b ? 'owner_staff_id' THEN
    v_owner := CASE WHEN b->>'owner_staff_id' = 'me' THEN st.id ELSE crm.fn_uuid(b->>'owner_staff_id') END;
    IF v_owner IS NULL THEN PERFORM crm.fn_fail(400, 'bad_staff', 'Choose who the task is for.'); END IF;
    IF v_owner IS DISTINCT FROM t.owner_staff_id THEN
      IF v_owner <> st.id AND NOT crm.fn_is_manager(st.role) THEN PERFORM crm.fn_fail(403, 'manager_only', 'Only a manager can give a task to someone else.'); END IF;
      IF NOT EXISTS (SELECT 1 FROM crm.staff s WHERE s.id = v_owner AND s.org_id = st.org_id AND s.active) THEN
        PERFORM crm.fn_fail(400, 'bad_staff', 'That person is not an active member of the CRM.');
      END IF;
      t.owner_staff_id := v_owner; v_fields := array_append(v_fields, 'owner');
    END IF;
  END IF;

  UPDATE crm.task SET status = t.status, completed_at = t.completed_at, completed_by_staff_id = t.completed_by_staff_id, title = t.title, body = t.body,
         type = t.type, priority = t.priority, due_at = t.due_at, escalated_at = t.escalated_at, escalated_to_staff_id = t.escalated_to_staff_id,
         owner_staff_id = t.owner_staff_id, updated_at = now()
  WHERE id = t.id;
  IF t.lead_id IS NOT NULL AND v_evt = 'task.completed' THEN UPDATE crm.lead SET last_activity_at = now(), updated_at = now() WHERE id = t.lead_id; END IF;
  IF v_evt IS NOT NULL THEN
    PERFORM crm.fn_event(st.org_id, v_evt, st.id, st.full_name, t.lead_id, t.customer_id, t.id, jsonb_build_object('title', t.title), false, 'TRAVELCRM-API-001', p_exec);
  END IF;
  IF array_length(v_fields, 1) > 0 THEN
    PERFORM crm.fn_event(st.org_id, 'task.updated', st.id, st.full_name, t.lead_id, t.customer_id, t.id,
      jsonb_build_object('title', t.title, 'fields', to_jsonb(v_fields), 'due_at', t.due_at, 'for', (SELECT full_name FROM crm.staff WHERE id = t.owner_staff_id)), false, 'TRAVELCRM-API-001', p_exec);
  END IF;
  RETURN jsonb_build_object('status', t.status, 'changed', true);
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_customers_list(st crm.staff, b jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_q text := crm.fn_s(b->>'q', 80); v_lim int := COALESCE(crm.fn_int(b->>'limit', 1, 200), 50); v_off int := COALESCE(crm.fn_int(b->>'offset', 0, 100000), 0);
  v_out jsonb;
BEGIN
  WITH hit AS (
    SELECT c.id, c.customer_no, c.kind, c.full_name, c.company_name, c.phone_e164, c.email, c.city, c.created_at,
           (SELECT count(*)::int FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL) AS leads,
           (SELECT count(*)::int FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL AND l.status = 'won') AS won,
           (SELECT max(l.created_at) FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL) AS last_lead_at
    FROM crm.customer c
    WHERE c.org_id = st.org_id AND c.deleted_at IS NULL AND c.merged_into_customer_id IS NULL
      AND (st.role <> 'sales_executive'
           OR NOT EXISTS (SELECT 1 FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL)
           OR EXISTS (SELECT 1 FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL AND (l.owner_staff_id = st.id OR l.owner_staff_id IS NULL)))
      AND (v_q IS NULL OR c.full_name ILIKE '%' || v_q || '%' OR c.phone_e164 LIKE '%' || v_q || '%' OR c.whatsapp_e164 LIKE '%' || v_q || '%'
           OR c.email ILIKE '%' || v_q || '%' OR c.customer_no ILIKE '%' || v_q || '%' OR c.company_name ILIKE '%' || v_q || '%' OR c.city ILIKE '%' || v_q || '%')
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*)::int FROM hit),
    'customers', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY COALESCE(p.last_lead_at, p.created_at) DESC)
                           FROM (SELECT * FROM hit ORDER BY COALESCE(last_lead_at, created_at) DESC LIMIT v_lim OFFSET v_off) p), '[]'::jsonb))
  INTO v_out;
  RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_customer_get(st crm.staff, b jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c crm.customer%ROWTYPE; v_out jsonb;
BEGIN
  c := crm.fn_customer_guard(st, crm.fn_uuid(b->>'id'), false);
  SELECT jsonb_build_object(
    'customer', jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'kind', c.kind, 'full_name', c.full_name, 'company_name', c.company_name,
      'phone_e164', c.phone_e164, 'whatsapp_e164', c.whatsapp_e164, 'email', c.email, 'language', c.language, 'city', c.city, 'state', c.state,
      'country_code', c.country_code, 'agent_code', c.agent_code, 'notes', c.notes, 'created_at', c.created_at, 'updated_at', c.updated_at,
      'can_edit', crm.fn_can_edit_customers(st.role)),
    'preferences', (SELECT jsonb_build_object('hotel_category', p.hotel_category, 'meal_plan', p.meal_plan, 'vehicle', p.vehicle, 'destinations', to_jsonb(p.destinations),
                      'language', p.language, 'special_assistance', p.special_assistance, 'channel_preference', p.channel_preference, 'notes', p.notes)
                    FROM crm.customer_preference p WHERE p.customer_id = c.id),
    'travellers', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'full_name', t.full_name, 'relation', t.relation, 'date_of_birth', t.date_of_birth,
                              'nationality_code', t.nationality_code, 'meal_preference', t.meal_preference, 'special_assistance', t.special_assistance) ORDER BY t.created_at)
                            FROM crm.traveller t WHERE t.customer_id = c.id AND t.deleted_at IS NULL), '[]'::jsonb),
    'leads', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', l.id, 'lead_no', l.lead_no, 'status', l.status, 'temperature', l.temperature, 'destination_text', l.destination_text,
                         'travel_start', l.travel_start, 'created_at', l.created_at, 'owner_name', (SELECT full_name FROM crm.staff WHERE id = l.owner_staff_id)) ORDER BY l.created_at DESC)
                       FROM crm.lead l WHERE l.customer_id = c.id AND l.deleted_at IS NULL
                         AND (st.role <> 'sales_executive' OR l.owner_staff_id = st.id OR l.owner_staff_id IS NULL)), '[]'::jsonb),
    'tasks', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'type', t.type, 'due_at', t.due_at, 'status', t.status, 'priority', t.priority,
                         'owner_name', (SELECT full_name FROM crm.staff WHERE id = t.owner_staff_id)) ORDER BY t.due_at NULLS LAST)
                       FROM crm.task t WHERE t.customer_id = c.id AND t.status IN ('open', 'in_progress')
                         AND (st.role <> 'sales_executive' OR t.owner_staff_id = st.id OR t.owner_staff_id IS NULL OR t.created_by_staff_id = st.id)), '[]'::jsonb),
    'consent', COALESCE((SELECT jsonb_object_agg(x.channel, x.granted) FROM (
                  SELECT DISTINCT ON (n.channel) n.channel, n.granted FROM crm.consent n WHERE n.customer_id = c.id AND n.purpose = 'marketing' ORDER BY n.channel, n.recorded_at DESC) x), '{}'::jsonb),
    'timeline', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'type', e.event_type, 'at', e.occurred_at, 'by', e.actor_label, 'detail', e.detail, 'lead_id', e.lead_id) ORDER BY e.occurred_at DESC, e.id)
                          FROM (SELECT * FROM crm.event WHERE customer_id = c.id ORDER BY occurred_at DESC LIMIT 60) e), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_customer_update(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c crm.customer%ROWTYPE; v_fields text[] := '{}'; v_phone text; v_email text; v_txt text; v_other text; pr jsonb := b->'preferences'; v_dest text[];
BEGIN
  c := crm.fn_customer_guard(st, crm.fn_uuid(b->>'id'), true);
  IF b ? 'full_name' THEN
    IF crm.fn_s(b->>'full_name', 120) IS NULL THEN PERFORM crm.fn_fail(400, 'missing_name', 'Enter the name of the customer.'); END IF;
    c.full_name := crm.fn_s(b->>'full_name', 120); v_fields := array_append(v_fields, 'name');
  END IF;
  IF b ? 'phone' THEN
    v_phone := crm.fn_norm_phone(b->>'phone');
    IF crm.fn_s(b->>'phone', 40) IS NOT NULL AND v_phone IS NULL THEN PERFORM crm.fn_fail(400, 'bad_phone', 'That phone number does not look right. Use 10 digits, or start with + and the country code.'); END IF;
    IF v_phone IS NOT NULL THEN
      SELECT o.customer_no INTO v_other FROM crm.customer o WHERE o.org_id = st.org_id AND o.id <> c.id AND o.deleted_at IS NULL AND o.merged_into_customer_id IS NULL AND o.phone_e164 = v_phone LIMIT 1;
      IF v_other IS NOT NULL THEN PERFORM crm.fn_fail(409, 'phone_in_use', 'Customer ' || v_other || ' already has this phone number.'); END IF;
    END IF;
    IF c.whatsapp_e164 IS NOT DISTINCT FROM c.phone_e164 AND NOT (b ? 'whatsapp') THEN c.whatsapp_e164 := v_phone; END IF;
    c.phone_e164 := v_phone; v_fields := array_append(v_fields, 'phone');
  END IF;
  IF b ? 'whatsapp' THEN
    v_phone := crm.fn_norm_phone(b->>'whatsapp');
    IF crm.fn_s(b->>'whatsapp', 40) IS NOT NULL AND v_phone IS NULL THEN PERFORM crm.fn_fail(400, 'bad_phone', 'That WhatsApp number does not look right.'); END IF;
    c.whatsapp_e164 := v_phone; v_fields := array_append(v_fields, 'WhatsApp');
  END IF;
  IF b ? 'email' THEN
    v_email := crm.fn_norm_email(b->>'email');
    IF crm.fn_s(b->>'email', 160) IS NOT NULL AND v_email IS NULL THEN PERFORM crm.fn_fail(400, 'bad_email', 'That email address does not look right.'); END IF;
    c.email := v_email; v_fields := array_append(v_fields, 'email');
  END IF;
  IF c.phone_e164 IS NULL AND c.whatsapp_e164 IS NULL AND c.email IS NULL THEN PERFORM crm.fn_fail(400, 'missing_contact', 'Keep at least a phone number or an email.'); END IF;
  IF b ? 'kind' THEN
    v_txt := crm.fn_s(b->>'kind', 20);
    IF v_txt IN ('individual', 'company', 'agent') THEN c.kind := v_txt; v_fields := array_append(v_fields, 'type'); END IF;
  END IF;
  IF b ? 'company_name' THEN c.company_name := crm.fn_s(b->>'company_name', 160); v_fields := array_append(v_fields, 'company'); END IF;
  IF b ? 'city' THEN c.city := crm.fn_s(b->>'city', 80); v_fields := array_append(v_fields, 'city'); END IF;
  IF b ? 'state' THEN c.state := crm.fn_s(b->>'state', 80); v_fields := array_append(v_fields, 'state'); END IF;
  IF b ? 'country_code' THEN c.country_code := upper(crm.fn_s(b->>'country_code', 2)); v_fields := array_append(v_fields, 'country'); END IF;
  IF b ? 'language' THEN c.language := crm.fn_s(b->>'language', 40); v_fields := array_append(v_fields, 'language'); END IF;
  IF b ? 'notes' THEN c.notes := crm.fn_s(b->>'notes', 4000); v_fields := array_append(v_fields, 'notes'); END IF;
  UPDATE crm.customer SET full_name = c.full_name, phone_e164 = c.phone_e164, whatsapp_e164 = c.whatsapp_e164, email = c.email, kind = c.kind,
         company_name = c.company_name, city = c.city, state = c.state, country_code = c.country_code, language = c.language, notes = c.notes, updated_at = now()
  WHERE id = c.id;

  IF pr IS NOT NULL AND jsonb_typeof(pr) = 'object' THEN
    v_txt := crm.fn_s(pr->>'channel_preference', 10);
    IF v_txt IS NOT NULL AND v_txt NOT IN ('whatsapp', 'email', 'sms', 'call') THEN v_txt := NULL; END IF;
    SELECT COALESCE(array_agg(d), '{}'::text[]) INTO v_dest FROM (
      SELECT crm.fn_s(x, 80) AS d FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pr->'destinations') = 'array' THEN pr->'destinations' ELSE '[]'::jsonb END) x LIMIT 30) q
    WHERE d IS NOT NULL;
    INSERT INTO crm.customer_preference (customer_id, hotel_category, meal_plan, vehicle, destinations, language, special_assistance, channel_preference, notes)
    VALUES (c.id, crm.fn_s(pr->>'hotel_category', 60), crm.fn_s(pr->>'meal_plan', 60), crm.fn_s(pr->>'vehicle', 60), v_dest,
            crm.fn_s(pr->>'language', 40), crm.fn_s(pr->>'special_assistance', 500), v_txt, crm.fn_s(pr->>'notes', 2000))
    ON CONFLICT (customer_id) DO UPDATE SET hotel_category = EXCLUDED.hotel_category, meal_plan = EXCLUDED.meal_plan, vehicle = EXCLUDED.vehicle,
      destinations = EXCLUDED.destinations, language = EXCLUDED.language, special_assistance = EXCLUDED.special_assistance,
      channel_preference = EXCLUDED.channel_preference, notes = EXCLUDED.notes, updated_at = now();
    v_fields := array_append(v_fields, 'preferences');
  END IF;

  IF array_length(v_fields, 1) > 0 THEN
    PERFORM crm.fn_event(st.org_id, 'customer.updated', st.id, st.full_name, NULL, c.id, NULL, jsonb_build_object('fields', to_jsonb(v_fields)), false, 'TRAVELCRM-API-001', p_exec);
  END IF;
  RETURN jsonb_build_object('changed', to_jsonb(v_fields));
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_traveller_save(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c crm.customer%ROWTYPE; t crm.traveller%ROWTYPE; v_id uuid := crm.fn_uuid(b->>'id'); v_name text := crm.fn_s(b->>'full_name', 120);
BEGIN
  IF v_id IS NOT NULL THEN
    SELECT * INTO t FROM crm.traveller WHERE id = v_id AND org_id = st.org_id AND deleted_at IS NULL;
    IF NOT FOUND THEN PERFORM crm.fn_fail(404, 'not_found', 'That traveller was not found.'); END IF;
    c := crm.fn_customer_guard(st, t.customer_id, true);
    IF COALESCE((b->>'remove')::boolean, false) THEN
      UPDATE crm.traveller SET deleted_at = now(), updated_at = now() WHERE id = t.id;
      PERFORM crm.fn_event(st.org_id, 'traveller.removed', st.id, st.full_name, NULL, c.id, NULL, jsonb_build_object('name', t.full_name), true, 'TRAVELCRM-API-001', p_exec);
      RETURN jsonb_build_object('traveller_id', t.id, 'removed', true);
    END IF;
    IF v_name IS NULL THEN PERFORM crm.fn_fail(400, 'missing_name', 'Enter the name of the traveller.'); END IF;
    UPDATE crm.traveller SET full_name = v_name, relation = crm.fn_s(b->>'relation', 40), date_of_birth = crm.fn_date(b->>'date_of_birth'),
           nationality_code = upper(crm.fn_s(b->>'nationality_code', 2)), meal_preference = crm.fn_s(b->>'meal_preference', 60),
           special_assistance = crm.fn_s(b->>'special_assistance', 500), updated_at = now()
    WHERE id = t.id;
    PERFORM crm.fn_event(st.org_id, 'traveller.updated', st.id, st.full_name, NULL, c.id, NULL, jsonb_build_object('name', v_name), false, 'TRAVELCRM-API-001', p_exec);
    RETURN jsonb_build_object('traveller_id', t.id);
  END IF;
  c := crm.fn_customer_guard(st, crm.fn_uuid(b->>'customer_id'), true);
  IF v_name IS NULL THEN PERFORM crm.fn_fail(400, 'missing_name', 'Enter the name of the traveller.'); END IF;
  INSERT INTO crm.traveller (org_id, customer_id, full_name, relation, date_of_birth, nationality_code, meal_preference, special_assistance)
  VALUES (st.org_id, c.id, v_name, crm.fn_s(b->>'relation', 40), crm.fn_date(b->>'date_of_birth'), upper(crm.fn_s(b->>'nationality_code', 2)),
          crm.fn_s(b->>'meal_preference', 60), crm.fn_s(b->>'special_assistance', 500))
  RETURNING id INTO v_id;
  PERFORM crm.fn_event(st.org_id, 'traveller.added', st.id, st.full_name, NULL, c.id, NULL, jsonb_build_object('name', v_name), false, 'TRAVELCRM-API-001', p_exec);
  RETURN jsonb_build_object('traveller_id', v_id);
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_staff_admin_list(st crm.staff) RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT crm.fn_is_admin(st.role) THEN PERFORM crm.fn_fail(403, 'admin_only', 'Only an admin can manage the team.'); END IF;
  RETURN jsonb_build_object('staff', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.full_name, 'email', s.email, 'role', s.role, 'active', s.active,
      'phone_e164', s.phone_e164, 'specialities', to_jsonb(s.specialities), 'languages', to_jsonb(s.languages), 'max_open_leads', s.max_open_leads, 'last_seen_at', s.last_seen_at,
      'open_leads', (SELECT count(*)::int FROM crm.lead l WHERE l.owner_staff_id = s.id AND l.deleted_at IS NULL AND l.status NOT IN ('won', 'lost', 'dormant', 'duplicate')),
      'open_tasks', (SELECT count(*)::int FROM crm.task t WHERE t.owner_staff_id = s.id AND t.status IN ('open', 'in_progress')),
      'is_me', s.id = st.id) ORDER BY s.active DESC, s.full_name)
    FROM crm.staff s WHERE s.org_id = st.org_id), '[]'::jsonb));
END $fn$;

CREATE OR REPLACE FUNCTION crm.api_staff_update(st crm.staff, b jsonb, p_exec text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE s crm.staff%ROWTYPE; v_fields text[] := '{}'; v_role text; v_arr text[]; v_phone text; v_before jsonb;
BEGIN
  IF NOT crm.fn_is_admin(st.role) THEN PERFORM crm.fn_fail(403, 'admin_only', 'Only an admin can manage the team.'); END IF;
  SELECT * INTO s FROM crm.staff WHERE id = crm.fn_uuid(b->>'id') AND org_id = st.org_id;
  IF NOT FOUND THEN PERFORM crm.fn_fail(404, 'not_found', 'That team member was not found.'); END IF;
  v_before := jsonb_build_object('role', s.role, 'active', s.active);
  IF b ? 'role' THEN
    v_role := crm.fn_s(b->>'role', 30);
    IF v_role IS NULL OR v_role NOT IN ('super_admin', 'company_admin', 'branch_manager', 'sales_manager', 'sales_executive', 'operations', 'accounts', 'marketing', 'supplier_manager', 'read_only') THEN
      PERFORM crm.fn_fail(400, 'bad_role', 'Choose a role from the list.');
    END IF;
    IF v_role <> s.role THEN
      IF s.id = st.id THEN PERFORM crm.fn_fail(400, 'own_role', 'You cannot change your own role.'); END IF;
      IF (v_role = 'super_admin' OR s.role = 'super_admin') AND st.role <> 'super_admin' THEN PERFORM crm.fn_fail(403, 'owner_only', 'Only the owner can give or remove the owner role.'); END IF;
      s.role := v_role; v_fields := array_append(v_fields, 'role');
    END IF;
  END IF;
  IF b ? 'active' THEN
    IF (b->>'active')::boolean IS DISTINCT FROM s.active THEN
      IF s.id = st.id THEN PERFORM crm.fn_fail(400, 'own_access', 'You cannot pause your own access.'); END IF;
      IF s.role = 'super_admin' AND st.role <> 'super_admin' THEN PERFORM crm.fn_fail(403, 'owner_only', 'Only the owner can pause an owner.'); END IF;
      s.active := (b->>'active')::boolean; v_fields := array_append(v_fields, 'access');
    END IF;
  END IF;
  IF b ? 'specialities' THEN
    SELECT COALESCE(array_agg(d), '{}'::text[]) INTO v_arr FROM (
      SELECT lower(crm.fn_s(x, 40)) AS d FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(b->'specialities') = 'array' THEN b->'specialities' ELSE '[]'::jsonb END) x LIMIT 20) q
    WHERE d IS NOT NULL;
    s.specialities := v_arr; v_fields := array_append(v_fields, 'specialities');
  END IF;
  IF b ? 'languages' THEN
    SELECT COALESCE(array_agg(d), '{}'::text[]) INTO v_arr FROM (
      SELECT crm.fn_s(x, 40) AS d FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(b->'languages') = 'array' THEN b->'languages' ELSE '[]'::jsonb END) x LIMIT 20) q
    WHERE d IS NOT NULL;
    s.languages := v_arr; v_fields := array_append(v_fields, 'languages');
  END IF;
  IF b ? 'max_open_leads' THEN s.max_open_leads := crm.fn_int(b->>'max_open_leads', 1, 10000); v_fields := array_append(v_fields, 'lead limit'); END IF;
  IF b ? 'phone' THEN
    v_phone := crm.fn_norm_phone(b->>'phone');
    IF crm.fn_s(b->>'phone', 40) IS NOT NULL AND v_phone IS NULL THEN PERFORM crm.fn_fail(400, 'bad_phone', 'That phone number does not look right.'); END IF;
    s.phone_e164 := v_phone; v_fields := array_append(v_fields, 'phone');
  END IF;
  UPDATE crm.staff SET role = s.role, active = s.active, specialities = s.specialities, languages = s.languages, max_open_leads = s.max_open_leads,
         phone_e164 = s.phone_e164, updated_at = now()
  WHERE id = s.id;
  IF array_length(v_fields, 1) > 0 THEN
    PERFORM crm.fn_event(st.org_id, 'staff.updated', st.id, st.full_name, NULL, NULL, NULL,
      jsonb_build_object('staff_id', s.id, 'name', s.full_name, 'fields', to_jsonb(v_fields), 'before', v_before, 'after', jsonb_build_object('role', s.role, 'active', s.active)),
      true, 'TRAVELCRM-API-001', p_exec);
  END IF;
  RETURN jsonb_build_object('changed', to_jsonb(v_fields));
END $fn$;

CREATE OR REPLACE FUNCTION crm.api(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  ctx jsonb := COALESCE(p->'ctx', '{}'::jsonb); v_action text := crm.fn_s(p->>'action', 40);
  b jsonb := CASE WHEN jsonb_typeof(p->'body') = 'object' THEN p->'body' ELSE '{}'::jsonb END;
  v_exec text := crm.fn_s(p->>'execution_id', 60); v_email text := crm.fn_norm_email(ctx->>'email');
  v_org uuid; st crm.staff%ROWTYPE; res jsonb; v_parts text[]; v_state text; v_msg text; v_where text; l crm.lead%ROWTYPE;
BEGIN
  IF v_email IS NULL THEN RETURN jsonb_build_object('status', 401, 'body', jsonb_build_object('error', 'signed_out', 'message', 'Sign in to NegoTrip HQ first.')); END IF;
  SELECT id INTO v_org FROM crm.org WHERE code = 'NEGOTRIP';
  INSERT INTO crm.staff (org_id, email, full_name, role, hq_member_id, last_seen_at)
  VALUES (v_org, v_email, COALESCE(crm.fn_s(ctx->>'name', 120), v_email),
          CASE ctx->>'hq_role' WHEN 'owner' THEN 'super_admin' WHEN 'manager' THEN 'sales_manager' ELSE 'sales_executive' END,
          crm.fn_s(ctx->>'hq_id', 60), now())
  ON CONFLICT (org_id, lower(email)) DO UPDATE SET last_seen_at = now(), hq_member_id = EXCLUDED.hq_member_id,
    role = CASE WHEN EXCLUDED.role = 'super_admin' THEN 'super_admin' ELSE crm.staff.role END,
    active = CASE WHEN EXCLUDED.role = 'super_admin' THEN true ELSE crm.staff.active END
  RETURNING * INTO st;
  IF NOT st.active THEN
    RETURN jsonb_build_object('status', 403, 'body', jsonb_build_object('error', 'paused', 'message', 'Your CRM access is paused. Ask the owner to turn it back on.'));
  END IF;

  BEGIN
    CASE v_action
      WHEN 'bootstrap' THEN res := crm.api_bootstrap(st);
      WHEN 'leads_list' THEN res := crm.api_leads_list(st, b);
      WHEN 'lead_create' THEN res := crm.api_lead_create(st, b, v_exec);
      WHEN 'lead_get' THEN res := crm.api_lead_get(st, b);
      WHEN 'lead_update' THEN res := crm.api_lead_update(st, b, v_exec);
      WHEN 'lead_set_status' THEN res := crm.api_lead_set_status(st, b, v_exec);
      WHEN 'lead_assign' THEN res := crm.api_lead_assign(st, b, v_exec);
      WHEN 'lead_note_add' THEN res := crm.api_lead_note_add(st, b, v_exec);
      WHEN 'lead_rescore' THEN
        l := crm.fn_lead_guard(st, crm.fn_uuid(b->>'id'), true);
        res := jsonb_build_object('score', crm.fn_lead_score(l.id));
      WHEN 'duplicate_decide' THEN res := crm.api_duplicate_decide(st, b, v_exec);
      WHEN 'tasks_list' THEN res := crm.api_tasks_list(st, b);
      WHEN 'task_create' THEN res := crm.api_task_create(st, b, v_exec);
      WHEN 'task_update' THEN res := crm.api_task_update(st, b, v_exec);
      WHEN 'customers_list' THEN res := crm.api_customers_list(st, b);
      WHEN 'customer_get' THEN res := crm.api_customer_get(st, b);
      WHEN 'customer_update' THEN res := crm.api_customer_update(st, b, v_exec);
      WHEN 'traveller_save' THEN res := crm.api_traveller_save(st, b, v_exec);
      WHEN 'staff_admin_list' THEN res := crm.api_staff_admin_list(st);
      WHEN 'staff_update' THEN res := crm.api_staff_update(st, b, v_exec);
      ELSE RETURN jsonb_build_object('status', 400, 'body', jsonb_build_object('error', 'unknown_action', 'message', 'The CRM does not know that request.'));
    END CASE;
  EXCEPTION
    WHEN SQLSTATE 'CRM01' THEN
      v_parts := string_to_array(SQLERRM, '|');
      RETURN jsonb_build_object('status', COALESCE(crm.fn_int(v_parts[1], 400, 599), 400),
        'body', jsonb_build_object('error', COALESCE(v_parts[2], 'failed'), 'message', COALESCE(array_to_string(v_parts[3:], '|'), 'That did not work.')));
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_where = PG_EXCEPTION_CONTEXT;
      INSERT INTO crm.error_log (org_id, workflow, execution_id, node, error_class, http_status, message, detail)
      VALUES (v_org, 'TRAVELCRM-API-001', v_exec, 'crm.api', 'database', 500, left(v_msg, 1500),
              jsonb_build_object('action', v_action, 'sqlstate', v_state, 'where', left(v_where, 1500), 'staff_id', st.id));
      RETURN jsonb_build_object('status', 500, 'body', jsonb_build_object('error', 'server_error', 'message', 'Something went wrong on our side. It has been logged.'));
  END;
  RETURN jsonb_build_object('status', 200, 'body', jsonb_build_object('ok', true) || COALESCE(res, '{}'::jsonb));
END $fn$;

CREATE OR REPLACE FUNCTION crm.intake(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE res jsonb; v_parts text[]; v_state text; v_msg text; v_where text; v_org uuid; v_err uuid; v_safe jsonb;
BEGIN
  BEGIN
    res := crm.fn_lead_intake(COALESCE(p, '{}'::jsonb) || jsonb_build_object('strict', false));
  EXCEPTION
    WHEN SQLSTATE 'CRM01' THEN
      v_parts := string_to_array(SQLERRM, '|');
      RETURN jsonb_build_object('status', COALESCE(crm.fn_int(v_parts[1], 400, 599), 400),
        'body', jsonb_build_object('error', COALESCE(v_parts[2], 'failed'), 'message', COALESCE(array_to_string(v_parts[3:], '|'), 'That did not work.')));
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_where = PG_EXCEPTION_CONTEXT;
      SELECT id INTO v_org FROM crm.org WHERE code = 'NEGOTRIP';
      v_safe := COALESCE(p, '{}'::jsonb);
      INSERT INTO crm.error_log (org_id, workflow, execution_id, node, error_class, http_status, message, detail)
      VALUES (v_org, COALESCE(crm.fn_s(v_safe->>'workflow', 80), 'TRAVELCRM-WF-001'), crm.fn_s(v_safe->>'execution_id', 60), 'crm.intake', 'database', 500, left(v_msg, 1500),
              jsonb_build_object('sqlstate', v_state, 'where', left(v_where, 1500), 'source', v_safe->>'source'))
      RETURNING id INTO v_err;
      INSERT INTO crm.error_queue (org_id, source_workflow, event_type, payload, error_log_id, next_attempt_at)
      VALUES (v_org, COALESCE(crm.fn_s(v_safe->>'workflow', 80), 'TRAVELCRM-WF-001'), 'lead.intake', v_safe, v_err, now() + interval '10 minutes');
      RETURN jsonb_build_object('status', 202, 'body', jsonb_build_object('ok', true, 'queued', true, 'message', 'The lead was received and is waiting to be processed.'));
  END;
  RETURN jsonb_build_object('status', 200, 'body', jsonb_build_object('ok', true) || res);
END $fn$;

INSERT INTO crm.schema_migration (filename, note) VALUES ('002_lead_engine.sql', 'Phase 2 lead engine: duplicates, scoring, assignment, tasks, customers and the crm.api dispatcher') ON CONFLICT (filename) DO NOTHING
;
