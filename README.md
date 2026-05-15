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
- `METRICS_DB_PATH`: SQLite metrics database path. Defaults to `.build/metrics.sqlite`.
- `OPENAI_INPUT_PRICE_PER_1M_TOKENS`: Input token price used for dashboard cost estimates.
- `OPENAI_OUTPUT_PRICE_PER_1M_TOKENS`: Output token price used for dashboard cost estimates.
- `DASHBOARD_USERNAME`: Basic auth username for the metrics dashboard.
- `DASHBOARD_PASSWORD`: Basic auth password for the metrics dashboard.
- `DASHBOARD_HOST`: Dashboard bind host. Defaults to `0.0.0.0`.
- `DASHBOARD_PORT`: Dashboard port. Defaults to `8080`.

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

## Metrics Dashboard
The bot records each run to SQLite. Start the dashboard as a long-running process:

```bash
export METRICS_DB_PATH=/root/ios-feed/metrics.sqlite
export DASHBOARD_USERNAME=your_user
export DASHBOARD_PASSWORD=your_password
export DASHBOARD_HOST=0.0.0.0
export DASHBOARD_PORT=8080
./.build/release/iOSFeedDashboard
```

Open `http://89.167.48.211:8080` and sign in with the configured Basic auth credentials. The page refreshes metrics every 5 seconds.

Example systemd unit:

```ini
[Unit]
Description=iOS Feed Metrics Dashboard
After=network.target

[Service]
WorkingDirectory=/root/ios-feed
Environment=METRICS_DB_PATH=/root/ios-feed/metrics.sqlite
Environment=DASHBOARD_USERNAME=your_user
Environment=DASHBOARD_PASSWORD=your_password
Environment=DASHBOARD_HOST=0.0.0.0
Environment=DASHBOARD_PORT=8080
ExecStart=/root/ios-feed/.build/release/iOSFeedDashboard
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
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
