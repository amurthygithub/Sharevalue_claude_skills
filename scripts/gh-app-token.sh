#!/usr/bin/env bash
# OPTIONAL — mint a short-lived (~1h) GitHub App installation token.
#
# Why this exists: branch protection can require a formal "Approve" from a
# distinct identity. To let your review bot (<BOT_NAME>) post that Approve —
# rather than approving your own PRs as yourself — you mint an installation
# token for a GitHub App you control, then run `gh pr review --approve` as
# that App. Skip this whole file if your workflow doesn't gate merges on a
# bot approval; nothing else in the template depends on it.
#
# Reads from env (no secret VALUES live in this file — set these in your shell):
#   <BOT_APP_ID>            numeric GitHub App ID
#   <BOT_INSTALLATION_ID>   numeric Installation ID (App installed on the repo)
#   <BOT_PRIVATE_KEY_PATH>  filesystem path to the App's RSA private key (.pem)
#
# Prints the installation token to stdout (and nothing else there). Exits
# non-zero on failure with the error on stderr. Capture it inline so the
# value never lands in a logged command or shell history:
#
#   GH_TOKEN="$(scripts/gh-app-token.sh)" gh pr review <PR> --approve
#
# We mint a fresh token every call: no caching, no reuse across invocations.
# An installation token inherits the App's permissions and lasts ~60 minutes,
# so short-lived-by-construction beats a long-lived PAT in a credential file.
#
# Deps: openssl + curl + jq (defaults on macOS / most Linux).

set -euo pipefail

# CUSTOMIZE: rename these to your actual env-var names. The `:?` form fails
# closed — an unset/empty value aborts the script rather than minting a
# token for the wrong App.
: "${BOT_APP_ID:?BOT_APP_ID env not set}"
: "${BOT_INSTALLATION_ID:?BOT_INSTALLATION_ID env not set}"
: "${BOT_PRIVATE_KEY_PATH:?BOT_PRIVATE_KEY_PATH env not set}"

if [ ! -r "$BOT_PRIVATE_KEY_PATH" ]; then
  echo "❌ Private key not readable at: $BOT_PRIVATE_KEY_PATH" >&2
  exit 1
fi

# Build the App JWT (RS256). GitHub caps the JWT lifetime at 10 minutes; we
# use 9 with a 60s backdated `iat` to absorb clock skew between hosts.
NOW=$(date +%s)
IAT=$((NOW - 60))
EXP=$((NOW + 540))

# base64url: standard base64, +/ → -_, strip '=' padding. JWT segments
# require URL-safe alphabet — plain base64 produces invalid tokens.
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

HEADER='{"alg":"RS256","typ":"JWT"}'
PAYLOAD="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$IAT" "$EXP" "$BOT_APP_ID")"

H_ENC=$(printf '%s' "$HEADER"  | b64url)
P_ENC=$(printf '%s' "$PAYLOAD" | b64url)

# Sign `<header>.<payload>` with the App private key; append the signature.
SIG=$(printf '%s.%s' "$H_ENC" "$P_ENC" \
  | openssl dgst -sha256 -sign "$BOT_PRIVATE_KEY_PATH" \
  | b64url)

JWT="${H_ENC}.${P_ENC}.${SIG}"

# Exchange the JWT for an installation access token.
RESP=$(curl -sS -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${BOT_INSTALLATION_ID}/access_tokens")

TOKEN=$(printf '%s' "$RESP" | jq -r '.token // empty')

# Fail closed: surface the API response on STDERR only (never stdout —
# stdout is the token channel the caller captures), then exit non-zero.
if [ -z "$TOKEN" ]; then
  echo "❌ Token mint failed. Response:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi

# The token is this script's sole stdout output, with no trailing newline,
# so `GH_TOKEN="$(...)"` captures exactly the value. Do not add an `echo`
# or log line here — that is the one place the secret would leak.
printf '%s' "$TOKEN"
