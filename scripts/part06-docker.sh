#!/usr/bin/env bash
# Part 6: Docker networking. Runs on a fresh GitHub-hosted Ubuntu 26.04 runner.
set -uo pipefail
cd "$(dirname "$0")/../part06"
source ../scripts/lib.sh

# pull first, so that no pull progress ends up in the captured output
for img in traefik/whoami:v1.12.0 busybox:1.38 alpine:3.24 nginx:1.30-alpine postgres:18-alpine; do
  must docker pull -q "$img"
done

capture p6-docker-version <<'CMD'
docker version --format '{{.Server.Version}}'
CMD
capture p6-docker-ls <<'CMD'
docker network ls
CMD
capture p6-docker-create <<'CMD'
docker network create shop
CMD
capture p6-docker-inspect <<'CMD'
docker network inspect shop --format '{{json .IPAM.Config}}'
CMD
capture p6-docker-run-api <<'CMD'
docker run -d --name api --network shop traefik/whoami:v1.12.0
CMD
capture p6-docker-resolv <<'CMD'
docker run --rm --network shop busybox:1.38 cat /etc/resolv.conf
CMD
capture p6-docker-dns <<'CMD'
docker run --rm --network shop alpine:3.24 getent hosts api
CMD
capture p6-docker-wget <<'CMD'
docker run --rm --network shop busybox:1.38 wget -qO- http://api
CMD
capture p6-docker-run-default <<'CMD'
docker run -d --name api-default traefik/whoami:v1.12.0
CMD
capture p6-docker-default-dns <<'CMD'
docker run --rm alpine:3.24 getent hosts api-default || echo "api-default: not found"
CMD
capture p6-docker-run-web <<'CMD'
docker run -d --name web -p 127.0.0.1:8080:80 traefik/whoami:v1.12.0
CMD
must 'for i in $(seq 30); do curl -sf -o /dev/null http://127.0.0.1:8080/ && break; sleep 1; done'
capture p6-docker-port <<'CMD'
docker port web
CMD
capture p6-docker-curl <<'CMD'
curl -s http://127.0.0.1:8080/ | grep -E '^(Hostname|IP: 172|RemoteAddr)'
CMD
capture p6-docker-ss <<'CMD'
sudo ss -tlnp 'sport = :8080'
CMD
capture p6-docker-nat <<'CMD'
sudo iptables -t nat -S DOCKER
CMD
capture p6-docker-create-internal <<'CMD'
docker network create --internal backend
CMD
capture p6-docker-internal 1 <<'CMD'
docker run --rm --network backend busybox:1.38 wget -T 3 -qO- http://example.com
CMD
capture p6-docker-internal-ip 1 <<'CMD'
docker run --rm --network backend busybox:1.38 wget -T 3 -qO- http://1.1.1.1
CMD
capture p6-docker-nsenter <<'CMD'
sudo nsenter -t "$(docker inspect -f '{{.State.Pid}}' web)" -n ss -tln
CMD

cd shop
capture p6-compose-up <<'CMD'
docker compose up -d --quiet-pull
CMD
capture p6-compose-front <<'CMD'
docker run --rm --network shop_front alpine:3.24 getent hosts db || echo "db: not found"
CMD
capture p6-compose-back <<'CMD'
docker run --rm --network shop_back alpine:3.24 getent hosts db
CMD
must docker compose down
cd ..

capture p6-docker-validate <<'CMD'
sudo dockerd --validate --config-file daemon.json
CMD
finish
