# VPS traffic forwarding

## English

The script forwards TCP/UDP ports `443`, `8443`, and `10000–60000` from an Ubuntu/Debian VPS to your destination server using UFW.

Replace `YOUR_ORIGIN_IP` with your destination server's IPv4 address, then run this command in an SSH session on the forwarding VPS:

```bash
f=$(mktemp) && curl -fsSLo "$f" https://raw.githubusercontent.com/ant1k-1/vps-traffic-forwarding/main/forwarding-install.sh && sudo env ORIGIN_IP=YOUR_ORIGIN_IP SSH_PORT="${SSH_CONNECTION##* }" bash "$f"
```

If you are logged in as `root` and `sudo` is unavailable, replace `sudo env` with `env`. The VPS provider's external firewall must also allow the forwarded ports.

## Русский

Скрипт настраивает на VPS с Ubuntu/Debian перенаправление TCP/UDP портов `443`, `8443` и `10000–60000` на ваш целевой сервер через UFW.

Замените `YOUR_ORIGIN_IP` на IPv4-адрес целевого сервера и запустите команду в SSH-сессии на VPS, который будет перенаправлять трафик:

```bash
f=$(mktemp) && curl -fsSLo "$f" https://raw.githubusercontent.com/ant1k-1/vps-traffic-forwarding/main/forwarding-install.sh && sudo env ORIGIN_IP=YOUR_ORIGIN_IP SSH_PORT="${SSH_CONNECTION##* }" bash "$f"
```

Если вы вошли как `root` и `sudo` отсутствует, замените `sudo env` на `env`. Во внешнем файрволе провайдера VPS тоже должны быть разрешены перенаправляемые порты.

