#!/bin/sh
# Modlight server: install or update with Docker Compose, then show how to connect.
#
#   curl -fsSL https://raw.githubusercontent.com/LOGIN-TB/modlight/main/server/install.sh | sh
#
# `docker compose up -d` starts the container in the background and never shows its log, so the
# box with address and pairing code stays out of sight. This script pulls the current image,
# starts the server, waits until it answers and prints the box.
#
# It works in the current folder when its compose file already holds the Modlight server, and
# otherwise in ./modlight, where it puts the compose file from the repository. Running it again
# updates the server; the data volume and the pairing stay.
#
# Optional, as environment variables:
#   MODLIGHT_DIR   the folder to use
#   MODLIGHT_LANG  de or en for the box (default: from LANG)
#   HOST_IP        this machine's address in your network (default: found out, private ones only)
#
# Everything is wrapped in main() so that `curl … | sh` reads the whole script before running it.

main() {
  set -eu

  RAW=${MODLIGHT_RAW:-https://raw.githubusercontent.com/LOGIN-TB/modlight/main/server}
  SERVICE=${MODLIGHT_SERVICE:-modlight}

  case "${MODLIGHT_LANG:-${LC_ALL:-${LANG:-}}}" in de*) LANGUAGE=de ;; *) LANGUAGE=en ;; esac

  command -v docker >/dev/null 2>&1 || fail "Docker is not installed. See https://docs.docker.com/engine/install/" \
                                            "Docker ist nicht installiert. Siehe https://docs.docker.com/engine/install/"
  if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
  else fail "Docker Compose is missing (the docker-compose-plugin package)." \
            "Docker Compose fehlt (Paket docker-compose-plugin)."
  fi
  docker info >/dev/null 2>&1 || fail "Docker does not answer. Is it running, and may this user use it (root or the docker group)?" \
                                      "Docker antwortet nicht. Läuft es, und darf dieser Benutzer es nutzen (root oder Gruppe docker)?"

  # The folder: given, here when this compose file already runs Modlight, otherwise ./modlight.
  if [ -n "${MODLIGHT_DIR:-}" ]; then dir=$MODLIGHT_DIR
  elif compose_file . >/dev/null; then dir=.
  else dir=./modlight
  fi
  mkdir -p "$dir"
  cd "$dir"
  if ! compose_file . >/dev/null; then
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      [ -f "$f" ] && fail "$(pwd)/$f belongs to something else. Choose another folder with MODLIGHT_DIR=…" \
                          "$(pwd)/$f gehört zu etwas anderem. Wähle mit MODLIGHT_DIR=… einen anderen Ordner."
    done
    say "Fetching docker-compose.yml into $(pwd) …" "Lade docker-compose.yml nach $(pwd) …"
    download "$RAW/docker-compose.yml" docker-compose.yml
  fi

  # A language chosen at an earlier run stays, unless MODLIGHT_LANG says otherwise now.
  if [ -z "${MODLIGHT_LANG:-}" ]; then
    case "$(env_value MODLIGHT_LANG)" in de) LANGUAGE=de ;; en) LANGUAGE=en ;; esac
  fi

  # The address in your network: the container cannot see it, so it goes into .env as HOST_IP.
  host_ip=${HOST_IP:-$(env_value HOST_IP)}
  [ -n "$host_ip" ] || host_ip=$(private_ip)
  [ -n "$host_ip" ] && set_env HOST_IP "$host_ip"
  set_env MODLIGHT_LANG "$LANGUAGE"

  say "Fetching the current Modlight server image …" "Lade das aktuelle Image des Modlight-Servers …"
  $COMPOSE pull "$SERVICE" </dev/null
  $COMPOSE up -d </dev/null

  say "Waiting for the server to answer …" "Warte, bis der Server antwortet …"
  tries=0
  until $COMPOSE exec -T "$SERVICE" node -e \
      "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      </dev/null >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 90 ]; then
      $COMPOSE logs --tail 40 "$SERVICE" </dev/null || true
      fail "The server did not answer within 90 seconds; its log is above." \
           "Der Server hat nach 90 Sekunden nicht geantwortet; sein Log steht oben."
    fi
    sleep 1
  done

  # The box, with what only the host knows: its address and the port it publishes.
  published=$($COMPOSE port "$SERVICE" 8080 </dev/null 2>/dev/null | head -n 1 | sed 's/.*://') || published=""
  set -- -e "MODLIGHT_LANG=$LANGUAGE"
  [ -n "$host_ip" ] && set -- "$@" -e "HOST_IP=$host_ip"
  [ -n "$published" ] && set -- "$@" -e "HOST_PORT=$published"
  printf '\n'
  $COMPOSE exec -T "$@" "$SERVICE" modlight-info </dev/null \
    || fail "This server image is older than 0.8.0 and has no modlight-info. Check the image line in the compose file." \
            "Dieses Server-Image ist älter als 0.8.0 und kennt modlight-info nicht. Prüfe die image-Zeile in der Compose-Datei."
  printf '\n'
  say "Show this again:  cd $(pwd) && $COMPOSE exec $SERVICE modlight-info" \
      "Erneut anzeigen:  cd $(pwd) && $COMPOSE exec $SERVICE modlight-info"
  say "New pairing code: cd $(pwd) && $COMPOSE exec $SERVICE modlight-code" \
      "Neuer Kopplungscode: cd $(pwd) && $COMPOSE exec $SERVICE modlight-code"
}

say() { if [ "$LANGUAGE" = de ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
fail() { say "modlight: $1" "modlight: $2" >&2; exit 1; }

# Prints the compose file in $1 that runs the Modlight server image; fails when there is none.
compose_file() {
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$1/$f" ] && grep -q 'modlight-server' "$1/$f"; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

download() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else fail "Neither curl nor wget is installed." "Weder curl noch wget ist installiert."
  fi
}

env_value() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -n 1 || true; }

# Adds KEY=value to .env unless KEY is there already: what someone set by hand stays.
set_env() {
  if [ -f .env ] && grep -q "^$1=" .env; then return 0; fi
  printf '%s=%s\n' "$1" "$2" >> .env
}

# The address this machine uses towards the internet, when it is a private one (10/8,
# 172.16/12, 192.168/16): a public address would be offered as plain http, which the app refuses.
private_ip() {
  ip=$( (ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}') || true)
  [ -n "$ip" ] || ip=$( (hostname -I 2>/dev/null | awk '{print $1}') || true)
  case "$ip" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) printf '%s\n' "$ip" ;;
  esac
}

LANGUAGE=en
main "$@"
