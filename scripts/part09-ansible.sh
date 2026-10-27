#!/usr/bin/env bash
# Part 9: run the firewall playbook against a container with NET_ADMIN (its own network namespace).
set -uo pipefail
cd "$(dirname "$0")/../part09/ansible"
source ../../scripts/lib.sh
must docker run -d --name db1 --cap-add NET_ADMIN ubuntu:26.04 sleep infinity
must docker exec db1 bash -c "'apt-get update -q && apt-get install -y -q python3 python3-apt >/dev/null'"
capture p9-ansible-lint <<'CMD'
ansible-lint firewall.yml
CMD
capture p9-ansible-check <<'CMD'
ansible-playbook -i inventory.ini firewall.yml --check --diff
CMD
capture p9-ansible-apply <<'CMD'
ansible-playbook -i inventory.ini firewall.yml
CMD
capture p9-ansible-again <<'CMD'
ansible-playbook -i inventory.ini firewall.yml
CMD
capture p9-ansible-rules <<'CMD'
ansible -i inventory.ini db -b -m ansible.builtin.command -a 'nft list chain inet filter input'
CMD
