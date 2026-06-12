import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

type PushRequest = {
  messageId?: string;
};

type MessageRow = {
  id: string;
  user_id: string;
  channel_id: string | null;
  conversation_id: string;
  parent_message_id: string | null;
  content: string | null;
};

const invalidTokenReasons = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

function requiredSecret(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function notificationChannel(name: string | null | undefined) {
  const trimmed = name?.trim() || "";
  const characters = Array.from(trimmed);
  const first = characters[0] || "";
  const hasEmoji = Boolean(first && !/[#@a-zA-Z0-9]/.test(first));
  return {
    emoji: hasEmoji ? first : "💬",
    name: (hasEmoji ? characters.slice(1).join("") : trimmed.replace(/^#/, "")).trim() || "canal",
  };
}

async function providerToken() {
  const privateKey = requiredSecret("APNS_PRIVATE_KEY").replace(/\\n/g, "\n");
  const key = await importPKCS8(privateKey, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: requiredSecret("APNS_KEY_ID") })
    .setIssuer(requiredSecret("APNS_TEAM_ID"))
    .setIssuedAt()
    .setExpirationTime("50m")
    .sign(key);
}

async function sendPush(input: {
  token: string;
  authorization: string;
  title: string;
  body: string;
  badge: number;
  message: MessageRow;
}) {
  const production = Deno.env.get("APNS_PRODUCTION") !== "false";
  const origin = production
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  const response = await fetch(`${origin}/3/device/${input.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${input.authorization}`,
      "apns-topic": Deno.env.get("APNS_BUNDLE_ID")?.trim() || "authcode.ZiaChat",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: { title: input.title, body: input.body },
        sound: "default",
        badge: input.badge,
        "thread-id": input.message.channel_id || input.message.conversation_id,
      },
      kind: input.message.parent_message_id ? "thread_message" : "channel_message",
      messageId: input.message.id,
      parentMessageId: input.message.parent_message_id,
      conversationId: input.message.conversation_id,
      channelId: input.message.channel_id,
    }),
  });

  if (response.ok) return { invalid: false };
  const payload = await response.json().catch(() => ({}));
  console.error("[zia-chat-apns] APNs rejected token", response.status, payload);
  return { invalid: invalidTokenReasons.has(payload?.reason) };
}

async function unreadBadgeCount(supabase: ReturnType<typeof createClient>, userId: string) {
  const [{ data: channelMemberships, error: channelError }, { data: conversationMemberships, error: conversationError }] =
    await Promise.all([
      supabase.from("core_channel_members").select("channel_id").eq("user_id", userId),
      supabase.from("core_conversation_members").select("conversation_id").eq("user_id", userId),
    ]);
  if (channelError) throw channelError;
  if (conversationError) throw conversationError;

  const channelIds = [...new Set((channelMemberships || []).map((row) => row.channel_id))];
  const { data: channelConversations, error: channelConversationError } = channelIds.length
    ? await supabase.from("core_conversations").select("id").in("channel_id", channelIds)
    : { data: [], error: null };
  if (channelConversationError) throw channelConversationError;

  const conversationIds = [...new Set([
    ...(conversationMemberships || []).map((row) => row.conversation_id),
    ...(channelConversations || []).map((row) => row.id),
  ])];
  if (conversationIds.length === 0) return 0;

  const { data: reads, error: readsError } = await supabase
    .from("core_message_reads")
    .select("conversation_id,last_read_at")
    .eq("user_id", userId)
    .in("conversation_id", conversationIds);
  if (readsError) throw readsError;

  const readAtByConversation = new Map(
    (reads || []).map((row) => [row.conversation_id, row.last_read_at]),
  );
  const counts = await Promise.all(conversationIds.map(async (conversationId) => {
    let query = supabase
      .from("core_messages")
      .select("id", { count: "exact", head: true })
      .eq("conversation_id", conversationId)
      .neq("user_id", userId)
      .is("parent_message_id", null)
      .is("deleted_at", null);
    const lastReadAt = readAtByConversation.get(conversationId);
    if (lastReadAt) query = query.gt("created_at", lastReadAt);
    const { count, error } = await query;
    if (error) throw error;
    return count || 0;
  }));

  return counts.reduce((total, count) => total + count, 0);
}

Deno.serve(async (request) => {
  try {
    const expectedSecret = requiredSecret("ZIA_CHAT_PUSH_WEBHOOK_SECRET");
    if (request.headers.get("x-zia-chat-secret") !== expectedSecret) {
      return new Response("Unauthorized", { status: 401 });
    }

    const { messageId } = await request.json() as PushRequest;
    if (!messageId) return new Response("Missing messageId", { status: 400 });

    const supabase = createClient(
      requiredSecret("SUPABASE_URL"),
      requiredSecret("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );
    const { data: message, error: messageError } = await supabase
      .from("core_messages")
      .select("id,user_id,channel_id,conversation_id,parent_message_id,content")
      .eq("id", messageId)
      .is("deleted_at", null)
      .maybeSingle<MessageRow>();
    if (messageError) throw messageError;
    if (!message) return new Response("Message not found", { status: 404 });

    const membershipTable = message.channel_id
      ? "core_channel_members"
      : "core_conversation_members";
    const membershipColumn = message.channel_id ? "channel_id" : "conversation_id";
    const membershipValue = message.channel_id || message.conversation_id;
    const { data: memberships, error: membershipError } = await supabase
      .from(membershipTable)
      .select("user_id")
      .eq(membershipColumn, membershipValue)
      .neq("user_id", message.user_id);
    if (membershipError) throw membershipError;

    const recipientIds = [...new Set((memberships || []).map((row) => row.user_id))];
    if (recipientIds.length === 0) return Response.json({ sent: 0 });

    const [{ data: tokens, error: tokenError }, { data: sender }, { data: channel }] = await Promise.all([
      supabase
        .from("core_push_tokens")
        .select("token,user_id")
        .eq("platform", "zia_chat_apns")
        .in("user_id", recipientIds),
      supabase.from("profiles").select("full_name").eq("id", message.user_id).maybeSingle(),
      message.channel_id
        ? supabase.from("core_channels").select("name").eq("id", message.channel_id).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);
    if (tokenError) throw tokenError;
    if (!tokens?.length) return Response.json({ sent: 0 });

    const author = sender?.full_name?.trim() || "Alguien";
    const preview = message.content?.trim().slice(0, 120) || "Nuevo mensaje";
    const channelLabel = notificationChannel(channel?.name);
    const title = message.channel_id
      ? `${channelLabel.emoji} #${channelLabel.name}`
      : author;
    const authorization = await providerToken();
    const badgeByUser = new Map<string, number>();
    const results = await Promise.all(tokens.map(async ({ token, user_id }) => {
      let badge = badgeByUser.get(user_id);
      if (badge == null) {
        badge = await unreadBadgeCount(supabase, user_id);
        badgeByUser.set(user_id, badge);
      }
      return {
        token,
        ...(await sendPush({
          token,
          authorization,
          title,
          body: `${author}: ${preview}`,
          badge,
          message,
        })),
      };
    }));
    const invalidTokens = results.filter((result) => result.invalid).map((result) => result.token);
    if (invalidTokens.length > 0) {
      await supabase.from("core_push_tokens").delete().in("token", invalidTokens);
    }

    return Response.json({ sent: results.length - invalidTokens.length });
  } catch (error) {
    console.error("[zia-chat-apns]", error);
    const message = error instanceof Error
      ? error.message
      : typeof error === "object" && error && "message" in error
        ? String(error.message)
        : String(error);
    return Response.json({ error: message }, { status: 500 });
  }
});
