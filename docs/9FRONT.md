# Working with 9front

InferNode reaches 9front machines the way 9front's own `rcpu` and `rimport`
do: 9front's authentication (dp9ik), then TLS keyed by its session secret,
then a script the cpu server's `rc` runs. Nothing changes on the 9front side.
A 9front cpu server that answers its own `rcpu` answers InferNode's.

| Command | What it does |
|---------|--------------|
| `rimport host tree mountpoint` | 9front's `exportfs` serves `tree` over the connection; it is mounted at `mountpoint` |
| `rcpu -h host -c cmd ...` | `cmd` runs on the 9front machine as you, with your input and output |
| `rcpu -h host` | an interactive `rc` there (`service=cpu`) |

This is **compatibility mode**. It is off until you give factotum a dp9ik
key, and it is refused in CNSA mode (see
[compliance/CNSA-2.0.md §3.8](compliance/CNSA-2.0.md)). dp9ik and its TLS are
classical cryptography (Ed448, ChaCha20-Poly1305, SHA-256). They are good
against today's attackers, but they have nothing post-quantum and they are not
CNSA 2.0.

## Setting it up

You need an account in the 9front machine's authentication domain, and the
domain's auth server must be reachable on port 567 (the ticket service).

```sh
auth/factotum        # if it is not already running
echo 'key proto=dp9ik dom=9front user=glenda !password=yourpassword auth=tcp!authhost!567' > /mnt/factotum/ctl
```

`auth=` names the auth server. Without it, factotum asks ndb for the domain
(`authdom=9front auth=authhost` in `/lib/ndb/local`). To keep the key, save it
to secstore as you would any other.

Then:

```sh
rimport cirno / /n/cirno
ls /n/cirno/usr/glenda
rcpu -h cirno -c 'cat /dev/sysname; ps | wc -l'
echo hello | rcpu -h cirno -c 'tr a-z A-Z'
```

A host is a name or an address. The network defaults to `tcp` and the port to
17019 (rcpu).

## What the 9front machine sees of yours

9front's `rcpu` serves the whole of the client's name space to the server at
`/mnt/term`. InferNode's serves a tree of its own and **nothing else of this
machine**:

```
/mnt/term/fd/10 fd/11 fd/12   your input, output, error
/mnt/term/dev/cons            input and output
/mnt/term/mnt/cpunote/data    notes (none are sent)
/mnt/term/env/rstatus         where the remote leaves its exit status
```

`rimport` serves nothing at all; it only mounts.

## What is not here (yet)

- **A drawterm.** A 9front graphical program has no `/dev/draw` of this
  machine's to draw on. InferNode's draw device speaks 9front's draw protocol,
  its `w` message (affine warp, which 9front's `page` and image tools send)
  included, checked against 9front 11952's own answers
  (`tests/drawwarp_test.b`); serving it through rcpu with the mouse, keyboard
  and snarf files is the next step.
- **Interrupts.** No note is sent to the far end, so `DEL` does not reach the
  remote command.
- **`-p` (aan).** No session survives a dropped connection.
- **9front's other services.** `import` and `cpu` on port 17007 and Tauth on
  plain 9P speak p9sk1 or p9any over a 9P connection; only rcpu's form is
  here. 9front's own tools moved to rcpu, and so has this.
- **Being a 9front server.** InferNode is only the client. factotum's p9any and
  dp9ik are `role=client` alone.

## When it does not work

| Message | Meaning |
|---------|---------|
| `the auth server's ticket for us: ticket does not decrypt (wrong password?)` | The password is not the one the auth server has for that user. dp9ik never says so outright: the PAK gives each side a different key. |
| `no auth server found for 9front` | Give the key `auth=` or put an ndb entry in place. |
| `remote: ...` | The auth server's own refusal, passed on. |
| `p9any: the server offers p9sk1 alone ...` | That server has no dp9ik (an old Plan 9, not 9front). p9sk1 needs DES, which InferNode no longer has. |
| `dp9ik is not available in CNSA mode` | `/env/cnsamode` is set. |

If **9front's own** `rcpu` fails with `bad key` against the same server, the
problem is on the server. A 9front auth server whose `/adm/keys` was created
empty reads it in the old DES form, where no account has an AES key; it then
answers dp9ik with tickets under a random key (`pak-fail no AES key` in
`/sys/log/auth`). Run `auth/convkeys -a /adm/keys`, restart keyfs (reboot),
and set the user's password again with `auth/changeuser`.

## How it is built and tested

- `appl/lib/dp9ik.b` is 9front's `authpak.c`, `passtokey.c` and `form1.c` in
  Limbo on IPint (Ed448, Elligator 2, decaf, SPAKE2-EE, HKDF). It was written
  from 9front's source and checked against answers 9front 11952 itself gave
  (`tests/host/dp9ik/9front-vectors.txt`, made by `vecgen.c` on 9front). A
  Python version made from the same source (`tests/host/dp9ik/ref.py`) gives
  the same answers.
- `appl/cmd/auth/factotum/proto/p9any.b` is the client side of factotum's
  p9any and dp9ik. The password stays in factotum.
- `appl/lib/tlspsk.b` is a TLS 1.2 PSK client with one suite, kept apart from
  `tls(2)`.
- `tests/dp9ik_test.b` checks the library against 9front's answers and
  against what a peer can send that is not right.
- `tests/dp9ik_proto_test.b` puts factotum against a scripted 9front cpu
  server and auth server: the session secret agrees, plus each refusal.
- `tests/host/dp9ik_live_test.sh` runs everything against 9front itself
  under QEMU (opt-in: `NINEFRONT=1`). It fetches the release by SHA-256 and
  provisions it as a cpu and auth server (`tests/host/dp9ik/nine.py`).

A login costs about a tenth of a second of curve arithmetic, under the JIT or
the interpreter alike, since the arithmetic is IPint's C. `rimport` mounts in
under a second against a local 9front.
