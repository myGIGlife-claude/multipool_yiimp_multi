# multipool_yiimp_multi
Installation files for YiiMP multi server

#### These files do nothing on their own please go to https://github.com/mygiglifeinc-glitch/Multi-Pool-Installer

Supported operating systems: Ubuntu 22.04, 24.04 and 26.04 LTS (x86_64), on every server of the pool.

## How it works

The installer is started on the server that will host the database. It asks all
questions up front, installs the DB (or DB + stratum) server locally and then
installs the web, stratum and daemon servers over SSH:

* each server is logged in to once; the connection is reused for every step, the
  password is never written to disk or passed on a command line, and host keys are
  checked (`StrictHostKeyChecking=accept-new`, stored in `~/.ssh/multipool_known_hosts`);
* the remote user needs password-less sudo (the multipool user setup configures it;
  otherwise the installer adds it with the password you entered);
* files are copied to a private temporary directory on each server that is removed
  when that server is done, and each server only receives the settings it needs
  (no SSH or database root passwords).

The database accounts may only connect from the web/stratum server that uses them,
MariaDB listens on the private IP only and the firewall (ufw) of every server only
allows SSH, what the server role needs publicly and traffic from the other pool
servers. Without provider private IPs, install the WireGuard network first (menu
option 1).

## Install-time overrides

| Variable | Default | Purpose |
|:--|:--|:--|
| `YIIMP_REPO` | `https://github.com/mygiglifeinc-glitch/yiimp.git` | YiiMP source repository |
| `YIIMP_BRANCH` | repository default | YiiMP branch or tag |
| `DISABLE_FIREWALL` | unset | Set to `1` to skip the ufw configuration |

## Stratum servers

* `stratum start|stop|restart algo` starts or stops the stratum of an algo.
* `addport` creates a dedicated port stratum for a coin. `addport_multi` does the
  same and also updates the stratum servers listed, one `user@private_ip` per line,
  in `$STORAGE_ROOT/yiimp/.remote_stratums.conf` (SSH asks for each password
  unless you use SSH keys).
* The `verthash` stratum (Vertcoin) needs its 1.2 GB data file. Create it once on each stratum
  server: `cd $STORAGE_ROOT/yiimp/site/stratum && ./verthash_gen verthash.dat`.

## Algos with their own stratum protocols

These algos use a protocol other than the Bitcoin stratum. Each needs a few
extra steps on the coin daemons.

### KawPoW family (kawpow, evrprogpow, meowpow, firopow, sccpow, meraki)

- Coins: RVN, XNA, NEOX, SATOX, EVR, MEWC, FIRO, SCC, TLS.
- Ports: 9501-9506.
- Each stratum keeps the ProgPoW verification caches of the current and next epoch in memory, about 95-140 MB per coin.
- Because of that memory use they are not started at boot. Start the ones you need with `stratum start kawpow` (or firopow, meowpow...).
- Coins whose getblocktemplate has a `!segwit` rule (MEWC 30.x, TLS 3.x) need `usesegwit` enabled on the coin.

### Equihash (equihash, equihash144, equihash192) and yespowerRES

- Coins: ZEC, KMD, ARRR (200,9); BTG, BTCZ, GLINK (144,5); YEC, ZER, ZCL (192,7); RES.
- Ports: 9600-9602 and 9650.
- Daemon setup:
  - zcashd 6.x needs `mineraddress=<pool t-address>`. The coinbase, founders reward and funding streams come from the daemon.
  - BTG needs `usesegwit` enabled on the coin.
  - Resistance needs its Sapling/Sprout parameters in `~/.resistance-params`.
- Every daemon needs at least one peer to answer getblocktemplate, and `blocknotify=/usr/bin/blocknotify 127.0.0.1:<stratum port> <coin id> %s`.
- The Equihash personalization of a coin can be set in the stratum `.conf`: `equihash_personalization`, or an `[EQUIHASH]` section with `SYMBOL = personalization`.

### Decred (decred, BLAKE3)

- Decred's proof of work has been BLAKE3 since block 794,368. The `decred` stratum (port 3252) mines it through dcrd's getwork.
- dcrd must run with `--miningaddr=<pool wallet address>`. The block reward is paid there.
- The coin's RPC can point at dcrwallet (RPC passthrough, not SPV).
- Blocks are confirmed by `blocknotify-dcr` from the YiiMP source. Building it needs Go 1.21 or newer:
  ```
  make -C blocknotify-dcr install
  blocknotify-dcr -stratum 127.0.0.1:3252 -coinid <id> -rpcuser <user> -rpcpass <pass> -rpccert <dcrd rpc.cert>
  ```
- Keep the stratum difficulty at 1 or more.

### RandomX (randomx, Monero)

- Coin: XMR. Port: 9701. Miners use the xmrig protocol (xmrig, XMRig-proxy).
- It is not started at boot. Start it with `stratum start randomx`.
- **Resources:**
  - Memory: up to about 800 MB of RandomX caches.
  - CPU: each share costs about 20-40 ms of one core.
- **monerod:**
  - Run it with `--rpc-login <user>:<pass>`.
  - Also pass `--block-notify '/usr/bin/blocknotify 127.0.0.1:9701 <coin id> %s'`.
- **monero-wallet-rpc:**
  - It runs the pool wallet. That wallet's address must be the coin's master wallet.
  - Payouts are sent from it with `transfer_split`.
- **Coin setup:**
  - Set the coin's *RPC Type* to `XMR`.
  - Add the wallet to `serverconfig.php`: `$configWalletRPC['XMR'] = 'host:port:user:pass';`. Without that line it is expected on the daemon host at RPC port + 1.
- **Testing:** payouts have been tested only once, on a private test network.
- To connect a different stratum program (for algos this stratum can't handle), see [docs/BRIDGE.md](https://github.com/mygiglifeinc-glitch/yiimp/blob/next/docs/BRIDGE.md) in the YiiMP source.
