#!/usr/bin/env bash
# netlab.sh: a practice network built from Linux network namespaces, for the
# DevOps Daily guide "Networking Fundamentals for Developers".
#
#   sudo ./netlab.sh up       build the network and start its services
#   sudo ./netlab.sh status   list the lab hosts and their addresses
#   sudo ./netlab.sh down     stop the services and remove everything the lab created
#
# Every lab host is a network namespace, so your own interfaces, routes and
# firewall are not changed. Run it on a throwaway Linux VM or cloud server.
set -euo pipefail

HOSTS=(client remote router lb web1 web2 web3 db ns1)
EXTRA=(ctr1 ctr2)                       # namespaces that Part 6 of the guide adds
CONF=/etc/netlab                        # configs, app and TLS files
RUN=/run/netlab                         # pid files
LOGS=$RUN/log                           # one log file per lab service
STATE=/var/lib/netlab                   # what this script created; survives a reboot
REGISTRY=$STATE/namespaces              # the namespaces it created
MANIFEST=$STATE/manifest                # the files and directories it created
MAGIC="# netlab manifest v1"
BIND_DIR=/etc/bind/netlab               # AppArmor lets named read only /etc/bind
BIND_WORK=/var/cache/bind/netlab        # ...and write only /var/cache/bind
UNBOUND_CONF=/etc/unbound/netlab.conf   # AppArmor lets unbound read only /etc/unbound

die() {
  echo "netlab: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run it as root: sudo $0 ${1:-up}"
}

need_tools() {
  local missing=() t
  for t in ip nft python3 curl openssl named named-checkzone unbound nginx; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing commands: ${missing[*]} (see the prerequisites in Part 1)"
}

ns_exists() { [ -e "/run/netns/$1" ]; }

# start NAME HOST COMMAND...: run a lab service in HOST's namespace, logging to $LOGS/NAME.log
start() {
  local name=$1 host=$2
  shift 2
  ip netns exec "$host" setsid "$@" >>"$LOGS/$name.log" 2>&1 </dev/null &
}

# wait_for HOST COMMAND...: retry a check inside HOST for up to 10 seconds
wait_for() {
  local host=$1 i
  shift
  for i in $(seq 1 50); do
    if ip netns exec "$host" "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  die "timed out in $host waiting for: $* (see $LOGS)"
}

# plug HOST BRIDGE ADDRESS GATEWAY: connect HOST to a router bridge with a veth pair
plug() {
  local host=$1 bridge=$2 addr=$3 gw=$4
  ip -n router link add "p-$host" type veth peer name eth0 netns "$host"
  ip -n router link set "p-$host" master "$bridge" up
  ip -n "$host" addr add "$addr" dev eth0
  ip -n "$host" link set eth0 up
  ip -n "$host" route add default via "$gw"
}

# register HOST: remember a namespace that this script created, so that "down" removes only those
register() { echo "$1" >>"$REGISTRY"; }

# created PATH: remember a file or directory that this script created
created() { echo "$1" >>"$MANIFEST"; }

# owned: true if $STATE holds a manifest that this script wrote
owned() { [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ "$(head -n 1 "$MANIFEST" 2>/dev/null)" = "$MAGIC" ]; }

# paths that only netlab creates; "up" refuses to start if any of them already exists
lab_paths() {
  local h
  echo "$STATE" "$CONF" "$RUN" "$BIND_DIR" "$BIND_WORK" "$UNBOUND_CONF"
  for h in "${HOSTS[@]}" "${EXTRA[@]}"; do echo "/etc/netns/$h"; done
}

write_files() {
  local d
  # up checked that none of these exist, so plain mkdir (no -p) fails if anything appears meanwhile
  mkdir -m 0700 "$STATE"
  echo "$MAGIC" >"$MANIFEST"
  cat /proc/sys/kernel/random/boot_id >"$STATE/boot_id"
  : >"$REGISTRY"
  for d in "$CONF" "$RUN" "$BIND_DIR"; do
    mkdir -m 0755 "$d"
    created "$d"
  done
  mkdir -m 0755 "$LOGS" "$CONF/tls"   # the keys in tls/ are chmod 600

  # named's working directory: AppArmor allows writes only under /var/cache/bind, which the bind
  # group can write to. So create it in one step with its final mode, hand it over without
  # following links, and never write into it as root.
  mkdir -m 0750 -- "$BIND_WORK"
  created "$BIND_WORK"
  chown -h bind:bind -- "$BIND_WORK"

  cat >"$CONF/app.py" <<'PY'
#!/usr/bin/env python3
"""Small services for the netlab hosts.
  app.py http NAME PORT   HTTP: /health answers "ok", /slow waits 2 s, anything else names the server
  app.py tcp NAME PORT    TCP: every connection gets one line, then the server closes it
"""
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def http(name, port):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def version_string(self):
            return 'netlab-app'

        def do_GET(self):
            self.respond(send_body=True)

        def do_HEAD(self):
            self.respond(send_body=False)

        def respond(self, send_body):
            if self.path == '/health':
                body = 'ok\n'
            elif self.path == '/slow':
                time.sleep(2)
                body = f'{name}: slow response\n'
            else:
                body = f'served by {name} ({self.connection.getsockname()[0]})\n'
            data = body.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if send_body:
                self.wfile.write(data)

        def log_message(self, fmt, *args):
            headers = getattr(self, 'headers', None)
            xff = headers.get('X-Forwarded-For', '-') if headers else '-'
            sys.stderr.write(f'{self.client_address[0]} xff={xff} {fmt % args}\n')
            sys.stderr.flush()

    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(('', port), Handler).serve_forever()


def tcp(name, port):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.sendall(f'{name}: ready\n'.encode())

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer.daemon_threads = True
    socketserver.ThreadingTCPServer(('', port), Handler).serve_forever()


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] not in ('http', 'tcp'):
        sys.exit('usage: app.py http|tcp NAME PORT')
    {'http': http, 'tcp': tcp}[sys.argv[1]](sys.argv[2], int(sys.argv[3]))
PY

  # A private certificate authority and a certificate for www.shop.example
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
    -subj "/CN=netlab CA" -keyout "$CONF/tls/ca.key" -out "$CONF/tls/ca.crt" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj "/CN=www.shop.example" -keyout "$CONF/tls/shop.key" -out "$CONF/tls/shop.csr" 2>/dev/null
  openssl x509 -req -in "$CONF/tls/shop.csr" -CA "$CONF/tls/ca.crt" -CAkey "$CONF/tls/ca.key" \
    -days 30 -out "$CONF/tls/shop.crt" \
    -extfile <(printf 'subjectAltName=DNS:www.shop.example,DNS:shop.example\nextendedKeyUsage=serverAuth\n') 2>/dev/null
  chmod 600 "$CONF/tls/ca.key" "$CONF/tls/shop.key"

  cat >"$CONF/lb-nginx.conf" <<'NGINX'
# nginx on lb: a reverse proxy in front of web1 (Part 5 turns it into a load balancer)
worker_processes 1;
pid /run/netlab/lb-nginx.pid;
error_log /run/netlab/log/lb-nginx-error.log;

events {
    worker_connections 256;
}

http {
    access_log /run/netlab/log/lb-nginx-access.log;

    server {
        listen 80;
        listen 443 ssl;
        http2 on;
        server_name www.shop.example shop.example;

        ssl_certificate     /etc/netlab/tls/shop.crt;
        ssl_certificate_key /etc/netlab/tls/shop.key;

        location / {
            proxy_pass http://10.0.2.11:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
NGINX

  # nginx before 1.25.1 (Ubuntu 24.04 ships 1.24) has no "http2 on;" and enables HTTP/2 on the listen line
  local v
  v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
  if printf '%s\n1.25.0\n' "$v" | sort -V -C; then
    sed -i -e 's/^        listen 443 ssl;$/        listen 443 ssl http2;/' -e '/^        http2 on;$/d' "$CONF/lb-nginx.conf"
  fi

  cat >"$CONF/router-nat.nft" <<'NFT'
# NAT on the router: the shop's public address and outbound access for the private subnets
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip daddr 203.0.113.80 tcp dport { 80, 443 } dnat to 10.0.1.10
        ip daddr 203.0.113.53 meta l4proto { tcp, udp } th dport 53 dnat to 10.0.3.53
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.0.0.0/16 oifname "br-wan" masquerade
    }
}
NFT

  cat >"$BIND_DIR/named.conf" <<'BIND'
// BIND on ns1: authoritative for the lab zones, no recursion
options {
    directory "/var/cache/bind/netlab";
    pid-file none;
    listen-on { 10.0.3.53; 127.0.0.1; };
    listen-on-v6 { none; };
    recursion no;
    allow-transfer { none; };
    dnssec-validation no;
    notify no;
};

zone "shop.example" {
    type primary;
    file "/etc/bind/netlab/db.shop.example";
};

// the private zones answer only the lab's own networks
zone "shop.internal" {
    type primary;
    file "/etc/bind/netlab/db.shop.internal";
    allow-query { 10.0.0.0/16; 127.0.0.1; };
};

zone "0.10.in-addr.arpa" {
    type primary;
    file "/etc/bind/netlab/db.10.0";
    allow-query { 10.0.0.0/16; 127.0.0.1; };
};
BIND

  cat >"$BIND_DIR/db.shop.example" <<'ZONE'
; shop.example: the public names
$TTL 300
@        IN SOA   ns1.shop.example. hostmaster.shop.example. (
                  2026102701 ; serial
                  3600       ; refresh
                  600        ; retry
                  604800     ; expire
                  60 )       ; negative caching TTL
         IN NS    ns1.shop.example.
         IN A     203.0.113.80
         IN MX    10 mail.shop.example.
         IN TXT   "v=spf1 mx -all"
         IN CAA   0 issue "letsencrypt.org"
ns1      IN A     203.0.113.53
www      IN CNAME shop.example.
mail     IN A     203.0.113.25
ZONE

  cat >"$BIND_DIR/db.shop.internal" <<'ZONE'
; shop.internal: the private names
$TTL 60
@        IN SOA   ns1.shop.internal. hostmaster.shop.example. (
                  2026102701 3600 600 604800 60 )
         IN NS    ns1.shop.internal.
ns1      IN A     10.0.3.53
lb       IN A     10.0.1.10
web1     IN A     10.0.2.11
web2     IN A     10.0.2.12
web3     IN A     10.0.2.13
db       IN A     10.0.3.10
api      IN CNAME web1.shop.internal.
_postgresql._tcp IN SRV 0 0 5432 db.shop.internal.
ZONE

  cat >"$BIND_DIR/db.10.0" <<'ZONE'
; reverse lookups for 10.0.0.0/16
$TTL 60
@        IN SOA   ns1.shop.internal. hostmaster.shop.example. (
                  2026102701 3600 600 604800 60 )
         IN NS    ns1.shop.internal.
10.1     IN PTR   lb.shop.internal.
11.2     IN PTR   web1.shop.internal.
12.2     IN PTR   web2.shop.internal.
13.2     IN PTR   web3.shop.internal.
10.3     IN PTR   db.shop.internal.
53.3     IN PTR   ns1.shop.internal.
ZONE

  created "$UNBOUND_CONF"
  cat >"$UNBOUND_CONF" <<'UNBOUND'
# Unbound on router: the caching resolver that every lab host uses
server:
    interface: 127.0.0.1
    interface: 203.0.113.1
    interface: 10.0.1.1
    interface: 10.0.2.1
    interface: 10.0.3.1
    access-control: 10.0.0.0/16 allow
    access-control: 203.0.113.0/24 allow
    do-ip6: no
    username: ""
    chroot: ""
    directory: "/etc/unbound"
    use-syslog: no
    logfile: ""
    module-config: "iterator"
    # unbound answers 10.x reverse lookups locally by default; send them to ns1 instead
    local-zone: "10.in-addr.arpa." nodefault
    # client and remote stand for the internet: they must not see the private names
    access-control-view: 203.0.113.0/24 internet

view:
    name: "internet"
    local-zone: "shop.internal." refuse
    local-zone: "10.in-addr.arpa." refuse

stub-zone:
    name: "shop.example"
    stub-addr: 10.0.3.53
stub-zone:
    name: "shop.internal"
    stub-addr: 10.0.3.53
stub-zone:
    name: "0.10.in-addr.arpa"
    stub-addr: 10.0.3.53
UNBOUND
}

up() {
  need_root up
  need_tools
  local h p
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    owned || die "$STATE exists but netlab did not create it; move it away first"
    die "the lab is already up (or was, before a reboot): run 'sudo $0 down' first"
  fi
  for h in "${HOSTS[@]}" "${EXTRA[@]}"; do
    ! ns_exists "$h" || die "a namespace called $h already exists and netlab did not create it; remove it first (sudo ip netns del $h)"
  done
  for p in $(lab_paths); do
    [ ! -e "$p" ] && [ ! -L "$p" ] || die "$p already exists and netlab did not create it; move it away first"
  done
  trap 'rc=$?; [ "$rc" -eq 0 ] || echo "netlab: setup failed; clean up with: sudo $0 down" >&2' EXIT

  write_files
  named-checkzone -q shop.example "$BIND_DIR/db.shop.example"
  named-checkzone -q shop.internal "$BIND_DIR/db.shop.internal"
  named-checkzone -q 0.10.in-addr.arpa "$BIND_DIR/db.10.0"

  for h in "${HOSTS[@]}"; do
    ip netns add "$h"
    register "$h"
    ip -n "$h" link set lo up
    mkdir -p /etc/netns
    mkdir -m 0755 "/etc/netns/$h"
    created "/etc/netns/$h"
  done

  # the router: one bridge (switch) per subnet, forwarding on
  local br
  for br in br-wan br-edge br-app br-data; do
    ip -n router link add "$br" type bridge
    ip -n router link set "$br" up
  done
  ip -n router addr add 203.0.113.1/24 dev br-wan
  ip -n router addr add 203.0.113.80/24 dev br-wan    # the shop's public address
  ip -n router addr add 203.0.113.53/24 dev br-wan    # public address of the DNS server ns1
  ip -n router addr add 10.0.1.1/24 dev br-edge
  ip -n router addr add 10.0.2.1/24 dev br-app
  ip -n router addr add 10.0.3.1/24 dev br-data
  ip netns exec router sysctl -qw net.ipv4.ip_forward=1
  # if br_netfilter is loaded (Docker loads it), keep bridged traffic out of the router's firewall
  ip netns exec router sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true

  plug client br-wan 203.0.113.10/24 203.0.113.1
  plug remote br-wan 203.0.113.20/24 203.0.113.1
  plug lb br-edge 10.0.1.10/24 10.0.1.1
  plug web1 br-app 10.0.2.11/24 10.0.2.1
  plug web2 br-app 10.0.2.12/24 10.0.2.1
  plug web3 br-app 10.0.2.13/24 10.0.2.1
  plug db br-data 10.0.3.10/24 10.0.3.1
  plug ns1 br-data 10.0.3.53/24 10.0.3.1
  ip netns exec router nft -f "$CONF/router-nat.nft"

  # DNS settings: "ip netns exec" mounts /etc/netns/HOST/resolv.conf over /etc/resolv.conf
  printf 'nameserver 203.0.113.1\n' >/etc/netns/client/resolv.conf
  printf 'nameserver 203.0.113.1\n' >/etc/netns/remote/resolv.conf
  printf 'nameserver 127.0.0.1\n' >/etc/netns/router/resolv.conf
  printf 'nameserver 10.0.1.1\nsearch shop.internal\n' >/etc/netns/lb/resolv.conf
  for h in web1 web2 web3; do
    printf 'nameserver 10.0.2.1\nsearch shop.internal\n' >"/etc/netns/$h/resolv.conf"
  done
  printf 'nameserver 10.0.3.1\nsearch shop.internal\n' >/etc/netns/db/resolv.conf
  printf 'nameserver 10.0.3.1\nsearch shop.internal\n' >/etc/netns/ns1/resolv.conf

  # services
  # -u bind: named drops to the bind user, like the packaged service (it needs to read rndc.key)
  start ns1-named ns1 named -g -u bind -c "$BIND_DIR/named.conf"
  start router-unbound router unbound -d -p -c "$UNBOUND_CONF"
  for h in web1 web2 web3; do
    start "$h-app" "$h" python3 "$CONF/app.py" http "$h" 8080
  done
  start db-app db python3 "$CONF/app.py" tcp db 5432
  start remote-app remote python3 "$CONF/app.py" http remote 80
  start lb-nginx lb nginx -c "$CONF/lb-nginx.conf" -e "$LOGS/lb-nginx-error.log" -g 'daemon off;'

  for h in web1 web2 web3; do
    wait_for lb curl -sf -m 1 "http://10.0.2.1${h#web}:8080/health"
  done
  wait_for lb curl -sf -m 1 http://127.0.0.1/health
  wait_for client curl -sf -m 1 http://www.shop.example/health
  trap - EXIT

  cat <<EOF
netlab is up. Hosts and addresses:
  client   203.0.113.10                 a user on the internet
  remote   203.0.113.20                 a web server on the internet (port 80)
  router   203.0.113.1                  the gateway: routing, NAT, firewall, DNS resolver
           10.0.1.1, 10.0.2.1, 10.0.3.1 (public: 203.0.113.80 for lb, 203.0.113.53 for ns1)
  lb       10.0.1.10                    nginx on ports 80 and 443 (public: 203.0.113.80)
  web1-3   10.0.2.11, .12, .13          the app on port 8080
  db       10.0.3.10                    a database stand-in on port 5432
  ns1      10.0.3.53                    authoritative DNS for shop.example and shop.internal
Run a command on a lab host:  sudo ip netns exec client curl http://www.shop.example/
EOF
}

# same_boot: true if the namespaces in the registry were created since the last reboot
# (namespaces do not survive a reboot; a namespace with a lab name after one is not ours)
same_boot() { [ "$(cat "$STATE/boot_id" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id)" ]; }

# lab_hosts: the registered namespaces whose names belong to the lab (HOSTS or EXTRA)
lab_hosts() {
  local h known
  [ -f "$REGISTRY" ] || return 0
  sort -u "$REGISTRY" | while read -r h; do
    for known in "${HOSTS[@]}" "${EXTRA[@]}"; do
      if [ "$h" = "$known" ]; then echo "$h"; fi
    done
  done
}

status() {
  local h
  owned && same_boot || { echo "netlab is not up."; return 0; }
  for h in $(lab_hosts); do
    if ns_exists "$h"; then
      echo "== $h"
      ip -n "$h" -br addr show | grep -v '^lo ' || true
    fi
  done
}

down() {
  need_root down
  local h i p
  if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
    echo "netlab: no lab state in $STATE, nothing to remove."
    return 0
  fi
  owned || die "$STATE was not created by netlab.sh; nothing removed"
  for h in $(lab_hosts); do
    if same_boot && ns_exists "$h"; then
      ip netns pids "$h" | xargs -r kill 2>/dev/null || true
      for i in $(seq 1 25); do
        [ -z "$(ip netns pids "$h")" ] && break
        sleep 0.2
      done
      ip netns pids "$h" | xargs -r kill -9 2>/dev/null || true
      ip netns del "$h"
    fi
  done
  # remove only what the manifest lists, newest first, and only paths that belong to the lab
  tail -n +2 "$MANIFEST" | tac | while read -r p; do
    case " $(lab_paths | tr '\n' ' ') " in
      *" $p "*) rm -rf -- "$p" ;;
    esac
  done
  rm -rf -- "$STATE"
  echo "netlab is down."
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *)
    echo "usage: sudo $0 up|status|down" >&2
    exit 2
    ;;
esac
