# iOS Feed Bot Implementation Plan

## Background & Motivation
The goal is to create an automated workflow that publishes the most interesting iOS development article of the day to a public Telegram channel. It aims to source articles from the iOS Dev Directory, evaluate articles from the last 24 hours, use an LLM (OpenAI) to select the best one and generate a post, and publish it automatically.

## Scope & Impact
- **In Scope:** 
  - A stateless Swift CLI tool executed via cron.
  - Fetching the list of blogs from iOS Dev Directory.
  - Parsing RSS/Atom feeds to extract posts from the last 24 hours.
  - Integration with the OpenAI API to score/select the best article and generate a formatted Telegram post.
  - Integration with the Telegram Bot API to publish the generated message.
- **Out of Scope:**
  - Creating the Telegram bot/channel itself (assumed already configured).
  - Setting up the Hetzner VPS environment from scratch (assumed already available, though deployment scripts will be needed).
  - An always-on daemon or chat-based commands.

## Proposed Solution
A standalone Swift Package Manager (SPM) executable project. 
It will use:
- `URLSession` for network requests to fetch the blog directory and feeds.
- A feed parsing library (like `FeedKit`) to handle RSS/Atom normalization.
- A lightweight HTTP client to interact with the OpenAI API (using structured prompting to return the best article).
- The Telegram Bot API to send the final post.

### Flow
1. **Fetch Sources:** Download the list of blogs (e.g., from `iosdevdirectory` data/JSON).
2. **Parse Feeds:** Concurrently download and parse RSS feeds for all blogs.
3. **Filter:** Discard articles older than 24 hours.
4. **AI Selection & Generation:** Pass the list of recent articles (Titles + Links + Summaries) to OpenAI API. Ask it to choose the single most interesting and generate a Telegram post (Title, Short Summary, Hashtags).
5. **Publish:** Send the generated post to the Telegram Channel using the Bot API token and Chat ID.

## Alternatives Considered
- **Always-on Daemon:** Rejected in favor of a simpler Cron-based CLI tool, which is stateless, consumes no resources while idle, and is easier to maintain.
- **Node.js/Python Scripts:** Rejected based on user preference to use Swift for this iOS-related project.

## Implementation Plan
- **Phase 1: Project Setup**
  - Initialize the Swift executable package.
  - Set up dependency for FeedKit (for RSS parsing).
- **Phase 2: Data Ingestion**
  - Implement logic to fetch the blog list from iOS Dev Directory.
  - Implement concurrent RSS feed fetching and parsing.
  - Add logic to filter articles strictly by the last 24 hours.
- **Phase 3: AI Integration**
  - Create the OpenAI API client.
  - Craft the prompt to input the recent articles and output the formatted selection.
- **Phase 4: Telegram Publishing**
  - Create the Telegram API client to send the post to the specified channel.
- **Phase 5: Configuration & Deployment**
  - Add `.env` or environment variable support for Secrets (OpenAI Key, Telegram Bot Token, Channel ID).
  - Document the cron setup for the Hetzner VPS.

## Verification
- Run the tool locally with a dry-run flag (print output instead of posting to Telegram).
- Ensure the selected article is genuinely from the last 24 hours.
- Verify the generated output formatting.

## Migration & Rollback
- No data migration is necessary as the tool is stateless.
- Rollback involves simply disabling the cron job on the VPS.
