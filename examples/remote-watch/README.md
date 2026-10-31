# loopkit-watch: notifications without secrets in the sandbox

The agents run with broad permissions, so the safest place for a bot token is somewhere else. With `loopkit-watch`
the loop machine only writes `logs/notify.log`; a trusted machine (your server, a Raspberry Pi, your laptop) pulls
it over SSH every two minutes and forwards it. It also tells you when a loop stops or comes back, when the machine is
unreachable, and sends a daily summary.

```bash
cp loopkit-watch ~/.local/bin/ && chmod +x ~/.local/bin/loopkit-watch
mkdir -p ~/.config/loopkit-watch && cp projects.example ~/.config/loopkit-watch/projects   # edit it
cat > ~/.config/loopkit-watch/env <<'EOT'
SEND_CMD=/path/to/loop-kit/examples/notify/telegram.sh
export TELEGRAM_BOT_TOKEN=123456:ABC... TELEGRAM_CHAT_ID=123456789
EOT
chmod 600 ~/.config/loopkit-watch/env
loopkit-watch            # try it once (without SEND_CMD it prints to the terminal)
mkdir -p ~/.config/systemd/user && cp loopkit-watch.service loopkit-watch.timer ~/.config/systemd/user/
systemctl --user enable --now loopkit-watch.timer
```

Or with cron: `*/2 * * * * $HOME/.local/bin/loopkit-watch`.
