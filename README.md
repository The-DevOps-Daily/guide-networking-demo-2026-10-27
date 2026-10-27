# Networking Fundamentals: companion repository

Lab script and test runs for the DevOps Daily guide
[Networking Fundamentals for Developers](https://devops-daily.com/guides/networking-fundamentals).

- `netlab.sh` builds the guide's practice network from Linux network namespaces on one machine:
  a client and a server on a stand-in internet (`203.0.113.0/24`), a router with NAT, a firewall
  and a DNS resolver, a load balancer, three app servers, a database stand-in and an authoritative
  DNS server. Run it on a throwaway Ubuntu 26.04 or 24.04 VM; Part 1 of the guide lists the packages.

  ```bash
  sudo ./netlab.sh up      # build the lab
  sudo ./netlab.sh status  # list the hosts and addresses
  sudo ./netlab.sh down    # remove everything it created
  ```

- `.github/workflows/guide.yml` runs `netlab.sh` with a smoke test on Ubuntu 24.04 and 26.04 runners,
  and runs the Docker, Kubernetes and automation commands shown in the guide, saving their output as
  artifacts. The guide's terminal output for those sections comes from these runs.

The files under `part06/` and later are copied from the guide, so what the guide shows is what ran.
