-- Ensure Zia chat tables emit complete Postgres Changes events.

DO $migration$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'core_messages',
    'core_reactions',
    'core_attachments',
    'core_message_pins'
  ]
  LOOP
    IF to_regclass('public.' || table_name) IS NULL THEN
      CONTINUE;
    END IF;

    EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY FULL', table_name);

    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = table_name
    ) THEN
      EXECUTE format(
        'ALTER PUBLICATION supabase_realtime ADD TABLE public.%I',
        table_name
      );
    END IF;
  END LOOP;
END
$migration$;

DO $verification$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'core_messages'
  ) THEN
    RAISE EXCEPTION 'core_messages no esta publicada en supabase_realtime';
  END IF;
END
$verification$;
