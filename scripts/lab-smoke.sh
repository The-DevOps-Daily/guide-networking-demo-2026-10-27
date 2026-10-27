#!/usr/bin/env bash
# Smoke test for netlab.sh on a real Ubuntu host: the paths every part of the guide relies on.
set -euo pipefail
on() { ip netns exec "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok    $what"; else fail "$what"; fi; }

check "client reaches the shop over HTTP" on client curl -sf -m 3 http://www.shop.example/
check "client reaches the shop over HTTPS" on client curl -sf -m 3 --cacert /etc/netlab/tls/ca.crt https://www.shop.example/
[ "$(on client dig +short www.shop.example | tail -n 1)" = 203.0.113.80 ] && echo "ok    public DNS" || fail "public DNS"
on client dig db.shop.internal | grep -q 'status: REFUSED' && echo "ok    private zone refused from the internet side" || fail "split view"
[ "$(on web1 dig +short db.shop.internal)" = 10.0.3.10 ] && echo "ok    private DNS" || fail "private DNS"
[ "$(on web1 dig +short -x 10.0.3.10)" = db.shop.internal. ] && echo "ok    reverse DNS" || fail "reverse DNS"
[ "$(on client dig @203.0.113.53 +short shop.example)" = 203.0.113.80 ] && echo "ok    published authoritative DNS" || fail "published DNS"
on web1 curl -sf -m 3 http://203.0.113.20/ >/dev/null
grep -q '^203.0.113.1 ' /run/netlab/log/remote-app.log && echo "ok    source NAT" || fail "source NAT"
check "conntrack lists the NAT entries" on router conntrack -L -p tcp
check "web2 reaches the database" on web2 nc -zv -w 3 db 5432
check "rndc reload" on ns1 rndc reload shop.example
check "tc netem" on router tc qdisc add dev p-client root netem delay 10ms
on router tc qdisc del dev p-client root
for h in web1 web2 web3; do check "lb reaches $h" on lb curl -sf -m 3 "http://$h:8080/health"; done
if ./netlab.sh up >/dev/null 2>&1; then fail "a second up was not refused"; else echo "ok    a second up is refused"; fi
[ "$(sort -u /run/netlab/namespaces | wc -l)" -eq 9 ] && echo "ok    nine namespaces registered" || fail "registry"
echo "all lab checks passed"
