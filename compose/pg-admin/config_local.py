# pgAdmin local config, mounted read-only at /pgadmin4/config_local.py.
# Loaded after pgAdmin's defaults and the PGADMIN_CONFIG_* environment.
#
# Automatic login from Authelia's Remote-User header (no login page). pgAdmin
# accepts the header only when the TCP peer is Traefik's fixed address on
# proxy_internal (traefik.yaml); requests from anything else are refused.
# Never give pg.int.* a 'bypass' policy in Authelia: Traefik would then pass a
# client-supplied Remote-User straight through.

AUTHENTICATION_SOURCES = ['webserver']

WEBSERVER_REMOTE_USER = 'Remote-User'
WEBSERVER_REMOTE_USER_FROM_HEADER = True
# pgAdmin listens on [::], so Traefik's IPv4 address arrives IPv4-mapped.
WEBSERVER_TRUSTED_PROXIES = ['172.21.7.249/32', '::ffff:172.21.7.249/128']
WEBSERVER_AUTO_CREATE_USER = True
