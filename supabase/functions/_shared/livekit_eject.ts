// Disconnect a viewer from a show they no longer hold a ticket to.
//
// The ticket gate runs exactly once, when the viewer's LiveKit token is minted,
// so revoking access mid-show (refund, chargeback) took the money back and left
// them watching to the end. Their identity carries a per-connection suffix and
// they may be on more than one device, so match on the userId in the
// participant metadata rather than trying to reconstruct an identity string.
//
// Best-effort throughout. By the time this runs the money has already moved;
// failing the caller over a room that is not up would report a broken refund
// that was not broken. Missing LiveKit credentials degrade to "no eject".
//
// Shared by refund-ticket (host-initiated refund) and stripe-webhook
// (charge.dispute.created).

import { RoomServiceClient } from "https://esm.sh/livekit-server-sdk@2.9.7?target=deno";

const LIVEKIT_URL = Deno.env.get("LIVEKIT_URL") ?? "";

const roomService = LIVEKIT_URL
  ? new RoomServiceClient(
    LIVEKIT_URL.replace(/^wss:/, "https:").replace(/^ws:/, "http:"),
    Deno.env.get("LIVEKIT_API_KEY")!,
    Deno.env.get("LIVEKIT_API_SECRET")!,
  )
  : null;

export async function ejectFromLiveRoom(
  livekitRoom: string | null,
  userId: string | null,
  caller = "eject",
) {
  if (!roomService || !livekitRoom || !userId) return;
  try {
    const roomName = `nile-event-${livekitRoom}`;
    const participants = await roomService.listParticipants(roomName);
    await Promise.all(
      participants
        .filter((p) => {
          try {
            return JSON.parse(p.metadata || "{}").userId === userId;
          } catch {
            return false;
          }
        })
        .map((p) => roomService!.removeParticipant(roomName, p.identity)),
    );
  } catch (err) {
    console.error(`${caller}: could not eject viewer`, String(err));
  }
}
