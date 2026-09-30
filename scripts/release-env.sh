#!/bin/bash
# Shared by release scripts. Source from the repository root.
load_dotenv() {
  [[ -f .env ]] || return 0
  local names=(GH_TOKEN GH_REPO DEVELOPER_ID_APPLICATION APPLE_TEAM_ID
    APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER_ID SPARKLE_PRIVATE_KEY
    SPARKLE_PUBLIC_KEY OMIL_RELEASE_CACHE_DIR OMIL_DISTRIBUTION_DIR IOS_EXPORT_METHOD)
  local preserved=() name saved_name
  for name in "${names[@]}"; do
    if [[ -n ${!name:-} ]]; then
      saved_name="omil_saved_${name}"
      printf -v "$saved_name" '%s' "${!name}"
      preserved+=("$name")
    fi
  done
  set -a
  # .env is a trusted local shell file ignored by git.
  # shellcheck disable=SC1091
  source .env
  set +a
  set +x
  for name in ${preserved[@]+"${preserved[@]}"}; do
    saved_name="omil_saved_${name}"
    export "$name=${!saved_name}"
  done
}
load_dotenv

# Team API keys work with both notarytool and Xcode automatic provisioning.
configure_apple_api_auth() {
  local name
  for name in APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
    [[ -n ${!name:-} ]] || { echo "error: set $name in .env for App Store Connect API authentication" >&2; return 1; }
  done
  [[ $APPLE_API_KEY_ID =~ ^[A-Za-z0-9]{10,}$ ]] || { echo 'error: invalid APPLE_API_KEY_ID' >&2; return 1; }
  [[ $APPLE_API_ISSUER_ID =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
    || { echo 'error: APPLE_API_ISSUER_ID must be the issuer UUID for your team API key' >&2; return 1; }
  [[ -f $APPLE_API_KEY_PATH && -r $APPLE_API_KEY_PATH ]] \
    || { echo 'error: APPLE_API_KEY_PATH must point to your downloaded readable .p8 private key' >&2; return 1; }
  command -v openssl >/dev/null || { echo 'error: openssl is required to validate the API key' >&2; return 1; }
  openssl pkey -in "$APPLE_API_KEY_PATH" -passin pass: -check -noout >/dev/null 2>&1 \
    || { echo 'error: the API key file is not a valid unencrypted private key' >&2; return 1; }
  APPLE_API_KEY_PATH=$(cd "$(dirname "$APPLE_API_KEY_PATH")" && pwd)/$(basename "$APPLE_API_KEY_PATH")
  export APPLE_API_KEY_PATH
  # Used by distribute-mac.sh and distribute-ios.sh after this function returns.
  # shellcheck disable=SC2034
  notary_auth=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
  # shellcheck disable=SC2034
  provisioning_auth=(-authenticationKeyPath "$APPLE_API_KEY_PATH" \
    -authenticationKeyID "$APPLE_API_KEY_ID" -authenticationKeyIssuerID "$APPLE_API_ISSUER_ID")
}

distribution_directory() {
  if [[ -n ${OMIL_DISTRIBUTION_DIR:-} ]]; then
    [[ ! -e $OMIL_DISTRIBUTION_DIR ]] || { echo "error: output directory already exists: $OMIL_DISTRIBUTION_DIR" >&2; return 1; }
    mkdir -p "$OMIL_DISTRIBUTION_DIR"
    (cd "$OMIL_DISTRIBUTION_DIR" && pwd)
  else
    mkdir -p .build/distribution
    mktemp -d "$PWD/.build/distribution/Omil-release.XXXXXX"
  fi
}
