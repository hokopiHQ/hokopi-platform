#!/bin/sh
set -eu

# Explicit public allowlist. Omit unset/empty values to allow Vite fallbacks.
config=$(jq -n '{API_URL: env.API_URL, STRIPE_PUBLIC_KEY: env.STRIPE_PUBLIC_KEY, APP_ENV: env.APP_ENV} | with_entries(select(.value != null and .value != ""))')
printf 'window.__CONFIG__ = %s;\n' "$config" > "${1:-/usr/share/nginx/html/config.js}"
