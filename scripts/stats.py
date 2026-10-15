# /// script
# requires-python = ">=3.11"
# dependencies = ["telethon>=1.36", "python-dotenv>=1.0", "qrcode>=7.4"]
# ///
"""Fetch @ios_daily channel stats via MTProto. First run is interactive (login)."""

import asyncio
import getpass
import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from telethon import TelegramClient
from telethon.errors import SessionPasswordNeededError
from telethon.tl.functions.stats import GetBroadcastStatsRequest, LoadAsyncGraphRequest
from telethon.tl.types import StatsGraph, StatsGraphAsync

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

CHANNEL = os.environ.get("TG_CHANNEL", "ios_daily")
SESSION = str(ROOT / "scripts" / "stats")


def abs_value(v):
    return {"current": v.current, "previous": v.previous}


async def graph(client, g):
    if isinstance(g, StatsGraphAsync):
        g = await client(LoadAsyncGraphRequest(token=g.token))
    if isinstance(g, StatsGraph):
        return json.loads(g.json.data)
    return None


async def qr_login(client):
    import qrcode

    qr = await client.qr_login()
    while True:
        code = qrcode.QRCode(border=1)
        code.add_data(qr.url)
        code.print_ascii(invert=True)
        print("Scan: Telegram > Settings > Devices > Link Desktop Device", file=sys.stderr)
        try:
            await qr.wait(timeout=60)
            return
        except asyncio.TimeoutError:
            await qr.recreate()
        except SessionPasswordNeededError:
            await client.sign_in(password=getpass.getpass("2FA password: "))
            return


async def main():
    client = TelegramClient(SESSION, int(os.environ["TG_API_ID"]), os.environ["TG_API_HASH"])
    if "--qr" in sys.argv:
        await client.connect()
        if not await client.is_user_authorized():
            await qr_login(client)
    await client.start()
    channel = await client.get_entity(CHANNEL)
    s = await client(GetBroadcastStatsRequest(channel=channel, dark=False))

    out = {
        "period": {"min": s.period.min_date.isoformat(), "max": s.period.max_date.isoformat()},
        "followers": abs_value(s.followers),
        "views_per_post": abs_value(s.views_per_post),
        "shares_per_post": abs_value(s.shares_per_post),
        "reactions_per_post": abs_value(s.reactions_per_post),
        "enabled_notifications_pct": round(s.enabled_notifications.part / s.enabled_notifications.total * 100, 1)
        if s.enabled_notifications.total
        else None,
        "recent_posts": [
            {"id": p.msg_id, "views": p.views, "forwards": p.forwards, "reactions": p.reactions}
            for p in s.recent_posts_interactions
            if hasattr(p, "msg_id")
        ],
    }
    if "--graphs" in sys.argv:
        out["graphs"] = {
            name: await graph(client, getattr(s, name))
            for name in (
                "growth_graph",
                "followers_graph",
                "views_by_source_graph",
                "new_followers_by_source_graph",
                "top_hours_graph",
                "languages_graph",
            )
        }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    await client.disconnect()


asyncio.run(main())
