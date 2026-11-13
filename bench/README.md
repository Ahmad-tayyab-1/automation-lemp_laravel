# bench: speed test, Ansible against bash

| File | What it is |
|---|---|
| `benchmark.sh ROUNDS` | deploys the same new project with three tools, then redeploys it, then removes it; the order rotates each round |
| `deploy-bash-minimal.sh` | the first bash comparison script: native, local, HTTP only, run on the server (one file, no templates) |
| `cleanup-site.sh DOMAIN` | removes a test site completely, native or Docker; refuses any domain except `bench-*.test` |
| `traffic.json` | the copy the minimal script reads |

The three tools:

| | Tool | Test site |
|---|---|---|
| A | `/opt/deployer/deploy.sh` (deploy.sh + Ansible) | bench-a.test |
| B | `deploy-bash-minimal.sh` | bench-b.test |
| C | `/opt/deployer-bash/deploy.sh` (deploy.sh + the bash engine) | bench-c.test |

Run it on a native_lemp server that has `/opt/deployer` and `/opt/deployer-bash`:

```bash
sudo /opt/deployer-bash/bench/benchmark.sh 3
```

Results go to `/root/bench/results.csv` (`round,tool,kind,seconds,exit code`), with one log per run. Step times are in the Ansible logs (profile_tasks) and in `C-*.timings`. The server's other sites are polled every second; the counts are printed at the end.
