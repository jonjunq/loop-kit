# Notifications

The harness and the usage guard notify about: features failing their way to a replan, replans, regressions, user-test
rounds, usage stops and relaunches, budget reached, waiting on usage limits for over an hour, the project finishing,
and the loop halting because it needs a human.

Every notification is appended to `logs/notify.log`. On top of that, configure any of these in `loopkit.env`:

## ntfy (simplest)

Install the ntfy app on your phone, subscribe to a long, unguessable topic name, and:

```bash
NTFY_TOPIC=myapp-7f3a9c1e2b
#NTFY_SERVER=https://ntfy.example.com    # if you self-host it
```

## Any command (`NOTIFY_CMD`)

`NOTIFY_CMD` is either a script, which gets the message as its argument, or an inline command that uses `"$1"` (e.g. `NOTIFY_CMD='logger -t loopkit "$1"'`). Ready-made scripts in `examples/notify/`:

| Script | Variables |
|---|---|
| `telegram.sh` | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (create a bot with @BotFather) |
| `discord.sh` | `DISCORD_WEBHOOK_URL` |
| `slack.sh` | `SLACK_WEBHOOK_URL` |
| `webhook.sh` | `WEBHOOK_URL` (POSTs JSON: project, message, time) |

```bash
NOTIFY_CMD="$HOME/loop-kit/examples/notify/telegram.sh"
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=123456789
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
```

Test it: `./loopkit/notify.sh "hello from the loop"`.

## Keeping tokens out of the sandbox

Anything in `loopkit.env` is readable by the agents. If that bothers you, leave `NOTIFY_CMD` empty and run
[`examples/remote-watch/loopkit-watch`](../examples/remote-watch/README.md) on a trusted machine: it reads each
project's `logs/notify.log` over SSH every two minutes, forwards what is new, tells you when a loop stops running or
a machine becomes unreachable, and sends a daily summary.
