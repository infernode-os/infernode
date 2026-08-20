# Wallet, Payments, and Key Management

This document covers InferNode's cryptocurrency wallet system, the x402 payment protocol integration, the secstore-based key persistence architecture, and the login screen.

## Status and Security Model

The wallet is a supported InferNode component. Its signing pipeline is
cross-validated byte-for-byte against go-ethereum (the EIP-155
specification test vector), its EIP-712/EIP-3009 encoding is validated
against the published type-hash constants, key generation uses the host
OS CSPRNG with fail-closed entropy checks, and every payment path is
policy-enforced server-side (budgets, approval queue, strict integer
amount parsing, network pinning). The threat model and the enforcement
points are described throughout this document; the test suite asserts
each of them.

**Operational guidance:**

- Every wallet account starts with `requireapproval on`: agent-initiated
  payments and x402 authorizations wait in a queue until a human approves
  them in the wallet GUI (**Pending Payments**). Leave this on for any
  account an agent can reach.
- Set a budget (`budget <maxpertx> <maxpersess> <currency>`) on any
  account holding real funds. Budgets are hard caps enforced inside
  wallet9p on every execution path, including approved payments.
- Mainnet networks (Ethereum, Base) are supported. As with any hot
  wallet, keep balances proportional to what the configured budgets and
  your approval discipline can protect; use testnets (Ethereum Sepolia,
  Base Sepolia) for development.

**Known limitations** (tracked, not hidden):

- Transactions are legacy type-0 (EIP-155 gas-price) — accepted on all
  supported networks; EIP-1559 fee-market transactions are a planned
  addition.
- The secp256k1 field arithmetic reduces through libmp's `mpint`, and
  the Jacobian point addition contains data-dependent branches: the
  scalar-multiplication ladder is structurally constant-time but the
  implementation is not constant-time end to end. RFC 6979 deterministic
  nonces remove per-signature nonce randomness as an attack surface, and
  remote timing attacks against ECDSA over 9P/HTTP round-trips are not
  practical; a co-resident local attacker with high-resolution timing is
  outside the current threat model.
- Accounts are single random keys — there is no BIP-39 mnemonic or
  BIP-32 HD derivation. Backup is via secstore (encrypted, passworded),
  not a seed phrase.
- Solana account signing exists at the primitive level (Ed25519) but
  Solana transaction construction is not implemented.
- The code has been reviewed and hardened in-tree but has not had an
  independent third-party audit.

## Overview

InferNode provides a native cryptocurrency wallet that enables Veltro AI agents to make autonomous payments for external services. The system follows Plan 9 architecture principles: everything is a file, secrets are managed by factotum, and persistent storage uses secstore.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    User / Agent                          │
├──────────┬──────────┬───────────┬───────────────────────┤
│ Wallet   │ Veltro   │ payfetch  │  Keyring GUI          │
│ GUI App  │ wallet   │ tool      │  (credential mgmt)    │
│          │ tool     │ (x402)    │                        │
├──────────┴──────────┴───────────┴───────────────────────┤
│                   wallet9p (9P server)                   │
│           /n/wallet/{acct}/address,balance,pay,authorize │
├─────────────────────────────────────────────────────────┤
│  ethcrypto     │  ethrpc        │  x402         │ stripe │
│  (RLP, EIP-155)│  (JSON-RPC)    │  (HTTP 402)   │ (fiat) │
├─────────────────────────────────────────────────────────┤
│              factotum (in-memory key agent)               │
│                   /mnt/factotum/ctl                       │
├─────────────────────────────────────────────────────────┤
│              secstore (encrypted persistent storage)      │
│                 PAK authentication, AES-256-GCM           │
├─────────────────────────────────────────────────────────┤
│  secp256k1 + Keccak-256 (libsec C primitives)            │
│  keyring.m builtins                                       │
└─────────────────────────────────────────────────────────┘
```

## Boot Sequence

```
1. secstored starts (listens on tcp!localhost!5356 by default)
2. factotum starts:
   - If $SECSTORE_PASSWORD set: factotum -S -P (keys loaded automatically)
   - Otherwise: factotum starts empty (keys loaded by login screen)
3. wm/logon displays login screen (skipped if keys already loaded)
4. User enters secstore password (with confirmation on first boot)
5. Login screen:
   a. Connects to secstore, authenticates (PAK)
   b. Loads encrypted keys into factotum
   c. Establishes save-back path for new keys
   d. Creates /tmp/.secstore-unlocked sentinel
6. llmsrv, tools9p, lucibridge, lucifer start
7. System fully operational with all keys available
```

For headless operation, set `SECSTORE_PASSWORD` in the host environment before launching emu. See [Headless Mode](#headless-mode) below.

## Login Screen (wm/logon)

The login screen is a fullscreen raw Draw application that runs before the window manager. It handles secstore authentication and key loading.

### First Boot

On first boot, no secstore account exists. The login screen prompts "First boot — choose a secstore password." The password must be entered twice (confirmation step prevents typos). After confirmation, the secstore account (PAK verifier) is created and boot proceeds. All keys added during the session are automatically saved to secstore.

### Subsequent Boots

The login screen prompts for the secstore password. On successful authentication, all stored keys (wallet keys, API keys, email credentials) are loaded into factotum. The system then boots with all credentials available.

If the password is incorrect, the login screen shows the error and offers a choice: **Enter** to try again, or **Escape** to continue without secstore (with a warning that keys/secrets won't be available and AI integration may not work).

### Skipping

Press **Escape** twice to skip secstore unlock — the first press shows a warning ("Keys won't persist"), the second confirms. The system boots with an empty factotum — wallet accounts won't be available and API keys must be provisioned from environment variables. The Keyring and Settings apps will indicate that key persistence is inactive.

### Headless Mode

For non-interactive/headless deployments (servers, Jetson, CI), set `SECSTORE_PASSWORD` on the host:

```sh
export SECSTORE_PASSWORD=mypassword
emu -r. sh -l -c "your_command"
```

The profile detects the variable and starts factotum with secstore backing (`-S -P`). The login screen detects keys are already loaded and skips the password prompt automatically.

### Secstore Status Detection

After successful unlock, `wm/logon` creates a sentinel file at `/tmp/.secstore-unlocked`. Other apps (Keyring, Settings) check this file to display persistence status:
- **Keyring**: "Keys persist to secstore" or "Keys are in-memory only (login was skipped)"
- **Settings**: "Key persistence: active" or "Key persistence: inactive (login skipped)"

## Secstore (Persistent Key Storage)

Secstore is the Plan 9 secure storage service. The server stores opaque encrypted
blobs; encryption and decryption happen entirely on the client side (factotum or
the `auth/secstore` CLI). Clients authenticate to the server using the PAK
(Password Authenticated Key exchange) protocol.

For the protocol-level reference (PAK exchange, file format, threat model,
deployment topologies), see [AUTHENTICATION.md](AUTHENTICATION.md) and
[DISTRIBUTED-AUTH.md](DISTRIBUTED-AUTH.md). The summary below is
intentionally short.

### How It Works

- **secstored** runs as a background service, listening on TCP port 5356 by
  default on loopback (`tcp!localhost!5356`). Remote exposure is explicit via
  `-a` because secstore compatibility includes unauthenticated account-existence
  probes and no built-in server lockout.
- Keys are stored in `/usr/inferno/secstore/<username>/`.
- The `factotum` file is a newline-separated list of `key <attrs>` lines,
  encrypted client-side. New writes use AES-256-GCM in `SGCM2` format
  (`SGCM2\n` + 16-byte blob salt + 12-byte nonce + ciphertext + 16-byte tag).
  Older `SGCM1` GCM blobs and legacy AES-CBC blobs remain readable for
  compatibility.
- New `SGCM2` writes derive a user-scoped root key from the password with
  100 000 rounds of HMAC-SHA-256, then derive a fresh per-blob file key from
  random salt. This is stronger than the older fixed-salt `SGCM1` design, but
  still not a memory-hard KDF like scrypt or Argon2.
- New secstore accounts now write a tagged `PAK` verifier in `secstore3`
  format, using SHA-256 for the password hash and PAK transcript checks on a
  stronger 2048/256 subgroup set. `secstore2` and legacy bare-hex `PAK` files
  still authenticate via fallback.
- The `PAK` file contains the password verifier `Hi = H⁻¹ mod p` — a function
  of (username, password) but not the password itself.
- The PAK exchange uses a 1024-bit prime; the first authentication of a session
  takes ~5 seconds on a laptop because of `H = (...)^r mod p`. Factotum caches
  `Hi` per (user, password) so subsequent auth is fast.
- The wire is wrapped with Inferno SSL (`alg sha256 aes_128_cbc`); the bulk
  cipher is AES-128-CBC and integrity is HMAC-SHA-256, with keys derived from
  the PAK shared secret. There is no PKI / no X.509 — the SSL handshake is
  symmetric, keyed entirely by PAK.

### Key Persistence Flow

```
Create wallet account
  → key stored in factotum memory
  → wallet9p writes "sync" to /mnt/factotum/ctl (async)
  → factotum connects to secstore (PAK auth)
  → factotum encrypts all keys with AES-256-GCM
  → encrypted blob stored in secstore
```

### Factotum Secstore CTL Command

A running factotum instance can be connected to secstore mid-session:

```
echo 'secstore tcp!localhost!5356 username password' > /mnt/factotum/ctl
```

This is used by the login screen to establish the save-back path after authentication.

### Cross-Machine Key Sync

secstored can serve keys to remote machines:

```
# On the key server (e.g., Mac)
auth/secstored    # already running from boot

# On the remote machine (e.g., Jetson)
auth/factotum -S tcp!mac-ip!5356 -u username -P password
```

All keys (wallet, API, email) sync automatically.

## Cryptographic Primitives

### secp256k1 (libsec/secp256k1.c)

Clean-room implementation of the secp256k1 elliptic curve used by Ethereum and Bitcoin. Follows the same patterns as the existing P-256 implementation in `libsec/ecc.c`.

- **Montgomery ladder** in Jacobian coordinates (structurally constant-time;
  see the field-arithmetic caveat under [Status and Security Model](#status-and-security-model))
- **RFC 6979 deterministic k** for reproducible signatures (required by Ethereum)
- **Recovery ID** in signatures (byte 65) for `ecrecover`
- **Low-S normalization** (BIP-62 / EIP-2)
- **Host OS CSPRNG** (`arc4random_buf` on macOS, `getrandom` on Linux) with
  rejection sampling to `0 < k < n` and fail-closed entropy verification
- **Scalar range validation** — key import, public-key derivation, and signing
  all reject out-of-range private keys (0 or ≥ n)
- Cross-validated against the EIP-155 specification test vector (byte-identical
  signed transaction vs go-ethereum)

Keyring builtins:
```limbo
kr->secp256k1_keygen()           # → (priv[32], pub[65])
kr->secp256k1_pubkey(priv)       # → pub[65]
kr->secp256k1_sign(priv, hash)   # → sig[65] (r||s||v)
kr->secp256k1_recover(hash, sig) # → pub[65]
```

### Keccak-256 (libsec/keccak256.c)

Ethereum's hash function. Identical to SHA3-256 except for the domain separator byte: Keccak uses `0x01`, SHA-3 uses `0x06`.

```limbo
kr->keccak256(data, len, digest)  # → 32-byte hash
```

## Ethcrypto Library (module/ethcrypto.m)

Pure Limbo translation of go-ethereum's core crypto operations.

### Address Derivation

```limbo
pub := kr->secp256k1_pubkey(privkey);
addr := ethcrypto->pubkeytoaddr(pub);     # Keccak-256(pub[1:])[12:]
addrstr := ethcrypto->addrtostr(addr);    # EIP-55 checksummed hex
```

### RLP Encoding

Recursive Length Prefix encoding for Ethereum transactions:

```limbo
ethcrypto->rlpencode_bytes(data)           # encode byte string
ethcrypto->rlpencode_uint(value)           # encode unsigned integer
ethcrypto->rlpencode_list(items)           # encode list of encoded items
```

### Transaction Signing (EIP-155)

```limbo
tx := ref Ethcrypto->EthTx(
    nonce, gasprice, gaslimit, dst,
    ethcrypto->dectobe("1000000000000000000"),  # value: uint256 as BE bytes
    data, chainid
);
rawtx := ethcrypto->signtx(tx, privkey);   # signed RLP-encoded transaction
```

`EthTx.value` is an arbitrary-precision uint256 (big-endian bytes) built with
`dectobe`, which parses **strict** decimal integers — amounts above 2^63 wei
are handled correctly, malformed strings return nil instead of a wrong number.
`signtx` validates every field (chain id, destination length, value range,
key range) and returns nil rather than signing a malformed transaction.

### EIP-712 Typed Data Hashing

Used by the x402 payment protocol for authorization signing:

```limbo
hash := ethcrypto->eip712hash(domainsep, structhash);
```

### Limbo Big Integer Caution

Limbo truncates `big` hex literals larger than `0x7FFFFFFF`. Use arithmetic with variables:

```limbo
# WRONG: big 16r4A817C800 → truncated to negative
# RIGHT:
billion := big 1000000000;
gwei20 := big 20 * billion;
```

## Wallet9p (9P File Server)

The wallet filesystem mounts at `/n/wallet/` and provides account management, signing, and balance queries.

### File Tree

```
/n/wallet/
├── ctl              rw   "network <name>", "default <name>", "rpc <url>",
│                         "approve <id>", "deny <id>"
├── accounts         r    newline-separated account names
├── default          r    default account name
├── network          r    active network: name, chainid, caip2, usdc contract
├── pending          r    trusted controller view of pending payments
├── new              rw   write: "eth chain name" or "import eth chain name hexkey"
│                         read: account name after creation
└── {name}/
    ├── address      r    public address (EIP-55 checksummed)
    ├── balance      r    live balance from blockchain RPC
    ├── chain        rw   chain name
    ├── pay          rw   write: "amount recipient" → read: pending:id or txhash
    ├── authorize    rw   write: structured x402 request → read: pending:id or
    │                         "sig <hex> from <addr> nonce <hex> validafter <n> validbefore <n>"
    ├── ctl          rw   "budget maxpertx maxpersess currency", "requireapproval [off]"
    └── history      r    recent transactions (timestamped, capped at 200)
```

Agent namespaces do not receive this full tree. A `/n/wallet` capability is
narrowed to `accounts`, `default`, `network`, account directories, and the
per-account `address`, `balance`, `chain`, `pay`, `authorize`, and `history`
files. Root `ctl`, `pending`, `new`, and per-account `ctl` are trusted
controller surfaces hidden from agents.

**There is no raw signing file.** An earlier `sign` file signed an arbitrary
caller-chosen 32-byte hash with the account's spend key — a *blind signing
oracle*: anything that could reach it could hash an EIP-3009
TransferWithAuthorization for the entire balance and have the wallet sign it,
bypassing budgets and the approval queue entirely. Keeping agents away from it
depended on namespace narrowing being correct everywhere, which is one bug away
from re-exposure, so the file was removed outright. Payments go through the
structured `pay` and `authorize` files, where wallet9p constructs everything it
signs and enforces policy first. `nsconstruct` still refuses `sign` (and
per-account `ctl`) as `caps.paths` grants, and `tools9p` shares that one
predicate (`NsConstruct->walletcontrolpath`) rather than keeping a copy.

**Results are bound to the writing fid.** wallet9p is a single server shared by
every agent's bound view, and a signed EIP-3009 authorization is a replayable
bearer credential, so a reader that did not submit the request sees nothing —
there is no account-level fallback. Clients must write and read on ONE `ORDWR`
descriptor (write, seek 0, read); the shell `echo`-then-`cat` idiom will not
return a result.

### Account Creation

```sh
echo 'eth ethereum myaccount' > /n/wallet/new
cat /n/wallet/new    # → myaccount
cat /n/wallet/myaccount/address    # → 0x...
```

### Importing a Private Key

```sh
echo 'import eth ethereum myaccount 0123456789abcdef...' > /n/wallet/new
```

### x402 Authorization

```sh
echo 'scheme exact
network eip155:84532
asset 0x036CbD53842c5426634e7929541eC2318f3dCF7e
payto 0xServerAddress...
amount 10000
timeout 60
name USDC
version 2' > /n/wallet/myaccount/authorize
cat /n/wallet/myaccount/authorize
# → pending:3            (waits for approval), then after approval:
# → sig <130 hex> from <addr> nonce <64 hex> validafter <t> validbefore <t>
```

wallet9p validates the request (addresses, strict integer amount, the
network **must** match the wallet's active network), generates the 32-byte
nonce and validity window itself (validAfter is backdated 600 s for clock
skew), computes the EIP-712 digest itself, checks the budget, and queues
for approval. The signature it returns authorizes exactly one transfer of
exactly that amount to exactly that recipient within the validity window.

The request format is line-oriented `key value`, and every field originates
in a remote server's 402 response, so both ends are strict about it: the
x402 client rejects any field containing a control character (a smuggled
newline would inject extra lines), and **wallet9p rejects duplicate keys**
outright rather than letting a later `payto`/`amount` line override an
earlier one. Unknown fields are refused.

### Network Selection

wallet9p supports multiple networks, each with its own RPC endpoint and USDC contract:

| Network | RPC Endpoint | USDC Contract | Chain ID |
|---------|-------------|---------------|----------|
| Ethereum Sepolia | ethereum-sepolia-rpc.publicnode.com | 0x1c7D4B196... | 11155111 |
| Base Sepolia | sepolia.base.org | 0x036CbD538... | 84532 |
| Ethereum Mainnet | eth.llamarpc.com | 0xA0b86991... | 1 |
| Base | mainnet.base.org | 0x833589fCD... | 8453 |

Switch network:
```sh
echo 'network Ethereum Sepolia' > /n/wallet/ctl
```

### Account Persistence

wallet9p restores accounts from factotum on startup. It scans for `service=wallet-*` keys and derives addresses from the stored private keys. Keys are stored in factotum as:

```
key proto=pass service=wallet-eth-{name} user=key chain={chain} !password={hex-encoded-privkey}
```

The `chain` attribute preserves the account's configured chain across
restarts (older keys without it default by account type). Stored keys are
validated on restore — a corrupt or out-of-range key is skipped with an
error rather than yielding a wrong address.

When a new account is created, wallet9p immediately triggers a factotum sync to persist the key to secstore (async, non-blocking).

### Budget Enforcement

```sh
echo 'budget 1000000 10000000 USDC' > /n/wallet/myaccount/ctl
```

Budgets are hard caps enforced inside wallet9p on **every** execution path:
direct payments, approved payments, ERC-20 transfers, x402 authorizations,
and Stripe charges. Amounts are integer base units and per-tx / per-session
limits both apply. Budgets are currency-scoped (`USDC`, `ETH` in wei, `USD`
in cents): a payment in a currency the configured budget cannot evaluate is
**rejected**, not waved through — including x402 requests for any asset other
than the active network's USDC contract. Human approval does not override a
budget; over-budget payments fail even after approval.

Amount parsing everywhere is strict: only plain decimal integers are
accepted (`"1.5"`, `"10 USDC"`, hex, or empty amounts are errors, never
silently misread), and values are handled as arbitrary-precision uint256 —
amounts and balances above 2^63 wei do not wrap.

### Payment Approval

New and restored accounts require approval by default. Writing to
`/n/wallet/{account}/pay` or `/n/wallet/{account}/authorize` queues a pending
payment and returns `pending:<id>`. Requests are validated *before* queueing
(malformed or over-budget requests are rejected immediately), and pending
entries expire after 15 minutes if unapproved.

To review: open the wallet GUI and choose **Pending Payments** from the
right-click menu (the status bar shows a count when payments are waiting),
or from a trusted shell:

```sh
cat /n/wallet/pending   # "<id> <kind> <acct> <token> <amount> <recipient> <network> <agent>"
echo 'approve 3' > /n/wallet/ctl      # or: deny 3
```

Payments the user initiates in the wallet GUI itself are auto-approved (the
human just clicked Send); agent proposals always wait.

Trusted live-payment tests or administrative sessions may explicitly opt out:

```sh
echo 'requireapproval off' > /n/wallet/myaccount/ctl
```

### Network Pinning

The chain ID used for signing always comes from the wallet's configured
network table, never from the RPC endpoint. Before signing, wallet9p
cross-checks `eth_chainId` against the configured value and **refuses to
sign** on mismatch or error — a compromised or misconfigured RPC endpoint
cannot move a payment onto a different chain. x402 authorization requests
must likewise name the active network or they are rejected.

## Ethereum JSON-RPC Client (module/ethrpc.m)

Speaks the standard Ethereum JSON-RPC API over HTTPS.

```limbo
ethrpc->init("https://ethereum-sepolia-rpc.publicnode.com");
(balance, err) := ethrpc->getbalance("0x...");           # wei as decimal string
(tokbal, err) := ethrpc->tokenbalance(usdc_addr, "0x...");  # ERC-20 balance
(nonce, err) := ethrpc->getnonce("0x...");
(txhash, err) := ethrpc->sendrawtx("0x...");
(receipt, err) := ethrpc->waitreceipt(txhash, 30);

# Conversions
ethrpc->weitoeth("1000000000000000000")    # → "1"
ethrpc->weitotoken("20000000", 6)          # → "20" (USDC)
```

## x402 Payment Protocol (module/x402.m)

Implements the x402 v2 specification for HTTP 402 payment flows.

### Protocol Flow

```
1. Client requests resource
2. Server returns 402 with payment requirements (JSON)
3. Client selects the payment option matching the wallet's active network
4. Client writes a structured request to /n/wallet/{acct}/authorize;
   wallet9p validates, budget-checks, queues for approval, and signs
   the EIP-3009 authorization itself
5. Client retries with the X-PAYMENT header (base64 payload; the legacy
   PAYMENT-SIGNATURE raw-JSON header is also sent for older servers)
6. Server verifies and settles payment via facilitator
7. Server returns resource (X-PAYMENT-RESPONSE carries settlement info)
```

### Library API

```limbo
# Parse 402 response
(pr, err) := x402->parse402(body);

# Select best payment option for our chain
opt := x402->selectoption(pr, "base");

# Request a signed authorization from wallet9p (policy enforced there);
# polls up to waitsecs while trusted approval is pending
(payload, err) := x402->authorize(opt, pr.resource, "myaccount", 90);
# err == "pending:<id>" if approval did not arrive in time

# Compute the EIP-712 digest of an EIP-3009 authorization
# (wallet9p uses this — the signer constructs what it signs)
(digest, err) := x402->authdigest(network, asset, payto, from, amount,
    validafter, validbefore, nonce, tokenname, tokenversion);

# Parse settlement response
(sr, err) := x402->parsesettlement(body);
```

### Chain/Network Mapping

```limbo
x402->chaintonetwork("base")        # → "eip155:8453"
x402->networktochainid("eip155:1")  # → 1
```

## Veltro Tools

### wallet tool

Agent-facing interface to wallet9p:

```
wallet accounts                    List all wallet accounts
wallet address <account>           Show public address
wallet balance <account>           Show balance
wallet chain <account>             Show blockchain network
wallet history <account>           Show recent transactions
wallet network                     Show the active network (read-only)
wallet pay <account> <wei> <addr>  Queue an ETH payment proposal
wallet pay <account> usdc <amount> <addr>   Queue a USDC proposal
```

There is deliberately no `wallet sign` command and no network switching from
the agent tool — raw signing and network selection are trusted-controller
operations.

### payfetch tool

HTTP client with automatic x402 payment handling:

```
payfetch <url>                     Fetch URL, pay if 402
payfetch <url> -a <account>        Use specific wallet account
payfetch <url> -a <account> -c <chain>    Specify chain preference
```

When a server returns 402 Payment Required:
1. Parses x402 payment requirements
2. Selects the option matching the wallet's active network (`/n/wallet/network`)
3. Requests a signed authorization from wallet9p via `authorize`
   (budget + approval enforced there; waits up to 90 s for approval,
   then reports "payment pending approval" so the agent can retry later)
4. Retries with the `X-PAYMENT` header (and legacy `PAYMENT-SIGNATURE`)
5. Reports what was paid before returning content

The agent explicitly chooses `payfetch` over `webfetch` when willing to spend
money. payfetch applies the same SSRF blocklist as webfetch (private ranges,
IPv6 loopback/link-local, cloud metadata, bare-IP encodings), and the
outbound path (publicnet) independently refuses private and reserved
destinations at dial time on every hop. Loopback is always unreachable —
local x402 test servers must listen on a routable address.

### Namespace Security

Wallet access is gated by namespace capabilities:

- Agent needs `"/n/wallet"` in `caps.paths` to access the wallet
- `/mnt/factotum/ctl` is blocked by nsconstruct — agents never see private keys
- Budget and approval enforcement is server-side in wallet9p, on every path
- There is no raw signing file at all. Agents submit structured `pay` and
  `authorize` requests; wallet9p constructs and policy-checks everything the
  key signs, and the key never enters the agent's address space
- Results are per-fid: one agent cannot read another's txhash or signed
  authorization

## Wallet GUI App (wm/wallet.b)

Graphical wallet manager for users (Tk-based). The GUI is the trusted
controller for the agent payment approval queue.

### Layout

- **Left pane (35%)**: Account list
- **Right pane (65%)**: Network selector, account details (name, chain, address, balance)

### Features

- **Network selector**: Switch between Ethereum Sepolia, Base Sepolia, Ethereum Mainnet, Base
- **Account creation**: Right-click → New Ethereum Account
- **Key import**: Right-click → Import Private Key
- **Pending Payments**: Right-click → Pending Payments — review agent payment
  proposals and x402 authorization requests, approve or deny each. The status
  bar shows a live count of waiting payments.
- **Send Payment**: user-initiated sends are auto-approved (the human just
  clicked Send); agent proposals always go through the queue
- **Balance display**: USDC and ETH on separate lines, fetched asynchronously
- **Context menu** (right-click on detail pane): Copy Address, Copy Account Name, Refresh Balance
- **Auto-start**: Starts wallet9p automatically if not running
- **Persistence**: Accounts survive emu restart via factotum/secstore

### Balance Loading

Balances are fetched asynchronously in a background goroutine. The GUI shows "loading..." immediately and updates when the RPC call completes. A 30-second timer refreshes automatically.

## Stripe Fiat Backend (module/stripe.m)

Basic Stripe API client for fiat payments. API key stored in factotum.

```limbo
stripe->init(apikey);
(id, err) := stripe->createpayment(amount, "usd", "description");
(balance, err) := stripe->balance();
(charges, err) := stripe->recent(10);
```

## Dropdown Widget

A new widget added to the toolkit (`module/widget.m`):

```limbo
dd := Dropdown.mk(rect, items, selectedIndex);
dd.label = "Network:";    # optional prefix
dd.draw(screen);

# On click: opens popup overlay with all options
if(dd.contains(ptr.xy))
    dd.click(screen, ptrchan);    # blocks until selection

dd.value()    # → selected item string
```

The popup renders over the parent image, highlights items on hover, and restores the underlying pixels on close.

## Post-Quantum Readiness

The wallet architecture is designed for future post-quantum signature schemes:

- `Account.accttype` dispatches signing by type — adding `ACCT_PQ` is one new case
- ML-DSA-65/87 (FIPS 204) is already available in keyring.m
- TLS connections to RPC endpoints use hybrid X25519+ML-KEM-768 when available
- No PQ-specific wallet work needed until chains adopt PQ signatures

## Verified Live Transactions

The wallet has been exercised with live transactions on Ethereum Sepolia
(recorded before the policy overhaul; the signing pipeline is additionally
verified byte-for-byte against the EIP-155 specification vector):

| Type | Transaction | Hash |
|------|------------|------|
| ETH send (1000 wei) | Burn address | `0xf38d2f48a4391823a1d1356c522bacfc9e11639d5fa12e13652d1be082760b1c` |
| USDC ERC-20 (1 USDC) | Burn address | `0x536630bba5ae9ca2cf6eec123f2965ef23a1164d212a4a436c2685f1903ac8b5` |
| Agent wallet tool | Burn address | `0x73c19911a9e0ee44a4445a1eb82f251c4aa6f174ae1925f17563f090af93c669` |
| x402 payfetch | Test server | EIP-712 signed authorization, 200 OK returned |

All transactions verifiable at [sepolia.etherscan.io](https://sepolia.etherscan.io).

## Testing

### Unit Tests (run inside emu)

```sh
./emu/MacOSX/o.emu -r. -c0 /dis/tests/secp256k1_test.dis -v    # curve, ECDSA, recovery
./emu/MacOSX/o.emu -r. -c0 /dis/tests/ethcrypto_test.dis -v    # RLP, EIP-155 spec vector, dectobe
./emu/MacOSX/o.emu -r. -c0 /dis/tests/x402_test.dis -v         # parsing, EIP-712 type hashes, authdigest
./emu/MacOSX/o.emu -r. -c0 /dis/tests/publicnet_host_test.dis  # URL host parsing + SSRF blocklist
./emu/MacOSX/o.emu -r. -c0 /dis/tests/wallet_capability_test.dis  # agent namespace narrowing
```

Notable assertions: the EIP-155 specification test vector must produce a
byte-identical signed transaction to go-ethereum; the EIP-712 and EIP-3009
type hashes must match the published constants; `dectobe` must reject every
malformed amount form; `becmp`/`beadd` must carry budget arithmetic past
2^63 without wrapping; `networktochainid` must fail closed; the shared SSRF
predicate must block octal, hex, and packed-integer IP encodings; and the
agent namespace must expose `authorize` while no `sign` file exists at all.

### Integration Tests (run on host)

```sh
bash tests/host/wallet9p_test.sh              # wallet policy suite against a live
                                              #   wallet9p: address KAT, key validation,
                                              #   strict amounts, uint256 budgets,
                                              #   currency fail-closed, network pinning,
                                              #   request-injection rejection,
                                              #   pending/approve/deny, per-fid isolation,
                                              #   and absence of the signing oracle
bash tests/host/wallet_e2e_test.sh            # Base Sepolia RPC connectivity
bash tests/host/secstore_logon_test.sh        # secstore + factotum persistence (10 tests)
bash tests/host/secstore_apikey_test.sh       # API key persistence through secstore (10 tests)
bash tests/host/wallet_persist_test.sh        # wallet key survival across restarts (7 tests)
bash tests/host/payfetch_test.sh              # x402 payfetch end-to-end (requires x402-test-server)
```

### x402 Test Server

A dedicated test server is available for payfetch testing:

```sh
git clone git@github.com:infernode-os/x402-test-server.git
cd x402-test-server && npm install && npm start
```

The server listens on port 4020 and returns proper x402 v2 402 responses.
payfetch cannot reach loopback addresses (its SSRF policy and publicnet both
refuse them), so address the server by a routable address — e.g. the host's
LAN IP. Test from the Inferno shell:

```
echo 'http://<lan-ip>:4020/api/data -a veltro-demo-wallet' > /tool.1/payfetch/ctl
cat /tool.1/payfetch/ctl
```

### Test Safety

All integration tests use dedicated test user accounts (`testuser-walletpersist`, `testuser-seclogon`, `testuser-payfetch`). They never touch the real user's secstore data.

### CI/CD

The CI pipeline (`.github/workflows/ci.yml`) runs on both Linux AMD64 and macOS ARM64:
- All `*_test.dis` unit tests via the emu test runner
- `wallet9p_test.sh` — wallet policy suite (budgets, approval queue,
  x402 authorization, network pinning, per-fid isolation)
- `wallet_persist_test.sh` — secstore round-trip key survival

## Building

```sh
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH

# C crypto layer (requires emu rebuild)
cd libsec && mk install
cd ../libinterp && rm -f keyring.h keyringif.h && mk keyring.h && mk keyringif.h && mk install
cd ../emu/MacOSX && mk o.emu && cp o.emu InferNode

# Limbo libraries
limbo -I$ROOT/module -gw -o dis/lib/ethcrypto.dis appl/lib/ethcrypto.b
limbo -I$ROOT/module -gw -o dis/lib/wallet.dis appl/lib/wallet.b
limbo -I$ROOT/module -gw -o dis/lib/x402.dis appl/lib/x402.b
limbo -I$ROOT/module -gw -o dis/lib/stripe.dis appl/lib/stripe.b
limbo -I$ROOT/module -gw -o dis/lib/ethrpc.dis appl/lib/ethrpc.b

# 9P server and tools
limbo -I$ROOT/module -gw -o dis/veltro/wallet9p.dis appl/veltro/wallet9p.b
cd appl/veltro/tools && limbo -I$ROOT/module -I$ROOT/appl/veltro -gw \
    -o $ROOT/dis/veltro/tools/wallet.dis wallet.b
cd appl/veltro/tools && limbo -I$ROOT/module -I$ROOT/appl/veltro -gw \
    -o $ROOT/dis/veltro/tools/payfetch.dis payfetch.b

# GUI apps
limbo -I$ROOT/module -gw -o dis/wm/wallet.dis appl/wm/wallet.b
limbo -I$ROOT/module -gw -o dis/wm/logon.dis appl/wm/logon.b

# Widget toolkit (if widget.m changed, rebuild all GUI apps)
limbo -I$ROOT/module -gw -o dis/lib/widget.dis appl/lib/widget.b
```

## File Index

| File | Purpose |
|------|---------|
| `libsec/secp256k1.c` | secp256k1 ECDSA (C, constant-time) |
| `libsec/keccak256.c` | Keccak-256 hash (C) |
| `include/libsec.h` | C function declarations |
| `module/keyring.m` | Limbo crypto builtins |
| `libinterp/keyring.c` | C↔Limbo glue for crypto |
| `module/ethcrypto.m` | Ethereum crypto module interface |
| `appl/lib/ethcrypto.b` | RLP, EIP-155, EIP-712, addresses |
| `module/wallet.m` | Wallet library interface |
| `appl/lib/wallet.b` | Factotum-backed account management |
| `module/ethrpc.m` | Ethereum JSON-RPC client interface |
| `appl/lib/ethrpc.b` | JSON-RPC implementation |
| `module/x402.m` | x402 payment protocol interface |
| `appl/lib/x402.b` | x402 v2 implementation |
| `module/stripe.m` | Stripe API client interface |
| `appl/lib/stripe.b` | Stripe REST API implementation |
| `appl/veltro/wallet9p.b` | Wallet 9P file server |
| `appl/veltro/tools/wallet.b` | Veltro wallet tool |
| `appl/veltro/tools/payfetch.b` | x402-enabled HTTP fetch tool |
| `appl/wm/wallet.b` | Wallet GUI application |
| `appl/wm/logon.b` | Login/secstore unlock screen |
| `appl/cmd/auth/factotum/factotum.b` | Factotum with secstore ctl command |
| `module/widget.m` | Widget toolkit (includes Dropdown) |
| `appl/lib/widget.b` | Widget implementation |
| `lib/sh/profile` | Boot profile (secstored + factotum) |
| `lib/lucifer/login-screen.png` | Login screen brand image |
