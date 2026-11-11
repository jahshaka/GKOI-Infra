# The plain-environment DEFAULTS (variables.tf's *_env maps are merged on top). Values only — never a secret.

locals {
  default_cms_server_env = {
    NODE_ENV                = "production"
    APP_ENV                 = "production"
    HOST                    = "0.0.0.0"
    PORT                    = "8090"
    LOG_LEVEL               = "info"
    SITE_URL                = "https://www.gkoi.com"
    TRUST_PROXY             = "loopback"   # the task's own nginx on 127.0.0.1
    DB_NAME                 = "aisolver_cms"  # from prod (2026-11-11)
    DB_USER                 = "cms"  # from prod (2026-11-11)
    PGSSLMODE               = "require"    # verify-full needs the RDS CA bundle in the image (README "TLS to RDS")
    CONTENT_DIR             = "/data/content"
    NGINX_CACHE_DIR         = "/data/nginx-cache"
    SESSION_COOKIE_NAME     = "__Host-gkoi_session"  # from prod (2026-11-11)
    MIKAIDO_ENGINE_URL      = "https://engine.gkoi.com"
    FILES_SERVICE_URL       = "https://files.gkoi.com"
    APP_SERVICE_PUBLIC_URLS = "{\"mikaido\":\"https://engine.gkoi.com\",\"files\":\"https://files.gkoi.com\"}"
    LABS_COUNTRY_HEADER     = "cloudfront"
    SMTP_HOST               = ""  # from prod (2026-11-11)
    SMTP_PORT               = ""  # from prod (2026-11-11)
    SMTP_USER               = ""  # from prod (2026-11-11)
    MAIL_FROM               = ""  # from prod (2026-11-11)
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
    CSP_CDN_ORIGIN      = "https://cdn.gkoi.com"
    CSP_LIVE_CDN_ORIGIN = "https://live.gkoi.com"
    PRODUCT_NAME        = "GKOI"
  }

  default_engine_env = {
    APP_ENV                  = "production"
    LOG_LEVEL                = "info"
    AUTH_MODE                = "gateway"
    POSTGRES_DB              = "mikaido"
    POSTGRES_APP_USER        = "mikaido_app"
    PGSSLMODE                = "require"
    REDIS_REQUIRE_NOEVICTION = "1"
    HTTP_KEEPALIVE_MS        = "55000"
    API_PRIVATE_NO_STORE     = "1"
    ENGINE_HOME_REGION       = "us-west-2"
    S3_ENDPOINT_INTERNAL     = "https://s3.us-west-2.amazonaws.com"
    S3_ENDPOINT_PUBLIC       = "https://s3.us-west-2.amazonaws.com"
    S3_REGION                = "us-west-2"
    CDN_DOWNLOAD_BASE        = "https://vod.gkoi.com"
    PUBLIC_API_URL           = "https://www.gkoi.com/streaming"
    PORTAL_URL               = "https://www.gkoi.com"
    SITE_SERVICE_URL         = "https://www.gkoi.com"
    RELAY_POOL_INSTANCES     = "[{\"id\":\"mk-pool-0\",\"region\":\"us-west-2\",\"controlBaseUrl\":\"http://mk-pool-0:9997\",\"internalHost\":\"mk-pool-0\",\"publicHost\":\"stream.gkoi.com\",\"publicRtmpPort\":11935,\"publicRtmpsPort\":11936,\"apiHost\":\"172.26.12.2\",\"apiHlsPort\":18888,\"apiWhipPort\":18889,\"apiControlBaseUrl\":\"http://172.26.12.2:19997\",\"liveOriginBase\":\"https://live.gkoi.com\"},{\"id\":\"mk-pool-1\",\"region\":\"us-west-2\",\"controlBaseUrl\":\"http://mk-pool-1:9997\",\"internalHost\":\"mk-pool-1\",\"publicHost\":\"stream.gkoi.com\",\"publicRtmpPort\":21935,\"publicRtmpsPort\":21936,\"apiHost\":\"172.26.12.2\",\"apiHlsPort\":28888,\"apiWhipPort\":28889,\"apiControlBaseUrl\":\"http://172.26.12.2:29997\",\"liveOriginBase\":\"https://live.gkoi.com\"},{\"id\":\"euc1-0\",\"region\":\"eu-central-1\",\"controlBaseUrl\":\"http://mk-pool-0:9997\",\"internalHost\":\"mk-pool-0\",\"publicHost\":\"stream-euc1.gkoi.com\",\"publicRtmpPort\":11935,\"publicRtmpsPort\":11936,\"apiHost\":\"10.88.0.2\",\"apiHlsPort\":18888,\"apiWhipPort\":18889,\"apiControlBaseUrl\":\"http://10.88.0.2:19997\",\"liveOriginBase\":\"https://live.gkoi.com\"},{\"id\":\"euc1-1\",\"region\":\"eu-central-1\",\"controlBaseUrl\":\"http://mk-pool-1:9997\",\"internalHost\":\"mk-pool-1\",\"publicHost\":\"stream-euc1.gkoi.com\",\"publicRtmpPort\":21935,\"publicRtmpsPort\":21936,\"apiHost\":\"10.88.0.2\",\"apiHlsPort\":28888,\"apiWhipPort\":28889,\"apiControlBaseUrl\":\"http://10.88.0.2:29997\",\"liveOriginBase\":\"https://live.gkoi.com\"}]"  # from prod (2026-11-11)
    MK_POOL_API_USER         = "mkpool"  # from prod (2026-11-11)
    TWITCH_CLIENT_ID         = ""  # from prod (2026-11-11)
    GOOGLE_CLIENT_ID         = ""  # from prod (2026-11-11)
    KICK_CLIENT_ID           = ""  # from prod (2026-11-11)
  }

  default_engine_edge_env = {
    EDGE_TLS              = "off"
    EDGE_API_HOST         = "engine.gkoi.com"
    EDGE_LIVE_ORIGIN_HOST = "origin-live.gkoi.com"
    UPSTREAM              = "127.0.0.1:3000"
    REALIP_MODE           = "alb"
  }

  default_fm_env = {
    APP_ENV                  = "production"
    API_PORT                 = "3200"
    LOG_LEVEL                = "info"
    POSTGRES_DB              = "filemanager"
    POSTGRES_APP_USER        = "filemanager_app"
    PGSSLMODE                = "require"
    REDIS_REQUIRE_NOEVICTION = "1"
    API_PRIVATE_NO_STORE     = "1"
    PUBLIC_BASE_URL          = "https://files.gkoi.com"
    THUMBS_PUBLIC_BASE_URL   = "https://cdn.gkoi.com"
    S3_ENDPOINT_INTERNAL     = "https://s3.us-west-2.amazonaws.com"
    S3_ENDPOINT_PUBLIC       = "https://s3.us-west-2.amazonaws.com"
    S3_REGION                = "us-west-2"
    S3_FORCE_PATH_STYLE      = "0"
    CDN_DOWNLOAD_BASE        = "https://dl.gkoi.com"
    CDN_KEY_PAIR_ID          = "K2DJ50W8CDZ68L"  # from prod (2026-11-11)
    ASSETS_ORPHAN_SWEEP_MODE = "report"
  }
}
