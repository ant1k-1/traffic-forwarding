# VPS traffic forwarding

## English

An IPv4 NAT relay for VLESS: TCP/UDP ports `443`, `8443` and `10000–60000` are forwarded to the same ports on your destination server. Uses DNAT + SNAT, global `FORWARD ACCEPT`, TCPMSS clamping and `fq` queues; an existing `mq` queue tree is preserved.

Requires a **fresh Ubuntu/Debian VPS with systemd and one network interface carrying a global-scope IPv4 address** (a private address behind the provider's NAT is supported). The destination and the VPS's local IPv4 address must remain unchanged. Existing firewall/relay configurations are rejected; changing the destination requires a fresh installation. BBR, socket buffers and conntrack limits are not changed.

Install `curl` if needed. Replace `YOUR_ORIGIN_IP` with the destination IPv4 address and run in an SSH session on the relay VPS:

```bash
f=$(mktemp) && curl -fsSLo "$f" https://raw.githubusercontent.com/ant1k-1/traffic-forwarding/main/forwarding-install.sh && sudo env ORIGIN_IP=YOUR_ORIGIN_IP SSH_PORT="${SSH_CONNECTION##* }" bash "$f" && rm -f "$f"
```

If logged in as `root`, replace `sudo env` with `env`. Outside an SSH session, explicitly set `SSH_PORT` to the actual SSH port. Installation stops if that port overlaps the forwarded ports. If SSH listens on additional ports, allow them separately before enabling UFW.

Rules, IPv4 forwarding and `fq` persist across VPS restarts. A small systemd service applies `fq` after networking starts. The installer checks the applied configuration and saves a diagnostic backup under `/var/backups/traffic-forwarding.*`; it does not reboot the VPS. Allow the forwarded ports in your provider's external firewall and on the destination server. NAT hides client IP addresses from the destination.

## Русский

IPv4 NAT-мост для VLESS: TCP/UDP порты `443`, `8443` и `10000–60000` перенаправляются на те же порты целевого сервера. Используются DNAT + SNAT, глобальный `FORWARD ACCEPT`, TCPMSS clamp и очередь `fq`; существующая структура очередей `mq` сохраняется.

Нужна **чистая VPS с Ubuntu/Debian, systemd и одним основным IPv4-интерфейсом** (частный адрес за NAT провайдера поддерживается). Адрес назначения и локальный IPv4-адрес VPS должны оставаться неизменными. При существующей настройке файрвола или перенаправления установщик останавливается; смена адреса назначения требует новой установки. BBR, буферы сокетов и лимиты conntrack не меняются.

При необходимости установите `curl`. Замените `YOUR_ORIGIN_IP` на IPv4 целевого сервера и выполните команду в SSH-сессии на VPS-мосте:

```bash
f=$(mktemp) && curl -fsSLo "$f" https://raw.githubusercontent.com/ant1k-1/traffic-forwarding/main/forwarding-install.sh && sudo env ORIGIN_IP=YOUR_ORIGIN_IP SSH_PORT="${SSH_CONNECTION##* }" bash "$f" && rm -f "$f"
```

При входе под `root` замените `sudo env` на `env`. При запуске вне SSH-сессии явно укажите реальный порт в `SSH_PORT`. Если он пересекается с портами перенаправления, установка остановится. Если SSH слушает дополнительные порты, разрешите их отдельно до включения UFW.

Правила, IPv4 forwarding и `fq` сохраняются после перезапуска VPS. Небольшой сервис systemd применяет `fq` после запуска сети. Установщик проверяет применённые настройки и сохраняет диагностическую копию в `/var/backups/traffic-forwarding.*`; VPS автоматически не перезагружается. Разрешите перенаправляемые порты во внешнем файрволе провайдера и на целевом сервере. Из-за NAT целевой сервер видит адрес моста вместо IP клиента.
