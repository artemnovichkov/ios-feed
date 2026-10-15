# /// script
# requires-python = ">=3.11"
# dependencies = ["telethon>=1.36", "python-dotenv>=1.0"]
# ///
"""Manage named @ios_daily invite links to track subscriber sources.

    uv run scripts/invites.py               # list links with join counts
    uv run scripts/invites.py create a b c  # create links titled a, b, c (skips existing)
"""

import asyncio
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from telethon import TelegramClient
from telethon.tl.functions.messages import ExportChatInviteRequest, GetExportedChatInvitesRequest
from telethon.tl.types import InputUserSelf

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

CHANNEL = os.environ.get("TG_CHANNEL", "ios_daily")
SESSION = str(ROOT / "scripts" / "stats")


async def invites(client, channel):
    r = await client(GetExportedChatInvitesRequest(peer=channel, admin_id=InputUserSelf(), limit=100))
    return [i for i in r.invites if getattr(i, "title", None) and not i.revoked]


async def main():
    client = TelegramClient(SESSION, int(os.environ["TG_API_ID"]), os.environ["TG_API_HASH"])
    await client.connect()
    if not await client.is_user_authorized():
        sys.exit("Not logged in, run: uv run scripts/stats.py --qr")
    channel = await client.get_entity(CHANNEL)

    if sys.argv[1:2] == ["create"]:
        existing = {i.title for i in await invites(client, channel)}
        for title in sys.argv[2:]:
            if title not in existing:
                await client(ExportChatInviteRequest(peer=channel, title=title))

    for i in sorted(await invites(client, channel), key=lambda i: i.title):
        print(f"{i.title:32} {i.usage or 0:>4}  {i.link}")
    await client.disconnect()


asyncio.run(main())
