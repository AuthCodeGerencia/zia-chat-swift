-- Shared pinned messages for Zia channel and direct-message conversations.

CREATE TABLE IF NOT EXISTS public.core_message_pins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id integer NOT NULL REFERENCES public.internal_companies(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.core_conversations(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.core_messages(id) ON DELETE CASCADE,
  pinned_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, message_id)
);

CREATE INDEX IF NOT EXISTS core_message_pins_conversation_created_idx
  ON public.core_message_pins (conversation_id, created_at DESC);

ALTER TABLE public.core_message_pins ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.core_can_pin_in_conversation(
  p_conversation_id uuid,
  p_empresa_id integer
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.core_conversations c
    LEFT JOIN public.core_channels ch ON ch.id = c.channel_id
    WHERE c.id = p_conversation_id
      AND c.empresa_id = p_empresa_id
      AND p_empresa_id = public.core_user_company_id()
      AND (
        public.core_has_permission('core_admin')
        OR ch.visibility = 'public'
        OR ch.created_by = auth.uid()
        OR EXISTS (
          SELECT 1
          FROM public.core_channel_members cm
          WHERE cm.channel_id = c.channel_id
            AND cm.user_id = auth.uid()
        )
        OR EXISTS (
          SELECT 1
          FROM public.core_conversation_members m
          WHERE m.conversation_id = c.id
            AND m.user_id = auth.uid()
        )
      )
  )
$$;

DROP POLICY IF EXISTS core_message_pins_select ON public.core_message_pins;
CREATE POLICY core_message_pins_select
ON public.core_message_pins
FOR SELECT
TO authenticated
USING (
  public.core_can_pin_in_conversation(conversation_id, empresa_id)
);

DROP POLICY IF EXISTS core_message_pins_insert ON public.core_message_pins;
CREATE POLICY core_message_pins_insert
ON public.core_message_pins
FOR INSERT
TO authenticated
WITH CHECK (
  pinned_by = auth.uid()
  AND public.core_can_pin_in_conversation(conversation_id, empresa_id)
  AND EXISTS (
    SELECT 1
    FROM public.core_messages msg
    WHERE msg.id = core_message_pins.message_id
      AND msg.conversation_id = core_message_pins.conversation_id
      AND msg.empresa_id = core_message_pins.empresa_id
      AND msg.deleted_at IS NULL
  )
);

DROP POLICY IF EXISTS core_message_pins_delete ON public.core_message_pins;
CREATE POLICY core_message_pins_delete
ON public.core_message_pins
FOR DELETE
TO authenticated
USING (
  public.core_can_pin_in_conversation(conversation_id, empresa_id)
);

GRANT SELECT, INSERT, DELETE ON public.core_message_pins TO authenticated;
GRANT EXECUTE ON FUNCTION public.core_can_pin_in_conversation(uuid, integer) TO authenticated;
