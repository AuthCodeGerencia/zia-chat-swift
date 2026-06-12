-- Zia Chat: core_create_channel v2.
-- Paridad con la web (azank-react /api/core/channels): soporta tipo de canal
-- (texto/voz), metadata (icono, tema, unidad de negocio) y devuelve metadata.
-- Los canales de voz NO crean conversación (igual que la web).

DROP FUNCTION IF EXISTS public.core_create_channel(text, text, text);

CREATE OR REPLACE FUNCTION public.core_create_channel(
  p_name text,
  p_description text DEFAULT NULL,
  p_visibility text DEFAULT 'public',
  p_channel_type text DEFAULT 'text',
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  id uuid,
  empresa_id integer,
  name text,
  slug text,
  description text,
  visibility text,
  metadata jsonb,
  conversation_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_profile record;
  new_channel record;
  new_conversation record;
  clean_name text;
  clean_slug text;
  clean_visibility text;
  clean_type text;
  clean_metadata jsonb;
BEGIN
  SELECT p.id, p.empresa_id, p.client_id
  INTO current_profile
  FROM public.profiles p
  WHERE p.id = auth.uid()
  LIMIT 1;

  IF current_profile.id IS NULL OR current_profile.empresa_id IS NULL THEN
    RAISE EXCEPTION 'No hay perfil interno asociado a esta sesion';
  END IF;

  clean_name := trim(coalesce(p_name, ''));
  clean_slug := public.core_slugify(clean_name);
  clean_visibility := coalesce(nullif(p_visibility, ''), 'public');
  clean_type := CASE WHEN p_channel_type = 'voice' THEN 'voice' ELSE 'text' END;
  clean_metadata := CASE
    WHEN p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object' THEN '{}'::jsonb
    ELSE p_metadata
  END;
  clean_metadata := jsonb_strip_nulls(clean_metadata) || jsonb_build_object('channelType', clean_type);

  IF clean_name = '' OR clean_slug = '' THEN
    RAISE EXCEPTION 'El nombre del canal es obligatorio';
  END IF;

  IF clean_visibility NOT IN ('public', 'private') THEN
    clean_visibility := 'public';
  END IF;

  INSERT INTO public.core_channels (
    empresa_id,
    name,
    slug,
    description,
    visibility,
    metadata,
    created_by
  )
  VALUES (
    current_profile.empresa_id,
    clean_name,
    clean_slug,
    nullif(trim(coalesce(p_description, '')), ''),
    clean_visibility,
    clean_metadata,
    current_profile.id
  )
  RETURNING * INTO new_channel;

  INSERT INTO public.core_channel_members (channel_id, user_id, role)
  VALUES (new_channel.id, current_profile.id, 'admin')
  ON CONFLICT (channel_id, user_id) DO UPDATE SET role = EXCLUDED.role;

  IF clean_type <> 'voice' THEN
    INSERT INTO public.core_conversations (
      empresa_id,
      type,
      channel_id,
      created_by
    )
    VALUES (
      current_profile.empresa_id,
      'channel',
      new_channel.id,
      current_profile.id
    )
    RETURNING * INTO new_conversation;

    INSERT INTO public.core_conversation_members (conversation_id, user_id, role)
    VALUES (new_conversation.id, current_profile.id, 'admin')
    ON CONFLICT (conversation_id, user_id) DO UPDATE SET role = EXCLUDED.role;
  END IF;

  RETURN QUERY
  SELECT
    new_channel.id,
    new_channel.empresa_id,
    new_channel.name,
    new_channel.slug,
    new_channel.description,
    new_channel.visibility,
    new_channel.metadata,
    new_conversation.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.core_create_channel(text, text, text, text, jsonb) TO authenticated;
