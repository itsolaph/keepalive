#!/usr/bin/env python3
"""Keepalive demo provider: BTC/ETH price alerts to Telegram + onchain heartbeats.

The bot heartbeats each plan once per epoch, but only while its own job is
healthy: the price feed answered in the last 2 minutes and Telegram answers.
If the feed or Telegram breaks, heartbeats stop and the subscribers' epochs
are refunded on settle.

Kill switch (demo): if the file <KA_KILL_DIR>/kill-<planId> exists, the bot
skips heartbeats for that plan, exactly as if the service were down.
"""
import json, os, subprocess, time, urllib.request

RPC = os.environ.get("KA_RPC", "https://rpc.mainnet.arc.io")
CONTRACT = os.environ["KA_CONTRACT"]
PLANS = [p.strip() for p in os.environ.get("KA_PLANS", "1").split(",") if p.strip()]
KEYFILE = os.path.expanduser(os.environ["KA_KEYFILE"])
CAST = os.path.expanduser(os.environ.get("KA_CAST", "~/.foundry/bin/cast"))
TG_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TG_CHAT = os.environ["KA_TG_CHAT"]
MOVE_PCT = float(os.environ.get("KA_MOVE_PCT", "1.0"))
STATE = os.path.expanduser(os.environ.get("KA_STATE", "~/.keepalive/state.json"))
KILL_DIR = os.path.expanduser(os.environ.get("KA_KILL_DIR", "~/.keepalive"))
UA = {"User-Agent": "keepalive-bot/1.1"}
ASSETS = ["BTC", "ETH"]
TICK = 10
LOW_GAS = float(os.environ.get("KA_LOW_GAS_USDC", "0.05"))
FEED_EVERY = 60


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *a, flush=True)


def http_json(url, data=None, timeout=15):
    hdr = {**UA, "Content-Type": "application/json"} if data else UA
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=hdr), timeout=timeout) as r:
        return json.load(r)


def price(asset):
    return float(http_json(f"https://api.coinbase.com/v2/prices/{asset}-USD/spot")["data"]["amount"])


def tg_send(text):
    body = json.dumps({"chat_id": TG_CHAT, "text": text, "disable_web_page_preview": True}).encode()
    return bool(http_json(f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage", body).get("ok"))


def tg_ping():
    return bool(http_json(f"https://api.telegram.org/bot{TG_TOKEN}/getMe").get("ok"))


def cast(*args, timeout=60):
    out = subprocess.run([CAST, *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[-300:])
    return out.stdout.strip()


def current_epoch(plan):
    return int(cast("call", CONTRACT, "currentEpoch(uint256)(uint256)", plan).split()[0])


def is_alive(plan, epoch):
    return cast("call", CONTRACT, "isAlive(uint256,uint256)(bool)", plan, str(epoch)) == "true"


def heartbeat(plan):
    with open(KEYFILE) as f:
        key = f.read().strip()
    d = json.loads(cast("send", CONTRACT, "heartbeat(uint256)", plan, "--private-key", key,
                        "--gas-price", "21gwei", "--priority-gas-price", "0.01gwei", "--json", timeout=120))
    if d.get("status") != "0x1":
        raise RuntimeError(f"heartbeat reverted {d.get('transactionHash')}")
    return d["transactionHash"]


def signer_balance():
    with open(KEYFILE) as f:
        key = f.read().strip()
    addr = subprocess.run([CAST, "wallet", "address", "--private-key", key],
                          capture_output=True, text=True, timeout=30).stdout.strip()
    return float(cast("balance", addr, "--ether"))


def load_state():
    try:
        s = json.load(open(STATE))
    except Exception:
        s = {}
    s.setdefault("anchor", {})
    if s.get("contract") != CONTRACT or not isinstance(s.get("last_hb"), dict):
        s["contract"], s["last_hb"] = CONTRACT, {}
    return s


def save_state(s):
    tmp = STATE + ".tmp"
    json.dump(s, open(tmp, "w"))
    os.replace(tmp, STATE)


def feed_step(s):
    prices = {a: price(a) for a in ASSETS}
    tg_ok = tg_ping()
    for a, p in prices.items():
        anchor = s["anchor"].get(a)
        if anchor is None or time.time() - anchor["t"] > 6 * 3600:
            s["anchor"][a] = {"p": p, "t": time.time()}
            continue
        move = (p - anchor["p"]) / anchor["p"] * 100
        if abs(move) >= MOVE_PCT:
            mins = int((time.time() - anchor["t"]) / 60)
            tg_ok = tg_send(f"{a} {'up' if move > 0 else 'down'} {move:+.2f}% in {mins} min: "
                            f"${anchor['p']:,.2f} -> ${p:,.2f}\n"
                            f"Keepalive on Arc: subscribers pay per epoch only while this bot heartbeats.")
            s["anchor"][a] = {"p": p, "t": time.time()}
    return tg_ok


def main():
    s = load_state()
    feed_ok_at, tg_ok, last_feed = 0.0, False, 0.0
    log("start plans", PLANS, "contract", CONTRACT)
    last_gas_check, gas_warned = 0.0, False
    while True:
        if time.time() - last_feed >= FEED_EVERY:
            last_feed = time.time()
            try:
                tg_ok = feed_step(s)
                feed_ok_at = time.time()
            except Exception as e:
                log("feed/telegram error:", e)
                tg_ok = False
        healthy = time.time() - feed_ok_at < 120 and tg_ok
        for plan in PLANS:
            try:
                ep = current_epoch(plan)
                if s["last_hb"].get(plan) == ep:
                    continue
                if os.path.exists(os.path.join(KILL_DIR, f"kill-{plan}")):
                    if s.get(f"killed_{plan}") != ep:
                        log(f"plan {plan} epoch {ep}: KILL SWITCH on, no heartbeat")
                        s[f"killed_{plan}"] = ep
                    continue
                if not healthy:
                    log(f"plan {plan} epoch {ep}: unhealthy, skipping heartbeat")
                    continue
                if not is_alive(plan, ep):
                    log(f"plan {plan} epoch {ep}: heartbeat {heartbeat(plan)}")
                s["last_hb"][plan] = ep
            except Exception as e:
                log(f"plan {plan} chain error:", e)
        if time.time() - last_gas_check >= 3600:
            last_gas_check = time.time()
            try:
                bal = signer_balance()
                if bal < LOW_GAS and not gas_warned:
                    log(f"signer gas low: {bal:.4f} USDC")
                    tg_send(f"Keepalive: heartbeat signer has {bal:.4f} USDC left for gas. Top it up or heartbeats stop.")
                gas_warned = bal < LOW_GAS
            except Exception as e:
                log("gas check error:", e)
        save_state(s)
        time.sleep(TICK)


if __name__ == "__main__":
    main()
