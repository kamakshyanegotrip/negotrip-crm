-- NegoTrip CRM · migration 003 · intake for connected lead sources
-- 1. History lines written in one transaction keep their real order (clock time, not transaction time).
-- 2. crm.intake learns three things: reuse an open lead when the same person writes again, respect an AI
--    screening verdict (supplier mail is recorded but never becomes a lead), and a dry run that saves nothing.
-- Safe to run again. A dollar sign is never written directly before a quote in this file.

CREATE OR REPLACE FUNCTION crm.fn_event(
  p_org uuid, p_type text, p_staff uuid, p_label text, p_lead uuid, p_customer uuid, p_task uuid,
  p_detail jsonb, p_audit boolean, p_workflow text, p_exec text
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v_id uuid;
BEGIN
  INSERT INTO crm.event (org_id, occurred_at, event_type, is_audit, actor_staff_id, actor_label, lead_id, customer_id, task_id, workflow, execution_id, detail)
  VALUES (p_org, clock_timestamp(), p_type, COALESCE(p_audit, false), p_staff, p_label, p_lead, p_customer, p_task, p_workflow, p_exec, COALESCE(p_detail, '{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END $fn$;

CREATE OR REPLACE FUNCTION crm.fn_intake_core(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_org uuid; v_days int := COALESCE(crm.fn_int(p->>'reuse_open_days', 0, 365), 0);
  v_src text := COALESCE(crm.fn_s(p->>'source', 40), 'external_api'); v_ref text := crm.fn_s(p->>'source_ref', 200);
  v_verdict text := lower(COALESCE(crm.fn_s(p->'screen'->>'verdict', 20), ''));
  v_wf text := COALESCE(crm.fn_s(p->>'workflow', 80), 'TRAVELCRM'); v_exec text := crm.fn_s(p->>'execution_id', 60);
  v_label text := COALESCE(crm.fn_s(p->>'actor_label', 160), 'System');
  v_msg text := crm.fn_s(p->>'message', 4000); v_src_name text;
  v_phone text; v_wa text; v_email text; l crm.lead%ROWTYPE; v_new boolean := false;
BEGIN
  v_org := COALESCE(crm.fn_uuid(p->>'org_id'), (SELECT id FROM crm.org WHERE code = COALESCE(crm.fn_s(p->>'org_code', 40), 'NEGOTRIP')));
  IF v_org IS NULL THEN PERFORM crm.fn_fail(400, 'bad_org', 'Unknown organisation.'); END IF;
  SELECT name INTO v_src_name FROM crm.lead_source WHERE org_id = v_org AND code = v_src;

  -- the same message or form entry sent twice never makes anything twice
  IF v_ref IS NOT NULL THEN
    SELECT x.* INTO l FROM crm.lead x JOIN crm.lead_source s ON s.id = x.source_id
    WHERE x.org_id = v_org AND s.code = v_src AND x.source_ref = v_ref;
    IF FOUND THEN
      RETURN jsonb_build_object('created', false, 'lead', jsonb_build_object('id', l.id, 'lead_no', l.lead_no, 'score', l.score,
        'temperature', l.temperature, 'owner_staff_id', l.owner_staff_id), 'customer_id', l.customer_id,
        'duplicates', jsonb_build_object('exact', 0, 'probable', 0));
    END IF;
  END IF;

  -- screened out by the AI check: keep a trace, make no lead
  IF v_verdict = 'not_enquiry' THEN
    IF v_ref IS NULL OR NOT EXISTS (SELECT 1 FROM crm.event e WHERE e.org_id = v_org AND e.event_type = 'intake.screened_out'
                                     AND e.detail->>'source' = v_src AND e.detail->>'source_ref' = v_ref) THEN
      PERFORM crm.fn_event(v_org, 'intake.screened_out', NULL, 'AI assistant', NULL, NULL, NULL,
        jsonb_build_object('source', v_src, 'source_name', v_src_name, 'source_ref', v_ref, 'kind', left(p->'screen'->>'kind', 40),
                           'reason', left(p->'screen'->>'reason', 300), 'model', left(p->'screen'->>'model', 80)), false, v_wf, v_exec);
    END IF;
    RETURN jsonb_build_object('created', false, 'screened_out', true);
  END IF;

  -- the same person writing again while their lead is still open: add to that lead instead of making another
  IF v_days > 0 THEN
    v_phone := crm.fn_norm_phone(p->>'phone');
    v_wa := COALESCE(crm.fn_norm_phone(p->>'whatsapp'), v_phone);
    v_email := crm.fn_norm_email(p->>'email');
    IF v_phone IS NOT NULL OR v_wa IS NOT NULL OR v_email IS NOT NULL THEN
      SELECT o.* INTO l FROM crm.lead o
      WHERE o.org_id = v_org AND o.deleted_at IS NULL AND o.status NOT IN ('won', 'lost', 'dormant', 'duplicate')
        AND COALESCE(o.last_activity_at, o.created_at) > now() - make_interval(days => v_days)
        AND ((v_phone IS NOT NULL AND (o.phone_e164 = v_phone OR o.whatsapp_e164 = v_phone))
          OR (v_wa IS NOT NULL AND (o.phone_e164 = v_wa OR o.whatsapp_e164 = v_wa))
          OR (v_email IS NOT NULL AND lower(o.email) = v_email))
      ORDER BY o.created_at DESC LIMIT 1;
      IF FOUND THEN
        IF v_ref IS NULL OR NOT EXISTS (SELECT 1 FROM crm.event e WHERE e.lead_id = l.id AND e.event_type = 'lead.contacted_again'
                                         AND e.detail->>'source' = v_src AND e.detail->>'source_ref' = v_ref) THEN
          v_new := true;
          UPDATE crm.lead SET last_activity_at = now(), updated_at = now() WHERE id = l.id;
          PERFORM crm.fn_event(v_org, 'lead.contacted_again', NULL, v_label, l.id, l.customer_id, NULL,
            jsonb_build_object('source', v_src, 'source_name', v_src_name, 'source_ref', v_ref, 'preview', left(v_msg, 300)), false, v_wf, v_exec);
          INSERT INTO crm.task (org_id, type, title, body, lead_id, customer_id, owner_staff_id, priority, due_at, sla_minutes, dedupe_key)
          SELECT v_org, 'follow_up', 'They wrote again: ' || COALESCE(l.full_name, l.phone_e164, l.email, l.lead_no), left(v_msg, 300),
                 l.id, l.customer_id, l.owner_staff_id, 'high', now() + interval '60 minutes', 60,
                 'again:' || l.id || ':' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYYMMDD')
          WHERE NOT EXISTS (SELECT 1 FROM crm.task t WHERE t.lead_id = l.id AND t.status IN ('open', 'in_progress'))
          ON CONFLICT DO NOTHING;
        END IF;
        RETURN jsonb_build_object('created', false, 'reused', true, 'noted', v_new,
          'lead', jsonb_build_object('id', l.id, 'lead_no', l.lead_no, 'score', l.score, 'temperature', l.temperature, 'owner_staff_id', l.owner_staff_id),
          'customer_id', l.customer_id, 'duplicates', jsonb_build_object('exact', 0, 'probable', 0));
      END IF;
    END IF;
  END IF;

  RETURN crm.fn_lead_intake(p || jsonb_build_object('strict', false));
END $fn$;

CREATE OR REPLACE FUNCTION crm.intake(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_p jsonb := CASE WHEN jsonb_typeof(p) = 'object' THEN p ELSE '{}'::jsonb END;
  v_dry boolean := COALESCE(v_p->>'dry_run', '') = 'true';
  res jsonb; v_parts text[]; v_state text; v_msg text; v_where text; v_org uuid; v_err uuid; v_wf text;
BEGIN
  BEGIN
    res := crm.fn_intake_core(v_p);
    IF v_dry THEN RAISE EXCEPTION USING ERRCODE = 'CRM02', MESSAGE = res::text; END IF;
  EXCEPTION
    WHEN SQLSTATE 'CRM02' THEN
      -- a dry run: everything above has been rolled back; report what would have happened
      RETURN jsonb_build_object('status', 200, 'body', jsonb_build_object('ok', true, 'dry_run', true) || SQLERRM::jsonb);
    WHEN SQLSTATE 'CRM01' THEN
      v_parts := string_to_array(SQLERRM, '|');
      RETURN jsonb_build_object('status', COALESCE(crm.fn_int(v_parts[1], 400, 599), 400),
        'body', jsonb_build_object('error', COALESCE(v_parts[2], 'failed'), 'message', COALESCE(array_to_string(v_parts[3:], '|'), 'That did not work.')));
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_where = PG_EXCEPTION_CONTEXT;
      IF v_dry THEN
        RETURN jsonb_build_object('status', 500, 'body', jsonb_build_object('error', 'server_error', 'dry_run', true, 'message', left(v_msg, 500)));
      END IF;
      SELECT id INTO v_org FROM crm.org WHERE code = 'NEGOTRIP';
      v_wf := COALESCE(crm.fn_s(v_p->>'workflow', 80), 'TRAVELCRM-WF-001');
      INSERT INTO crm.error_log (org_id, workflow, execution_id, node, error_class, http_status, message, detail)
      VALUES (v_org, v_wf, crm.fn_s(v_p->>'execution_id', 60), 'crm.intake', 'database', 500, left(v_msg, 1500),
              jsonb_build_object('sqlstate', v_state, 'where', left(v_where, 1500), 'source', v_p->>'source'))
      RETURNING id INTO v_err;
      INSERT INTO crm.error_queue (org_id, source_workflow, event_type, payload, error_log_id, next_attempt_at)
      VALUES (v_org, v_wf, 'lead.intake', v_p, v_err, now() + interval '10 minutes');
      RETURN jsonb_build_object('status', 202, 'body', jsonb_build_object('ok', true, 'queued', true, 'message', 'The lead was received and is waiting to be processed.'));
  END;
  RETURN jsonb_build_object('status', 200, 'body', jsonb_build_object('ok', true) || res);
END $fn$;

INSERT INTO crm.schema_migration (filename, note) VALUES ('003_intake_reuse.sql', 'Intake for connected lead sources: reuse of open leads, AI screening verdict, dry run; ordered history') ON CONFLICT (filename) DO NOTHING;
