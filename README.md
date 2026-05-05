# iOS Feed Bot

A Swift CLI tool that fetches the latest iOS development articles, uses OpenAI to select the best one from the last 24 hours, and posts it to a Telegram channel.

## Prerequisites
- Swift 5.9+
- OpenAI API Key
- Telegram Bot Token
- Telegram Channel ID (e.g., @mychannel or the numeric ID)

## Environment Variables
- `OPENAI_API_KEY`: Your OpenAI API Key.
- `TELEGRAM_BOT_TOKEN`: Your Telegram Bot Token.
- `TELEGRAM_CHANNEL_ID`: Your Telegram Channel ID.

## Build
```bash
swift build -c release
```

## Run
```bash
export OPENAI_API_KEY=your_key
export TELEGRAM_BOT_TOKEN=your_token
export TELEGRAM_CHANNEL_ID=your_id
./.build/release/iOSFeedBot
```

## Deployment on VPS
1. Clone the repository.
2. Build the project in release mode.
3. Set up a cron job to run the bot daily.

### Cron Example
To run daily at 9:00 AM:
```bash
0 9 * * * cd /path/to/ios-feed && export OPENAI_API_KEY=... && export TELEGRAM_BOT_TOKEN=... && export TELEGRAM_CHANNEL_ID=... && ./.build/release/iOSFeedBot >> log.txt 2>&1
```
