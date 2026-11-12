#!/bin/zsh
# Copies the page into build/site/keychain-cam/ and deploys it with wrangler.
set -e
cd "$(dirname "$0")"
rm -rf ../build/site && mkdir -p ../build/site/keychain-cam
cp index.html sw.js manifest.webmanifest *.png ../build/site/keychain-cam/
npx -y wrangler@4 deploy --config wrangler.jsonc
