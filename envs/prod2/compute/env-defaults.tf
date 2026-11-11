# The plain-environment DEFAULTS (variables.tf's *_env maps are merged on top). Values only — never a secret.

locals {
  default_cms_server_env = {
    NODE_ENV                = "production"
    APP_ENV                 = "production"
    HOST                    = "0.0.0.0"
    PORT                    = "8090"
    LOG_LEVEL               = "info"
    SITE_URL                = "https://www.gkoi.com"
    TRUST_PROXY             = "loopback"     # the task's own nginx on 127.0.0.1
    DB_NAME                 = "aisolver_cms" # from prod (2026-11-11)
    DB_USER                 = "cms"          # from prod (2026-11-11)
    PGSSLMODE               = "require"      # verify-full needs the RDS CA bundle in the image (README "TLS to RDS")
    CONTENT_DIR             = "/data/content"
    NGINX_CACHE_DIR         = "/data/nginx-cache"
    SESSION_COOKIE_NAME     = "__Host-gkoi_session" # from prod (2026-11-11)
    MIKAIDO_ENGINE_URL      = "https://engine.gkoi.com"
    FILES_SERVICE_URL       = "https://files.gkoi.com"
    APP_SERVICE_PUBLIC_URLS = "{\"mikaido\":\"https://engine.gkoi.com\",\"files\":\"https://files.gkoi.com\"}"
    LABS_COUNTRY_HEADER     = "cloudfront"
    SMTP_HOST               = ""              # from prod (2026-11-11)
    SMTP_PORT               = ""              # from prod (2026-11-11)
    SMTP_USER               = ""              # from prod (2026-11-11)
    MAIL_FROM               = ""              # from prod (2026-11-11)
    MAIL_DEV_LOG_ONLY       = "1"             # as prod: no SMTP yet, sign-in codes go to the log (unset once SMTP is set)
    CMS_TESTNET_AREAS       = "coins,gallery" # from prod (/opt/aisolver-www/.env, 2026-11-11; audit B4-5)
  }

  default_cms_nginx_env = {
    SITE_HOST           = "www.gkoi.com"
    SITE_APEX           = "gkoi.com"
    CMS_UPSTREAM        = "127.0.0.1:8090"
    CMS_RESOLVER        = "169.254.169.253"
    CMS_REALIP_MODE     = "cloudfront"
    CMS_CONTENT_DIR     = "/data/content"
    LABS_COUNTRY_HEADER = "cloudfront"
    LABS_HOST           = "labs.gkoi.com"
    LABS_ORIGIN_HOST    = "origin-labs.gkoi.com" # the labs CDN sends this Host (audit B4-3; CMS 9d222b28)
    CSP_CDN_ORIGIN      = "https://cdn.gkoi.com"
    CSP_LIVE_CDN_ORIGIN = "https://live.gkoi.com"
    PRODUCT_NAME        = "GKOI"
    # The six below verbatim from prod's nginx-conf/render.env (2026-11-11; audit B4-1) — public origins, not secrets.
    CSP_ENGINE_S3_ORIGIN   = "https://vod.gkoi.com https://gkoi-beta-vods.s3.us-west-2.amazonaws.com"
    CSP_FILES_API_ORIGIN   = "https://files.gkoi.com"
    CSP_FILES_S3_ORIGIN    = "https://gkoi-beta-files.s3.us-west-2.amazonaws.com"
    CSP_WALLET_CONNECT_SRC = "https://auth.privy.io wss://relay.walletconnect.com wss://relay.walletconnect.org wss://www.walletlink.org https://*.rpc.privy.systems https://explorer-api.walletconnect.com"
    CSP_WALLET_FRAME_SRC   = "https://auth.privy.io https://verify.walletconnect.com https://verify.walletconnect.org https://challenges.cloudflare.com"
    CSP_WALLET_IMG_SRC     = "https://explorer-api.walletconnect.com"
  }

  default_engine_env = {
    APP_ENV              = "production"
    LOG_LEVEL            = "info"
    AUTH_MODE            = "gateway"
    POSTGRES_DB          = "mikaido"
    POSTGRES_APP_USER    = "mikaido_app"
    PGSSLMODE            = "require"
    HTTP_KEEPALIVE_MS    = "55000"
    API_PRIVATE_NO_STORE = "1"
    ENGINE_HOME_REGION   = "us-west-2"
    S3_ENDPOINT_INTERNAL = "https://s3.us-west-2.amazonaws.com"
    S3_ENDPOINT_PUBLIC   = "https://s3.us-west-2.amazonaws.com"
    S3_REGION            = "us-west-2"
    CDN_DOWNLOAD_BASE    = "https://vod.gkoi.com"
    PUBLIC_API_URL       = "https://www.gkoi.com/streaming"
    PORTAL_URL           = "https://www.gkoi.com"
    SITE_SERVICE_URL     = "https://www.gkoi.com"
    # HOME_DESTINATION_NAME + LIVE_CDN_BASE from prod (2026-11-11; without the first the app says "Streaming to Mikaido")
    HOME_DESTINATION_NAME = "GKOI"
    LIVE_CDN_BASE         = "https://live.gkoi.com"
    # SPEC-ENGINE-DYNAMIC-REGIONS-V1 C1: every pool comes from the live registry (the EC2 media boxes register
    # themselves — envs/prod2/media). RELAY_POOL_INSTANCES is deliberately ABSENT: the Lightsail list (172.26.x /
    # 10.88.x, unroutable from the VPC) must never reach AWS — a static entry never leaves the registry, so placement
    # would keep choosing it. The api accepts no list only with this flag (config.ts, f997524); the worker needs no flag
    # (its list defaults to empty) and ignores this one.
    RELAY_REGISTRY_ONLY = "1"
    MK_POOL_API_USER    = "mkpool" # from prod (2026-11-11)
    TWITCH_CLIENT_ID    = ""       # from prod (2026-11-11)
    GOOGLE_CLIENT_ID    = ""       # from prod (2026-11-11)
    KICK_CLIENT_ID      = ""       # from prod (2026-11-11)
  }

  default_engine_edge_env = {
    EDGE_TLS              = "off"
    EDGE_API_HOST         = "engine.gkoi.com"
    EDGE_LIVE_ORIGIN_HOST = "origin-live.gkoi.com"
    UPSTREAM              = "127.0.0.1:3000"
    REALIP_MODE           = "alb"
  }

  default_fm_env = {
    APP_ENV                    = "production"
    API_PORT                   = "3200"
    LOG_LEVEL                  = "info"
    POSTGRES_DB                = "filemanager"
    POSTGRES_APP_USER          = "filemanager_app"
    PGSSLMODE                  = "require"
    API_PRIVATE_NO_STORE       = "1"
    PUBLIC_BASE_URL            = "https://files.gkoi.com"
    THUMBS_PUBLIC_BASE_URL     = "https://cdn.gkoi.com"
    S3_ENDPOINT_INTERNAL       = "https://s3.us-west-2.amazonaws.com"
    S3_ENDPOINT_PUBLIC         = "https://s3.us-west-2.amazonaws.com"
    S3_REGION                  = "us-west-2"
    S3_FORCE_PATH_STYLE        = "0"
    CDN_DOWNLOAD_BASE          = "https://dl.gkoi.com"
    CDN_KEY_PAIR_ID            = "K2DJ50W8CDZ68L" # from prod (2026-11-11)
    ASSETS_ORPHAN_SWEEP_MODE   = "report"
    ASSETS_AUTO_SYNC_MAX_BYTES = "1073741824" # from prod (2026-11-11; the 256 MiB default stops large avatars auto-syncing)
  }
}
