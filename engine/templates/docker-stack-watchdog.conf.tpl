# Container watchdog settings.  Install to /etc/container-watchdog.conf (chmod 600)
# This file holds the Discord webhook, so keep it root-only and out of git.

DISCORD_WEBHOOK=""

# Where per-container state is kept (alert counters, down-since, last restart)
STATE_DIR="/var/lib/container-watchdog"

# How many log lines to attach to an alert
LOG_LINES=10

# Containers to ignore completely (extended regex on the container name).
# These are the throwaway names docker compose run / buildx create.
IGNORE_REGEX="(-run-[0-9a-f]{12}$|^buildx_)"

# ---------------------------------------------------------------- restarting

# yes = unhealthy container par khud "docker restart" chalao (wahi ID rehti hai)
# no  = kuch na karo, sirf alert bhejo
ENABLE_RESTART="yes"

# Ek hi container ko itne second ke andar dobara restart nahi karna.
# Alert phir bhi HAR DAFA jata hai - sirf restart ruka rehta hai.
# 120s rakha hai kyunki restart ke baad container ko start_period + ek probe
# ka waqt chahiye (~90-105s), to ye kisi jaiz restart ko nahi rokta.
RESTART_COOLDOWN=120

# Yeh containers kabhi auto-restart nahi honge - sirf alert aayega.
# Redis isme is liye hai ke usme data hai (13 sites ke session + cache).
# Agar aap chahein ke Redis bhi auto-restart ho, to yahan "" kar dein.
NO_RESTART_REGEX="(redis|nginx)"

# Itne containers ek saath toote = masla container mein nahi, BAHAR hai
# (MariaDB, disk, memory, network). Us surat mein ek summary alert jata hai
# aur KOI restart nahi hota.
MAX_PARALLEL_FAIL=8

# Mass-failure wala summary alert itne second mein ek baar se zyada nahi.
MASS_ALERT_EVERY=600

# docker events par kuch hone ke baad itna ruk kar dobara dekhna
# (taake restart:always ko apna kaam karne ka mauqa mil jaye).
EVENT_SETTLE=3

# Alert ke "Log:" block mein kaun si lines bhejni hain.
# Script pehle in lafzon wali lines dhoondti hai aur sirf wohi bhejti hai, taake
# alert mein aam traffic ki lines (jaise "request handled") na aayein. Agar ek
# bhi aisi line na mili to phir aakhri LOG_LINES lines bhej deti hai.
LOG_ERROR_REGEX="(error|exception|fatal|critical|fail|refus|timeout|timed out|denied|cannot|can.t|unable|panic|segfault|killed|out of memory|no such|not found|warning)"

# Jab koi container jaan-boojh kar band ya freeze kiya jaye - `docker stop`,
# `compose down`, ya `docker pause` - to script usay wapas chalu NAHI karegi:
# sirf ek dafa alert bhejegi aur chhod degi.
#   stop  : Docker khud apni state file mein likhta hai ke band insaan ne kiya
#           tha ya container mara tha; script wahi flag padhti hai.
#   pause : container khud ba khud kabhi paused nahi hota, to yeh hamesha kisi
#           ka faisla hota hai.
# Crash, OOM kill, ya exit 1 par purana behaviour chalta hai: alert + restart.
# "yes" kar dein to band/paused container bhi dobara chal padega.
RESTART_MANUALLY_STOPPED="no"
