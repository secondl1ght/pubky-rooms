# QA helper: writes a room straight to the testnet homeserver from a fresh
# headless identity, so the running dev server has never seen it (the
# Directory learns rooms from its own users' sign-ins, creations and events).
# Prints the room URL. The first visit shows the page loader; with many
# messages it is also the paging fixture (`docs/qa/checklist.md`).
#
#   cd pubky_rooms && mix run --no-start scripts/headless_room.exs        # 2 messages
#   cd pubky_rooms && mix run --no-start scripts/headless_room.exs 150    # 150 messages
#
# Needs pubky-docker up. Not part of the app; nothing here runs in production.
alias Pubky.Auth.{Capability, LocalSigner}
alias Pubky.{Config, Keypair, Storage}
alias PubkyRooms.Rooms.{Membership, Message, Paths, Room}

{:ok, _} = Application.ensure_all_started(:pubky)
PubkyRooms.Ids.init()

config = Config.get()
hs = Config.testnet_homeserver()
kp = Keypair.generate()
:ok = LocalSigner.signup(kp, hs, [], config)
{:ok, cap} = Capability.read_write("/pub/pubky-rooms/")
{:ok, session} = LocalSigner.signin(kp, hs, [caps: [cap]], config)
me = Keypair.public_z32(kp)

{:ok, room} = Room.new(me, %{"name" => "Never seen here", "topic" => "Written straight to the homeserver by a headless identity", "visibility" => "unlisted"})
ref = Room.ref(room)
put = fn path, body -> :ok = Storage.put(session, path, body, content_type: "application/json") end
put.(Paths.room(room.id), Room.encode(room))
put.(Paths.member(ref), Membership.encode(ref))

count = System.argv() |> List.first() |> then(&if(&1, do: String.to_integer(&1), else: 2))

texts =
  case count do
    2 -> ["Hello from a room this node has never indexed.", "The page loader should have shown before this appeared."]
    n -> Enum.map(1..n, &"Message #{&1} of #{n}, written headlessly for the paging check.")
  end

for text <- texts do
  {:ok, msg} = Message.new(me, ref, text)
  put.(Paths.message(ref, msg.msg_id), Message.encode(msg))
end

IO.puts("http://localhost:4000/r/#{me}/#{room.id}")
